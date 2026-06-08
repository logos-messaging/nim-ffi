# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed
- User event callbacks now run on a dedicated event thread fed by a
  bounded SPSC queue (default capacity 1024), so a slow listener can no
  longer block the FFI thread or concurrent `add_event_listener` /
  `remove_event_listener` calls
  ([#6](https://github.com/logos-messaging/nim-ffi/issues/6)).
- Replaced the dedicated watchdog thread with a heartbeat check that
  runs on the event thread. The FFI thread advances an atomic heartbeat
  each loop iteration; if it stalls for more than 1s past the start-up
  grace window, the event thread emits the `not_responding` event.
- Removed the redundant `ffiType` macro; the `ffi` macro is now the single
  authoring entry point
  ([#22](https://github.com/logos-messaging/nim-ffi/pull/22)).
- Generated C++ avoids move constructors and assignment operators
  ([#36](https://github.com/logos-messaging/nim-ffi/pull/36)) and no longer
  throws exceptions across the binding boundary
  ([#46](https://github.com/logos-messaging/nim-ffi/pull/46)).
- Removed the wildcard event listener; event dispatch is now strictly
  per-event ([#70](https://github.com/logos-messaging/nim-ffi/pull/70)).

### Added
- Queue-overflow handling: when the bounded event queue is full, the
  library sets a sticky "stuck" flag, logs an error, fires
  `not_responding` from the event thread, and rejects subsequent
  `sendRequestToFFIThread` calls with `event queue stuck - library
  cannot accept new requests`.
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
# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed
- User event callbacks now run on a dedicated event thread fed by a
  bounded SPSC queue (default capacity 1024), so a slow listener can no
  longer block the FFI thread or concurrent `add_event_listener` /
  `remove_event_listener` calls
  ([#6](https://github.com/logos-messaging/nim-ffi/issues/6)).
- Replaced the dedicated watchdog thread with a heartbeat check that
  runs on the event thread. The FFI thread advances an atomic heartbeat
  each loop iteration; if it stalls for more than 1s past the start-up
  grace window, the event thread emits the `not_responding` event.
- Removed the redundant `ffiType` macro; the `ffi` macro is now the single
  authoring entry point
  ([#22](https://github.com/logos-messaging/nim-ffi/pull/22)).
- Generated C++ avoids move constructors and assignment operators
  ([#36](https://github.com/logos-messaging/nim-ffi/pull/36)) and no longer
  throws exceptions across the binding boundary
  ([#46](https://github.com/logos-messaging/nim-ffi/pull/46)).
- Removed the wildcard event listener; event dispatch is now strictly
  per-event ([#70](https://github.com/logos-messaging/nim-ffi/pull/70)).

### Added
- Queue-overflow handling: when the bounded event queue is full, the
  library sets a sticky "stuck" flag, logs an error, fires
  `not_responding` from the event thread, and rejects subsequent
  `sendRequestToFFIThread` calls with `event queue stuck - library
  cannot accept new requests`.
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

### Fixed
- Use-after-free in the event/context lifetime path
  ([#47](https://github.com/logos-messaging/nim-ffi/pull/47)).

## [0.1.5] - 2026-06-08

[Full changelog](https://github.com/logos-messaging/nim-ffi/compare/v0.1.4...v0.1.5)

### Fixed

- Recycle FFI contexts in the pool instead of tearing them down per cycle,
  stopping a per-cycle file-descriptor leak (#74).

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
# Changelog

## [0.1.5] - 2026-06-08

[Full changelog](https://github.com/logos-messaging/nim-ffi/compare/v0.1.4...v0.1.5)

### Fixed

- Recycle FFI contexts in the pool instead of tearing them down per cycle,
  stopping a per-cycle file-descriptor leak (#74).

## [0.1.4] - 2026-06-02

[Full changelog](https://github.com/logos-messaging/nim-ffi/compare/v0.1.3...v0.1.4)

### Added

- Simplified FFI authoring with auto-generated C++ and Rust language bindings,
  including new `ffi/codegen/cpp.nim`, `ffi/codegen/rust.nim` and shared
  `ffi/codegen/meta.nim` helpers (#15).
- Rust example bindings and clients under `examples/nim_timer/` (`rust_bindings`
  and `rust_client`, the latter with a Tokio async variant) (#15).
- CBOR serialization support via `ffi/serial.nim`, with `tests/test_serial.nim`
  coverage.
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
