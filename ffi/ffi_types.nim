import std/tables
import chronos

################################################################################
### Exported types

type FFICallBack* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

const RET_OK*: cint = 0
const RET_ERR*: cint = 1
const RET_MISSING_CALLBACK*: cint = 2

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

## Per-request handler-timeout overrides in milliseconds, keyed by the same Req
## type name as `registeredRequests`. Populated at compile time from a
## `{.ffi: "timeout = <ms>".}` spec; an absent key means "use the context's
## `defaultRequestTimeout`". Like `registeredRequests`, never mutated at run time.
var requestTimeoutsMs*: Table[cstring, int]

### End of FFI utils
################################################################################
