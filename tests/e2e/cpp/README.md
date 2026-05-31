# C++ end-to-end tests

These tests validate that a Nim FFI library exported with `nim-ffi`'s C++
codegen is usable from a real C++ consumer. They drive the `my_timer` example
through its auto-generated `my_timer_cbor.hpp` bindings (constructor, sync method,
async methods, complex types with optional fields, multiple contexts, error
propagation, async pipelines, short-lived-thread stress, concurrent hammer)
and assert the round-tripped values. The `CrossLibrary` test additionally
loads `examples/echo`'s `echo_cbor.hpp` alongside the timer to prove two
independent nim-ffi libraries coexist in one process with no symbol clash
and no shared global state.

## Layout

The suite reuses the generated bindings instead of duplicating the Nim build
glue:

- `CMakeLists.txt` — `add_subdirectory`s both
  `examples/timer/cpp_bindings` (compiles `libmy_timer`, exposes
  `my_timer_headers`) and `examples/echo/cpp_bindings` (compiles
  `libecho`, exposes `echo_headers`). Fetches GoogleTest and registers
  tests with CTest via `gtest_discover_tests`.
- `test_timer_e2e.cpp` — the test cases.

## Running

```sh
# 1. Generate the C++ bindings for both example libraries
nimble genbindings_cpp        # → examples/timer/cpp_bindings/
nimble genbindings_cpp_echo   # → examples/echo/cpp_bindings/

# 2. Configure + build + run the tests
cmake -S tests/e2e/cpp -B tests/e2e/cpp/build
cmake --build tests/e2e/cpp/build
ctest --test-dir tests/e2e/cpp/build --output-on-failure
```
