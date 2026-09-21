/* A static request has no context of its own: its reply arrives on the
 * library's static context, which the binding wraps here, once per program.
 * The single-thread rule holds for it too. */
NIMFFI_SHARED {{CTX}} {{LIB}}_static_binding_ = {NULL, {NULL, 0, 0}};

static inline {{CTX}}* {{LIB}}_static_(void) {
    /* Asked every time: {{LIB}}_shutdown() ends the static context, and the
     * next static request starts a new one. */
    {{LIB}}_static_binding_.ptr = {{LIB}}_static_ctx();
    return &{{LIB}}_static_binding_;
}

/* {{LIB}}_ctx_dispatch_next() on the static context: delivers the replies of the
 * {{LIB}}_static_*() requests. */
static inline int {{LIB}}_static_dispatch_next(int32_t timeout_ms, const {{HANDLERS}}* handlers) {
    return {{LIB}}_ctx_dispatch_next({{LIB}}_static_(), timeout_ms, handlers);
}
