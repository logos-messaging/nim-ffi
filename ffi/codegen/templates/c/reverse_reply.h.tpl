static inline int {{LIB}}_reverse_reply_{{WIRE}}(void* ctx, uint64_t call_id, const {{REPLY}}* reply) {
    uint8_t* buf = NULL;
    size_t len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf({{LIB}}_encv_{{TOKEN}}, reply, &buf, &len, &err) != 0) {
        free(err);
        return -1;
    }
    int rc = {{LIB}}_reverse_reply(ctx, call_id, 0, buf, len);
    free(buf);
    return rc;
}
/* Only while ctx is alive: a deferred reply uses the impl's ctx token. */
static inline int {{LIB}}_ctx_reverse_reply_{{WIRE}}(const {{CTX}}* ctx, uint64_t call_id, const {{REPLY}}* reply) {
    return {{LIB}}_reverse_reply_{{WIRE}}(ctx->ptr, call_id, reply);
}
