// Basic C++ end-to-end tests for the auto-generated `timer` bindings.
//
// These tests link against the same `timer_headers` INTERFACE library and Nim
// shared object used by `examples/timer/cpp_bindings/main.cpp`. They exercise
// the full FFI round-trip — CBOR encode -> Nim FFI thread -> chronos -> CBOR
// decode -> C++ — to validate that a binding produced by `nimble
// genbindings_cpp` is callable end-to-end from C++.
// The CrossLibrary test also loads `examples/echo/cpp_bindings` to prove
// two nim-ffi libraries can coexist in one process.
//
// The generated bindings never throw: every call returns a Result<T>. The
// `mustOk` helper below unwraps a Result and fails the test (without
// aborting) when it carries an error, so single-threaded tests read as if
// the value came back directly.

#include "my_timer.hpp"
#include "echo.hpp"

#include <atomic>
#include <chrono>
#include <future>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

namespace {

// Unwrap a Result<T> in a single-threaded test context. On error it records a
// non-fatal gtest failure and returns a default-constructed T so the caller
// can keep going (subsequent expectations will fail loudly).
template <typename T>
T mustOk(Result<T> r) {
    if (r.isErr()) {
        ADD_FAILURE() << "unexpected FFI error: " << r.error();
        return T{};
    }
    return r.take();
}

std::unique_ptr<MyTimerCtx> makeCtx(const std::string& name = "e2e") {
    return mustOk(MyTimerCtx::create(TimerConfig{name}));
}

} // namespace

TEST(TimerE2E, CreateAndDestroy) {
    auto ctx = makeCtx("create-destroy");
    // Destruction happens at scope exit via MyTimerCtx::~MyTimerCtx,
    // which invokes timer_destroy on the underlying FFI context.
    SUCCEED();
}

TEST(TimerE2E, VersionSync) {
    auto ctx = makeCtx("version-sync");
    const auto v = mustOk(ctx->version());
    EXPECT_EQ(v, "nim-timer v0.1.0");
}

TEST(TimerE2E, VersionAsync) {
    auto ctx = makeCtx("version-async");
    auto fut = ctx->versionAsync();
    EXPECT_EQ(mustOk(fut.get()), "nim-timer v0.1.0");
}

TEST(TimerE2E, EchoRoundTripsMessageAndTimerName) {
    auto ctx = makeCtx("echo-ctx");
    const auto resp = mustOk(ctx->echo(EchoRequest{"hello", 10}));
    EXPECT_EQ(resp.echoed, "hello");
    EXPECT_EQ(resp.timerName, "echo-ctx");
}

TEST(TimerE2E, EchoHonoursDelay) {
    auto ctx = makeCtx("echo-delay");
    constexpr int delayMs = 150;

    const auto start = std::chrono::steady_clock::now();
    const auto resp = mustOk(ctx->echo(EchoRequest{"waited", delayMs}));
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count();

    EXPECT_EQ(resp.echoed, "waited");
    EXPECT_GE(elapsed, delayMs - 20) // allow a tiny scheduler-precision slack
        << "echo returned too early: " << elapsed << "ms < " << delayMs << "ms";
}

TEST(TimerE2E, ConcurrentAsyncCallsAreIndependent) {
    auto ctx = makeCtx("concurrent");

    auto f1 = ctx->echoAsync(EchoRequest{"one", 80});
    auto f2 = ctx->echoAsync(EchoRequest{"two", 40});
    auto f3 = ctx->echoAsync(EchoRequest{"three", 20});

    const auto r3 = mustOk(f3.get());
    const auto r2 = mustOk(f2.get());
    const auto r1 = mustOk(f1.get());

    EXPECT_EQ(r1.echoed, "one");
    EXPECT_EQ(r2.echoed, "two");
    EXPECT_EQ(r3.echoed, "three");
    EXPECT_EQ(r1.timerName, "concurrent");
    EXPECT_EQ(r2.timerName, "concurrent");
    EXPECT_EQ(r3.timerName, "concurrent");
}

TEST(TimerE2E, ComplexWithOptionalNotePresent) {
    auto ctx = makeCtx("complex-1");
    ComplexRequest req{
        std::vector<EchoRequest>{EchoRequest{"a", 1}, EchoRequest{"b", 2}},
        std::vector<std::string>{"tag1", "tag2"},
        std::optional<std::string>("a note"),
        std::optional<int64_t>(2),
    };

    const auto resp = mustOk(ctx->complex(req));
    EXPECT_EQ(resp.itemCount, 2);
    EXPECT_TRUE(resp.hasNote);
    EXPECT_NE(resp.summary.find("note=a note"), std::string::npos)
        << "summary missing note: " << resp.summary;
    EXPECT_NE(resp.summary.find("retries=2"), std::string::npos)
        << "summary missing retries: " << resp.summary;
}

