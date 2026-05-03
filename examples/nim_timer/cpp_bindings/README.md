# C++ Bindings for nim-timer

## Purpose

This folder contains **auto-generated C++ bindings** for the `nim_timer` Nim library. It is generated from `../nim_timer.nim` and provides:

- `nimtimer.hpp`: High-level C++ class (`NimTimerCtx`) wrapping the FFI interface
- `main.cpp`: Example executable demonstrating how to use the bindings
- `CMakeLists.txt`: Build configuration that compiles the Nim library and links the C++ example

## How It's Generated

Generate or regenerate these bindings by running from the parent directory:

```sh
cd examples/nim_timer
nimble genbindings_cpp
```

This command:
1. Invokes the Nim compiler with `-d:targetLang:cpp` flag
2. Triggers `genBindings("examples/nim_timer/cpp_bindings", "../nim_timer.nim")` in `nim_timer.nim`
3. Creates/updates the generated binding files

## Building the Example

```sh
cd examples/nim_timer/cpp_bindings
cmake -S . -B build
cmake --build build
./build/example
```

## Do Not Edit

The generated files in this folder are overwritten each time `nimble genbindings_cpp` runs. Any manual changes will be lost.
