#pragma once
// Generated bindings require C++20 — the event-listener API uses
// std::span<const std::uint8_t> for the wildcard callback.
#if !defined(__cplusplus) || __cplusplus < 202002L
#error "nim-ffi generated headers require C++20 or later"
#endif
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