TEST(TimerE2E, ComplexWithOptionalNoteAbsent) {
    auto ctx = makeCtx("complex-2");
    ComplexRequest req{
        std::vector<EchoRequest>{},
        std::vector<std::string>{},
        std::nullopt,
        std::nullopt,
    };

    const auto resp = mustOk(ctx->complex(req));
    EXPECT_EQ(resp.itemCount, 0);
    EXPECT_FALSE(resp.hasNote);
    EXPECT_NE(resp.summary.find("note=<none>"), std::string::npos)
        << "summary should report <none>: " << resp.summary;
    EXPECT_NE(resp.summary.find("retries=0"), std::string::npos)
        << "summary should report retries=0: " << resp.summary;
}

TEST(TimerE2E, IndependentContextsKeepTheirOwnState) {
    auto ctxA = makeCtx("alpha");
    auto ctxB = makeCtx("beta");

    const auto rA = mustOk(ctxA->echo(EchoRequest{"x", 5}));
    const auto rB = mustOk(ctxB->echo(EchoRequest{"x", 5}));

    EXPECT_EQ(rA.timerName, "alpha");
    EXPECT_EQ(rB.timerName, "beta");
}

// N contexts keep independent state; an error on one must not poison siblings.
// Empty JobSpec.name is the chosen error trigger: schedule() returns
// err("job name must not be empty"), which the bindings surface as an
// err() Result carrying the exact string.
TEST(TimerE2E, MultiContextIsolation) {
    constexpr int kCtxCount = 5;
    std::vector<std::unique_ptr<MyTimerCtx>> ctxs;
    ctxs.reserve(kCtxCount);
    for (int i = 0; i < kCtxCount; ++i) {
        ctxs.push_back(makeCtx("iso-" + std::to_string(i)));
    }

    for (int i = 0; i < kCtxCount; ++i) {
        const auto resp = mustOk(ctxs[i]->echo(EchoRequest{"ping", 0}));
        EXPECT_EQ(resp.echoed, "ping");
        EXPECT_EQ(resp.timerName, "iso-" + std::to_string(i));
    }

    const auto bad = JobSpec{/*name*/ "", /*payload*/ {}, /*priority*/ 0};
    const auto retry = RetryPolicy{1, 10, {}};
    const auto sched = ScheduleConfig{0, 0, std::nullopt};
    const auto scheduleRes = ctxs[2]->schedule(bad, retry, sched);
    ASSERT_TRUE(scheduleRes.isErr()) << "expected schedule() to fail on empty job name";
    EXPECT_EQ(scheduleRes.error(), "job name must not be empty");

    const auto recovered = mustOk(ctxs[2]->echo(EchoRequest{"after-err", 0}));
    EXPECT_EQ(recovered.echoed, "after-err");
    EXPECT_EQ(recovered.timerName, "iso-2");

    for (int i = 0; i < kCtxCount; ++i) {
        if (i == 2) continue;
        const auto resp = mustOk(ctxs[i]->echo(EchoRequest{"still-here", 0}));
        EXPECT_EQ(resp.echoed, "still-here");
        EXPECT_EQ(resp.timerName, "iso-" + std::to_string(i));
    }
}

// Two nim-ffi libraries in one process must not share state or symbols.
TEST(TimerE2E, CrossLibrary) {
    auto timerCtx = mustOk(MyTimerCtx::create(TimerConfig{"x-timer"}));
    auto echoCtx  = mustOk(EchoCtx::create(EchoConfig{"X-ECHO"}));

    EXPECT_EQ(mustOk(timerCtx->version()), "nim-timer v0.1.0");
    EXPECT_EQ(mustOk(echoCtx->version()),  "nim-echo v0.1.0");

    const auto timerResp = mustOk(timerCtx->echo(EchoRequest{"hello", 0}));
    EXPECT_EQ(timerResp.echoed, "hello");
    EXPECT_EQ(timerResp.timerName, "x-timer");

    const auto echoResp = mustOk(echoCtx->shout(ShoutRequest{"hello"}));
    EXPECT_EQ(echoResp.shouted, "X-ECHO: HELLO");
    EXPECT_EQ(echoResp.prefix,  "X-ECHO");

    for (int i = 0; i < 4; ++i) {
        const auto t = mustOk(timerCtx->echo(EchoRequest{"t" + std::to_string(i), 0}));
        const auto e = mustOk(echoCtx->shout(ShoutRequest{"e" + std::to_string(i)}));
        EXPECT_EQ(t.timerName, "x-timer");
        EXPECT_EQ(e.prefix,    "X-ECHO");
    }

    auto tFut = timerCtx->echoAsync(EchoRequest{"async-t", 30});
    auto eFut = echoCtx->shoutAsync(ShoutRequest{"async-e"});
    const auto t = mustOk(tFut.get());
    const auto e = mustOk(eFut.get());
    EXPECT_EQ(t.echoed, "async-t");
    EXPECT_EQ(t.timerName, "x-timer");
    EXPECT_EQ(e.shouted, "X-ECHO: ASYNC-E");
}

