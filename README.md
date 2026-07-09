# nim-ffi

Expose a Nim library to C, C++ and Rust by annotating ordinary Nim procs.

You write async Nim; `nim-ffi` provides the whole FFI runtime — a dedicated
worker thread, a request channel, CBOR (de)serialization, an event queue and a
context/handle registry — and generates the foreign-language bindings for you.
No hand-written `.h` files, no manual request enums, no shared-memory plumbing.

## Install

Add nim-ffi to your library's `.nimble`, then `import ffi`:

```nim
requires "https://github.com/logos-messaging/nim-ffi >= 0.2.0"
```

## Mental model

- You **declare a library** once with `declareLibrary(name, LibType)`.
- You **annotate procs and types** with pragmas (`{.ffi.}`, `{.ffiCtor.}`,
  `{.ffiDtor.}`, `{.ffiEvent.}`).
- You **call `genBindings()` last**, which emits the foreign bindings.

By default, every request/response crosses the boundary as a single CBOR blob
(the wire format is configurable per library or per annotation — see
[ABI format](#abi-format)); the ctx handle returned by the constructor is the
only pointer that crosses. Each `{.ffi.}` proc runs on the library's own chronos
event loop, so bodies can `await` freely.

## Minimal example

```nim
import ffi, chronos

# 1. The library's main state. The FFI context owns one instance.
type Counter = object
  value: int

declareLibrary("counter", Counter)

# 2. Request/response shapes. Any {.ffi.} object type becomes a first-class
#    struct/class in the generated bindings and rides the wire in the library's
#    ABI format (CBOR by default).
type BumpRequest {.ffi.} = object
  by: int

type BumpResponse {.ffi.} = object
  newValue: int

# 3. Constructor: returns Future[Result[LibType, string]].
proc counterNew*(): Future[Result[Counter, string]] {.ffiCtor.} =
  return ok(Counter(value: 0))

# 4. A method: first param is the library value, then any typed params.
#    Return type is always Future[Result[T, string]].
proc counterBump*(
    c: Counter, req: BumpRequest
): Future[Result[BumpResponse, string]] {.ffi.} =
  await sleepAsync(1.milliseconds)
  return ok(BumpResponse(newValue: c.value + req.by))

# 5. Destructor: exactly one param (the library value).
proc counterDestroy*(c: Counter) {.ffiDtor.} =
  discard

# 6. genBindings() must be the LAST FFI call in the file (see below).
genBindings()
```

The generated C export names are the snake_case form of the proc names, e.g.
`counterBump` → `counter_bump`.

## Pragma reference

| Pragma | Applies to | Purpose |
| --- | --- | --- |
| `declareLibrary(name, LibType[, defaultABIFormat])` | call | Registers the library, its state type, and the default wire format. Must run before any annotation. |
| `{.ffi.}` on a `type` | `object` | Registers the type for binding generation; it serializes via the library's ABI format (CBOR by default). |
| `{.ffi.}` on a `proc` | proc | Exposes a method. First param is the library value, then typed params; returns `Future[Result[T, string]]`. |
| `{.ffiCtor.}` | proc | The constructor. Returns `Future[Result[LibType, string]]`; creates the FFI context. |
| `{.ffiDtor.}` | proc | The destructor. Exactly one param `(x: LibType)`; tears the context down. |
| `{.ffiEvent[: "wire_name"].}` | proc (empty body) | A library-initiated callback. Call the proc from any `{.ffi.}` handler to fire it. The wire name is optional — see below. |
| `{.ffiHandle.}` | `ref object` | Marks a type as an opaque handle: it stays server-side and crosses the wire as a `uint64` id. |
| `genBindings()` | call | Emits the bindings. Must be the **last** FFI call in the compilation root. |

### The return-type contract

Every `{.ffi.}` / `{.ffiCtor.}` proc must have an explicit
`Future[Result[T, string]]` return type — even for synchronous logic (just
`return ok(...)` without awaiting). The `Result`'s error string is delivered to
the foreign caller as the failure message.

### The result callback contract

Each request carries a result callback. It receives one of these status codes
(`ret` / `err_code`):

| Code | Value | Terminal? | Meaning |
| --- | --- | --- | --- |
| `RET_OK` | 0 | yes | Success; the payload carries the encoded result. |
| `RET_ERR` | 1 | yes | Failure; the payload carries the UTF-8 error string. |
| `RET_MISSING_CALLBACK` | 2 | — | No callback was passed; the request path reports this itself. |
| `RET_STALE_WARN` | 3 | **no** | Progress ping — the handler is still running. |

**nim-ffi never times a handler out.** A slow request runs to its natural
`RET_OK` / `RET_ERR`; it is never cancelled (a hard-cancel mid-call into the
underlying library can leave it half-applied). Instead, while a handler is still
in flight the callback receives a **non-terminal** `RET_STALE_WARN` every 5s
(Android's ANR interval; override at build time with
`-d:ffiStaleWarnIntervalMs=<ms>`), with the payload carrying the elapsed
milliseconds as a decimal string. The dev decides what to do with a slow request
— keep waiting, surface a spinner, tear the context down — nim-ffi does not
decide for them.

`RET_STALE_WARN` may fire any number of times and is **always** followed by
exactly one terminal `RET_OK` / `RET_ERR`. A caller that only wants the final
answer must ignore it (do not treat a non-zero code as an error without checking
for `RET_STALE_WARN` first). The generated higher-level typed wrappers currently
ignore it; the progress signal is delivered at the raw result-callback boundary.

### Events

An event is a proc with an empty body annotated `{.ffiEvent.}`. You fire it by
calling it with a typed payload from inside any `{.ffi.}` handler; the foreign
side receives it through a registered callback.

```nim
type PeerConnected {.ffi.} = object
  id: string

proc onPeerConnected*(peer: PeerConnected) {.ffiEvent.}  # wire name: "on_peer_connected"

proc counterBump*(c: Counter, req: BumpRequest): Future[Result[BumpResponse, string]] {.ffi.} =
  onPeerConnected(PeerConnected(id: "p-1"))
  return ok(BumpResponse(newValue: c.value + req.by))
```

The wire name is **optional**: when omitted it is derived from the proc name
(`onPeerConnected` → `on_peer_connected`), matching how `{.ffi.}` derives its C
export symbol. Pass a string literal (`{.ffiEvent: "custom_name".}`) only when
you need a name that differs from the proc.

### ABI format

The wire format is chosen **in code**, never by a compile flag. Override the
library default with `declareLibrary("lib", Lib, defaultABIFormat = "c")`, or
per annotation with an `"abi = ..."` spec, e.g. `{.ffi: "abi = c".}`. The
`-d:targetLang` flag (below) picks which *language* the bindings are emitted
for; it does not change the wire.

`cbor` is the default and fully-supported format: every proc, ctor, dtor and
event serializes through the generic CBOR path, and all binding generators emit
working callers for it.

`abi = c` is a newer, native C-struct wire (no CBOR round-trip). The single `c`
generator (`-d:targetLang=c`) emits its callers, choosing the `abi = c` or CBOR
header shape from the library's ABI format. It carries two honest limits today:

- **Events are CBOR-only.** Applying `abi = c` to an `{.ffiEvent.}` proc is a
  hard compile error; declare events with `abi = cbor` (they ride CBOR
  internally regardless of the library default).
- **All-scalar `abi = c` procs are dropped from the foreign bindings.** A
  `{.ffi: "abi = c".}` method whose every param and return is a plain scalar
  takes the CBOR-free scalar fast path at runtime, but the foreign codegen for
  that inline-args shape is a follow-up (tracked in #120) — such procs are
  omitted from the generated `.h`. Give a proc at least one non-scalar
  (struct / `seq` / `Option`) param or return, or use `abi = cbor`, if you need
  it in the bindings.

An `abi = c` proc whose whole signature is scalar — fixed-width integer, float,
or bool params (a `string` return is fine, a `string` param is not) and no
structs, handles, or pointers — dispatches through a CBOR-free scalar fast path.
The `-d:targetLang=c_abi` generator emits real bindings for that shape: the
wrapper passes the scalar args inline (no request struct) and adapts the
raw-bytes reply into the same typed callback surface the flat-struct methods
use. The CBOR-speaking targets (`c`, `cpp`, `rust`, `cddl`) have no scalar
codegen, so under `-d:ffiGenBindings` they would omit such a proc from the
generated bindings — and `genBindings()` fails with an error naming the
affected procs. Resolve it by generating with `-d:targetLang=c_abi`, switching
the proc to `abi = cbor`, adding a non-scalar param so it takes the CBOR wire
shape, or passing `-d:ffiAllowScalarSkip` to accept the omission (the proc
still works over the scalar fast path; it's just absent from the generated
foreign bindings).

## Placement of `genBindings()`

`genBindings()` reads the compile-time registries that the pragmas populate as
the compiler expands them, so **it must come after every annotation**. Since
Nim resolves `import`s before running the importing module's body, a multi-file
library keeps its annotations in imported sub-modules and calls `genBindings()`
once at the bottom of the top-level root file.

An annotation that expands *after* `genBindings()` is now a **compile error**
(previously it was silently dropped from the bindings).

## Building — the two-compile model

A nim-ffi library ships from **two separate compiles of the same source**,
because binding emission is gated behind `-d:ffiGenBindings`: without that
define `genBindings()` is a no-op, so the normal build just produces the shared
library and nothing else.

**1. Build the shared library** (the artifact your host loads):

```sh
nim c --app:lib --noMain --nimMainPrefix:libmylib mylib.nim
```

**2. Emit the foreign bindings** — add the binding defines and `--compileOnly`,
which stops after codegen: the binding files are written during macro expansion,
so there's no library to link (no `--app:lib`/`-o:/dev/null` needed). The
generated files (for `targetLang=c`: the `<name>.h` header your host includes,
plus a `CMakeLists.txt`) land in `-d:ffiOutputDir`:

```sh
nim c -d:ffiGenBindings -d:targetLang=rust,cpp,c --compileOnly mylib.nim
```

- `-d:targetLang` — which generator(s) run; pass a comma-separated list to emit
  several from one compile:
  - **Language bindings:** `rust` (default), `cpp`, `c`. The `c` target follows
    the library's ABI format — an `abi = c` C-struct header for `abi = c`, a CBOR
    header otherwise; `rust`/`cpp` speak CBOR.
  - **`cddl`** — a CDDL schema of the CBOR wire, not a language binding at all.
- `-d:ffiOutputDir` — override where the generated files land. Defaults to
  `<lang>_bindings/` next to the compiled source.
- `-d:ffiSrcPath` — override the Nim source path embedded in the generated build
  files. Defaults to the compiled source made relative to the output dir.

### The `--nimMainPrefix:lib<name>` rule

`--app:lib` builds a shared library; `--noMain` hands program entry to the
foreign host rather than Nim's own `main`. To initialize the Nim runtime,
`declareLibrary("<name>", …)` emits an `initializeLibrary()` export that calls
`lib<name>NimMain()` — the symbol Nim's `NimMain` is renamed to by
`--nimMainPrefix`. So the prefix **must be exactly `lib` + the `declareLibrary`
name**, on *both* compiles above, or the library fails to link. For
`declareLibrary("my_timer", …)` that is `--nimMainPrefix:libmy_timer`.

**Library-naming collisions.** When several nim-ffi libraries are loaded into
one process (as the C++ end-to-end test does with `timer` + `echo`), each must
use a **distinct** library name — and therefore a distinct `--nimMainPrefix` —
so their exported `NimMain`, `initializeLibrary` and per-symbol names don't
clash. The example libraries deliberately differ: `libmy_timer` vs `libecho`.

## Examples

- `examples/timer` — a self-contained Nimble project covering the ctor, sync
  and async methods, multi-param methods, events, and C / C++ / Rust / CDDL
  bindings with runnable clients. Start here:

  ```sh
  cd examples/timer && nimble install -y ../.. && nimble build
  ```

- `examples/echo` — a second minimal library, loaded alongside `timer` in the
  C++ end-to-end test to prove two libraries coexist in one process.
