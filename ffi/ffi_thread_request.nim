## This file contains the base message request type that will be handled.
## The requests are created by the main thread and processed by
## the FFI Thread.

import std/[json, macros], results, tables
import chronos, chronos/threadsync
import ./ffi_types, ./internal/ffi_macro, ./alloc

type FFIDestroyContentProc* = proc(content: pointer) {.nimcall, gcsafe.}

type FFIThreadRequest* = object
  callback: FFICallBack
  userData: pointer
  reqId*: cstring
  reqContent*: pointer
  deleteReqContent*: FFIDestroyContentProc
    ## Called by sendRequestToFFIThread on failure to free reqContent when
    ## the FFI thread will never process (and thus never free) this request.

proc init*(
    T: typedesc[FFIThreadRequest],
    callback: FFICallBack,
    userData: pointer,
    reqId: cstring,
    reqContent: pointer,
): ptr type T =
  var ret = createShared(FFIThreadRequest)
  ret[].callback = callback
  ret[].userData = userData
  ret[].reqId = reqId.alloc()
  ret[].reqContent = reqContent
  return ret

proc deleteRequest*(request: ptr FFIThreadRequest) =
  if not request[].deleteReqContent.isNil():
    request[].deleteReqContent(request[].reqContent)
  deallocShared(request[].reqId)
  deallocShared(request)

proc handleRes*[T: string | void](
    res: Result[T, string], request: ptr FFIThreadRequest
) =
  ## Handles the Result responses, which can either be Result[string, string] or
  ## Result[void, string].

  defer:
    deleteRequest(request)

  if res.isErr():
    foreignThreadGc:
      let msg = "ffi error: handleRes fireSyncRes error: " & $res.error
      request[].callback(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
      )
    return

  foreignThreadGc:
    var resStr: string
      ## we need to bind the string to extend its lifetime to callback's in ARC/ORC
    when T is string:
      resStr = res.get()
    let msg: cstring = resStr.cstring()
    request[].callback(
      RET_OK, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
    )
  return

proc nilProcess*(reqId: cstring): Future[Result[string, string]] {.async.} =
  return err("This request type is not implemented: " & $reqId)