// Chained async calls A->B->C must preserve ordering and payload across hops.
TEST(TimerE2E, TriplePipeline) {
    auto ctx = makeCtx("pipeline");

    auto pipeline = std::async(std::launch::async, [&ctx]() {
        auto a = mustOk(ctx->echoAsync(EchoRequest{"A", 20}).get());
        auto b = mustOk(ctx->echoAsync(EchoRequest{a.echoed + "->B", 10}).get());
        auto c = mustOk(ctx->echoAsync(EchoRequest{b.echoed + "->C", 5}).get());
        return c;
    });

    const auto final = pipeline.get();
    EXPECT_EQ(final.echoed, "A->B->C");
    EXPECT_EQ(final.timerName, "pipeline");
}

// Per-thread context create -> one call -> destroy churns the FFI context pool.
// Worker threads avoid gtest assertion macros (not thread-safe) and report via
// the atomic `errors` counter instead.
TEST(TimerE2E, StressShortLivedPerThreadContext) {
    constexpr int kThreads = 16;

    std::vector<std::thread> workers;
    std::atomic<int> errors{0};
    workers.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        workers.emplace_back([&, t] {
            auto ctxRes = MyTimerCtx::create(TimerConfig{"short-" + std::to_string(t)});
            if (ctxRes.isErr()) { ++errors; return; }
            auto ctx = std::move(ctxRes.value());
            const auto resp = ctx->echo(EchoRequest{"hi", 0});
            if (resp.isErr()) { ++errors; return; }
            if (resp->echoed != "hi") ++errors;
            if (resp->timerName != "short-" + std::to_string(t)) ++errors;
        });
    }
    for (auto& w : workers) w.join();
    EXPECT_EQ(errors.load(), 0);
}

// Many short-lived threads, one shared context: exercises the multi-producer
// SPSC request-queue path (where TSan would catch producer-side races).
TEST(TimerE2E, StressShortLivedSharedContext) {
    constexpr int kThreads = 32;
    auto shared = makeCtx("shared-short");

    std::vector<std::thread> workers;
    std::atomic<int> errors{0};
    workers.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        workers.emplace_back([&, t] {
            const auto resp = shared->echo(EchoRequest{"x" + std::to_string(t), 0});
            if (resp.isErr()) { ++errors; return; }
            if (resp->echoed != "x" + std::to_string(t)) ++errors;
            if (resp->timerName != "shared-short") ++errors;
        });
    }
    for (auto& w : workers) w.join();
    EXPECT_EQ(errors.load(), 0);
}

// Concurrency workload for ThreadSanitizer: many threads hammering both a
// shared context (multi-producer into the same SPSC request queue — where
// producer-side races would live) and per-thread contexts (validates
// independent FFI threads stay isolated). Mixes sync and async paths so
// both code paths are exercised.
TEST(TimerE2E, ThreadedHammer) {
    constexpr int kThreads = 8;
    constexpr int kIters   = 50;

    auto shared = makeCtx("hammer-shared");

    std::vector<std::thread> workers;
    std::atomic<int> errors{0};
    workers.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        workers.emplace_back([&, t] {
            auto ownRes = MyTimerCtx::create(TimerConfig{"hammer-t" + std::to_string(t)});
            if (ownRes.isErr()) { ++errors; return; }
            auto own = std::move(ownRes.value());
            for (int i = 0; i < kIters; ++i) {
                if ((i & 1) == 0) {
                    const auto r = shared->echo(EchoRequest{"s", 0});
                    if (r.isErr() || r->echoed != "s") ++errors;
                } else {
                    auto f = own->echoAsync(EchoRequest{"a", 1});
                    const auto r = f.get();
                    if (r.isErr() || r->echoed != "a") ++errors;
                }
            }
        });
    }
    for (auto& w : workers) w.join();
    EXPECT_EQ(errors.load(), 0);
}


// Library-initiated events flow through `MyTimerCtx::addOnEchoFiredListener`:
// the listener registers a CBOR-decoding trampoline inside the lib's
// registry, and every successful `echo()` triggers it. The promise here
// is fulfilled from the FFI thread; we wait synchronously for it before
// destroying the context (the dtor tears down the FFI thread and any
// further events).
TEST(TimerE2E, TypedEventFiresAfterEcho) {
    auto ctx = makeCtx("events");

    std::promise<EchoEvent> evtPromise;
    auto evtFuture = evtPromise.get_future();

    const auto handle = ctx->addOnEchoFiredListener(
        [&](const EchoEvent& evt) { evtPromise.set_value(evt); });
    ASSERT_NE(handle.id, 0u) << "addOnEchoFiredListener returned zero id";

    const auto resp = mustOk(ctx->echo(EchoRequest{"event-msg", 1}));
    EXPECT_EQ(resp.echoed, "event-msg");

    const auto status = evtFuture.wait_for(std::chrono::seconds(2));
    ASSERT_EQ(status, std::future_status::ready) << "event never arrived";

    const auto evt = evtFuture.get();
    EXPECT_EQ(evt.message, "event-msg");
    EXPECT_EQ(evt.echoCount, 1);
}

