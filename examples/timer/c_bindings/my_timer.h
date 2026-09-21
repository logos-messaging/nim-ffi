#ifndef NIM_FFI_LIB_MY_TIMER_H_INCLUDED
#define NIM_FFI_LIB_MY_TIMER_H_INCLUDED
#include "nim_ffi_cbor.h"

/* ============================================================ */
/* Generated constants                                          */
/* ============================================================ */

static const int64_t MAX_DELAY_MS = 5000;
static const uint32_t DEFAULT_BACKOFF_MS = 250;
static const char* const TIMER_VERSION = "nim-timer v0.1.0";

/* ============================================================ */
/* Generated types (user-declared + per-proc request envelopes) */
/* ============================================================ */

typedef struct {
    const char* name;
} TimerConfig;
typedef struct {
    const char* message;
    int64_t delayMs;
} EchoRequest;
typedef struct {
    const char* echoed;
    const char* timerName;
} EchoResponse;
typedef struct {
    EchoRequest* data;
    size_t len;
} MyTimerSeq_EchoRequest;
typedef struct {
    const char** data;
    size_t len;
} MyTimerSeq_Str;
typedef struct {
    bool has_value;
    const char* value;
} MyTimerOpt_Str;
typedef struct {
    bool has_value;
    int64_t value;
} MyTimerOpt_I64;
typedef struct {
    MyTimerSeq_EchoRequest messages;
    MyTimerSeq_Str tags;
    MyTimerOpt_Str note;
    MyTimerOpt_I64 retries;
} ComplexRequest;
typedef struct {
    const char* summary;
    int64_t itemCount;
    bool hasNote;
} ComplexResponse;
typedef struct {
    const char* message;
    int64_t echoCount;
} EchoEvent;
typedef struct {
    const char* jobId;
    int64_t willRunCount;
} OnJobScheduledPayload;
typedef enum {
    JOB_PRIORITY_JP_LOW = 0,
    JOB_PRIORITY_JP_NORMAL = 1,
    JOB_PRIORITY_JP_HIGH = 2
} JobPriority;
typedef struct {
    const char* name;
    MyTimerSeq_Str payload;
    JobPriority priority;
} JobSpec;
typedef struct {
    int64_t maxAttempts;
    int64_t backoffMs;
    MyTimerSeq_Str retryOn;
} RetryPolicy;
typedef struct {
    int64_t startAtMs;
    int64_t intervalMs;
    MyTimerOpt_I64 jitter;
} ScheduleConfig;
typedef struct {
    const char* jobId;
    int64_t willRunCount;
    int64_t firstRunAtMs;
    int64_t effectiveBackoffMs;
    JobPriority priority;
} ScheduleResult;
typedef struct {
    TimerConfig config;
} MyTimerCreateCtorReq;
typedef struct {
    EchoRequest req;
} MyTimerEchoReq;
typedef struct {
    char _nimffi_empty; /* C forbids empty structs */
} MyTimerVersionReq;
typedef struct {
    char _nimffi_empty; /* C forbids empty structs */
} MyTimerLibVersionReq;
typedef struct {
    ComplexRequest req;
} MyTimerComplexReq;
typedef struct {
    JobSpec job;
    RetryPolicy retry;
    ScheduleConfig schedule;
} MyTimerScheduleReq;

