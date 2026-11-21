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
struct ReverseAnswerSeen { uint64_t call; int ret; std::vector<uint8_t> payload; };
static std::mutex revMu;
static std::vector<ReverseAnswerSeen> revAnswers;
int pollfake_reverse_reply(void*, uint64_t call, int ret, const uint8_t* payload, size_t len) {
  std::lock_guard<std::mutex> guard(revMu);
  revAnswers.push_back({call, ret, std::vector<uint8_t>(payload, payload + len)});
  return NIMFFI_RET_OK;
}
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
  // Reverse calls: the library asks, the typed handler answers through a Responder.
  const auto pushReverse = [](uint64_t call, const char* wire, std::vector<uint8_t> args) {
    std::lock_guard<std::mutex> guard(qmu);
    queue.push_back({NIMFFI_MSG_REVERSE_CALL, call, nimffi_name_id(wire), NIMFFI_RET_OK, std::move(args)});
  };
  const auto lastAnswer = [] {
    std::lock_guard<std::mutex> guard(revMu);
    return revAnswers.back();
  };
  const auto answerCount = [] {
    std::lock_guard<std::mutex> guard(revMu);
    return revAnswers.size();
  };
  const auto text = [](const std::vector<uint8_t>& payload) {
    return std::string(payload.begin(), payload.end());
  };

  ctx.onFetchHost([](const FetchHostHostCall& a, Responder<std::string> respond) {
    respond.ok("body of " + a.url);
  });
  pushReverse(500, "fetch_host", encodeCborFFI(FetchHostHostCall{"u"}).value());
  CHECK(ctx.poll() == 1);
  CHECK(lastAnswer().call == 500 && lastAnswer().ret == NIMFFI_RET_OK);
  CHECK(decodeCborFFI<std::string>(lastAnswer().payload).value() == "body of u");

  ctx.onHostTick([](Responder<std::string> respond) { respond.ok("tick"); });
  pushReverse(501, "host_tick", {0xa0});
  CHECK(ctx.poll() == 1);
  CHECK(lastAnswer().call == 501 && decodeCborFFI<std::string>(lastAnswer().payload).value() == "tick");

  ctx.onHostNotify([](const FetchHostHostCall&, Responder<void> respond) { respond.ok(); });
  pushReverse(502, "host_notify", encodeCborFFI(FetchHostHostCall{"x"}).value());
  CHECK(ctx.poll() == 1);
  CHECK(lastAnswer().call == 502 && lastAnswer().ret == NIMFFI_RET_OK);

  // answered later, from another thread: the pump is free in between
  Responder<std::string> held{std::weak_ptr<nim_ffi::Host>{}, 0};
  std::atomic<bool> haveHeld{false};
  ctx.onFetchHost([&](const FetchHostHostCall&, Responder<std::string> respond) {
    held = respond;
    haveHeld = true;
  });
  const auto before = answerCount();
  pushReverse(503, "fetch_host", encodeCborFFI(FetchHostHostCall{"later"}).value());
  CHECK(ctx.poll() == 1 && haveHeld.load());
  CHECK(answerCount() == before);  // nothing answered yet
  std::thread([held] { held.ok("late"); }).join();
  CHECK(lastAnswer().call == 503 && decodeCborFFI<std::string>(lastAnswer().payload).value() == "late");
  held.err("a second answer is ignored");
  CHECK(lastAnswer().call == 503 && lastAnswer().ret == NIMFFI_RET_OK);

  // a handler that drops its Responder: the library hears at once
  ctx.onFetchHost([](const FetchHostHostCall&, Responder<std::string>) {});
  pushReverse(504, "fetch_host", encodeCborFFI(FetchHostHostCall{"y"}).value());
  CHECK(ctx.poll() == 1);
  CHECK(lastAnswer().call == 504 && lastAnswer().ret == NIMFFI_RET_ERR);
  CHECK(text(lastAnswer().payload).find("dropped") != std::string::npos);

  // arguments that do not decode, and a call nobody handles
  ctx.onFetchHost([](const FetchHostHostCall&, Responder<std::string> respond) { respond.ok("never"); });
  pushReverse(505, "fetch_host", {0xff});
  CHECK(ctx.poll() == 1);
  CHECK(lastAnswer().call == 505 && lastAnswer().ret == NIMFFI_RET_ERR);
  CHECK(text(lastAnswer().payload).find("could not decode the arguments") != std::string::npos);
  pushReverse(506, "unknown_call", {0xa0});
  CHECK(ctx.poll() == 1);
  CHECK(lastAnswer().call == 506 && lastAnswer().ret == NIMFFI_RET_ERR);
  CHECK(text(lastAnswer().payload).find("no handler") != std::string::npos);
  std::puts("ok");
  return 0;
}
