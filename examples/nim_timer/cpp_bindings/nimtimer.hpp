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
// Types
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

// ============================================================
// C FFI declarations
// ============================================================

extern "C" {
typedef void (*FfiCallback)(int ret, const char* msg, size_t len, void* user_data);

int nimtimer_create(const char* config_json, FfiCallback callback, void* user_data);
int nimtimer_echo(void* ctx, FfiCallback callback, void* user_data, const char* req_json);
int nimtimer_version(void* ctx, FfiCallback callback, void* user_data);
int nimtimer_complex(void* ctx, FfiCallback callback, void* user_data, const char* req_json);
void nimtimer_destroy(void* ctx);
} // extern "C"

template<typename T>
inline std::string serializeFfiArg(const T& value) {
    return nlohmann::json(value).dump();
}

inline std::string serializeFfiArg(void* value) {
    return std::to_string(reinterpret_cast<uintptr_t>(value));
}

template<typename T>
inline T deserializeFfiResult(const std::string& raw) {
    try {
        return nlohmann::json::parse(raw).get<T>();
    } catch (const nlohmann::json::exception& e) {
        throw std::runtime_error(std::string("FFI response deserialization failed: ") + e.what());
    }
}

template<>
inline void* deserializeFfiResult<void*>(const std::string& raw) {
    try {
        return reinterpret_cast<void*>(static_cast<uintptr_t>(std::stoull(raw)));
    } catch (const std::exception& e) {
        throw std::runtime_error(std::string("FFI returned non-numeric address: ") + raw);
    }
}

// ============================================================
// Synchronous call helper (anonymous namespace, header-only)
// ============================================================

namespace {

struct FfiCallState_ {
    std::mutex              mtx;
    std::condition_variable cv;
    bool                    done{false};
    bool                    ok{false};
    std::string             msg;
};

inline void ffi_cb_(int ret, const char* msg, size_t /*len*/, void* ud) {
    auto* sptr = static_cast<std::shared_ptr<FfiCallState_>*>(ud);
    {
        auto& s = **sptr;
        std::lock_guard<std::mutex> lock(s.mtx);
        s.ok   = (ret == 0);
        s.msg  = msg ? std::string(msg) : std::string{};
        s.done = true;
        s.cv.notify_one();
    }
    delete sptr;
}

inline std::string ffi_call_(std::function<int(FfiCallback, void*)> f,
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
        throw std::runtime_error(state->msg);
    return state->msg;
}

} // anonymous namespace

// ============================================================
// High-level C++ context class
// ============================================================

class NimTimerCtx {
public:
    static NimTimerCtx create(const TimerConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto config_json = serializeFfiArg(config);
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_create(config_json.c_str(), cb, ud);
        }, timeout);
        try {
            const auto addr = std::stoull(raw);
            return NimTimerCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout);
        } catch (const std::exception&) {
            throw std::runtime_error("FFI create returned non-numeric address: " + raw);
        }
    }

    static std::future<NimTimerCtx> createAsync(const TimerConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        return std::async(std::launch::async, [config, timeout]() { return create(config, timeout); });
    }

    ~NimTimerCtx() {
        if (ptr_) {
            nimtimer_destroy(ptr_);
            ptr_ = nullptr;
        }
    }

    NimTimerCtx(const NimTimerCtx&) = delete;
    NimTimerCtx& operator=(const NimTimerCtx&) = delete;

    NimTimerCtx(NimTimerCtx&& other) noexcept : ptr_(other.ptr_), timeout_(other.timeout_) {
        other.ptr_ = nullptr;
    }
    NimTimerCtx& operator=(NimTimerCtx&& other) noexcept {
        if (this != &other) {
            if (ptr_) nimtimer_destroy(ptr_);
            ptr_ = other.ptr_;
            timeout_ = other.timeout_;
            other.ptr_ = nullptr;
        }
        return *this;
    }

    EchoResponse echo(const EchoRequest& req) const {
        const auto req_json = serializeFfiArg(req);
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_echo(ptr_, cb, ud, req_json.c_str());
        }, timeout_);
        return deserializeFfiResult<EchoResponse>(raw);
    }

    std::future<EchoResponse> echoAsync(const EchoRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return echo(req); });
    }

    std::string version() const {
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_version(ptr_, cb, ud);
        }, timeout_);
        return deserializeFfiResult<std::string>(raw);
    }

    std::future<std::string> versionAsync() const {
        return std::async(std::launch::async, [this]() { return version(); });
    }

    ComplexResponse complex(const ComplexRequest& req) const {
        const auto req_json = serializeFfiArg(req);
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_complex(ptr_, cb, ud, req_json.c_str());
        }, timeout_);
        return deserializeFfiResult<ComplexResponse>(raw);
    }

    std::future<ComplexResponse> complexAsync(const ComplexRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return complex(req); });
    }

private:
    void* ptr_;
    std::chrono::milliseconds timeout_;
    explicit NimTimerCtx(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}
};
