# Rust Bindings for nim-timer

## Purpose

This folder contains **auto-generated Rust bindings** (the `my_timer` crate) for the `my_timer` Nim library. It is generated from `../timer.nim` and provides:

- `src/lib.rs`: Main library exposing high-level Rust types and the `MyTimerCtx` API
- `src/api.rs`: High-level async/sync wrapper around the FFI. One pump thread per context takes the messages out with `my_timer_poll`: a reply goes to the call that waits for it (every request has a blocking method and an `_async` one), and everything else the library sends (events, stale warnings, liveness, closed) is listed by `MyTimerMessage` and runs the `add_*_listener` handlers. A listener may make a blocking call, but must not block on an `_async` one
- `src/ffi.rs`: Raw `extern "C"` declarations for the Nim library, `NimFfiMsg` included
- `src/types.rs`: Serializable Rust types matching the Nim FFI types
- `build.rs`: Build script that compiles the Nim library to `libmy_timer.dylib` (or `.so`/`.dll`)
- `Cargo.toml`: Package manifest with serde and serde_json dependencies

## How It's Generated

Generate or regenerate these bindings by running from the repository root:

```sh
nimble genbindings_rust
```

This command:
1. Invokes the Nim compiler with `-d:targetLang:rust` flag
2. Triggers `genBindings("examples/timer/rust_bindings", "../timer.nim")` in `timer.nim`
3. Creates/updates the generated binding files

## Using as a Dependency

A consumer depends on the crate by path:

```toml
[dependencies]
my_timer = { path = "../rust_bindings" }
```

The four clients under `examples/` are cargo examples of this crate, and they are hand-written: `nimble genbindings_rust` does not touch that directory. CI compiles them with `cargo build --locked --examples`, which is the only thing that type-checks the generated `api.rs` surface.

## Do Not Edit

The generated files in this folder are overwritten each time `nimble genbindings_rust` runs. Any manual changes will be lost.
