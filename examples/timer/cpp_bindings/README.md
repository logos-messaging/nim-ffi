# C++ Bindings for nim-timer

## Purpose

This folder contains **auto-generated C++ bindings** for the `my_timer` Nim library. It is generated from `../timer.nim` (with the default `both` ABI mode) and provides:

- `my_timer_cbor.hpp`: High-level C++ class (`MyTimerCtx`) wrapping the **CBOR** FFI interface (inter-process)
- `my_timer.hpp` + `my_timer.h`: the **native** (zero-serialization, same-process) wrapper and the C ABI it builds on
- `main.cpp`: Example executable demonstrating how to use the CBOR bindings
- `CMakeLists.txt`: Build configuration that compiles the Nim library and links the C++ example

The native header is the bare `my_timer.hpp` and the CBOR header carries the `_cbor` suffix — the same convention as the C bindings (`my_timer.h` / `my_timer_cbor.h`) and the underlying symbols (`<name>` / `<name>_cbor`).

## How It's Generated

Generate or regenerate these bindings by running from the parent directory:

```sh
cd examples/timer
nimble genbindings_cpp
```

This command:
1. Invokes the Nim compiler with `-d:targetLang:cpp` flag
2. Triggers `genBindings("examples/timer/cpp_bindings", "../timer.nim")` in `timer.nim`
3. Creates/updates the generated binding files

## Building the Example

```sh
cd examples/timer/cpp_bindings
cmake -S . -B build
cmake --build build
./build/example
```

## Do Not Edit

The generated files in this folder are overwritten each time `nimble genbindings_cpp` runs. Any manual changes will be lost.
