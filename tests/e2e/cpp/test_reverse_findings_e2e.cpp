// Reproducers for the PR #154 review findings at the C++ wrapper layer. Each test
// asserts the intended behaviour, so it fails until its finding is fixed.
//
// "Freed" is observed without touching freed memory: every impl captures a
// shared_ptr token, the test keeps only a weak_ptr to it, and the impl copies
// the pointer to its probe onto its own stack before doing anything that could
// destroy its box.

#include "my_timer.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

namespace {

std::unique_ptr<MyTimerCtx> makeCtx(const std::string& name) {
    auto r = MyTimerCtx::create(TimerConfig{name});
    if (r.isErr()) {
        ADD_FAILURE() << "create failed: " << r.error();
        return nullptr;
    }
    return r.take();
}

struct Latch {
    std::mutex m;
    std::condition_variable cv;
    bool open = false;
    int entered = 0;

    void enterAndWait() {
        std::unique_lock<std::mutex> lk(m);
        entered++;
        cv.notify_all();
        cv.wait(lk, [&] { return open; });
    }
    void waitEntered(int n) {
        std::unique_lock<std::mutex> lk(m);
        cv.wait(lk, [&] { return entered >= n; });
    }
    void release() {
        std::lock_guard<std::mutex> lk(m);
        open = true;
        cv.notify_all();
    }
};

// Outlives every box; the impls reach it through a raw pointer copied to the stack.
struct Probe {
    MyTimerCtx* ctx = nullptr;
    std::weak_ptr<int> capture; // the running impl's own capture
    Latch latch;
    std::atomic<int> freedWhileRunning{-1}; // -1 unset, 0 alive, 1 freed
    std::atomic<bool> done{false};
};

void noopImpl(MyTimerCtx::FetchHostClockCall call, const std::string&) {
    call.reply(HostClock{0, "UTC"});
}

} // namespace

// Review comment 4087687777, "the same happens when an impl replaces itself".
TEST(ReverseFindings, SelfReplacementKeepsTheRunningImplsCapturesAlive) {
    auto ctx = makeCtx("find-self-replace");
    ASSERT_TRUE(ctx);
    Probe probe;
    probe.ctx = ctx.get();
    auto token = std::make_shared<int>(1);
    probe.capture = token;
    ASSERT_TRUE(ctx->setFetchHostClockImpl(
        [token, p = &probe](MyTimerCtx::FetchHostClockCall call, const std::string&) {
            Probe* local = p; // the capture itself may die below
            local->ctx->setFetchHostClockImpl(&noopImpl);
            local->freedWhileRunning.store(local->capture.expired() ? 1 : 0);
            call.reply(HostClock{1, "UTC"});
            local->done.store(true);
        }));
    token.reset(); // only the box holds it now

    auto r = ctx->host_clock();
    ASSERT_FALSE(r.isErr()) << r.error();
    ASSERT_TRUE(probe.done.load());
    // 1 today: set_impl returned, the wrapper destroyed the old box, and with it
    // the std::function this impl is still executing.
    EXPECT_EQ(probe.freedWhileRunning.load(), 0);
}

// Control: a host thread outside any dispatch already waits.
TEST(ReverseFindings, ClearFromAHostThreadWaitsForTheRunningImpl) {
    auto ctx = makeCtx("find-host-clear");
    ASSERT_TRUE(ctx);
    Probe probe;
    probe.ctx = ctx.get();
    auto token = std::make_shared<int>(1);
    probe.capture = token;
    ASSERT_TRUE(ctx->setFetchHostClockImpl(
        [token, p = &probe](MyTimerCtx::FetchHostClockCall call, const std::string&) {
            Probe* local = p;
            local->latch.enterAndWait();
            local->freedWhileRunning.store(local->capture.expired() ? 1 : 0);
            call.reply(HostClock{1, "UTC"});
        }));
    token.reset();

    auto pending = ctx->host_clockAsync();
    probe.latch.waitEntered(1);
    std::thread releaser([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        probe.latch.release();
    });
    ASSERT_TRUE(ctx->clearFetchHostClockImpl()); // blocks until the impl returns
    releaser.join();
    EXPECT_EQ(probe.freedWhileRunning.load(), 0);
    EXPECT_TRUE(probe.capture.expired()); // and the box is gone right after
    (void)pending.get();
}

// Found in the walkthrough: ~MyTimerCtx frees the box even when destroy had
// to leak a worker that is still inside the impl.
TEST(ReverseFindings, DestroyWithAStuckImplKeepsItsCapturesAlive) {
    auto ctx = makeCtx("find-teardown");
    ASSERT_TRUE(ctx);
    auto probe = std::make_shared<Probe>(); // outlives the ctx and the test body
    probe->ctx = ctx.get();
    auto token = std::make_shared<int>(1);
    probe->capture = token;
    ASSERT_TRUE(ctx->setFetchHostClockImpl(
        [token, p = probe.get()](MyTimerCtx::FetchHostClockCall call, const std::string&) {
            Probe* local = p;
            call.reply(HostClock{1, "UTC"}); // answer first, then stay stuck
            local->latch.enterAndWait();
            local->freedWhileRunning.store(local->capture.expired() ? 1 : 0);
            local->done.store(true);
        }));
    token.reset();

    // The call completes (so no host thread still uses `ctx`); the worker stays inside.
    ASSERT_FALSE(ctx->host_clock().isErr());
    probe->latch.waitEntered(1);
    ctx.reset(); // destroy: the recycle quarantines the slot, the wrapper frees the box
    probe->latch.release();
    for (int i = 0; i < 1000 && !probe->done.load(); i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(probe->done.load());
    // 1 today: the leaked worker resumed inside a destroyed std::function.
    EXPECT_EQ(probe->freedWhileRunning.load(), 0);
}

// Review comment 4087688037: an exception must not cross the extern "C" boundary.
TEST(ReverseFindings, ThrowingImplFailsTheCallInsteadOfTerminating) {
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(
        {
            auto ctx = makeCtx("find-throw");
            ctx->setFetchHostClockImpl([](MyTimerCtx::FetchHostClockCall, const std::string&) {
                throw std::runtime_error("boom");
            });
            auto r = ctx->host_clock();
            std::_Exit(r.isErr() ? 0 : 1);
        },
        ::testing::ExitedWithCode(0), "");
}

// Found in the walkthrough: the C++ slot has no lock at all, so the Rust race
// (review comment 4087687900) is a data race here. Probabilistic without TSan.
TEST(ReverseFindings, ConcurrentSetsLeaveNimAndTheWrapperAgreeing) {
    auto ctx = makeCtx("find-set-race");
    ASSERT_TRUE(ctx);
    std::atomic<int> invokedId{-1};
    constexpr int kThreads = 4;
    constexpr int kIters = 500;
    std::vector<std::thread> setters;
    for (int t = 0; t < kThreads; t++) {
        setters.emplace_back([&, t] {
            for (int i = 0; i < kIters; i++) {
                const int id = t * kIters + i;
                ctx->setFetchHostClockImpl(
                    [id, &invokedId](MyTimerCtx::FetchHostClockCall call, const std::string&) {
                        invokedId.store(id);
                        call.reply(HostClock{id, "UTC"});
                    });
            }
        });
    }
    for (auto& s : setters) s.join();
    auto r = ctx->host_clock();
    ASSERT_FALSE(r.isErr()) << r.error();
    // The impl Nim runs must be one the wrapper still owns. Today Nim may hold a
    // box the wrapper already dropped; ASan reports that as heap-use-after-free.
    EXPECT_GE(invokedId.load(), 0);
}
