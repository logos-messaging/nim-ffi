#ifndef NIM_FFI_LIB_MY_TIMER_H_INCLUDED
#define NIM_FFI_LIB_MY_TIMER_H_INCLUDED
#include "nim_ffi_cbor.h"

/* ============================================================ */
/* Generated types (user-declared + per-proc request envelopes) */
/* ============================================================ */

typedef struct {
    NimFfiStr name;
} TimerConfig;
typedef struct {
    NimFfiStr message;
    int64_t delayMs;
} EchoRequest;
typedef struct {
    NimFfiStr echoed;
    NimFfiStr timerName;
} EchoResponse;
typedef struct {
    EchoRequest* data;
    size_t len;
} MyTimerSeq_EchoRequest;
typedef struct {
    NimFfiStr* data;
    size_t len;
} MyTimerSeq_Str;
typedef struct {
    bool has_value;
    NimFfiStr value;
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
    NimFfiStr summary;
    int64_t itemCount;
    bool hasNote;
} ComplexResponse;
typedef struct {
    NimFfiStr message;
    int64_t echoCount;
} EchoEvent;
typedef struct {
    NimFfiStr name;
    MyTimerSeq_Str payload;
    int64_t priority;
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
    NimFfiStr jobId;
    int64_t willRunCount;
    int64_t firstRunAtMs;
    int64_t effectiveBackoffMs;
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
    nimffi_free_str(&v->name);
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
    nimffi_free_str(&v->message);
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
    nimffi_free_str(&v->echoed);
    nimffi_free_str(&v->timerName);
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
    out->data = (NimFfiStr*)calloc(len ? len : 1, sizeof(NimFfiStr));
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
    for (size_t i = 0; i < v->len; i++) nimffi_free_str(&v->data[i]);
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
    nimffi_free_str(&v->value);
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
    nimffi_free_str(&v->summary);
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
    nimffi_free_str(&v->message);
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
    err = nimffi_enc_i64(&m, &v->priority);
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
    err = nimffi_dec_i64(&field, &out->priority);
    if (err) return err;
    return cbor_value_advance(it);
}
static inline void my_timer_free_JobSpec(JobSpec* v) {
    if (!v) return;
    nimffi_free_str(&v->name);
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
    CborError err = cbor_encoder_create_map(e, &m, 4);
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
    return cbor_value_advance(it);
}
static inline void my_timer_free_ScheduleResult(ScheduleResult* v) {
    if (!v) return;
    nimffi_free_str(&v->jobId);
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

void* my_timer_create(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);
int my_timer_echo(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_version(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_complex(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_schedule(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int my_timer_destroy(void* ctx);
uint64_t my_timer_add_event_listener(void* ctx, const char* event_name, FFICallback callback, void* user_data);
int my_timer_remove_event_listener(void* ctx, uint64_t listener_id);

#ifdef __cplusplus
} /* extern "C" */
#endif

/* CBOR buffer adapters (typed codec → void* driver signature) */
static inline CborError my_timer_encv_MyTimerCreateCtorReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerCreateCtorReq(e, (const MyTimerCreateCtorReq*)v); }
static inline CborError my_timer_encv_MyTimerEchoReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerEchoReq(e, (const MyTimerEchoReq*)v); }
static inline CborError my_timer_encv_MyTimerVersionReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerVersionReq(e, (const MyTimerVersionReq*)v); }
static inline CborError my_timer_encv_MyTimerComplexReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerComplexReq(e, (const MyTimerComplexReq*)v); }
static inline CborError my_timer_encv_MyTimerScheduleReq(CborEncoder* e, const void* v) { return my_timer_enc_MyTimerScheduleReq(e, (const MyTimerScheduleReq*)v); }
static inline CborError my_timer_decv_EchoResponse(CborValue* it, void* v) { return my_timer_dec_EchoResponse(it, (EchoResponse*)v); }
static inline CborError my_timer_decv_Str(CborValue* it, void* v) { return nimffi_dec_str(it, (NimFfiStr*)v); }
static inline CborError my_timer_decv_ComplexResponse(CborValue* it, void* v) { return my_timer_dec_ComplexResponse(it, (ComplexResponse*)v); }
static inline CborError my_timer_decv_ScheduleResult(CborValue* it, void* v) { return my_timer_dec_ScheduleResult(it, (ScheduleResult*)v); }

