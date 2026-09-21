## Unit-tests for the C binding generator: drives generateCLibHeader (and the
## shared-header generators) against a synthetic registry and asserts on the text.

import std/strutils
import unittest2
import ffi/ffi_msg
import ffi/codegen/[meta, c]

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
    check "nimffi_enc_str" in header

  test "user structs become C structs with mapped field types":
    check "} EchoRequest;" in header
    check "int64_t delayMs;" in header
    check "const char* message;" in header

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
    check "int timer_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);" in
      header
    check "intptr_t timer_poll_fd(void* ctx);" in header

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
    check "typedef void (*TimerVersionReplyFn)(int err_code, const char* const* reply, const char* err_msg, void* user_data);" in
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
    # Only poll and the dispatch thread take a timeout; no request does.
    check "timer_ctx_version(const TimerCtx* ctx, TimerVersionReplyFn on_reply, void* user_data) {" in
      header

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
    let types = @[
      FFITypeMeta(name: "TickEvent", fields: @[field("count", "int")]),
      FFITypeMeta(name: "JobDone", fields: @[field("jobId", "string")]),
    ]
    let events = @[
      FFIEventMeta(
        wireName: "on_tick",
        nimProcName: "onTick",
        libName: "timer",
        payloadTypeName: "TickEvent",
        doc: "Fires once a second.",
      ),
      FFIEventMeta(
        wireName: "job_done",
        nimProcName: "onJobDone",
        libName: "timer",
        payloadTypeName: "JobDone",
      ),
    ]
    let header = generateCLibHeader(procs, types, "timer", events)

  test "every event gets its name id constant, from the wire name":
    check "#define TIMER_EVT_ON_TICK " & nameIdLiteral("on_tick") &
      "ULL  /* \"on_tick\" */" in header
    check "#define TIMER_EVT_ON_JOB_DONE " & nameIdLiteral("job_done") & "ULL" in header

  test "every event gets a decoder of the bare payload":
    check "static inline int timer_decode_on_tick(const NimFfiMsg* msg, TickEvent* out) {" in
      header
    check "static inline int timer_decode_on_job_done(const NimFfiMsg* msg, JobDone* out) {" in
      header
    check "cbor_parser_init(msg->payload, msg->len, 0, &parser, &it)" in header
    # The v0.3 `{eventType, payload}` envelope is gone.
    check "\"payload\"" notin header
    check "\"eventType\"" notin header

  test "a decoder says who frees, and reclaims a partial decode itself":
    check "On success the caller frees `out` with timer_free_JobDone()." in header
    check "        timer_free_JobDone(out);\n        return -1;" in header
    # TickEvent is all scalars: nothing to free, and no free helper to name.
    check "timer_free_TickEvent" notin header

  test "Handlers lists every event, with its doc, then liveness and closed":
    check(
      """
typedef struct {
    /** Fires once a second. */
    void (*on_tick)(const TickEvent* ev, void* user_data);
    void (*on_job_done)(const JobDone* ev, void* user_data);""" in
        header
    )
    check "    void (*not_responding)(uint64_t reason, void* user_data);" in header
    check "    void (*responding)(void* user_data);" in header
    check "    void (*closed)(int ret, const char* reason, void* user_data);" in header
    check "    void* user_data;\n} TimerHandlers;" in header

  test "dispatch decodes, then calls the handler, then frees":
    check "static inline int timer_ctx_dispatch(TimerCtx* ctx, const NimFfiMsg* msg, const TimerHandlers* handlers) {" in
      header
    check(
      """
        if (msg->name_id == TIMER_EVT_ON_JOB_DONE) {
            JobDone ev;
            if (timer_decode_on_job_done(msg, &ev) != 0) return -1;
            if (handlers && handlers->on_job_done) handlers->on_job_done(&ev, handlers->user_data);
            timer_free_JobDone(&ev);
            return 0;
        }""" in
        header
    )
    check "case NIMFFI_MSG_NOT_RESPONDING:" in header
    check "case NIMFFI_MSG_RESPONDING:" in header
    check "case NIMFFI_MSG_CLOSED:" in header

  test "the dispatch loop and the wake handle are emitted":
    check "static inline int timer_ctx_dispatch_next(TimerCtx* ctx, int32_t timeout_ms, const TimerHandlers* handlers) {" in
      header
    check "int rc = timer_poll(ctx->ptr, timeout_ms, &msg);" in header
    check "static inline intptr_t timer_ctx_poll_fd(const TimerCtx* ctx) {" in header

  test "the API index names the requests and every message":
    check "/* timer API" in header
    check " *   on_tick(const TickEvent*)  TIMER_EVT_ON_TICK" in header
    check " *   not_responding, responding, closed" in header

  test "the listener registry is gone":
    for gone in [
      "_add_event_listener", "_remove_event_listener", "_listener(", "TimerCtxListener",
      "listeners_len", "TimerOnTickFn", "TimerOnTickBox", "timer_on_tick_trampoline",
    ]:
      check gone notin header

  test "the context destructor frees nothing but the context":
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

suite "generateCLibHeader: a library without events":
  test "it still gets Handlers, dispatch, the dispatch loop and the wake handle":
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
    check "} TimerHandlers;" in header
    check "    void (*closed)(int ret, const char* reason, void* user_data);" in header
    check "timer_ctx_dispatch(" in header
    check "timer_ctx_dispatch_next(" in header
    check "timer_ctx_poll_fd(" in header
    check "int timer_poll(void* ctx" in header
    check "_EVT_" notin header
    check "_add_event_listener" notin header

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

suite "shared headers: prelude and cbor split":
  test "the prelude owns the leaf types and libc/TinyCBOR includes":
    let prelude = generateCPreludeHeader()
    check "#include <tinycbor/cbor.h>" in prelude
    check "} NimFfiBytes;" in prelude
    check "nimffi_free_bytes" in prelude
    # Strings are a bare `const char*`: no leaf type and no free helper.
    check "NimFfiStr" notin prelude

  test "the prelude declares the poll message once, from ffi_msg":
    let prelude = generateCPreludeHeader()
    check cMsgDecl() in prelude
    check prelude.count("} NimFfiMsg;") == 1
    check "#define NIMFFI_MSG_EVENT 2" in prelude
    check "{{MSG_DECL}}" notin prelude
    check "NimFfiMsg;" notin generateCLibHeader(@[], @[], "timer")

  test "the cbor header carries the leaf codecs and pulls in the prelude":
    let cbor = generateCCborHeader()
    check "#include \"nim_ffi_prelude.h\"" in cbor
    check "nimffi_enc_str" in cbor
    check "nimffi_decode_from_buf" in cbor

  test "each generated file is independently include-guarded":
    check "NIM_FFI_PRELUDE_H_INCLUDED" in generateCPreludeHeader()
    check "NIM_FFI_CBOR_HELPERS_H_INCLUDED" in generateCCborHeader()
    check "NIM_FFI_LIB_TIMER_H_INCLUDED" in generateCLibHeader(@[], @[], "timer")
