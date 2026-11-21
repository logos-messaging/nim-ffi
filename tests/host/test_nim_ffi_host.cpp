// nim_ffi::Host against a scripted fake library: no Nim involved, so the pump's own
// behaviour (ordering, deadlines, late replies, reverse calls, closing) is pinned.
#include "../../host/nim_ffi_host.hpp"

#include <cstdio>
#include <cstdlib>
#include <deque>
#include <atomic>
#include <mutex>
#include <thread>
#ifndef _WIN32
#include <unistd.h>
#endif

using namespace nim_ffi;

#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); std::exit(1); } } while (0)

struct Msg { uint32_t kind; uint64_t id; uint64_t name_id; int ret; Bytes payload; };

static std::deque<Msg> queue;           // what the fake library will hand out
static PollResult cur;                  // the message being handed out
static Bytes curPayload;                // its payload, alive until the next poll
static uint64_t nextId = 0;
static uint64_t lastReverseCall = 0;
static int lastReverseRet = -1;
static int fakeCtx = 1;
static int pollRet = -1;                // when set, poll answers with it
static int createRet = NIMFFI_RET_OK;

static int fakeCreate(const uint8_t*, size_t, void** ctx, uint64_t* id) {
  if (createRet != NIMFFI_RET_OK) return createRet;
  *ctx = &fakeCtx;
  *id = ++nextId;
  queue.push_back({NIMFFI_MSG_REPLY, *id, 0, NIMFFI_RET_OK, {}});
  return NIMFFI_RET_OK;
}
static int fakeDestroy(void*) { return NIMFFI_RET_OK; }
static std::mutex qmu;  // the pump thread polls while the test thread pushes
static int fakePoll(void*, int32_t timeoutMs, const PollResult** out) {
  if (pollRet >= 0) return pollRet;
  std::unique_lock<std::mutex> guard(qmu);
  if (queue.empty()) {
    guard.unlock();
    std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
    return NIMFFI_RET_TIMEOUT;
  }
  Msg m = std::move(queue.front());
  queue.pop_front();
  curPayload = std::move(m.payload);
  cur = PollResult{};
  cur.struct_size = sizeof(PollResult);
  cur.kind = m.kind;
  cur.id = m.id;
  cur.name_id = m.name_id;
  cur.ret_code = m.ret;
  cur.payload = curPayload.data();
  cur.len = curPayload.size();
  *out = &cur;
  return NIMFFI_RET_OK;
}
static std::atomic<int> pollFdCalls{0};
static int64_t fakePollFd(void*) {
  ++pollFdCalls;
  return 7;
}
static int fakeReverseReply(void*, uint64_t callId, int ret, const uint8_t*, size_t) {
  lastReverseCall = callId;
  lastReverseRet = ret;
  return NIMFFI_RET_OK;
}

// `script` queues what the library says in answer to one request.
static void (*script)(uint64_t id) = nullptr;
static int fakeMethod(void*, const uint8_t*, size_t, uint64_t* id) {
  *id = ++nextId;
  if (script) script(*id);
  return NIMFFI_RET_OK;
}

static Library lib() { return {fakeCreate, fakeDestroy, fakePoll, fakePollFd, fakeReverseReply}; }
static const auto kShort = std::chrono::milliseconds(200);

static Host& up(Host& h) {
  CHECK(h.create({}, kShort).ret == NIMFFI_RET_OK);
  return h;
}

