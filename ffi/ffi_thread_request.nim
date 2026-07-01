## Carries one CBOR-encoded request blob between the main thread and the FFI
## thread. The main thread allocates the request, the FFI thread frees it
## after invoking the user callback.
##
## All three pieces (envelope, reqId copy, payload buffer) are obtained from
## libc `malloc` and released by libc `free`. Nim's `allocShared` under
## `--mm:orc` is backed by a per-thread `MemRegion` stored in TLS; if the
## producer thread (commonly a transient `std::async` worker on the foreign
## side) has exited by the time the FFI thread runs `deleteRequest`, the
## chunk's `owner` pointer dangles into reclaimed TLS and the deallocator
## segfaults. `malloc`/`free` are process-global and immune to that.

import system/ansi_c
import results
import chronos
import ./ffi_types, ./alloc, ./cbor_serial

const EmptyErrorMarker = "unknown error"
  ## Sent verbatim on RET_ERR when the handler produced no message — keeps
  ## the callback's msg ptr non-nil and gives the foreign side a recognizable
  ## fallback to log.

type FFIThreadRequest* = object
  callback*: FFICallBack
  userData*: pointer
  reqId*: cstring ## Per-proc Req type name used to look up the handler.
  data*: ptr UncheckedArray[byte] ## Owned CBOR-encoded request payload.
  dataLen*: int
  next*: ptr FFIThreadRequest
    ## Intrusive ingress-queue link (see `ffi_request_queue.nim`). Touched only
    ## under the queue's lock; the request doubles as its own node, so no
    ## separate node alloc lands on the per-thread ORC MemRegion.
  responded*: bool
    ## De-duplicates the callback across the timeout and completion paths. Both
    ## run on the FFI thread, so a plain flag suffices — no cross-thread race.

proc allocBaseRequest(
    callback: FFICallBack, userData: pointer, reqId: cstring
): ptr FFIThreadRequest =
  ## Allocates the request envelope via `c_malloc` and populates the routing
  ## fields. Payload setup is delegated to one of the payload helpers below
  ## depending on whether the bytes need to be copied or adopted.
  var ret = cast[ptr FFIThreadRequest](c_malloc(csize_t(sizeof(FFIThreadRequest))))
  ret[].callback = callback
  ret[].userData = userData
  ret[].reqId = reqId.alloc()
  ret[].data = nil
  ret[].dataLen = 0
  ret[].next = nil
  ret[].responded = false
  return ret

proc copySharedPayload(req: ptr FFIThreadRequest, data: ptr byte, dataLen: int) =
  ## Allocates a fresh `c_malloc` buffer and copies `dataLen` bytes from
  ## `data` into `req`. Empty payloads (non-positive `dataLen` or nil
  ## `data`) leave the request's payload fields at their zero-initialised
  ## state.
  if dataLen > 0 and not data.isNil():
    req[].data = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(dataLen)))
    copyMem(req[].data, data, dataLen)
    req[].dataLen = dataLen

proc adoptOwnedSharedPayload(
    req: ptr FFIThreadRequest, data: ptr UncheckedArray[byte], dataLen: int
) =
  ## Embeds an already-`c_malloc`'d buffer into `req` without copying.
  ## `(nil, 0)` is the empty-payload contract; a zero-length-but-non-nil
  ## buffer is treated as empty and disposed here so it doesn't leak.
  if dataLen > 0 and not data.isNil():
    req[].data = data
    req[].dataLen = dataLen
  elif not data.isNil():
    c_free(data)

proc initFromPtr*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    data: ptr byte,
    dataLen: int,
): ptr type T =
  ## Takes a raw ptr+len; the bytes are copied into a fresh shared-memory
  ## buffer owned by the returned request.
  var ret = allocBaseRequest(callback, userData, reqId)
  copySharedPayload(ret, data, dataLen)
  return ret

proc init*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    data: openArray[byte],
): ptr type T =
  ## Same contract as `initFromPtr` but accepts a Nim openArray, copying its
  ## bytes into a fresh shared-memory buffer owned by the returned request.
  let dataPtr =
    if data.len > 0:
      cast[ptr byte](unsafeAddr data[0])
    else:
      nil
  initFromPtr(T, callback, userData, reqId, dataPtr, data.len)

proc initFromOwnedShared*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    data: ptr UncheckedArray[byte],
    dataLen: int,
): ptr type T =
  ## Takes ownership of an already-allocated buffer (`data`) and embeds it
  ## in the request without copying. Pair with `cborEncodeShared` so the
  ## request payload travels from encoder to FFI thread with a single
  ## allocation instead of seq → c_malloc + copyMem.
  ##
  ## Ownership: `data` must have been allocated via `c_malloc`. After this
  ## call, `deleteRequest` will `c_free` it. Pass `(nil, 0)` for an empty
  ## payload.
  var ret = allocBaseRequest(callback, userData, reqId)
  adoptOwnedSharedPayload(ret, data, dataLen)
  return ret

proc deleteRequest*(request: ptr FFIThreadRequest) =
  if not request[].data.isNil:
    c_free(request[].data)
  if not request[].reqId.isNil:
    c_free(cast[pointer](request[].reqId))
  c_free(request)

proc fireCallback(res: Result[seq[byte], string], request: ptr FFIThreadRequest) =
  ## Delivers one response to the foreign callback. Success payload is CBOR
  ## bytes; error payload is the raw UTF-8 error string.
  if res.isErr():
    foreignThreadGc:
      let msg = if res.error.len > 0: res.error else: EmptyErrorMarker
      request[].callback(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), request[].userData
      )
    return

  foreignThreadGc:
    let bytes = res.get()
    if bytes.len > 0:
      request[].callback(
        RET_OK,
        cast[ptr cchar](unsafeAddr bytes[0]),
        cast[csize_t](bytes.len),
        request[].userData,
      )
    else:
      # Always hand the callback a real buffer; CBOR null marks "no value".
      var sentinel = CborNullByte
      request[].callback(
        RET_OK, cast[ptr cchar](addr sentinel), 1.csize_t, request[].userData
      )

proc respondOnce*(request: ptr FFIThreadRequest, res: Result[seq[byte], string]) =
  ## Fires the callback the first time it's called for `request` and no-ops
  ## after — the timeout path and the handler-completion path both call it, but
  ## the foreign side must be answered exactly once. Does NOT free the request:
  ## freeing stays with `handleRes` so the handler always owns the buffer until
  ## it finishes.
  if request[].responded:
    return
  request[].responded = true
  fireCallback(res, request)

proc handleRes*(res: Result[seq[byte], string], request: ptr FFIThreadRequest) =
  ## Terminal step of every request: delivers the response (unless a timeout
  ## already did) and frees the request exactly once.
  defer:
    deleteRequest(request)
  respondOnce(request, res)

proc nilProcess*(reqId: cstring): Future[Result[seq[byte], string]] {.async.} =
  return err("This request type is not implemented: " & $reqId)
