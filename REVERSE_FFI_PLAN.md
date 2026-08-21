# Implementation Plan: Reverse FFI (`{.ffiReverse.}` / `{.ffiReverseEvent.}`) — Option B

Design: reverse calls are delivered on the event dispatch thread with an async reply
ABI; reverse events are sugar over the existing one-way request path. All file:line
anchors verified against the current tree (master @ 07ee8e1).

## 1. Design summary

### `{.ffiReverse.}` (host-implemented interface)

Library author writes a **bodyless** proc signature:

```nim
proc fetchConfig(key: string): Future[Result[ConfigResp, string]] {.ffiReverse.}
```

The macro generates the async body: encode args to CBOR (multi-param envelope
synthesized exactly like `buildFFIEventProc`, ffi/internal/ffi_macro.nim:1828-1850),
allocate a call-id, park a `Future[Result[seq[byte], string]]` in an FFI-thread-local
pending table, enqueue an `ekReverse` record on the existing event ring, `await` it
under a mandatory chronos `withTimeout`, then decode the reply into `ConfigResp` on
the FFI thread's own heap.

- Host registers via generated `<lib>_set_<name>_impl(ctx, impl, userData)` (never a
  raw fn-pointer parameter in a normal call — `rejectRawPtrType` at
  ffi/internal/ffi_macro.nim:98 untouched).
- Event thread invokes `impl(callId, argsCbor, len, userData)`; impl looked up **at
  dispatch time** under the reverse registry lock with a `dispatching` counter
  mirroring `beginDispatch`/`endDispatch` (ffi/ffi_events.nim:51-69), so
  `set_impl(ctx, NULL, NULL)` can wait an in-flight invocation out before the host
  frees `userData`.
- Host completes via `<lib>_reverse_reply(...)` from any thread: token resolved
  (`resolveCtx`, ffi/ffi_context_pool.nim:181), payload c_malloc-copied into an
  intrusive mailbox node (same pattern as `FFIThreadRequest.next`,
  ffi/ffi_thread_request.nim:36), `reqSignal` fired (reusing the existing wake at
  ffi/ffi_thread.nim:361 avoids a 7th ThreadSignalPtr, which matters because refc
  cannot close them, ffi/ffi_context.nim:149-152). The FFI loop drains the mailbox
  next to `processQueue()` (ffi/ffi_thread.nim:362) and completes the parked future.
- Unfulfilled interface at call time: checked under the registry lock *before*
  enqueue on the FFI thread; the future completes immediately with
  `err("no host implementation registered for <name>")` — the Nim caller sees a
  normal `Result` error. No new terminal RET code on the callback ABI;
  `reverse_reply` gets its own C status-code enum (section 2).

### `{.ffiReverseEvent.}` (host-emitted, library-handled)

Library author writes a proc **with a body**:

```nim
proc onHostPing(info: PingInfo) {.ffiReverseEvent.} = ...
```

Sugar over the existing request path: the macro synthesizes `<Name>Req` and reuses
`buildProcessFFIRequestProc` (ffi_macro.nim:447) + `addNewRequestToRegistry` (:547)
with a `void` response (`replyEncode` void branch :534), plus a C export
`<lib>_emit_<name>(ctx, cbor, len)` that builds an `FFIThreadRequest` with a static
no-op callback and submits via `sendRequestToFFIThread` (ffi/ffi_thread.nim:5).
Fire-and-forget; the return value is enqueue status only (0 / invalid-ctx /
queue-full — the same failures `sendRequestToFFIThread` already distinguishes at
ffi/ffi_thread.nim:14-47).

## 2. New C ABI surface (naming per ffi/codegen/c.nim:931-936 conventions)

```c
/* once per library, next to FFICallback in the prelude */
typedef void (*FFIReverseImpl)(uint64_t call_id, const uint8_t* args_cbor,
                               size_t args_len, void* user_data);

/* per {.ffiReverse.} proc */
int <lib>_set_<name>_impl(void* ctx, FFIReverseImpl impl, void* user_data);
    /* impl == NULL unregisters; blocks until an in-flight invocation returns */

/* once per library */
int <lib>_reverse_reply(void* ctx, uint64_t call_id, int ret_code,
                        const uint8_t* reply_cbor, size_t reply_len);
    /* callable from ANY thread; 0=accepted, 1=invalid context/token,
       2=context not active (recycling/quarantined), 3=payload too large
       (> MaxRequestPayloadBytes, ffi_thread_request.nim:13), 4=mailbox full */

/* per {.ffiReverseEvent.} proc */
int <lib>_emit_<name>(void* ctx, const uint8_t* payload_cbor, size_t payload_len);
```