// Multiple listeners on the same event each fire exactly once per emit.
TEST(TimerE2E, MultipleTypedListenersAllFire) {
    auto ctx = makeCtx("multi-listeners");

    std::promise<EchoEvent> firstPromise;
    std::promise<EchoEvent> secondPromise;
    auto firstFuture = firstPromise.get_future();
    auto secondFuture = secondPromise.get_future();

    ctx->addOnEchoFiredListener(
        [&](const EchoEvent& evt) { firstPromise.set_value(evt); });
    ctx->addOnEchoFiredListener(
        [&](const EchoEvent& evt) { secondPromise.set_value(evt); });

    ctx->echo(EchoRequest{"fan-out", 1});

    ASSERT_EQ(firstFuture.wait_for(std::chrono::seconds(2)), std::future_status::ready);
    ASSERT_EQ(secondFuture.wait_for(std::chrono::seconds(2)), std::future_status::ready);
    EXPECT_EQ(firstFuture.get().message, "fan-out");
    EXPECT_EQ(secondFuture.get().message, "fan-out");
}

// Removing a listener stops it from firing on subsequent events while the
// other listener keeps receiving them.
TEST(TimerE2E, RemoveEventListenerStopsDelivery) {
    auto ctx = makeCtx("remove-listener");

    std::atomic<int> removedHits{0};
    std::atomic<int> keptHits{0};

    const auto removedHandle = ctx->addOnEchoFiredListener(
        [&](const EchoEvent&) { removedHits.fetch_add(1); });
    ctx->addOnEchoFiredListener(
        [&](const EchoEvent&) { keptHits.fetch_add(1); });

    ctx->echo(EchoRequest{"before-remove", 1});

    // Give the FFI thread a beat to deliver the first event to both
    // listeners before we yank one of them out.
    for (int i = 0; i < 200 && (removedHits.load() == 0 || keptHits.load() == 0); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_EQ(removedHits.load(), 1);
    ASSERT_EQ(keptHits.load(), 1);

    EXPECT_TRUE(ctx->removeEventListener(removedHandle));
    EXPECT_FALSE(ctx->removeEventListener(removedHandle)) << "double remove must report false";

    ctx->echo(EchoRequest{"after-remove", 1});

    for (int i = 0; i < 200 && keptHits.load() < 2; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    EXPECT_EQ(keptHits.load(), 2);
    EXPECT_EQ(removedHits.load(), 1) << "removed listener fired after removeEventListener";
}

// The wildcard `addEventListener` overload receives every event with the
// wire `eventId` pre-extracted plus a `std::span` view over the raw
// envelope bytes. The helper `decodeEventPayload<T>` lifts the payload
// into a typed value.
TEST(TimerE2E, WildcardListenerReceivesEventIdAndDecodesPayload) {
    auto ctx = makeCtx("wildcard");

    struct Capture {
        int retCode;
        std::string eventId;
        std::size_t envelopeBytes;
        std::optional<EchoEvent> decoded;
    };

    std::mutex mu;
    std::vector<Capture> captured;
    auto handle = ctx->addEventListener(
        [&](int retCode, const std::string& eventId,
            std::span<const std::uint8_t> envelope) {
            Capture c{retCode, eventId, envelope.size(), std::nullopt};
            if (retCode == 0 && eventId == "on_echo_fired") {
                EchoEvent evt{};
                if (decodeEventPayload(envelope, evt)) {
                    c.decoded = evt;
                }
            }
            std::lock_guard<std::mutex> lock(mu);
            captured.push_back(std::move(c));
        });
    ASSERT_NE(handle.id, 0u);

    ctx->echo(EchoRequest{"hello", 1});

    for (int i = 0; i < 200; ++i) {
        {
            std::lock_guard<std::mutex> lock(mu);
            if (!captured.empty()) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    std::lock_guard<std::mutex> lock(mu);
    ASSERT_GE(captured.size(), 1u);
    EXPECT_EQ(captured.front().retCode, 0);
    EXPECT_EQ(captured.front().eventId, "on_echo_fired");
    EXPECT_GT(captured.front().envelopeBytes, 0u);
    ASSERT_TRUE(captured.front().decoded.has_value());
    EXPECT_EQ(captured.front().decoded->message, "hello");
    EXPECT_EQ(captured.front().decoded->echoCount, 1);
}
