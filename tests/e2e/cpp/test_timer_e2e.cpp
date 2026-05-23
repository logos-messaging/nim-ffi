// Basic C++ end-to-end tests for the auto-generated `timer` bindings.
//
// These tests link against the same `timer_headers` INTERFACE library and Nim
// shared object used by `examples/timer/cpp_bindings/main.cpp`. They exercise
// the full FFI round-trip — CBOR encode -> Nim FFI thread -> chronos -> CBOR
// decode -> C++ — to validate that a binding produced by `nimble
// genbindings_cpp` is callable end-to-end from C++.
//
// The CrossLibrary test additionally loads `examples/echo/cpp_bindings`
// alongside the timer to prove that two independent nim-ffi libraries can
// coexist in one process with no symbol clash and no shared global state.

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

std::unique_ptr<MyTimerCtx> makeCtx(const std::string& name = "e2e") {
    return MyTimerCtx::create(TimerConfig{name});
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
    const auto v = ctx->version();
    EXPECT_EQ(v, "nim-timer v0.1.0");
}

TEST(TimerE2E, VersionAsync) {
    auto ctx = makeCtx("version-async");
    auto fut = ctx->versionAsync();
    EXPECT_EQ(fut.get(), "nim-timer v0.1.0");
}

TEST(TimerE2E, EchoRoundTripsMessageAndTimerName) {
    auto ctx = makeCtx("echo-ctx");
    const auto resp = ctx->echo(EchoRequest{"hello", 10});
    EXPECT_EQ(resp.echoed, "hello");
    EXPECT_EQ(resp.timerName, "echo-ctx");
}

TEST(TimerE2E, EchoHonoursDelay) {
    auto ctx = makeCtx("echo-delay");
    constexpr int delayMs = 150;

    const auto start = std::chrono::steady_clock::now();
    const auto resp = ctx->echo(EchoRequest{"waited", delayMs});
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

    const auto r3 = f3.get();
    const auto r2 = f2.get();
    const auto r1 = f1.get();

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

    const auto resp = ctx->complex(req);
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

    const auto resp = ctx->complex(req);
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

    const auto rA = ctxA->echo(EchoRequest{"x", 5});
    const auto rB = ctxB->echo(EchoRequest{"x", 5});

    EXPECT_EQ(rA.timerName, "alpha");
    EXPECT_EQ(rB.timerName, "beta");
}

// MultiContextIsolation — N independent contexts each carry their own
// `timer.name` state, and an error returned by one context's call does not
// affect a sibling context. Drives the schedule() proc, which returns
// `err("job name must not be empty")` when JobSpec.name is empty: the
// generated bindings translate that into a thrown std::runtime_error
// carrying the exact error string, so we can pin the propagation.
TEST(TimerE2E, MultiContextIsolation) {
    constexpr int kCtxCount = 5;
    std::vector<std::unique_ptr<MyTimerCtx>> ctxs;
    ctxs.reserve(kCtxCount);
    for (int i = 0; i < kCtxCount; ++i) {
        ctxs.push_back(makeCtx("iso-" + std::to_string(i)));
    }

    // Each context returns its own configured name — proves per-context
    // state isn't shared across the pool.
    for (int i = 0; i < kCtxCount; ++i) {
        const auto resp = ctxs[i]->echo(EchoRequest{"ping", 0});
        EXPECT_EQ(resp.echoed, "ping");
        EXPECT_EQ(resp.timerName, "iso-" + std::to_string(i));
    }

    // Trigger a Result-side error on ctx[2] and assert it propagates as
    // an exception carrying the Nim-side message. The other contexts must
    // remain fully usable afterwards (no poisoning of the pool).
    const auto bad = JobSpec{/*name*/ "", /*payload*/ {}, /*priority*/ 0};
    const auto retry = RetryPolicy{1, 10, {}};
    const auto sched = ScheduleConfig{0, 0, std::nullopt};
    try {
        (void)ctxs[2]->schedule(bad, retry, sched);
        FAIL() << "expected schedule() to throw on empty job name";
    } catch (const std::runtime_error& ex) {
        EXPECT_STREQ(ex.what(), "job name must not be empty");
    }

    // Same context still works on a subsequent valid call.
    const auto recovered = ctxs[2]->echo(EchoRequest{"after-err", 0});
    EXPECT_EQ(recovered.echoed, "after-err");
    EXPECT_EQ(recovered.timerName, "iso-2");

    // Every other context still works and still reports its own name.
    for (int i = 0; i < kCtxCount; ++i) {
        if (i == 2) continue;
        const auto resp = ctxs[i]->echo(EchoRequest{"still-here", 0});
        EXPECT_EQ(resp.echoed, "still-here");
        EXPECT_EQ(resp.timerName, "iso-" + std::to_string(i));
    }
}