The C header additionally gets typed sugar mirroring the listener trampolines
(c.nim:400-436): a generated typed impl typedef
(`void (*fn)(uint64_t call_id, const <ArgsStruct>* args, void* user_data)`), a
decode trampoline, and a typed reply helper
`<lib>_reverse_reply_<name>(ctx, call_id, const <RespStruct>*)` that CBOR-encodes
and forwards.

## 3. Call-id table design

Lives in a new **non-generic** `FFIReverseState` object embedded in `FFIContext`
(field added near `eventRegistry`, ffi/ffi_context.nim:55-99), init/deinit in
`initContextResources`/`deinitContextResources` (ffi_context.nim:180-183 / :145-148,
mirroring `initEventRegistry`):

- `nextCallId: Atomic[uint64]` — monotonic, **never reset across recycles** (like
  the slot `generation`, ffi_context.nim:63), so a stale id can never be reissued;
  ids start at 1, 0 invalid.
- `lock: Lock` + `impls: Table[string, tuple[fn: FFIReverseImpl, userData: pointer]]`
  + `dispatching: int` + `dispatchDone: Cond` — structural copy of
  `FFIEventRegistry` (ffi/ffi_events.nim:21-26). `set_impl` runs on the foreign
  caller thread and calls `initializeLibrary()` first, same GC rationale as the
  add-listener body (ffi/internal/ffi_library.nim:174-179).
- `mailbox: ptr ReverseReply` (intrusive c_malloc list) + `mailboxCount: int` under
  the same lock;
  `ReverseReply = {callId: uint64, retCode: cint, data: ptr UncheckedArray[byte], len: int, next: ptr ReverseReply}`
  — all libc memory, zero Nim refs. Bounded by
  `ReverseMailboxDepth {.intdefine.} = 1024`.
- `pendingReverse {.threadvar.}: Table[uint64, Future[Result[seq[byte], string]]]` —
  **FFI-thread-only** (installed in `ffiThreadBody` beside the other threadvars,
  ffi/ffi_thread.nim:283-287). Futures are refs and must never leave the FFI
  thread's heap; keyed by call-id, no lock needed. Stale-reply rejection is
  therefore trivial: a drained mailbox node whose id is absent from
  `pendingReverse` (timed out, recycled, or bogus) is freed and dropped.

## 4. Event-thread delivery (ring extension)

Extend `QueuedEvent` (ffi/ffi_events.nim:157-163) with `kind: EventRecordKind`
(`ekListener` default = 0, so existing zero-init paths are unaffected) and
`callId: uint64`. Reuse the same ring, slabs, and `tryEnqueueEvent` copy path
(:228-266) via a new `tryEnqueueReverse(q, name, src, len, callId)`.
`dispatchQueuedEvent` (ffi/event_thread.nim:55) branches: `ekListener` →
`dispatchToListeners` as today; `ekReverse` → look up `impls[name]` under the
reverse lock (inc `dispatching`, release lock, invoke, dec + broadcast). If the impl
vanished between call and dispatch, synthesize an error node into the mailbox so the
future fails promptly instead of waiting out the timeout.

Backpressure: when `tryEnqueueReverse` returns false (ring full), the FFI-thread
stub does **not** set the sticky `eventQueueStuck` flag (that semantics belongs to
listener overload, ffi_events.nim:322-340); it fails the call's future immediately
with `err("event queue full")`. Payloads over the 512 B slab take the existing
per-item heap fallback (:222-226) — no new limit.

## 5. Timeout mechanism

`const ReverseCallTimeoutMs {.intdefine: "ffiReverseCallTimeoutMs".} = 10000` beside
the other timeouts (ffi/ffi_context.nim:103-125); overridable per proc via
`{.ffiReverse, timeout = N.}` pragma arg (parsed like the wire-name/abi leading
args, ffi_macro.nim:1788). The stub does `await fut.withTimeout(deadline)`; on
timeout it deletes the call-id from `pendingReverse` (making any late
`reverse_reply` a no-op) and returns
`err("reverse call <name> timed out after N ms")`. No change to
`awaitWithStaleWarnings` (ffi/ffi_thread.nim:63): the reverse await happens *inside*
the handler, so a reverse deadline longer than `StaleWarnInterval` simply produces
RET_STALE_WARN pings to the original caller — correct and already documented
behavior.

