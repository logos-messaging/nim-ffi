# nim-ffi

Expose a Nim library to C, C++ and Rust by annotating ordinary Nim procs.

You write async Nim; `nim-ffi` provides the whole FFI runtime — a dedicated
worker thread, a request channel, CBOR (de)serialization, an event queue and a
context/handle registry — and generates the foreign-language bindings for you.
No hand-written `.h` files, no manual request enums, no shared-memory plumbing.

## Mental model

- You **declare a library** once with `declareLibrary(name, LibType)`.
- You **annotate procs and types** with pragmas (`{.ffi.}`, `{.ffiCtor.}`,
  `{.ffiDtor.}`, `{.ffiEvent.}`).
- You **call `genBindings()` last**, which emits the foreign bindings.

Every request/response crosses the boundary as a single CBOR blob; the ctx
handle returned by the constructor is the only pointer that crosses. Each
`{.ffi.}` proc runs on the library's own chronos event loop, so bodies can
`await` freely.

## Minimal example

```nim
import ffi, chronos

# 1. The library's main state. The FFI context owns one instance.
type Counter = object
  value: int

declareLibrary("counter", Counter)

# 2. Request/response shapes. Any {.ffi.} object type becomes a first-class
#    struct/class in the generated bindings and rides the wire as CBOR.
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
proc counter_destroy*(c: Counter) {.ffiDtor.} =
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
| `{.ffi.}` on a `type` | `object` | Registers the type for binding generation; it serializes via the generic CBOR overloads. |
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

The default wire format is `cbor`. Override the library default with
`declareLibrary("lib", Lib, defaultABIFormat = "c")`, or per annotation with an
`"abi = ..."` spec, e.g. `{.ffi: "abi = c".}`.

## Placement of `genBindings()`

`genBindings()` reads the compile-time registries that the pragmas populate as
the compiler expands them, so **it must come after every annotation**. Since
Nim resolves `import`s before running the importing module's body, a multi-file
library keeps its annotations in imported sub-modules and calls `genBindings()`
once at the bottom of the top-level root file.

An annotation that expands *after* `genBindings()` is now a **compile error**
(previously it was silently dropped from the bindings).

## Generating bindings

Binding emission is gated behind `-d:ffiGenBindings`; without it, `genBindings()`
is a no-op and the library just builds normally.

```sh
nim c -d:ffiGenBindings -d:targetLang=c \
      -d:ffiOutputDir=path/to/output -d:ffiSrcPath=../mylib.nim mylib.nim
```

- `-d:targetLang` — `rust` (default), `cpp`, `c`, or `cddl`.
- `-d:ffiOutputDir` — where the generated files land.
- `-d:ffiSrcPath` — the Nim source path embedded in the generated build files.

## Examples

- `examples/timer` — a self-contained Nimble project covering the ctor, sync
  and async methods, multi-param methods, events, and C / C++ / Rust / CDDL
  bindings with runnable clients. Start here:

  ```sh
  cd examples/timer && nimble install -y ../.. && nimble build
  ```

- `examples/echo` — a second minimal library, loaded alongside `timer` in the
  C++ end-to-end test to prove two libraries coexist in one process.
