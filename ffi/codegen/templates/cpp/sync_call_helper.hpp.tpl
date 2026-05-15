// ============================================================
// Synchronous call helper
// ============================================================

namespace {

struct FFICallState_ {
    std::mutex              mtx;
    std::condition_variable cv;
    bool                    done{false};
    bool                    ok{false};
    std::vector<std::uint8_t> bytes;
    std::string             err;
};

inline void ffi_cb_(int ret, const char* msg, size_t len, void* ud) {
    // ffi_call_ heap-allocated a shared_ptr and passed its address as ud;
    // take ownership here so it's freed on every exit path.
    std::unique_ptr<std::shared_ptr<FFICallState_>> handle(
        static_cast<std::shared_ptr<FFICallState_>*>(ud));
    FFICallState_& s = **handle;

    std::lock_guard<std::mutex> lock(s.mtx);
    s.ok = (ret == 0);
    if (msg && len > 0) {
        const auto* p = reinterpret_cast<const std::uint8_t*>(msg);
        if (s.ok) s.bytes.assign(p, p + len);
        else      s.err.assign(msg, len);
    }
    s.done = true;
    s.cv.notify_one();
}

inline std::vector<std::uint8_t> ffi_call_(std::function<int(FFICallback, void*)> f,
                                          std::chrono::milliseconds timeout) {
    auto state = std::make_shared<FFICallState_>();
    auto* cb_ref = new std::shared_ptr<FFICallState_>(state);
    const int ret = f(ffi_cb_, cb_ref);
    if (ret == 2) {
        delete cb_ref;
        throw std::runtime_error("RET_MISSING_CALLBACK (internal error)");
    }
    std::unique_lock<std::mutex> lock(state->mtx);
    const bool fired = state->cv.wait_for(lock, timeout, [&]{ return state->done; });
    if (!fired)
        throw std::runtime_error("FFI call timed out after " + std::to_string(timeout.count()) + "ms");
    if (!state->ok)
        throw std::runtime_error(state->err);
    return state->bytes;
}

} // anonymous namespace
