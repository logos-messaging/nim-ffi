// End-to-end FFI round-trip benchmark for the CBOR-mode timer library.
//
// Times the full path foreign-thread → CBOR encode → FFI thread → chronos →
// CBOR encode → callback dispatch → CBOR decode → foreign-thread, using the
// auto-generated C++ wrapper at `examples/timer/cpp_bindings/my_timer.hpp`.
//
// The paired raw-mode benchmark under `tests/bench/c_raw/` exercises the
// same operations against the `ffiMode=raw` library; the runner script
// diffs the two CSV outputs.

#include "my_timer.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

using clk = std::chrono::steady_clock;

double timeOp(const char* label, int iters, const std::function<void(int)>& op) {
    // Warm-up — the very first FFI call pays for thread/context-pool init,
    // ORC churn, and a chronos tick that the steady-state cost shouldn't
    // include. A handful of iterations is plenty.
    for (int i = 0; i < std::min(iters, 50); ++i) op(i);

    const auto start = clk::now();
    for (int i = 0; i < iters; ++i) op(i);
    const auto elapsed = clk::now() - start;
    const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count();
    const double perOp = static_cast<double>(ns) / iters;
    std::printf("%s,cbor,%.2f,%d\n", label, perOp, iters);
    std::fflush(stdout);
    return perOp;
}

} // namespace

int main(int argc, char** argv) {
    const int versionIters = argc > 1 ? std::atoi(argv[1]) : 5000;
    const int echoIters    = argc > 2 ? std::atoi(argv[2]) : 2000;
    const int complexIters = argc > 3 ? std::atoi(argv[3]) : 2000;
    const int schedIters   = argc > 4 ? std::atoi(argv[4]) : 2000;

    auto ctx = MyTimerCtx::create(TimerConfig{"bench-cbor"});

    std::printf("op,mode,ns_per_op,iters\n");

    timeOp("version_sync", versionIters, [&](int){
        const auto v = ctx.version();
        if (v.empty()) std::abort();
    });

    timeOp("echo_0ms", echoIters, [&](int i){
        const auto r = ctx.echo(EchoRequest{"hello", 0});
        if (r.timerName.empty()) std::abort();
        (void)i;
    });

    timeOp("complex_small", complexIters, [&](int){
        const auto r = ctx.complex(ComplexRequest{
            std::vector<EchoRequest>{
                EchoRequest{"alpha", 0},
                EchoRequest{"beta",  0},
                EchoRequest{"gamma", 0},
                EchoRequest{"delta", 0},
            },
            std::vector<std::string>{"fast", "async", "bench"},
            std::optional<std::string>("a slightly longer note"),
            std::optional<int64_t>(7),
        });
        if (r.itemCount != 4) std::abort();
    });

    timeOp("schedule_3objs", schedIters, [&](int){
        const auto r = ctx.schedule(
            JobSpec{"nightly-rollup", {"rollup", "v2"}, 10},
            RetryPolicy{3, 500, {"timeout", "5xx"}},
            ScheduleConfig{1000, 15000, std::optional<int64_t>(250)});
        if (r.willRunCount <= 0) std::abort();
    });

    // ── Payload-size sweep ────────────────────────────────────────────────
    // Sizes mirror real consumers: 100 B (RPC), 1 KiB (chat), 10 KiB (fat
    // pubsub), 64 KiB (codex block), 150 KiB (Waku max). Iteration count
    // scales down with size to keep wall-clock budget reasonable.
    struct SizeCfg { int size; int iters; const char* label; };
    const SizeCfg sweep[] = {
        {     100, 2000, "bytes_echo_100B"  },
        {    1024, 2000, "bytes_echo_1KiB"  },
        {  10*1024, 1000, "bytes_echo_10KiB" },
        {  64*1024,  500, "bytes_echo_64KiB" },
        { 150*1024,  300, "bytes_echo_150KiB"},
    };
    for (const auto& cfg : sweep) {
        BytesPayload blob;
        blob.payload.assign(cfg.size, static_cast<uint8_t>(0xAB));
        timeOp(cfg.label, cfg.iters, [&](int){
            const auto r = ctx.bytes_echo(blob);
            if (static_cast<int>(r.payload.size()) != cfg.size) std::abort();
        });
    }

    return 0;
}
