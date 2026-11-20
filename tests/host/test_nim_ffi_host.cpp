// nim_ffi::Host against a scripted fake library: no Nim involved, so the pump's own
// behaviour (ordering, deadlines, late replies, reverse calls, closing) is pinned.
#include "../../host/nim_ffi_host.hpp"

#include <cstdio>
#include <cstdlib>
#include <deque>
#include <thread>

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
static int fakePoll(void*, int32_t timeoutMs, const PollResult** out) {
  if (pollRet >= 0) return pollRet;
  if (queue.empty()) {
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
static int64_t fakePollFd(void*) { return 7; }
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
    h.drain();
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
    h.drain();
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
    h.drain();  // nothing stale left behind
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
    h.drain();
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
    h.drain();
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
  {  // drain() does not wait for a call another thread is pumping
    Host h(lib());
    up(h);
    script = nullptr;
    std::thread t([&] { h.call(fakeMethod, {}, std::chrono::milliseconds(300)); });
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    const auto start = std::chrono::steady_clock::now();
    h.drain();
    CHECK(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(100));
    t.join();
  }
  std::puts("ok");
  return 0;
}
