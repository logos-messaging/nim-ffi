# nim-ffi
Allows exposing Nim projects to other languages

## Examples

- `examples/timer` — the canonical example covering all three target paths.
- `examples/echoer` — a second Nim library used by the cross-library e2e
  test to prove that two independent nim-ffi libraries can co-exist in one
  process and exchange data through the pure-C ABI.

## Target languages

Pick a target via `-d:targetLang=...` at compile time. Each target has its
own generated wrapper directory and its own runtime contract:

| target | when to use it                      | wire format       |
|--------|-------------------------------------|-------------------|
| `c`    | in-process linking (host + library in the same address space) | flat C structs, no serialisation |
| `cpp`  | inter-process / inter-language consumers that already speak C++ | CBOR              |
| `rust` | inter-process / inter-language consumers in Rust            | CBOR              |

Inter-process callers should pick `cpp` or `rust` because their wire format
(CBOR) is portable and stable across compilers/platforms. In-process
callers should pick `c` because the CBOR step is pure overhead when both
sides share memory.

## Quick start — pure-C target

```bash
# From the repo root: build the example library + regenerate the header.
nim c --mm:orc --app:lib --noMain --nimMainPrefix:libmy_timer \
      -d:targetLang=c -d:ffiGenBindings \
      -d:ffiOutputDir=examples/timer/c_bindings \
      -d:ffiNimSrcRelPath=../timer.nim \
      -o:libmy_timer.dylib examples/timer/timer.nim

# Build a C consumer (the smoke at examples/timer/c_bindings/main.c works):
cmake -S tests/e2e/c -B tests/e2e/c/build && cmake --build tests/e2e/c/build
ctest --test-dir tests/e2e/c/build --output-on-failure
```

## Test suites

| command                   | what it runs                                  |
|---------------------------|-----------------------------------------------|
| `nimble test`             | Nim unit tests under both `--mm:orc` and `--mm:refc` |
| `nimble test_cpp_e2e`     | C++ end-to-end (CBOR target) against the timer lib  |
| `nimble test_c_e2e`       | C end-to-end (pure-C target): single-library smoke + cross-library scenario |

The cross-library e2e (`tests/e2e/c/cross_lib_e2e`) builds both
`libmy_timer` and `libechoer`, threads a string from one through the
other using only their respective C headers, and asserts the round-trip
result. This is the canonical demonstration of "two Nim-FFI libraries
talking through the C ABI only".

## Per-library quick example (legacy)

`examples/timer` is a self-contained Nimble project that imports `nim-ffi`
directly. Use `cd examples/timer && nimble install -y ../.. && nimble build`
to compile the example.
