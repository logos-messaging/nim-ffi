/* Encodes reply and answers call_id. An encode failure answers the call with
   the reason as an error, so the library does not wait out its timeout, and
   returns NIMFFI_RET_ERR; when err is not NULL, *err is set to the reason
   (the caller frees it). */
static inline int {{LIB}}_reverse_reply_{{WIRE}}(void* ctx, uint64_t call_id, const {{REPLY}}* reply, char** err) {
    uint8_t* buf = NULL;
    size_t len = 0;
    char* why = NULL;
    if (nimffi_encode_to_buf({{LIB}}_encv_{{TOKEN}}, reply, &buf, &len, &why) != 0) {
        const char* msg = why ? why : "reply encode failed";
        (void){{LIB}}_reverse_reply(ctx, call_id, 1, (const uint8_t*)msg, strlen(msg));
        if (err) *err = why; else free(why);
        return NIMFFI_RET_ERR;
    }
    int rc = {{LIB}}_reverse_reply(ctx, call_id, 0, buf, len);
    free(buf);
    return rc;
}
/* Only while ctx is alive: a deferred reply uses the impl's ctx token. */
static inline int {{LIB}}_ctx_reverse_reply_{{WIRE}}(const {{CTX}}* ctx, uint64_t call_id, const {{REPLY}}* reply, char** err) {
    return {{LIB}}_reverse_reply_{{WIRE}}(ctx->ptr, call_id, reply, err);
}
