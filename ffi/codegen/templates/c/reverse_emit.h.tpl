/* Encodes payload and emits it. An encode failure returns NIMFFI_RET_ERR and,
   when err is not NULL, sets *err to the reason (the caller frees it). */
static inline int {{LIB}}_ctx_emit_{{WIRE}}(const {{CTX}}* ctx, const {{REQ}}* payload, char** err) {
    uint8_t* buf = NULL;
    size_t len = 0;
    if (nimffi_encode_to_buf({{LIB}}_encv_{{TOKEN}}, payload, &buf, &len, err) != 0) {
        return NIMFFI_RET_ERR;
    }
    int rc = {{LIB}}_emit_{{WIRE}}(ctx->ptr, buf, len);
    free(buf);
    return rc;
}
