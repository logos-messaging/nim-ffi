# nim-ffi

Expose a Nim library to C, C++ and Rust by annotating ordinary Nim procs.

You write async Nim; `nim-ffi` provides the whole FFI runtime — a dedicated
worker thread, a request channel, CBOR (de)serialization, an event queue and a
context/handle registry — and generates the foreign-language bindings for you.
No hand-written `.h` files, no manual request enums, no shared-memory plumbing.

## Install

Add nim-ffi to your library's `.nimble`, then `import ffi`:

```nim
requires "https://github.com/logos-messaging/nim-ffi >= 0.3.0"
```

## Mental model

- You **declare a library** once with `declareLibrary(name, LibType)`.
- You **annotate procs and types** with pragmas (`{.ffi.}`, `{.ffiCtor.}`,
  `{.ffiDtor.}`, `{.ffiStatic.}`, `{.ffiEvent.}`).
- You **call `genBindings()` last**, which emits the foreign bindings.

Every request/response crosses the boundary as a single CBOR blob; the ctx
handle returned by the constructor is the only pointer that crosses. Each `{.ffi.}` proc runs on the library's own chronos
event loop, so bodies can `await` freely.

## Minimal example

```nim
import ffi, chronos

# 1. The library's main state. The FFI context owns one instance.
type Counter = object
  value: int

declareLibrary("counter", Counter)

# 2. Request/response shapes. Any {.ffi.} object or enum type becomes a
#    first-class struct/class in the generated bindings and rides the CBOR wire.
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
| `declareLibrary(name, LibType)` | call | Registers the library and its state type. Must run before any annotation. |
| `{.ffi.}` on a `type` | `object`, `enum` | Registers the type for binding generation; it serializes as CBOR. |
| `{.ffi.}` on a `proc` | proc | Exposes a method. First param is the library value, then typed params; returns `Future[Result[T, string]]`. |
| `{.ffiStatic.}` | proc | Exposes a context-independent proc: no library param, and its wrapper takes no ctx — see below. |
| `{.ffiCtor.}` | proc | The constructor. Returns `Future[Result[LibType, string]]`; creates the FFI context. |
| `{.ffiDtor.}` | proc | The destructor. Exactly one param `(x: LibType)`; tears the context down. Must cancel and await everything it spawned — see [the teardown contract](#the-teardown-contract). |
| `{.ffiEvent[: "wire_name"].}` | proc (empty body) | A library-initiated callback. Call the proc from any `{.ffi.}` handler to fire it. The wire name is optional — see below. |
| `{.ffiHandle.}` | `ref object` | Marks a type as an opaque handle: it stays server-side and crosses the wire as a `uint64` id. |
| `{.ffiConst.}` | `const` | Re-emits the value as a native constant in every generated binding — see below. |
| `genBindings()` | call | Emits the bindings. Must be the **last** FFI call in the compilation root. |

### Enums

`{.ffi.}` on an `enum` gives each language its own native enum:

```nim
type Level {.ffi.} = enum
  lLow = "low"
  lHigh = "high"
