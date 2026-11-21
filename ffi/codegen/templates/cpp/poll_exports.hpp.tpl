// ============================================================
// C FFI declarations (poll mode)
// ============================================================

extern "C" {
{{PROC_DECLS}}
int {{LIB}}_poll(void* ctx, int32_t timeout_ms, const PollResult** msg);
int64_t {{LIB}}_poll_fd(void* ctx);
int {{LIB}}_reverse_reply(void* ctx, uint64_t call_id, int ret, const uint8_t* payload, size_t len);
void* {{LIB}}_static_ctx(void);
{{SHUTDOWN_DOC}}
int {{LIB}}_shutdown(void);
} // extern "C"

namespace {
inline std::string ffiPollError_(const char* what, const nim_ffi::Reply& r) {
    return std::string(what) + ": " +
           (r.error.empty() ? "return code: " + std::to_string(r.ret) : r.error);
}
} // namespace
