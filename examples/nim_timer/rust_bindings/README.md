# Rust Bindings for nim-timer

## Purpose

This folder contains **auto-generated Rust bindings** (the `nimtimer` crate) for the `nim_timer` Nim library. It is generated from `../nim_timer.nim` and provides:

- `src/lib.rs`: Main library exposing high-level Rust types and the `NimTimerCtx` API
- `src/api.rs`: High-level async/sync wrapper around the FFI
- `src/ffi.rs`: Raw `extern "C"` declarations for the Nim library
- `src/types.rs`: Serializable Rust types matching the Nim FFI types
- `build.rs`: Build script that compiles the Nim library to `libnimtimer.dylib` (or `.so`/`.dll`)
- `Cargo.toml`: Package manifest with serde and serde_json dependencies

## How It's Generated

Generate or regenerate these bindings by running from the parent directory:

```sh
cd examples/nim_timer
nimble genbindings_rust
```

This command:
1. Invokes the Nim compiler with `-d:targetLang:rust` flag
2. Triggers `genBindings("examples/nim_timer/rust_bindings", "../nim_timer.nim")` in `nim_timer.nim`
3. Creates/updates the generated binding files

## Using as a Dependency

The `rust_client` example consumes this crate:

```toml
[dependencies]
nimtimer = { path = "../rust_bindings" }
```

## Do Not Edit

The generated files in this folder are overwritten each time `nimble genbindings_rust` runs. Any manual changes will be lost.
