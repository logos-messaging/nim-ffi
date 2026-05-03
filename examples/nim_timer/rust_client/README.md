# Rust Client Examples

## Purpose

This folder contains **example Rust applications** that demonstrate how to use the auto-generated `nimtimer` crate (from `../rust_bindings`).

## What's Included

Two executable examples:

- **`rust_client`** — Synchronous example
  - Shows basic synchronous calls to the Nim timer API
  - Uses blocking wait with condition variables
  - Source: `src/main.rs`

- **`tokio_client`** — Asynchronous example with Tokio runtime
  - Demonstrates the Tokio async runtime integration
  - Uses `spawn_blocking` to handle the blocking FFI callbacks on a separate thread pool
  - Source: `src/tokio_main.rs`

## Building

```sh
cd examples/nim_timer/rust_client
cargo build
```

## Running

```sh
# Sync example
cargo run --bin rust_client

# Tokio async example
cargo run --bin tokio_client
```

## Important Notes

- The `nimtimer` crate is a **local dependency** (`path = "../rust_bindings"`)
- It is **auto-generated** — do not manually edit it
- These examples are **not** part of the generated output; they are hand-written to show usage patterns
- To regenerate the `nimtimer` crate, run `nimble genbindings_rust` from the parent directory
