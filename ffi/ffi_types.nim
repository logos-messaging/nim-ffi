import chronos
import ./ret_codes

export ret_codes

type FFICallBack* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}
  ## Result-delivery callback. `RET_OK`/`RET_ERR` fire once and end the request;
  ## `RET_STALE_WARN` may fire repeatedly before them.

type FFIRequestProc* = proc(
  request: pointer, reqHandler: pointer
): Future[Result[seq[byte], string]] {.async.}
  ## OK payload is a CBOR-encoded response body; errors are plain UTF-8.

template foreignThreadGc*(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()
