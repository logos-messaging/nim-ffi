// nim-ffi poll mode: the host side, once.
//
// A poll-mode library never calls the host back. Method replies, events and the
// library's own questions (REVERSE_CALL) all come out of one queue per context, and
// fd() is readable while that queue is not empty. nim_ffi::Host owns the queue for
// one context and starts no thread.
//
// Header-only; requires nim_ffi.h beside it. This is the low-level API: payloads are
// bytes (the CBOR, or the UTF-8 of a text reply, is yours to decode), and a generated
// typed client is meant to wrap it.
//
//   nim_ffi::Host host({my_create, my_destroy, my_poll, my_poll_fd, my_reverse_reply});
//   host.onReverseCall([&](uint64_t call, uint64_t name, const uint8_t* args, size_t len) {
//     /* answer, from any thread: */ host.reverseReply(call, NIMFFI_RET_OK, cbor_bytes);
//   });
//   host.create(cbor_of({{"configJson", "{}"}}), 5s);
//   auto r = host.call(my_send, cbor_of({{"messageJson", msg}}), 30s);
//
// Serving events and reverse calls. Nothing runs until someone serves the queue, and
// handlers run on that thread, so they must return quickly (Host calls onSlowHandler
// past setSlowHandlerLimit, 50 ms by default; set both before the first message).
//   - no loop of its own:  runLoop() blocks the calling thread until stop().
//   - a loop you can call each iteration:  poll() serves what is waiting and returns.
//   - a loop with descriptor watchers (Qt, libuv, asio, epoll, kqueue, ...): watch fd()
//     and call poll() when it is readable.
// fd() is level-triggered and is an epoll descriptor on Linux, a kqueue on macOS and
// the BSDs, an Event HANDLE on Windows (reinterpret_cast<HANDLE>(host.fd())). Only
// watch it: never read, write or kevent into it; poll() is what clears it.
//
// Threads. reverseReply() may be called from any thread. One thread serves at a time:
// poll() returns at once when another thread is inside call(), create() or poll().
// destroy() waits for it.
#ifndef NIM_FFI_HOST_HPP
#define NIM_FFI_HOST_HPP

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// runLoop() waits on the library's wake handle with the OS's own call, which needs
// <poll.h> or <windows.h>. Define NIM_FFI_NO_RUNLOOP before including this header to
// leave runLoop() out and keep those headers (and their names) out of your code.
#ifndef NIM_FFI_NO_RUNLOOP
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <poll.h>
#endif
#endif

#include "nim_ffi.h"

namespace nim_ffi {

// The five fixed exports of one library, bound by the host.
struct Library {
  int (*create)(const uint8_t* req, size_t len, void** ctx_out, uint64_t* id_out);
  int (*destroy)(void* ctx);
  int (*poll)(void* ctx, int32_t timeout_ms, const PollResult** msg);
  int64_t (*poll_fd)(void* ctx);
  int (*reverse_reply)(void* ctx, uint64_t call_id, int ret, const uint8_t* payload, size_t len);
};

using Method = int (*)(void* ctx, const uint8_t* req, size_t len, uint64_t* id_out);
// A `{.ffiStatic.}` export: no context argument; its reply comes out of the
// library's static context, which a Host attach()es to.
using StaticMethod = int (*)(const uint8_t* req, size_t len, uint64_t* id_out);
using Bytes = std::vector<uint8_t>;

// A request's outcome. `ret` is the library's code; on NIMFFI_RET_OK `payload`
// is the reply's CBOR, otherwise `error` is the library's text (or the host's,
// for a submit that was not accepted or a wait that ran out).
struct Reply {
  int ret = NIMFFI_RET_ERR;
  Bytes payload;
  std::string error;
};

class Host {
 public:
  // An event: its wire name id and its payload, borrowed for the call.
  using EventHandler = std::function<void(uint64_t name_id, const uint8_t* payload, size_t len)>;
  // A question from the library: answer it, from any thread, with reverseReply.
  using ReverseHandler =
      std::function<void(uint64_t call_id, uint64_t name_id, const uint8_t* args, size_t len)>;
  // A reply nobody waits for, handed on arrival (see submit).
  using Done = std::function<void(const Reply&)>;

  // A handler or callback that ran longer than the limit: what it was, and how long.
  using SlowHandler = std::function<void(const char* what, std::chrono::milliseconds took)>;

