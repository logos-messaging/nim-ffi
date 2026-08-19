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

4. Generate bindings:
   ```sh
   nimble genbindings_rust
   nimble genbindings_cpp
   ```

## Rust example clients

The Rust clients are cargo examples of the generated crate, in `examples/timer/rust_bindings/examples`. `main` and `tokio_main` cover the typed event listeners; `client` and `tokio_client` cover the constants and the multi-parameter `schedule` call.

```sh
cd examples/timer/rust_bindings
cargo run --example main          # sync, event listeners
cargo run --example tokio_main    # async, event listeners
cargo run --example client        # sync, schedule + consts
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
