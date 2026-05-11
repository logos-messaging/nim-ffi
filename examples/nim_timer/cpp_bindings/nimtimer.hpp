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
#include <type_traits>
#include <vector>
#include <optional>
#include <nlohmann/json.hpp>

#if !defined(NIM_FFI_NO_OPTIONAL_SERIALIZER) \
    && !defined(NIM_FFI_OPTIONAL_SERIALIZER_DEFINED_) \
    && (!defined(NLOHMANN_JSON_VERSION_MAJOR) \
        || (NLOHMANN_JSON_VERSION_MAJOR < 3) \
        || (NLOHMANN_JSON_VERSION_MAJOR == 3 && NLOHMANN_JSON_VERSION_MINOR < 12))
#define NIM_FFI_OPTIONAL_SERIALIZER_DEFINED_
namespace nlohmann {
    template<typename T>
    struct adl_serializer<std::optional<T>> {
        static void to_json(json& j, const std::optional<T>& opt) {
            if (opt) j = *opt;
            else j = nullptr;
        }
        static void from_json(const json& j, std::optional<T>& opt) {
            if (j.is_null()) opt = std::nullopt;
            else opt = j.get<T>();
        }
    };
}
#endif

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

// True-async helpers: std::promise<T> + std::future<T> mirror the Rust
// tokio::sync::oneshot design -- the FFI callback completes the promise
// directly, so the returned future becomes ready without ever blocking a
// thread. The C ABI trampoline cannot be a template, so the per-T completion
// logic is type-erased into a std::function held inside FfiAsyncState_.
struct FfiAsyncState_ {
    std::function<void(int, const char*)> complete;
};

inline void ffi_cb_async_(int ret, const char* msg, size_t /*len*/, void* ud) {
    auto* state = static_cast<FfiAsyncState_*>(ud);
    state->complete(ret, msg);
    delete state;
}

template<typename T>
inline std::future<T> ffi_call_async_(std::function<int(FfiCallback, void*)> f) {
    auto promise = std::make_shared<std::promise<T>>();
    auto future  = promise->get_future();
    auto* state  = new FfiAsyncState_{
        [promise](int ret, const char* msg) {
            const std::string s = msg ? std::string(msg) : std::string{};
            try {
                if (ret == 0) {
                    if constexpr (std::is_same_v<T, std::string>) {
                        promise->set_value(s);
                    } else if constexpr (std::is_same_v<T, void*>) {
                        promise->set_value(deserializeFfiResult<void*>(s));
                    } else {
                        promise->set_value(deserializeFfiResult<T>(s));
                    }
                } else {
                    promise->set_exception(std::make_exception_ptr(std::runtime_error(s)));
                }
            } catch (...) {
                promise->set_exception(std::current_exception());
            }
        }
    };
    const int ret = f(ffi_cb_async_, state);
    if (ret == 2) {
        delete state;
        throw std::runtime_error("RET_MISSING_CALLBACK (internal error)");
    }
    return future;
}

} // anonymous namespace

// ============================================================
// High-level C++ context class
//
// Async methods (createAsync / <name>Async) return a std::future<T>
// that becomes ready when the Nim callback fires. No thread is
// spawned for the wait: the FFI callback completes the underlying
// std::promise directly, mirroring the Rust tokio::oneshot path.
// Apply timeouts via future.wait_for(...) on the caller's side.
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
        const auto config_json = serializeFfiArg(config);
        auto promise = std::make_shared<std::promise<NimTimerCtx>>();
        auto future  = promise->get_future();
        auto* state  = new FfiAsyncState_{
            [promise, timeout](int ret, const char* msg) {
                const std::string s = msg ? std::string(msg) : std::string{};
                try {
                    if (ret == 0) {
                        const auto addr = std::stoull(s);
                        promise->set_value(NimTimerCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout));
                    } else {
                        promise->set_exception(std::make_exception_ptr(std::runtime_error(s)));
                    }
                } catch (...) {
                    promise->set_exception(std::current_exception());
                }
            }
        };
        const int ret = nimtimer_create(config_json.c_str(), ffi_cb_async_, state);
        if (ret == 2) {
            delete state;
            throw std::runtime_error("RET_MISSING_CALLBACK (internal error)");
        }
        return future;
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
        const auto req_json = serializeFfiArg(req);
        return ffi_call_async_<EchoResponse>([&](FfiCallback cb, void* ud) {
            return nimtimer_echo(ptr_, cb, ud, req_json.c_str());
        });
    }

    std::string version() const {
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_version(ptr_, cb, ud);
        }, timeout_);
        return deserializeFfiResult<std::string>(raw);
    }

    std::future<std::string> versionAsync() const {
        return ffi_call_async_<std::string>([&](FfiCallback cb, void* ud) {
            return nimtimer_version(ptr_, cb, ud);
        });
    }

    ComplexResponse complex(const ComplexRequest& req) const {
        const auto req_json = serializeFfiArg(req);
        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {
            return nimtimer_complex(ptr_, cb, ud, req_json.c_str());
        }, timeout_);
        return deserializeFfiResult<ComplexResponse>(raw);
    }

    std::future<ComplexResponse> complexAsync(const ComplexRequest& req) const {
        const auto req_json = serializeFfiArg(req);
        return ffi_call_async_<ComplexResponse>([&](FfiCallback cb, void* ud) {
            return nimtimer_complex(ptr_, cb, ud, req_json.c_str());
        });
    }

private:
    void* ptr_;
    std::chrono::milliseconds timeout_;
    explicit NimTimerCtx(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}
};
