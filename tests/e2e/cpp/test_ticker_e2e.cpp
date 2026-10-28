// Listener box lifetime against tests/e2e/ticker: under ASan a box freed too early is a use-after-free.

#include "ticker.hpp"

#include <atomic>
#include <chrono>
#include <future>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

namespace {

constexpr int TickIntervalMs = 1;
constexpr auto WaitLimit = std::chrono::seconds(5);
constexpr std::size_t TagLen = 64;
constexpr int TicksBeforeDestroy = 5;
constexpr int TicksToObserve = 20;

std::unique_ptr<TickerCtx> makeCtx(bool stallTeardown) {
    auto res = TickerCtx::create(TickerConfig{stallTeardown});
    if (res.isErr()) {
        ADD_FAILURE() << "create failed: " << res.error();
        return nullptr;
    }
    return res.take();
}

void startTicks(TickerCtx& ctx) {
    const auto res = ctx.start(TickIntervalMs);
    ASSERT_FALSE(res.isErr()) << res.error();
}

bool waitForTicks(const std::atomic<int>& ticks, int atLeast) {
    const auto deadline = std::chrono::steady_clock::now() + WaitLimit;
    while (ticks.load() < atLeast) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}

} // namespace

TEST(TickerListenerLifetime, ListenerRemovesItself) {
    TickerCtx::ListenerHandle self;
    std::atomic<bool> fired{false};
    std::promise<std::size_t> done;
    auto ctx = makeCtx(false);
    ASSERT_NE(ctx, nullptr);

    // `tag` lives in the box: reading it after the remove reads freed memory unless the free waits for the callback.
    self = ctx->addOnTickListener(
        [&, tag = std::string(TagLen, 'x')](const Tick&) {
            if (fired.exchange(true)) return;
            EXPECT_TRUE(ctx->removeEventListener(self));
            done.set_value(tag.size());
        });
    ASSERT_NE(self.id, 0u);
    startTicks(*ctx);

    auto fut = done.get_future();
    ASSERT_EQ(fut.wait_for(WaitLimit), std::future_status::ready);
    EXPECT_EQ(fut.get(), TagLen);
}

TEST(TickerListenerLifetime, ListenerRemovesSibling) {
    // Declared before `ctx`, so they outlive the ticks its destroy waits out.
    TickerCtx::ListenerHandle sibling;
    std::atomic<bool> removed{false};
    std::atomic<int> callsAfterRemove{0};
    std::atomic<int> ticks{0};
    auto ctx = makeCtx(false);
    ASSERT_NE(ctx, nullptr);

    ctx->addOnTickListener([&](const Tick&) {
        if (!removed.exchange(true)) EXPECT_TRUE(ctx->removeEventListener(sibling));
        ticks.fetch_add(1);
    });
    sibling = ctx->addOnTickListener([&, tag = std::string(TagLen, 'y')](const Tick&) {
        if (removed.load() && tag.size() == TagLen) callsAfterRemove.fetch_add(1);
    });
    ASSERT_NE(sibling.id, 0u);
    startTicks(*ctx);

    ASSERT_TRUE(waitForTicks(ticks, TicksToObserve));
    EXPECT_EQ(callsAfterRemove.load(), 0);
}

TEST(TickerListenerLifetime, StalledDestroyKeepsBoxesAlive) {
    auto ctx = makeCtx(true);
    ASSERT_NE(ctx, nullptr);
    // Shared with the box, which the failed destroy leaks with the context.
    auto ticks = std::make_shared<std::atomic<int>>(0);
    ctx->addOnTickListener([ticks, tag = std::string(TagLen, 'z')](const Tick&) {
        if (tag.size() == TagLen) ticks->fetch_add(1);
    });
    startTicks(*ctx);
    ASSERT_TRUE(waitForTicks(*ticks, TicksBeforeDestroy));

    ctx.reset();

    const int afterDestroy = ticks->load();
    EXPECT_TRUE(waitForTicks(*ticks, afterDestroy + TicksToObserve)) << "the loop stopped firing";
}

