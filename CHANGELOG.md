# Changelog

All notable changes to this project are documented in this file.

## [0.2.0] - 2026-05-20

Major release introducing CBOR-based wire format, multi-language binding
generation (C++, Rust, CDDL), CI hardening with sanitizers, and several
robustness fixes around context lifetime and memory safety.

### Added
- **CBOR serialization** as the FFI wire format ([#23](https://github.com/waku-org/nim-ffi/pull/23)).
- **C++ binding generator** with end-to-end tests driven by CMake/CTest
  ([#15](https://github.com/waku-org/nim-ffi/pull/15),
  [#27](https://github.com/waku-org/nim-ffi/pull/27)).
- **Rust binding generator** for simplified FFI authoring
  ([#15](https://github.com/waku-org/nim-ffi/pull/15)).
- **CDDL schema generator** for the FFI types
  ([#24](https://github.com/waku-org/nim-ffi/pull/24)).
- **CI pipeline**: first GitHub Actions workflow
  ([#12](https://github.com/waku-org/nim-ffi/pull/12)), parallel test
  execution ([#26](https://github.com/waku-org/nim-ffi/pull/26)), and
  AddressSanitizer / UndefinedBehaviorSanitizer / ThreadSanitizer jobs
  ([#34](https://github.com/waku-org/nim-ffi/pull/34)).
- Tests run under both `--mm:orc` and `--mm:refc`
  ([#20](https://github.com/waku-org/nim-ffi/pull/20)).

### Changed
- FFI contexts now use a **fixed-size array** instead of dynamically allocated
  slots, so creating many contexts no longer exhausts file descriptors
  ([#14](https://github.com/waku-org/nim-ffi/pull/14)).
- Removed the redundant `ffiType` macro; the `ffi` macro is now the single
  authoring entry point
  ([#22](https://github.com/waku-org/nim-ffi/pull/22)).
- Dropped `CatchableError` usage in favour of more specific exception types
  ([#19](https://github.com/waku-org/nim-ffi/pull/19)).

### Fixed
- Context buffer overflow when handling large payloads
  ([#21](https://github.com/waku-org/nim-ffi/pull/21)).
- Several memory leaks in request dispatch, context creation/destruction,
  and `handleRes` under ARC/ORC; tightened lock initialization and resource
  cleanup ([#11](https://github.com/waku-org/nim-ffi/pull/11)).
- macOS dylibs are now built with a relocatable `install_name` instead of
  hard-coded paths ([#8](https://github.com/waku-org/nim-ffi/pull/8)).

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
