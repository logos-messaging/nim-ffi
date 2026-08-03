// perf_driver — C++ -> Nim -> C++ e2e perf harness for nim-ffi.
//
// Drives the ACTUAL foreign path: this C++ process -> generated
// perfbench.hpp wrapper (CBOR encode) -> libperfbench C ABI -> FFI thread
// -> Nim handler, and back.
//
// Three lanes:
//   sync    C++ -> Nim -> C++   blocking round trip; per-call latency sampled
//   async   C++ -> Nim -> C++   `*Async` future turnaround, bounded in-flight
//                               window per thread; throughput only
//   event   C++ -> Nim -> C++   a sync trigger fires one on_perf_ping event
//                               per call; delivery latency is measured from a
//                               driver-side steady_clock stamp passed through
//                               the Nim provider verbatim
//
// Two payload families share ONE trivial O(1) parity predicate as the handler
// compute, so setups differ purely in TRANSPORT cost, never in handler work:
//   scalar  — 2 x int64 + 1 x float64 in, bool out
//   payload — N-byte byte payload (N swept), predicate over (first byte,
//             last byte, length); the bytes are never walked by the handler
//
// Correctness is enforced on every reply: a wrong or failed result aborts the
// run rather than being mistimed.
//
// Env knobs: NIM_FFI_PERF_THREADS ("1,2,4,8"), NIM_FFI_PERF_PER_THREAD (2000),
// NIM_FFI_PERF_ITERS (3, median reported), NIM_FFI_PERF_PAYLOAD_SIZES
// ("64,512,4096,65536"), NIM_FFI_PERF_EVENT_PAYLOAD (512),
// NIM_FFI_PERF_ASYNC_WINDOW (64 in-flight futures per thread).

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "perfbench.hpp"

using sclock = std::chrono::steady_clock;

static int envInt(const char* name, int def) {
    const char* v = std::getenv(name);
    if (v == nullptr || *v == '\0') return def;
    return std::atoi(v);
}

static std::vector<int> envIntList(const char* name, const char* def) {
    const char* v = std::getenv(name);
    std::string s = (v != nullptr && *v != '\0') ? v : def;
    std::vector<int> out;
    size_t pos = 0;
    while (pos < s.size()) {
        size_t comma = s.find(',', pos);
        if (comma == std::string::npos) comma = s.size();
        out.push_back(std::atoi(s.substr(pos, comma - pos).c_str()));
        pos = comma + 1;
    }
    return out;
}

[[noreturn]] static void fatal(const char* what, const std::string& detail) {
    std::fprintf(stderr, "FATAL: %s: %s\n", what, detail.c_str());
    std::exit(2);
}

// ---------------------------------------------------------------------------
// Formatting — human-readable ns and table helpers.
// ---------------------------------------------------------------------------

static void fmtNs(char* buf, size_t cap, int64_t ns) {
    if (ns >= 1'000'000'000) {
        std::snprintf(buf, cap, "%.3f s", static_cast<double>(ns) / 1e9);
    } else if (ns >= 1'000'000) {
        std::snprintf(buf, cap, "%.3f ms", static_cast<double>(ns) / 1e6);
    } else if (ns >= 1'000) {
        std::snprintf(buf, cap, "%.1f µs", static_cast<double>(ns) / 1e3);
    } else {
        std::snprintf(buf, cap, "%" PRId64 " ns", ns);
    }
}

static double median(std::vector<double> xs) {
    std::sort(xs.begin(), xs.end());
    const size_t n = xs.size();
    return (n % 2 == 1) ? xs[n / 2] : (xs[n / 2 - 1] + xs[n / 2]) / 2.0;
}

static int64_t percentile(const std::vector<int64_t>& sorted, int pct) {
    if (sorted.empty()) return 0;
    const size_t i = (sorted.size() * static_cast<size_t>(pct)) / 100;
    return sorted[std::min(i, sorted.size() - 1)];
}

// ---------------------------------------------------------------------------
// The one shared predicate — identical formula in the Nim provider
// (`parityPred` in perfbench.nim), so every reply is exactly predictable here.
// ---------------------------------------------------------------------------

static bool parityPred(int64_t a, int64_t b, double x) {
    return ((a + b + static_cast<int64_t>(x)) & 1) == 0;
}

static std::vector<std::uint8_t> makePayload(int size) {
    std::vector<std::uint8_t> p(static_cast<size_t>(size));
    for (size_t i = 0; i < p.size(); ++i) p[i] = static_cast<std::uint8_t>(i & 0xFF);
    return p;
}

static bool payloadPredOf(const std::vector<std::uint8_t>& p) {
    if (p.empty()) return parityPred(0, 0, 0.0);
    return parityPred(static_cast<int64_t>(p.front()), static_cast<int64_t>(p.back()),
                      static_cast<double>(p.size()));
}

