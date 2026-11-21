# timer example

This example is a self-contained Nimble project demonstrating how to import `nim-ffi` and use the `.ffiCtor.` / `.ffi.` abstraction.

## Usage

1. Change into the example directory:
   ```sh
   cd examples/timer
   ```

2. Install the local `ffi` dependency:
   ```sh
   nimble install -y ../..
   ```

3. Build the example library:
   ```sh
   nimble build
   ```

4. Generate bindings, from the repository root:
   ```sh
   nimble genbindings_rust
   nimble genbindings_cpp
   ```

## Rust example clients

The Rust clients are cargo examples of the generated crate, in `examples/timer/rust_bindings/examples`. `sync_main` and `tokio_main` cover the typed event listeners; `sync_client` and `tokio_client` cover the constants and the multi-parameter `schedule` call.

```sh
cd examples/timer/rust_bindings
cargo run --example sync_main     # sync, event listeners
cargo run --example tokio_main    # async, event listeners
cargo run --example sync_client   # sync, schedule + consts
cargo run --example tokio_client  # async, schedule + consts
```

## C++ example

The generated C++ example lives in `examples/timer/cpp_bindings`.

Build and run it with:
```sh
cd examples/timer/cpp_bindings
cmake -S . -B build
cmake --build build
./build/example
```

### The same example for the poll model

`examples/timer/cpp_poll_bindings/main.cpp` is that program for the poll model, step for step, so the two can be compared. The library is the same source: the bindings are generated with `-d:ffiPollMode`, and the generated `CMakeLists.txt` builds the library the same way.

```sh
nimble run_examples_poll
```

The calls and events read the same. What differs: there are no `...Async` variants (a call serves the library's queue while it waits), events arrive on whichever thread serves the queue, the library's reverse calls are answered through a typed `Responder`, and something has to serve the queue between calls (`poll()` or `runLoop()`).
