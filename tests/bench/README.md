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