## 6. refc/orc cross-thread handoff table

| Handoff | Mechanism | refc | orc |
|---|---|---|---|
| args, FFI→event thread | copy into c_malloc ring slab (existing) | safe | safe |
| impl fn + userData, host→ctx | raw pointers in locked Table | safe | safe |
| `impls` Table keys (GC strings) mutated from foreign thread | `initializeLibrary()` first (precedent ffi_library.nim:174-190) | safe | safe |
| reply buf, host→FFI thread | c_malloc copy on caller thread, c_free after decode on FFI thread | safe (libc heap is shared) | safe |
| parked Future + decoded value | never leaves FFI thread (`{.threadvar.}` table) | safe | safe |
| emit payload, host→FFI thread | existing `copySharedPayload` c_malloc (ffi_thread_request.nim:95) | safe | safe |
| ThreadSignalPtr wake | reuse `reqSignal` (no new fd; refc close-skip at ffi_context.nim:149 unaffected) | safe | safe |

## 7. Teardown / quarantine

- **First statement of `recycleContext`** (ffi/ffi_thread.nim:241, before
  `drainOngoing`:247): fail every entry in `pendingReverse` with
  `err("context is recycling")`. This is required, not optional —
  `awaitWithStaleWarnings` converts drain-cancel into `noCancel(retFut)`
  (ffi_thread.nim:83-86), so a handler parked on a reverse call would otherwise hold
  `drainOngoing` until the reverse timeout and risk a `DrainTimeout` quarantine
  (commit 07ee8e1).
- `resetForNextOwner` (ffi_thread.nim:207): free all mailbox nodes, clear `impls`
  (waiting `dispatching` out, like `clearListeners`:209).
- Late `reverse_reply` after recycle: stale token → `resolveCtx` nil → status 1;
  live-slot race → `lifecycle != Active` check (same as ffi_thread.nim:25) →
  status 2; anything that slips through hits an empty `pendingReverse` and is
  dropped. `nextCallId` never resets, so no id collision.
- Quarantined slot (`RecycleFailed`): threads stay alive; `reverse_reply` rejected
  by the lifecycle check; pending futures were already failed at recycle entry.

## 8. Macro / registry design

- `{.ffiReverse.}` requires a bodyless proc returning `Future[Result[T, string]]`
  with no receiver. It must **not** call `assertFFIPath` (ffi/internal/ffi_route.nim:76):
  its shape is `fpStatic`'s, and like `{.ffiCtor.}` it stays explicit-only
  (rationale ffi_route.nim:8-11). No `routeFFIProc` change; `{.ffi.}` never reaches
  reverse.
- `{.ffiReverseEvent.}` has the `fpEvent` shape (payload param, no result,
  ffi_route.nim:72) but with a body; also explicit-only, no `assertFFIPath` —
  otherwise the router message would tell the author to use `{.ffiEvent.}`. Add one
  sentence to the ffi_route.nim module doc.
- Compile-time metadata: `FFIReverseMeta`/`FFIReverseEventMeta` + registries in
  ffi/codegen/meta.nim mirroring `FFIEventMeta`/`ffiEventRegistry`; threaded into
  `generateCBindings`'s parameter list at ffi_macro.nim:1968-1972 (cpp:1963,
  rust:1958 in a later phase).
- `declareLibraryImpl` (ffi_library.nim:140) emits the two library-wide exports
  (`_reverse_reply`; the shared no-op callback for emit) exactly like
  `_add_event_listener` (:168-206); per-proc `_set_<name>_impl` / `_emit_<name>`
  are emitted by the respective macros (they know the pool ident via
  `currentLibType`, ffi_library.nim:145).

## 9. Phased steps

1. **`ffi/ffi_reverse.nim`**: `FFIReverseState`, `ReverseReply`,
   register/unregister with dispatch-wait, mailbox push/drain, call-id alloc; wire
   into `FFIContext` + init/deinit (ffi_context.nim:55, :143, :166)
   → verify: `nim c -r tests/unit/test_ffi_reverse_state.nim` (new, pure unit:
   mailbox bounds, stale-id drop, unregister-waits).
2. **Ring extension**: `kind`/`callId` on `QueuedEvent` + `tryEnqueueReverse`
   (ffi_events.nim:156-266); dispatch branch in `dispatchQueuedEvent`
   (event_thread.nim:55)
   → verify: existing `test_event_thread.nim`, `test_event_dispatch.nim` still
   green (`nimble test`), new cases in `test_ffi_reverse_state.nim`.
