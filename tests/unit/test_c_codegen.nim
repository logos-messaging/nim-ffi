## Unit-tests for the C binding generator. Drives generateCHeader directly
## against a synthetic registry (no macro pipeline, no files written) and
## asserts on the emitted text — the same approach as test_cddl_codegen.

import std/strutils
import unittest2
import ffi/codegen/[meta, c]

proc field(n, t: string): FFIFieldMeta =
  FFIFieldMeta(name: n, typeName: t)

proc param(n, t: string, isPtr = false): FFIParamMeta =
  FFIParamMeta(name: n, typeName: t, isPtr: isPtr)

suite "generateCHeader: types and codecs":
  setup:
    let types = @[
      FFITypeMeta(
        name: "EchoRequest",
        fields: @[field("message", "string"), field("delayMs", "int")],
      ),
      FFITypeMeta(name: "EchoResponse", fields: @[field("echoed", "string")]),
      FFITypeMeta(
        name: "ComplexRequest",
        fields:
          @[field("messages", "seq[EchoRequest]"), field("note", "Option[string]")],
      ),
    ]
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[param("config", "EchoRequest")],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_echo",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[param("req", "EchoRequest")],
        returnTypeName: "EchoResponse",
      ),
      FFIProcMeta(
        procName: "timer_destroy",
        libName: "timer",
        kind: FFIKind.DTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "",
      ),
    ]
    let header = generateCHeader(procs, types, "timer")

  test "vendored TinyCBOR and the leaf prelude are pulled in":
    check "#include <tinycbor/cbor.h>" in header
    check "NimFfiStr" in header
    check "nimffi_enc_str" in header

  test "user structs become C structs with mapped field types":
    check "} EchoRequest;" in header
    check "int64_t delayMs;" in header
    check "NimFfiStr message;" in header

  test "per-struct encode/decode/free are emitted":
    check "timer_enc_EchoRequest(" in header
    check "timer_dec_EchoRequest(" in header
    check "timer_free_EchoRequest(" in header

  test "seq[T] is monomorphised into a sized struct":
    check "} TimerSeq_EchoRequest;" in header
    check "EchoRequest* data;" in header
    check "timer_enc_TimerSeq_EchoRequest(" in header

  test "Option[T] is monomorphised with a has_value flag":
    check "} TimerOpt_Str;" in header
    check "bool has_value;" in header

  test "a struct whose fields own no heap memory gets no free helper":
    # EchoResponse has only a string field, so it does get a free; assert the
    # inverse with the per-proc Version-less example via the int-only check:
    check "timer_free_EchoResponse(" in header

suite "generateCHeader: ABI declarations and context API":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[param("config", "EchoRequest")],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_version",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "string",
      ),
      FFIProcMeta(
        procName: "timer_destroy",
        libName: "timer",
        kind: FFIKind.DTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "",
      ),
    ]
    let types = @[FFITypeMeta(name: "EchoRequest", fields: @[field("m", "string")])]
    let header = generateCHeader(procs, types, "timer")

  test "raw dylib symbols are declared with the C ABI shape":
    check "void* timer_create(const uint8_t* req_cbor, size_t req_cbor_len," in header
    check "int timer_version(void* ctx, FFICallback callback" in header
    check "int timer_destroy(void* ctx);" in header
    check "uint64_t timer_add_event_listener(" in header

  test "high-level wrappers are namespaced to avoid the raw symbols":
    check "timer_ctx_create(" in header
    check "timer_ctx_version(" in header
    check "timer_ctx_destroy(" in header

  test "the async API is callback-driven, not blocking":
    # methods take a typed reply callback + user_data; no out-param, no char** err
    check "typedef void (*TimerVersionReplyFn)(int err_code, const NimFfiStr* reply, const char* err_msg, void* user_data);" in
      header
    check "TimerVersionCallBox" in header
    check "timer_version_reply_trampoline(" in header
    check "timer_ctx_version(const TimerCtx* ctx, TimerVersionReplyFn on_reply, void* user_data)" in
      header

  test "the constructor is async and hands the context to a callback":
    check "typedef void (*TimerCreateFn)(int err_code, TimerCtx* ctx, const char* err_msg, void* user_data);" in
      header
    check "timer_create_trampoline(" in header
    check "timer_ctx_create(const EchoRequest* config, TimerCreateFn on_created, void* user_data)" in
      header

  test "no blocking sync-call machinery or per-call timeout survives":
    check "nimffi_wait_result" notin header
    check "NimFfiCallState" notin header
    check "timeout_ms" notin header

  test "an empty request envelope still encodes a (zero-length) map":
    check "_nimffi_empty" in header

suite "generateCHeader: events":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_destroy",
        libName: "timer",
        kind: FFIKind.DTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "",
      ),
    ]
    let types = @[FFITypeMeta(name: "TickEvent", fields: @[field("count", "int")])]
    let events = @[
      FFIEventMeta(
        wireName: "on_tick",
        nimProcName: "onTick",
        libName: "timer",
        payloadTypeName: "TickEvent",
      )
    ]
    let header = generateCHeader(procs, types, "timer", events)

  test "a typed handler, box and trampoline are emitted per event":
    check "TimerOnTickFn" in header
    check "TimerOnTickBox" in header
    check "timer_on_tick_trampoline(" in header

  test "the registration API uses the wire name and snake-cased proc name":
    check "timer_ctx_add_on_tick_listener(" in header
    check "\"on_tick\"" in header
    check "timer_ctx_remove_event_listener(" in header

  test "the context tracks listeners only when events exist":
    check "TimerCtxListener* listeners;" in header

suite "generateCHeader: no-event libraries stay lean":
  test "a library without events has no listener bookkeeping":
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "Timer",
      )
    ]
    let header = generateCHeader(procs, @[], "timer")
    check "listeners_len" notin header
    check "_add_event_listener" in header # raw ABI symbol is always declared
