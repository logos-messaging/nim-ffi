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
#include <type_traits>
#include <cstring>
extern "C" {
#include <tinycbor/cbor.h>
}

// ── encode_cbor overloads (primitives + containers) ─────────────────────
// Per-struct encode_cbor / decode_cbor are emitted by cpp.nim next to each
// generated struct; these helpers cover the leaf types they defer into.
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_CBOR_HELPERS_HPP_INCLUDED
#define NIM_FFI_CBOR_HELPERS_HPP_INCLUDED

inline CborError encode_cbor(CborEncoder& e, bool v) {
    return cbor_encode_boolean(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, int64_t v) {
    return cbor_encode_int(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, int32_t v) {
    return cbor_encode_int(&e, static_cast<int64_t>(v));
}
inline CborError encode_cbor(CborEncoder& e, uint64_t v) {
    return cbor_encode_uint(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, double v) {
    return cbor_encode_double(&e, v);
}
inline CborError encode_cbor(CborEncoder& e, const std::string& v) {
    return cbor_encode_text_string(&e, v.data(), v.size());
}

template<typename T>
inline CborError encode_cbor(CborEncoder& e, const std::vector<T>& v) {
    CborEncoder arr;
    CborError err = cbor_encoder_create_array(&e, &arr, v.size());
    if (err) return err;
    for (const auto& item : v) {
        err = encode_cbor(arr, item);
        if (err) return err;
    }
    return cbor_encoder_close_container(&e, &arr);
}

template<typename T>
inline CborError encode_cbor(CborEncoder& e, const std::optional<T>& v) {
    if (!v) return cbor_encode_null(&e);
    return encode_cbor(e, *v);
}

// ── decode_cbor overloads ───────────────────────────────────────────────

inline CborError decode_cbor(CborValue& it, bool& out) {
    if (!cbor_value_is_boolean(&it)) return CborErrorImproperValue;
    CborError err = cbor_value_get_boolean(&it, &out);
    if (err) return err;
    return cbor_value_advance(&it);
}
inline CborError decode_cbor(CborValue& it, int64_t& out) {
    if (!cbor_value_is_integer(&it)) return CborErrorImproperValue;
    CborError err = cbor_value_get_int64_checked(&it, &out);
    if (err) return err;
    return cbor_value_advance(&it);
}
inline CborError decode_cbor(CborValue& it, int32_t& out) {
    int64_t tmp = 0;
    CborError err = decode_cbor(it, tmp);
    if (err) return err;
    out = static_cast<int32_t>(tmp);
    return CborNoError;
}
inline CborError decode_cbor(CborValue& it, uint64_t& out) {
    if (!cbor_value_is_unsigned_integer(&it)) return CborErrorImproperValue;
    CborError err = cbor_value_get_uint64(&it, &out);
    if (err) return err;
    return cbor_value_advance(&it);
}
inline CborError decode_cbor(CborValue& it, double& out) {
    if (cbor_value_is_double(&it)) {
        CborError err = cbor_value_get_double(&it, &out);
        if (err) return err;
        return cbor_value_advance(&it);
    }
    if (cbor_value_is_float(&it)) {
        float f = 0.0f;
        CborError err = cbor_value_get_float(&it, &f);
        if (err) return err;
        out = static_cast<double>(f);
        return cbor_value_advance(&it);
    }
    return CborErrorImproperValue;
}
inline CborError decode_cbor(CborValue& it, std::string& out) {
    if (!cbor_value_is_text_string(&it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_string_length(&it, &len);
    if (err) return err;
    out.resize(len);
    err = cbor_value_copy_text_string(&it, out.empty() ? nullptr : &out[0], &len, nullptr);
    if (err) return err;
    return cbor_value_advance(&it);
}

template<typename T>
inline CborError decode_cbor(CborValue& it, std::vector<T>& out) {
    if (!cbor_value_is_array(&it)) return CborErrorImproperValue;
    size_t len = 0;
    CborError err = cbor_value_get_array_length(&it, &len);
    if (err) return err;
    out.clear();
    out.resize(len);
    CborValue inner;
    err = cbor_value_enter_container(&it, &inner);
    if (err) return err;
    for (size_t i = 0; i < len; ++i) {
        err = decode_cbor(inner, out[i]);
        if (err) return err;
    }
    return cbor_value_leave_container(&it, &inner);
}

template<typename T>
inline CborError decode_cbor(CborValue& it, std::optional<T>& out) {
    if (cbor_value_is_null(&it)) {
        out = std::nullopt;
        return cbor_value_advance(&it);
    }
    T tmp{};
    CborError err = decode_cbor(it, tmp);
    if (err) return err;
    out = std::move(tmp);
    return CborNoError;
}

// ── Public entry points ─────────────────────────────────────────────────

template<typename T>
inline std::vector<std::uint8_t> encodeCborFFI(const T& value) {
    // Start with a generous 4 KiB buffer; double on overflow until it fits.
    std::vector<std::uint8_t> buf(4096);
    while (true) {
        CborEncoder enc;
        cbor_encoder_init(&enc, buf.data(), buf.size(), 0);
        CborError err = encode_cbor(enc, value);
        if (err == CborNoError) {
            const size_t used = cbor_encoder_get_buffer_size(&enc, buf.data());
            buf.resize(used);
            return buf;
        }
        if (err == CborErrorOutOfMemory) {
            const size_t extra = cbor_encoder_get_extra_bytes_needed(&enc);
            buf.resize(buf.size() + (extra > 0 ? extra : buf.size()));
            continue;
        }
        throw std::runtime_error(std::string("FFI CBOR encode failed: ") +
                                 cbor_error_string(err));
    }
}

template<typename T>
inline T decodeCborFFI(const std::vector<std::uint8_t>& bytes) {
    CborParser parser;
    CborValue it;
    CborError err = cbor_parser_init(bytes.data(), bytes.size(), 0, &parser, &it);
    if (err != CborNoError) {
        throw std::runtime_error(std::string("FFI CBOR parse init failed: ") +
                                 cbor_error_string(err));
    }
    T out{};
    err = decode_cbor(it, out);
    if (err != CborNoError) {
        throw std::runtime_error(std::string("FFI CBOR decode failed: ") +
                                 cbor_error_string(err));
    }
    return out;
}

#endif // NIM_FFI_CBOR_HELPERS_HPP_INCLUDED

// ============================================================
// User-declared FFI types
// ============================================================

struct EchoConfig {
    std::string prefix;
};
inline CborError encode_cbor(CborEncoder& e, const EchoConfig& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "prefix"); if (err) return err;
    err = encode_cbor(m, v.prefix);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoConfig& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "prefix", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.prefix); if (err) return err;
    return cbor_value_advance(&it);
}

struct ShoutRequest {
    std::string text;
};
inline CborError encode_cbor(CborEncoder& e, const ShoutRequest& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "text"); if (err) return err;
    err = encode_cbor(m, v.text);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, ShoutRequest& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "text", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.text); if (err) return err;
    return cbor_value_advance(&it);
}

struct ShoutResponse {
    std::string shouted;
    std::string prefix;
};
inline CborError encode_cbor(CborEncoder& e, const ShoutResponse& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 2);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "shouted"); if (err) return err;
    err = encode_cbor(m, v.shouted);              if (err) return err;
    err = cbor_encode_text_stringz(&m, "prefix"); if (err) return err;
    err = encode_cbor(m, v.prefix);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, ShoutResponse& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "shouted", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.shouted); if (err) return err;
    err = cbor_value_map_find_value(&it, "prefix", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.prefix); if (err) return err;
    return cbor_value_advance(&it);
}

