# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added
- The `abi = c` C header now declares the event-listener ABI that
  `declareLibrary` always exports (`<lib>_add_event_listener` /
  `<lib>_remove_event_listener`) and the `FFICallBack` typedef they take, so a
  consumer needs no hand-written header. The typed listener machinery for
  `{.ffiEvent.}` is still unsupported under `abi = c`.
- The `abi = c` C header is self-contained: it emits the `<stdint.h>` /
  `<stddef.h>` includes, the `NIMFFI_RET_*` status codes, and short
  `#ifndef`-guarded `RET_*` aliases for consumers that use the unprefixed names.
- Each `{.ffi.}` proc's `##` doc comment reaches the generated C header as a
  `/** ... */` block above the declaration and its wrapper.
- `declareLibrary` accepts the `ABIFormat` enum for `defaultABIFormat`, so
  `defaultABIFormat = ABIFormat.C` compiles alongside the `"c"` string.
- `declareLibrary` takes an optional `headerBanner` argument, stamped as a
  `//`-comment block at the top of every generated C header.
- `genBindings()` fails compilation when a library declares an `{.ffiCtor.}` but
  no `{.ffiDtor.}`, so the context a constructor builds always has a way to be
  released.
- `{.ffiEvent.}` now accepts multiple parameters. The macro synthesises and
  registers an envelope object (`<WireNamePascalCase>Payload`) whose fields are
  the parameters and dispatches an instance of it, so multi-field events no
  longer need a hand-written payload type. A single parameter still rides the
  wire directly (a scalar, or an existing `{.ffi.}` object). The foreign
  bindings gain the envelope as a first-class struct plus a typed handler.
- `{.ffiExport.}`, for simple synchronous C exports, from the 0.2 line. Each
  wrapper carries `raises: []` and catches every exception of the body, because
  an exception must not cross the C ABI. A return type with no C ABI mapping is
  a compile error. `int` maps to `long long`, so a 64-bit value keeps its full
  width. A `string` return rides in a buffer that belongs to the calling thread
  and stays valid until that thread calls another string export.
- Pooled FFI contexts are recycled instead of destroyed. Each slot builds its
  worker thread, its event thread and its signal fds once, then reuses them, so
  repeated create/destroy no longer churns fds past `FD_SETSIZE`. The `ffiDtor`
  asks the FFI thread to drain the in-flight handlers, free the library and
  return the slot, while the threads stay alive. A recycle also fails every
  request still queued for that slot, because such a request carries the
  `userData` of a host that is gone.
- `{.ffi.}` now picks the path from the shape of the signature. One pragma
  covers the context method, the static call, the synchronous export, the
  destructor and the event. `ffi/internal/ffi_route.nim` holds the rules:

  | Shape | Path |
  |---|---|
  | The first parameter is the library type or an `{.ffiHandle.}` type | Context method |
  | No receiver, and the result is `Future[Result[T, string]]` | Static call |
  | No parameters, and the result is a plain Nim type | Synchronous export |
  | A library receiver, and no result or `Future[void]` | Destructor |
  | A payload parameter, and no result | Event |

  Every shape that the router claims failed to compile under any other pragma
  before, so the router only turns a compile error into the intended meaning.

  `{.ffiStatic.}`, `{.ffiExport.}`, `{.ffiDtor.}` and `{.ffiEvent.}` still work.
  Each one now asserts its shape and names the right pragma when the shape does
  not match.

  `{.ffiCtor.}` stays explicit, because its shape is not free. A ctor differs
  from a static call by one token: the type inside `Result`. A static call that
  returns the library type builds today and exports a working C symbol, so a
  router would silently give it the ctor ABI instead.

### Changed
- **A submit now has two limits, and fails instead of accepting without bound.**
  The ingress queue took every request a producer offered, so a producer faster
  than the FFI thread — or any producer once that thread is wedged — grew memory
  without bound, and no request carried a maximum size. A submit is rejected once
  its ingress queue holds `-d:ffiRequestQueueDepth` (1024) requests, or once its
  payload passes `-d:ffiMaxRequestPayloadBytes` (8 MiB). Ingress is sharded over
  16 queues, so a context holds at most 16384 requests. The payload cap measures
  the buffer the request owns: on the `abi = c` path that is the packed wire
  struct, and the buffers its fields point at stay uncounted, because that path
  trusts its caller. Both limits come back as the error the submit already
  returns, which the generated entry points report as `RET_ERR` through the
  callback, so a host that stays under the limits sees no change. Raise either
  define if your host needs more.

