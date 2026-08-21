## Unit-tests for the C binding generator: drives generateCLibHeader (and the
## shared-header generators) against a synthetic registry and asserts on the text.

import std/[strutils, sequtils]
import unittest2
import ffi/codegen/[meta, c]
import ffi/internal/ffi_scalar

proc field(n, t: string): FFIFieldMeta =
  FFIFieldMeta(name: n, typeName: t)

proc param(n, t: string, isPtr = false): FFIParamMeta =
  FFIParamMeta(name: n, typeName: t, isPtr: isPtr)

suite "generateCLibHeader: types and codecs":
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
    let header = generateCLibHeader(procs, types, "timer")

  test "the lib header pulls in the shared cbor header and uses its codecs":
    check "#include \"nim_ffi_cbor.h\"" in header
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
    # EchoResponse has a string field, so it gets a free helper.
    check "timer_free_EchoResponse(" in header

suite "generateCLibHeader: ABI declarations and context API":
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
    let header = generateCLibHeader(procs, types, "timer")

  test "raw dylib symbols are declared with the C ABI shape":
    check "void* timer_create(const uint8_t* req_cbor, size_t req_cbor_len," in header
    check "int timer_version(void* ctx, FFICallback callback" in header
    check "int timer_destroy(void* ctx);" in header
    check "uint64_t timer_add_event_listener(" in header

  test "high-level wrappers are namespaced to avoid the raw symbols":
    check "timer_ctx_create(" in header
    check "timer_ctx_version(" in header
    check "timer_ctx_destroy(" in header

  test "the context destructor propagates the destructor's status code":
    check(
      """
static inline int timer_ctx_destroy(TimerCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    if (ctx->ptr) { rc = timer_destroy(ctx->ptr); ctx->ptr = NULL; }
    free(ctx);
    return rc;
}""" in
        header
    )

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

suite "generateCLibHeader: context-independent procs":
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
        procName: "timer_parse",
        libName: "timer",
        kind: FFIKind.STATIC,
        libTypeName: "Timer",
        extraParams: @[param("req", "EchoRequest")],
        returnTypeName: "EchoResponse",
      ),
    ]
    let types = @[
      FFITypeMeta(name: "EchoRequest", fields: @[field("m", "string")]),
      FFITypeMeta(name: "EchoResponse", fields: @[field("echoed", "string")]),
    ]
    let header = generateCLibHeader(procs, types, "timer")

  test "the static's raw symbol takes no ctx":
    check "int timer_parse(FFICallback callback, void* user_data, " &
      "const uint8_t* req_cbor, size_t req_cbor_len);" in header

  test "its wrapper is _static_-namespaced and takes neither ctx nor timeout":
    check "timer_static_parse(const EchoRequest* req, TimerParseReplyFn on_reply, void* user_data)" in
      header
    check "timer_ctx_parse(" notin header

  test "the wrapper calls the raw symbol without a ctx argument":
    check "timer_parse(timer_parse_reply_trampoline, box, req_buf, req_len);" in header

  test "a static gets the same reply machinery as a method":
    check "typedef void (*TimerParseReplyFn)(int err_code, const EchoResponse* reply, " &
      "const char* err_msg, void* user_data);" in header
    check "TimerParseCallBox" in header
    check "timer_parse_reply_trampoline(" in header

  test "its return type is monomorphised into the codecs":
    check "timer_decv_EchoResponse" in header

  test "methods keep their ctx":
    check "int timer_version(void* ctx, FFICallback callback" in header
    check "timer_ctx_version(const TimerCtx* ctx," in header

suite "generateCLibHeader: events":
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
    let header = generateCLibHeader(procs, types, "timer", events)

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

  test "a failed teardown leaks the listener boxes instead of dangling them":
    # A non-OK rc leaves the worker threads live, still holding each box as
    # callback user_data, so the sweep must sit behind the rc guard.
    check(
      """
static inline int timer_ctx_destroy(TimerCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    if (ctx->ptr) { rc = timer_destroy(ctx->ptr); ctx->ptr = NULL; }
    if (rc == NIMFFI_RET_OK) {
        for (size_t i = 0; i < ctx->listeners_len; i++) free(ctx->listeners[i].box);
    }
    free(ctx->listeners);
    free(ctx);
    return rc;
}""" in
        header
    )

suite "generateCLibHeader: no-event libraries stay lean":
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
    let header = generateCLibHeader(procs, @[], "timer")
    check "listeners_len" notin header
    check "_add_event_listener" in header # raw ABI symbol is always declared

  test "a library without a dtor still reports success from ctx_destroy":
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
    let header = generateCLibHeader(procs, @[], "timer")
    check(
      """
static inline int timer_ctx_destroy(TimerCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    free(ctx);
    return rc;
}""" in
        header
    )

