static inline int {{LIB}}_ctx_set_{{WIRE}}_impl(const {{CTX}}* ctx, FFIReverseImpl impl, void* user_data, FFIReverseRelease release) {
    return {{LIB}}_set_{{WIRE}}_impl(ctx->ptr, impl, user_data, release);
}