// ============================================================
// Per-proc request envelopes (CBOR encoded on the wire)
// ============================================================

struct EchoCreateCtorReq {
    EchoConfig config;
};
inline CborError encode_cbor(CborEncoder& e, const EchoCreateCtorReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "config"); if (err) return err;
    err = encode_cbor(m, v.config);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoCreateCtorReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "config", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.config); if (err) return err;
    return cbor_value_advance(&it);
}

struct EchoShoutReq {
    ShoutRequest req;
};
inline CborError encode_cbor(CborEncoder& e, const EchoShoutReq& v) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 1);
    if (err) return err;
    err = cbor_encode_text_stringz(&m, "req"); if (err) return err;
    err = encode_cbor(m, v.req);              if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoShoutReq& v) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    CborValue field;
    CborError err;
    err = cbor_value_map_find_value(&it, "req", &field); if (err) return err;
    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;
    err = decode_cbor(field, v.req); if (err) return err;
    return cbor_value_advance(&it);
}

struct EchoVersionReq {
};
inline CborError encode_cbor(CborEncoder& e, const EchoVersionReq&) {
    CborEncoder m;
    CborError err = cbor_encoder_create_map(&e, &m, 0);
    if (err) return err;
    return cbor_encoder_close_container(&e, &m);
}
inline CborError decode_cbor(CborValue& it, EchoVersionReq&) {
    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;
    return cbor_value_advance(&it);
}

