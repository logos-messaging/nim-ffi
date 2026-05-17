# nim-ffi
Allows exposing Nim projects to other languages.

## Target matrix

Bindings are picked by two compile-time strdefines that together select
one cell of a 2×2 matrix:

```
-d:ffiMode={ raw | cbor }    # HOW data crosses the FFI boundary
-d:ffiLang={ cpp  | rust }    # WHICH language the consumer wrapper uses
```

|                    | **ffiLang=cpp**                          | **ffiLang=rust**                         |
|--------------------|------------------------------------------|-------------------------------------------|
| **ffiMode=cbor**   | C++ header using CBOR on the wire — works **both in-process and inter-process**, portable. *(ready)* | Rust crate using CBOR on the wire — works **both in-process and inter-process**, portable. *(ready)* |
| **ffiMode=raw**    | Flat C ABI header consumable by both C and C++ callers — **in-process only**, zero-copy-friendly. *(ready)* | Rust over the pure-C ABI — **in-process only**. *(not yet implemented)* |

### What each `ffiMode` value means

The mode chooses **how data crosses the FFI boundary**. **`cbor` works
in *both* deployment shapes** (in-process and inter-process); **`raw`
is in-process only**. Think of them as "always-works, with overhead"
vs "fast, but the consumer must share memory with the library":

- **`ffiMode=raw`** — **in-memory communication, no encode/decode**.
  The consumer is linked into *the same process* as the Nim library and
  shares its address space. The exported symbols take a `ptr <Req>` of a
  flat C struct; strings and arrays travel as raw pointers into shared
  memory. There is **no serialisation step on either side**. Cheapest
  path per call, but only viable when both sides share memory — pointers
  in the wire structs are real virtual addresses in the calling process,
  meaningless across a process boundary. Pick this for in-process
  linking when payloads are large or frequent: the ~10–50× lower
  per-call cost vs CBOR pays off above ~10 KiB payloads or ~500 calls/s.

  To prevent silent layout drift between library and consumer versions,
  the exported C symbols are **content-addressed** (`my_timer_echo_v4d2cf2b`):
  the suffix is an FNV-1a hash of the canonical signature, so any
  parameter / return / nested-type change produces a different symbol
  and stale consumers fail to link with a loud `undefined symbol`
  instead of corrupting memory. Consumer source keeps writing
  `my_timer_echo(...)` — a `#define` in the generated header expands to
  the hashed symbol at the consumer's own build time.

- **`ffiMode=cbor`** — **CBOR on the wire — works in-process *and*
  inter-process**. Payloads are encoded as self-describing CBOR bytes
  that survive any byte-oriented transport: Unix sockets and TCP for
  the inter-process case (different process, different host), or simply
  shared memory / direct function call when the consumer happens to live
  in the same process. **CBOR mode is the universal choice** — it works
  for every deployment shape `raw` works for, plus the ones `raw`
  can't reach. The trade-off vs `raw` is the encode/decode cost on every
  call (~0.5–1 ms per round-trip at 150 KiB payloads); the benefits are
  transport-flexibility *and* ABI tolerance — CBOR's self-describing
  wire format absorbs additive type changes by default, so consumer
  binaries built against an older library schema keep working when the
  library evolves.

  Concretely: if your consumer always runs in the same process as the
  library and per-call cost matters, prefer `raw`. If you might move
  the consumer to another process later, or you want one library
  release to keep working with older consumer binaries, prefer `cbor`
  — even in-process. The two modes are not "in-process vs inter-process";
  they are "fast-and-tight vs flexible-and-portable".

### What each `ffiLang` value means

The language chooses the **consumer-side wrapper** — the file(s)
emitted alongside the ABI to make calling the library idiomatic:

- **`ffiLang=cpp`** — emits a single `<lib>.hpp` (or `<lib>.h` when
  `ffiMode=raw`) under `<output>/`. The header is `extern "C"`-safe
  on the raw cell, so it works for both pure-C and C++ consumers.
  On the `cbor` cell it includes CBOR-encode/decode helpers, RAII
  context classes, and `std::future` overloads.

- **`ffiLang=rust`** — emits a complete Rust crate under `<output>/`:
  `Cargo.toml`, `build.rs`, `src/lib.rs`, `src/ffi.rs`, `src/types.rs`,
  `src/api.rs`. The crate uses `ciborium` for CBOR (on the `cbor`
  cell); a Rust-over-pure-C variant (`raw, rust`) is planned but not
  yet implemented.

The choice of `ffiLang` is independent of `ffiMode` — the same Nim-side
ABI is consumed identically regardless of whether the foreign wrapper
is written in C++ or Rust.

## Quick start

```bash
# Cell (cpp, raw) — in-memory, flat C ABI header, C/C++ consumer:
nim c --mm:orc --app:lib --noMain --nimMainPrefix:libmy_timer \
      -d:ffiGenBindings -d:ffiMode=raw -d:ffiLang=cpp \
      -d:ffiOutputDir=examples/timer/c_bindings \
      -d:ffiNimSrcRelPath=../timer.nim \
      -o:libmy_timer.dylib examples/timer/timer.nim

# Or use the nimble shortcuts:
nimble genbindings_cpp_rawc          # cell (cpp, raw)
nimble genbindings_cpp_cbor          # cell (cpp, cbor)
nimble genbindings_rust_cbor         # cell (rust, cbor)
```

## Examples

- [`examples/timer`](examples/timer/timer.nim) — canonical example covering
  every active cell of the matrix.
- [`examples/echoer`](examples/echoer/echoer.nim) — a second Nim library
  used by the cross-library e2e test.
- [`examples/aggregator`](examples/aggregator/aggregator.nim) — a stateful
  third Nim library (`ref object`) used by the stress scenarios.

## Test suites

| command               | what it runs                                                                |
|-----------------------|------------------------------------------------------------------------------|
| `nimble test`         | Nim unit tests under both `--mm:orc` and `--mm:refc`                         |
| `nimble test_cpp_e2e` | cell **(cpp, cbor)** end-to-end against the timer lib                        |
| `nimble test_c_e2e`   | cell **(cpp, raw)** end-to-end: smoke + cross-library + 4 stress scenarios  |

The cross-library e2e ([tests/e2e/c/cross_lib_e2e](tests/e2e/c/CMakeLists.txt))
builds both `libmy_timer` and `libechoer`, threads a string from one
through the other using only their respective C headers, and asserts the
round-trip result. This is the canonical demonstration of "two Nim-FFI
libraries talking through the pure-C ABI only".
