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

typedef struct TimerConfig {
    const char* name;
} TimerConfig;

typedef struct EchoRequest {
    const char* message;
    int64_t delayMs;
} EchoRequest;

typedef struct EchoResponse {
    const char* echoed;
    const char* timerName;
} EchoResponse;

typedef struct ComplexRequest {
    const EchoRequest* messages;
    size_t messages_len;
    const char** tags;
    size_t tags_len;
    const char** note;
    const int64_t* retries;
} ComplexRequest;

typedef struct ComplexResponse {
    const char* summary;
    int64_t itemCount;
    bool hasNote;
} ComplexResponse;

typedef struct JobSpec {
    const char* name;
    const char** payload;
    size_t payload_len;
    int64_t priority;
} JobSpec;

typedef struct RetryPolicy {
    int64_t maxAttempts;
    int64_t backoffMs;
    const char** retryOn;
    size_t retryOn_len;
} RetryPolicy;

typedef struct ScheduleConfig {
    int64_t startAtMs;
    int64_t intervalMs;
    const int64_t* jitter;
} ScheduleConfig;

typedef struct ScheduleResult {
    const char* jobId;
    int64_t willRunCount;
    int64_t firstRunAtMs;
    int64_t effectiveBackoffMs;
} ScheduleResult;

/* ============================================================
 * Per-proc request envelopes
 * ============================================================ */

typedef struct MyTimerCreateCtorReq {
    TimerConfig config;
} MyTimerCreateCtorReq;

typedef struct MyTimerEchoReq {
    EchoRequest req;
} MyTimerEchoReq;

typedef struct MyTimerVersionReq {
    uint8_t _placeholder;
} MyTimerVersionReq;

typedef struct MyTimerComplexReq {
    ComplexRequest req;
} MyTimerComplexReq;

typedef struct MyTimerScheduleReq {
    JobSpec job;
    RetryPolicy retry;
    ScheduleConfig schedule;
} MyTimerScheduleReq;

/* ============================================================
 * Per-proc response envelopes
 * (delivered through the FfiCallback's `msg` pointer)
 * ============================================================ */

typedef struct MyTimerEchoResp {
    EchoResponse value;
} MyTimerEchoResp;

typedef struct MyTimerVersionResp {
    const char* value;
} MyTimerVersionResp;

typedef struct MyTimerComplexResp {
    ComplexResponse value;
} MyTimerComplexResp;

typedef struct MyTimerScheduleResp {
    ScheduleResult value;
} MyTimerScheduleResp;

/* ============================================================
 * Function declarations
 * ============================================================ */

void* my_timer_create(const MyTimerCreateCtorReq* req, FfiCallback cb, void* user_data);
int my_timer_echo(void* ctx, const MyTimerEchoReq* req, FfiCallback cb, void* user_data);
int my_timer_version(void* ctx, const MyTimerVersionReq* req, FfiCallback cb, void* user_data);
int my_timer_complex(void* ctx, const MyTimerComplexReq* req, FfiCallback cb, void* user_data);
int my_timer_schedule(void* ctx, const MyTimerScheduleReq* req, FfiCallback cb, void* user_data);
int my_timer_destroy(void* ctx);

#ifdef __cplusplus
} /* extern "C" */
#endif
