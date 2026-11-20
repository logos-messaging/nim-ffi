## The liveness events are typed in every binding, with no event declared by the library.

import std/strutils
import unittest2
import ffi/codegen/[meta, c, cpp, rust]

let ctor = FFIProcMeta(
  procName: "timer_create",
  libName: "timer",
  kind: FFIKind.CTOR,
  libTypeName: "Timer",
  extraParams: @[],
  returnTypeName: "Timer",
)

const WireNames =
  ["not_responding", "responding", "reverse_worker_blocked", "reverse_worker_recovered"]

suite "builtin liveness events in the C header":
  setup:
    let header = generateCLibHeader(@[ctor], @[], "timer")

  test "a typed registration exists per builtin event":
    check "timer_ctx_add_not_responding_listener(TimerCtx* ctx, TimerNotRespondingFn fn" in
      header
    check "timer_ctx_add_responding_listener(" in header
    check "timer_ctx_add_reverse_worker_blocked_listener(" in header
    check "timer_ctx_add_reverse_worker_recovered_listener(" in header

  test "each registration targets its wire name through the shared decoder":
    for w in WireNames:
      checkpoint(w)
      check "timer_add_event_listener(ctx->ptr, \"" & w & "\"," in header

  test "the payload carries the reason enum":
    check "NotRespondingReason" in header
    check "queueFull" in header

  test "a declared event of the same wire name is not duplicated":
    let own = FFIEventMeta(
      wireName: "not_responding",
      nimProcName: "notResponding",
      libName: "timer",
      payloadTypeName: "NotRespondingEvent",
    )
    let h = generateCLibHeader(@[ctor], @[], "timer", @[own])
    check h.count("timer_ctx_add_not_responding_listener(") == 1

suite "builtin liveness events in the C++ header":
  test "the context gets a typed method per builtin event":
    let header = generateCppHeader(@[ctor], @[], "timer")
    check "ListenerHandle addOnNotRespondingListener(std::function<void(const NotRespondingEvent&)> handler)" in
      header
    check "addOnRespondingListener(" in header
    check "addOnReverseWorkerBlockedListener(" in header
    check "\"not_responding\"" in header

suite "builtin liveness events in the Rust crate":
  test "the api has typed listeners and types.rs the reason enum":
    let api = generateApiRs(@[ctor], "timer")
    check "pub fn add_not_responding_listener<F>" in api
    check "pub fn add_responding_listener<F>" in api
    check "Fn(&NotRespondingEvent)" in api
    let types = generateTypesRs(@[], @[ctor])
    check "pub enum NotRespondingReason {" in types
    check "    Heartbeat," in types
    check "    QueueFull," in types
    check "pub struct NotRespondingEvent {" in types
    check "pub reason: NotRespondingReason," in types
