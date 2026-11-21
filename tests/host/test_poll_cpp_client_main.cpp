// The generated poll-mode client (pollfake.hpp, written by test_cpp_poll_codegen.nim)
// against a scripted fake `pollfake` library: create, a typed call, and an event
// that arrives ahead of the reply and is delivered to its typed listener.
#include "pollfake.hpp"

#include <cstdio>
#include <cstdlib>
#include <deque>
#include <atomic>
#include <mutex>
#include <thread>

#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); std::exit(1); } } while (0)

struct Msg { uint32_t kind; uint64_t id; uint64_t name_id; int ret; std::vector<uint8_t> payload; };

static std::deque<Msg> queue;
static std::mutex qmu;  // runLoop() polls on another thread while main pushes
static PollResult cur;
static std::vector<uint8_t> curPayload;
static uint64_t nextId = 0;
static int fakeCtx = 1;

extern "C" {
int pollfake_create(const uint8_t*, size_t, void** ctx, uint64_t* id) {
  *ctx = &fakeCtx;
  *id = ++nextId;
  queue.push_back({NIMFFI_MSG_REPLY, *id, 0, NIMFFI_RET_OK, {}});
  return NIMFFI_RET_OK;
}
int pollfake_destroy(void*) { return NIMFFI_RET_OK; }
int pollfake_echo(void*, const uint8_t*, size_t, uint64_t* id) {
  *id = ++nextId;
  auto tick = encodeCborFFI(TickPayload{7});
  queue.push_back({NIMFFI_MSG_EVENT, 0, nimffi_name_id("on_tick"), NIMFFI_RET_OK, tick.value()});
  auto reply = encodeCborFFI(std::string("echoed"));
  queue.push_back({NIMFFI_MSG_REPLY, *id, 0, NIMFFI_RET_OK, reply.value()});
  return NIMFFI_RET_OK;
}
static int staticCtx = 2;
static int staticCtxCalls = 0;
// Not ready on the first call, as a library still starting up would be.
void* pollfake_static_ctx(void) { return staticCtxCalls++ == 0 ? nullptr : &staticCtx; }
int pollfake_ping(const uint8_t*, size_t, uint64_t* id) {
  *id = ++nextId;
  auto reply = encodeCborFFI(std::string("pong"));
  queue.push_back({NIMFFI_MSG_REPLY, *id, 0, NIMFFI_RET_OK, reply.value()});
  return NIMFFI_RET_OK;
}
int pollfake_poll(void*, int32_t timeoutMs, const PollResult** out) {
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
int64_t pollfake_poll_fd(void*) { return 7; }
int pollfake_reverse_reply(void*, uint64_t, int, const uint8_t*, size_t) { return NIMFFI_RET_OK; }
int pollfake_shutdown(void) { return NIMFFI_RET_OK; }
}

int main() {
  auto created = FakeCtx::create(std::string("t"), std::chrono::milliseconds(500));
  CHECK(created.isOk());
  auto& ctx = *created.value();

  std::atomic<int64_t> seen{0};
  const auto handle = ctx.addOnTickListener([&](const TickPayload& t) { seen = t.n; });
  CHECK(handle.id != 0);

  auto reply = ctx.echo(std::string("hi"));
  CHECK(reply.isOk() && reply.value() == "echoed");
  CHECK(seen == 7);  // the event that came ahead of the reply

  CHECK(ctx.removeEventListener(handle));
  seen = 0;
  CHECK(ctx.echo(std::string("again")).isOk());
  CHECK(seen == 0);  // removed: no longer delivered
  auto early = FakeCtx::ping();  // the static context is not ready yet
  CHECK(early.isErr() && early.error().rfind("ping: ", 0) == 0);
  auto pong = FakeCtx::ping();   // attached on the next call: a failure is not remembered
  CHECK(pong.isOk() && pong.value() == "pong");
  // poll() and runLoop() serve events on the calling thread
  {
    std::lock_guard<std::mutex> guard(qmu);
    queue.push_back({NIMFFI_MSG_EVENT, 0, nimffi_name_id("on_tick"), NIMFFI_RET_OK,
                     encodeCborFFI(TickPayload{11}).value()});
  }
  seen = 0;
  const auto handle2 = ctx.addOnTickListener([&](const TickPayload& t) { seen = t.n; });
  CHECK(ctx.poll() == 1 && seen == 11);
  {
    std::lock_guard<std::mutex> guard(qmu);
    queue.push_back({NIMFFI_MSG_EVENT, 0, nimffi_name_id("on_tick"), NIMFFI_RET_OK,
                     encodeCborFFI(TickPayload{12}).value()});
  }
  std::thread runner([&] { ctx.runLoop(); });
  for (int i = 0; i < 100 && seen != 12; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  CHECK(seen == 12);
  ctx.stop();
  runner.join();
  CHECK(ctx.removeEventListener(handle2));
  std::puts("ok");
  return 0;
}
