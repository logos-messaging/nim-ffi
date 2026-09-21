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
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#elif defined(__linux__)
#include <fstream>
#endif

namespace {

// Threads of this process, or -1 where there is no cheap way to count them.
int threadCount() {
#if defined(__APPLE__)
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return -1;
    for (mach_msg_type_number_t i = 0; i < count; ++i)
        mach_port_deallocate(mach_task_self(), threads[i]);
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads),
                  count * sizeof(thread_act_t));
    return static_cast<int>(count);
#elif defined(__linux__)
    std::ifstream status("/proc/self/status");
    std::string key;
    while (status >> key) {
        if (key == "Threads:") {
            int n = -1;
            status >> n;
            return n;
        }
    }
    return -1;
#else
    return -1;
#endif
}

// Unwrap a Result<T> in a single-threaded test context. On error it records a
// non-fatal gtest failure and returns a default-constructed T so the caller
// can keep going (subsequent expectations will fail loudly).
template <typename T>
T mustOk(Result<T> r) {
    if (r.isErr()) {
        ADD_FAILURE() << "unexpected FFI error: " << r.error() << " line: " << __LINE__;
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
    EXPECT_EQ(v, TIMER_VERSION);
}

TEST(TimerE2E, VersionAsync) {
    auto ctx = makeCtx("version-async");
    auto fut = ctx->versionAsync();
    EXPECT_EQ(mustOk(fut.get()), TIMER_VERSION);
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

// jpHigh halves the requested backoff, and the enum comes back as itself.
TEST(TimerE2E, SchedulePriorityRoundTrips) {
    auto ctx = makeCtx("prio");
    const auto job = JobSpec{"rollup", {"p"}, JobPriority::jpHigh};
    const auto res = mustOk(ctx->schedule(job, RetryPolicy{3, 100, {}},
                                          ScheduleConfig{0, 0, std::nullopt}));
    EXPECT_EQ(res.priority, JobPriority::jpHigh);
    EXPECT_EQ(res.effectiveBackoffMs, 50);
}

// backoffMs 0 falls back to DEFAULT_BACKOFF_MS, doubled for jpLow.
TEST(TimerE2E, ScheduleDefaultBackoffComesFromConst) {
    auto ctx = makeCtx("prio-default");
    const auto job = JobSpec{"rollup", {}, JobPriority::jpLow};
    const auto res = mustOk(ctx->schedule(job, RetryPolicy{1, 0, {}},
                                          ScheduleConfig{0, 0, std::nullopt}));
    EXPECT_EQ(res.effectiveBackoffMs, DEFAULT_BACKOFF_MS * 2);
}

TEST(TimerE2E, EchoRejectsDelayAboveMaxDelayMs) {
    auto ctx = makeCtx("max-delay");
    const auto res = ctx->echo(EchoRequest{"too-slow", MAX_DELAY_MS + 1});
    ASSERT_TRUE(res.isErr());
    EXPECT_EQ(res.error(), "delayMs must not exceed " + std::to_string(MAX_DELAY_MS));
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

    const auto bad = JobSpec{/*name*/ "", /*payload*/ {}, JobPriority::jpNormal};
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

    EXPECT_EQ(mustOk(timerCtx->version()), TIMER_VERSION);
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

// No EchoCtx is constructed anywhere in this test.
TEST(TimerE2E, StaticProcNeedsNoContext) {
    EXPECT_EQ(mustOk(EchoCtx::lib_version()), "nim-echo v0.1.0");

    const auto resp = mustOk(EchoCtx::shout_anon(ShoutRequest{"hello"}));
    EXPECT_EQ(resp.shouted, "HELLO");
    EXPECT_EQ(resp.prefix, "");
}

// The static context is created once, on demand, and shared by every caller.
TEST(TimerE2E, StaticProcConcurrentFirstCall) {
    constexpr int kThreads = 8;

    std::vector<std::future<Result<ShoutResponse>>> futs;
    futs.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        futs.push_back(EchoCtx::shout_anonAsync(ShoutRequest{"race" + std::to_string(i)}));
    }
    for (int i = 0; i < kThreads; ++i) {
        EXPECT_EQ(mustOk(futs[i].get()).shouted, "RACE" + std::to_string(i));
    }
}

// A static call and a ctx call must not disturb each other's state.
TEST(TimerE2E, StaticProcCoexistsWithContext) {
    auto ctx = mustOk(EchoCtx::create(EchoConfig{"WITH-CTX"}));

    EXPECT_EQ(mustOk(ctx->shout(ShoutRequest{"a"})).prefix, "WITH-CTX");
    EXPECT_EQ(mustOk(EchoCtx::shout_anon(ShoutRequest{"b"})).prefix, "");
    EXPECT_EQ(mustOk(ctx->shout(ShoutRequest{"c"})).prefix, "WITH-CTX");
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
// the context's dispatch thread takes each event out of `my_timer_poll`, decodes
// its CBOR payload and calls the listeners. The promise here is fulfilled from
// that dispatch thread; we wait for it before destroying the context.
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

    // Give the dispatch thread a beat to deliver the first event to both
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

// One dispatch thread per context: events come out in the order the library
// produced them, each decoded into its own payload type.
TEST(TimerE2E, EventsArriveInOrderWithTypedPayloads) {
    auto ctx = makeCtx("ordered-events");
    constexpr int kEchoes = 20;

    std::mutex mtx;
    std::vector<EchoEvent> echoes;
    std::promise<void> allEchoes;
    std::promise<OnJobScheduledPayload> jobPromise;
    auto jobFuture = jobPromise.get_future();

    ctx->addOnEchoFiredListener([&](const EchoEvent& evt) {
        std::lock_guard<std::mutex> lock(mtx);
        echoes.push_back(evt);
        if (echoes.size() == kEchoes) allEchoes.set_value();
    });
    ctx->addOnJobScheduledListener(
        [&](const OnJobScheduledPayload& evt) { jobPromise.set_value(evt); });

    for (int i = 0; i < kEchoes; ++i) {
        mustOk(ctx->echo(EchoRequest{"m" + std::to_string(i), 0}));
    }
    const auto sched = mustOk(ctx->schedule(JobSpec{"rollup", {}, JobPriority::jpNormal},
                                            RetryPolicy{1, 10, {}},
                                            ScheduleConfig{0, 0, std::nullopt}));

    ASSERT_EQ(allEchoes.get_future().wait_for(std::chrono::seconds(5)),
              std::future_status::ready);
    ASSERT_EQ(jobFuture.wait_for(std::chrono::seconds(5)), std::future_status::ready);

    std::lock_guard<std::mutex> lock(mtx);
    for (int i = 0; i < kEchoes; ++i) {
        EXPECT_EQ(echoes[i].message, "m" + std::to_string(i));
        EXPECT_EQ(echoes[i].echoCount, 1);
    }
    const auto job = jobFuture.get();
    EXPECT_EQ(job.jobId, sched.jobId);
    EXPECT_EQ(job.willRunCount, sched.willRunCount);
}

// A listener runs with the listener table unlocked, so it may remove itself.
TEST(TimerE2E, HandlerRemovesItself) {
    auto ctx = makeCtx("self-remove");

    std::atomic<int> onceHits{0};
    std::atomic<int> keptHits{0};
    std::atomic<bool> removed{false};
    MyTimerCtx::ListenerHandle self;
    std::promise<void> handleReady;
    auto handleReadyFuture = handleReady.get_future().share();

    self = ctx->addOnEchoFiredListener([&](const EchoEvent&) {
        handleReadyFuture.wait();
        onceHits.fetch_add(1);
        removed.store(ctx->removeEventListener(self));
    });
    handleReady.set_value();
    ctx->addOnEchoFiredListener([&](const EchoEvent&) { keptHits.fetch_add(1); });

    for (int i = 0; i < 3; ++i) mustOk(ctx->echo(EchoRequest{"x", 0}));

    for (int i = 0; i < 400 && keptHits.load() < 3; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    EXPECT_EQ(keptHits.load(), 3);
    EXPECT_EQ(onceHits.load(), 1);
    EXPECT_TRUE(removed.load());
}

// A listener added from inside a listener starts with the next event.
TEST(TimerE2E, HandlerAddsAnotherListener) {
    auto ctx = makeCtx("add-in-handler");

    std::atomic<int> outerHits{0};
    std::mutex mtx;
    std::vector<std::string> innerSeen;

    ctx->addOnEchoFiredListener([&](const EchoEvent&) {
        if (outerHits.fetch_add(1) != 0) return;
        const auto inner = ctx->addOnEchoFiredListener([&](const EchoEvent& evt) {
            std::lock_guard<std::mutex> lock(mtx);
            innerSeen.push_back(evt.message);
        });
        if (inner.id == 0) outerHits.store(-1000);
    });

    mustOk(ctx->echo(EchoRequest{"first", 0}));
    mustOk(ctx->echo(EchoRequest{"second", 0}));

    for (int i = 0; i < 400; ++i) {
        {
            std::lock_guard<std::mutex> lock(mtx);
            if (!innerSeen.empty() && outerHits.load() >= 2) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    EXPECT_EQ(outerHits.load(), 2);
    std::lock_guard<std::mutex> lock(mtx);
    ASSERT_EQ(innerSeen.size(), 1u);
    EXPECT_EQ(innerSeen[0], "second");
}

// A listener may call back into its own context: it runs on the dispatch thread,
// not on the library's FFI thread.
TEST(TimerE2E, HandlerCallsBackIntoTheContext) {
    auto ctx = makeCtx("reentrant");

    std::promise<Result<std::string>> versionPromise;
    auto versionFuture = versionPromise.get_future();
    std::atomic<bool> first{true};
    ctx->addOnEchoFiredListener([&](const EchoEvent&) {
        if (first.exchange(false)) versionPromise.set_value(ctx->version());
    });

    mustOk(ctx->echo(EchoRequest{"x", 0}));
    ASSERT_EQ(versionFuture.wait_for(std::chrono::seconds(5)), std::future_status::ready);
    EXPECT_EQ(mustOk(versionFuture.get()), TIMER_VERSION);
}

// Tearing a context down while its dispatch thread is still delivering must neither crash
// nor hang, and no listener may run once the destructor returned.
TEST(TimerE2E, DestroyWhileEventsInFlight) {
    for (int round = 0; round < 10; ++round) {
        auto ctx = makeCtx("in-flight-" + std::to_string(round));
        auto alive = std::make_shared<std::atomic<bool>>(true);
        auto lateHits = std::make_shared<std::atomic<int>>(0);

        ctx->addOnEchoFiredListener([alive, lateHits](const EchoEvent&) {
            if (!alive->load()) lateHits->fetch_add(1);
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        });

        for (int i = 0; i < 25; ++i) mustOk(ctx->echo(EchoRequest{"burst", 0}));
        ctx.reset();
        alive->store(false);

        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        EXPECT_EQ(lateHits->load(), 0);
    }
}

// The closed hook is the last thing a context's listeners hear, exactly once.
TEST(TimerE2E, ClosedListenerFiresOnceOnDestroy) {
    auto ctx = makeCtx("closed-hook");

    std::atomic<int> closedHits{0};
    std::atomic<bool> closedOk{false};
    std::string closedReason = "unset";
    ctx->addClosedListener([&](bool ok, const std::string& reason) {
        closedOk.store(ok);
        closedReason = reason;
        closedHits.fetch_add(1);
    });
    const auto quiet = ctx->addNotRespondingListener([](std::uint64_t) {});
    EXPECT_NE(quiet.id, 0u);
    EXPECT_TRUE(ctx->removeEventListener(quiet));

    mustOk(ctx->echo(EchoRequest{"x", 0}));
    ctx.reset(); // joins the dispatch thread, so the hook has run by now

    EXPECT_EQ(closedHits.load(), 1);
    EXPECT_TRUE(closedOk.load());
    EXPECT_EQ(closedReason, "");
}

// A listener may destroy its own context: the destructor then runs on the dispatch thread
// thread, which detaches instead of joining itself.
TEST(TimerE2E, HandlerDestroysItsContext) {
    auto ctx = makeCtx("self-destroy");

    std::promise<void> echoSubmitted;
    auto echoSubmittedFuture = echoSubmitted.get_future().share();
    std::promise<void> destroyed;
    std::atomic<int> laterHits{0};
    ctx->addOnEchoFiredListener([&](const EchoEvent&) {
        // Let the caller leave `echoAsync` first. It must not wait for the reply
        // itself: replies come out of this very thread.
        echoSubmittedFuture.wait();
        ctx.reset();
        destroyed.set_value();
    });
    ctx->addOnEchoFiredListener([&](const EchoEvent&) { laterHits.fetch_add(1); });

    auto echoFuture = ctx->echoAsync(EchoRequest{"bye", 0});
    echoSubmitted.set_value();

    ASSERT_EQ(destroyed.get_future().wait_for(std::chrono::seconds(10)),
              std::future_status::ready);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    EXPECT_EQ(laterHits.load(), 0);

    // The echo's reply was behind the event: the context closed before it came out.
    ASSERT_EQ(echoFuture.wait_for(std::chrono::seconds(10)), std::future_status::ready);
    const auto echo = echoFuture.get();
    ASSERT_TRUE(echo.isErr());
    EXPECT_NE(echo.error().find("context closed"), std::string::npos) << echo.error();
}

// echo declares no event; it still has a dispatch thread, so the liveness and closed hooks work.
TEST(TimerE2E, EventlessLibraryStillReportsClosed) {
    auto ctx = mustOk(EchoCtx::create(EchoConfig{"NO-EVENTS"}));

    std::atomic<int> closedHits{0};
    const auto handle = ctx->addClosedListener(
        [&](bool, const std::string&) { closedHits.fetch_add(1); });
    EXPECT_NE(handle.id, 0u);

    EXPECT_EQ(mustOk(ctx->shout(ShoutRequest{"a"})).prefix, "NO-EVENTS");
    ctx.reset();
    EXPECT_EQ(closedHits.load(), 1);
}

// ── Replies through the dispatch thread ──────────────────────────────────────────────────

// A blocking call made inside a listener runs on the dispatch thread, the only one
// that can take its reply out: the call polls in place. The echo it makes fires
// the event again, which is delivered while that call is still waiting.
TEST(TimerE2E, BlockingCallsInsideAListenerPollInPlace) {
    auto ctx = makeCtx("inline-poll");

    struct Seen {
        Result<std::string> version;
        Result<EchoResponse> echo;
        Result<std::string> libVersion;
        int nestedEvents;
    };
    std::promise<Seen> seenPromise;
    auto seenFuture = seenPromise.get_future();
    std::atomic<int> depth{0};
    std::atomic<int> nested{0};
    ctx->addOnEchoFiredListener([&](const EchoEvent&) {
        if (depth.fetch_add(1) != 0) {
            nested.fetch_add(1);
            return;
        }
        auto version = ctx->version();
        auto echo = ctx->echo(EchoRequest{"from-listener", 5});
        auto libVersion = MyTimerCtx::lib_version();
        seenPromise.set_value(Seen{std::move(version), std::move(echo),
                                   std::move(libVersion), nested.load()});
    });

    mustOk(ctx->echo(EchoRequest{"outer", 0}));
    ASSERT_EQ(seenFuture.wait_for(std::chrono::seconds(10)), std::future_status::ready);
    auto seen = seenFuture.get();
    EXPECT_EQ(mustOk(std::move(seen.version)), TIMER_VERSION);
    EXPECT_EQ(mustOk(std::move(seen.echo)).echoed, "from-listener");
    EXPECT_EQ(mustOk(std::move(seen.libVersion)), "nim-timer v0.1.0");
    EXPECT_EQ(seen.nestedEvents, 1) << "the nested echo's event was not delivered in place";

    // The dispatch thread is back to normal afterwards.
    EXPECT_EQ(mustOk(ctx->echo(EchoRequest{"after", 0})).echoed, "after");
}

// A blocking call inside a listener still honours the context's timeout.
TEST(TimerE2E, BlockingCallInsideAListenerTimesOut) {
    auto ctx = mustOk(MyTimerCtx::create(TimerConfig{"inline-timeout"},
                                         std::chrono::milliseconds(100)));

    std::promise<Result<EchoResponse>> slowPromise;
    auto slowFuture = slowPromise.get_future();
    std::atomic<bool> first{true};
    ctx->addOnEchoFiredListener([&](const EchoEvent&) {
        if (first.exchange(false)) slowPromise.set_value(ctx->echo(EchoRequest{"slow", 600}));
    });

    mustOk(ctx->echo(EchoRequest{"go", 0}));
    ASSERT_EQ(slowFuture.wait_for(std::chrono::seconds(10)), std::future_status::ready);
    const auto slow = slowFuture.get();
    ASSERT_TRUE(slow.isErr());
    EXPECT_NE(slow.error().find("timed out"), std::string::npos) << slow.error();
    EXPECT_EQ(mustOk(ctx->version()), TIMER_VERSION);
}

// Every *Async call is one waiter in the dispatch thread, not one thread.
TEST(TimerE2E, ManyConcurrentAsyncCallsShareTheDispatchThread) {
    constexpr int kCalls = 300;
    auto ctx = makeCtx("many-async");
    mustOk(ctx->echo(EchoRequest{"warm-up", 0}));

    const int before = threadCount();
    std::vector<std::future<Result<EchoResponse>>> futs;
    futs.reserve(kCalls);
    for (int i = 0; i < kCalls; ++i) {
        futs.push_back(ctx->echoAsync(EchoRequest{"m" + std::to_string(i), 150}));
    }
    const int during = threadCount();

    for (int i = 0; i < kCalls; ++i) {
        const auto resp = mustOk(futs[i].get());
        EXPECT_EQ(resp.echoed, "m" + std::to_string(i));
        EXPECT_EQ(resp.timerName, "many-async");
    }
    if (before >= 0) {
        EXPECT_LE(during, before) << kCalls << " calls in flight started threads";
    }
}

// Futures taken from many threads at once resolve to their own replies.
TEST(TimerE2E, AsyncCallsFromManyThreadsResolveToTheirOwnReply) {
    constexpr int kThreads = 8;
    constexpr int kPerThread = 100;
    auto ctx = makeCtx("async-mt");

    std::vector<std::thread> workers;
    std::atomic<int> errors{0};
    for (int t = 0; t < kThreads; ++t) {
        workers.emplace_back([&, t] {
            std::vector<std::future<Result<EchoResponse>>> futs;
            futs.reserve(kPerThread);
            for (int i = 0; i < kPerThread; ++i) {
                futs.push_back(ctx->echoAsync(
                    EchoRequest{std::to_string(t) + ":" + std::to_string(i), i % 3}));
            }
            for (int i = 0; i < kPerThread; ++i) {
                const auto r = futs[i].get();
                if (r.isErr() || r->echoed != std::to_string(t) + ":" + std::to_string(i))
                    ++errors;
            }
        });
    }
    for (auto& w : workers) w.join();
    EXPECT_EQ(errors.load(), 0);
}

// A call that timed out gave its waiter up: the reply that arrives later is
// dropped, and the context keeps working.
TEST(TimerE2E, TimedOutCallLeavesTheContextUsable) {
    auto ctx = mustOk(MyTimerCtx::create(TimerConfig{"timeouts"},
                                         std::chrono::milliseconds(100)));

    const auto start = std::chrono::steady_clock::now();
    const auto slow = ctx->echo(EchoRequest{"slow", 400});
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count();
    ASSERT_TRUE(slow.isErr());
    EXPECT_EQ(slow.error(), "FFI call timed out after 100ms");
    EXPECT_LT(elapsed, 390) << "the call waited for the reply instead of timing out";

    EXPECT_EQ(mustOk(ctx->echo(EchoRequest{"quick", 0})).echoed, "quick");

    // The late reply of "slow" lands here and must not be taken for another call's.
    std::this_thread::sleep_for(std::chrono::milliseconds(450));
    for (int i = 0; i < 5; ++i) {
        const auto r = mustOk(ctx->echo(EchoRequest{"after-" + std::to_string(i), 0}));
        EXPECT_EQ(r.echoed, "after-" + std::to_string(i));
    }
}

// Nobody waits on a future's deadline but the dispatch thread, which fails it in time.
TEST(TimerE2E, AsyncCallTimesOutInsteadOfHanging) {
    auto ctx = mustOk(MyTimerCtx::create(TimerConfig{"async-timeout"},
                                         std::chrono::milliseconds(100)));

    auto slowFut = ctx->echoAsync(EchoRequest{"slow", 1500});
    ASSERT_EQ(slowFut.wait_for(std::chrono::milliseconds(1200)), std::future_status::ready)
        << "the future outlived its timeout";
    const auto slow = slowFut.get();
    ASSERT_TRUE(slow.isErr());
    EXPECT_EQ(slow.error(), "FFI call timed out after 100ms");

    EXPECT_EQ(mustOk(ctx->echoAsync(EchoRequest{"quick", 0}).get()).echoed, "quick");
}

// Destroying a context fails the calls still waiting for their reply; a reply
// that made it out before the context closed is still delivered.
TEST(TimerE2E, DestroyFailsTheCallsInFlight) {
    auto ctx = makeCtx("destroy-in-flight");

    std::vector<std::future<Result<EchoResponse>>> futs;
    for (int i = 0; i < 8; ++i) {
        futs.push_back(ctx->echoAsync(EchoRequest{"pending", 1000}));
    }
    ctx.reset();

    for (auto& fut : futs) {
        ASSERT_EQ(fut.wait_for(std::chrono::seconds(0)), std::future_status::ready)
            << "a future survived its context";
        const auto r = fut.get();
        if (r.isErr()) {
            // Either the library answered the call as it recycled, or the binding
            // failed it when the poll returned CLOSED. Both say the context is gone.
            EXPECT_TRUE(r.error().find("context closed") != std::string::npos ||
                        r.error().find("recycled") != std::string::npos)
                << r.error();
        } else {
            EXPECT_EQ(r->echoed, "pending");
        }
    }
}

// A request the library refuses at the door claims no context: well past the
// pool's 32 slots, a create still works.
TEST(TimerE2E, RefusedCreateLeaksNoContext) {
    const TimerConfig tooLarge{std::string(9 * 1024 * 1024, 'x')};
    for (int i = 0; i < 34; ++i) {
        const auto res = MyTimerCtx::create(tooLarge);
        ASSERT_TRUE(res.isErr()) << "round " << i;
        EXPECT_FALSE(res.error().empty());
    }
    auto asyncRes = MyTimerCtx::createAsync(tooLarge).get();
    EXPECT_TRUE(asyncRes.isErr());

    auto ctx = makeCtx("after-refusals");
    EXPECT_EQ(mustOk(ctx->version()), TIMER_VERSION);
}

// Contexts come and go well past the pool's 32 slots, through both creates.
TEST(TimerE2E, CreateDestroyLoopReusesThePool) {
    for (int i = 0; i < 40; ++i) {
        auto ctx = (i & 1) ? mustOk(MyTimerCtx::createAsync(TimerConfig{"loop"}).get())
                           : makeCtx("loop");
        ASSERT_TRUE(ctx) << "round " << i;
        EXPECT_EQ(mustOk(ctx->version()), TIMER_VERSION);
    }
}

TEST(TimerE2E, CreateAsyncBuildsAWorkingContext) {
    auto f1 = MyTimerCtx::createAsync(TimerConfig{"async-1"});
    auto f2 = MyTimerCtx::createAsync(TimerConfig{"async-2"});
    auto c2 = mustOk(f2.get());
    auto c1 = mustOk(f1.get());
    ASSERT_TRUE(c1 && c2);
    EXPECT_EQ(mustOk(c1->echo(EchoRequest{"x", 0})).timerName, "async-1");
    EXPECT_EQ(mustOk(c2->echo(EchoRequest{"x", 0})).timerName, "async-2");
}

// shutdown stops the static dispatch thread before the library; a later static call
// starts a new static context and a new dispatch thread for it.
TEST(TimerE2E, ShutdownStopsTheStaticDispatcherAndStaticCallsStartOver) {
    EXPECT_EQ(mustOk(EchoCtx::lib_version()), "nim-echo v0.1.0");
    const auto down = EchoCtx::shutdown();
    EXPECT_TRUE(down.isOk()) << down.error();
    EXPECT_EQ(mustOk(EchoCtx::lib_version()), "nim-echo v0.1.0");
    EXPECT_EQ(mustOk(EchoCtx::shout_anonAsync(ShoutRequest{"again"}).get()).shouted, "AGAIN");

    auto ctx = mustOk(EchoCtx::create(EchoConfig{"AFTER-SHUTDOWN"}));
    EXPECT_EQ(mustOk(ctx->shout(ShoutRequest{"a"})).prefix, "AFTER-SHUTDOWN");
}

// Cross-language byte-string contract: the generated C++ codec must round-trip
// a std::vector<std::uint8_t> as a CBOR byte string (major type 2), byte-for-byte
// identical to what Nim's cbor_serialization emits for `seq[byte]`. The goldens
// below match tests/unit/test_wire_compat.nim and tests/unit/test_serial.nim.
TEST(WireCompat, SeqByteRidesAsByteString) {
    const std::vector<std::uint8_t> blob{1, 2, 3};
    auto enc = encodeCborFFI(blob);
    ASSERT_FALSE(enc.isErr()) << enc.error();
    // 0x43 = byte string, length 3; then the raw bytes 01 02 03.
    const std::vector<std::uint8_t> golden{0x43, 0x01, 0x02, 0x03};
    EXPECT_EQ(enc.value(), golden);

    auto dec = decodeCborFFI<std::vector<std::uint8_t>>(enc.value());
    ASSERT_FALSE(dec.isErr()) << dec.error();
    EXPECT_EQ(dec.value(), blob);
}

TEST(WireCompat, EmptySeqByteRidesAsEmptyByteString) {
    const std::vector<std::uint8_t> blob{};
    auto enc = encodeCborFFI(blob);
    ASSERT_FALSE(enc.isErr()) << enc.error();
    // 0x40 = byte string, length 0.
    const std::vector<std::uint8_t> golden{0x40};
    EXPECT_EQ(enc.value(), golden);

    auto dec = decodeCborFFI<std::vector<std::uint8_t>>(enc.value());
    ASSERT_FALSE(dec.isErr()) << dec.error();
    EXPECT_TRUE(dec.value().empty());
}
