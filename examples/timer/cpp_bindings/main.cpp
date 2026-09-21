#include "my_timer.hpp"
#include <atomic>
#include <future>
#include <iostream>

// The generated bindings never throw: every call returns a Result<T>. We
// branch on isErr() and read value()/error() instead of using try/catch.
int main() {
    auto ctxRes = MyTimerCtx::create(TimerConfig{"cpp-demo"});
    if (ctxRes.isErr()) {
        std::cerr << "Error: " << ctxRes.error() << "\n";
        return 1;
    }
    auto ctx = std::move(ctxRes.value());
    std::cout << "[1] Context created\n";

    auto versionFuture = ctx->versionAsync();
    auto echo1Future = ctx->echoAsync(EchoRequest{"hello from C++", 200});
    auto echo2Future = ctx->echoAsync(EchoRequest{"second C++ request", 50});

    auto version = versionFuture.get();
    if (version.isErr()) {
        std::cerr << "Error: " << version.error() << "\n";
        return 1;
    }
    std::cout << "[2] Version: " << version.value() << " (const TIMER_VERSION="
              << TIMER_VERSION << ", MAX_DELAY_MS=" << MAX_DELAY_MS << ")\n";

    auto echo = echo1Future.get();
    if (echo.isErr()) {
        std::cerr << "Error: " << echo.error() << "\n";
        return 1;
    }
    std::cout << "[3] Echo 1: echoed=" << echo->echoed
              << ", timerName=" << echo->timerName << "\n";

    auto echo2 = echo2Future.get();
    if (echo2.isErr()) {
        std::cerr << "Error: " << echo2.error() << "\n";
        return 1;
    }
    std::cout << "[4] Echo 2: echoed=" << echo2->echoed
              << ", timerName=" << echo2->timerName << "\n";

    auto complexReq = ComplexRequest{
        std::vector<EchoRequest>{EchoRequest{"one", 10}, EchoRequest{"two", 20}},
        std::vector<std::string>{"fast", "async"},
        std::optional<std::string>("extra note"),
        std::optional<int64_t>(3)
    };

    auto complex = ctx->complexAsync(complexReq).get();
    if (complex.isErr()) {
        std::cerr << "Error: " << complex.error() << "\n";
        return 1;
    }
    std::cout << "[5] Complex: summary=" << complex->summary
              << ", itemCount=" << complex->itemCount
              << ", hasNote=" << complex->hasNote << "\n";

    // ── 6. Call with three complex parameters ─────────────────────
    // Each parameter is its own generated C++ struct. The nim-ffi
    // macro packs all three into one CBOR envelope on the wire — at
    // the call site, this is just a typed method invocation.
    auto job = JobSpec{
        /*name*/ "nightly-rollup",
        /*payload*/ std::vector<std::string>{"rollup", "v2"},
        JobPriority::jpHigh,
    };
    auto retry = RetryPolicy{
        /*maxAttempts*/ 3,
        /*backoffMs*/ 500,
        /*retryOn*/ std::vector<std::string>{"timeout", "5xx"},
    };
    auto schedule = ScheduleConfig{
        /*startAtMs*/ 1000,
        /*intervalMs*/ 15000,
        /*jitter*/ std::optional<int64_t>(250),
    };

    auto scheduleRes = ctx->scheduleAsync(job, retry, schedule).get();
    if (scheduleRes.isErr()) {
        std::cerr << "Error: " << scheduleRes.error() << "\n";
        return 1;
    }
    std::cout << "[6] Schedule (3 complex params): jobId=" << scheduleRes->jobId
              << ", willRunCount=" << scheduleRes->willRunCount
              << ", firstRunAtMs=" << scheduleRes->firstRunAtMs
              << ", effectiveBackoffMs=" << scheduleRes->effectiveBackoffMs
              << ", priority=" << static_cast<int>(scheduleRes->priority) << "\n";

    // Each `{.ffiEvent.}` declared on the Nim side gets a typed
    // registration method — `addOnEchoFiredListener(handler)` here. The
    // context's pump thread takes the events out of `my_timer_poll` and calls
    // the handlers, so synchronise via std::promise / atomics.
    std::promise<EchoEvent> echoEvtPromise;
    auto echoEvtFuture = echoEvtPromise.get_future();
    const auto typedHandle = ctx->addOnEchoFiredListener(
        [&](const EchoEvent& evt) { echoEvtPromise.set_value(evt); });

    ctx->echo(EchoRequest{"event-demo", 1});
    const auto evt = echoEvtFuture.get();
    std::cout << "[7] typed event onEchoFired: message=" << evt.message
              << ", echoCount=" << evt.echoCount << "\n";

    // Drop the typed listener — no handler fires for the follow-up echo.
    ctx->removeEventListener(typedHandle);
    ctx->echo(EchoRequest{"event-demo-after-remove", 1});
    std::cout << "[7] after removeEventListener: typed listener removed\n";

    // The liveness and closed hooks are listeners too. The closed hook is the
    // last call a context makes; the destructor joins the pump, so it has run
    // by the time `reset` returns.
    ctx->addNotRespondingListener([](std::uint64_t reason) {
        std::cerr << "context stopped answering, reason=" << reason << "\n";
    });
    std::atomic<bool> closedOk{false};
    ctx->addClosedListener(
        [&](bool ok, const std::string&) { closedOk.store(ok); });
    ctx.reset();
    std::cout << "[8] context closed: ok=" << closedOk.load() << "\n";

    // A static proc needs no context: its reply arrives on the library's static
    // context, which has a pump of its own. `shutdown` stops that pump, then
    // every context the library still holds.
    auto libVersion = MyTimerCtx::lib_version();
    if (libVersion.isErr()) {
        std::cerr << "Error: " << libVersion.error() << "\n";
        return 1;
    }
    std::cout << "[9] static lib_version: " << libVersion.value() << "\n";
    auto down = MyTimerCtx::shutdown();
    if (down.isErr()) {
        std::cerr << "Error: " << down.error() << "\n";
        return 1;
    }

    std::cout << "\nDone.\n";
    return 0;
}
