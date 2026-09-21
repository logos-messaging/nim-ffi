## `{.ffi.}` picks the path from the shape of the signature. This file writes one
## proc per path with the same pragma, then calls each generated C wrapper.

import unittest2
import results
import ffi
import ./helpers

type RouterLib = ref object
  marker: int

type RouterTick {.ffi.} = object
  count: int

# A stub for the NimMain proc that declareLibrary imports. The test links as a
# plain executable.
{.emit: "void librouterNimMain(void) {}".}

declareLibrary("router", RouterLib)

proc router_create*(seed: int): Future[Result[RouterLib, string]] {.ffiCtor.} =
  return ok(RouterLib(marker: seed))

# A library receiver, so the router picks the context method.
proc router_marker*(lib: RouterLib): Future[Result[int, string]] {.ffi.} =
  return ok(lib.marker)

# No receiver, so the router picks the static call.
proc router_version*(): Future[Result[string, string]] {.ffi.} =
  return ok("router v1")

# No arguments and a plain return type, so the router picks the synchronous
# export.
proc router_alive*(): int {.ffi.} =
  7

# `int` is pointer-wide, so the export must not narrow it to a C `int`.
proc router_big*(): int {.ffi.} =
  int(high(int32)) + 1

proc router_banner*(): string {.ffi.} =
  "router banner"

var routerBeats = 0

proc router_beat*() {.ffi.} =
  inc routerBeats

proc router_raises*(): int {.ffi.} =
  raise newException(ValueError, "boom")

# A library receiver and no result, so the router picks the destructor.
proc router_destroy*(lib: RouterLib) {.ffi.} =
  discard

# A payload parameter and no result, so the router picks the event. The leading
# literal sets the wire name, exactly as {.ffiEvent.} accepts it.
proc onRouterTick*(evt: RouterTick) {.ffi: "on_router_tick".} =
  discard

# The event queue is per-thread, so only a handler on the FFI thread can fire.
proc router_tick*(lib: RouterLib): Future[Result[int, string]] {.ffi.} =
  onRouterTick(RouterTick(count: 3))
  return ok(lib.marker)

proc createCtx(): FFICtxToken =
  var cfg = cborEncode(RouterCreateCtorReq(seed: 42))
  var token: FFICtxToken
  var reqId: uint64
  if router_create(encodedPtr(cfg), cfg.len.csize_t, addr token, addr reqId) != RET_OK:
    return FFICtxToken(nil)
  doAssert pollReply(RouterLibFFIPool.resolveCtx(token), reqId).retCode == RET_OK
  return token

suite "{.ffi.} routes on the shape of the signature":
  test "a library receiver routes to the context method":
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      discard router_destroy(ctx)

    var req = cborEncode(RouterMarkerReq())
    var reqId: uint64
    check router_marker(ctx, encodedPtr(req), req.len.csize_t, addr reqId) == RET_OK
    let reply = pollReply(RouterLibFFIPool.resolveCtx(ctx), reqId)
    check reply.retCode == RET_OK
    check cborDecode(reply.payload, int).value == 42

  test "no receiver routes to the static call, answered on the static context":
    defer:
      discard RouterLibFFIPool.destroyStaticFFIContext()
    var req = cborEncode(RouterVersionReq())
    var reqId: uint64
    check router_version(encodedPtr(req), req.len.csize_t, addr reqId) == RET_OK
    check reqId != 0

    # The host polls the token `<lib>_static_ctx()` hands out, like any other context.
    let staticToken = router_static_ctx()
    check not staticToken.isNil()
    check router_static_ctx() == staticToken
    var msg: ptr NimFfiMsg
    check router_poll(staticToken, 5000, addr msg) == RET_OK
    check msg.kind == MsgReply
    check msg.id == reqId
    check msg.retCode == RET_OK
    var payload = newSeq[byte](int(msg.len))
    copyMem(addr payload[0], msg.payload, int(msg.len))
    check cborDecode(payload, string).value == "router v1"

  test "no arguments and a plain return type route to the synchronous export":
    # The export returns its value directly, with no context and no callback.
    check router_alive() == clonglong(7)

  test "an int export keeps its full width across the C ABI":
    check router_big() == clonglong(int32.high) + 1

  test "a string export returns bytes the caller can read":
    check $router_banner() == "router banner"

  test "a no-return export routes to a void C symbol":
    let before = routerBeats
    router_beat()
    check routerBeats == before + 1

  test "an exception in the body never crosses the C ABI":
    check router_raises() == clonglong(0)

  test "a payload parameter and no result route to the event":
    let ctx = createCtx()
    check not ctx.isNil()
    defer:
      discard router_destroy(ctx)

    var req = cborEncode(RouterTickReq())
    var reqId: uint64
    check router_tick(ctx, encodedPtr(req), req.len.csize_t, addr reqId) == RET_OK

    var msg: ptr NimFfiMsg
    check router_poll(ctx, 5000, addr msg) == RET_OK
    check msg.kind == MsgEvent
    check msg.nameId == nameId("on_router_tick")
    var payload = newSeq[byte](int(msg.len))
    copyMem(addr payload[0], msg.payload, int(msg.len))
    check cborDecode(payload, RouterTick).value.count == 3

    # One stream: the event the handler emitted comes before the handler's reply.
    check router_poll(ctx, 5000, addr msg) == RET_OK
    check msg.kind == MsgReply
    check msg.id == reqId

  test "a library receiver and no result route to the destructor":
    let ctx = createCtx()
    check not ctx.isNil()
    check router_destroy(ctx) == RET_OK
    # The token died with its context, so a second destroy is refused like a nil one.
    check router_destroy(ctx) == RET_INVALID_CTX
    check router_destroy(cast[FFICtxToken](nil)) == RET_INVALID_CTX
