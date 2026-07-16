# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed
- **`abi = c` non-scalar procs no longer marshal through CBOR.** The foreign
  surface is unchanged — the generated headers and exported symbols are
  byte-identical — but the hop between the caller and the FFI thread now carries
  the packed `_CWire` struct itself instead of CBOR-encoding it and decoding it
  back. A request is packed into a `malloc`'d owned copy on the calling thread
  and unpacked (then freed) on the FFI thread; an object reply rides back as its
  `_CWire` image and a `string` reply as raw UTF-8, so the round trip through
  `cborEncodeShared`/`cborDecodePtr` is gone from both directions. Only the
  scalar fast path was CBOR-free before
  ([#131](https://github.com/logos-messaging/nim-ffi/issues/131)).
- `_CWire` seq/Option payload buffers are allocated with libc `malloc`
  (`cwireAllocBuf`) rather than `allocShared`, so a wire packed on the calling
  thread can be freed on the FFI thread — the cross-thread ownership the
  CBOR-free request path relies on, and consistent with the libc-backed request
  envelope.
- The generated C `<lib>_ctx_destroy()` now returns `int` instead of `void`,
  propagating the exported `<lib>_destroy()` status code (`NIMFFI_RET_OK` on
  success, `RET_ERR` on a null/invalid context or a failed context teardown)
  instead of discarding it, so a host can observe a failed teardown. Existing
  callers that invoke it as a statement are unaffected
  ([#133](https://github.com/logos-messaging/nim-ffi/issues/133)).
- A failed `<lib>_ctx_destroy()` no longer frees the event-listener boxes. A
  non-`NIMFFI_RET_OK` teardown leaves the worker threads live, and they still
  hold each box as callback `user_data`; the boxes are now leaked rather than
  freed out from under a running event thread. The context struct and the
  listener array are still freed unconditionally.
- User event callbacks now run on a dedicated event thread fed by a
  bounded SPSC queue (default capacity 1024), so a slow listener can no
  longer block the FFI thread or concurrent `add_event_listener` /
  `remove_event_listener` calls
  ([#6](https://github.com/logos-messaging/nim-ffi/issues/6)).
- Replaced the dedicated watchdog thread with a heartbeat check that
  runs on the event thread. The FFI thread advances an atomic heartbeat
  each loop iteration; if it stalls for more than 1s past the start-up
  grace window, the event thread emits the `not_responding` event.
- `declareLibrary` no longer emits the shared-library `soname` /
  `install_name` linker flags when building as an executable (`--app:lib`
  guard), so FFI code can be unit-tested as a plain binary — fatal on macOS,
  where `-install_name` requires `-dynamiclib`.

### Added
- **`{.ffiStatic.}`**: exports a context-independent proc. It takes no library
  param and its wrapper takes no `ctx`, so a host can call a stateless utility
  (key generation, parsing, a version string) without constructing the library
  ([#134](https://github.com/logos-messaging/nim-ffi/issues/134)). Wired for both
  the `cbor` and `c` ABIs across all four backends: the C header emits
  `<lib>_static_<proc>(...)`, while C++ and Rust emit an associated function on
  the ctx type taking the `timeout` a method reads from its ctx. Handlers run on
  the library's *static context*, created on the first such call and alive for the
  rest of the process, so that call starts a thread pair that is never torn down.
  An `{.ffiHandle.}` parameter or return is rejected at macro time: a handle
  belongs to the context that created it, which a static proc cannot reach.
- `{.ffi.}` now accepts an `enum` type, emitting a native enum in every target
  (C `enum`, C++ `enum class`, Rust enum, CDDL string choice). Values cross the
  wire as the text `$value` yields — the associated string if declared, else the
  symbol name — matching what `cbor_serialization` writes. Enums are supported
  on the CBOR wire only; reaching one from an `abi = c` type or proc is now a
  compile error naming the type, where it previously registered as a
  fieldless struct and silently dropped the value.
- `{.ffiConst.}` exposes a Nim `const` to every generated binding as a native
  constant (`static const` in C, `constexpr` in C++, `pub const` in Rust).
  Integer, float, `bool` and `string` values are supported, computed
  expressions arrive folded, and names are re-cased to `UPPER_SNAKE`.
- `{.ffiEvent.}` no longer requires an explicit wire-name string: when omitted
  it is derived from the proc name via `camelToSnakeCase`
  (`onPeerConnected` → `on_peer_connected`), matching how `{.ffi.}` derives its
  C export symbol. Pass a string literal only to override it.
- Doc comments (`##`) on `{.ffi.}` / `{.ffiCtor.}` / `{.ffiDtor.}` procs are now
  propagated to the generated bindings — `/** ... */` on the C declarations,
  `///` on the C++ class methods and Rust `pub fn`s, and `;` comments in the
  CDDL schema — so the exported API is documented once, in the Nim source
  ([#127](https://github.com/logos-messaging/nim-ffi/issues/127)). Editing a
  `##` comment now changes the generated bindings, so `nimble check_bindings`
  flags them stale until regenerated; an undocumented proc still generates
  byte-identical output.
- FFI annotations (`{.ffi.}`, `{.ffiStatic.}`, `{.ffiCtor.}`, `{.ffiDtor.}`,
  `{.ffiEvent.}`, `{.ffiHandle.}`, `{.ffiRaw.}`) that expand after `genBindings()` now produce a
  loud compile error instead of being silently dropped from the generated
  bindings.
- **C binding generator** (`-d:targetLang=c`): emits a header-only C binding
  (`<lib>.h`) plus a `CMakeLists.txt`, alongside the existing Rust / C++ / CDDL
  backends. Requests/responses travel as CBOR using the same vendored TinyCBOR
  the C++ backend uses. C has no generics or overloading, so each `seq[T]` /
  `Option[T]` is monomorphised into its own struct + encode/decode/free triple.
  The high-level `<lib>_ctx_*` API is asynchronous: each method/constructor
  takes a typed result callback and the binding owns and reclaims all reply
  data and error strings (valid only for the duration of the callback), so the
  caller never frees anything — there is no blocking wait and no manual-free
  contract. Shared codegen helpers were extracted
  into `ffi/codegen/common.nim` (used by both the C and C++ backends). New
  `nimble genbindings_c` / `genbindings_c_echo` / `check_bindings_c` /
  `test_c_e2e` tasks, a `tests/e2e/c` ctest harness, and a
  `tests/unit/test_c_codegen.nim` unit suite.
- Non-terminal `RET_STALE_WARN` (3) progress callback in place of a handler
  timeout: nim-ffi never times a handler out (a hard-cancel mid-call into the
  underlying library can leave it half-applied). Instead, while a request is
  still in flight its result callback receives a `RET_STALE_WARN` every 5s
  (Android's ANR interval; override with `-d:ffiStaleWarnIntervalMs=<ms>`), with
  the payload carrying the elapsed milliseconds as a decimal string. The request
  always ends with exactly one terminal `RET_OK` / `RET_ERR`; the dev decides
  what to do with a slow one. Replaces the never-released per-proc
  `{.ffi: "timeout = <ms>".}` override and the `defaultRequestTimeout` context
  field ([#126](https://github.com/logos-messaging/nim-ffi/issues/126),
  supersedes [#93](https://github.com/logos-messaging/nim-ffi/issues/93)).
- Per-interaction ABI-format annotations: `declareLibrary` now takes an
  optional `defaultABIFormat` (`"cbor"` default, or `"c"`) that every
  `{.ffi.}` / `{.ffiCtor.}` / `{.ffiDtor.}` / `{.ffiRaw.}` / `{.ffiEvent.}`
  inherits, and each annotation can override it with an `"abi = c"` /
  `"abi = cbor"` spec (e.g. `{.ffi: "abi = cbor".}`). `declareLibrary` is now
  required before any FFI annotation
  ([#78](https://github.com/logos-messaging/nim-ffi/issues/78)).
- `c` (`abi = c` C-struct) ABI **codec**: every `{.ffi: "abi = c".}` type gets a
  `<T>_CWire` companion plus `cwirePack` / `cwireUnpack` / `cwireFree`. This
  first slice covers the `abi = c` path — POD scalars and `string` (as `cstring`);
  composite fields follow. (`c` events remain CBOR-only.)
- **CBOR-free (`abi = c`) C bindings, emitted by the single `c` target**
  (`-d:targetLang=c`): the one `c` generator now picks its output from the
  library's ABI format — the `abi = c` header or the CBOR header. The `abi = c`
  header is a single self-contained `<lib>.h` whose `_CWire` structs *are* the C
  ABI, so the C consumer passes native structs and links no CBOR at all. The `c`
  proc-dispatch path is wired end-to-end: the generated exported wrappers
  `cwireUnpack` the request into a Nim object, reuse the existing CBOR thread
  transport internally, and a Nim reply trampoline `cwirePack`s the response
  back into a `_CWire` struct for the caller's typed callback.
  `abiCodegenImplemented` accepts `c` for proc/ctor/dtor annotations (events
  remain CBOR-only). New `examples/echo/c_abi_bindings/` (checked in beside the
  CBOR `c_bindings/` for comparison), `nimble genbindings_c_abi_echo` /
  `check_bindings_c_abi` / `test_c_abi_e2e` / `test_c_abi_e2e_sanitized`
  tasks, and a `tests/e2e/c_abi` ctest harness
  ([#105](https://github.com/logos-messaging/nim-ffi/issues/105)).
- `tests/bench/bench_codec.nim` (+ `nimble bench_codec`): a single-process
  microbenchmark comparing the `cbor` and `c` codecs across payload shapes,
  isolating codec cost from the (identical) thread/callback round-trip.
- Queue-overflow handling: when the bounded event queue is full, the
  library sets a sticky "stuck" flag, logs an error, fires
  `not_responding` from the event thread, and rejects subsequent
  `sendRequestToFFIThread` calls with `event queue stuck - library
  cannot accept new requests`.

## [0.2.0] - 2026-06-04

Major release introducing the CBOR-based wire format, CBOR-backed FFI events
with a multi-listener registry, multi-language binding generation (C++, Rust,
CDDL), CI hardening with sanitizers, and several robustness fixes around
context lifetime and memory safety.

### Added
- **CBOR serialization** as the FFI wire format, replacing the previous
  JSON/string-based `serial.nim`
  ([#23](https://github.com/logos-messaging/nim-ffi/pull/23)).
- **CBOR-backed FFI events**: event payloads are now serialized with CBOR
  ([#39](https://github.com/logos-messaging/nim-ffi/pull/39)).
- **Multi-listener event registry** (`FFIEventRegistry`) and its wiring into
  `FFIContext`
  ([#45](https://github.com/logos-messaging/nim-ffi/pull/45),
  [#49](https://github.com/logos-messaging/nim-ffi/pull/49)).
- **Event-listener ABI** with per-event typed listeners
  ([#50](https://github.com/logos-messaging/nim-ffi/pull/50)).
- **C++ typed per-event listeners** in the generated bindings
  ([#51](https://github.com/logos-messaging/nim-ffi/pull/51)).
- **Rust per-event typed listeners** (`add_on_<x>_listener` + wildcard
  `add_event_listener`)
  ([#52](https://github.com/logos-messaging/nim-ffi/pull/52)) and Rust event
  example bindings/clients
  ([#53](https://github.com/logos-messaging/nim-ffi/pull/53)).
- **C++ binding generator** with end-to-end tests driven by CMake/CTest
  ([#27](https://github.com/logos-messaging/nim-ffi/pull/27)), later expanded
  with multi-context, cross-library, pipeline, and stress tests
  ([#42](https://github.com/logos-messaging/nim-ffi/pull/42)).
- **CDDL schema generator** for the FFI types
  ([#24](https://github.com/logos-messaging/nim-ffi/pull/24)).
- **CI pipeline**: parallel test execution
  ([#26](https://github.com/logos-messaging/nim-ffi/pull/26)),
  AddressSanitizer / UndefinedBehaviorSanitizer / ThreadSanitizer jobs
  ([#34](https://github.com/logos-messaging/nim-ffi/pull/34)), and a
  cross-platform OS matrix for the C++ e2e suite
  ([#38](https://github.com/logos-messaging/nim-ffi/pull/38)).
- CBOR type-coverage tests
  ([#41](https://github.com/logos-messaging/nim-ffi/pull/41)).

### Changed
- Removed the redundant `ffiType` macro; the `ffi` macro is now the single
  authoring entry point
  ([#22](https://github.com/logos-messaging/nim-ffi/pull/22)).
- Generated C++ avoids move constructors and assignment operators
  ([#36](https://github.com/logos-messaging/nim-ffi/pull/36)) and no longer
  throws exceptions across the binding boundary
  ([#46](https://github.com/logos-messaging/nim-ffi/pull/46)).
- Removed the wildcard event listener; event dispatch is now strictly
  per-event ([#70](https://github.com/logos-messaging/nim-ffi/pull/70)).

### Fixed
- Use-after-free in the event/context lifetime path
  ([#47](https://github.com/logos-messaging/nim-ffi/pull/47)).

## [0.1.4] - 2026-05-13

[Full changelog](https://github.com/logos-messaging/nim-ffi/compare/v0.1.3...v0.1.4)

### Added

- Simplified FFI authoring with auto-generated C++ and Rust language bindings,
  including new `ffi/codegen/cpp.nim`, `ffi/codegen/rust.nim` and shared
  `ffi/codegen/meta.nim` helpers (#15).
- Rust example bindings and clients under `examples/nim_timer/` (`rust_bindings`
  and `rust_client`, the latter with a Tokio async variant) (#15).
- JSON/string-based FFI (de)serialization via `ffi/serial.nim`
  (`ffiSerialize`/`ffiDeserialize`), with `tests/test_serial.nim` coverage.
  (CBOR replaced this layer later, in 0.2.0.)
- FFI context pool (`ffi/ffi_context_pool.nim`) using a fixed array of contexts.
- Test suite expansion: `test_alloc.nim`, `test_ctx_validation.nim`,
  `test_ffi_context.nim`, `test_gc_compat.nim`.
- Continuous integration pipeline (#12).

### Fixed

- Context buffer overflow (#21).
- Use a fixed array of contexts to avoid consuming all file descriptors (#14).
- Memory leaks (#11).
- Add `install_name` for macOS shared libraries (#8).

### Changed

- Run tests with the `refc` garbage collector (#20).
- Remove `CatchableError` usage (#19).
- Update license files to comply with Logos licensing requirements.

## [0.1.3] - 2026-01-23

### Fixed
- Properly import and re-export `chronicles` so downstream packages get the
  logging macros transitively.

## [0.1.2] - 2026-01-23

### Fixed
- Re-export `chronicles` and `std/tables` when the `ffi` module is imported,
  so generated code resolves these symbols at the call site.

## [0.1.1] - 2026-01-23

Initial tagged release.

### Added
- Core `ffi` macro for declaring procs exposed across the FFI boundary.
- `FFIContext` with a dedicated worker thread, request dispatch, and a
  watchdog with configurable timeout
  ([#7](https://github.com/logos-messaging/nim-ffi/pull/7)).
- License files updated to comply with Logos licensing requirements.
