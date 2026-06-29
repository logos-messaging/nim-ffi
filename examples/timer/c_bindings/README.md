# C Bindings for nim-timer

## Purpose

This folder contains **auto-generated C bindings** for the `my_timer` Nim
library. It is generated from `../timer.nim` and provides:

- `my_timer.h`: header-only C binding (`MyTimerCtx` + `my_timer_ctx_*` API)
- `main.c`: example executable demonstrating how to use the bindings
- `CMakeLists.txt`: build configuration that compiles the Nim library, the
  vendored TinyCBOR, and the C example

The bindings speak CBOR on the wire (the same format as the Rust and C++
backends) using the TinyCBOR copy vendored at
`ffi/codegen/templates/cpp/vendor/tinycbor`.

## How It's Generated

Regenerate these bindings by running from the parent directory:

```sh
cd examples/timer
nimble genbindings_c
```

This invokes the Nim compiler with `-d:targetLang=c`, triggering
`genBindings(...)` in `timer.nim`, which reads the compile-time FFI registries
and emits the binding files.

## Building the Example

```sh
cd examples/timer/c_bindings
cmake -S . -B build
cmake --build build
./build/my_timer_example
```

## Memory Ownership

- Request-side strings/sequences are *borrowed* — wrap C strings with
  `nimffi_str(...)`; the binding never frees them.
- Response values returned through an out-parameter are *owned* by the caller;
  release them with the generated `my_timer_free_<Type>()` helper.
- Error strings handed back through a `char** err` are heap-allocated; release
  them with `free()`.

## Do Not Edit

The generated files in this folder are overwritten each time
`nimble genbindings_c` runs. Any manual changes will be lost.