suite "generateCLibHeader: scalar-fast-path procs are excluded":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "calc_create",
        libName: "calc",
        kind: FFIKind.CTOR,
        libTypeName: "Calc",
        returnTypeName: "Calc",
      ),
      FFIProcMeta(
        procName: "calc_echo",
        libName: "calc",
        kind: FFIKind.FFI,
        libTypeName: "Calc",
        extraParams: @[param("req", "EchoRequest")],
        returnTypeName: "EchoResponse",
      ),
      FFIProcMeta(
        procName: "calc_add",
        libName: "calc",
        kind: FFIKind.FFI,
        libTypeName: "Calc",
        extraParams: @[param("a", "int"), param("b", "int")],
        returnTypeName: "int",
        abiFormat: ABIFormat.C,
        scalarFastPath: true,
      ),
    ]
    let types = @[
      FFITypeMeta(name: "EchoRequest", fields: @[field("m", "string")]),
      FFITypeMeta(name: "EchoResponse", fields: @[field("echoed", "string")]),
    ]

  test "bindableProcs keeps the CBOR procs and drops the scalar one":
    let kept = bindableProcs(procs)
    check kept.anyIt(it.procName == "calc_create")
    check kept.anyIt(it.procName == "calc_echo")
    check not kept.anyIt(it.procName == "calc_add")

  test "the C header emitted from the bindable set carries no scalar symbol":
    let header = generateCLibHeader(bindableProcs(procs), types, "calc")
    check "int calc_echo(void* ctx, FFICallback callback" in header
    check "int calc_add(" notin header # note: calc_add_event_listener is unrelated

  test "unfiltered, the generator would emit a wrong-ABI CBOR caller for it":
    # Unfiltered, the generator emits a wrong-ABI CBOR prototype for the scalar proc.
    let header = generateCLibHeader(procs, types, "calc")
    check "int calc_add(void* ctx, FFICallback callback, void* user_data, " &
      "const uint8_t* req_cbor, size_t req_cbor_len);" in header

suite "generateCAbiLibHeader: self-contained header":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "widget_create",
        libName: "widget",
        kind: FFIKind.CTOR,
        libTypeName: "Widget",
        extraParams: @[param("config", "Cfg")],
        returnTypeName: "Widget",
      ),
      FFIProcMeta(
        procName: "widget_poke",
        libName: "widget",
        kind: FFIKind.FFI,
        libTypeName: "Widget",
        extraParams: @[param("req", "Cfg")],
        returnTypeName: "Cfg",
      ),
      FFIProcMeta(
        procName: "widget_destroy",
        libName: "widget",
        kind: FFIKind.DTOR,
        libTypeName: "Widget",
        returnTypeName: "",
      ),
    ]
    let types = @[FFITypeMeta(name: "Cfg", fields: @[field("tag", "string")])]
    let header = generateCAbiLibHeader(procs, types, "widget")

  test "the header is self-contained: libc includes and NIMFFI_RET_* codes":
    check "#include <stdint.h>" in header
    check "#include <stddef.h>" in header
    check "#define NIMFFI_RET_OK 0" in header
    check "#define NIMFFI_RET_STALE_WARN 3" in header

  test "short RET_* aliases are emitted, each #ifndef-guarded":
    check "#ifndef RET_OK\n#define RET_OK NIMFFI_RET_OK\n#endif" in header
    check "#ifndef RET_ERR\n#define RET_ERR NIMFFI_RET_ERR\n#endif" in header
    check "#define RET_MISSING_CALLBACK NIMFFI_RET_MISSING_CALLBACK" in header
    check "#define RET_STALE_WARN NIMFFI_RET_STALE_WARN" in header

  test "the event-listener ABI and FFICallback are declared":
    check "typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);" in
      header
    check "uint64_t widget_add_event_listener(void* ctx, const char* event_name, " &
      "FFICallback callback, void* user_data);" in header
    check "int widget_remove_event_listener(void* ctx, uint64_t listener_id);" in header

  test "the callback typedef matches the CBOR header's spelling, not the Nim symbol":
    check "FFICallBack" notin header # the Nim symbol; the C header uses FFICallback

  test "the FFICallback typedef is include-guarded against co-inclusion":
    check "#ifndef NIMFFI_FFICALLBACK_DEFINED" in header

  test "no banner is emitted when none is requested":
    check not header.startsWith("//")

  test "a header banner is stamped above the include guard as // lines":
    let banner = "GENERATED FILE — do not edit.\nRegenerate with nimble genbindings."
    let withBanner = generateCAbiLibHeader(procs, types, "widget", banner = banner)
    check withBanner.startsWith(
      "// GENERATED FILE — do not edit.\n// Regenerate with nimble genbindings.\n#ifndef "
    )

  test "a banner line ending in a backslash cannot splice the include guard away":
    let withBanner =
      generateCAbiLibHeader(procs, types, "widget", banner = "edit me and lose\\")
    check "// edit me and lose\n#ifndef " in withBanner