```

```c
typedef enum { LEVEL_L_LOW = 0, LEVEL_L_HIGH = 1 } Level;  /* C   */
enum class Level { lLow = 0, lHigh = 1 };                  // C++
pub enum Level { #[serde(rename = "low")] LLow, ... }      // Rust
```

An enum crosses the wire as **text**, not as its ordinal — whatever `$value`
yields, so the associated string if the enum declares one (`"low"` above) and
the symbol name otherwise (`lLow`). That is what `cbor_serialization` writes on
the Nim side, and the generated codecs map name ↔ value on the far side, so
reordering or renumbering values doesn't break an already-deployed peer.
Explicit ordinals are carried into the foreign enum so the two sides agree if
you ever cast.

### Constants

`{.ffiConst.}` copies a Nim `const` into the generated bindings, so callers
don't hand-maintain a second copy of a limit, a default or a protocol string:

```nim
const
  MaxPeers* {.ffiConst.} = 42
  DefaultTimeoutMs* {.ffiConst.}: uint32 = 3 * 1000
  Greeting* {.ffiConst.} = "hello"
```

```c
static const int64_t MAX_PEERS = 42LL;            /* C   */
static const uint32_t DEFAULT_TIMEOUT_MS = 3000;
static const char* const GREETING = "hello";
```

```cpp
constexpr int64_t MAX_PEERS = 42LL;               // C++
```

```rust
pub const MAX_PEERS: i64 = 42;                    // Rust
```

Integer, float, `bool` and `string` consts are supported; anything else is a
compile error. The value is whatever the const evaluates to, so computed
expressions arrive folded. Names are re-cased to `UPPER_SNAKE`, preserving
acronyms (`httpTTL` → `HTTP_TTL`). A constant is a compile-time value in each
language, not a symbol exported by the shared library — it never crosses the
wire.

### Doc comments

A `##` doc comment on an annotated proc is carried through to every generated
binding, so the exported API is documented once, at the source:

```nim
proc myTimerEcho*(
    timer: MyTimer, req: EchoRequest
): Future[Result[EchoResponse, string]] {.ffi.} =
  ## Sleeps `delayMs` then echoes the message back.
  ...
```

becomes ``/** Sleeps `delayMs` then echoes the message back. */`` above both the
exported symbol and the `<lib>_ctx_echo` wrapper in the C header, `/// ...` on
the C++ class method and the Rust `pub fn`, and a `;` comment in the CDDL
schema. Multi-line doc comments are preserved as-is.

Only `##` doc comments are propagated, and only on procs — a plain `#` comment
above the proc, and any comment on a `{.ffi.}` type or its fields, is dropped by
Nim's parser before the macro can see it.

### The return-type contract

Every `{.ffi.}` / `{.ffiCtor.}` proc must have an explicit
`Future[Result[T, string]]` return type — even for synchronous logic (just
`return ok(...)` without awaiting). The `Result`'s error string is delivered to
the foreign caller as the failure message.

### Context-independent procs

A `{.ffi.}` proc is a method: it takes the library value, and its wrapper takes a
`ctx`, so the host must construct the library to call it. A stateless utility
shouldn't have to pay for that. Annotate it `{.ffiStatic.}` instead — drop the
library param, and the ctx disappears from the generated wrapper:

```nim
proc counterParse*(text: string): Future[Result[BumpRequest, string]] {.ffiStatic.} =
  return ok(BumpRequest(by: text.parseInt()))
```

```c
/* {.ffi.} method              */ counter_ctx_bump(ctx, &req, on_reply, ud);
/* {.ffiStatic.} — no ctx      */ counter_static_parse(text, on_reply, ud);
```

The wrapper is `<lib>_static_<proc>`, not `<lib>_<proc>`, for the same reason a
method's is `<lib>_ctx_<proc>`: `<lib>_<proc>` is the raw symbol the dylib
exports. In C++ and Rust a static is an associated function on the ctx type
(`EchoCtx::lib_version()`), taking the `timeout` a method reads from its ctx.

The handler still needs an FFI thread, so it runs on the library's **static
context**: created on the first `{.ffiStatic.}` call, then alive for the rest of
the process — no ctx owns it, so nothing tears its thread pair down, and it holds
one of the pool's slots. It has no `myLib`, which is why a static proc cannot
take the library value.

There is no foreign teardown for it. From Nim, `destroyStaticFFIContext(pool)`
stops the thread pair and frees the slot; it is only sound once nothing will call
a `{.ffiStatic.}` proc again, so it is meant for process shutdown and tests.

The macro rejects an `{.ffiHandle.}` parameter or return: a handle is registered
in the context that created it, which a static proc cannot reach.

### The teardown contract

A `{.ffiDtor.}` must cancel **and await** everything it spawned. The pool recycles
a context by handing its slot — including the live FFI and event thread pair and
their chronos dispatcher — to the next owner, and the only proof that the previous
owner is gone from that thread is its teardown having run to the end. The runtime
cannot make up for a teardown that gave up: chronos exposes no way to enumerate,
let alone cancel, the futures of a thread outside a debug build, and a cancel is
cooperative in any case.

A teardown that overruns `-d:ffiTeardownTimeoutMs` (10 s) is cancelled at the
timeout; one that raises stops there. Either way the runtime treats the context as
unsafe to reuse and **quarantines** it:

| | Teardown completed | Teardown cut short or raised |
| --- | --- | --- |
| `<lib>_ctx_destroy` | `RET_OK` | `RET_ERR` |
| The library object | freed | kept alive — orphaned work may still hold pointers into it |
| The pool slot | back in the pool | claimed for the life of the process |
| In-flight callbacks | done before the destroy returned | can still fire, so keep their `userData` alive |

Quarantine costs one of the 32 slots permanently, so a library that habitually
overruns its teardown will exhaust the pool. `FFIContextPool.quarantinedSlots()`
reports the count from Nim, every quarantine is logged at `error`, and so is the
pool-exhausted error once any slot has been quarantined.

### Process exit

`<lib>_ctx_destroy` recycles: the slot's FFI and event thread pair stays up for
the next owner. Once no context is live the pool joins that pair, so a host that
destroys what it created leaves no thread of the library running. A finalize
under a live thread crashes the process, which is what this avoids.

Two cases keep a pair alive anyway: a host that exits still owning a context, and
a `{.ffiStatic.}` call, whose shared context holds its slot for the life of the
process. `<lib>_shutdown()` stops both, from `atexit` or the last line of `main`.
It returns 0 when every context stopped, 1 when one was left running. A context
you had not destroyed never ran its `{.ffiDtor.}`, so its slot is quarantined:
later calls on that handle fail, and the slot is gone from the pool's 32.

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
  - **Language bindings:** `rust` (default), `cpp`, `c`. All three speak CBOR.
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
