// ============================================================
// Result<T> — exception-free error channel
// ============================================================
// The generated bindings never throw: every fallible entry point (create,
// instance methods, and their *Async futures) returns a Result<T>. Callers
// branch on isOk()/isErr() (or the explicit bool conversion) and read
// value()/error(). This mirrors the Nim side's Result[T, string] and keeps
// us off C++23's std::expected. Guarded so two nim-ffi headers can share a
// translation unit.
#ifndef NIM_FFI_RESULT_HPP_INCLUDED
#define NIM_FFI_RESULT_HPP_INCLUDED

template <typename T>
class Result {
    std::optional<T> value_;
    std::string error_;
public:
    static Result<T> ok(T value) {
        Result<T> r;
        r.value_ = std::move(value);
        return r;
    }
    static Result<T> err(std::string message) {
        Result<T> r;
        r.error_ = std::move(message);
        return r;
    }
    bool isOk() const { return value_.has_value(); }
    bool isErr() const { return !value_.has_value(); }
    explicit operator bool() const { return isOk(); }
    const T& value() const { return *value_; }
    T& value() { return *value_; }
    const T& operator*() const { return *value_; }
    const T* operator->() const { return &*value_; }
    T&& take() { return std::move(*value_); }
    const std::string& error() const { return error_; }
};

template <>
class Result<void> {
    bool ok_ = true;
    std::string error_;
public:
    static Result<void> ok() {
        Result<void> r;
        r.ok_ = true;
        return r;
    }
    static Result<void> err(std::string message) {
        Result<void> r;
        r.ok_ = false;
        r.error_ = std::move(message);
        return r;
    }
    Result() = default;
    bool isOk() const { return ok_; }
    bool isErr() const { return !ok_; }
    explicit operator bool() const { return isOk(); }
    const std::string& error() const { return error_; }
};

#endif // NIM_FFI_RESULT_HPP_INCLUDED