3. **FFI-loop integration**: `pendingReverse` threadvar (ffi_thread.nim:283),
   `drainReverseReplies()` beside `processQueue()` (:362 and :365), recycle-entry
   fail + `resetForNextOwner` cleanup (:207, :241)
   → verify: `nim c -r tests/unit/test_ffi_reverse.nim`
   (park/reply/timeout/missing-impl/late-reply), `test_ffi_teardown.nim` + new
   recycle-with-inflight-reverse case, both `-d:gcRefc` and orc.
4. **`{.ffiReverse.}` macro** in ffi_macro.nim (new section after `ffiEvent`:1890):
   stub body, envelope synthesis reuse, `_set_<name>_impl` export, meta
   registration
   → verify: `test_ffi_reverse.nim` end-to-end through a `declareLibrary` fixture;
   `test_ffi_router_reject.nim` addition confirming `{.ffi.}` on a reverse-shaped
   proc still errors sanely.
5. **`{.ffiReverseEvent.}` macro**: Req synthesis + `buildProcessFFIRequestProc`
   reuse (:447) + `_emit_<name>` export with no-op callback
   → verify: `nim c -r tests/unit/test_ffi_reverse_event.nim`.
6. **C codegen** (ffi/codegen/c.nim): impl typedef + decode trampoline
   (pattern :400-436), typed reply helper, header decls beside :931-936; cbor abi
   only, `abi = c` rejected like events (ffi_macro.nim:1791-1795)
   → verify: `nim c -r tests/unit/test_c_codegen.nim` (extended golden checks),
   `nimble genbindings_c`.
7. **Example + e2e**: extend `examples/timer/timer.nim` with one reverse proc + one
   reverse event; extend `tests/e2e/c/test_timer_e2e.c` (host impl computing
   inline, off-thread reply, timeout)
   → verify: `nimble test_c_e2e`, `nimble check_bindings_c`.
8. **Sanitizers/CI**: run the new unit tests under `nimble test_sanitized`
   (NIM_FFI_SAN=asan/tsan × refc/orc) — no task changes needed,
   `discoverUnitTests` auto-picks `tests/unit/test_*.nim`
   → verify: `NIM_FFI_SAN=tsan nimble test_sanitized`.
9. **Docs**: README + CHANGELOG entries; cpp.nim/rust.nim generators emit a
   "reverse FFI not yet bound" comment until phase 2
   → verify: `nimble check_bindings`.

## 10. New / changed files

- **New**: `ffi/ffi_reverse.nim` (state, mailbox, call-ids);
  `tests/unit/test_ffi_reverse_state.nim`, `tests/unit/test_ffi_reverse.nim`,
  `tests/unit/test_ffi_reverse_event.nim`.
- **Changed**: `ffi/ffi_events.nim` (ring record kind), `ffi/event_thread.nim`
  (dispatch branch), `ffi/ffi_thread.nim` (reply drain, recycle hooks),
  `ffi/ffi_context.nim` (state field + init/deinit),
  `ffi/internal/ffi_macro.nim` (two macros), `ffi/internal/ffi_library.nim`
  (`_reverse_reply` export), `ffi/codegen/meta.nim` + `ffi/codegen/c.nim`
  (+ later cpp/rust), `examples/timer/timer.nim`, `tests/e2e/c/test_timer_e2e.c`,
  `tests/unit/test_c_codegen.nim`.

## 11. Resolved design decisions

1. `set_impl` while a call is in flight **replaces**: new calls get the new impl,
   the old invocation completes against the old userData (unregister/replace waits
   out `dispatching` before returning, so the host may free the old userData after
   `set_impl` returns).
2. Timeout override is **pragma-level only**: `{.ffiReverse, timeout = N.}`.
3. Host-facing reply shape is **both**: one shared raw `<lib>_reverse_reply` per
   library plus generated per-proc typed helpers that CBOR-encode and delegate to
   it.

## 12. Out of scope

- `abi = c` (CBOR-free) wire shape for reverse calls/events (events already reject
  it, ffi_macro.nim:1791).
- cpp/rust/cddl codegen beyond stub comments (phase-2 follow-up).
- Reverse calls from `{.ffiStatic.}` contexts, streaming/multi-shot replies,
  host-side cancellation of a parked reverse call (timeout only), and re-entrant
  reverse calls issued from inside a host impl on the event thread.
