static inline int {{LIB}}_ctx_reverse_reply_err(const {{CTX}}* ctx, uint64_t call_id, const char* msg) {
    return {{LIB}}_reverse_reply(ctx->ptr, call_id, 1, (const uint8_t*)msg, msg ? strlen(msg) : 0);
}
