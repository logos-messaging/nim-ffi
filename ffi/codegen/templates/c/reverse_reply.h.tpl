static inline int {{LIB}}_ctx_reverse_reply_{{WIRE}}(const {{CTX}}* ctx, uint64_t call_id, const {{REPLY}}* reply) {
    uint8_t* buf = NULL;
    size_t len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf({{LIB}}_encv_{{TOKEN}}, reply, &buf, &len, &err) != 0) {
        free(err);
        return -1;
    }
    int rc = {{LIB}}_reverse_reply(ctx->ptr, call_id, 0, buf, len);
    free(buf);
    return rc;
}
