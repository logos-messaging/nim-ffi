# Design: typed host callbacks (`{.ffiHost.}`)

Status: **draft / in progress.** Roadmap item #1 from [future-work.md](future-work.md).

## Goal

Let a Nim `{.ffi.}` handler call **back into the host language** for typed data
and `await` the result:

```nim
# Declared in the library, implemented by the host (no Nim body):
proc fetchProfile(userId: string): Future[Result[Profile, string]] {.ffiHost.}

proc myAppLogin(app: MyApp, req: LoginReq): Future[Result[Session, string]] {.ffi.} =
  let profile = (await fetchProfile(req.userId)).valueOr:
    return err("host fetch failed: " & error)
  return ok(openSession(profile))
```

This is the inverse of events (which are lib → host, fire-and-forget). It is the
"a lower layer needs to read from a higher one" case from logos-delivery #3865.

## Why it's not just "events backwards"

Events invoke a host `FFICallBack` **synchronously on the FFI thread** and
ignore any return value. A host *call* must return data, and the host may take
arbitrary time / answer on its own thread. The chronos `Future` the Nim handler
awaits can only be completed **on the FFI (event-loop) thread**. So the result
has to be marshaled back across the thread boundary — exactly the reverse of the
existing request path:

```
host → lib request : reqChannel.trySend + reqSignal.fireSync → FFI loop → processRequest → reply callback
lib → host call    : hostFn(token, req) … host works … <lib>_host_complete(token, result)
                     → completionQueue.push + completionSignal.fireSync → FFI loop → fut.complete(result)
```

The completion path reuses the same primitive (`ThreadSignalPtr` + an SPSC/MPSC
queue) that `reqSignal`/`reqChannel` already use (`ffi/ffi_context.nim`).

## Moving parts

### 1. Host-function registry (per context)
A small registry mirroring `FFIEventRegistry` (`ffi/ffi_events.nim`): maps a wire
name (`"fetch_profile"`) to a `(FFIHostFn, userData)`. The host registers an
implementation at runtime; a nil/missing entry makes the imported proc resolve
to `err("host fn '<name>' not registered")` rather than crash (never-crash
policy).

### 2. In-flight completion table (per context)
`token: uint64 → Completer`, where `Completer` holds the pending chronos
`Future` and a slot for the raw result bytes. Tokens are monotonic per context.
Guarded by a lock; only the FFI thread completes futures.

### 3. Completion bridge (FFI thread integration)
- New `completionSignal: ThreadSignalPtr` + `completionQueue` on `FFIContext`.
- `<lib>_host_complete(...)` (called from the host thread) pushes `(token, ret,
  bytes)` onto the queue and fires `completionSignal`.
- The FFI loop (`ffiThreadBody`) additionally waits on `completionSignal`; on
  wake it drains the queue and, for each entry, looks up the token and
  `fut.complete(decodedResult)` — on the loop thread, satisfying chronos.

### 4. The `{.ffiHost.}` macro
From a bodyless `proc <name>(args…): Future[Result[T, string]] {.ffiHost.}`,
emit a normal async Nim proc whose body:
1. marshals `args` into a request buffer (native POD first; CBOR variant later),
2. allocates a token + registers a `Completer` (Future) in the in-flight table,
3. looks up the host fn for `"<name>"`; if absent → `return err(...)`,
4. invokes `hostFn(token, reqMsg, reqLen, userData)`,
5. `return await completer.fut` (decoded to `Result[T, string]`).

Note the same dual-proc spirit as `{.ffi.}`: in-process Nim callers could later
get a directly-injectable implementation, but the foreign path goes through the
registry.

### 5. ABI + codegen (per language)
Exported symbols (added to `c.nim` and the other generators):
```c
typedef void (*FFIHostFn)(uint64_t token, const char *req, size_t reqLen, void *userData);
int  <lib>_register_host_fn(void *ctx, const char *name, FFIHostFn fn, void *userData);
int  <lib>_host_complete(void *ctx, uint64_t token, int ret, const char *msg, size_t len);
```
Each generator then emits an idiomatic wrapper: register a closure, and on
completion call `<lib>_host_complete`. (Out of scope for the first slice — C ABI
+ a C e2e test prove the mechanism first.)

## Host consumption (per language)

The raw contract a host satisfies, and the rule that shapes the wrappers:

1. Register `fn` under a name. When the Nim handler `await`s the imported proc,
   the library invokes `fn` **on the FFI thread** with a `token` + marshaled
   args.
2. `fn` **must return immediately** — it sits on the chronos event-loop thread,
   so it captures the `token`, kicks the real work onto the host's own executor,
   and returns.
3. When the work finishes (any thread, any time later), the host calls
   `<lib>_host_complete(ctx, token, ret, msg, len)`, which enqueues + signals the
   FFI loop to complete the awaited `Future`. The `token` is what decouples
   "invoked on the FFI thread" from "answered later on the host's thread."

The generated wrapper hides token, threading hop, and marshaling — the host dev
writes a normal function in the language's async idiom. The wrapper's trampoline
does three things: decode `req` → typed args, run the closure **on the host
executor** (never inline on the FFI thread), encode the result and call
`<lib>_host_complete`.

```go
// Go — trampoline spawns a goroutine, then host_complete
node.SetFetchProfile(func(userID string) (Profile, error) { return db.Lookup(userID) })
```
```swift
// Swift — trampoline launches a Task
node.fetchProfile = { userID in try await db.lookup(userID) }
```
```kotlin
// Kotlin — JNI trampoline launches a coroutine
node.setFetchProfile { userID -> db.lookup(userID) }
```
```rust
// Rust — closure returning a future, driven on the host runtime
node.set_fetch_profile(|userId| async move { db.lookup(&userId).await });
```

**The gotcha the wrappers exist to enforce:** a binding that ran the closure
inline in `FFIHostFn` would stall the event loop (and deadlock if the closure
re-entered the library). Each language needs its own trampoline to hop onto its
executor — that's the real work of increment 5, not a shared shim.

## Threading / safety notes

- Futures completed **only** on the FFI thread (drain runs there). `host_complete`
  from any thread only enqueues + signals.
- A `host_complete` for an unknown/expired token is dropped with a debug log (a
  late/double completion must not crash) — never-crash policy.
- Context teardown must fail every outstanding `Completer`
  (`err("context shutting down")`) and drain the queue so no future is abandoned
  (matches the existing in-flight `pending` drain in `ffiThreadBody`).
- Re-entrancy: an imported call happens *inside* a `{.ffi.}` handler already on
  the FFI thread; it must `await` (yield the loop) so the loop keeps draining —
  it must never block the thread waiting on the host.

## Increments

1. **Registry + in-flight table** (pure data structures + unit tests) ← first
2. Completion bridge on `FFIContext` (signal + queue + loop drain + teardown)
3. `{.ffiHost.}` macro (native POD marshaling, string args/results first)
4. C ABI codegen + a C end-to-end test (Nim handler calls a C-provided host fn)
5. Idiomatic wrappers in the per-language generators
6. CBOR variant + structured (`{.ffi.}`-typed) args/results
```
