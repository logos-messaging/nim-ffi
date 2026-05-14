## Carries one CBOR-encoded request blob between the main thread and the FFI
## thread. The main thread allocates the request (in shared memory), the FFI
## thread frees it after invoking the user callback.

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
  reqId*: cstring
    ## Per-proc Req type name used to look up the handler.
  data*: ptr UncheckedArray[byte]
    ## Owned CBOR-encoded request payload.
  dataLen*: int

proc init*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    data: openArray[byte],
): ptr type T =
  var ret = createShared(FFIThreadRequest)
  ret[].callback = callback
  ret[].userData = userData
  ret[].reqId = reqId.alloc()
  ret[].data = nil
  ret[].dataLen = data.len
  if data.len > 0:
    ret[].data = cast[ptr UncheckedArray[byte]](allocShared(data.len))
    copyMem(ret[].data, unsafeAddr data[0], data.len)
  return ret

proc initFromPtr*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    data: ptr byte,
    dataLen: int,
): ptr type T =
  ## Same as init but takes a raw ptr+len, avoiding the need to bind an
  ## openArray to a local for callers that operate on raw FFI buffers.
  ## The bytes are copied into a fresh shared-memory buffer.
  var ret = createShared(FFIThreadRequest)
  ret[].callback = callback
  ret[].userData = userData
  ret[].reqId = reqId.alloc()
  ret[].data = nil
  ret[].dataLen = 0
  if dataLen > 0 and not data.isNil:
    ret[].data = cast[ptr UncheckedArray[byte]](allocShared(dataLen))
    copyMem(ret[].data, data, dataLen)
    ret[].dataLen = dataLen
  return ret

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
  var ret = createShared(FFIThreadRequest)
  ret[].callback = callback
  ret[].userData = userData
  ret[].reqId = reqId.alloc()
  ret[].data = nil
  ret[].dataLen = 0
  if dataLen > 0 and not data.isNil():
    ret[].data = data
    ret[].dataLen = dataLen
  elif not data.isNil():
    # `cborEncodeShared` returns `(nil, 0)` for empty payloads, but be safe
    # if a caller hands us a zero-length-but-non-nil buffer.
    deallocShared(data)
  return ret

proc deleteRequest*(request: ptr FFIThreadRequest) =
  if not request[].data.isNil:
    deallocShared(request[].data)
  if not request[].reqId.isNil:
    deallocShared(request[].reqId)
  deallocShared(request)

proc handleRes*(
    res: Result[seq[byte], string], request: ptr FFIThreadRequest
) =
  ## Fires the registered callback exactly once and frees the request.
  ## Success payload is CBOR bytes; error payload is the raw UTF-8 error string.
  defer:
    deleteRequest(request)

  if res.isErr():
    foreignThreadGc:
      let msg =
        if res.error.len > 0: res.error
        else: EmptyErrorMarker
      request[].callback(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), request[].userData
      )
    return

  foreignThreadGc:
    let bytes = res.get()
    if bytes.len > 0:
      request[].callback(
        RET_OK, cast[ptr cchar](unsafeAddr bytes[0]), cast[csize_t](bytes.len),
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
