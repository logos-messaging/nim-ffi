#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ----------------------------------------------------------------------------
 * FFI callback type.
 *
 * Used as the success/failure notification for every async call. Identical
 * to the Nim `FFICallBack` signature byte-for-byte; reused unchanged by the
 * C++ sugar layer.
 *
 *   ret      : 0 = OK, 1 = error, 2 = missing callback
 *   msg      : on RET_OK, points to a `const <Proc>Resp*` (caller must cast).
 *              On RET_ERR, points to a UTF-8 error message of `len` bytes
 *              (not necessarily NUL-terminated).
 *   len      : on RET_OK, sizeof of the Resp struct. On RET_ERR, byte length
 *              of the error string.
 *   user_data: pass-through pointer the caller supplied at the call site.
 *
 * Lifetime: any pointer reachable from `msg` (the Resp struct, any
 * `const char*` field inside it, etc.) is valid only for the duration of
 * the callback invocation. Deep-copy anything you want to retain.
 * -------------------------------------------------------------------------- */
typedef void (*FfiCallback)(int ret, const char* msg, size_t len, void* user_data);


/* ============================================================
 * User-declared FFI types
 * ============================================================ */

typedef struct EchoerConfig {
    const char* prefix;
} EchoerConfig;

typedef struct ShoutRequest {
    const char* message;
    int64_t exclamations;
} ShoutRequest;

typedef struct ShoutResponse {
    const char* shouted;
    const char* prefixUsed;
} ShoutResponse;

/* ============================================================
 * Per-proc request envelopes
 * ============================================================ */

typedef struct EchoerCreateCtorReq {
    EchoerConfig config;
} EchoerCreateCtorReq;

typedef struct EchoerShoutReq {
    ShoutRequest req;
} EchoerShoutReq;

/* ============================================================
 * Per-proc response envelopes
 * (delivered through the FfiCallback's `msg` pointer)
 * ============================================================ */

typedef struct EchoerShoutResp {
    ShoutResponse value;
} EchoerShoutResp;

/* ============================================================
 * Function declarations
 * ============================================================ */

void* echoer_create(const EchoerCreateCtorReq* req, FfiCallback cb, void* user_data);
int echoer_shout(void* ctx, const EchoerShoutReq* req, FfiCallback cb, void* user_data);
int echoer_destroy(void* ctx);

#ifdef __cplusplus
} /* extern "C" */
#endif