  explicit Host(Library lib) : lib_(lib) {
    on_slow_ = [](const char* what, std::chrono::milliseconds took) {
      std::fprintf(stderr,
                   "nim_ffi: %s blocked the pump for %lld ms; return quickly and answer later\n",
                   what, static_cast<long long>(took.count()));
    };
  }
  // A thread inside runLoop() is told to stop and waited for, so the Host is never
  // freed under it. Not from a handler: that handler runs on the loop thread itself.
  ~Host() {
    stop_ = true;
    waitLoopExit();
    destroy();
  }
  Host(const Host&) = delete;
  Host& operator=(const Host&) = delete;

  void onSlowHandler(SlowHandler h) { on_slow_ = std::move(h); }
  void setSlowHandlerLimit(std::chrono::milliseconds limit) { slow_limit_ = limit; }
  void onEvent(EventHandler h) { on_event_ = std::move(h); }
  void onReverseCall(ReverseHandler h) { on_reverse_ = std::move(h); }

  // Creates the context and pumps until the constructor's reply. On a
  // non-OK reply the context is destroyed again and alive() stays false.
  Reply create(const Bytes& req, std::chrono::milliseconds timeout) {
    std::lock_guard<std::recursive_mutex> lock(lock_);
    Reply r;
    if (ctx_) {
      r.error = "context already created";
      return r;
    }
    void* ctx = nullptr;
    uint64_t id = 0;
    const int rc = lib_.create(req.data(), req.size(), &ctx, &id);
    if (rc != NIMFFI_RET_OK || !ctx) {
      r.ret = rc;
      r.error = "create: not accepted, rc=" + std::to_string(rc);
      return r;
    }
    ctx_ = ctx;
    owned_ = true;
    bool timedOut = false;
    r = waitFor(id, timeout, timedOut);
    if (timedOut) r.error = timeoutText(timeout);
    if (r.ret != NIMFFI_RET_OK) {
      if (void* c = ctx_.exchange(nullptr)) lib_.destroy(c);
      failPending(NIMFFI_RET_CLOSED, "context destroyed");
    }
    return r;
  }

  // Serves an existing context the library owns (`<lib>_static_ctx()`) instead of
  // creating one: destroy() and the destructor then leave it alone. False when
  // this host already has a context or `token` is null.
  bool attach(void* token) {
    std::lock_guard<std::recursive_mutex> lock(lock_);
    if (ctx_ || !token) return false;
    owned_ = false;
    ctx_ = token;
    return true;
  }

  void destroy() {
    std::lock_guard<std::recursive_mutex> lock(lock_);
    if (void* c = ctx_.exchange(nullptr)) {
      if (owned_) lib_.destroy(c);
    }
    failPending(NIMFFI_RET_CLOSED, "context destroyed");
  }

  bool alive() const { return ctx_.load() != nullptr; }
  void* ctx() const { return ctx_.load(); }
  // Readable while a message waits; -1 without a context.
  int64_t fd() const {
    void* ctx = ctx_.load();
    return ctx ? lib_.poll_fd(ctx) : -1;
  }

  // Submits `method` and pumps this thread until its reply, or `timeout`.
  Reply call(Method method, const Bytes& req, std::chrono::milliseconds timeout) {
    std::lock_guard<std::recursive_mutex> lock(lock_);
    return callWith(
        [&](uint64_t* id) { return method(ctx_, req.data(), req.size(), id); }, timeout);
  }

  // The same for a static export, on a host attach()ed to the static context.
  Reply call(StaticMethod method, const Bytes& req, std::chrono::milliseconds timeout) {
    std::lock_guard<std::recursive_mutex> lock(lock_);
    return callWith([&](uint64_t* id) { return method(req.data(), req.size(), id); },
                    timeout);
  }

  // Submits without waiting and hands the reply to `done` when the pump sees
  // it. Returns the library's code; `done` never runs unless it is OK.
  int submit(Method method, const Bytes& req, Done done) {
    std::lock_guard<std::recursive_mutex> lock(lock_);
    if (!ctx_) return NIMFFI_RET_INVALID_CTX;
    uint64_t id = 0;
    const int rc = method(ctx_, req.data(), req.size(), &id);
    if (rc == NIMFFI_RET_OK) done_[id] = done ? std::move(done) : [](const Reply&) {};
    poll();  // whatever is already queued, including a reply that came at once
    return rc;
  }

  // Answers a REVERSE_CALL. Any thread. `payload` is the reply's CBOR on
  // NIMFFI_RET_OK, otherwise UTF-8 text.
  void reverseReply(uint64_t call_id, int ret, const uint8_t* payload, size_t len) {
    void* ctx = ctx_.load();  // no lock: replies come from other threads
    if (!ctx) return;
    lib_.reverse_reply(ctx, call_id, ret, payload, len);
  }
  void reverseReply(uint64_t call_id, int ret, const Bytes& payload) {
    reverseReply(call_id, ret, payload.data(), payload.size());
  }
  void reverseReply(uint64_t call_id, int ret, const std::string& text) {
    reverseReply(call_id, ret, reinterpret_cast<const uint8_t*>(text.data()), text.size());
  }

