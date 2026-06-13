# nim-ffi — future work

Ideas for making nim-ffi a best-in-class FFI solution for exposing Nim to any
platform. Captured from design discussion; not yet scheduled unless linked to a
branch/PR.

## Foundation: the dual-proc design

A `{.ffi.}` / `{.ffiCtor.}` / `{.ffiDtor.}` proc compiles into **two** procs that
share the source name:

1. a normal, fully-typed Nim proc (the user's body) — callable in-process with
   zero serialization, and unit-testable without any FFI; and
2. an `{.exportc, cdecl, dynlib.}` wrapper with the `(ctx, cb, ud, …)` ABI that
   foreign callers bind.

Nim disambiguates by overload resolution (see `ffi/internal/ffi_macro.nim`, the
note at the `cExportProcName` definition). Most items below build on this: the
same source can serve an in-process Nim caller and a foreign caller over the C
ABI, choosing the transport per call site.

## Roadmap (priority order)

### 1. Typed bidirectional calls — host-provided functions the Nim side can `await`  ⬅ in progress
Today data flows lib → host as events (raw/CBOR). The inverse is missing: a Nim
`{.ffi.}` proc calling **back into** the host language for typed data and
awaiting the result — the "a lower layer needs to read from a higher one" case
(logos-delivery issue #3865). A `{.ffiHost.}`-style annotation turns a
bodyless typed Nim proc into a call that marshals to a host-registered function
pointer and resolves a chronos `Future` when the host calls back. Reuses the
event machinery (registry + `ThreadSignalPtr` bridging into chronos). This is
the feature that changes what people can *build* with nim-ffi.

### 2. Richer error model than `string`
`Result[T, string]` crosses today. Allow `Result[T, E]` where `E` is a typed
`{.ffi.}` struct, so every language surfaces structured errors (codes, fields)
instead of parsing text. Small change to the macro's return handling.

### 3. Streaming / multi-shot results
A proc that yields *many* values (an `AsyncStream`) mapping to host-native
iterators: Kotlin `Flow`, Swift `AsyncSequence`, Rust `Stream`, JS async
iterators. Turns nim-ffi from RPC into a reactive core.

### 4. ABI self-descriptor symbol
Export `<lib>_abi_descriptor()` returning the schema (CBOR/JSON) so a host can
validate compatibility at load time. Addresses the deferred CBOR wire-versioning
concern.

## Cross-cutting decisions

- **ABI format selection** ([design-abi-format.md](design-abi-format.md)) — per-proc
  pragma arg `{.ffi: raw.}` / `{.ffi: cbor.}` (default native/`raw`), with a
  library-wide `declareLibrary(defaultAbiFormat = …)` override. Global compile
  flag discarded. Applies to `{.ffiHost.}` too. Direction decided, design only.

## Adjacent / parallel tracks (already discussed elsewhere)

- **seq/Option + multi-struct param marshaling parity** for the Swift (#59) and
  Kotlin (#60) generators — `go.nim` is the reference (it already does this).
- **Typed events on Swift/Kotlin** — the JNI-thread-attach-into-JVM case for
  Kotlin is the hard part.
- **Async idiom mapping** — `Future[T]` → Promise / `async`/`await` / `suspend`
  / `impl Future`, so callers `await` instead of blocking on a semaphore.
- **WASM Component Model (WIT) emitter** — emit a `.wit` so any host consumes the
  interface without bespoke glue.
