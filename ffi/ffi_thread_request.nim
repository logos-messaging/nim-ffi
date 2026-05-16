## Carries one request blob between the main thread and the FFI thread.
## The main thread allocates the request (in shared memory), the FFI thread
## frees it after invoking the user callback.
##
## Two payload formats coexist on this carrier:
##   - **CBOR mode** (default; cpp / rust targets): `data` points to
##     CBOR-encoded request bytes that the FFI thread's `processFFIRequest`
##     decodes back into a Nim Req object.
##   - **C-wire mode** (-d:targetLang=c): `data` points to a *typed* wire
##     struct (a `Req_CWire` in shared memory) whose layout matches the C
##     `Req` struct seen by the foreign caller. The FFI thread casts it back
##     to the right `ptr Req_CWire` and unpacks fields without serialisation.
##     The response, similarly, is a `Resp_CWire` ptr cleaned up after the
##     callback fires.
##
## The C-wire mode bolts onto the existing carrier via two cleanup hooks:
##   - `cleanupReqProc`  — invoked by `deleteRequest` so generated code can
##     free cstrings/arrays owned by the wire Req struct.
##   - `cleanupRespData` / `cleanupRespProc` — set by the FFI-thread handler
##     before returning the response bytes; `handleRes` invokes the proc
##     **after** firing the user callback so any shared-memory strings
##     pointed to by the Resp survive at least until the callback returns.

import results
import chronos
import ./ffi_types, ./alloc, ./cbor_serial

const EmptyErrorMarker = "unknown error"
  ## Sent verbatim on RET_ERR when the handler produced no message — keeps
  ## the callback's msg ptr non-nil and gives the foreign side a recognizable
  ## fallback to log.

type
  CleanupProc* = proc(p: pointer) {.nimcall, gcsafe, raises: [].}

  FFIThreadRequest* = object
    callback*: FFICallBack
    userData*: pointer
    reqId*: cstring ## Per-proc Req type name used to look up the handler.
    data*: ptr UncheckedArray[byte] ## CBOR-encoded payload OR typed wire ptr.
    dataLen*: int
    cleanupReqProc*: CleanupProc
      ## C-wire mode only. Called from `deleteRequest` on `data` to free any
      ## shared-memory cstrings/arrays owned by the wire Req struct. The
      ## proc receives the `data` pointer (which is the wire struct itself);
      ## after it returns, `deleteRequest` deallocShared's the struct.
      ## Nil for CBOR mode.
    cleanupRespData*: pointer
    cleanupRespProc*: CleanupProc
      ## Set by the FFI-thread handler before returning the response. Runs
      ## from `handleRes` *after* firing the user callback so shared-memory
      ## strings inside the Resp remain valid throughout the call. Nil for
      ## CBOR mode.

proc allocBaseRequest(
    callback: FFICallBack, userData: pointer, reqId: cstring
): ptr FFIThreadRequest =
  ## Allocates the request envelope in shared memory and populates the
  ## routing fields. Payload setup is delegated to one of the payload helpers
  ## below depending on whether the bytes need to be copied or adopted.
  var ret = createShared(FFIThreadRequest)
  ret[].callback = callback
  ret[].userData = userData
  ret[].reqId = reqId.alloc()
  ret[].data = nil
  ret[].dataLen = 0
  ret[].cleanupReqProc = nil
  ret[].cleanupRespData = nil
  ret[].cleanupRespProc = nil
  return ret

proc copySharedPayload(req: ptr FFIThreadRequest, data: ptr byte, dataLen: int) =
  ## Allocates a fresh shared buffer and copies `dataLen` bytes from `data`
  ## into `req`. Empty payloads (non-positive `dataLen` or nil `data`) leave
  ## the request's payload fields at their zero-initialised state.
  if dataLen > 0 and not data.isNil():
    req[].data = cast[ptr UncheckedArray[byte]](allocShared(dataLen))
    copyMem(req[].data, data, dataLen)
    req[].dataLen = dataLen

proc adoptOwnedSharedPayload(
    req: ptr FFIThreadRequest, data: ptr UncheckedArray[byte], dataLen: int
) =
  ## Embeds an already-`allocShared` buffer into `req` without copying.
  ## `(nil, 0)` is the empty-payload contract; a zero-length-but-non-nil
  ## buffer is treated as empty and disposed here so it doesn't leak.
  if dataLen > 0 and not data.isNil():
    req[].data = data
    req[].dataLen = dataLen
  elif not data.isNil():
    deallocShared(data)

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
  ## Takes ownership of an already-allocated shared-memory buffer (`data`)
  ## and embeds it in the request without copying. Pair with `cborEncodeShared`
  ## so the request payload travels from encoder to FFI thread with a single
  ## allocation instead of seq → allocShared + copyMem.
  ##
  ## Ownership: `data` must have been allocated via `allocShared` / grown via
  ## `reallocShared`. After this call, `deleteRequest` will `deallocShared` it.
  ## Pass `(nil, 0)` for an empty payload.
  var ret = allocBaseRequest(callback, userData, reqId)
  adoptOwnedSharedPayload(ret, data, dataLen)
  return ret

proc initFromOwnedWirePtr*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    wirePtr: pointer,
    wireSize: int,
    cleanup: CleanupProc,
): ptr type T =
  ## C-wire mode constructor. `wirePtr` is the shared-memory wire Req struct
  ## (allocated via `allocShared`); `cleanup` will be invoked from
  ## `deleteRequest` on `wirePtr` before the struct itself is freed.
  ##
  ## A nil `wirePtr` is supported for procs that take no parameters: the
  ## request travels without a payload and no cleanup is needed. `cleanup`
  ## may be nil for POD wire types (no embedded cstrings/arrays).
  var ret = allocBaseRequest(callback, userData, reqId)
  ret[].data = cast[ptr UncheckedArray[byte]](wirePtr)
  ret[].dataLen = wireSize
  ret[].cleanupReqProc = cleanup
  return ret

proc deleteRequest*(request: ptr FFIThreadRequest) =
  if not request[].data.isNil:
    if not request[].cleanupReqProc.isNil:
      # C-wire mode: ask the generated proc to free any cstrings/arrays it
      # owns before we release the struct itself.
      request[].cleanupReqProc(cast[pointer](request[].data))
    deallocShared(request[].data)
  if not request[].reqId.isNil:
    deallocShared(request[].reqId)
  deallocShared(request)

proc handleRes*(res: Result[seq[byte], string], request: ptr FFIThreadRequest) =
  ## Fires the registered callback exactly once and frees the request.
  ## On the CBOR path the OK payload is CBOR bytes; on the C-wire path it is
  ## a struct snapshot whose pointers may reach into shared memory owned by
  ## `cleanupRespData`. Either way the cleanup hook (when set) runs after the
  ## callback returns so those pointers remain valid throughout.
  defer:
    if not request[].cleanupRespProc.isNil:
      request[].cleanupRespProc(request[].cleanupRespData)
      if not request[].cleanupRespData.isNil:
        deallocShared(request[].cleanupRespData)
    deleteRequest(request)

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

proc nilProcess*(reqId: cstring): Future[Result[seq[byte], string]] {.async.} =
  return err("This request type is not implemented: " & $reqId)
