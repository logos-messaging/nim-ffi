#include "my_timer.hpp"
#include <atomic>
#include <chrono>
#include <future>
#include <iostream>
#include <thread>

static int failures = 0;

template <typename T, typename U>
static void expect(const char* what, const T& got, const U& want) {
    if (!(got == want)) {
        std::cerr << "FAIL " << what << ": got " << got << ", want " << want << "\n";
        failures++;
    }
}

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
    expect("version", version.value(), std::string(TIMER_VERSION));
    expect("TIMER_VERSION", std::string(TIMER_VERSION), "nim-timer v0.1.0");
    expect("MAX_DELAY_MS", MAX_DELAY_MS, 5000);

    auto echo = echo1Future.get();
    if (echo.isErr()) {
        std::cerr << "Error: " << echo.error() << "\n";
        return 1;
    }
    std::cout << "[3] Echo 1: echoed=" << echo->echoed
              << ", timerName=" << echo->timerName << "\n";
    expect("echo1.echoed", echo->echoed, "hello from C++");
    expect("echo1.timerName", echo->timerName, "cpp-demo");

    auto echo2 = echo2Future.get();
    if (echo2.isErr()) {
        std::cerr << "Error: " << echo2.error() << "\n";
        return 1;
    }
    std::cout << "[4] Echo 2: echoed=" << echo2->echoed
              << ", timerName=" << echo2->timerName << "\n";
    expect("echo2.echoed", echo2->echoed, "second C++ request");
    expect("echo2.timerName", echo2->timerName, "cpp-demo");

    // A delay above MAX_DELAY_MS is rejected: the Result carries the error.
    auto tooSlow = ctx->echo(EchoRequest{"too slow", MAX_DELAY_MS + 1});
    std::cout << "[4b] Echo over MAX_DELAY_MS: isErr=" << tooSlow.isErr() << "\n";
    expect("echo over limit fails", tooSlow.isErr(), true);
    if (tooSlow.isErr()) {
        expect("echo over limit error", tooSlow.error(), "delayMs must not exceed 5000");
    }

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
    expect("complex.summary", complex->summary,
           "received 2 messages, note=extra note, retries=3");
    expect("complex.itemCount", complex->itemCount, 2);
    expect("complex.hasNote", complex->hasNote, true);

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
    expect("schedule.jobId", scheduleRes->jobId, "cpp-demo:nightly-rollup");
    expect("schedule.willRunCount", scheduleRes->willRunCount, 60000 / 15000);
    expect("schedule.firstRunAtMs", scheduleRes->firstRunAtMs, 1000 + 250);
    expect("schedule.effectiveBackoffMs", scheduleRes->effectiveBackoffMs, 500 / 2);
    expect("schedule.priority", scheduleRes->priority == JobPriority::jpHigh, true);

    // Each `{.ffiEvent.}` declared on the Nim side gets a typed
    // registration method — `addOnEchoFiredListener(handler)` here.
    // Subscribe to each event separately; handlers fire from the lib's
    // dispatch thread, so synchronise via std::promise / atomics.
    std::promise<EchoEvent> echoEvtPromise;
    auto echoEvtFuture = echoEvtPromise.get_future();
    std::atomic<int> echoEvtCalls{0};
    const auto typedHandle = ctx->addOnEchoFiredListener([&](const EchoEvent& evt) {
        if (echoEvtCalls.fetch_add(1) == 0) echoEvtPromise.set_value(evt);
    });

    ctx->echo(EchoRequest{"event-demo", 1});
    if (echoEvtFuture.wait_for(std::chrono::seconds(5)) != std::future_status::ready) {
        std::cerr << "Error: onEchoFired never arrived\n";
        ctx->removeEventListener(typedHandle);
        return 1;
    }
    const auto evt = echoEvtFuture.get();
    std::cout << "[7] typed event onEchoFired: message=" << evt.message
              << ", echoCount=" << evt.echoCount << "\n";
    expect("onEchoFired.message", evt.message, "event-demo");
    expect("onEchoFired.echoCount", evt.echoCount, 1);

    // Drop the typed listener: no handler fires for the follow-up echo.
    expect("removeEventListener", ctx->removeEventListener(typedHandle), true);
    ctx->echo(EchoRequest{"event-demo-after-remove", 1});
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    std::cout << "[7] after removeEventListener: handler calls=" << echoEvtCalls.load()
              << "\n";
    expect("onEchoFired calls after remove", echoEvtCalls.load(), 1);

    if (failures != 0) {
        std::cerr << "\n" << failures << " check(s) failed.\n";
        return 1;
    }
    std::cout << "\nDone.\n";
    return 0;
}
