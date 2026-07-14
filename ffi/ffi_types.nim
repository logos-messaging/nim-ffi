import std/tables
import chronos

################################################################################
### Exported types

type FFICallBack* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}
  ## Result-delivery callback. `callerRet` is one of the `RET_*` codes below:
  ## `RET_OK`/`RET_ERR` fire exactly once and end the request, `RET_STALE_WARN`
  ## may fire repeatedly before them and should be ignored unless progress
  ## matters.

const RET_OK*: cint = 0
const RET_ERR*: cint = 1
const RET_MISSING_CALLBACK*: cint = 2
const RET_STALE_WARN*: cint = 3
  ## Non-terminal: the request is still in flight. Fires every
  ## `StaleWarnInterval` (default 5s) while the handler runs, `msg` carrying the
  ## elapsed milliseconds as decimal ASCII, and is always followed by a terminal
  ## code — nim-ffi never times a handler out, so the caller decides whether to
  ## keep waiting.

### End of exported types
################################################################################

################################################################################
### FFI utils

type FFIRequestProc* = proc(
  request: pointer, reqHandler: pointer
): Future[Result[seq[byte], string]] {.async.}
  ## The OK payload is a CBOR-encoded response body. Errors are plain UTF-8.

template foreignThreadGc*(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

## Registered requests table populated at compile time and never updated at run time.
## The key represents the request type name as cstring, e.g., "CreateNodeRequest".
## The value is a proc that handles the request asynchronously.
var registeredRequests*: Table[cstring, FFIRequestProc]

### End of FFI utils
################################################################################
