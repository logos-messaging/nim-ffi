## `{.ffi.}` picks the path from the shape of the signature. This file writes one
## proc per path with the same pragma, then calls each generated C wrapper.

import std/[atomics, os]
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

type CallbackState = object
  called: Atomic[bool]
  retCode: Atomic[int]
  msg: string

proc resetState(s: var CallbackState) =
  s.called.store(false)
  s.retCode.store(-1)
  s.msg = ""

proc recordingCallback(
    retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let s = cast[ptr CallbackState](userData)
  if not msg.isNil() and len > 0:
    s[].msg = newString(int(len))
    copyMem(addr s[].msg[0], msg, int(len))
  s[].retCode.store(int(retCode))
  s[].called.store(true)

proc waitCalled(s: var CallbackState): bool =
  var tries = 0
  while not s.called.load() and tries < 500:
    os.sleep(5)
    inc tries
  s.called.load()

proc createCtx(s: var CallbackState): FFICtxToken =
  resetState(s)
  var cfg = cborEncode(RouterCreateCtorReq(seed: 42))
  let ret = router_create(encodedPtr(cfg), cfg.len.csize_t, recordingCallback, addr s)
  discard waitCalled(s)
  ret

suite "{.ffi.} routes on the shape of the signature":
  test "a library receiver routes to the context method":
    var s: CallbackState
    let ctx = createCtx(s)
    check not ctx.isNil()
    defer:
      discard router_destroy(ctx)

    resetState(s)
    var req = cborEncode(RouterMarkerReq())
    check router_marker(
      ctx, recordingCallback, addr s, encodedPtr(req), req.len.csize_t
    ) == RET_OK
    check waitCalled(s)
    check s.retCode.load() == int(RET_OK)
    check cborDecode(cast[seq[byte]](s.msg), int).value == 42

  test "no receiver routes to the static call, which needs no context":
    var s: CallbackState
    resetState(s)
    var req = cborEncode(RouterVersionReq())
    check router_version(recordingCallback, addr s, encodedPtr(req), req.len.csize_t) ==
      RET_OK
    check waitCalled(s)
    check s.retCode.load() == int(RET_OK)
    check cborDecode(cast[seq[byte]](s.msg), string).value == "router v1"

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
    var s: CallbackState
    let ctx = createCtx(s)
    check not ctx.isNil()
    defer:
      discard router_destroy(ctx)

    var evt: CallbackState
    resetState(evt)
    check router_add_event_listener(
      ctx, "on_router_tick".cstring, recordingCallback, addr evt
    ) != 0'u64

    resetState(s)
    var req = cborEncode(RouterTickReq())
    check router_tick(ctx, recordingCallback, addr s, encodedPtr(req), req.len.csize_t) ==
      RET_OK
    check waitCalled(evt)
    let env = cborDecode(cast[seq[byte]](evt.msg), EventEnvelope[RouterTick])
    check env.value.eventType == "on_router_tick"
    check env.value.payload.count == 3

  test "a library receiver and no result route to the destructor":
    var s: CallbackState
    let ctx = createCtx(s)
    check not ctx.isNil()
    check router_destroy(ctx) == RET_OK
    check router_destroy(cast[FFICtxToken](nil)) == RET_ERR
