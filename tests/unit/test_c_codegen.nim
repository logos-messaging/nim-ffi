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
    check "int timer_create(const uint8_t* req_cbor, size_t req_cbor_len, void** ctx_out, uint64_t* req_id_out);" in
      header
    check "int timer_version(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);" in
      header
    check "int timer_destroy(void* ctx);" in header
    check "void* timer_static_ctx(void);" in header
    check "const char* timer_last_error(void);" in header
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
    nimffi_pending_close(&ctx->pending);
    /* A callback above may have made room for a request that was refused. */
    free(ctx->pending.items);
    free(ctx);
    return rc;
}""" in
        header
    )

  test "the library calls nothing back: no callback type, no retired code":
    for gone in [
      "FFICallback", "MISSING_CALLBACK", "NIMFFI_RET_STALE_WARN", "CallBox",
      "_trampoline", "nimffi_wait_result", "NimFfiCallState",
    ]:
      check gone notin header
      check gone notin generateCCborHeader()
      check gone notin generateCPreludeHeader()

  test "the context carries the table of the requests waiting for a reply":
    check(
      """
typedef struct {
    void* ptr;             /* the library's token, for the raw exports */
    NimFfiPending pending; /* requests waiting for their reply */
} TimerCtx;""" in
        header
    )

  test "a request has an asynchronous form whose reply comes through the dispatch loop":
    check "typedef void (*TimerVersionReplyFn)(int ret, const char* const* reply, const char* err, void* user_data);" in
      header
    check "static inline int timer_ctx_version(TimerCtx* ctx, TimerVersionReplyFn on_reply, void* user_data, uint64_t* req_id_out) {" in
      header
    check "const int rc_ = timer_version_submit_(ctx, timer_version_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);" in
      header

  test "a request has a _sync form that dispatches until its own reply":
    check "static inline int timer_ctx_version_sync(TimerCtx* ctx, const char** out, char** err, int32_t timeout_ms, const TimerHandlers* handlers) {" in
      header
    check "return timer_ctx_await_(ctx, req_id, &slot, timeout_ms, handlers);" in header
    # Giving up forgets the request, so a late reply is dropped, not settled.
    check "nimffi_pending_abandon(&ctx->pending, req_id);" in header

  test "a request has a typed decoder of its raw reply":
    check "static inline int timer_decode_version_reply(const NimFfiMsg* msg, const char** out, char** err) {" in
      header
    check "int rc = nimffi_decode_reply(msg, timer_decv_Str, out, err);" in header
    check " * On success the caller frees `*out` with free(). */" in header
    # Reclaims what a partial decode allocated.
    check "if (rc == -1 && out) do { free((void*)*out); *out = NULL; } while (0);" in
      header

  test "room is made before the submit, the waiter is recorded after it":
    let body = header[header.find("timer_version_submit_(TimerCtx* ctx") .. ^1]
    let reserve = body.find("nimffi_pending_reserve(&ctx->pending)")
    let submit =
      body.find("int rc = timer_version(ctx->ptr, req_buf, req_len, req_id_out);")
    let refused = body.find("*err = nimffi_dup_cstr(timer_last_error());")
    let record = body.find("nimffi_pending_add(&ctx->pending, entry);")
    check reserve >= 0
    check reserve < submit
    check submit < refused
    check refused < record

  test "a NULL ctx is refused, not dereferenced":
    check "        return NIMFFI_RET_INVALID_CTX;\n    }\n    TimerVersionReq ffi_req;" in
      header

  test "the constructor hands the context out at once, in both forms":
    check "typedef void (*TimerCreateFn)(int ret, const char* err, void* user_data);" in
      header
    check "static inline int timer_ctx_create(const EchoRequest* config, TimerCtx** ctx_out, TimerCreateFn on_created, void* user_data) {" in
      header
    check "static inline int timer_ctx_create_sync(const EchoRequest* config, TimerCtx** out, char** err, int32_t timeout_ms) {" in
      header
    check "int rc = timer_create(req_buf, req_len, &ctx->ptr, req_id_out);" in header
    # The old reply was the context's address as text.
    check "strtoull" notin header

  test "a failed or abandoned construction destroys the claimed slot":
    check(
      """
    rc = timer_ctx_await_(ctx, req_id, &slot, timeout_ms, NULL);
    if (rc != NIMFFI_RET_OK) {
        /* The slot is claimed even when construction failed. */
        (void)timer_ctx_destroy(ctx);
        return rc;
    }""" in
        header
    )

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
    check "int timer_parse(const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);" in
      header

  test "its wrappers are _static_-namespaced and take no ctx":
    check "static inline int timer_static_parse(const EchoRequest* req, TimerParseReplyFn on_reply, void* user_data, uint64_t* req_id_out) {" in
      header
    check "static inline int timer_static_parse_sync(const EchoRequest* req, EchoResponse* out, char** err, int32_t timeout_ms, const TimerHandlers* handlers) {" in
      header
    check "timer_ctx_parse(" notin header

  test "the wrapper calls the raw symbol without a ctx argument":
    check "int rc = timer_parse(req_buf, req_len, req_id_out);" in header

  test "its reply arrives on the static context, which has a dispatch thread of its own":
    check "NIMFFI_SHARED TimerCtx timer_static_binding_ = {NULL, {NULL, 0, 0}};" in
      header
    check "timer_static_binding_.ptr = timer_static_ctx();" in header
    check "static inline int timer_static_dispatch_next(int32_t timeout_ms, const TimerHandlers* handlers) {" in
      header
    check "    TimerCtx* ctx = timer_static_();" in header
    check "return timer_ctx_await_(timer_static_(), req_id, &slot, timeout_ms, handlers);" in
      header

  test "a static gets the same reply machinery as a method":
    check "typedef void (*TimerParseReplyFn)(int ret, const EchoResponse* reply, " &
      "const char* err, void* user_data);" in header
    check "static inline int timer_decode_parse_reply(const NimFfiMsg* msg, EchoResponse* out, char** err) {" in
      header
    check "if (rc == -1 && out) timer_free_EchoResponse(out);" in header
    check " * On success the caller frees `out` with timer_free_EchoResponse(). */" in
      header

  test "every request is listed with its three entry points":
    check " *   timer_ctx_version()  timer_ctx_version_sync()  timer_decode_version_reply()" in
      header
    check " *   timer_static_parse()  timer_static_parse_sync()  timer_decode_parse_reply()" in
      header
    check " * Context: timer_ctx_create_sync(), timer_ctx_create(), timer_ctx_destroy()." in
      header
    check "single-threaded by design" in header

  test "its return type is monomorphised into the codecs":
    check "timer_decv_EchoResponse" in header

  test "methods keep their ctx":
    check "int timer_version(void* ctx, const uint8_t* req_cbor" in header
    check "timer_ctx_version(TimerCtx* ctx," in header

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

  test "Handlers lists every event, with its doc, then stale_warn, liveness and closed":
    check(
      """
