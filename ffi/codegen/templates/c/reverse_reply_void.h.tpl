static inline int {{LIB}}_ctx_reverse_reply_{{WIRE}}(const {{CTX}}* ctx, uint64_t call_id) {
    return {{LIB}}_reverse_reply(ctx->ptr, call_id, 0, NULL, 0);
}
