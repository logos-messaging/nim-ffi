# Rust end-to-end tests

End-to-end tests for the auto-generated Rust `my_timer` crate (from
`examples/timer/rust_bindings`), the Rust counterpart to `tests/e2e/c` and
`tests/e2e/cpp`.

They link the same `rust_bindings` crate the examples use — its `build.rs`
compiles the Nim shared library — and exercise the full FFI round-trip (CBOR
encode → Nim FFI thread → chronos → CBOR decode) over **both** generated call
surfaces:

- the **blocking** wrappers (`ctx.version()`, `ctx.echo(..)`, `ctx.schedule(..)`),
  which block on a condition variable until the reply lands, and
- the **tokio-async** wrappers (`ctx.version_async().await`, …), which wake the
  awaiting task from the FFI callback without blocking a runtime thread.

## Running

```sh
# From the repo root
nimble test_rust_e2e

# Or directly
cd tests/e2e/rust && cargo test
```

To regenerate the `rust_bindings` crate under test, run `nimble genbindings_rust`
from the repo root.