typedef struct {
    /** Fires once a second. */
    void (*on_tick)(const TickEvent* ev, void* user_data);
    void (*on_job_done)(const JobDone* ev, void* user_data);""" in
        header
    )
    check "    void (*stale_warn)(uint64_t req_id, uint64_t elapsed_ms, void* user_data);" in
      header
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

  test "dispatch settles a reply from the table, and ignores one nobody waits for":
    check(
      """
    case NIMFFI_MSG_REPLY: {
        NimFfiPendingEntry entry;
        /* Nobody waits: given up on by a _sync timeout, or sent through the raw export. */
        if (!nimffi_pending_take(&ctx->pending, msg->id, &entry)) return 0;
        entry.settle(msg, entry.on_reply, entry.user_data);
        return 0;
    }
    case NIMFFI_MSG_STALE_WARN:
        if (handlers && handlers->stale_warn) handlers->stale_warn(msg->id, msg->aux, handlers->user_data);
        return 0;""" in
        header
    )

  test "CLOSED fails every waiting request before the closed handler runs":
    let closing = header.find("nimffi_pending_close(&ctx->pending);")
    let handler = header.find("handlers->closed(ret, reason, handlers->user_data);")
    check closing >= 0
    check closing < handler

  test "the dispatch loop and the wake handle are emitted":
    check "static inline int timer_ctx_dispatch_next(TimerCtx* ctx, int32_t timeout_ms, const TimerHandlers* handlers) {" in
      header
    check "int rc = timer_poll(ctx->ptr, timeout_ms, &msg);" in header
    check "static inline intptr_t timer_ctx_poll_fd(const TimerCtx* ctx) {" in header

  test "the API index names the requests and every message":
    check "/* timer API" in header
    check " *   on_tick(const TickEvent*)  TIMER_EVT_ON_TICK" in header
    check " *   stale_warn, not_responding, responding, closed" in header

  test "the listener registry is gone":
    for gone in [
      "_add_event_listener", "_remove_event_listener", "_listener(", "TimerCtxListener",
      "listeners_len", "TimerOnTickFn", "TimerOnTickBox", "timer_on_tick_trampoline",
    ]:
      check gone notin header

  test "the context destructor settles what still waits after the library let go":
    check(
      """
    if (ctx->ptr) { rc = timer_destroy(ctx->ptr); ctx->ptr = NULL; }
    nimffi_pending_close(&ctx->pending);""" in
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
    # No statics: no static context either.
    check "_static_" notin header.replace("timer_static_ctx(void)", "")

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
    nimffi_pending_close(&ctx->pending);
    /* A callback above may have made room for a request that was refused. */
    free(ctx->pending.items);
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

  test "the cbor header carries the reply reader and the table of waiting requests":
    let cbor = generateCCborHeader()
    check "static inline int nimffi_reply_status(const NimFfiMsg* msg, char** err) {" in
      cbor
    check "} NimFfiPending;" in cbor
    check "} NimFfiSyncSlot;" in cbor
    for fn in [
      "nimffi_pending_reserve", "nimffi_pending_add", "nimffi_pending_take",
      "nimffi_pending_abandon", "nimffi_pending_close", "nimffi_now_ms",
    ]:
      check fn & "(" in cbor
    check "#define NIMFFI_RET_QUEUE_FULL 8" in cbor
    check "{{RET_CODES}}" notin cbor

  test "the prose no longer promises a callback from the library":
    let prelude = generateCPreludeHeader()
    check "The library never calls into the host" in prelude
    check "single-threaded by design" in prelude
    check "Nim dispatch thread" notin prelude

  test "each generated file is independently include-guarded":
    check "NIM_FFI_PRELUDE_H_INCLUDED" in generateCPreludeHeader()
    check "NIM_FFI_CBOR_HELPERS_H_INCLUDED" in generateCCborHeader()
    check "NIM_FFI_LIB_TIMER_H_INCLUDED" in generateCLibHeader(@[], @[], "timer")
