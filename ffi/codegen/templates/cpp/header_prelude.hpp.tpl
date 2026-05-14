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
