#!/usr/bin/env bash
# Run both e2e benchmarks back-to-back and emit a side-by-side comparison.
#
# Each bench prints CSV `op,mode,ns_per_op,iters`. We join on `op`, compute
# the cbor/raw ratio, and print a small table at the end. The CSV is also
# preserved under `bench-results.csv` for downstream processing.
#
# Usage: tests/bench/run_bench.sh [version_iters] [echo_iters] [complex_iters] [sched_iters]
set -euo pipefail

cd "$(dirname "$0")/../.."

VER_ITERS="${1:-5000}"
ECHO_ITERS="${2:-2000}"
CPX_ITERS="${3:-2000}"
SCHED_ITERS="${4:-2000}"

echo "── Building cbor-mode bench ──────────────────────────────────────"
cmake -S tests/bench/cpp_cbor -B tests/bench/cpp_cbor/build >/dev/null
cmake --build tests/bench/cpp_cbor/build --target bench_timer_cbor >/dev/null

echo "── Building raw-mode bench ───────────────────────────────────────"
cmake -S tests/bench/c_raw -B tests/bench/c_raw/build >/dev/null
cmake --build tests/bench/c_raw/build --target bench_timer_raw >/dev/null

OUT=tests/bench/bench-results.csv
echo "op,mode,ns_per_op,iters" >"$OUT"

echo "── Running cbor bench ────────────────────────────────────────────"
tests/bench/cpp_cbor/build/bench_timer_cbor "$VER_ITERS" "$ECHO_ITERS" "$CPX_ITERS" "$SCHED_ITERS" \
    | tail -n +2 >>"$OUT"

echo "── Running raw bench  ────────────────────────────────────────────"
tests/bench/c_raw/build/bench_timer_raw "$VER_ITERS" "$ECHO_ITERS" "$CPX_ITERS" "$SCHED_ITERS" \
    | tail -n +2 >>"$OUT"

echo ""
echo "── Comparison (lower is better) ──────────────────────────────────"
# Custom sort: top-level ops first in a canonical order, then bytes_echo
# rows sorted by byte size (100B < 1KiB < 10KiB < 64KiB < 150KiB) so the
# size sweep reads top-down.
awk -F, '
    function rank(op,    n) {
        if (op == "version_sync")   return 1
        if (op == "echo_0ms")       return 2
        if (op == "complex_small")  return 3
        if (op == "schedule_3objs") return 4
        if (op ~ /^bytes_echo_/) {
            n = substr(op, length("bytes_echo_") + 1)
            if (n ~ /KiB$/) return 100 + (n + 0)              # 100 + KiB (check first — "KiB" also ends in "B")
            if (n ~ /B$/)   return 10 + (n + 0) / 1024.0      # bytes
            return 999
        }
        return 500
    }
    {
        ops[$1] = 1
        ns[$1,$2] = $3
    }
    END {
        printf "%-18s %12s %12s %10s\n", "op", "cbor (ns)", "raw (ns)", "cbor/raw"
        printf "%-18s %12s %12s %10s\n", "------------------", "------------", "------------", "----------"
        n = 0
        for (op in ops) {
            sorted[++n] = op
        }
        # Simple insertion sort on rank() — list is small.
        for (i = 2; i <= n; ++i) {
            key = sorted[i]; j = i - 1
            while (j >= 1 && rank(sorted[j]) > rank(key)) {
                sorted[j + 1] = sorted[j]; j--
            }
            sorted[j + 1] = key
        }
        for (i = 1; i <= n; ++i) {
            op = sorted[i]
            if ((op,"cbor") in ns && (op,"raw") in ns) {
                ratio = ns[op,"cbor"] / ns[op,"raw"]
                printf "%-18s %12.2f %12.2f %9.2fx\n", op, ns[op,"cbor"], ns[op,"raw"], ratio
            }
        }
    }
' "$OUT"

echo ""
echo "Raw CSV saved to: $OUT"
