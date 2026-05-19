// Basic C++ end-to-end tests for the auto-generated `timer` bindings.
//
// These tests link against the same `timer_headers` INTERFACE library and Nim
// shared object used by `examples/timer/cpp_bindings/main.cpp`. They exercise
// the full FFI round-trip — CBOR encode -> Nim FFI thread -> chronos -> CBOR
// decode -> C++ — to validate that a binding produced by `nimble
// genbindings_cpp` is callable end-to-end from C++.

#include "my_timer.hpp"

#include <chrono>
#include <future>
#include <memory>
#include <string>
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