/* Event listener machinery */
typedef void (*MyTimerOnEchoFiredFn)(const EchoEvent* evt, void* user_data);
typedef struct { MyTimerOnEchoFiredFn fn; void* user_data; } MyTimerOnEchoFiredBox;
static void my_timer_on_echo_fired_trampoline(int ret, const char* msg, size_t len, void* ud) {
    if (!ud || ret != 0 || !msg || len == 0) return;
    MyTimerOnEchoFiredBox* box = (MyTimerOnEchoFiredBox*)ud;
    if (!box->fn) return;
    CborParser parser;
    CborValue it;
    if (cbor_parser_init((const uint8_t*)msg, len, 0, &parser, &it) != CborNoError) return;
    if (!cbor_value_is_map(&it)) return;
    CborValue payloadField;
    if (cbor_value_map_find_value(&it, "payload", &payloadField) != CborNoError) return;
    EchoEvent payload;
    memset(&payload, 0, sizeof(payload));
    if (my_timer_dec_EchoEvent(&payloadField, &payload) != CborNoError) return;
    box->fn(&payload, box->user_data);
    my_timer_free_EchoEvent(&payload);
}

/* ============================================================ */
/* High-level context wrapper                                   */
/* ============================================================ */
typedef struct {
    uint64_t id;
    void* box;
} MyTimerCtxListener;

typedef struct {
    void* ptr;
    MyTimerCtxListener* listeners;
    size_t listeners_len;
    size_t listeners_cap;
} MyTimerCtx;

