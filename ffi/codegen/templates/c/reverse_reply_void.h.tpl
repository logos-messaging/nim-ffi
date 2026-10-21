static inline int {{LIB}}_reverse_reply_{{WIRE}}(void* ctx, uint64_t call_id) {
    return {{LIB}}_reverse_reply(ctx, call_id, 0, NULL, 0);
}
/* Only while ctx is alive: a deferred reply uses the impl's ctx token. */
static inline int {{LIB}}_ctx_reverse_reply_{{WIRE}}(const {{CTX}}* ctx, uint64_t call_id) {
    return {{LIB}}_reverse_reply_{{WIRE}}(ctx->ptr, call_id);
}
