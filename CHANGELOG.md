# Changelog

All notable changes to this project are documented in this file.

## [0.2.0] - 2026-05-20

Major release introducing CBOR-based wire format, multi-language binding
generation (C++, Rust, CDDL), CI hardening with sanitizers, and several
robustness fixes around context lifetime and memory safety.

### Added
- **CBOR serialization** as the FFI wire format ([#23](https://github.com/waku-org/nim-ffi/pull/23)).
- **C++ binding generator** with end-to-end tests driven by CMake/CTest
  ([#27](https://github.com/waku-org/nim-ffi/pull/27)).
- **CDDL schema generator** for the FFI types
  ([#24](https://github.com/waku-org/nim-ffi/pull/24)).
- **CI pipeline**: first GitHub Actions workflow
  parallel test
  execution ([#26](https://github.com/waku-org/nim-ffi/pull/26)), and
  AddressSanitizer / UndefinedBehaviorSanitizer / ThreadSanitizer jobs
  ([#34](https://github.com/waku-org/nim-ffi/pull/34)).

### Changed
- Removed the redundant `ffiType` macro; the `ffi` macro is now the single
  authoring entry point
  ([#22](https://github.com/waku-org/nim-ffi/pull/22)).

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
  ([#7](https://github.com/waku-org/nim-ffi/pull/7)).
- License files updated to comply with Logos licensing requirements.
