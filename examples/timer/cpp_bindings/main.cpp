#include "my_timer.hpp"
#include <atomic>
#include <chrono>
#include <future>
#include <iostream>
#include <thread>

int main() {
    try {
        auto ctx = MyTimerCtx::create(TimerConfig{"cpp-demo"});
        std::cout << "[1] Context created\n";

        auto versionFuture = ctx->versionAsync();
        auto echo1Future = ctx->echoAsync(EchoRequest{"hello from C++", 200});
        auto echo2Future = ctx->echoAsync(EchoRequest{"second C++ request", 50});

        auto version = versionFuture.get();
        std::cout << "[2] Version: " << version << "\n";

        auto echo = echo1Future.get();
        std::cout << "[3] Echo 1: echoed=" << echo.echoed
                  << ", timerName=" << echo.timerName << "\n";

        auto echo2 = echo2Future.get();
        std::cout << "[4] Echo 2: echoed=" << echo2.echoed
                  << ", timerName=" << echo2.timerName << "\n";

        auto complexReq = ComplexRequest{
            std::vector<EchoRequest>{EchoRequest{"one", 10}, EchoRequest{"two", 20}},
            std::vector<std::string>{"fast", "async"},
            std::optional<std::string>("extra note"),
            std::optional<int64_t>(3)
        };

        auto complexFuture = ctx->complexAsync(complexReq);
        auto complex = complexFuture.get();
        std::cout << "[5] Complex: summary=" << complex.summary
                  << ", itemCount=" << complex.itemCount
                  << ", hasNote=" << complex.hasNote << "\n";

        // Each parameter is its own generated C++ struct. The nim-ffi
        // macro packs all three into one CBOR envelope on the wire — at
        // the call site, this is just a typed method invocation.
        auto job = JobSpec{
            /*name*/ "nightly-rollup",
            /*payload*/ std::vector<std::string>{"rollup", "v2"},
            /*priority*/ 10,
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

        auto scheduleFuture = ctx->scheduleAsync(job, retry, schedule);
        auto scheduleRes = scheduleFuture.get();
        std::cout << "[6] Schedule (3 complex params): jobId=" << scheduleRes.jobId
                  << ", willRunCount=" << scheduleRes.willRunCount
                  << ", firstRunAtMs=" << scheduleRes.firstRunAtMs
                  << ", effectiveBackoffMs=" << scheduleRes.effectiveBackoffMs
                  << "\n";

        // Each `{.ffiEvent.}` declared on the Nim side gets a typed
        // registration method — `addOnEchoFiredListener(handler)` here.
        // A second `addEventListener` overload registers a catch-all
        // wildcard listener that receives every event as raw envelope
        // bytes plus the FFI return code. Both fire from the lib's
        // dispatch thread, so synchronise via std::promise / atomics.
        std::promise<EchoEvent> echoEvtPromise;
        auto echoEvtFuture = echoEvtPromise.get_future();
        const auto typedHandle = ctx->addOnEchoFiredListener(
            [&](const EchoEvent& evt) { echoEvtPromise.set_value(evt); });

        std::atomic<int> wildcardHits{0};
        // Wildcard listener receives every event with the wire `eventId`
        // pre-extracted plus the raw CBOR envelope bytes. Dispatch on
        // `eventId` and use `decodeEventPayload<T>` to lift the payload
        // into a typed value without hand-parsing CBOR.
        const auto wildcardHandle = ctx->addEventListener(
            [&](int retCode, const std::string& eventId,
                const std::vector<std::uint8_t>& envelope) {
                wildcardHits.fetch_add(1);
                std::cout << "[7] wildcard event: retCode=" << retCode
                          << ", eventId=" << eventId
                          << ", envelope bytes=" << envelope.size() << "\n";
                if (retCode != 0) return;
                if (eventId == "on_echo_fired") {
                    EchoEvent decoded{};
                    if (decodeEventPayload(envelope, decoded)) {
                        std::cout << "    decoded EchoEvent: message="
                                  << decoded.message
                                  << ", echoCount=" << decoded.echoCount << "\n";
                    }
                }
            });

        ctx->echo(EchoRequest{"event-demo", 1});
        const auto evt = echoEvtFuture.get();
        std::cout << "[7] typed event onEchoFired: message=" << evt.message
                  << ", echoCount=" << evt.echoCount
                  << ", wildcardHits=" << wildcardHits.load() << "\n";

        // Drop the typed listener — only the wildcard fires for the
        // follow-up echo. Sleep briefly to give the lib thread time to
        // deliver before we tear the ctx down.
        ctx->removeEventListener(typedHandle);
        ctx->echo(EchoRequest{"event-demo-after-remove", 1});
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        std::cout << "[7] after removeEventListener: wildcardHits="
                  << wildcardHits.load() << "\n";
        ctx->removeEventListener(wildcardHandle);

        std::cout << "\nDone.\n";
    } catch (const std::exception& ex) {
        std::cerr << "Error: " << ex.what() << "\n";
        return 1;
    }
    return 0;
}
