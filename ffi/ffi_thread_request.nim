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

const MaxScalarArgs* = 8
  ## Inline capacity for the scalar fast path. A `.ffi.` method with more than
  ## this many scalar params can't use the fast path (checked at compile time).

type FFIThreadRequest* = object
  callback*: FFICallBack
  userData*: pointer
  reqId*: cstring ## Per-proc Req type name used to look up the handler.
  data*: ptr UncheckedArray[byte] ## Owned CBOR-encoded request payload.
  dataLen*: int
  isScalar*: bool
    ## Set by `initScalar`: the payload rode inline in `scalarArgs` (no CBOR,
    ## no `data` buffer). Lets `handleRes` tell a scalar 0-length return (a real
    ## empty string) from a CBOR "no value".
  scalarArgs*: array[MaxScalarArgs, uint64]
    ## Scalar-fast-path args inlined in the envelope so there's no per-call
    ## `c_malloc`. A plain array rather than a `union` with `data`: costs a fixed
    ## 64 bytes per request but keeps `deleteRequest` unaliased and branch-free.
  next*: ptr FFIThreadRequest
    ## Intrusive ingress-queue link (see `ffi_request_queue.nim`). Touched only
    ## under the queue's lock; the request doubles as its own node, so no
    ## separate node alloc lands on the per-thread ORC MemRegion.
  responded*: bool
    ## De-duplicates the callback across the timeout and completion paths. Both
    ## run on the FFI thread, so a plain flag suffices — no cross-thread race.

func ffiPackScalar*[T](x: T): uint64 =
  ## Bit-cast one scalar into a `uint64` request slot. Signed ints sign-extend
  ## to 64 bits; `float32` widens to `float64` (exactly representable, so the
  ## value round-trips); `bool` becomes 0/1. Reverse with `ffiUnpackScalar`.
  when T is SomeFloat:
    cast[uint64](float64(x))
  elif T is bool:
    uint64(ord(x))
  elif T is SomeSignedInt:
    cast[uint64](int64(x))
  else:
    uint64(x)

func ffiUnpackScalar*[T](u: uint64, _: typedesc[T]): T =
  ## Inverse of `ffiPackScalar`: reinterpret a request slot back into `T`.
  when T is SomeFloat:
    T(cast[float64](u))
  elif T is bool:
    u != 0'u64
  elif T is SomeSignedInt:
    T(cast[int64](u))
  else:
    T(u)

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
  ret[].isScalar = false
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

proc initScalar*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    args: varargs[uint64],
): ptr type T =
  ## Builds a scalar-fast-path request: the packed scalar args ride inline in
  ## `scalarArgs` with no payload `c_malloc`. `args` come from `ffiPackScalar`.
  ## Only the routing `reqId` cstring is heap-allocated, same as the CBOR path.
  doAssert args.len <= MaxScalarArgs,
    "initScalar: " & $args.len & " scalar args exceed MaxScalarArgs (" & $MaxScalarArgs &
      ")"
  var ret = allocBaseRequest(callback, userData, reqId)
  ret[].isScalar = true
  for i in 0 ..< args.len:
    ret[].scalarArgs[i] = args[i]
  ret

func ffiScalarRetBytes*[T](x: T): seq[byte] =
  ## Serializes a scalar handler result into the raw response payload — no CBOR
  ## envelope. A `string`/`cstring` rides as its own UTF-8 bytes (like the error
  ## path); every other scalar rides as the 8-byte native-endian image of
  ## `ffiPackScalar(x)`. An empty string yields a 0-length payload (see
  ## `handleRes`, which delivers it as `""` rather than the CBOR-null sentinel).
  when T is string:
    var b = newSeq[byte](x.len)
    if x.len > 0:
      copyMem(addr b[0], unsafeAddr x[0], x.len)
    b
  elif T is cstring:
    let n = x.len
    var b = newSeq[byte](n)
    if n > 0:
      copyMem(addr b[0], cast[pointer](x), n)
    b
  else:
    let u = ffiPackScalar(x)
    var b = newSeq[byte](sizeof(uint64))
    copyMem(addr b[0], unsafeAddr u, sizeof(uint64))
    b

proc deleteRequest*(request: ptr FFIThreadRequest) =
  if not request[].data.isNil:
    c_free(request[].data)
  if not request[].reqId.isNil:
    c_free(cast[pointer](request[].reqId))
  c_free(request)

proc fireCallback*(res: Result[seq[byte], string], request: ptr FFIThreadRequest) =
  ## Delivers the response to the foreign callback, at most once per request:
  ## the timeout path and the handler-completion path both call it, but the
  ## foreign side must be answered exactly once. Both run on the FFI thread, so
  ## the plain `responded` flag needs no synchronization. Success payload is the
  ## encoded response bytes; error payload is the raw UTF-8 error string. Does
  ## NOT free the request; that stays with `handleRes`.
  if request[].responded:
    return
  request[].responded = true
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
    elif request[].isScalar:
      # `isScalar` marks a scalar-fast-path request (args rode inline in
      # `scalarArgs`, no CBOR): its result bytes come from `ffiScalarRetBytes`,
      # not a CBOR encoder. So a 0-byte return is a real empty string, not
      # "no value" — hand back a genuine empty buffer, not the CBOR-null sentinel.
      var empty: byte
      request[].callback(
        RET_OK, cast[ptr cchar](addr empty), 0.csize_t, request[].userData
      )
    else:
      # Always hand the callback a real buffer; CBOR null marks "no value".
      var sentinel = CborNullByte
      request[].callback(
        RET_OK, cast[ptr cchar](addr sentinel), 1.csize_t, request[].userData
      )

proc fireStaleWarn*(request: ptr FFIThreadRequest, elapsedMs: int64) =
  ## Non-terminal progress signal telling the caller its request is still in
  ## flight after `elapsedMs`. Unlike `fireCallback` it deliberately does NOT set
  ## `responded` and may fire many times — the one terminal RET_OK/RET_ERR is
  ## still owed. Skipped once a terminal response has gone out. Runs on the FFI
  ## thread, so the plain `responded` read needs no synchronization. The payload
  ## is the elapsed milliseconds as a decimal UTF-8 string.
  if request[].responded:
    return
  foreignThreadGc:
    let msg = $elapsedMs
    request[].callback(
      RET_STALE_WARN,
      cast[ptr cchar](unsafeAddr msg[0]),
      cast[csize_t](msg.len),
      request[].userData,
    )

proc handleRes*(res: Result[seq[byte], string], request: ptr FFIThreadRequest) =
  ## Terminal step of every request: delivers the response and frees the request
  ## exactly once. Any RET_STALE_WARN progress signals have already gone out; the
  ## `responded` guard in `fireStaleWarn` keeps this terminal answer the last one.
  defer:
    deleteRequest(request)
  fireCallback(res, request)

proc nilProcess*(reqId: cstring): Future[Result[seq[byte], string]] {.async.} =
  return err("This request type is not implemented: " & $reqId)