int main() {
  {  // an event that precedes the reply is dispatched on the way
    Host h(lib());
    up(h);
    int events = 0;
    h.onEvent([&](uint64_t n, const uint8_t*, size_t) { events += (n == 42); });
    script = [](uint64_t id) {
      queue.push_back({NIMFFI_MSG_EVENT, 0, 42, NIMFFI_RET_OK, {1}});
      queue.push_back({NIMFFI_MSG_REPLY, id, 0, NIMFFI_RET_OK, {9, 9}});
    };
    Reply r = h.call(fakeMethod, {}, kShort);
    CHECK(r.ret == NIMFFI_RET_OK && r.payload == Bytes({9, 9}) && events == 1);
  }
  {  // a call that times out; its late reply must not be mistaken for the next one's
    Host h(lib());
    up(h);
    script = nullptr;
    Reply late = h.call(fakeMethod, {}, std::chrono::milliseconds(60));
    CHECK(late.ret == NIMFFI_RET_TIMEOUT && !late.error.empty());
    queue.push_back({NIMFFI_MSG_REPLY, nextId, 0, NIMFFI_RET_OK, {1}});  // the late one
    script = [](uint64_t id) { queue.push_back({NIMFFI_MSG_REPLY, id, 0, NIMFFI_RET_OK, {2}}); };
    Reply next = h.call(fakeMethod, {}, kShort);
    CHECK(next.ret == NIMFFI_RET_OK && next.payload == Bytes({2}));
    h.poll();
    CHECK(queue.empty());
  }
  {  // a reverse call raised while waiting is answered from the handler
    Host h(lib());
    up(h);
    h.onReverseCall([&](uint64_t call, uint64_t, const uint8_t*, size_t) {
      h.reverseReply(call, NIMFFI_RET_OK, Bytes{});
    });
    script = [](uint64_t id) {
      queue.push_back({NIMFFI_MSG_REVERSE_CALL, 77, 5, NIMFFI_RET_OK, {}});
      queue.push_back({NIMFFI_MSG_REPLY, id, 0, NIMFFI_RET_OK, {}});
    };
    CHECK(h.call(fakeMethod, {}, kShort).ret == NIMFFI_RET_OK);
    CHECK(lastReverseCall == 77 && lastReverseRet == NIMFFI_RET_OK);
  }
  {  // with no handler a reverse call is refused, not left hanging
    Host h(lib());
    up(h);
    script = [](uint64_t id) {
      queue.push_back({NIMFFI_MSG_REVERSE_CALL, 78, 5, NIMFFI_RET_OK, {}});
      queue.push_back({NIMFFI_MSG_REPLY, id, 0, NIMFFI_RET_OK, {}});
    };
    h.call(fakeMethod, {}, kShort);
    CHECK(lastReverseCall == 78 && lastReverseRet == NIMFFI_RET_ERR);
  }
  {  // a closed context ends the wait
    Host h(lib());
    up(h);
    script = [](uint64_t) { queue.push_back({NIMFFI_MSG_CLOSED, 0, 0, NIMFFI_RET_OK, {}}); };
    Reply r = h.call(fakeMethod, {}, kShort);
    CHECK(r.ret == NIMFFI_RET_CLOSED && !h.alive());
  }
  {  // a reply nobody waits for goes to `done`, once
    Host h(lib());
    up(h);
    script = [](uint64_t id) { queue.push_back({NIMFFI_MSG_REPLY, id, 0, NIMFFI_RET_OK, {3}}); };
    int seen = 0;
    CHECK(h.submit(fakeMethod, {}, [&](const Reply& r) { seen += (r.payload == Bytes({3})); }) ==
          NIMFFI_RET_OK);
    h.poll();
    CHECK(seen == 1);
  }
  {  // a library reply that itself says TIMEOUT is a reply, not the host's deadline
    Host h(lib());
    up(h);
    script = [](uint64_t id) { queue.push_back({NIMFFI_MSG_REPLY, id, 0, NIMFFI_RET_TIMEOUT, {'x'}}); };
    Reply r = h.call(fakeMethod, {}, kShort);
    CHECK(r.ret == NIMFFI_RET_TIMEOUT && r.error == "x");
    script = [](uint64_t id) { queue.push_back({NIMFFI_MSG_REPLY, id, 0, NIMFFI_RET_OK, {}}); };
    CHECK(h.call(fakeMethod, {}, kShort).ret == NIMFFI_RET_OK);
    h.poll();  // nothing stale left behind
    CHECK(queue.empty());
  }
  {  // a submit still pending when the context closes hears about it
    Host h(lib());
    up(h);
    script = nullptr;
    int closed = 0;
    CHECK(h.submit(fakeMethod, {}, [&](const Reply& r) { closed += (r.ret == NIMFFI_RET_CLOSED); }) ==
          NIMFFI_RET_OK);
    queue.push_back({NIMFFI_MSG_CLOSED, 0, 0, NIMFFI_RET_OK, {}});
    h.poll();
    CHECK(closed == 1 && !h.alive());
  }
  {  // destroy() also fails what is pending
    Host h(lib());
    up(h);
    script = nullptr;
    int closed = 0;
    h.submit(fakeMethod, {}, [&](const Reply& r) { closed += (r.ret == NIMFFI_RET_CLOSED); });
    h.destroy();
    CHECK(closed == 1);
  }
  {  // a poll that says the context is closed ends it, instead of draining forever
    Host h(lib());
    up(h);
    pollRet = NIMFFI_RET_CLOSED;
    h.poll();
    pollRet = -1;
    CHECK(!h.alive());
  }
  {  // a create that is refused leaves no context behind
    Host h(lib());
    createRet = NIMFFI_RET_ERR;
    Reply r = h.create({}, kShort);
    createRet = NIMFFI_RET_OK;
    CHECK(r.ret == NIMFFI_RET_ERR && !h.alive());
  }
  {  // poll() does not wait for a call another thread is pumping
    Host h(lib());
    up(h);
    script = nullptr;
    std::thread t([&] { h.call(fakeMethod, {}, std::chrono::milliseconds(300)); });
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    const auto start = std::chrono::steady_clock::now();
    h.poll();
    CHECK(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(100));
    t.join();
  }
  {  // a host attached to a context the library owns serves static calls and never destroys it
    static int destroyed = 0;
    Library l = lib();
    l.destroy = [](void*) { ++destroyed; return NIMFFI_RET_OK; };
    {
      Host h(l);
      CHECK(!h.attach(nullptr));
      CHECK(h.attach(&fakeCtx) && h.alive());
      CHECK(!h.attach(&fakeCtx));  // already has a context
      queue.push_back({NIMFFI_MSG_REPLY, nextId + 1, 0, NIMFFI_RET_OK, {5}});
      Reply r = h.call(
          [](const uint8_t*, size_t, uint64_t* id) { *id = ++nextId; return NIMFFI_RET_OK; }, {},
          kShort);
      CHECK(r.ret == NIMFFI_RET_OK && r.payload == Bytes({5}));
    }
    CHECK(destroyed == 0);
  }
  {  // a handler that holds the pump too long is reported, with its name and time
    Host h(lib());
    up(h);
    std::string what;
    std::chrono::milliseconds took{0};
    h.onSlowHandler([&](const char* w, std::chrono::milliseconds t) { what = w; took = t; });
    h.onEvent([](uint64_t, const uint8_t*, size_t) {
      std::this_thread::sleep_for(std::chrono::milliseconds(120));
    });
    queue.push_back({NIMFFI_MSG_EVENT, 0, 1, NIMFFI_RET_OK, {}});
    h.poll();
    CHECK(what.find("event") != std::string::npos && took >= std::chrono::milliseconds(100));
    what.clear();
    h.setSlowHandlerLimit(std::chrono::milliseconds(0));  // off
    queue.push_back({NIMFFI_MSG_EVENT, 0, 1, NIMFFI_RET_OK, {}});
    h.poll();
    CHECK(what.empty());
  }
  {  // poll() serves what is waiting and says how many
    Host h(lib());
    up(h);
    int events = 0;
    h.onEvent([&](uint64_t, const uint8_t*, size_t) { ++events; });
    CHECK(h.poll() == 0);
    queue.push_back({NIMFFI_MSG_EVENT, 0, 1, NIMFFI_RET_OK, {}});
    queue.push_back({NIMFFI_MSG_EVENT, 0, 1, NIMFFI_RET_OK, {}});
    CHECK(h.poll() == 2 && events == 2);
    CHECK(h.poll() == 0);
  }
  {  // runLoop() serves on the calling thread until stop(); a stop() beforehand ends it at once
    Host h(lib());
    up(h);
    std::atomic<int> events{0};
    h.onEvent([&](uint64_t, const uint8_t*, size_t) { ++events; });
    h.stop();
    h.runLoop();  // returns immediately, and the stop is consumed
    std::thread t([&] { h.runLoop(); });
    {
      std::lock_guard<std::mutex> guard(qmu);
      queue.push_back({NIMFFI_MSG_EVENT, 0, 1, NIMFFI_RET_OK, {}});
    }
    for (int i = 0; i < 100 && events.load() == 0; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
    CHECK(events.load() == 1);  // served without a wake: the slice bounds the delay
    h.stop();
    t.join();
  }
  {  // runLoop() also ends when the context closes
    Host h(lib());
    up(h);
    std::thread t([&] { h.runLoop(); });
    {
      std::lock_guard<std::mutex> guard(qmu);
      queue.push_back({NIMFFI_MSG_CLOSED, 0, 0, NIMFFI_RET_OK, {}});
    }
    t.join();  // would hang if runLoop() ignored the close
    CHECK(!h.alive());
  }
#ifndef _WIN32
  {  // runLoop() does not spin while another thread holds the serving lock
    int fds[2];
    CHECK(pipe(fds) == 0);
    static int pipeRead = fds[0];
    Library l = lib();
    l.poll_fd = [](void*) -> int64_t {
      ++pollFdCalls;
      return pipeRead;
    };
    const char byte = 'x';
    CHECK(write(fds[1], &byte, 1) == 1);  // the line stays raised: messages "wait"
    Host h(l);
    up(h);
    h.onEvent([](uint64_t, const uint8_t*, size_t) {
      std::this_thread::sleep_for(std::chrono::milliseconds(300));  // a slow handler
    });
    h.setSlowHandlerLimit(std::chrono::milliseconds(0));
    {
      std::lock_guard<std::mutex> guard(qmu);
      queue.push_back({NIMFFI_MSG_EVENT, 0, 1, NIMFFI_RET_OK, {}});
    }
    pollFdCalls = 0;
    std::thread serving([&] { h.poll(); });  // holds the lock for 300 ms
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    std::thread loop([&] { h.runLoop(); });
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    CHECK(pollFdCalls.load() < 1000);  // a busy loop would make millions
    h.stop();
    loop.join();
    serving.join();
    close(fds[0]);
    close(fds[1]);
  }
#endif
  {  // destroying a Host stops and waits for a runLoop() still running on another thread
    auto* h = new Host(lib());
    up(*h);
    std::thread loop([&] { h->runLoop(); });
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    delete h;  // must not free the Host under the loop thread
    loop.join();
  }
  {  // a stop() that arrives after one was consumed is kept for the next runLoop()
    Host h(lib());
    up(h);
    h.stop();
    h.runLoop();  // consumes it
    std::thread t([&] { h.runLoop(); });
    std::this_thread::sleep_for(std::chrono::milliseconds(120));
    h.stop();
    t.join();  // a stale flag would have ended the loop early; a lost stop would hang here
  }
  std::puts("ok");
  return 0;
}
