#pragma once
#include <string>
#include <cstdint>
#include <stdexcept>
#include <mutex>
#include <condition_variable>
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
    return nlohmann::json::parse(raw).get<T>();
}

template<>
inline void* deserializeFfiResult<void*>(const std::string& raw) {
    return reinterpret_cast<void*>(static_cast<uintptr_t>(std::stoull(raw)));
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
    auto* s = static_cast<FfiCallState_*>(ud);
    std::lock_guard<std::mutex> lock(s->mtx);
    s->ok   = (ret == 0);
    s->msg  = msg ? std::string(msg) : std::string{};
    s->done = true;
    s->cv.notify_one();
}

inline std::string ffi_call_(std::function<int(FfiCallback, void*)> f) {
    FfiCallState_ state;
    const int ret = f(ffi_cb_, &state);
    if (ret == 2)
        throw std::runtime_error("RET_MISSING_CALLBACK (internal error)");
    std::unique_lock<std::mutex> lock(state.mtx);
    state.cv.wait(lock, [&state]{ return state.done; });
    if (!state.ok)
        throw std::runtime_error(state.msg);
    return state.msg;
}

} // anonymous namespace

// ============================================================
// High-level C++ context class
// ============================================================

class NimTimerCtx {
public:
    static NimTimerCtx create(const TimerConfig& config) {
        const auto config_json = serializeFfiArg(config);
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_create(config_json.c_str(), cb, ud);
        });
        // ctor returns the context address as a plain decimal string
        const auto addr = std::stoull(raw);
        return NimTimerCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)));
    }

    static std::future<NimTimerCtx> createAsync(const TimerConfig& config) {
        return std::async(std::launch::async, [config]() { return create(config); });
    }

    EchoResponse echo(const EchoRequest& req) const {
        const auto req_json = serializeFfiArg(req);
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_echo(ptr_, cb, ud, req_json.c_str());
        });
        return deserializeFfiResult<EchoResponse>(raw);
    }

    std::future<EchoResponse> echoAsync(const EchoRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return echo(req); });
    }

    std::string version() const {
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_version(ptr_, cb, ud);
        });
        return deserializeFfiResult<std::string>(raw);
    }

    std::future<std::string> versionAsync() const {
        return std::async(std::launch::async, [this]() { return version(); });
    }

    ComplexResponse complex(const ComplexRequest& req) const {
        const auto req_json = serializeFfiArg(req);
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_complex(ptr_, cb, ud, req_json.c_str());
        });
        return deserializeFfiResult<ComplexResponse>(raw);
    }

    std::future<ComplexResponse> complexAsync(const ComplexRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return complex(req); });
    }

private:
    void* ptr_;
    explicit NimTimerCtx(void* p) : ptr_(p) {}
};
