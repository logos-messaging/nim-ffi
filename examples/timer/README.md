# timer example

This example is a self-contained Nimble project demonstrating how to import `nim-ffi` and use the `.ffiCtor.` / `.ffi.` abstraction.

## Two ABIs, one library

Every generated library exports **two ABIs side by side**, and you choose per call site:

| ABI | Header / symbols | Use it for |
|-----|------------------|------------|
| **Native (pure C)** | `<lib>.h` / `<name>` | **Same-process / local** calls. Flat C structs by value, zero serialization. |
| **CBOR** | `<lib>_cbor.h` / `<name>_cbor` | **Inter-process communication only** — a different process or machine, where the request must be serialized to cross the boundary. |

In a shared address space the CBOR round-trip is pure overhead, so **default to the native ABI locally and reach for CBOR only when you actually cross a process/machine boundary** (see [`ipc/`](ipc)). The per-language examples below: native C ([`c_bindings/`](c_bindings)), native Go ([`go_bindings/`](go_bindings)), native/CBOR C++ ([`cpp_bindings/`](cpp_bindings)), CBOR Rust ([`rust_client/`](rust_client)), and CBOR-over-socket IPC ([`ipc/`](ipc)).

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

The Rust client lives in `examples/timer/rust_client`.

- Run the sync example:
  ```sh
  cd examples/timer/rust_client
  cargo run --bin rust_client
  ```

- Run the Tokio example:
  ```sh
  cd examples/timer/rust_client
  cargo run --bin tokio_client
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
