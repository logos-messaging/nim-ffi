import chronos
import ./ret_codes

export ret_codes

type FFIRequestProc* = proc(
  request: pointer, reqHandler: pointer
): Future[Result[seq[byte], string]] {.async.}
  ## OK payload is a CBOR-encoded response body; errors are plain UTF-8.
