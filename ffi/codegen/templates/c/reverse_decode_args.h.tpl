/* Decode the args of a `{{WIRE}}` invocation{{FREE_NOTE}}. */
static inline int {{LIB}}_decode_{{WIRE}}_args(const uint8_t* args_cbor, size_t args_len, {{ARGS}}* out, char** err) {
    memset(out, 0, sizeof(*out));
    return nimffi_decode_from_buf({{LIB}}_decv_{{TOKEN}}, args_cbor, args_len, out, err);
}