TEST(TickerListenerLifetime, RemoveReturnsFalseForUnknownAndRemovedHandles) {
    constexpr std::uint64_t NeverIssuedId = 1000000;
    auto ctx = makeCtx(false);
    ASSERT_NE(ctx, nullptr);
    const auto handle = ctx->addOnTickListener([](const Tick&) {});
    ASSERT_NE(handle.id, 0u);

    EXPECT_FALSE(ctx->removeEventListener(TickerCtx::ListenerHandle{0}));
    EXPECT_FALSE(ctx->removeEventListener(TickerCtx::ListenerHandle{NeverIssuedId}));
    EXPECT_TRUE(ctx->removeEventListener(handle));
    EXPECT_FALSE(ctx->removeEventListener(handle));
}

TEST(TickerListenerLifetime, HostThreadsAddAndRemoveWhileCallbacksFire) {
    constexpr int HostThreads = 4;
    constexpr int CyclesPerThread = 200;
    std::atomic<int> ticks{0};
    std::atomic<int> failedRemoves{0};
    std::atomic<int> zeroIds{0};
    auto ctx = makeCtx(false);
    ASSERT_NE(ctx, nullptr);
    ctx->addOnTickListener([&](const Tick&) { ticks.fetch_add(1); });
    startTicks(*ctx);
    ASSERT_TRUE(waitForTicks(ticks, 1));

    std::vector<std::thread> workers;
    for (int t = 0; t < HostThreads; ++t) {
        workers.emplace_back([&] {
            for (int i = 0; i < CyclesPerThread; ++i) {
                const auto h = ctx->addOnTickListener([tag = std::string(TagLen, 'h')](const Tick&) {
                    if (tag.size() != TagLen) std::abort();
                });
                if (h.id == 0) { zeroIds.fetch_add(1); continue; }
                if (!ctx->removeEventListener(h)) failedRemoves.fetch_add(1);
            }
        });
    }
    for (auto& w : workers) w.join();

    EXPECT_EQ(zeroIds.load(), 0);
    EXPECT_EQ(failedRemoves.load(), 0);
    EXPECT_TRUE(waitForTicks(ticks, ticks.load() + TicksToObserve)) << "the loop stopped firing";
}

TEST(TickerListenerLifetime, RemoveFromOtherContextWaitsForRunningCallback) {
    constexpr auto RaceWindow = std::chrono::milliseconds(50);
    std::atomic<bool> aInside{false};
    std::atomic<bool> bRemoving{false};
    std::atomic<bool> aFired{false};
    std::promise<std::size_t> aDone;
    auto ctxA = makeCtx(false);
    auto ctxB = makeCtx(false);
    ASSERT_NE(ctxA, nullptr);
    ASSERT_NE(ctxB, nullptr);

    const auto victim = ctxA->addOnTickListener([&, tag = std::string(TagLen, 'v')](const Tick&) {
        if (aFired.exchange(true)) return;
        aInside = true;
        const auto deadline = std::chrono::steady_clock::now() + WaitLimit;
        while (!bRemoving.load() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::yield();
        // A remove that does not wait for this callback frees `tag` inside this window.
        std::this_thread::sleep_for(RaceWindow);
        aDone.set_value(tag.size());
    });
    ASSERT_NE(victim.id, 0u);
    ctxB->addOnTickListener([&](const Tick&) {
        if (!aInside.load() || bRemoving.exchange(true)) return;
        EXPECT_TRUE(ctxA->removeEventListener(victim));
    });
    startTicks(*ctxA);
    startTicks(*ctxB);

    auto fut = aDone.get_future();
    ASSERT_EQ(fut.wait_for(WaitLimit * 2), std::future_status::ready);
    EXPECT_EQ(fut.get(), TagLen);
}
