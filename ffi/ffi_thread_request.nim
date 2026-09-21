## Request blob passed main→FFI thread. Uses libc malloc/free (not Nim
## allocShared) so a producer thread exiting before the FFI thread frees can't
## dangle into reclaimed per-thread ORC TLS.

import system/ansi_c
import results
import chronos
import ./ffi_types, ./alloc, ./cbor_serial

const MaxRequestPayloadBytes* {.intdefine: "ffiMaxRequestPayloadBytes".} =
  8 * 1024 * 1024
  ## Largest CBOR `data` a submit accepts. Override with
  ## `-d:ffiMaxRequestPayloadBytes=<n>`.

type FFIThreadRequest* = object
  reqId*: uint64 ## What the host got at submit; its reply carries the same id.
  reqTypeName*: cstring ## Req type name used to look up the handler.
  data*: ptr UncheckedArray[byte]
    ## Owned. The CBOR-encoded request, then, once answered, the reply bytes.
  dataLen*: int
  next*: ptr FFIThreadRequest
    ## Intrusive queue link; request doubles as its own node so enqueue needs no
    ## ORC-heap alloc. Links the request queue, then the reply queue.
  generation*: uint
    ## Claim the submitter resolved its context under; the FFI thread drops the request when the slot has since changed owner.
  retCode*: cint ## Set with the reply.
  seq*: uint64 ## Place of the reply among the context's messages.
  staleNext*: ptr FFIThreadRequest
  staleQueued*: bool
    ## A stale warning waits for the poller. One per request: a newer one overwrites it.
  staleElapsedMs*: int64
  staleSeq*: uint64

proc deleteRequest*(request: ptr FFIThreadRequest) =
  if request.isNil():
    return
  if not request[].data.isNil:
    c_free(request[].data)
  if not request[].reqTypeName.isNil:
    c_free(cast[pointer](request[].reqTypeName))
  c_free(request)

proc allocBaseRequest(reqTypeName: cstring): ptr FFIThreadRequest =
  ## c_malloc the envelope and set routing fields; payload set by a helper below.
  ## Nil when the allocation fails; every caller passes that nil on, and
  ## `sendRequestToFFIThread` turns it into an error for the host.
  var ret = cast[ptr FFIThreadRequest](c_malloc(csize_t(sizeof(FFIThreadRequest))))
  if ret.isNil():
    return nil
  zeroMem(ret, sizeof(FFIThreadRequest))
  ret[].reqTypeName = reqTypeName.alloc()
  return ret

proc copySharedPayload(req: ptr FFIThreadRequest, data: ptr byte, dataLen: int): bool =
  ## c_malloc a fresh buffer and copy `dataLen` bytes in; empty payload is a
  ## no-op. False only when the allocation fails.
  if dataLen <= 0 or data.isNil():
    return true
  let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(dataLen)))
  if buf.isNil():
    return false
  copyMem(buf, data, dataLen)
  req[].data = buf
  req[].dataLen = dataLen
  return true

proc adoptOwnedSharedPayload(
    req: ptr FFIThreadRequest, data: ptr UncheckedArray[byte], dataLen: int
) =
  ## Embed an already-c_malloc'd buffer without copying; frees a zero-length
  ## non-nil buffer so it doesn't leak.
  if dataLen > 0 and not data.isNil():
    req[].data = data
    req[].dataLen = dataLen
  elif not data.isNil():
    c_free(data)

proc initFromPtr*(
    T: typedesc[FFIThreadRequest], reqTypeName: cstring, data: ptr byte, dataLen: int
): ptr type T =
  ## Copies raw ptr+len into a fresh buffer owned by the returned request.
  ## Nil when an allocation fails.
  var ret = allocBaseRequest(reqTypeName)
  if ret.isNil():
    return nil
  if not copySharedPayload(ret, data, dataLen):
    deleteRequest(ret)
    return nil
  return ret

proc init*(
    T: typedesc[FFIThreadRequest], reqTypeName: cstring, data: openArray[byte]
): ptr type T =
  ## Like `initFromPtr` but from a Nim openArray.
  let dataPtr =
    if data.len > 0:
      cast[ptr byte](unsafeAddr data[0])
    else:
      nil
  initFromPtr(T, reqTypeName, dataPtr, data.len)

proc initFromOwnedShared*(
    T: typedesc[FFIThreadRequest],
    reqTypeName: cstring,
    data: ptr UncheckedArray[byte],
    dataLen: int,
): ptr type T =
  ## Adopts an already-c_malloc'd buffer (no copy); `deleteRequest` c_frees it.
  ## Pass `(nil, 0)` for an empty payload. Nil when the allocation fails, in which
  ## case it frees the adopted buffer: nobody else owns it any more.
  var ret = allocBaseRequest(reqTypeName)
  if ret.isNil():
    if not data.isNil():
      c_free(data)
    return nil
  adoptOwnedSharedPayload(ret, data, dataLen)
  return ret

proc setReply*(
    request: ptr FFIThreadRequest, res: Result[seq[byte], string]
) {.raises: [].} =
  ## Swaps the request bytes for the reply: the CBOR value, or the UTF-8 error
  ## text. c_malloc'd because the poller is a host thread. When that allocation
  ## fails the reply is a RET_ERR without text.
  if not request[].data.isNil():
    c_free(request[].data)
  request[].data = nil
  request[].dataLen = 0

  var src: pointer = nil
  var n = 0
  # A reply always carries a value; CBOR null marks "no value".
  var noValue = CborNullByte
  if res.isOk():
    request[].retCode = RET_OK
    n = res.value.len
    if n > 0:
      src = unsafeAddr res.value[0]
    else:
      src = addr noValue
      n = 1
  else:
    request[].retCode = RET_ERR
    n = res.error.len
    if n > 0:
      src = unsafeAddr res.error[0]
  if n == 0:
    return

  let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(n)))
  if buf.isNil():
    request[].retCode = RET_ERR
    return
  copyMem(buf, src, n)
  request[].data = buf
  request[].dataLen = n

proc nilProcess*(reqTypeName: cstring): Future[Result[seq[byte], string]] {.async.} =
  return err("This request type is not implemented: " & $reqTypeName)
