#pragma once
#include <string>
#include <cstdint>
#include <chrono>
#include <stdexcept>
#include <mutex>
#include <condition_variable>
#include <memory>
#include <functional>
#include <future>
#include <vector>
#include <optional>
#include <nlohmann/json.hpp>

namespace nlohmann {
    template<typename T>
    void to_json(json& j, const std::optional<T>& opt) {
        if (opt) j = *opt;
        else j = nullptr;
    }

    template<typename T>
    void from_json(const json& j, std::optional<T>& opt) {
        if (j.is_null()) opt = std::nullopt;
        else opt = j.get<T>();
    }
}

// ============================================================
// User-declared FFI types
// ============================================================

struct TimerConfig {
    std::string name;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(TimerConfig, name)

struct EchoRequest {
    std::string message;
    int64_t delayMs;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(EchoRequest, message, delayMs)

struct EchoResponse {
    std::string echoed;
    std::string timerName;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(EchoResponse, echoed, timerName)

struct ComplexRequest {
    std::vector<EchoRequest> messages;
    std::vector<std::string> tags;
    std::optional<std::string> note;
    std::optional<int64_t> retries;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(ComplexRequest, messages, tags, note, retries)

struct ComplexResponse {
    std::string summary;
    int64_t itemCount;
    bool hasNote;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(ComplexResponse, summary, itemCount, hasNote)

struct JobSpec {
    std::string name;
    std::vector<std::string> payload;
    int64_t priority;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(JobSpec, name, payload, priority)

struct RetryPolicy {
    int64_t maxAttempts;
    int64_t backoffMs;
    std::vector<std::string> retryOn;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(RetryPolicy, maxAttempts, backoffMs, retryOn)

struct ScheduleConfig {
    int64_t startAtMs;
    int64_t intervalMs;
    std::optional<int64_t> jitter;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(ScheduleConfig, startAtMs, intervalMs, jitter)

struct ScheduleResult {
    std::string jobId;
    int64_t willRunCount;
    int64_t firstRunAtMs;
    int64_t effectiveBackoffMs;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(ScheduleResult, jobId, willRunCount, firstRunAtMs, effectiveBackoffMs)

// ============================================================
// Per-proc request envelopes (CBOR encoded on the wire)
// ============================================================

struct TimerCreateCtorReq {
    TimerConfig config;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(TimerCreateCtorReq, config)

struct TimerEchoReq {
    EchoRequest req;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(TimerEchoReq, req)

struct TimerVersionReq {
};
inline void to_json(nlohmann::json& j, const TimerVersionReq&) { j = nlohmann::json::object(); }
inline void from_json(const nlohmann::json&, TimerVersionReq&) {}

struct TimerComplexReq {
    ComplexRequest req;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(TimerComplexReq, req)

struct TimerScheduleReq {
    JobSpec job;
    RetryPolicy retry;
    ScheduleConfig schedule;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(TimerScheduleReq, job, retry, schedule)

// ============================================================
// C FFI declarations
// ============================================================

extern "C" {
typedef void (*FfiCallback)(int ret, const char* msg, size_t len, void* user_data);

void* timer_create(const uint8_t* req_cbor, size_t req_cbor_len, FfiCallback callback, void* user_data);
int timer_echo(void* ctx, FfiCallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int timer_version(void* ctx, FfiCallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int timer_complex(void* ctx, FfiCallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int timer_schedule(void* ctx, FfiCallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int timer_destroy(void* ctx);
} // extern "C"

template<typename T>
inline std::vector<std::uint8_t> encodeCborFfi(const T& value) {
    return nlohmann::json::to_cbor(nlohmann::json(value));
}

template<typename T>
inline T decodeCborFfi(const std::vector<std::uint8_t>& bytes) {
    try {
        return nlohmann::json::from_cbor(bytes).get<T>();
    } catch (const nlohmann::json::exception& e) {
        throw std::runtime_error(std::string("FFI CBOR decode failed: ") + e.what());
    }
}

// ============================================================
// Synchronous call helper
// ============================================================

namespace {

struct FfiCallState_ {
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
    std::unique_ptr<std::shared_ptr<FfiCallState_>> handle(
        static_cast<std::shared_ptr<FfiCallState_>*>(ud));
    FfiCallState_& s = **handle;

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

inline std::vector<std::uint8_t> ffi_call_(std::function<int(FfiCallback, void*)> f,
                                          std::chrono::milliseconds timeout) {
    auto state = std::make_shared<FfiCallState_>();
    auto* cb_ref = new std::shared_ptr<FfiCallState_>(state);
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

// ============================================================
// High-level C++ context class
// ============================================================

class TimerCtx {
public:
    static TimerCtx create(const TimerConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = TimerCreateCtorReq{config};
        const auto ffi_req_bytes_ = encodeCborFfi(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FfiCallback cb, void* ud) {
            (void)timer_create(ffi_req_bytes_.data(), ffi_req_bytes_.size(), cb, ud);
            return 0;
        }, timeout);
        const auto addr_str = decodeCborFfi<std::string>(ffi_raw_);
        try {
            const auto addr = std::stoull(addr_str);
            return TimerCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout);
        } catch (const std::exception&) {
            throw std::runtime_error("FFI create returned non-numeric address: " + addr_str);
        }
    }

    static std::future<TimerCtx> createAsync(const TimerConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        return std::async(std::launch::async, [config, timeout]() { return create(config, timeout); });
    }

    // Rule of Five: because this class owns a raw resource (the timer
    // context pointer freed in the destructor), the compiler-generated copy
    // and move special members would do the wrong thing — copies would
    // double-free, and a default move would leave both objects pointing at
    // the same context. So we define all five special members explicitly:
    //   1. destructor          — releases the context.
    //   2. copy constructor    — deleted; contexts are not copyable.
    //   3. copy assignment     — deleted; same reason.
    //   4. move constructor    — transfers ownership, nulls the source.
    //   5. move assignment     — destroys the current context, then
    //                            transfers ownership from `other`.
    // See: https://en.cppreference.com/w/cpp/language/rule_of_three
    ~TimerCtx() {
        if (ptr_) {
            timer_destroy(ptr_);
            ptr_ = nullptr;
        }
    }

    TimerCtx(const TimerCtx&) = delete;
    TimerCtx& operator=(const TimerCtx&) = delete;

    TimerCtx(TimerCtx&& other) noexcept : ptr_(other.ptr_), timeout_(other.timeout_) {
        other.ptr_ = nullptr;
    }
    TimerCtx& operator=(TimerCtx&& other) noexcept {
        if (this != &other) {
            if (ptr_) timer_destroy(ptr_);
            ptr_ = other.ptr_;
            timeout_ = other.timeout_;
            other.ptr_ = nullptr;
        }
        return *this;
    }

    EchoResponse echo(const EchoRequest& req) const {
        const auto ffi_req_ = TimerEchoReq{req};
        const auto ffi_req_bytes_ = encodeCborFfi(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FfiCallback cb, void* ud) {
            return timer_echo(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFfi<EchoResponse>(ffi_raw_);
    }

    std::future<EchoResponse> echoAsync(const EchoRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return this->echo(req); });
    }

    std::string version() const {
        const auto ffi_req_ = TimerVersionReq{};
        const auto ffi_req_bytes_ = encodeCborFfi(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FfiCallback cb, void* ud) {
            return timer_version(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFfi<std::string>(ffi_raw_);
    }

    std::future<std::string> versionAsync() const {
        return std::async(std::launch::async, [this]() { return this->version(); });
    }

    ComplexResponse complex(const ComplexRequest& req) const {
        const auto ffi_req_ = TimerComplexReq{req};
        const auto ffi_req_bytes_ = encodeCborFfi(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FfiCallback cb, void* ud) {
            return timer_complex(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFfi<ComplexResponse>(ffi_raw_);
    }

    std::future<ComplexResponse> complexAsync(const ComplexRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return this->complex(req); });
    }

    ScheduleResult schedule(const JobSpec& job, const RetryPolicy& retry, const ScheduleConfig& schedule) const {
        const auto ffi_req_ = TimerScheduleReq{job, retry, schedule};
        const auto ffi_req_bytes_ = encodeCborFfi(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FfiCallback cb, void* ud) {
            return timer_schedule(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFfi<ScheduleResult>(ffi_raw_);
    }

    std::future<ScheduleResult> scheduleAsync(const JobSpec& job, const RetryPolicy& retry, const ScheduleConfig& schedule) const {
        return std::async(std::launch::async, [this, job, retry, schedule]() { return this->schedule(job, retry, schedule); });
    }

private:
    void* ptr_;
    std::chrono::milliseconds timeout_;
    explicit TimerCtx(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}
};