typedef void (*MyTimerCreateFn)(int err_code, MyTimerCtx* ctx, const char* err_msg, void* user_data);
typedef struct { MyTimerCreateFn fn; void* user_data; } MyTimerCreateBox;
static void my_timer_create_trampoline(int ret, const char* msg, size_t len, void* ud) {
    MyTimerCreateBox* box = (MyTimerCreateBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI create failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    NimFfiStr addr;
    memset(&addr, 0, sizeof(addr));
    if (nimffi_decode_from_buf(my_timer_decv_Str, (const uint8_t*)msg, len, &addr, &err) != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        free(box);
        return;
    }
    char* endp = NULL;
    unsigned long long a = addr.data ? strtoull(addr.data, &endp, 10) : 0;
    bool ok = addr.data && addr.len > 0 && endp && *endp == '\0';
    nimffi_free_str(&addr);
    if (!ok) {
        box->fn(-1, NULL, "FFI create returned non-numeric address", box->user_data);
        free(box);
        return;
    }
    MyTimerCtx* ctx = (MyTimerCtx*)calloc(1, sizeof(MyTimerCtx));
    if (!ctx) {
        box->fn(-1, NULL, "out of memory", box->user_data);
        free(box);
        return;
    }
    ctx->ptr = (void*)(uintptr_t)a;
    box->fn(NIMFFI_RET_OK, ctx, NULL, box->user_data);
    free(box);
}

static inline int my_timer_ctx_create(const TimerConfig* config, MyTimerCreateFn on_created, void* user_data) {
    MyTimerCreateCtorReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.config = *config;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerCreateCtorReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_created) on_created(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    MyTimerCreateBox* box = (MyTimerCreateBox*)malloc(sizeof(MyTimerCreateBox));
    if (!box) {
        free(req_buf);
        if (on_created) on_created(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_created;
    box->user_data = user_data;
    (void)my_timer_create(req_buf, req_len, my_timer_create_trampoline, box);
    free(req_buf);
    return 0;
}

static inline int my_timer_ctx_destroy(MyTimerCtx* ctx) {
    if (!ctx) return NIMFFI_RET_OK;
    int rc = NIMFFI_RET_OK;
    if (ctx->ptr) { rc = my_timer_destroy(ctx->ptr); ctx->ptr = NULL; }
    if (rc == NIMFFI_RET_OK) {
        for (size_t i = 0; i < ctx->listeners_len; i++) free(ctx->listeners[i].box);
    }
    free(ctx->listeners);
    free(ctx);
    return rc;
}

static inline uint64_t my_timer_ctx_add_on_echo_fired_listener(MyTimerCtx* ctx, MyTimerOnEchoFiredFn fn, void* user_data) {
    MyTimerOnEchoFiredBox* box = (MyTimerOnEchoFiredBox*)malloc(sizeof(MyTimerOnEchoFiredBox));
    if (!box) return 0;
    box->fn = fn;
    box->user_data = user_data;
    uint64_t id = my_timer_add_event_listener(ctx->ptr, "on_echo_fired", my_timer_on_echo_fired_trampoline, box);
    if (id == 0) { free(box); return 0; }
    if (ctx->listeners_len == ctx->listeners_cap) {
        size_t ncap = ctx->listeners_cap ? ctx->listeners_cap * 2 : 4;
        MyTimerCtxListener* grown = (MyTimerCtxListener*)realloc(ctx->listeners, ncap * sizeof(MyTimerCtxListener));
        if (!grown) { my_timer_remove_event_listener(ctx->ptr, id); free(box); return 0; }
        ctx->listeners = grown;
        ctx->listeners_cap = ncap;
    }
    ctx->listeners[ctx->listeners_len].id = id;
    ctx->listeners[ctx->listeners_len].box = box;
    ctx->listeners_len++;
    return id;
}

static inline bool my_timer_ctx_remove_event_listener(MyTimerCtx* ctx, uint64_t id) {
    if (id == 0) return false;
    int rc = my_timer_remove_event_listener(ctx->ptr, id);
    for (size_t i = 0; i < ctx->listeners_len; i++) {
        if (ctx->listeners[i].id == id) {
            free(ctx->listeners[i].box);
            ctx->listeners[i] = ctx->listeners[ctx->listeners_len - 1];
            ctx->listeners_len--;
            break;
        }
    }
    return rc == 0;
}

typedef void (*MyTimerEchoReplyFn)(int err_code, const EchoResponse* reply, const char* err_msg, void* user_data);
typedef struct { MyTimerEchoReplyFn fn; void* user_data; } MyTimerEchoCallBox;
static void my_timer_echo_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    MyTimerEchoCallBox* box = (MyTimerEchoCallBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI call failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    EchoResponse out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(my_timer_decv_EchoResponse, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        my_timer_free_EchoResponse(&out);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    my_timer_free_EchoResponse(&out);
    free(box);
}
static inline int my_timer_ctx_echo(const MyTimerCtx* ctx, const EchoRequest* req, MyTimerEchoReplyFn on_reply, void* user_data) {
    MyTimerEchoReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerEchoReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_reply) on_reply(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    MyTimerEchoCallBox* box = (MyTimerEchoCallBox*)malloc(sizeof(MyTimerEchoCallBox));
    if (!box) {
        free(req_buf);
        if (on_reply) on_reply(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    int ret = my_timer_echo(ctx->ptr, my_timer_echo_reply_trampoline, box, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        if (on_reply) on_reply(-1, NULL, "RET_MISSING_CALLBACK (internal error)", user_data);
        free(box);
        return -1;
    }
    return 0;
}

typedef void (*MyTimerVersionReplyFn)(int err_code, const NimFfiStr* reply, const char* err_msg, void* user_data);
typedef struct { MyTimerVersionReplyFn fn; void* user_data; } MyTimerVersionCallBox;
static void my_timer_version_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    MyTimerVersionCallBox* box = (MyTimerVersionCallBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI call failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    NimFfiStr out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(my_timer_decv_Str, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        nimffi_free_str(&out);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    nimffi_free_str(&out);
    free(box);
}
static inline int my_timer_ctx_version(const MyTimerCtx* ctx, MyTimerVersionReplyFn on_reply, void* user_data) {
    MyTimerVersionReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerVersionReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_reply) on_reply(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    MyTimerVersionCallBox* box = (MyTimerVersionCallBox*)malloc(sizeof(MyTimerVersionCallBox));
    if (!box) {
        free(req_buf);
        if (on_reply) on_reply(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    int ret = my_timer_version(ctx->ptr, my_timer_version_reply_trampoline, box, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        if (on_reply) on_reply(-1, NULL, "RET_MISSING_CALLBACK (internal error)", user_data);
        free(box);
        return -1;
    }
    return 0;
}

typedef void (*MyTimerComplexReplyFn)(int err_code, const ComplexResponse* reply, const char* err_msg, void* user_data);
typedef struct { MyTimerComplexReplyFn fn; void* user_data; } MyTimerComplexCallBox;
static void my_timer_complex_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    MyTimerComplexCallBox* box = (MyTimerComplexCallBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI call failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    ComplexResponse out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(my_timer_decv_ComplexResponse, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        my_timer_free_ComplexResponse(&out);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    my_timer_free_ComplexResponse(&out);
    free(box);
}
static inline int my_timer_ctx_complex(const MyTimerCtx* ctx, const ComplexRequest* req, MyTimerComplexReplyFn on_reply, void* user_data) {
    MyTimerComplexReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.req = *req;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerComplexReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_reply) on_reply(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    MyTimerComplexCallBox* box = (MyTimerComplexCallBox*)malloc(sizeof(MyTimerComplexCallBox));
    if (!box) {
        free(req_buf);
        if (on_reply) on_reply(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    int ret = my_timer_complex(ctx->ptr, my_timer_complex_reply_trampoline, box, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        if (on_reply) on_reply(-1, NULL, "RET_MISSING_CALLBACK (internal error)", user_data);
        free(box);
        return -1;
    }
    return 0;
}

typedef void (*MyTimerScheduleReplyFn)(int err_code, const ScheduleResult* reply, const char* err_msg, void* user_data);
typedef struct { MyTimerScheduleReplyFn fn; void* user_data; } MyTimerScheduleCallBox;
static void my_timer_schedule_reply_trampoline(int ret, const char* msg, size_t len, void* ud) {
    MyTimerScheduleCallBox* box = (MyTimerScheduleCallBox*)ud;
    /* Non-terminal progress ping: keep the box for the terminal reply. */
    if (ret == NIMFFI_RET_STALE_WARN) return;
    if (!box->fn) {
        free(box);
        return;
    }
    if (ret != 0) {
        char* em = nimffi_dup_cstr_n(msg ? msg : "", msg ? len : 0);
        box->fn(ret, NULL, em ? em : "FFI call failed", box->user_data);
        free(em);
        free(box);
        return;
    }
    char* err = NULL;
    ScheduleResult out;
    memset(&out, 0, sizeof(out));
    int dec = nimffi_decode_from_buf(my_timer_decv_ScheduleResult, (const uint8_t*)msg, len, &out, &err);
    if (dec != 0) {
        box->fn(-1, NULL, err ? err : "decode failed", box->user_data);
        free(err);
        my_timer_free_ScheduleResult(&out);
        free(box);
        return;
    }
    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);
    my_timer_free_ScheduleResult(&out);
    free(box);
}
static inline int my_timer_ctx_schedule(const MyTimerCtx* ctx, const JobSpec* job, const RetryPolicy* retry, const ScheduleConfig* schedule, MyTimerScheduleReplyFn on_reply, void* user_data) {
    MyTimerScheduleReq ffi_req;
    memset(&ffi_req, 0, sizeof(ffi_req));
    ffi_req.job = *job;
    ffi_req.retry = *retry;
    ffi_req.schedule = *schedule;
    uint8_t* req_buf = NULL;
    size_t req_len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf(my_timer_encv_MyTimerScheduleReq, &ffi_req, &req_buf, &req_len, &err) != 0) {
        if (on_reply) on_reply(-1, NULL, err ? err : "encode failed", user_data);
        free(err);
        return -1;
    }
    MyTimerScheduleCallBox* box = (MyTimerScheduleCallBox*)malloc(sizeof(MyTimerScheduleCallBox));
    if (!box) {
        free(req_buf);
        if (on_reply) on_reply(-1, NULL, "out of memory", user_data);
        return -1;
    }
    box->fn = on_reply;
    box->user_data = user_data;
    int ret = my_timer_schedule(ctx->ptr, my_timer_schedule_reply_trampoline, box, req_buf, req_len);
    free(req_buf);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        if (on_reply) on_reply(-1, NULL, "RET_MISSING_CALLBACK (internal error)", user_data);
        free(box);
        return -1;
    }
    return 0;
}

#endif /* NIM_FFI_LIB_MY_TIMER_H_INCLUDED */
