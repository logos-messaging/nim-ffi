# FFI benchmarks

This directory holds Nim micro/stress benchmarks. Neither is part of `nimble test`.

- `bench_codec.nim` — `cbor` vs `c` (cwire) wire-format codec microbenchmark (documented below). Pure measurement, not a gate.
- `bench_ffi_submit.nim` — concurrent-submit stress test + throughput benchmark for `sendRequestToFFIThread` (documented next). Carries a **scaling gate** that fails CI until the per-request submit lock is replaced.

## `sendRequestToFFIThread` concurrent-submit stress / throughput

`bench_ffi_submit.nim` motivates
[issue #90](https://github.com/logos-messaging/nim-ffi/issues/90): every
foreign-thread call serialises the whole `trySend + reqSignal.fireSync +
reqReceivedSignal.waitSync` cycle under a single `ctx.lock`. The lock is
load-bearing because `reqChannel` is single-slot and the accept handshake waits
on a *shared* `reqReceivedSignal`, so producers cannot overlap.

The bench fans **K producer threads (1 → 8)** at one context, each firing the same per-thread volume of no-op requests. It times the **submit phase only** — from the start gate until every producer returns from its last `sendRequestToFFIThread` — because that is the path the fix parallelises; completion is bounded by the single FFI thread and deliberately excluded. Each thread count runs `FFI_SUBMIT_ITERS` times (default 5) and the **median** submit/sec is reported, so run-to-run noise can't move the verdict.

It is also a correctness stress test: the aggregate callback count must match the submit count **exactly** (no drops or double-fires), with zero submit errors and (under asan/lsan/tsan) zero leaks or races.

```sh
nimble bench_ffi_submit
# smaller / faster (handy under sanitizers — they distort timing, so disable the gate):
FFI_SUBMIT_PER_THREAD=2000 FFI_SUBMIT_ITERS=1 FFI_SCALING_GATE=0 nimble bench_ffi_submit
# under a sanitizer (proves no leaks/races; gate off — see below):
NIM_FFI_SAN=tsan FFI_SUBMIT_PER_THREAD=2000 FFI_SCALING_GATE=0 nimble bench_ffi_submit
```

Env knobs: `FFI_SUBMIT_PER_THREAD` (volume per producer, default 20000), `FFI_SUBMIT_ITERS` (median sample count, default 5), `FFI_SCALING_GATE` (default `1`; set `0` to report numbers without failing).

### Scaling gate — red until the lock is replaced

By default the bench **fails** (non-zero exit) unless submit throughput at 8 threads is at least `1.5x` the 1-thread rate. This is a forcing function: it cannot pass while `sendRequestToFFIThread` holds `ctx.lock` across the synchronous `reqReceivedSignal` accept, because that serialises every submit no matter how many producers run.

Baseline measured 2026-06-24 (16-core Linux, orc, `-d:danger`, median of 5): submit scaling held at **0.98–1.16x** across threads — flat, as the lock dictates. `1.5x` sits above that noise ceiling (so the lock-bound code fails reliably) and well below the `>=2x` that parallel lock-free MPSC ingress yields on any multicore host (so the fix clears it with margin). Once it lands and this turns green, keep the gate as a regression guard.

The gate runs in the non-sanitized **Submit Scaling Gate** CI job (`.github/workflows/ci.yml`); the sanitized jobs run the same bench with `FFI_SCALING_GATE=0` for leak/race coverage only, since sanitizer instrumentation makes throughput scaling meaningless.

# FFI wire-format codec benchmark

`bench_codec.nim` is a single-process Nim microbenchmark comparing the two FFI
wire-format codecs head-to-head on identical payloads:

- **cbor** — `cborEncode` / `cborDecode`, self-describing bytes over
  `seq[byte]`. The codec the `cbor` ABI uses on every boundary crossing.
- **c (cwire)** — `cwirePack` / `cwireUnpack` / `cwireFree`, flat C-struct
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
