# Changelog

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
