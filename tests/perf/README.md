# C++ e2e perf harness

Measures the full foreign round trip — C++ driver → generated `perfbench.hpp`
wrapper (CBOR encode) → `libperfbench` C ABI → FFI thread → Nim handler → back
to C++ — across payload shapes, call lanes and thread counts. The nim-ffi
analog of nim-brokers' `test/ffibench` (`bench_e2e_driver.cpp` /
`perf_driver.cpp`), using the same O(1) parity predicate so the tables compare
directly.

Timing is a measurement, not a gate: the harness is not part of `nimble test`.
It still exits non-zero on any correctness failure — every reply is verified
against the driver-side predicate, and every fired event must be delivered.

## Running

```sh
nimble perf_cpp_e2e
```

Builds `tests/perf/benchlib/perfbench.nim` as a shared library with
`-d:danger` (matching the `tests/bench` methodology) for each mm in the
`NIM_FFI_MM` matrix (empty = orc + refc), regenerates the C++ bindings, builds
the driver Release via CMake, and runs it. The generated
`nim_ffi_lib.cmake` template is deliberately **not** used to build the lib —
it produces a debug orc build, which would make the numbers meaningless.

## What is measured

Every handler computes the same O(1) parity predicate
`((a + b + int64(x)) and 1) == 0`, so setups differ purely in **transport**
cost (encode / copy / decode / thread crossing), never in handler work:

| Setup | Wire shape | Lane |
| --- | --- | --- |
| scalar | 2 × `int64` + 1 × `float64` in, `bool` out | sync + async |
| payload N B | `seq[byte]` of N in, `bool` out; predicate reads (first, last, len) only | sync + async |
| event | sync trigger fires one `on_perf_ping` event of N B | delivery-latency |

- **sync** — blocking round trips; per-call latency sampled (p50/p99).
- **async** — `*Async` future turnaround with a bounded in-flight window per
  thread (`NIM_FFI_PERF_ASYNC_WINDOW`); throughput only.
- **event** — the listener computes delivery latency from a driver-side
  `steady_clock` stamp passed through the Nim provider verbatim, so the delta
  stays inside one clock domain.

Each table row is one thread count: median msg/s over `NIM_FFI_PERF_ITERS`
runs, latency percentiles pooled across runs, plus a `csv,perf_ffi,...` line
per row for diff-friendly capture.

## Env knobs

| Knob | Default | Meaning |
| --- | --- | --- |
| `NIM_FFI_MM` | both | `orc` / `refc` — mm matrix for the Nim lib build |
| `NIM_FFI_PERF_THREADS` | `1,2,4,8` | driver thread counts swept |
| `NIM_FFI_PERF_PER_THREAD` | `2000` | round trips per thread per run |
| `NIM_FFI_PERF_ITERS` | `3` | runs per row, median reported |
| `NIM_FFI_PERF_PAYLOAD_SIZES` | `64,512,4096,65536` | payload family sizes (bytes) |
| `NIM_FFI_PERF_EVENT_PAYLOAD` | `512` | event payload size (bytes) |
| `NIM_FFI_PERF_ASYNC_WINDOW` | `64` | in-flight futures per thread, async lane |
