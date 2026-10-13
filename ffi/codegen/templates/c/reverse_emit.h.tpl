static inline int {{LIB}}_ctx_emit_{{WIRE}}(const {{CTX}}* ctx, const {{REQ}}* payload) {
    uint8_t* buf = NULL;
    size_t len = 0;
    char* err = NULL;
    if (nimffi_encode_to_buf({{LIB}}_encv_{{TOKEN}}, payload, &buf, &len, &err) != 0) {
        free(err);
        return -1;
    }
    int rc = {{LIB}}_emit_{{WIRE}}(ctx->ptr, buf, len);
    free(buf);
    return rc;
}