### Fixed
- **A claim and the generation it opens are one atomic operation.** `tryClaim`
  set `inUse` and bumped `generation` in two steps, and between them a token of
  the previous owner passed both checks in `resolveCtx`: `inUse` was already
  true, and `generation` still held the value the token carried. The claim
  marker is now the parity of the generation itself, seqlock style: even is
  free, odd is claimed, and one CAS moves a slot from one to the other, so no
  token can observe a half-claimed slot. Bumping the generation first was not
  the answer: a claim that loses the race would then move the generation while
  the winner holds a token issued under the old value. `inUse` is gone, and
  `ctx.isInUse()` reads the parity.
- **A request carries the claim it was submitted under.** Every entry point
  resolved its token once and then enqueued with no second check, so a request
  that landed in the queue during the recycle window survived into the next
  claim, and the new library ran it and answered the callback of the old host.
  `FFIThreadRequest` gains a `generation` field that the entry point stamps from
  the resolved token. `sendRequestToFFIThread` rejects a stamp that no longer
  matches the live claim, and the FFI thread drops a dequeued request whose
  stamp does not match, without calling its callback: that callback carries
  `userData` the old host frees as soon as its recycle returns ok. A host that
  races a submit against its own recycle therefore loses that request silently,
  which is the safe side of the trade.
- **A losing `requestRecycle` can no longer swallow the drain failure of the
  winner.** The `recycleFailed` flag was cleared before the lifecycle CAS, so a
  concurrent caller could clear it between the moment the recycle handler set it
  and the moment the winner read it, and the winner then returned ok for a
  failed drain. A clear after the CAS races too, because the FFI thread polls
  and can finish the whole recycle in between. The flag is gone: the outcome now
  lives in the lifecycle state machine as the terminal `RecycleFailed`, which
  only the recycle handler writes and nothing clears. A later `requestRecycle`
  on such a slot gets the existing "not Active" error, which is the right answer
  for a wedged slot.
- **A recycled pool slot is reset before it serves the next owner.** The recycle
  handler computed whether its in-flight handlers had drained and then tore down
  regardless: it freed the library and returned the slot to the pool while
  handlers still ran, and each of those answers a callback carrying `userData`
  the host frees once teardown reports success. A drain that runs out of both
  rounds now aborts the recycle, so `requestRecycle` (and the generated
  `<lib>_destroy`) returns an error, the library stays alive and the slot stays
  claimed. A host that sees that error must keep the `userData` of its in-flight
  requests alive. The drain also counted the dispatcher rather than the handler,
  and the dispatcher unwound as soon as the cancel reached its `race`;
  `awaitWithStaleWarnings` now waits out the handler, which is never cancelled by
  design. The reset clears the handle registry as well: ids are monotonic from 1,
  so the next owner of a slot could pass id `1` and read an object of the
  previous one.
- A `{.ffi.}` constructor that failed after `createFFIContext` returned nil and
  left its slot claimed for the life of the process. Both ABI paths now recycle
  the slot before they return.
- The `abi = c` wrappers leaked their reply box on every send failure: `freeBox`
  runs only in the reply trampoline, which a rejected send never reaches. One
  trigger is sticky — once `eventQueueStuck` latches, every later call fails.
- Every `c_malloc` result in the runtime is checked. An out-of-memory condition
  used to become a nil dereference; it now becomes an error the host receives
  through its callback.
- A `{.ffiDtor.}` body now runs when the context is recycled. Only the
  thread-exit epilogue awaited the teardown hook, and the emitted C destructor
  never takes that path, so a dtor body was dead code and the library kept every
  loop it had spawned on the pooled worker. The recycle handler now awaits the
  hook between the drain and `freeLib`, once a constructor has stored a library.
  A body that overruns `-d:ffiTeardownTimeoutMs` (10 s) is cancelled, so keep the
  dtor cancellable; the slot is released on every exit path. Consumers shipping a
  non-empty dtor body should read it again: it is live now.