// Scalar family inputs, derived per message index i.
static int64_t scalarA(int64_t i) { return i; }
static int64_t scalarB(int64_t i) { return 3 * i + 1; }
static double scalarX(int64_t i) { return 0.5 * static_cast<double>(i); }
static bool scalarPred(int64_t i) {
    return parityPred(scalarA(i), scalarB(i), scalarX(i));
}

static std::unique_ptr<PerfbenchCtx> makeCtx() {
    auto r = PerfbenchCtx::create(PerfbenchConfig{"perf"});
    if (r.isErr()) fatal("PerfbenchCtx::create", r.error());
    return r.take();
}

struct IterOut {
    double msgPerSec = 0.0;
    std::vector<int64_t> latNs; // empty for lanes without per-call samples
};

// ---------------------------------------------------------------------------
// sync lane — blocking round trips, per-call latency sampled.
// `call(ctx, i)` performs one verified round trip.
// ---------------------------------------------------------------------------

template <typename CallFn>
static IterOut runSync(int threads, int perThread, CallFn&& call) {
    auto ctx = makeCtx();
    std::atomic<bool> start{false};
    std::vector<std::vector<int64_t>> perThreadLat(static_cast<size_t>(threads));

    std::vector<std::thread> workers;
    workers.reserve(static_cast<size_t>(threads));
    for (int t = 0; t < threads; ++t) {
        workers.emplace_back([&, t] {
            auto& lat = perThreadLat[static_cast<size_t>(t)];
            lat.reserve(static_cast<size_t>(perThread));
            while (!start.load(std::memory_order_acquire)) {}
            for (int64_t i = 0; i < perThread; ++i) {
                const auto c0 = sclock::now();
                call(*ctx, i);
                const auto c1 = sclock::now();
                lat.push_back(
                    std::chrono::duration_cast<std::chrono::nanoseconds>(c1 - c0)
                        .count());
            }
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& w : workers) w.join(); // blocking calls: join == all done
    const auto t1 = sclock::now();

    IterOut out;
    for (auto& v : perThreadLat)
        out.latNs.insert(out.latNs.end(), v.begin(), v.end());
    const double sec = std::chrono::duration<double>(t1 - t0).count();
    out.msgPerSec =
        static_cast<double>(static_cast<uint64_t>(threads) *
                            static_cast<uint64_t>(perThread)) /
        sec;
    return out;
}

// ---------------------------------------------------------------------------
// async lane — `*Async` future turnaround with a bounded in-flight window.
// `issue(ctx, i)` returns the future; `expect(i)` the predicted predicate.
// ---------------------------------------------------------------------------

template <typename IssueFn, typename ExpectFn>
static IterOut runAsync(int threads, int perThread, int window, IssueFn&& issue,
                        ExpectFn&& expect) {
    auto ctx = makeCtx();
    std::atomic<bool> start{false};
    std::atomic<uint64_t> bad{0};

    std::vector<std::thread> workers;
    workers.reserve(static_cast<size_t>(threads));
    for (int t = 0; t < threads; ++t) {
        workers.emplace_back([&] {
            using Fut = decltype(issue(*ctx, int64_t{0}));
            std::deque<std::pair<int64_t, Fut>> inflight;
            auto drainOne = [&] {
                auto [idx, fut] = std::move(inflight.front());
                inflight.pop_front();
                auto r = fut.get();
                if (r.isErr() || r.value().ok != expect(idx))
                    bad.fetch_add(1, std::memory_order_relaxed);
            };
            while (!start.load(std::memory_order_acquire)) {}
            for (int64_t i = 0; i < perThread; ++i) {
                inflight.emplace_back(i, issue(*ctx, i));
                if (inflight.size() >= static_cast<size_t>(window)) drainOne();
            }
            while (!inflight.empty()) drainOne();
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& w : workers) w.join();
    const auto t1 = sclock::now();

    if (bad.load() != 0)
        fatal("async correctness",
              std::to_string(bad.load()) + " failed or mispredicted replies");

    IterOut out;
    const double sec = std::chrono::duration<double>(t1 - t0).count();
    out.msgPerSec =
        static_cast<double>(static_cast<uint64_t>(threads) *
                            static_cast<uint64_t>(perThread)) /
        sec;
    return out;
}

// ---------------------------------------------------------------------------
// event lane — each verified sync trigger fires one on_perf_ping event; the
// listener measures delivery latency from the driver-side stamp. The clock is
// std::chrono::steady_clock on both ends (the stamp is passed through Nim
// verbatim), so the delta is a meaningful per-event delivery latency.
// ---------------------------------------------------------------------------

static IterOut runEvent(int threads, int perThread, int payloadBytes) {
    auto ctx = makeCtx();
    const uint64_t total =
        static_cast<uint64_t>(threads) * static_cast<uint64_t>(perThread);

    std::vector<int64_t> latencies;
    latencies.reserve(total);
    std::mutex latMu;
    std::atomic<uint64_t> delivered{0};

    const auto handle = ctx->addOnPerfPingListener([&](const PerfPingEvent& evt) {
        const int64_t nowNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                  sclock::now().time_since_epoch())
                                  .count();
        {
            std::lock_guard<std::mutex> g(latMu);
            latencies.push_back(nowNs - evt.stampNs);
        }
        delivered.fetch_add(1, std::memory_order_relaxed);
    });
    if (handle.id == 0) fatal("addOnPerfPingListener", "returned zero id");

    std::atomic<bool> start{false};
    std::vector<std::thread> workers;
    workers.reserve(static_cast<size_t>(threads));
    for (int t = 0; t < threads; ++t) {
        workers.emplace_back([&] {
            while (!start.load(std::memory_order_acquire)) {}
            for (int64_t i = 0; i < perThread; ++i) {
                const int64_t stampNs =
                    std::chrono::duration_cast<std::chrono::nanoseconds>(
                        sclock::now().time_since_epoch())
                        .count();
                auto r = ctx->trigger_ping(
                    TriggerPingRequest{1, payloadBytes, stampNs});
                if (r.isErr()) fatal("triggerPing", r.error());
                if (r.value().emitted != 1)
                    fatal("triggerPing", "emitted != 1");
            }
        });
    }

    const auto t0 = sclock::now();
    start.store(true, std::memory_order_release);
    for (auto& w : workers) w.join();

    // Drain: the run is over only when every event reached the listener.
    const auto deadline = sclock::now() + std::chrono::seconds(60);
    while (delivered.load(std::memory_order_acquire) < total) {
        if (sclock::now() > deadline)
            fatal("event drain", "timeout waiting for event delivery");
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    const auto t1 = sclock::now();

    ctx->removeEventListener(handle);
    if (delivered.load() != total)
        fatal("event correctness", "delivered != emitted");

    IterOut out;
    {
        std::lock_guard<std::mutex> g(latMu);
        out.latNs = std::move(latencies);
    }
    const double sec = std::chrono::duration<double>(t1 - t0).count();
    out.msgPerSec = static_cast<double>(total) / sec;
    return out;
}

// ---------------------------------------------------------------------------
// Sweep driver — one compact table per (lane, family) with a row per thread
// count: median msg/s over iters, latency percentiles pooled across iters.
// ---------------------------------------------------------------------------

struct Knobs {
    std::vector<int> threadCounts;
    int perThread = 0;
    int iters = 0;
};

static void runScenario(const std::string& name, const std::string& csvTag,
                        const Knobs& k, int bytesPerMsg,
                        const std::function<IterOut(int threads)>& fn) {
    std::printf("── %s — %d msgs/thread (median of %d) ──────\n", name.c_str(),
                k.perThread, k.iters);
    std::printf("  %-9s%-11s%-13s%-11s%-12s%-12s%s\n", "threads", "msgs", "msg/s",
                "MB/s", "p50", "p99", "vs first row");
    double base = 0.0;
    for (int threads : k.threadCounts) {
        std::vector<double> rates;
        std::vector<int64_t> lat;
        for (int i = 0; i < k.iters; ++i) {
            IterOut out = fn(threads);
            rates.push_back(out.msgPerSec);
            lat.insert(lat.end(), out.latNs.begin(), out.latNs.end());
        }
        const double med = median(rates);
        if (base == 0.0) base = med;

        std::sort(lat.begin(), lat.end());
        const int64_t p50 = percentile(lat, 50);
        const int64_t p99 = percentile(lat, 99);
        char mbs[32], p50Buf[32], p99Buf[32];
        if (bytesPerMsg > 0)
            std::snprintf(mbs, sizeof(mbs), "%.2f",
                          med * static_cast<double>(bytesPerMsg) / 1e6);
        else
            std::snprintf(mbs, sizeof(mbs), "-");
        if (lat.empty()) {
            std::snprintf(p50Buf, sizeof(p50Buf), "-");
            std::snprintf(p99Buf, sizeof(p99Buf), "-");
        } else {
            fmtNs(p50Buf, sizeof(p50Buf), p50);
            fmtNs(p99Buf, sizeof(p99Buf), p99);
        }
        std::printf("  %-9d%-11llu%-13.0f%-11s%-12s%-12s%s\n", threads,
                    static_cast<unsigned long long>(
                        static_cast<uint64_t>(threads) *
                        static_cast<uint64_t>(k.perThread)),
                    med, mbs, p50Buf, p99Buf,
                    (std::to_string(med / base).substr(0, 4) + "x").c_str());
        // CSV row: tag,threads,msg/s,p50_ns,p99_ns — diff-friendly capture.
        // Lanes without per-call samples emit -1, distinguishing "not
        // measured" from a measured 0 ns.
        std::printf("csv,perf_ffi,%s,%d,%.0f,%" PRId64 ",%" PRId64 "\n",
                    csvTag.c_str(), threads, med, lat.empty() ? int64_t{-1} : p50,
                    lat.empty() ? int64_t{-1} : p99);
        std::fflush(stdout);
    }
    std::printf("\n");
}

int main() {
    Knobs k;
    k.threadCounts = envIntList("NIM_FFI_PERF_THREADS", "1,2,4,8");
    k.perThread = envInt("NIM_FFI_PERF_PER_THREAD", 2000);
    k.iters = envInt("NIM_FFI_PERF_ITERS", 3);
    const std::vector<int> payloadSizes =
        envIntList("NIM_FFI_PERF_PAYLOAD_SIZES", "64,512,4096,65536");
    const int eventPayload = envInt("NIM_FFI_PERF_EVENT_PAYLOAD", 512);
    const int window = envInt("NIM_FFI_PERF_ASYNC_WINDOW", 64);
    // Element-level validation: a negative size would wrap to a huge size_t
    // in makePayload, and a 0 thread count (also what atoi turns garbage
    // into) would produce empty runs and nonsense scaling ratios.
    bool listsOk = !k.threadCounts.empty() && !payloadSizes.empty();
    for (int t : k.threadCounts)
        if (t < 1) listsOk = false;
    for (int s : payloadSizes)
        if (s < 0) listsOk = false;
    if (k.perThread < 1 || k.iters < 1 || window < 1 || eventPayload < 0 ||
        !listsOk) {
        std::fprintf(stderr, "invalid NIM_FFI_PERF_* configuration\n");
        return 2;
    }

    std::printf("# perfbench FFI e2e — shared O(1) parity predicate; setups "
                "differ only in transport (scalars vs N-byte payload)\n\n");

    // ── scalar family ────────────────────────────────────────────────────────
    runScenario("sync C++ -> Nim -> C++ (blocking round trip) [scalar]",
                "sync,scalar,0", k, 0, [&](int threads) {
                    return runSync(threads, k.perThread, [](PerfbenchCtx& ctx,
                                                           int64_t i) {
                        auto r = ctx.scalar_check(
                            ScalarCheckRequest{scalarA(i), scalarB(i), scalarX(i)});
                        if (r.isErr()) fatal("scalarCheck", r.error());
                        if (r.value().ok != scalarPred(i))
                            fatal("sync scalar correctness", "predicate mismatch");
                    });
                });

    runScenario("async C++ -> Nim -> C++ (future turnaround) [scalar]",
                "async,scalar,0", k, 0, [&](int threads) {
                    return runAsync(
                        threads, k.perThread, window,
                        [](PerfbenchCtx& ctx, int64_t i) {
                            return ctx.scalar_checkAsync(ScalarCheckRequest{
                                scalarA(i), scalarB(i), scalarX(i)});
                        },
                        [](int64_t i) { return scalarPred(i); });
                });

    // ── payload family, size sweep ───────────────────────────────────────────
    for (int size : payloadSizes) {
        const auto payload = makePayload(size);
        const bool expected = payloadPredOf(payload);
        const std::string tag = "[" + std::to_string(size) + "B payload]";

        runScenario("sync C++ -> Nim -> C++ (blocking round trip) " + tag,
                    "sync,payload," + std::to_string(size), k, size,
                    [&](int threads) {
                        return runSync(threads, k.perThread,
                                       [&](PerfbenchCtx& ctx, int64_t) {
                                           auto r = ctx.payload_check(
                                               PayloadCheckRequest{payload});
                                           if (r.isErr())
                                               fatal("payloadCheck", r.error());
                                           if (r.value().ok != expected)
                                               fatal("sync payload correctness",
                                                     "predicate mismatch");
                                       });
                    });

        runScenario("async C++ -> Nim -> C++ (future turnaround) " + tag,
                    "async,payload," + std::to_string(size), k, size,
                    [&](int threads) {
                        return runAsync(
                            threads, k.perThread, window,
                            [&](PerfbenchCtx& ctx, int64_t) {
                                return ctx.payload_checkAsync(
                                    PayloadCheckRequest{payload});
                            },
                            [&](int64_t) { return expected; });
                    });
    }

    // ── event lane ───────────────────────────────────────────────────────────
    runScenario("event C++ -> Nim -> C++ (on_perf_ping delivery) [" +
                    std::to_string(eventPayload) + "B payload]",
                "event,payload," + std::to_string(eventPayload), k, eventPayload,
                [&](int threads) {
                    return runEvent(threads, k.perThread, eventPayload);
                });

    std::printf("  correctness: all counts and predicates matched expectations.\n");
    return 0;
}
