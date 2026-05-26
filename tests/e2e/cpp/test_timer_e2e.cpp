// Basic C++ end-to-end tests for the auto-generated `timer` bindings.
//
// These tests link against the same `timer_headers` INTERFACE library and Nim
// shared object used by `examples/timer/cpp_bindings/main.cpp`. They exercise
// the full FFI round-trip — CBOR encode -> Nim FFI thread -> chronos -> CBOR
// decode -> C++ — to validate that a binding produced by `nimble
// genbindings_cpp` is callable end-to-end from C++.

#include "my_timer.hpp"

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

    const auto resp = ctx->echo(EchoRequest{"event-msg", 1});
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
// wire `eventId` pre-extracted plus the raw envelope bytes. The helper
// `decodeEventPayload<T>` lifts the payload into a typed value.
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
            const std::vector<std::uint8_t>& envelope) {
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