- A `{.ffi.}` call against a `ref` library type whose `{.ffiCtor.}` never stored
  a library (it failed, or none ran) no longer crashes. Without a constructed
  library the FFI thread points `myLib` at a default-valued fallback; for an
  `object` that is a usable zero value, but for a `ref` it is `nil`, so the user
  body faulted on its first field access. Such a request is now rejected with
  `library is not initialized: the constructor failed or has not run yet`
  through the callback. The check is emitted only for `ref` library types, and
  it runs on the FFI thread behind any queued constructor, so a host that issues
  a call without awaiting the create callback is unaffected.
- A listener callback that calls `<lib>_remove_event_listener` or
  `<lib>_add_event_listener` no longer deadlocks the event thread. The dispatch
  held the non-reentrant registry lock across the callbacks, so a listener that
  dropped itself waited on the thread it ran on. The dispatch now calls the
  listeners off a snapshot with the lock released, and the removed listener gets
  one last delivery from that snapshot. A remove from another thread still waits
  the delivery out, so the `userData` of a listener stays safe to free as soon as
  the remove returns. Under `--mm:refc` a listener may only remove, not add: a
  registration grows the registry, and the event thread must not allocate into
  the thread-local heap that owns it.
  A remove from inside a callback cannot wait for its own dispatch, so it returns
  at once. If it drops a different listener, the snapshot in flight can still
  deliver to that listener, and its `userData` must stay alive until the dispatch
  ends. The generated wrappers (`<lib>_ctx_remove_event_listener` in C,
  `removeEventListener` in C++, `remove_event_listener` in Rust) release the box
  that holds the handler, so call them from inside a callback only for the
  listener that runs.

## [0.3.0] - 2026-07-24

[Full changelog](https://github.com/logos-messaging/nim-ffi/compare/v0.2.0...v0.3.0)

Breaking release. `declareLibrary` is now required before any FFI annotation;
the per-request handler timeout and its `{.ffi: "timeout = <ms>".}` override are
replaced by the non-terminal `RET_STALE_WARN` progress callback; reaching an
`enum` from an `abi = c` type or proc is a compile error; and the generated C
`<lib>_ctx_destroy()` returns `int` instead of `void`.

New surface: `{.ffiStatic.}` for context-independent procs, `{.ffiConst.}`,
`{.ffi.}` enums, doc-comment propagation into the generated bindings, a C
binding generator (`-d:targetLang=c`), and a CBOR-free `abi = c` path in both
directions. Internally the watchdog thread is gone — the heartbeat now runs on
the dedicated event thread that also isolates user callbacks from the FFI thread.

### Changed
- **The host holds an opaque context token, not the address of a pool slot.** A
  slot keeps its address across a recycle, so a pointer from an earlier owner
  passed validation again as soon as a new owner claimed the same slot, and then
  dispatched onto the library of that new owner. A context now carries a
  generation that every claim opens, and the value the constructors hand back is
  an `FFICtxToken` packing the slot index and that generation; `resolveCtx`
  rejects a token whose generation no longer matches. The two event-listener
  entry points went through the same change — they used to dereference the host
  pointer behind a nil check alone. **The C ABI is unchanged**: the token is
  pointer-sized and the generated headers still declare `void* ctx`, so the
  bindings are byte-identical and no foreign consumer changes. A Nim consumer
  passes `ctx.ffiToken()` into a generated entry point and turns a token back
  into a context with `<Lib>FFIPool.resolveCtx(token)`; `FFICtxToken` is a
  distinct type, so every site is a compile error until it is updated.
- `FFIHandleRegistry.release` takes the handle's `typeName` and applies the same
  type-tag check as `lookup`, so a release cannot cross types.
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
- **`{.ffiStatic.}`**: exports a context-independent proc — no library param, and
  no `ctx` in its wrapper, so a host can call a stateless utility (key generation,
  parsing, a version string) without constructing the library
  ([#134](https://github.com/logos-messaging/nim-ffi/issues/134)). Wired for both
  the `cbor` and `c` ABIs across all four backends: the C header emits
  `<lib>_static_<proc>(...)`, C++ and Rust an associated function on the ctx type
  taking the `timeout` a method reads from its ctx. Handlers run on the library's
  *static context*, created on the first such call and held for the rest of the
  process, so that call starts a thread pair nothing tears down —
  `destroyFFIContext` refuses it; `destroyStaticFFIContext` is the Nim-side
  teardown for process shutdown and tests, with no foreign equivalent. An
  `{.ffiHandle.}` parameter or return is rejected at macro time: a handle belongs
  to the context that created it, which a static proc cannot reach.
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
