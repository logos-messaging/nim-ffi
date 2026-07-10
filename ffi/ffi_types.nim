import std/tables
import chronos

################################################################################
### Exported types

type FFICallBack* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}
  ## Result-delivery callback. `callerRet` is one of the `RET_*` codes below.
  ## `RET_OK`/`RET_ERR` are *terminal*: they fire exactly once and end the
  ## request. `RET_STALE_WARN` is *non-terminal*: it may fire repeatedly while a
  ## handler is still running (see below) and is always followed by a terminal
  ## code. Consumers that only care about the final answer should ignore it.

const RET_OK*: cint = 0
const RET_ERR*: cint = 1
const RET_MISSING_CALLBACK*: cint = 2
const RET_STALE_WARN*: cint = 3
  ## Non-terminal progress signal: the request is still in flight. Delivered
  ## every `StaleWarnInterval` (default 5s) for as long as the handler runs, with
  ## `msg` carrying the elapsed milliseconds as a decimal ASCII string. nim-ffi
  ## never times a handler out — it always ends with a terminal `RET_OK`/
  ## `RET_ERR`; `RET_STALE_WARN` just lets the caller decide whether to keep
  ## waiting.

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