// ============================================================
// C FFI declarations
// ============================================================

extern "C" {
typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);

void* echo_create(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);
int echo_shout(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int echo_version(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);
int echo_destroy(void* ctx);
uint64_t echo_add_event_listener(void* ctx, const char* event_name, FFICallback callback, void* user_data);
int echo_remove_event_listener(void* ctx, uint64_t listener_id);
} // extern "C"

// ============================================================
// Synchronous call helper
// ============================================================
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED
#define NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED

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

#endif // NIM_FFI_SYNC_CALL_HELPER_HPP_INCLUDED

// ============================================================
// High-level C++ context class
// ============================================================

class EchoCtx {
public:
    static std::unique_ptr<EchoCtx> create(const EchoConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        const auto ffi_req_ = EchoCreateCtorReq{config};
        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            (void)echo_create(ffi_req_bytes_.data(), ffi_req_bytes_.size(), cb, ud);
            return 0;
        }, timeout);
        const auto addr_str = decodeCborFFI<std::string>(ffi_raw_);
        try {
            const auto addr = std::stoull(addr_str);
            return std::unique_ptr<EchoCtx>(new EchoCtx(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout));
        } catch (const std::exception&) {
            throw std::runtime_error("FFI create returned non-numeric address: " + addr_str);
        }
    }

    static std::future<std::unique_ptr<EchoCtx>> createAsync(const EchoConfig& config, std::chrono::milliseconds timeout = std::chrono::seconds{30}) {
        return std::async(std::launch::async, [config, timeout]() { return create(config, timeout); });
    }

    // Special-member policy: this class owns a echo context, which in
    // turn owns the library's worker thread(s) and internal state. Moving
    // such an object out from under a caller silently tears that state
    // down and is easy to misuse (e.g. storing in a container that
    // relocates its elements). It also has no clean analogue in the other
    // binding languages we generate. So copies and moves are both
    // deleted; ownership is transferred via EchoCtx::create returning a
    // std::unique_ptr<EchoCtx>. The destructor still releases the
    // context.
    ~EchoCtx() {
        if (ptr_) {
            echo_destroy(ptr_);
            ptr_ = nullptr;
        }
    }

    EchoCtx(const EchoCtx&) = delete;
    EchoCtx& operator=(const EchoCtx&) = delete;
    EchoCtx(EchoCtx&&) = delete;
    EchoCtx& operator=(EchoCtx&&) = delete;

    ShoutResponse shout(const ShoutRequest& req) const {
        const auto ffi_req_ = EchoShoutReq{req};
        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return echo_shout(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFFI<ShoutResponse>(ffi_raw_);
    }

    std::future<ShoutResponse> shoutAsync(const ShoutRequest& req) const {
        return std::async(std::launch::async, [this, req]() { return this->shout(req); });
    }

    std::string version() const {
        const auto ffi_req_ = EchoVersionReq{};
        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);
        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {
            return echo_version(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());
        }, timeout_);
        return decodeCborFFI<std::string>(ffi_raw_);
    }

    std::future<std::string> versionAsync() const {
        return std::async(std::launch::async, [this]() { return this->version(); });
    }

private:
    void* ptr_;
    std::chrono::milliseconds timeout_;
    explicit EchoCtx(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}
};