// CrossLibrary — load libmy_timer + libecho in one process, exercise both,
// and prove they do not share state. The two libraries declare distinct
// symbols (my_timer_* vs echo_*) and own independent FFIContext pools, so a
// timer context's `name` must not bleed into an echo context's `prefix`
// (or vice versa) at any point.
TEST(TimerE2E, CrossLibrary) {
    auto timerCtx = MyTimerCtx::create(TimerConfig{"x-timer"});
    auto echoCtx  = EchoCtx::create(EchoConfig{"X-ECHO"});

    EXPECT_EQ(timerCtx->version(), "nim-timer v0.1.0");
    EXPECT_EQ(echoCtx->version(),  "nim-echo v0.1.0");

    const auto timerResp = timerCtx->echo(EchoRequest{"hello", 0});
    EXPECT_EQ(timerResp.echoed, "hello");
    EXPECT_EQ(timerResp.timerName, "x-timer");

    const auto echoResp = echoCtx->shout(ShoutRequest{"hello"});
    EXPECT_EQ(echoResp.shouted, "X-ECHO: HELLO");
    EXPECT_EQ(echoResp.prefix,  "X-ECHO");

    // Interleave calls — if either library held shared global state behind
    // the other's back, repeated round-trips would surface it.
    for (int i = 0; i < 4; ++i) {
        const auto t = timerCtx->echo(EchoRequest{"t" + std::to_string(i), 0});
        const auto e = echoCtx->shout(ShoutRequest{"e" + std::to_string(i)});
        EXPECT_EQ(t.timerName, "x-timer");
        EXPECT_EQ(e.prefix,    "X-ECHO");
    }

    // Cross-fire async calls on both libraries at once. Each library has
    // its own dispatch path; getting any value here would mean one
    // library's queue stalled the other's.
    auto tFut = timerCtx->echoAsync(EchoRequest{"async-t", 30});
    auto eFut = echoCtx->shoutAsync(ShoutRequest{"async-e"});
    const auto t = tFut.get();
    const auto e = eFut.get();
    EXPECT_EQ(t.echoed, "async-t");
    EXPECT_EQ(t.timerName, "x-timer");
    EXPECT_EQ(e.shouted, "X-ECHO: ASYNC-E");
}

// TriplePipeline — chain three async calls A -> B -> C, feeding each call's
// payload into the next. Asserts ordering (the .get() on C only resolves
// after A and B have both completed) and payload integrity (the chained
// echoes carry the expected concatenated string).
TEST(TimerE2E, TriplePipeline) {
    auto ctx = makeCtx("pipeline");

    auto pipeline = std::async(std::launch::async, [&ctx]() {
        auto a = ctx->echoAsync(EchoRequest{"A", 20}).get();
        auto b = ctx->echoAsync(EchoRequest{a.echoed + "->B", 10}).get();
        auto c = ctx->echoAsync(EchoRequest{b.echoed + "->C", 5}).get();
        return c;
    });

    const auto final = pipeline.get();
    EXPECT_EQ(final.echoed, "A->B->C");
    EXPECT_EQ(final.timerName, "pipeline");
}

// StressShortLivedPerThreadContext — many threads, each creating its OWN
// context, firing one request, then joining. Stresses the FFI context pool
// allocation/teardown path. With the pool capped at a fixed size, threads
// will see slots get reused as earlier threads' destructors return them.
TEST(TimerE2E, StressShortLivedPerThreadContext) {
    constexpr int kThreads = 16;

    std::vector<std::thread> workers;
    std::atomic<int> errors{0};
    workers.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        workers.emplace_back([&, t] {
            try {
                auto ctx = makeCtx("short-" + std::to_string(t));
                const auto resp = ctx->echo(EchoRequest{"hi", 0});
                if (resp.echoed != "hi") ++errors;
                if (resp.timerName != "short-" + std::to_string(t)) ++errors;
                // ctx destructor runs here, releasing the pool slot before
                // .join() unblocks the main thread.
            } catch (const std::exception&) {
                ++errors;
            }
        });
    }
    for (auto& w : workers) w.join();
    EXPECT_EQ(errors.load(), 0);
}

// StressShortLivedSharedContext — many threads sharing ONE context, each
// firing one request and joining. Exercises the multi-producer path into
// a single SPSC request queue (where TSan would surface producer-side
// races). Distinct from ThreadedHammer in that each thread issues exactly
// one request and exits — a churnier thread lifecycle.
TEST(TimerE2E, StressShortLivedSharedContext) {
    constexpr int kThreads = 32;
    auto shared = makeCtx("shared-short");

    std::vector<std::thread> workers;
    std::atomic<int> errors{0};
    workers.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        workers.emplace_back([&, t] {
            try {
                const auto resp = shared->echo(EchoRequest{"x" + std::to_string(t), 0});
                if (resp.echoed != "x" + std::to_string(t)) ++errors;
                if (resp.timerName != "shared-short") ++errors;
            } catch (const std::exception&) {
                ++errors;
            }
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
            auto own = makeCtx("hammer-t" + std::to_string(t));
            for (int i = 0; i < kIters; ++i) {
                if ((i & 1) == 0) {
                    const auto r = shared->echo(EchoRequest{"s", 0});
                    if (r.echoed != "s") ++errors;
                } else {
                    auto f = own->echoAsync(EchoRequest{"a", 1});
                    if (f.get().echoed != "a") ++errors;
                }
            }
        });
    }
    for (auto& w : workers) w.join();
    EXPECT_EQ(errors.load(), 0);
}

// Library-initiated events flow through the typed `MyTimerCtx::Events`
// dispatcher: setting `onEchoFired` registers a CBOR-decoding trampoline
// inside the context, and every successful `echo()` triggers it. The
// promise here is fulfilled from the FFI thread; we wait synchronously
// for it before destroying the context (the dtor tears down the FFI
// thread and any further events).
TEST(TimerE2E, TypedEventFiresAfterEcho) {
    auto ctx = makeCtx("events");

    std::promise<EchoEvent> evtPromise;
    auto evtFuture = evtPromise.get_future();

    ctx->setEventHandlers({
        .on_error = nullptr,
        .onEchoFired = [&](const EchoEvent& evt) { evtPromise.set_value(evt); },
    });

    const auto resp = ctx->echo(EchoRequest{"event-msg", 1});
    EXPECT_EQ(resp.echoed, "event-msg");

    const auto status = evtFuture.wait_for(std::chrono::seconds(2));
    ASSERT_EQ(status, std::future_status::ready) << "event never arrived";

    const auto evt = evtFuture.get();
    EXPECT_EQ(evt.message, "event-msg");
    EXPECT_EQ(evt.echoCount, 1);
}