  // Dispatches every message queued right now and returns how many it served; never
  // blocks. Call it once per iteration or tick of a loop of your own, or when fd()
  // is readable in a loop that watches descriptors.
  size_t poll() {
    std::unique_lock<std::recursive_mutex> lock(lock_, std::try_to_lock);
    if (!lock.owns_lock()) return 0;  // another thread is serving already
    return serveLocked();
  }

#ifndef NIM_FFI_NO_RUNLOOP
  // Blocks the calling thread, serving messages as they arrive, until stop() or the
  // context closes. A stop() that arrives while nothing is running ends the next
  // runLoop() at once; each stop() ends one runLoop().
  void runLoop() {
    {
      std::lock_guard<std::mutex> guard(loop_mu_);
      looping_ = true;
      loop_thread_ = std::this_thread::get_id();
    }
    while (ctx_ && !stop_.exchange(false)) {
      void* c = ctx_.load();
      if (!c) break;
      waitReadable(lib_.poll_fd(c), kWaitSliceMs);
      std::unique_lock<std::recursive_mutex> lock(lock_, std::try_to_lock);
      if (!lock.owns_lock()) {
        // Another thread is serving the queue; do not spin while it holds the lock.
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        continue;
      }
      serveLocked();  // also without a wake: a missed signal costs one slice
    }
    {
      std::lock_guard<std::mutex> guard(loop_mu_);
      looping_ = false;
    }
    loop_cv_.notify_all();
  }
#endif

  // Ends the running runLoop(), or the next one to start. Any thread, including a handler.
  void stop() { stop_ = true; }

 private:
  // Time slice of one blocking poll while waiting: long enough to stay idle
  // cheaply, short enough that the deadline is honoured.
  static constexpr int32_t kSliceMs = 50;

  static std::string timeoutText(std::chrono::milliseconds t) {
    return "no reply within " + std::to_string(t.count()) + " ms";
  }

  static Reply decodeReply(const PollResult* m) {
    Reply r;
    r.ret = m->ret_code;
    if (m->ret_code == NIMFFI_RET_OK) {
      r.payload.assign(m->payload, m->payload + m->len);
    } else {
      r.error.assign(reinterpret_cast<const char*>(m->payload), m->len);
    }
    return r;
  }

  size_t serveLocked() {
    if (!ctx_) return 0;
    size_t served = 0;
    for (;;) {
      const PollResult* m = nullptr;
      const int rc = lib_.poll(ctx_, 0, &m);
      if (rc == NIMFFI_RET_OK && m) {
        dispatch(m);
        ++served;
        if (!ctx_) return served;
      } else {
        if (rc == NIMFFI_RET_CLOSED || rc == NIMFFI_RET_INVALID_CTX) markClosed();
        return served;
      }
    }
  }

  void waitLoopExit() {
    std::unique_lock<std::mutex> guard(loop_mu_);
    if (looping_ && loop_thread_ != std::this_thread::get_id()) {
      loop_cv_.wait(guard, [&] { return !looping_; });
    }
  }

  // Runs `f`, a handler or callback of the host's, and reports it when it kept
  // the pump longer than the limit.
  template <class F>
  void timed(const char* what, F&& f) {
    const auto start = std::chrono::steady_clock::now();
    f();
    const auto took = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    if (slow_limit_.count() > 0 && took > slow_limit_ && on_slow_) on_slow_(what, took);
  }

#ifndef NIM_FFI_NO_RUNLOOP
  static constexpr int kWaitSliceMs = 50;  // how soon runLoop() notices stop()

  // Waits up to `ms` for the library's wake handle. The handle is already an epoll
  // descriptor, a kqueue or an Event, so a plain poll() or wait is enough.
  static void waitReadable(int64_t fd, int ms) {
#ifdef _WIN32
    if (WaitForSingleObject(reinterpret_cast<HANDLE>(fd), static_cast<DWORD>(ms)) ==
        WAIT_FAILED) {
      std::this_thread::sleep_for(std::chrono::milliseconds(ms));  // bad handle: do not spin
    }
#else
    pollfd p{static_cast<int>(fd), POLLIN, 0};
    const int n = ::poll(&p, 1, ms);
    if (n > 0 && !(p.revents & POLLIN)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(ms));  // error: do not spin
    }
#endif
  }
#endif

