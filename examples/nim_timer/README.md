# nim_timer example

This example is a self-contained Nimble project demonstrating how to import `nim-ffi` and use the `.ffiCtor.` / `.ffi.` abstraction.

## Usage

1. Change into the example directory:
   ```sh
   cd examples/nim_timer
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

The Rust client lives in `examples/nim_timer/rust_client`.

- Run the sync example:
  ```sh
  cd examples/nim_timer/rust_client
  cargo run --bin rust_client
  ```

- Run the Tokio example:
  ```sh
  cd examples/nim_timer/rust_client
  cargo run --bin tokio_client
  ```

## C++ example

The generated C++ example lives in `examples/nim_timer/cpp_bindings`.

Build and run it with:
```sh
cd examples/nim_timer/cpp_bindings
cmake -S . -B build
cmake --build build
./build/example
```