static inline CborError my_timer_enc_TimerConfig(
        CborEncoder* e, const TimerConfig* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "name");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->name);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_TimerConfig(
        CborValue* it, TimerConfig* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "name", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->name);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_TimerConfig(TimerConfig* v) {
    if (!v) return;
    do { free((void*)v->name); v->name = NULL; } while (0);
}
static inline CborError my_timer_enc_EchoRequest(
        CborEncoder* e, const EchoRequest* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "message");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->message);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "delayMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->delayMs);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_EchoRequest(
        CborValue* it, EchoRequest* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "message", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->message);
    if (err) return err;
    err = cbor_value_map_find_value(it, "delayMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->delayMs);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_EchoRequest(EchoRequest* v) {
    if (!v) return;
    do { free((void*)v->message); v->message = NULL; } while (0);
}
static inline CborError my_timer_enc_EchoResponse(
        CborEncoder* e, const EchoResponse* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "echoed");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->echoed);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "timerName");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->timerName);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_EchoResponse(
        CborValue* it, EchoResponse* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "echoed", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->echoed);
    if (err) return err;
    err = cbor_value_map_find_value(it, "timerName", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->timerName);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_EchoResponse(EchoResponse* v) {
    if (!v) return;
    do { free((void*)v->echoed); v->echoed = NULL; } while (0);
    do { free((void*)v->timerName); v->timerName = NULL; } while (0);
}
static inline CborError my_timer_enc_MyTimerSeq_EchoRequest(
        CborEncoder* e, const MyTimerSeq_EchoRequest* v) {
    CborEncoder arr;
    CborError err = cbor_encoder_create_array(e, &arr, v->len);
    if (err) return err;
    for (size_t i = 0; i < v->len; i++) {
        err = my_timer_enc_EchoRequest(&arr, &v->data[i]);
        if (err) return err;
    }
    return cbor_encoder_close_container(e, &arr);
}
static inline CborError my_timer_dec_MyTimerSeq_EchoRequest(
        CborValue* it, MyTimerSeq_EchoRequest* out) {
    if (!cbor_value_is_array(it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_array_length(it, &len);
    if (err) return err;
    out->data = (EchoRequest*)calloc(len ? len : 1, sizeof(EchoRequest));
    if (!out->data) return CborErrorOutOfMemory;
    out->len = len;
    CborValue inner;
    err = cbor_value_enter_container(it, &inner);
    if (err) return err;
    for (size_t i = 0; i < len; i++) {
        err = my_timer_dec_EchoRequest(&inner, &out->data[i]);
        if (err) return err;
    }
    return cbor_value_leave_container(it, &inner);
}
static inline void my_timer_free_MyTimerSeq_EchoRequest(MyTimerSeq_EchoRequest* v) {
    if (!v || !v->data) return;
    for (size_t i = 0; i < v->len; i++) my_timer_free_EchoRequest(&v->data[i]);
    free(v->data);
    v->data = NULL;
    v->len = 0;
}
static inline CborError my_timer_enc_MyTimerSeq_Str(
        CborEncoder* e, const MyTimerSeq_Str* v) {
    CborEncoder arr;
    CborError err = cbor_encoder_create_array(e, &arr, v->len);
    if (err) return err;
    for (size_t i = 0; i < v->len; i++) {
        err = nimffi_enc_str(&arr, &v->data[i]);
        if (err) return err;
    }
    return cbor_encoder_close_container(e, &arr);
}
static inline CborError my_timer_dec_MyTimerSeq_Str(
        CborValue* it, MyTimerSeq_Str* out) {
    if (!cbor_value_is_array(it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_array_length(it, &len);
    if (err) return err;
    out->data = (const char**)calloc(len ? len : 1, sizeof(const char*));
    if (!out->data) return CborErrorOutOfMemory;
    out->len = len;
    CborValue inner;
    err = cbor_value_enter_container(it, &inner);
    if (err) return err;
    for (size_t i = 0; i < len; i++) {
        err = nimffi_dec_str(&inner, &out->data[i]);
        if (err) return err;
    }
    return cbor_value_leave_container(it, &inner);
}
static inline void my_timer_free_MyTimerSeq_Str(MyTimerSeq_Str* v) {
    if (!v || !v->data) return;
    for (size_t i = 0; i < v->len; i++) do { free((void*)v->data[i]); v->data[i] = NULL; } while (0);
    free(v->data);
    v->data = NULL;
    v->len = 0;
}
static inline CborError my_timer_enc_MyTimerOpt_Str(
        CborEncoder* e, const MyTimerOpt_Str* v) {
    if (!v->has_value) return cbor_encode_null(e);
    return nimffi_enc_str(e, &v->value);
}
static inline CborError my_timer_dec_MyTimerOpt_Str(
        CborValue* it, MyTimerOpt_Str* out) {
    if (cbor_value_is_null(it)) {
        out->has_value = false;
        memset(&out->value, 0, sizeof(out->value));
        return cbor_value_advance(it);
    }
    out->has_value = true;
    return nimffi_dec_str(it, &out->value);
}
static inline void my_timer_free_MyTimerOpt_Str(MyTimerOpt_Str* v) {
    if (!v || !v->has_value) return;
    do { free((void*)v->value); v->value = NULL; } while (0);
    v->has_value = false;
}
static inline CborError my_timer_enc_MyTimerOpt_I64(
        CborEncoder* e, const MyTimerOpt_I64* v) {
    if (!v->has_value) return cbor_encode_null(e);
    return nimffi_enc_i64(e, &v->value);
}
static inline CborError my_timer_dec_MyTimerOpt_I64(
        CborValue* it, MyTimerOpt_I64* out) {
    if (cbor_value_is_null(it)) {
        out->has_value = false;
        memset(&out->value, 0, sizeof(out->value));
        return cbor_value_advance(it);
    }
    out->has_value = true;
    return nimffi_dec_i64(it, &out->value);
}
static inline CborError my_timer_enc_ComplexRequest(
        CborEncoder* e, const ComplexRequest* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 4);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "messages");
    if (err) return err;
    err = my_timer_enc_MyTimerSeq_EchoRequest(&m, &v->messages);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "tags");
    if (err) return err;
    err = my_timer_enc_MyTimerSeq_Str(&m, &v->tags);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "note");
    if (err) return err;
    err = my_timer_enc_MyTimerOpt_Str(&m, &v->note);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "retries");
    if (err) return err;
    err = my_timer_enc_MyTimerOpt_I64(&m, &v->retries);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_ComplexRequest(
        CborValue* it, ComplexRequest* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "messages", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerSeq_EchoRequest(&field, &out->messages);
    if (err) return err;
    err = cbor_value_map_find_value(it, "tags", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerSeq_Str(&field, &out->tags);
    if (err) return err;
    err = cbor_value_map_find_value(it, "note", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerOpt_Str(&field, &out->note);
    if (err) return err;
    err = cbor_value_map_find_value(it, "retries", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerOpt_I64(&field, &out->retries);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_ComplexRequest(ComplexRequest* v) {
    if (!v) return;
    my_timer_free_MyTimerSeq_EchoRequest(&v->messages);
    my_timer_free_MyTimerSeq_Str(&v->tags);
    my_timer_free_MyTimerOpt_Str(&v->note);
}
static inline CborError my_timer_enc_ComplexResponse(
        CborEncoder* e, const ComplexResponse* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "summary");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->summary);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "itemCount");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->itemCount);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "hasNote");
    if (err) return err;
    err = nimffi_enc_bool(&m, &v->hasNote);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_ComplexResponse(
        CborValue* it, ComplexResponse* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "summary", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->summary);
    if (err) return err;
    err = cbor_value_map_find_value(it, "itemCount", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->itemCount);
    if (err) return err;
    err = cbor_value_map_find_value(it, "hasNote", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_bool(&field, &out->hasNote);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_ComplexResponse(ComplexResponse* v) {
    if (!v) return;
    do { free((void*)v->summary); v->summary = NULL; } while (0);
}
static inline CborError my_timer_enc_EchoEvent(
        CborEncoder* e, const EchoEvent* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "message");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->message);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "echoCount");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->echoCount);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_EchoEvent(
        CborValue* it, EchoEvent* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "message", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->message);
    if (err) return err;
    err = cbor_value_map_find_value(it, "echoCount", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->echoCount);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_EchoEvent(EchoEvent* v) {
    if (!v) return;
    do { free((void*)v->message); v->message = NULL; } while (0);
}
static inline CborError my_timer_enc_OnJobScheduledPayload(
        CborEncoder* e, const OnJobScheduledPayload* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "jobId");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->jobId);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "willRunCount");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->willRunCount);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_OnJobScheduledPayload(
        CborValue* it, OnJobScheduledPayload* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "jobId", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->jobId);
    if (err) return err;
    err = cbor_value_map_find_value(it, "willRunCount", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->willRunCount);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_OnJobScheduledPayload(OnJobScheduledPayload* v) {
    if (!v) return;
    do { free((void*)v->jobId); v->jobId = NULL; } while (0);
}
static inline CborError my_timer_enc_JobPriority(
        CborEncoder* e, const JobPriority* v) {
    switch (*v) {
    case JOB_PRIORITY_JP_LOW: return cbor_encode_text_stringz(e, "low");
    case JOB_PRIORITY_JP_NORMAL: return cbor_encode_text_stringz(e, "normal");
    case JOB_PRIORITY_JP_HIGH: return cbor_encode_text_stringz(e, "high");
    }
    return CborErrorImproperValue;
}
static inline CborError my_timer_dec_JobPriority(
        CborValue* it, JobPriority* out) {
    if (!cbor_value_is_text_string(it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_string_length(it, &len);
    if (err) return err;
    char buf[7];
    if (len >= sizeof(buf)) return CborErrorImproperValue;
    size_t copied = sizeof(buf);
    err = cbor_value_copy_text_string(it, buf, &copied, NULL);
    if (err) return err;
    buf[len] = '\0';
    if (strcmp(buf, "low") == 0) { *out = JOB_PRIORITY_JP_LOW; return cbor_value_advance(it); }
    if (strcmp(buf, "normal") == 0) { *out = JOB_PRIORITY_JP_NORMAL; return cbor_value_advance(it); }
    if (strcmp(buf, "high") == 0) { *out = JOB_PRIORITY_JP_HIGH; return cbor_value_advance(it); }
    return CborErrorImproperValue;
}
static inline CborError my_timer_enc_JobSpec(
        CborEncoder* e, const JobSpec* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "name");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->name);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "payload");
    if (err) return err;
    err = my_timer_enc_MyTimerSeq_Str(&m, &v->payload);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "priority");
    if (err) return err;
    err = my_timer_enc_JobPriority(&m, &v->priority);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_JobSpec(
        CborValue* it, JobSpec* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "name", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->name);
    if (err) return err;
    err = cbor_value_map_find_value(it, "payload", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerSeq_Str(&field, &out->payload);
    if (err) return err;
    err = cbor_value_map_find_value(it, "priority", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_JobPriority(&field, &out->priority);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_JobSpec(JobSpec* v) {
    if (!v) return;
    do { free((void*)v->name); v->name = NULL; } while (0);
    my_timer_free_MyTimerSeq_Str(&v->payload);
}
static inline CborError my_timer_enc_RetryPolicy(
        CborEncoder* e, const RetryPolicy* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "maxAttempts");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->maxAttempts);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "backoffMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->backoffMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "retryOn");
    if (err) return err;
    err = my_timer_enc_MyTimerSeq_Str(&m, &v->retryOn);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_RetryPolicy(
        CborValue* it, RetryPolicy* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "maxAttempts", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->maxAttempts);
    if (err) return err;
    err = cbor_value_map_find_value(it, "backoffMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->backoffMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "retryOn", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerSeq_Str(&field, &out->retryOn);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_RetryPolicy(RetryPolicy* v) {
    if (!v) return;
    my_timer_free_MyTimerSeq_Str(&v->retryOn);
}
static inline CborError my_timer_enc_ScheduleConfig(
        CborEncoder* e, const ScheduleConfig* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "startAtMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->startAtMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "intervalMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->intervalMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "jitter");
    if (err) return err;
    err = my_timer_enc_MyTimerOpt_I64(&m, &v->jitter);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_ScheduleConfig(
        CborValue* it, ScheduleConfig* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "startAtMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->startAtMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "intervalMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->intervalMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "jitter", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_MyTimerOpt_I64(&field, &out->jitter);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline CborError my_timer_enc_ScheduleResult(
        CborEncoder* e, const ScheduleResult* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 5);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "jobId");
    if (err) return err;
    err = nimffi_enc_str(&m, &v->jobId);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "willRunCount");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->willRunCount);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "firstRunAtMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->firstRunAtMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "effectiveBackoffMs");
    if (err) return err;
    err = nimffi_enc_i64(&m, &v->effectiveBackoffMs);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "priority");
    if (err) return err;
    err = my_timer_enc_JobPriority(&m, &v->priority);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_ScheduleResult(
        CborValue* it, ScheduleResult* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "jobId", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_str(&field, &out->jobId);
    if (err) return err;
    err = cbor_value_map_find_value(it, "willRunCount", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->willRunCount);
    if (err) return err;
    err = cbor_value_map_find_value(it, "firstRunAtMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->firstRunAtMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "effectiveBackoffMs", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = nimffi_dec_i64(&field, &out->effectiveBackoffMs);
    if (err) return err;
    err = cbor_value_map_find_value(it, "priority", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_JobPriority(&field, &out->priority);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_ScheduleResult(ScheduleResult* v) {
    if (!v) return;
    do { free((void*)v->jobId); v->jobId = NULL; } while (0);
}
static inline CborError my_timer_enc_MyTimerCreateCtorReq(
        CborEncoder* e, const MyTimerCreateCtorReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "config");
    if (err) return err;
    err = my_timer_enc_TimerConfig(&m, &v->config);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerCreateCtorReq(
        CborValue* it, MyTimerCreateCtorReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "config", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_TimerConfig(&field, &out->config);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_MyTimerCreateCtorReq(MyTimerCreateCtorReq* v) {
    if (!v) return;
    my_timer_free_TimerConfig(&v->config);
}
static inline CborError my_timer_enc_MyTimerEchoReq(
        CborEncoder* e, const MyTimerEchoReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req");
    if (err) return err;
    err = my_timer_enc_EchoRequest(&m, &v->req);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerEchoReq(
        CborValue* it, MyTimerEchoReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "req", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_EchoRequest(&field, &out->req);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_MyTimerEchoReq(MyTimerEchoReq* v) {
    if (!v) return;
    my_timer_free_EchoRequest(&v->req);
}
static inline CborError my_timer_enc_MyTimerVersionReq(
        CborEncoder* e, const MyTimerVersionReq* v) {
    (void)v;
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerVersionReq(
        CborValue* it, MyTimerVersionReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    (void)out;
    return cbor_value_advance(it);
}
static inline CborError my_timer_enc_MyTimerLibVersionReq(
        CborEncoder* e, const MyTimerLibVersionReq* v) {
    (void)v;
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerLibVersionReq(
        CborValue* it, MyTimerLibVersionReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    (void)out;
    return cbor_value_advance(it);
}
static inline CborError my_timer_enc_MyTimerComplexReq(
        CborEncoder* e, const MyTimerComplexReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req");
    if (err) return err;
    err = my_timer_enc_ComplexRequest(&m, &v->req);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerComplexReq(
        CborValue* it, MyTimerComplexReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "req", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_ComplexRequest(&field, &out->req);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_MyTimerComplexReq(MyTimerComplexReq* v) {
    if (!v) return;
    my_timer_free_ComplexRequest(&v->req);
}
static inline CborError my_timer_enc_MyTimerScheduleReq(
        CborEncoder* e, const MyTimerScheduleReq* v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(e, &m, 3);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "job");
    if (err) return err;
    err = my_timer_enc_JobSpec(&m, &v->job);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "retry");
    if (err) return err;
    err = my_timer_enc_RetryPolicy(&m, &v->retry);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "schedule");
    if (err) return err;
    err = my_timer_enc_ScheduleConfig(&m, &v->schedule);
    if (err) return err;
    return cbor_encoder_close_container(e, &m);
}
static inline CborError my_timer_dec_MyTimerScheduleReq(
        CborValue* it, MyTimerScheduleReq* out) {
    if (!cbor_value_is_map(it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(it, "job", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_JobSpec(&field, &out->job);
    if (err) return err;
    err = cbor_value_map_find_value(it, "retry", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_RetryPolicy(&field, &out->retry);
    if (err) return err;
    err = cbor_value_map_find_value(it, "schedule", &field);
    if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = my_timer_dec_ScheduleConfig(&field, &out->schedule);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_MyTimerScheduleReq(MyTimerScheduleReq* v) {
    if (!v) return;
    my_timer_free_JobSpec(&v->job);
    my_timer_free_RetryPolicy(&v->retry);
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

/** Creates the FFIContext + MyTimer; async via chronos. */
int my_timer_create(const uint8_t* req_cbor, size_t req_cbor_len, void** ctx_out, uint64_t* req_id_out);
/** Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`. */
int my_timer_echo(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
/** Returns the library's version string. */
int my_timer_version(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
int my_timer_lib_version(const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
int my_timer_complex(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
/** Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope. */
int my_timer_schedule(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);
/** Tears down the FFI context; blocks until FFI + watchdog threads join. */
int my_timer_destroy(void* ctx);
/**
 * The token of the static context, where the replies of the static requests
 * arrive: poll it like any other context. Never destroy it; shutdown ends it.
 * NULL on failure, with the text in last_error().
 */
void* my_timer_static_ctx(void);
/**
 * Why the last request of the calling thread was refused. Thread-local, never
 * NULL, empty when nothing was refused, valid until that thread's next call into
 * the library. Owned by the library: never free it.
 */
const char* my_timer_last_error(void);
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
int my_timer_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);
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
intptr_t my_timer_poll_fd(void* ctx);
/**
 * Stop every context the library still holds and join their threads.
 * Call it before the process exits when a context is still alive, or when a
 * static proc built the shared context.
 * Returns 0 when every context stopped, 1 when one was left running.
 */
int my_timer_shutdown(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

/* CBOR buffer adapters (typed codec → void* driver signature) */
static inline CborError my_timer_encv_MyTimerCreateCtorReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerCreateCtorReq(e, (const MyTimerCreateCtorReq*)v); }
static inline CborError my_timer_encv_MyTimerEchoReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerEchoReq(e, (const MyTimerEchoReq*)v); }
static inline CborError my_timer_encv_MyTimerVersionReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerVersionReq(e, (const MyTimerVersionReq*)v); }
static inline CborError my_timer_encv_MyTimerLibVersionReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerLibVersionReq(e, (const MyTimerLibVersionReq*)v); }
static inline CborError my_timer_encv_MyTimerComplexReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerComplexReq(e, (const MyTimerComplexReq*)v); }
static inline CborError my_timer_encv_MyTimerScheduleReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerScheduleReq(e, (const MyTimerScheduleReq*)v); }
static inline CborError my_timer_decv_EchoResponse(CborValue* it, void* v) { return my_timer_dec_EchoResponse(it, (EchoResponse*)v); }
static inline CborError my_timer_decv_Str(CborValue* it, void* v) { return nimffi_dec_str(it, (const char**)v); }
static inline CborError my_timer_decv_ComplexResponse(CborValue* it, void* v) { return my_timer_dec_ComplexResponse(it, (ComplexResponse*)v); }
static inline CborError my_timer_decv_ScheduleResult(CborValue* it, void* v) { return my_timer_dec_ScheduleResult(it, (ScheduleResult*)v); }

/* ============================================================ */
/* my_timer API                                                 */
/* ============================================================ */
/* The library calls nothing back and the binding starts no thread: a reply,
 * an event or a liveness report reaches the host inside my_timer_ctx_pump_once(),
 * on the thread that calls it.
 *
 * Threads: a context of this binding is single-threaded by design. Submit and
 * pump it from one thread, or hold one lock around both. A host that wants
 * something else uses the raw my_timer_<proc>() and my_timer_poll() exports with the
 * decoders below.
 *
 * Context: my_timer_ctx_create_sync(), my_timer_ctx_create(), my_timer_ctx_destroy().
 *
 * Requests. Each has an asynchronous form, whose on_reply runs inside the pump;
 * a _sync form for a sequential program, which pumps until its own reply
 * arrives; and a decoder of the raw reply:
 *   my_timer_ctx_echo()  my_timer_ctx_echo_sync()  my_timer_decode_echo_reply()
 *   my_timer_ctx_version()  my_timer_ctx_version_sync()  my_timer_decode_version_reply()
 *   my_timer_ctx_complex()  my_timer_ctx_complex_sync()  my_timer_decode_complex_reply()
 *   my_timer_ctx_schedule()  my_timer_ctx_schedule_sync()  my_timer_decode_schedule_reply()
 *   my_timer_static_lib_version()  my_timer_static_lib_version_sync()  my_timer_decode_lib_version_reply()
 * The replies of the static requests arrive on the static context: my_timer_static_pump_once().
 *
 * on_reply(ret, reply, err, user_data) runs once, with `ret`:
 *   NIMFFI_RET_OK      `reply` is set and `err` is NULL
 *   NIMFFI_RET_ERR     the library answered with an error: `err` is its text
 *   NIMFFI_RET_CLOSED  the context closed before the reply came
 *   -1                 the reply did not decode: `err` says why
 * Submitting returns NIMFFI_RET_OK; or the code of the library's refusal, with
 * the text in my_timer_last_error(); or -1 when the binding could not encode the
 * request or is out of memory. After anything but NIMFFI_RET_OK nothing was
 * recorded and on_reply never runs.
 * A _sync form returns the same codes, and NIMFFI_RET_TIMEOUT when `timeout_ms`
 * passed first (negative waits forever; the late reply is then dropped). On
 * NIMFFI_RET_OK the caller owns `*out`; otherwise `*out` is zeroed and `*err`,
 * when `err` is not NULL, is a text the caller frees with free(). Every other
 * message that arrives meanwhile goes to `handlers`, which may be NULL.
 *
 * Messages from the library, each an entry of MyTimerHandlers. A handler may
 * submit requests, _sync ones included:
 *   on_echo_fired(const EchoEvent*)  MY_TIMER_EVT_ON_ECHO_FIRED
 *   on_job_scheduled(const OnJobScheduledPayload*)  MY_TIMER_EVT_ON_JOB_SCHEDULED
 *   stale_warn, not_responding, responding, closed
 */
typedef struct {
    void* ptr;             /* the library's token, for the raw exports */
    NimFfiPending pending; /* requests waiting for their reply */
} MyTimerCtx;

/* ---- events ---- */
/** Fired by `myTimerEcho` once the reply is ready. */
#define MY_TIMER_EVT_ON_ECHO_FIRED 0xcdfdf536356b2a2bULL  /* "on_echo_fired" */
/* Decodes the payload of a MY_TIMER_EVT_ON_ECHO_FIRED message.
 * Returns 0, or -1 when `msg` is not that event or does not decode.
 * On success the caller frees `out` with my_timer_free_EchoEvent(). */
static inline int my_timer_decode_on_echo_fired(const NimFfiMsg* msg, EchoEvent* out) {
    if (!msg || !out) return -1;
    if (msg->kind != NIMFFI_MSG_EVENT || msg->name_id != MY_TIMER_EVT_ON_ECHO_FIRED) return -1;
    memset(out, 0, sizeof(*out));
    CborParser parser;
    CborValue it;
    if (cbor_parser_init(msg->payload, msg->len, 0, &parser, &it) != CborNoError) return -1;
    if (my_timer_dec_EchoEvent(&it, out) != CborNoError) {
        my_timer_free_EchoEvent(out);
        return -1;
    }
    return 0;
}

/**
 * Fired by `myTimerSchedule`. Its two params ride the wire as a synthesised
 * `OnJobScheduledPayload` envelope, so the foreign side decodes one typed value.
 */
#define MY_TIMER_EVT_ON_JOB_SCHEDULED 0xd6ac432a40b9a85cULL  /* "on_job_scheduled" */
/* Decodes the payload of a MY_TIMER_EVT_ON_JOB_SCHEDULED message.
 * Returns 0, or -1 when `msg` is not that event or does not decode.
 * On success the caller frees `out` with my_timer_free_OnJobScheduledPayload(). */
static inline int my_timer_decode_on_job_scheduled(const NimFfiMsg* msg, OnJobScheduledPayload* out) {
    if (!msg || !out) return -1;
    if (msg->kind != NIMFFI_MSG_EVENT || msg->name_id != MY_TIMER_EVT_ON_JOB_SCHEDULED) return -1;
    memset(out, 0, sizeof(*out));
    CborParser parser;
    CborValue it;
    if (cbor_parser_init(msg->payload, msg->len, 0, &parser, &it) != CborNoError) return -1;
    if (my_timer_dec_OnJobScheduledPayload(&it, out) != CborNoError) {
        my_timer_free_OnJobScheduledPayload(out);
        return -1;
    }
    return 0;
}

/* ---- everything the library can send ---- */
/* Replies go to the on_reply of their request; the rest is listed here. A NULL
 * entry means "ignore". Each handler runs on the thread that pumps; what it is
 * handed belongs to the binding and is valid only until it returns. */
typedef struct {
    /** Fired by `myTimerEcho` once the reply is ready. */
    void (*on_echo_fired)(const EchoEvent* ev, void* user_data);
    /**
     * Fired by `myTimerSchedule`. Its two params ride the wire as a synthesised
     * `OnJobScheduledPayload` envelope, so the foreign side decodes one typed value.
     */
    void (*on_job_scheduled)(const OnJobScheduledPayload* ev, void* user_data);
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
} MyTimerHandlers;

/* Decodes `msg` fully, then calls its on_reply or its handler, then frees what
 * it decoded. Returns 0, also for an event this header does not know and for a
 * reply nobody waits for, or -1 on a decode error or an unknown message kind. */
static inline int my_timer_ctx_dispatch(MyTimerCtx* ctx, const NimFfiMsg* msg, const MyTimerHandlers* handlers) {
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
        if (msg->name_id == MY_TIMER_EVT_ON_ECHO_FIRED) {
            EchoEvent ev;
            if (my_timer_decode_on_echo_fired(msg, &ev) != 0) return -1;
            if (handlers && handlers->on_echo_fired) handlers->on_echo_fired(&ev, handlers->user_data);
            my_timer_free_EchoEvent(&ev);
            return 0;
        }
        if (msg->name_id == MY_TIMER_EVT_ON_JOB_SCHEDULED) {
            OnJobScheduledPayload ev;
            if (my_timer_decode_on_job_scheduled(msg, &ev) != 0) return -1;
            if (handlers && handlers->on_job_scheduled) handlers->on_job_scheduled(&ev, handlers->user_data);
            my_timer_free_OnJobScheduledPayload(&ev);
            return 0;
        }
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

/* One my_timer_poll() and the dispatch of what it returned.
 * Returns the poll code (NIMFFI_RET_OK, _TIMEOUT, _CLOSED after the `closed`
 * handler ran, _INVALID_CTX, _BUSY, _ERR), or -1 when the message did not
 * dispatch. `ctx` must stay alive for the whole call: stop pumping before
 * my_timer_ctx_destroy(). */
static inline int my_timer_ctx_pump_once(MyTimerCtx* ctx, int32_t timeout_ms, const MyTimerHandlers* handlers) {
    if (!ctx) return NIMFFI_RET_INVALID_CTX;
    const NimFfiMsg* msg = NULL;
    int rc = my_timer_poll(ctx->ptr, timeout_ms, &msg);
    if (rc != NIMFFI_RET_OK && rc != NIMFFI_RET_CLOSED) return rc;
    if (my_timer_ctx_dispatch(ctx, msg, handlers) != 0) return -1;
    return rc;
}

/* See my_timer_poll_fd(): the caller owns and closes the handle. */
static inline intptr_t my_timer_ctx_poll_fd(const MyTimerCtx* ctx) {
    if (!ctx) return -1;
    return my_timer_poll_fd(ctx->ptr);
}

/* Pumps `ctx` until `slot` is settled, handing every other message to
 * `handlers`. A request given up on is forgotten, so that its late reply is
 * dropped instead of written into a stack frame that is gone. */
static inline int my_timer_ctx_await_(MyTimerCtx* ctx, uint64_t req_id, const NimFfiSyncSlot* slot, int32_t timeout_ms, const MyTimerHandlers* handlers) {
    int64_t deadline = 0;
    if (timeout_ms >= 0) deadline = nimffi_now_ms() + timeout_ms;
    while (!slot->done) {
        int32_t wait_ms = -1;
        if (timeout_ms >= 0) {
            int64_t left = deadline - nimffi_now_ms();
            wait_ms = left > 0 ? (int32_t)left : 0;
        }
        int rc = my_timer_ctx_pump_once(ctx, wait_ms, handlers);
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
NIMFFI_SHARED MyTimerCtx my_timer_static_binding_ = {NULL, {NULL, 0, 0}};

static inline MyTimerCtx* my_timer_static_(void) {
    /* Asked every time: my_timer_shutdown() ends the static context, and the
     * next static request starts a new one. */
    my_timer_static_binding_.ptr = my_timer_static_ctx();
    return &my_timer_static_binding_;
}

/* my_timer_ctx_pump_once() on the static context: delivers the replies of the
 * my_timer_static_*() requests. */
static inline int my_timer_static_pump_once(int32_t timeout_ms, const MyTimerHandlers* handlers) {
    return my_timer_ctx_pump_once(my_timer_static_(), timeout_ms, handlers);
}

/* ---- context ---- */
/* Requests still waiting are settled with NIMFFI_RET_CLOSED, after the library
 * let go of the context. Never call it from a handler or an on_reply of `ctx`. */
/** Tears down the FFI context; blocks until FFI + watchdog threads join. */
static inline int my_timer_ctx_destroy(MyTimerCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    if (ctx->ptr) { rc = my_timer_destroy(ctx->ptr); ctx->ptr = NULL; }
    nimffi_pending_close(&ctx->pending);
    /* A callback above may have made room for a request that was refused. */
    free(ctx->pending.items);
    free(ctx);
    return rc;
}

/* `ret` as for a request's on_reply. The context is the caller's whatever `ret`
 * says: release it with my_timer_ctx_destroy(). */
typedef void (*MyTimerCreateFn)(int ret, const char* err, void* user_data);
static inline void my_timer_create_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    MyTimerCreateFn on_created = (MyTimerCreateFn)fn;
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
static inline void my_timer_create_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = nimffi_reply_status(msg, slot->err);
    slot->done = true;
}
static inline int my_timer_create_submit_(const TimerConfig* config, MyTimerCtx** ctx_out, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    MyTimerCreateCtorReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.config = *config;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerCreateCtorReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    MyTimerCtx* ctx = (MyTimerCtx*)calloc(1, sizeof(MyTimerCtx));
    if (!ctx || nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (ctx) free(ctx->pending.items);
        free(ctx);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = my_timer_create(req_buf, req_len, &ctx->ptr, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(my_timer_last_error());
        if (ctx) free(ctx->pending.items);
        free(ctx);
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    *ctx_out = ctx;
    return NIMFFI_RET_OK;
}
/** Creates the FFIContext + MyTimer; async via chronos. */
static inline int my_timer_ctx_create(const TimerConfig* config, MyTimerCtx** ctx_out, MyTimerCreateFn on_created, void* user_data) {
    if (!ctx_out) return -1;
    *ctx_out = NULL;
    uint64_t req_id = 0;
    return my_timer_create_submit_(config, ctx_out, my_timer_create_settle_, (nimffi_generic_fn)on_created, user_data, &req_id, NULL);
}
/** Creates the FFIContext + MyTimer; async via chronos. */
static inline int my_timer_ctx_create_sync(const TimerConfig* config, MyTimerCtx** out, char** err, int32_t timeout_ms) {
    if (err) *err = NULL;
    if (!out) return -1;
    *out = NULL;
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, NULL, err};
    MyTimerCtx* ctx = NULL;
    uint64_t req_id = 0;
    int rc = my_timer_create_submit_(config, &ctx, my_timer_create_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    rc = my_timer_ctx_await_(ctx, req_id, &slot, timeout_ms, NULL);
    if (rc != NIMFFI_RET_OK) {
        /* The slot is claimed even when construction failed. */
        (void)my_timer_ctx_destroy(ctx);
        return rc;
    }
    *out = ctx;
    return NIMFFI_RET_OK;
}

/* ---- requests ---- */
typedef void (*MyTimerEchoReplyFn)(int ret, const EchoResponse* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers my_timer_echo(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `out` with my_timer_free_EchoResponse(). */
static inline int my_timer_decode_echo_reply(const NimFfiMsg* msg, EchoResponse* out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, my_timer_decv_EchoResponse, out, err);
    if (rc == -1 && out) my_timer_free_EchoResponse(out);
    return rc;
}
static inline void my_timer_echo_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    MyTimerEchoReplyFn on_reply = (MyTimerEchoReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    EchoResponse out;
    char* err = NULL;
    int rc = my_timer_decode_echo_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    my_timer_free_EchoResponse(&out);
}
static inline void my_timer_echo_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = my_timer_decode_echo_reply(msg, (EchoResponse*)slot->out, slot->err);
    slot->done = true;
}
static inline int my_timer_echo_submit_(MyTimerCtx* ctx, const EchoRequest* req, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    if (!ctx) {
        if (err) *err = nimffi_dup_cstr("ctx is NULL");
        return NIMFFI_RET_INVALID_CTX;
    }
    MyTimerEchoReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerEchoReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = my_timer_echo(ctx->ptr, req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(my_timer_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
/** Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`. */
static inline int my_timer_ctx_echo(MyTimerCtx* ctx, const EchoRequest* req, MyTimerEchoReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = my_timer_echo_submit_(ctx, req, my_timer_echo_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
/** Sleeps `delayMs` then echoes the message back, firing `on_echo_fired`. */
static inline int my_timer_ctx_echo_sync(MyTimerCtx* ctx, const EchoRequest* req, EchoResponse* out, char** err, int32_t timeout_ms, const MyTimerHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = my_timer_echo_submit_(ctx, req, my_timer_echo_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return my_timer_ctx_await_(ctx, req_id, &slot, timeout_ms, handlers);
}

typedef void (*MyTimerVersionReplyFn)(int ret, const char* const* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers my_timer_version(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `*out` with free(). */
static inline int my_timer_decode_version_reply(const NimFfiMsg* msg, const char** out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, my_timer_decv_Str, out, err);
    if (rc == -1 && out) do { free((void*)*out); *out = NULL; } while (0);
    return rc;
}
static inline void my_timer_version_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    MyTimerVersionReplyFn on_reply = (MyTimerVersionReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    const char* out;
    char* err = NULL;
    int rc = my_timer_decode_version_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    do { free((void*)out); out = NULL; } while (0);
}
static inline void my_timer_version_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = my_timer_decode_version_reply(msg, (const char**)slot->out, slot->err);
    slot->done = true;
}
static inline int my_timer_version_submit_(MyTimerCtx* ctx, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    if (!ctx) {
        if (err) *err = nimffi_dup_cstr("ctx is NULL");
        return NIMFFI_RET_INVALID_CTX;
    }
    MyTimerVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerVersionReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = my_timer_version(ctx->ptr, req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(my_timer_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
/** Returns the library's version string. */
static inline int my_timer_ctx_version(MyTimerCtx* ctx, MyTimerVersionReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = my_timer_version_submit_(ctx, my_timer_version_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
/** Returns the library's version string. */
static inline int my_timer_ctx_version_sync(MyTimerCtx* ctx, const char** out, char** err, int32_t timeout_ms, const MyTimerHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = my_timer_version_submit_(ctx, my_timer_version_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return my_timer_ctx_await_(ctx, req_id, &slot, timeout_ms, handlers);
}

typedef void (*MyTimerComplexReplyFn)(int ret, const ComplexResponse* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers my_timer_complex(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `out` with my_timer_free_ComplexResponse(). */
static inline int my_timer_decode_complex_reply(const NimFfiMsg* msg, ComplexResponse* out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, my_timer_decv_ComplexResponse, out, err);
    if (rc == -1 && out) my_timer_free_ComplexResponse(out);
    return rc;
}
static inline void my_timer_complex_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    MyTimerComplexReplyFn on_reply = (MyTimerComplexReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    ComplexResponse out;
    char* err = NULL;
    int rc = my_timer_decode_complex_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    my_timer_free_ComplexResponse(&out);
}
static inline void my_timer_complex_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = my_timer_decode_complex_reply(msg, (ComplexResponse*)slot->out, slot->err);
    slot->done = true;
}
static inline int my_timer_complex_submit_(MyTimerCtx* ctx, const ComplexRequest* req, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    if (!ctx) {
        if (err) *err = nimffi_dup_cstr("ctx is NULL");
        return NIMFFI_RET_INVALID_CTX;
    }
    MyTimerComplexReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerComplexReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = my_timer_complex(ctx->ptr, req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(my_timer_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
static inline int my_timer_ctx_complex(MyTimerCtx* ctx, const ComplexRequest* req, MyTimerComplexReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = my_timer_complex_submit_(ctx, req, my_timer_complex_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
static inline int my_timer_ctx_complex_sync(MyTimerCtx* ctx, const ComplexRequest* req, ComplexResponse* out, char** err, int32_t timeout_ms, const MyTimerHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = my_timer_complex_submit_(ctx, req, my_timer_complex_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return my_timer_ctx_await_(ctx, req_id, &slot, timeout_ms, handlers);
}

typedef void (*MyTimerScheduleReplyFn)(int ret, const ScheduleResult* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers my_timer_schedule(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `out` with my_timer_free_ScheduleResult(). */
static inline int my_timer_decode_schedule_reply(const NimFfiMsg* msg, ScheduleResult* out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, my_timer_decv_ScheduleResult, out, err);
    if (rc == -1 && out) my_timer_free_ScheduleResult(out);
    return rc;
}
static inline void my_timer_schedule_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    MyTimerScheduleReplyFn on_reply = (MyTimerScheduleReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    ScheduleResult out;
    char* err = NULL;
    int rc = my_timer_decode_schedule_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    my_timer_free_ScheduleResult(&out);
}
static inline void my_timer_schedule_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = my_timer_decode_schedule_reply(msg, (ScheduleResult*)slot->out, slot->err);
    slot->done = true;
}
static inline int my_timer_schedule_submit_(MyTimerCtx* ctx, const JobSpec* job, const RetryPolicy* retry, const ScheduleConfig* schedule, nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    if (!ctx) {
        if (err) *err = nimffi_dup_cstr("ctx is NULL");
        return NIMFFI_RET_INVALID_CTX;
    }
    MyTimerScheduleReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.job = *job;
    ffi_req.retry = *retry;
    ffi_req.schedule = *schedule;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerScheduleReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = my_timer_schedule(ctx->ptr, req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(my_timer_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
/** Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope. */
static inline int my_timer_ctx_schedule(MyTimerCtx* ctx, const JobSpec* job, const RetryPolicy* retry, const ScheduleConfig* schedule, MyTimerScheduleReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = my_timer_schedule_submit_(ctx, job, retry, schedule, my_timer_schedule_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
/** Three object-typed params (`job`, `retry`, `schedule`) packed into one CBOR envelope. */
static inline int my_timer_ctx_schedule_sync(MyTimerCtx* ctx, const JobSpec* job, const RetryPolicy* retry, const ScheduleConfig* schedule, ScheduleResult* out, char** err, int32_t timeout_ms, const MyTimerHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = my_timer_schedule_submit_(ctx, job, retry, schedule, my_timer_schedule_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return my_timer_ctx_await_(ctx, req_id, &slot, timeout_ms, handlers);
}

typedef void (*MyTimerLibVersionReplyFn)(int ret, const char* const* reply, const char* err, void* user_data);
/* Decodes the NIMFFI_MSG_REPLY that answers my_timer_lib_version(); the caller matches
 * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR
 * with the library's error text in `*err`; or -1 when `msg` is not a reply or
 * does not decode, `*err` saying why. `*err` is freed with free().
 * On success the caller frees `*out` with free(). */
static inline int my_timer_decode_lib_version_reply(const NimFfiMsg* msg, const char** out, char** err) {
    if (out) memset(out, 0, sizeof(*out));
    int rc = nimffi_decode_reply(msg, my_timer_decv_Str, out, err);
    if (rc == -1 && out) do { free((void*)*out); *out = NULL; } while (0);
    return rc;
}
static inline void my_timer_lib_version_settle_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    MyTimerLibVersionReplyFn on_reply = (MyTimerLibVersionReplyFn)fn;
    if (!on_reply) return;
    if (!msg) {
        on_reply(NIMFFI_RET_CLOSED, NULL, "context closed", user_data);
        return;
    }
    const char* out;
    char* err = NULL;
    int rc = my_timer_decode_lib_version_reply(msg, &out, &err);
    if (rc != NIMFFI_RET_OK) {
        on_reply(rc, NULL, err ? err : "", user_data);
        free(err);
        return;
    }
    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);
    do { free((void*)out); out = NULL; } while (0);
}
static inline void my_timer_lib_version_settle_sync_(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {
    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;
    (void)fn;
    if (!msg) {
        nimffi_sync_slot_closed(slot);
        return;
    }
    slot->ret = my_timer_decode_lib_version_reply(msg, (const char**)slot->out, slot->err);
    slot->done = true;
}
static inline int my_timer_lib_version_submit_(nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {
    MyTimerLibVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerLibVersionReq, &ffi_req, &req_buf, &req_len, err) != 0) return -1;
    MyTimerCtx* ctx = my_timer_static_();
    if (nimffi_pending_reserve(&ctx->pending) != 0) {
        free(req_buf);
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    int rc = my_timer_lib_version(req_buf, req_len, req_id_out);
    free(req_buf);
    if (rc != NIMFFI_RET_OK) {
        if (err) *err = nimffi_dup_cstr(my_timer_last_error());
        return rc;
    }
    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};
    nimffi_pending_add(&ctx->pending, entry);
    return NIMFFI_RET_OK;
}
static inline int my_timer_static_lib_version(MyTimerLibVersionReplyFn on_reply, void* user_data, uint64_t* req_id_out) {
    uint64_t req_id = 0;
    if (req_id_out) *req_id_out = 0;
    const int rc_ = my_timer_lib_version_submit_(my_timer_lib_version_settle_, (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);
    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;
    return rc_;
}
static inline int my_timer_static_lib_version_sync(const char** out, char** err, int32_t timeout_ms, const MyTimerHandlers* handlers) {
    if (err) *err = NULL;
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};
    uint64_t req_id = 0;
    int rc = my_timer_lib_version_submit_(my_timer_lib_version_settle_sync_, NULL, &slot, &req_id, err);
    if (rc != NIMFFI_RET_OK) return rc;
    return my_timer_ctx_await_(my_timer_static_(), req_id, &slot, timeout_ms, handlers);
}

#endif /* NIM_FFI_LIB_MY_TIMER_H_INCLUDED */
