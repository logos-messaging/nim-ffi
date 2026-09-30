import unittest2
import results
import ffi

type CollisionLib = object

registerReqFFI(ParameterCollisionRequest, lib: ptr CollisionLib):
  proc(
      callback: string,
      userData: uint64,
      T: bool,
      request: int,
      reqObj: string,
      sharedData: uint64,
      sharedLen: int,
  ): Future[Result[string, string]] {.async.} =
    return ok(callback & $userData & $T & $request & reqObj & $sharedData & $sharedLen)

suite "generated request identifiers":
  test "user parameter names do not collide with macro internals":
    let request = ParameterCollisionRequest(
      callback: "callback",
      userData: 42,
      T: true,
      request: 7,
      reqObj: "reqObj",
      sharedData: 11,
      sharedLen: 13,
    )
    check request.callback == "callback"
    check request.userData == 42
    check request.T
    check request.request == 7
    check request.reqObj == "reqObj"
    check request.sharedData == 11
    check request.sharedLen == 13
