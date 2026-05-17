# C++ end-to-end tests

These tests validate that a Nim FFI library exported with `nim-ffi`'s C++
codegen is usable from a real C++ consumer. They drive the `my_timer` example
through its auto-generated `my_timer.hpp` bindings (constructor, sync method,
async methods, complex types with optional fields, multiple contexts) and
assert the round-tripped values.

## Layout

The suite reuses the generated bindings instead of duplicating the Nim build
glue:

- `CMakeLists.txt` — `add_subdirectory`s `examples/timer/cpp_bindings`, which
  compiles `libmy_timer` and exposes the `my_timer_headers` INTERFACE target.
  Fetches GoogleTest and registers tests with CTest via `gtest_discover_tests`.
- `test_timer_e2e.cpp` — the test cases.

## Running

```sh
# 1. Generate the C++ bindings (writes examples/timer/cpp_bindings/)
nimble genbindings_cpp_cbor

# 2. Configure + build + run the tests
cmake -S tests/e2e/cpp -B tests/e2e/cpp/build
cmake --build tests/e2e/cpp/build
ctest --test-dir tests/e2e/cpp/build --output-on-failure
```
