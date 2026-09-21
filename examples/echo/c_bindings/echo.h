#ifndef NIM_FFI_LIB_ECHO_H_INCLUDED
#define NIM_FFI_LIB_ECHO_H_INCLUDED
#include "nim_ffi_cbor.h"

/* ============================================================ */
/* Generated constants                                          */
/* ============================================================ */

static const int64_t MAX_SHOUT_LEN = 512;

/* ============================================================ */
/* Generated types (user-declared + per-proc request envelopes) */
/* ============================================================ */

typedef struct {
    const char* prefix;
} EchoConfig;
typedef struct {
    const char* text;
} ShoutRequest;
typedef struct {
    const char* shouted;
    const char* prefix;
} ShoutResponse;
typedef struct {
    EchoConfig config;
} EchoCreateCtorReq;
typedef struct {
    ShoutRequest req;
} EchoShoutReq;
typedef struct {
    char _nimffi_empty; /* C forbids empty structs */
} EchoVersionReq;
typedef struct {
    char _nimffi_empty; /* C forbids empty structs */
} EchoLibVersionReq;
typedef struct {
    ShoutRequest req;
} EchoShoutAnonReq;

static inline CborError echo_enc_EchoConfig(
        CborEncoder* e, const EchoConfig* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "prefix");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->prefix);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoConfig(
        CborValue* it, EchoConfig* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "prefix", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->prefix);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_EchoConfig(EchoConfig* v) {
    if (!v) return;
    do { free((void*)v->prefix); v->prefix = NULL; } while (0);
}
static inline CborError echo_enc_ShoutRequest(
        CborEncoder* e, const ShoutRequest* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "text");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->text);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_ShoutRequest(
        CborValue* it, ShoutRequest* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "text", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->text);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_ShoutRequest(ShoutRequest* v) {
    if (!v) return;
    do { free((void*)v->text); v->text = NULL; } while (0);
}
static inline CborError echo_enc_ShoutResponse(
        CborEncoder* e, const ShoutResponse* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "shouted");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->shouted);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "prefix");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->prefix);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_ShoutResponse(
        CborValue* it, ShoutResponse* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "shouted", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->shouted);
    if (err) return err;
    err = cbor_value_map_find_value(it, "prefix", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->prefix);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_ShoutResponse(ShoutResponse* v) {
    if (!v) return;
    do { free((void*)v->shouted); v->shouted = NULL; } while (0);
    do { free((void*)v->prefix); v->prefix = NULL; } while (0);
}
static inline CborError echo_enc_EchoCreateCtorReq(
        CborEncoder* e, const EchoCreateCtorReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "config");
    if (err) return err;
    err = echo_enc_EchoConfig(&m, &v->config);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoCreateCtorReq(
        CborValue* it, EchoCreateCtorReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "config", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = echo_dec_EchoConfig(&field, &out->config);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_EchoCreateCtorReq(EchoCreateCtorReq* v) {
    if (!v) return;
    echo_free_EchoConfig(&v->config);
}
static inline CborError echo_enc_EchoShoutReq(
        CborEncoder* e, const EchoShoutReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req");
    if (err) return err;
    err = echo_enc_ShoutRequest(&m, &v->req);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoShoutReq(
        CborValue* it, EchoShoutReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "req", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = echo_dec_ShoutRequest(&field, &out->req);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_EchoShoutReq(EchoShoutReq* v) {
    if (!v) return;
    echo_free_ShoutRequest(&v->req);
}
static inline CborError echo_enc_EchoVersionReq(
        CborEncoder* e, const EchoVersionReq* v) {
    (void)v;
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoVersionReq(
        CborValue* it, EchoVersionReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    (void)out;
    return cbor_value_advance(it);
}
static inline CborError echo_enc_EchoLibVersionReq(
        CborEncoder* e, const EchoLibVersionReq* v) {
    (void)v;
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoLibVersionReq(
        CborValue* it, EchoLibVersionReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    (void)out;
    return cbor_value_advance(it);
}
static inline CborError echo_enc_EchoShoutAnonReq(
        CborEncoder* e, const EchoShoutAnonReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req");
    if (err) return err;
    err = echo_enc_ShoutRequest(&m, &v->req);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError echo_dec_EchoShoutAnonReq(
        CborValue* it, EchoShoutAnonReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "req", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = echo_dec_ShoutRequest(&field, &out->req);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void echo_free_EchoShoutAnonReq(EchoShoutAnonReq* v) {
    if (!v) return;
    echo_free_ShoutRequest(&v->req);
}

/* ============================================================ */
/* C ABI declarations (symbols exported by the Nim dylib)       */
/* ============================================================ */
#ifdef __cplusplus
extern "C" {
#endif

/*
 * out of poll on that context, unless the context closes first. The reply of a
 * static request arrives on the static context, the reply of the constructor on
 * the context it hands out in `*ctx_out`.
 * Anything else: the request was refused and no reply will come. NIMFFI_RET_ERR
 * (bad argument, undecodable request, context not accepting requests),
 * NIMFFI_RET_INVALID_CTX, NIMFFI_RET_QUEUE_FULL or NIMFFI_RET_TOO_LARGE; the text
 * is in last_error(). `req_id_out` must not be NULL. Request ids are never 0.
 * A reply can be polled before the submitting call has returned: a host that
 * polls on another thread registers its waiter under a lock held across the call.
 * When the constructor's reply is NIMFFI_RET_ERR the context still has to be
 * destroyed; after a refused constructor `*ctx_out` is NULL and nothing does.
 */

/** Creates an echo context that prefixes every reply with `config.prefix`. */
int echo_create(const uint8_t* req_cbor, size_t req_cbor_len, void** ctx_out, uint64_t* req_id_out);
/** Upper-cases `req.text` and returns it behind the context's prefix. */
int echo_shout(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
/** Returns the library's version string. */
int echo_version(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
int echo_lib_version(const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
int echo_shout_anon(const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
/** Releases the echo context. */
int echo_destroy(void* ctx);
/**
 * The token of the static context, where the replies of the static requests
 * arrive: poll it like any other context. Never destroy it; shutdown ends it.
 * NULL on failure, with the text in last_error().
 */
void* echo_static_ctx(void);
/**
 * Why the last request of the calling thread was refused. Thread-local, never
 * NULL, empty when nothing was refused, valid until that thread's next call into
 * the library. Owned by the library: never free it.
 */
const char* echo_last_error(void);
/**
 * Take the next message of `ctx` out of the library: a reply, an event, a
 * liveness report or the end of the context. `*msg` is set to a message the library owns, or to NULL.
 * `timeout_ms` 0 never blocks; a negative value waits until a message arrives or
 * the context closes.
 * Returns NIMFFI_RET_OK (`*msg` is set), NIMFFI_RET_TIMEOUT (nothing arrived in
 * time), NIMFFI_RET_CLOSED (the context was destroyed or recycled; `*msg` is a
 * NIMFFI_MSG_CLOSED whose ret_code is NIMFFI_RET_OK, or NIMFFI_RET_ERR with UTF-8
 * text in the payload saying why), NIMFFI_RET_INVALID_CTX (`ctx` is NULL, forged
 * or already destroyed), NIMFFI_RET_BUSY (another thread is inside poll on this
 * context) or NIMFFI_RET_ERR (`msg` is NULL).
 * Lifetime: the message and its payload belong to the library and stay valid until the next
 * poll on the same context, whatever that poll returns. Never free it, and decode
 * it before polling again.
 * Single consumer: one thread at a time polls a context. Any host thread will do;
 * it needs no setup.
 */
int echo_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);
/**
 * A handle to wait on instead of blocking in poll, for a host with an event loop
 * of its own. It is ready while a message waits or the context is closed.
 * Linux: an epoll fd. macOS/BSD: a kqueue fd. Wait until it is readable with
 * poll(2), select(2) or the host's own epoll/kqueue; never read from it.
 * Windows: an Event HANDLE (cast the returned value) that can only be waited on,
 * with WaitForSingleObject or WaitForMultipleObjects.
 * Once it is ready, poll with a timeout of 0 until NIMFFI_RET_TIMEOUT.
 * A stalled FFI thread is only noticed inside poll, so the handle does not become
 * ready for it: a host that wants NIMFFI_MSG_NOT_RESPONDING also polls about once
 * a second.
 * Returns -1 on failure. Each call returns a new handle, which the caller owns
 * and closes with close(), or CloseHandle on Windows.
 */
intptr_t echo_poll_fd(void* ctx);
/**
 * Stop every context the library still holds and join their threads.
 * Call it before the process exits when a context is still alive, or when a
 * static proc built the shared context.
 * Returns 0 when every context stopped, 1 when one was left running.
 */
int echo_shutdown(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

/* CBOR buffer adapters (typed codec → void* driver signature) */
static inline CborError echo_encv_EchoCreateCtorReq(CborEncoder* e, const void* v) { return echo_enc_EchoCreateCtorReq(e, (const EchoCreateCtorReq*)v); }
static inline CborError echo_encv_EchoShoutReq(CborEncoder* e, const void* v) { return echo_enc_EchoShoutReq(e, (const EchoShoutReq*)v); }
static inline CborError echo_encv_EchoVersionReq(CborEncoder* e, const void* v) { return echo_enc_EchoVersionReq(e, (const EchoVersionReq*)v); }
static inline CborError echo_encv_EchoLibVersionReq(CborEncoder* e, const void* v) { return echo_enc_EchoLibVersionReq(e, (const EchoLibVersionReq*)v); }
static inline CborError echo_encv_EchoShoutAnonReq(CborEncoder* e, const void* v) { return echo_enc_EchoShoutAnonReq(e, (const EchoShoutAnonReq*)v); }
static inline CborError echo_decv_ShoutResponse(CborValue* it, void* v) { return echo_dec_ShoutResponse(it, (ShoutResponse*)v); }
static inline CborError echo_decv_Str(CborValue* it, void* v) { return nimffi_dec_str(it, (const char**)v); }

/* ============================================================ */
/* echo API                                                     */
/* ============================================================ */
/* The library calls nothing back and the binding starts no thread: a reply,
 * an event or a liveness report reaches the host inside echo_ctx_dispatch_next(),
 * on the thread that calls it.
 *
 * Threads: a context of this binding is single-threaded by design. Submit and
 * dispatch it from one thread, or hold one lock around both. A host that wants
 * something else uses the raw echo_<proc>() and echo_poll() exports with the
 * decoders below.
 *
 * Context: echo_ctx_create_sync(), echo_ctx_create(), echo_ctx_destroy().
 *
 * Requests. Each has an asynchronous form, whose on_reply runs inside the dispatch thread;
 * a _sync form for a sequential program, which dispatches until its own reply
 * arrives; and a decoder of the raw reply:
 *   echo_ctx_shout()  echo_ctx_shout_sync()  echo_decode_shout_reply()
 *   echo_ctx_version()  echo_ctx_version_sync()  echo_decode_version_reply()
 *   echo_static_lib_version()  echo_static_lib_version_sync()  echo_decode_lib_version_reply()
 *   echo_static_shout_anon()  echo_static_shout_anon_sync()  echo_decode_shout_anon_reply()
 * The replies of the static requests arrive on the static context: echo_static_dispatch_next().
 *
 * on_reply(ret, reply, err, user_data) runs once, with `ret`:
 *   NIMFFI_RET_OK      `reply` is set and `err` is NULL
 *   NIMFFI_RET_ERR     the library answered with an error: `err` is its text
 *   NIMFFI_RET_CLOSED  the context closed before the reply came
 *   -1                 the reply did not decode: `err` says why
 * Submitting returns NIMFFI_RET_OK; or the code of the library's refusal, with
 * the text in echo_last_error(); or -1 when the binding could not encode the
 * request or is out of memory. After anything but NIMFFI_RET_OK nothing was
 * recorded and on_reply never runs.
 * A _sync form returns the same codes, and NIMFFI_RET_TIMEOUT when `timeout_ms`
 * passed first (negative waits forever; the late reply is then dropped). On
 * NIMFFI_RET_OK the caller owns `*out`; otherwise `*out` is zeroed and `*err`,
 * when `err` is not NULL, is a text the caller frees with free(). Every other
 * message that arrives meanwhile goes to `handlers`, which may be NULL.
 *
 * Messages from the library, each an entry of EchoHandlers. A handler may
 * submit requests, _sync ones included:
 *   stale_warn, not_responding, responding, closed
 */
typedef struct {
    void* ptr;             /* the library's token, for the raw exports */
    NimFfiPending pending; /* requests waiting for their reply */
} EchoCtx;

/* ---- everything the library can send ---- */
/* Replies go to the on_reply of their request; the rest is listed here. A NULL
 * entry means "ignore". Each handler runs on the thread that dispatches; what it is
 * handed belongs to the binding and is valid only until it returns. */
typedef struct {
    /* Request `req_id` is still running after `elapsed_ms`; its reply still comes. */
    void (*stale_warn)(uint64_t req_id, uint64_t elapsed_ms, void* user_data);
    /* `reason` is a NIMFFI_NOT_RESPONDING_*: the FFI thread stalled, or the event
     * queue overflowed and requests are refused from now on. */
    void (*not_responding)(uint64_t reason, void* user_data);
    /* The FFI thread's heartbeat resumed. */
    void (*responding)(void* user_data);
    /* The context is gone. `ret` is NIMFFI_RET_OK, or NIMFFI_RET_ERR with `reason`
     * (a NUL-terminated copy, NULL when none) saying why it was quarantined. Runs
     * after every request still waiting was settled with NIMFFI_RET_CLOSED. */
    void (*closed)(int ret, const char* reason, void* user_data);
    void* user_data;
} EchoHandlers;

/* Decodes `msg` fully, then calls its on_reply or its handler, then frees what
 * it decoded. Returns 0, also for an event this header does not know and for a
 * reply nobody waits for, or -1 on a decode error or an unknown message kind. */
static inline int echo_ctx_dispatch(EchoCtx* ctx, const NimFfiMsg* msg, const EchoHandlers* handlers) {
    if (!ctx || !msg) return -1;
    switch (msg->kind) {
    case NIMFFI_MSG_REPLY: {
        NimFfiPendingEntry entry;
        /* Nobody waits: given up on by a _sync timeout, or sent through the raw export. */
        if (!nimffi_pending_take(&ctx->pending, msg->id, &entry)) return 0;
        entry.settle(msg, entry.on_reply, entry.user_data);
        return 0;
    }
    case NIMFFI_MSG_STALE_WARN:
        if (handlers && handlers->stale_warn) handlers->stale_warn(msg->id, msg->aux, handlers->user_data);
        return 0;
    case NIMFFI_MSG_EVENT:
        return 0;
    case NIMFFI_MSG_NOT_RESPONDING:
        if (handlers && handlers->not_responding) handlers->not_responding(msg->aux, handlers->user_data);
        return 0;
    case NIMFFI_MSG_RESPONDING:
        if (handlers && handlers->responding) handlers->responding(handlers->user_data);
        return 0;
    case NIMFFI_MSG_CLOSED: {
        /* Copied first: a callback below may poll, which ends the life of `msg`. */
        int ret = (int)msg->ret_code;
        char* reason = NULL;
        if (msg->len > 0) reason = nimffi_dup_cstr_n((const char*)msg->payload, msg->len);
        nimffi_pending_close(&ctx->pending);
        if (handlers && handlers->closed) handlers->closed(ret, reason, handlers->user_data);
        free(reason);
        return 0;
    }
    default:
        return -1;
    }
}

/* One echo_poll() and the dispatch of what it returned.
 * Returns the poll code (NIMFFI_RET_OK, _TIMEOUT, _CLOSED after the `closed`
 * handler ran, _INVALID_CTX, _BUSY, _ERR), or -1 when the message did not
 * dispatch. `ctx` must stay alive for the whole call: stop dispatching before
 * echo_ctx_destroy(). */
static inline int echo_ctx_dispatch_next(EchoCtx* ctx, int32_t timeout_ms, const EchoHandlers* handlers) {
    if (!ctx) return NIMFFI_RET_INVALID_CTX;
    const NimFfiMsg* msg = NULL;
    int rc = echo_poll(ctx->ptr, timeout_ms, &msg);
    if (rc != NIMFFI_RET_OK && rc != NIMFFI_RET_CLOSED) return rc;
    if (echo_ctx_dispatch(ctx, msg, handlers) != 0) return -1;
    return rc;
}

/* See echo_poll_fd(): the caller owns and closes the handle. */
static inline intptr_t echo_ctx_poll_fd(const EchoCtx* ctx) {
    if (!ctx) return -1;
    return echo_poll_fd(ctx->ptr);
}

/* Dispatches `ctx` until `slot` is settled, handing every other message to
 * `handlers`. A request given up on is forgotten, so that its late reply is
 * dropped instead of written into a stack frame that is gone. */
static inline int echo_ctx_await_(EchoCtx* ctx, uint64_t req_id, const NimFfiSyncSlot* slot, int32_t timeout_ms, const EchoHandlers* handlers) {
    int64_t deadline = 0;
    if (timeout_ms >= 0) deadline = nimffi_now_ms() + timeout_ms;
    while (!slot->done) {
        int32_t wait_ms = -1;
        if (timeout_ms >= 0) {
            int64_t left = deadline - nimffi_now_ms();
            wait_ms = left > 0 ? (int32_t)left : 0;
        }
        int rc = echo_ctx_dispatch_next(ctx, wait_ms, handlers);
        if (slot->done) break;
        /* A message that did not dispatch (-1) was not ours: keep waiting. */
        if (rc == NIMFFI_RET_OK || rc == -1) continue;
        if (rc == NIMFFI_RET_TIMEOUT && wait_ms != 0) continue;
        nimffi_pending_abandon(&ctx->pending, req_id);
        return rc;
    }
    return slot->ret;
}

/* A static request has no context of its own: its reply arrives on the
 * library's static context, which the binding wraps here, once per program.
 * The single-thread rule holds for it too. */
NIMFFI_SHARED EchoCtx echo_static_binding_ = {NULL, {NULL, 0, 0}};

static inline EchoCtx* echo_static_(void) {
    /* Asked every time: echo_shutdown() ends the static context, and the
     * next static request starts a new one. */
    echo_static_binding_.ptr = echo_static_ctx();
    return &echo_static_binding_;
}

/* echo_ctx_dispatch_next() on the static context: delivers the replies of the
 * echo_static_*() requests. */
static inline int echo_static_dispatch_next(int32_t timeout_ms, const EchoHandlers* handlers) {
    return echo_ctx_dispatch_next(echo_static_(), timeout_ms, handlers);
}

/* ---- context ---- */
/* Requests still waiting are settled with NIMFFI_RET_CLOSED, after the library
 * let go of the context. Never call it from a handler or an on_reply of `ctx`. */
/** Releases the echo context. */
static inline int echo_ctx_destroy(EchoCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    if (ctx->ptr) { rc = echo_destroy(ctx->ptr); ctx->ptr = NULL; }
    nimffi_pending_close(&ctx->pending);
    /* A callback above may have made room for a request that was refused. */
    free(ctx->pending.items);
    free(ctx);
    return rc;
}

/* `ret` as for a request's on_reply. The context is the caller's whatever `ret`
 * says: release it with echo_ctx_destroy(). */
typedef void (*EchoCreateFn)(int ret, const char* err, void* user_data);
static inline void echo_create_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    EchoCreateFn on_created = (EchoCreateFn)fn;
    if (!on_created) return;
    if (!msg) {
        on_created(NIMFFI_RET_CLOSED, "context closed", user_data);
        return;
    }
    char* err = NULL;
    int rc = nimffi_reply_status(msg, &err);
    const char* text = NULL;
    if (rc != NIMFFI_RET_OK) text = err ? err : "";
    on_created(rc, text, user_data);
    free(err);
}
static inline void echo_create_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = nimffi_reply_status(msg, slot->err);
    slot->done = true;
}
static inline int echo_create_submit_(const EchoConfig* config, EchoCtx** ctx_out, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    EchoCreateCtorReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.config = *config;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(echo_encv_EchoCreateCtorReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    EchoCtx* ctx = (EchoCtx*)calloc(1, sizeof(EchoCtx));
    if (!ctx || nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (ctx) free(ctx->pending.items);
        free(ctx);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = echo_create(req_buf, req_len, &ctx->ptr, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(echo_last_error());
        if (ctx) free(ctx->pending.items);
        free(ctx);
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    *ctx_out = ctx;
    return NIMFFI_RET_OK;
}
/** Creates an echo context that prefixes every reply with `config.prefix`. */
static inline int echo_ctx_create(const EchoConfig* config, EchoCtx** ctx_out, EchoCreateFn on_created, void* user_data) {
    if (!ctx_out) return -1;
    *ctx_out = NULL;
    uint64_t req_id = 0;
    return echo_create_submit_(config, ctx_out, echo_create_settle_, (nimffi_generic_fn)on_created, user_data, &req_id, NULL);
}
/** Creates an echo context that prefixes every reply with `config.prefix`. */
static inline int echo_ctx_create_sync(const EchoConfig* config, EchoCtx** out, char** err, int32_t timeout_ms) {
    if (err) *err = NULL;
    if (!out) return -1;
    *out = NULL;
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, NULL, err};
    EchoCtx* ctx = NULL;
    uint64_t req_id = 0;
    int rc = echo_create_submit_(config, &ctx, echo_create_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    rc = echo_ctx_await_(ctx, req_id, &slot, timeout_ms, NULL);
    if (rc != NIMFFI_RET_OK) {
        /* The slot is claimed even when construction failed. */
        (void)echo_ctx_destroy(ctx);
        return rc;
    }
    *out = ctx;
    return NIMFFI_RET_OK;
}

/* ---- requests ---- */
typedef void (*EchoShoutReplyFn)(int ret, const ShoutResponse* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers echo_shout(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `out` with echo_free_ShoutResponse(). */
static inline int echo_decode_shout_reply(const NimFfiMsg* msg, ShoutResponse* out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, echo_decv_ShoutResponse, out, err);
    if (rc == -1 && out) echo_free_ShoutResponse(out);
    return rc;
}
static inline void echo_shout_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    EchoShoutReplyFn on_reply = (EchoShoutReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    ShoutResponse out;
    char* err = NULL;
    int rc = echo_decode_shout_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    echo_free_ShoutResponse(&out);
}
static inline void echo_shout_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = echo_decode_shout_reply(msg, (ShoutResponse*)slot->out, slot->err);
    slot->done = true;
}
static inline int echo_shout_submit_(EchoCtx* ctx, const ShoutRequest* req, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    if (!ctx) {
        if (err) *err = nimffi_dup_cstr("ctx is NULL");
        return NIMFFI_RET_INVALID_CTX;
    }
    EchoShoutReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(echo_encv_EchoShoutReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = echo_shout(ctx->ptr, req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(echo_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
/** Upper-cases `req.text` and returns it behind the context's prefix. */
static inline int echo_ctx_shout(EchoCtx* ctx, const ShoutRequest* req, EchoShoutReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = echo_shout_submit_(ctx, req, echo_shout_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
/** Upper-cases `req.text` and returns it behind the context's prefix. */
static inline int echo_ctx_shout_sync(EchoCtx* ctx, const ShoutRequest* req, ShoutResponse* out, char** err, int32_t timeout_ms, const EchoHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = echo_shout_submit_(ctx, req, echo_shout_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return echo_ctx_await_(ctx, req_id, &slot, timeout_ms, handlers);
}

typedef void (*EchoVersionReplyFn)(int ret, const char* const* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers echo_version(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `*out` with free(). */
static inline int echo_decode_version_reply(const NimFfiMsg* msg, const char** out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, echo_decv_Str, out, err);
    if (rc == -1 && out) do { free((void*)*out); *out = NULL; } while (0);
    return rc;
}
static inline void echo_version_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    EchoVersionReplyFn on_reply = (EchoVersionReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    const char* out;
    char* err = NULL;
    int rc = echo_decode_version_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    do { free((void*)out); out = NULL; } while (0);
}
static inline void echo_version_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = echo_decode_version_reply(msg, (const char**)slot->out, slot->err);
    slot->done = true;
}
static inline int echo_version_submit_(EchoCtx* ctx, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    if (!ctx) {
        if (err) *err = nimffi_dup_cstr("ctx is NULL");
        return NIMFFI_RET_INVALID_CTX;
    }
    EchoVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(echo_encv_EchoVersionReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = echo_version(ctx->ptr, req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(echo_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
/** Returns the library's version string. */
static inline int echo_ctx_version(EchoCtx* ctx, EchoVersionReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = echo_version_submit_(ctx, echo_version_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
/** Returns the library's version string. */
static inline int echo_ctx_version_sync(EchoCtx* ctx, const char** out, char** err, int32_t timeout_ms, const EchoHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = echo_version_submit_(ctx, echo_version_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return echo_ctx_await_(ctx, req_id, &slot, timeout_ms, handlers);
}

typedef void (*EchoLibVersionReplyFn)(int ret, const char* const* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers echo_lib_version(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `*out` with free(). */
static inline int echo_decode_lib_version_reply(const NimFfiMsg* msg, const char** out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, echo_decv_Str, out, err);
    if (rc == -1 && out) do { free((void*)*out); *out = NULL; } while (0);
    return rc;
}
static inline void echo_lib_version_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    EchoLibVersionReplyFn on_reply = (EchoLibVersionReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    const char* out;
    char* err = NULL;
    int rc = echo_decode_lib_version_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    do { free((void*)out); out = NULL; } while (0);
}
static inline void echo_lib_version_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = echo_decode_lib_version_reply(msg, (const char**)slot->out, slot->err);
    slot->done = true;
}
static inline int echo_lib_version_submit_(nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    EchoLibVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(echo_encv_EchoLibVersionReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    EchoCtx* ctx = echo_static_();
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = echo_lib_version(req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(echo_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
static inline int echo_static_lib_version(EchoLibVersionReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = echo_lib_version_submit_(echo_lib_version_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
static inline int echo_static_lib_version_sync(const char** out, char** err, int32_t timeout_ms, const EchoHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = echo_lib_version_submit_(echo_lib_version_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return echo_ctx_await_(echo_static_(), req_id, &slot, timeout_ms, handlers);
}

typedef void (*EchoShoutAnonReplyFn)(int ret, const ShoutResponse* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers echo_shout_anon(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `out` with echo_free_ShoutResponse(). */
static inline int echo_decode_shout_anon_reply(const NimFfiMsg* msg, ShoutResponse* out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, echo_decv_ShoutResponse, out, err);
    if (rc == -1 && out) echo_free_ShoutResponse(out);
    return rc;
}
static inline void echo_shout_anon_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    EchoShoutAnonReplyFn on_reply = (EchoShoutAnonReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    ShoutResponse out;
    char* err = NULL;
    int rc = echo_decode_shout_anon_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    echo_free_ShoutResponse(&out);
}
static inline void echo_shout_anon_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = echo_decode_shout_anon_reply(msg, (ShoutResponse*)slot->out, slot->err);
    slot->done = true;
}
static inline int echo_shout_anon_submit_(const ShoutRequest* req, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    EchoShoutAnonReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(echo_encv_EchoShoutAnonReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    EchoCtx* ctx = echo_static_();
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = echo_shout_anon(req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(echo_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
static inline int echo_static_shout_anon(const ShoutRequest* req, EchoShoutAnonReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = echo_shout_anon_submit_(req, echo_shout_anon_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
static inline int echo_static_shout_anon_sync(const ShoutRequest* req, ShoutResponse* out, char** err, int32_t timeout_ms, const EchoHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = echo_shout_anon_submit_(req, echo_shout_anon_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return echo_ctx_await_(echo_static_(), req_id, &slot, timeout_ms, handlers);
}

#endif /* NIM_FFI_LIB_ECHO_H_INCLUDED */
