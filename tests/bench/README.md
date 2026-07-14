# FFI benchmarks

This directory holds Nim micro/stress benchmarks. Neither is part of `nimble test`.

- `bench_codec.nim` — `cbor` vs `c` (cwire) wire-format codec microbenchmark (documented below). Pure measurement, not a gate.
- `bench_ffi_submit.nim` — concurrent-submit stress test + throughput benchmark for `sendRequestToFFIThread` (documented next). Carries a **scaling gate** that fails CI until the per-request submit lock is replaced.

## `sendRequestToFFIThread` concurrent-submit stress / throughput

`bench_ffi_submit.nim` motivates [issue #90](https://github.com/logos-messaging/nim-ffi/issues/90): every foreign-thread call serialises the whole `trySend + reqSignal.fireSync + reqReceivedSignal.waitSync` cycle under a single `ctx.lock`. The lock is load-bearing because `reqChannel` is single-slot and the accept handshake waits on a *shared* `reqReceivedSignal`, so producers cannot overlap.

The bench fans **K producer threads** at one context (default sweep `1,2,4,8`), each firing the same per-thread volume of no-op requests. It times the **submit phase only** — from the start gate until every producer returns from its last `sendRequestToFFIThread` — because that is the path the fix parallelises; completion is bounded by the single FFI thread and deliberately excluded. Each thread count runs `FFI_SUBMIT_ITERS` times (default 5) and the **median** submit/sec is reported, so run-to-run noise can't move the verdict.

The high-contention curve (up to 100 producers) is **opt-in for local runs**, not CI: under a sanitizer on a slow runner, 100 threads can't settle their callbacks within the bench's timeout and would fail on time, not on a bug. Run it on demand with `FFI_SUBMIT_THREADS`:

```sh
FFI_SUBMIT_THREADS="1,8,16,32,64,100" nimble bench_ffi_submit
```

It is also a correctness stress test: the aggregate callback count must match the submit count **exactly** (no drops or double-fires), with zero submit errors and (under asan/lsan/tsan) zero leaks or races.

```sh
nimble bench_ffi_submit
# smaller / faster (handy under sanitizers — they distort timing, so disable the gate):
FFI_SUBMIT_PER_THREAD=2000 FFI_SUBMIT_ITERS=1 FFI_SCALING_GATE=0 nimble bench_ffi_submit
# under a sanitizer (proves no leaks/races; gate off — see below):
NIM_FFI_SAN=tsan FFI_SUBMIT_PER_THREAD=2000 FFI_SCALING_GATE=0 nimble bench_ffi_submit
```

Env knobs: `FFI_SUBMIT_PER_THREAD` (volume per producer, default 20000), `FFI_SUBMIT_ITERS` (median sample count, default 5), `FFI_SUBMIT_THREADS` (comma-separated producer counts, default `1,2,4,8`), `FFI_SCALING_GATE` (default `1`; set `0` to report numbers without failing).

### Scaling gate — guards the sharded ingress against regression

By default the bench **fails** (non-zero exit) unless submit throughput at the top thread count is at least `1.5x` the 1-thread rate. This was a forcing function while `sendRequestToFFIThread` still held `ctx.lock` across the synchronous `reqReceivedSignal` accept (which serialised every submit); it is now a regression guard for the sharded ingress that replaced it.

The original lock-bound code measured 2026-06-24 (16-core Linux, orc, `-d:danger`, median of 5): submit scaling held flat at **0.98–1.16x** — adding producers bought nothing. `1.5x` sits above that noise ceiling so the old code fails reliably, and well below what the sharded ingress delivers, so the fix clears it with wide margin.

The fix replaces the single-slot channel + accept handshake with a **sharded, mutex-guarded MPSC ingress** (`ffi/ffi_request_queue.nim`): independent per-producer queues remove the single shared hotspot, and the wake fires only on a queue's empty→non-empty edge so submits don't each pay a syscall. Measured 2026-06-25 (Apple M5, 10 cores, orc, `-d:danger`, median of 5), submit/sec and scaling vs 1 thread:

| threads | sharded ingress | vs 1T | lock-free MPSC (Vyukov) | vs 1T |
| ---: | ---: | :---: | ---: | :---: |
| 1   | 2.14M | 1.00x | 1.18M | 1.00x |
| 8   | 17.6M | 8.22x | 0.23M | 0.20x |
| 16  | 20.3M | 9.52x | 0.13M | 0.11x |
| 32  | 23.4M | 10.96x | 0.115M | 0.10x |
| 64  | 24.5M | 11.44x | 0.113M | 0.10x |
| 100 | 23.8M | **11.13x** | 0.113M | **0.10x** |

The sharded ingress tracks the hardware ceiling (~24M/s plateau, saturating the cores) and degrades gracefully past it; the single-hotspot lock-free queue collapses to a contention floor and gets *worse* with more threads. Both are correct at every level (callback count matches submits exactly, no drops/dupes).

The gate runs in the non-sanitized **Submit Scaling Gate** CI job (`.github/workflows/ci.yml`); the sanitized jobs run the same bench with `FFI_SCALING_GATE=0` for leak/race coverage only, since sanitizer instrumentation makes throughput scaling meaningless.

# FFI wire-format codec benchmark

`bench_codec.nim` is a single-process Nim microbenchmark comparing the two FFI
wire-format codecs head-to-head on identical payloads:

- **cbor** — `cborEncode` / `cborDecode`, self-describing bytes over
  `seq[byte]`. The codec the `cbor` ABI uses on every boundary crossing.
- **c (cwire)** — `cwirePack` / `cwireUnpack` / `cwireFree`, `abi = c` C-struct
  shared-memory packing. The codec the `c` ABI uses, emitted for every
  `{.ffi: "abi = c".}` type as its `<T>_CWire` companion.

Both paths run in the same process on the same values, so the numbers isolate
**codec cost only** — no thread hop, no callback dispatch, no chronos work. The
full FFI round-trip (thread channel + callback) is identical for both ABIs, so
the codec is where the ABI difference actually lives.

## Running

```sh
nimble bench_codec
# or directly, with the size sweep extended to 1 MiB:
nim c -r --mm:orc -d:danger tests/bench/bench_codec.nim --include-1mib
```

Build with `-d:danger` (the nimble task does) so the figures reflect optimized
codegen rather than a debug build.

## Payload shapes covered

| Type             | Shape                                              |
|------------------|----------------------------------------------------|
| `EchoRequest`    | 1 string + 1 int (small struct)                    |
| `EchoResponse`   | 2 strings                                          |
| `ComplexRequest` | `seq[EchoRequest]`, `seq[string]`, `Option[...]`   |
| `BytesPayload`   | `seq[byte]`, swept 100 B → 150 KiB (`--include-1mib` adds 1 MiB) |

## Interpreting

Small structs are dominated by CBOR's per-field tag/length framing, so cwire
wins by a large factor. As payloads grow into big `seq[byte]` blobs, both codecs
become `memcpy`-bound and the ratio converges toward ~1×. The byte-blob sweep
also reports throughput (MiB/s) for each codec.

> Note: this benchmark exercises the `c` ABI **codec** (the cwire companions on
> the Nim side). Wiring the `c` ABI through the full proc-dispatch path and the
> foreign (C++/Rust) generators is tracked separately; only `cbor` currently
> generates working end-to-end bindings.