  template <class Submit>
  Reply callWith(Submit submit, std::chrono::milliseconds timeout) {
    Reply r;
    if (!ctx_) {
      r.ret = NIMFFI_RET_INVALID_CTX;
      r.error = "no context";
      return r;
    }
    uint64_t id = 0;
    const int rc = submit(&id);
    if (rc != NIMFFI_RET_OK) {
      // no reply will come for this call; the code says why
      r.ret = rc;
      r.error = "not accepted, rc=" + std::to_string(rc);
      return r;
    }
    bool timedOut = false;
    r = waitFor(id, timeout, timedOut);
    if (timedOut) {
      r.error = timeoutText(timeout);
      done_[id] = [](const Reply&) {};  // the late reply is still promised: drop it on arrival
    }
    return r;
  }

  // The context is gone: nothing more will come, and every waiter or `submit`
  // callback is told so instead of waiting for a reply that cannot arrive.
  void markClosed() {
    ctx_ = nullptr;
    failPending(NIMFFI_RET_CLOSED, "context closed");
  }

  void failPending(int ret, const char* text) {
    auto pending = std::move(done_);
    done_.clear();
    settled_.clear();
    Reply r;
    r.ret = ret;
    r.error = text;
    for (auto& entry : pending) entry.second(r);
  }

  // `timedOut` is set only when the host's own deadline ran out, so a library
  // reply that itself carries NIMFFI_RET_TIMEOUT is not mistaken for it.
  Reply waitFor(uint64_t id, std::chrono::milliseconds timeout, bool& timedOut) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    for (;;) {
      if (auto it = settled_.find(id); it != settled_.end()) {
        Reply r = std::move(it->second);
        settled_.erase(it);
        return r;
      }
      Reply r;
      if (!ctx_) {
        r.ret = NIMFFI_RET_CLOSED;
        r.error = "context closed while waiting";
        return r;
      }
      const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
          deadline - std::chrono::steady_clock::now());
      if (left.count() <= 0) {
        r.ret = NIMFFI_RET_TIMEOUT;
        timedOut = true;
        return r;
      }
      const PollResult* m = nullptr;
      const int rc = lib_.poll(ctx_, static_cast<int32_t>(std::min<int64_t>(left.count(), kSliceMs)), &m);
      if (rc == NIMFFI_RET_OK && m) {
        dispatch(m);
      } else if (rc != NIMFFI_RET_TIMEOUT && rc != NIMFFI_RET_OK) {
        if (rc == NIMFFI_RET_CLOSED || rc == NIMFFI_RET_INVALID_CTX) markClosed();
        r.ret = rc;
        r.error = "poll rc=" + std::to_string(rc);
        return r;
      }
    }
  }

  void dispatch(const PollResult* m) {
    switch (m->kind) {
      case NIMFFI_MSG_REPLY:
        if (auto it = done_.find(m->id); it != done_.end()) {
          Done done = std::move(it->second);
          done_.erase(it);
          timed("a submit callback", [&] { done(decodeReply(m)); });
        } else {
          settled_[m->id] = decodeReply(m);  // kept until its caller asks
        }
        break;
      case NIMFFI_MSG_EVENT:
        if (on_event_) {
          timed("an event handler", [&] { on_event_(m->name_id, m->payload, m->len); });
        }
        break;
      case NIMFFI_MSG_REVERSE_CALL:
        if (on_reverse_) {
          timed("a reverse-call handler",
                [&] { on_reverse_(m->id, m->name_id, m->payload, m->len); });
        } else {
          reverseReply(m->id, NIMFFI_RET_ERR, std::string("no handler for reverse calls"));
        }
        break;
      case NIMFFI_MSG_CLOSED:
        markClosed();  // waiters see NIMFFI_RET_CLOSED
        break;
      default:
        break;  // STALE and the liveness ticks: the deadline decides
    }
  }

  Library lib_;
  std::atomic<void*> ctx_{nullptr};  // read from any thread; written under lock_
  std::chrono::milliseconds slow_limit_{50};
  SlowHandler on_slow_;
  std::atomic<bool> stop_{false};
  std::mutex loop_mu_;  // looping_ and loop_thread_: whether, and on which thread, runLoop() runs
  std::condition_variable loop_cv_;
  bool looping_ = false;
  std::thread::id loop_thread_;
  bool owned_ = true;  // false for an attach()ed context: the library owns it
  std::recursive_mutex lock_;  // the queue is pumped from one thread at a time
  std::map<uint64_t, Reply> settled_;  // replies seen before their waiter asked
  std::map<uint64_t, Done> done_;      // replies nobody waits for
  EventHandler on_event_;
  ReverseHandler on_reverse_;
};

}  // namespace nim_ffi

#endif  // NIM_FFI_HOST_HPP