suite "generateCLibHeader: header banner":
  test "the CBOR lib header also stamps the banner above its include guard":
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        returnTypeName: "Timer",
      )
    ]
    let header = generateCLibHeader(procs, @[], "timer", banner = "do not edit")
    check header.startsWith("// do not edit\n#ifndef ")

suite "shared headers: prelude and cbor split":
  test "the prelude owns the leaf types and libc/TinyCBOR includes":
    let prelude = generateCPreludeHeader()
    check "#include <tinycbor/cbor.h>" in prelude
    check "} NimFfiStr;" in prelude
    check "nimffi_free_str" in prelude

  test "the cbor header carries the leaf codecs and pulls in the prelude":
    let cbor = generateCCborHeader()
    check "#include \"nim_ffi_prelude.h\"" in cbor
    check "nimffi_enc_str" in cbor
    check "nimffi_decode_from_buf" in cbor

  test "each generated file is independently include-guarded":
    check "NIM_FFI_PRELUDE_H_INCLUDED" in generateCPreludeHeader()
    check "NIM_FFI_CBOR_HELPERS_H_INCLUDED" in generateCCborHeader()
    check "NIM_FFI_LIB_TIMER_H_INCLUDED" in generateCLibHeader(@[], @[], "timer")

suite "generateCLibHeader: reverse FFI":
  setup:
    let types = @[
      FFITypeMeta(
        name: "RevConfig", fields: @[field("name", "string"), field("attempt", "int")]
      ),
      FFITypeMeta(
        name: "FetchConfigArgs",
        fields: @[field("key", "string"), field("attempt", "int")],
      ),
      FFITypeMeta(name: "OnHostPingReq", fields: @[field("seqNo", "int")]),
    ]
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
    let reverse = @[
      FFIReverseMeta(
        wireName: "fetch_config",
        nimProcName: "fetchConfig",
        libName: "timer",
        argsTypeName: "FetchConfigArgs",
        replyTypeName: "RevConfig",
      ),
      FFIReverseMeta(
        wireName: "host_note",
        nimProcName: "notifyHost",
        libName: "timer",
        argsTypeName: "string",
        replyTypeName: "",
        timeoutMs: 300,
      ),
    ]
    let reverseEvents = @[
      FFIReverseEventMeta(
        wireName: "on_host_ping",
        nimProcName: "onHostPing",
        libName: "timer",
        reqTypeName: "OnHostPingReq",
      )
    ]
    let header =
      generateCLibHeader(procs, types, "timer", @[], @[], "", reverse, reverseEvents)

  test "raw reverse exports are declared with the impl typedef":
    check "typedef void (*FFIReverseImpl)(uint64_t call_id, const uint8_t* args_cbor, size_t args_len, void* user_data);" in
      header
    check "int timer_set_fetch_config_impl(void* ctx, FFIReverseImpl impl, void* user_data);" in
      header
    check "int timer_set_host_note_impl(void* ctx, FFIReverseImpl impl, void* user_data);" in
      header
    check "int timer_reverse_reply(void* ctx, uint64_t call_id, int ret_code, const uint8_t* reply_cbor, size_t reply_len);" in
      header
    check "int timer_emit_on_host_ping(void* ctx, const uint8_t* payload_cbor, size_t payload_len);" in
      header

  test "typed helpers ride the ctx wrapper":
    check "static inline int timer_ctx_set_fetch_config_impl(const TimerCtx* ctx, FFIReverseImpl impl, void* user_data)" in
      header
    check "static inline int timer_decode_fetch_config_args(const uint8_t* args_cbor, size_t args_len, FetchConfigArgs* out, char** err)" in
      header
    check "static inline int timer_ctx_reverse_reply_fetch_config(const TimerCtx* ctx, uint64_t call_id, const RevConfig* reply)" in
      header
    check "static inline int timer_ctx_reverse_reply_err(const TimerCtx* ctx, uint64_t call_id, const char* msg)" in
      header

  test "a void reply gets the payload-less reply helper":
    check "static inline int timer_ctx_reverse_reply_host_note(const TimerCtx* ctx, uint64_t call_id)" in
      header

  test "a string-args reverse proc decodes into NimFfiStr":
    check "static inline int timer_decode_host_note_args(const uint8_t* args_cbor, size_t args_len, NimFfiStr* out, char** err)" in
      header

  test "reverse events get the typed emit helper":
    check "static inline int timer_ctx_emit_on_host_ping(const TimerCtx* ctx, const OnHostPingReq* payload)" in
      header

  test "buffer adapters cover the reverse-direction types":
    check "timer_encv_RevConfig" in header
    check "timer_encv_OnHostPingReq" in header
    check "timer_decv_FetchConfigArgs" in header

  test "a header with no reverse procs stays reverse-free":
    let plain = generateCLibHeader(procs, types, "timer")
    check "FFIReverseImpl" notin plain
    check "reverse_reply" notin plain
