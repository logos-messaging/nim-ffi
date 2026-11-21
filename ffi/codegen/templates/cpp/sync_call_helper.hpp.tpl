// ============================================================
// Call helpers
// ============================================================
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED
#define NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED

// Gets the elapsed time on each RET_STALE_WARN. Runs on a library thread, also after a timeout.
using FFIProgress = std::function<void(std::chrono::milliseconds)>;

namespace {

using FFIBytes_ = std::vector<std::uint8_t>;

// The first of the terminal callback, a timeout and a failed submit settles the call.
template <typename T>
struct FFICallState_ {
    std::mutex                    mtx;
    bool                          settled{false};
    std::promise<Result<T>>       promise;
    FFIProgress                   progress;
    std::function<Result<T>(FFIBytes_&&)> decode;
    std::function<void()>         onSettled;

    bool live() {
        std::lock_guard<std::mutex> lock(mtx);
        return !settled;
    }

    void settle(Result<T> r) {
        std::function<void()> done;
        {
            std::lock_guard<std::mutex> lock(mtx);
            if (settled) return;
            settled = true;
            done = std::move(onSettled);
        }
        promise.set_value(std::move(r));
        if (done) done();
    }
};

// Runs deadlines for async calls on one shared thread, so no call owns a thread.
class FFITimer_ {
    using Clock = std::chrono::steady_clock;
    std::mutex mtx_;
    std::condition_variable cv_;
    std::map<std::pair<Clock::time_point, std::uint64_t>, std::function<void()>> q_;
    std::uint64_t next_{0};

    FFITimer_() { std::thread([this] { run_(); }).detach(); }

    // Never returns: the thread runs until the process exits.
    void run_() {
        std::unique_lock<std::mutex> lock(mtx_);
        for (;;) {
            if (q_.empty()) { cv_.wait(lock); continue; }
            const auto first = q_.begin();
            const auto due = first->first.first;
            if (due > Clock::now()) {
                cv_.wait_until(lock, due);
                continue;
            }
            auto fn = std::move(first->second);
            q_.erase(first);
            lock.unlock();
            fn();
            lock.lock();
        }
    }

public:
    // Never destroyed: the thread outlives static destruction.
    static FFITimer_& get() {
        static FFITimer_* t = new FFITimer_();
        return *t;
    }

    std::uint64_t at(std::chrono::milliseconds after, std::function<void()> fn) {
        std::lock_guard<std::mutex> lock(mtx_);
        const auto id = next_++;
        q_.emplace(std::make_pair(Clock::now() + after, id), std::move(fn));
        cv_.notify_one();
        return id;
    }

    void cancel(std::uint64_t id) {
        std::lock_guard<std::mutex> lock(mtx_);
        for (auto it = q_.begin(); it != q_.end(); ++it) {
            if (it->first.second == id) { q_.erase(it); return; }
        }
    }
};

template <typename T>
inline void ffi_cb_(int ret, const char* msg, size_t len, void* ud) {
    using State = FFICallState_<T>;
    // Non-terminal ping: leave `ud` alone, the terminal callback still owns the handle.
    if (ret == NIMFFI_RET_STALE_WARN) {
        State& s = **static_cast<std::shared_ptr<State>*>(ud);
        if (!s.progress) return;
        long long ms = 0;
        if (msg && len > 0) std::from_chars(msg, msg + len, ms);
        // An exception must not unwind into the library thread.
        try { s.progress(std::chrono::milliseconds{ms}); } catch (...) {}
        return;
    }

    std::unique_ptr<std::shared_ptr<State>> handle(
        static_cast<std::shared_ptr<State>*>(ud));
    State& s = **handle;
    if (!s.live()) return;

    if (ret != NIMFFI_RET_OK) {
        s.settle(Result<T>::err(msg && len > 0 ? std::string(msg, len) : std::string{}));
        return;
    }

    const auto* p = reinterpret_cast<const std::uint8_t*>(msg);
    FFIBytes_ bytes;
    if (msg && len > 0) bytes.assign(p, p + len);
    s.settle([&]() -> Result<T> {
        try { return s.decode(std::move(bytes)); }
        catch (...) { return Result<T>::err("reply decode threw"); }
    }());
}

template <typename T>
inline std::pair<std::shared_ptr<FFICallState_<T>>, std::future<Result<T>>>
ffi_submit_(const std::function<int(FFICallback, void*)>& f,
            FFIProgress progress,
            std::function<Result<T>(FFIBytes_&&)> decode) {
    auto state = std::make_shared<FFICallState_<T>>();
    state->progress = std::move(progress);
    state->decode = std::move(decode);
    auto fut = state->promise.get_future();
    auto* cb_ref = new std::shared_ptr<FFICallState_<T>>(state);
    const int ret = f(&ffi_cb_<T>, cb_ref);
    if (ret == NIMFFI_RET_MISSING_CALLBACK) {
        delete cb_ref;
        state->settle(Result<T>::err("RET_MISSING_CALLBACK (internal error)"));
    }
    return {std::move(state), std::move(fut)};
}

inline std::string ffi_timeout_msg_(std::chrono::milliseconds limit) {
    return "FFI call timed out after " + std::to_string(limit.count()) + "ms";
}

// A nullopt `timeout` waits with no limit. A timeout only stops the wait.
inline Result<FFIBytes_> ffi_call_(
        std::function<int(FFICallback, void*)> f,
        std::optional<std::chrono::milliseconds> timeout,
        FFIProgress progress = {}) {
    auto [state, fut] = ffi_submit_<FFIBytes_>(
        f, std::move(progress),
        [](FFIBytes_&& b) { return Result<FFIBytes_>::ok(std::move(b)); });
    if (timeout && fut.wait_for(*timeout) != std::future_status::ready)
        state->settle(Result<FFIBytes_>::err(ffi_timeout_msg_(*timeout)));
    return fut.get();
}

// Like ffi_call_, but returns at once; `f` runs before this returns.
template <typename T>
inline std::future<Result<T>> ffi_call_async_(
        std::function<int(FFICallback, void*)> f,
        std::optional<std::chrono::milliseconds> timeout,
        FFIProgress progress,
        std::function<Result<T>(FFIBytes_&&)> decode) {
    auto [state, fut] = ffi_submit_<T>(f, std::move(progress), std::move(decode));
    if (!timeout || !state->live()) return std::move(fut);

    const auto limit = *timeout;
    const auto id = FFITimer_::get().at(limit, [w = std::weak_ptr<FFICallState_<T>>(state), limit] {
        if (auto s = w.lock()) s->settle(Result<T>::err(ffi_timeout_msg_(limit)));
    });
    {
        std::lock_guard<std::mutex> lock(state->mtx);
        if (state->settled) FFITimer_::get().cancel(id);
        else state->onSettled = [id] { FFITimer_::get().cancel(id); };
    }
    return std::move(fut);
}

} // anonymous namespace

#endif // NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED
