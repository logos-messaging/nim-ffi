// Native (zero-serialization, same-process) C++ example for the timer library.
//
// This is the in-process path: the program links libmy_timer and calls the
// native `<name>` entry points, passing `{.ffi.}` types as plain C structs by
// value and receiving struct returns as a typed `const <Type>*` on the
// callback. No CBOR — the CBOR ABI (see ../cpp_bindings) is for crossing a
// process/machine boundary, where serialization is unavoidable.
//
// Each call is dispatched on the library's FFI thread; an idiomatic RAII
// wrapper blocks on a std::future until the result callback fires.
#include "my_timer.h" // native C ABI (../c_bindings)

#include <cstdint>
#include <future>
#include <iostream>
#include <stdexcept>
#include <string>

namespace mytimer {

struct EchoResult {
  std::string echoed;
  std::string timerName;
};

namespace detail {
// One-shot capture shared with a C callback via `userData`.
struct Capture {
  int ret = RET_ERR;
  std::string text;     // string return / error text
  EchoResult echo;      // typed EchoResponse return
  std::promise<void> done;
};

inline std::string rawText(const char *msg, std::size_t len) {
  return (msg && len) ? std::string(msg, len) : std::string();
}

// `{.ffi.}`-callback shaped free functions (non-capturing => usable as C fn ptrs)
extern "C" inline void ackCb(int ret, const char *msg, std::size_t len, void *ud) {
  auto *c = static_cast<Capture *>(ud);
  c->ret = ret;
  if (ret == RET_ERR) c->text = rawText(msg, len);
  c->done.set_value();
}
extern "C" inline void stringCb(int ret, const char *msg, std::size_t len, void *ud) {
  auto *c = static_cast<Capture *>(ud);
  c->ret = ret;
  c->text = rawText(msg, len);
  c->done.set_value();
}
extern "C" inline void echoCb(int ret, const char *msg, std::size_t len, void *ud) {
  auto *c = static_cast<Capture *>(ud);
  c->ret = ret;
  if (ret == RET_OK) {
    const auto *r = reinterpret_cast<const EchoResponse *>(msg); // typed return
    c->echo.echoed = r->echoed ? r->echoed : "";
    c->echo.timerName = r->timerName ? r->timerName : "";
  } else {
    c->text = rawText(msg, len);
  }
  c->done.set_value();
}
} // namespace detail

class TimerNode {
public:
  explicit TimerNode(const std::string &name) {
    detail::Capture cap;
    auto fut = cap.done.get_future();
    TimerConfig cfg{};
    cfg.name = name.c_str();
    ctx_ = my_timer_create(cfg, detail::ackCb, &cap);
    if (!ctx_) throw std::runtime_error("my_timer_create returned null");
    fut.wait();
    if (cap.ret != RET_OK) throw std::runtime_error("create failed: " + cap.text);
  }

  std::string version() {
    detail::Capture cap;
    auto fut = cap.done.get_future();
    if (my_timer_version(ctx_, detail::stringCb, &cap) != RET_OK)
      throw std::runtime_error("version dispatch failed");
    fut.wait();
    if (cap.ret != RET_OK) throw std::runtime_error(cap.text);
    return cap.text;
  }

  EchoResult echo(const std::string &message, std::int64_t delayMs = 0) {
    detail::Capture cap;
    auto fut = cap.done.get_future();
    EchoRequest req{};
    req.message = message.c_str();
    req.delayMs = delayMs;
    if (my_timer_echo(ctx_, detail::echoCb, &cap, req) != RET_OK)
      throw std::runtime_error("echo dispatch failed");
    fut.wait();
    if (cap.ret != RET_OK) throw std::runtime_error(cap.text);
    return cap.echo;
  }

  ~TimerNode() {
    if (ctx_) my_timer_destroy(ctx_);
  }

  TimerNode(const TimerNode &) = delete;
  TimerNode &operator=(const TimerNode &) = delete;

private:
  void *ctx_ = nullptr;
};

} // namespace mytimer

int main() {
  try {
    mytimer::TimerNode node("cpp-native-demo");
    std::cout << "version: " << node.version() << "\n";

    auto r = node.echo("hello from C++", /*delayMs=*/5);
    std::cout << "echo: echoed=" << r.echoed << " timerName=" << r.timerName << "\n";

    std::cout << "done.\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "error: " << e.what() << "\n";
    return 1;
  }
}
