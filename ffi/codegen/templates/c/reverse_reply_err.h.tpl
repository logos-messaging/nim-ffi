static inline int {{LIB}}_reverse_reply_err(void* ctx, uint64_t call_id, const char* msg) {
    return {{LIB}}_reverse_reply(ctx, call_id, 1, (const uint8_t*)msg, msg ? strlen(msg) : 0);
}
/* Only while ctx is alive: a deferred reply uses the impl's ctx token. */
static inline int {{LIB}}_ctx_reverse_reply_err(const {{CTX}}* ctx, uint64_t call_id, const char* msg) {
    return {{LIB}}_reverse_reply_err(ctx->ptr, call_id, msg);
}
