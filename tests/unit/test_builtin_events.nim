## The liveness events are typed in every binding, with no event declared by the library.

import std/[sequtils, strutils]
import unittest2
import ffi/liveness_events
import ffi/codegen/[meta, c, cpp, rust]

let ctor = FFIProcMeta(
  procName: "timer_create",
  libName: "timer",
  kind: FFIKind.CTOR,
  libTypeName: "Timer",
  extraParams: @[],
  returnTypeName: "Timer",
)

const WireNames = [NotRespondingEventName, RespondingEventName]

suite "builtin liveness metadata":
  test "the metadata follows the Nim payload types":
    let types = builtinTypes()
    check types.len == 3
    check types[0].name == "NotRespondingReason"
    check types[0].enumValues.len == 2
    check types[0].enumValues[1].name == $NotRespondingReason.queueFull
    check types[0].enumValues[1].ord == ord(NotRespondingReason.queueFull)
    for t in types[1 .. 2]:
      checkpoint(t.name)
      check t.fields == @[FFIFieldMeta(name: "reason", typeName: "NotRespondingReason")]

  test "only the not_responding and responding events are typed":
    let names = builtinEvents("timer").mapIt(it.wireName)
    check names == @WireNames

suite "builtin liveness events in the C header":
  setup:
    let header = generateCLibHeader(@[ctor], @[], "timer")

  test "a typed registration exists per builtin event":
    check "timer_ctx_add_not_responding_listener(TimerCtx* ctx, TimerNotRespondingFn fn" in
      header
    check "timer_ctx_add_responding_listener(" in header
    check "reverse_worker" notin header

  test "each registration targets its wire name through the shared decoder":
    for w in WireNames:
      checkpoint(w)
      check "timer_add_event_listener(ctx->ptr, \"" & w & "\"," in header

  test "the payload carries the reason enum":
    check "NotRespondingReason" in header
    check "queueFull" in header

  test "each builtin typedef is guarded so two lib headers share a TU":
    for name in ["NOT_RESPONDING_REASON", "NOT_RESPONDING_EVENT", "RESPONDING_EVENT"]:
      checkpoint(name)
      let guard = "NIM_FFI_BUILTIN_" & name & "_DEFINED"
      check ("#ifndef " & guard & "\n#define " & guard & "\ntypedef ") in header

  test "a declared type of a builtin name is not guarded":
    let own = FFITypeMeta(
      name: "NotRespondingEvent",
      fields: @[FFIFieldMeta(name: "reason", typeName: "NotRespondingReason")],
    )
    let h = generateCLibHeader(@[ctor], @[own], "timer")
    check "NIM_FFI_BUILTIN_NOT_RESPONDING_EVENT_DEFINED" notin h
    check "NIM_FFI_BUILTIN_NOT_RESPONDING_REASON_DEFINED" in h

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
    check "ReverseWorker" notin header
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
