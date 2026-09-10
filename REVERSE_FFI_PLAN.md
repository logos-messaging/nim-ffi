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

---

# Phase 3: per-context reverse worker pool (delivery off the event thread)

Phases 1–2 (branch `experimental_reverse_ffi_for_plugins`, PR #154) invoke the
host impl inline on the event dispatch thread. That violates two requirements
added after review: the wrapper must not assume the impl is non-blocking, and
reverse calls must not serialize behind one another. Phase 3 replaces the ring
hop with library-owned, per-context worker threads and adds cancel/skip
semantics plus explicit worker management.

## 3.1 Requirements (agreed)

| # | Requirement | Mechanism in this phase |
|---|---|---|
| R1 | Impl may block; wrappers stay unchanged; implicitly async in every language incl. C | host closure runs on a **reverse worker thread**, never on the event or FFI thread |
| R2 | Reverse calls don't serialize; hot-path safe | N workers per context pull from one queue; each parked call is independent |
| R3 | Timeout / explicit cancel; in-flight reply handled; **queued-but-expired skipped** | per-record `state` atomic (`Pending→Running` by worker, `Pending→Cancelled` by FFI thread) + deadline check at dequeue; late replies dropped by id as today |
| R4 | Workers managed: explicit stop at teardown; blocked worker noticed and not fed | stop flag + cond broadcast + bounded join; per-worker `busySince` watched by the existing event-thread heartbeat pass; pull model never feeds a busy worker |
| R5 | Harness compiled only when `{.ffiReverse.}` is used; lazy start; explicit start possible | worker procs are generic over the lib type and reached only through a per-library hook slot the macro installs (same pattern as `ffiTeardownHook[T]`, ffi/ffi_context.nim:129); started on first `set_impl`, or via `<lib>_start_reverse_workers` |

## 3.2 Design

**Per-context pool** (decided over per-library: isolation between plugins,
teardown ownership rides the context's existing lifecycle, liveness rides the
context's heartbeat; cost is `N` threads per *live* context, `N` default 2 via
`-d:ffiReverseWorkers`, threads created only once reverse FFI is actually used).

**Invocation record** (c_malloc, owned by the queue/worker, freed by whoever
dequeues it — the FFI thread never frees):

```
ReverseInvocation = object
  callId*: uint64
  generation*: uint          # ctx claim it was issued under; mismatch → drop at dequeue
  deadlineNs*: int64         # monotonic; expired → drop at dequeue (R3)
  state*: Atomic[ReverseCallState]   # Pending | Running | Cancelled
  name*: cstring             # c_malloc copy
  args*: ptr UncheckedArray[byte]; argsLen*: int
  next*: ptr ReverseInvocation
```

State machine:

| Transition | Actor | Effect |
|---|---|---|
| `Pending → Running` (CAS) | worker, after the generation + deadline checks | worker owns the call, invokes the impl |
| `Pending → Cancelled` (CAS) | FFI thread on deadline or `cancel` | never invoked — no wasted host work; worker frees it at dequeue |
| deadline/cancel while `Running` | FFI thread | future fails now; slot stays `Running`; the later `reverse_reply` finds no pending id and is dropped (today's path) |

**Queue**: one intrusive FIFO per context guarded by a `Lock` + `Cond`
(single producer = FFI thread, N consumers). No ring, no `ekReverse`: the event
ring goes back to events only (`QueuedEvent` returns to its pre-#153 layout —
also good for the Windows stack budget).

**Worker loop** (generic `reverseWorkerBody[T](ctx, idx)`):

1. wait on cond until a record or `stop`;
2. drop + free when `generation != ctx.currentGeneration()` (same rule as
   `rejectQueuedRequests`) or `now > deadlineNs` or CAS `Pending→Running` fails;
3. `busySince.store(now)`, `currentCall.store(callId)`;
4. `beginReverseDispatch(name)` → not found: `pushReply(RET_ERR, …)` + wake;
   found: `foreignThreadGc: entry.fn(...)`, `endReverseDispatch`;
5. `busySince.store(0)`, free record.

**FFI-thread side** (`ffiReverseCall`, ffi/ffi_reverse.nim): allocate the record,
`pendingReverse[callId] = (fut, rec)`, push + signal cond; `await fut.withTimeout`
inside `try/except CancelledError` so both the deadline and an explicit
`cancelSoon()` on the returned future do: CAS `Pending→Cancelled`, delete the
pending entry, fail/re-raise. `pushReply` fires `reqSignal` only on the
mailbox's empty→non-empty transition (wake coalescing).

**Lazy / explicit start**: `startReverseWorkers[T](ctx, n)` is idempotent under
the reverse lock (`started` flag). Called by the generated `<lib>_set_<wire>_impl`
export (macro knows `LibType`) and by a new export
`int <lib>_start_reverse_workers(void* ctx, int n)` (n ≤ 0 → default); Nim side
`startReverseWorkers(ctx)` for libraries that want workers warm before the first
registration. `declareLibrary` does **not** reference any of it: the `ffiReverse`
macro installs `ffiReverseHook[LibType]() = (stop: stopReverseWorkers[LibType],
liveness: checkReverseWorkers[LibType])` once per library (compile-time guard),
so a library without `{.ffiReverse.}` never instantiates the harness (R5); the
FFI/event threads only nil-check the hook.

**Liveness**: `FFIReverseWorker = {thread, busySince: Atomic[int64],
currentCall: Atomic[uint64], stalled: bool}`. The event thread's existing
heartbeat pass (`eventRun`, ffi/event_thread.nim) calls the hook: busy longer
than `ReverseWorkerStallMs` (default = `ReverseCallTimeoutMs`) → emit
`reverse_worker_blocked {worker, callId}` once; recovery → `reverse_worker_recovered`.
"Not fed" is inherent to pull. No automatic replacement workers (knob for later).

**Teardown**:

- full destroy (`stopAndJoinThreads` → after FFI/event join): hook `stop`: set
  stop flag, cancel + free every queued record, broadcast, join each worker with
  `ThreadExitTimeout`; an unjoinable worker is leaked and logged, the context
  reports it like other quarantine reasons;
- recycle: workers survive (like FFI/event threads); `resetForNextOwner` purges
  the queue and `clearImpls` waits `dispatching` out **with a bound** — a worker
  still inside a host impl after `RecycleTimeout` quarantines the slot with a new
  `RecycleFailure.ReverseImplBlocked` instead of hanging the recycle.

**Bindings**: C/C++/Rust closures unchanged (they now run on a worker). New raw
export `<lib>_start_reverse_workers`; typed helpers `<lib>_ctx_start_reverse_workers`,
`startReverseWorkers(n)` / `start_reverse_workers(n)`. No `is_live` query (hosts
that offload again on their side can be served later if needed).

**Memory model**: records/args/replies stay libc-malloc'd; workers are Nim
threads running host code under `foreignThreadGc` exactly as the dispatch
thread does today; no Nim ref crosses threads; identical under refc and orc.
Windows: `createThread`/`joinThread` + `Lock`/`Cond` only, no new signal fds.

## 3.3 Steps (all done on the branch; deviations from 3.2 noted)

- Records carry a two-owner refcount (queue/worker + pending entry): a deadline
  racing a worker that has just finished the impl could otherwise free the
  record under the FFI thread. Last release frees.
- The worker harness is non-generic; it stays out of libraries without
  `{.ffiReverse.}` through dead-code elimination: the only references to
  `startReverseWorkers` are the generated `set_impl` / `start_reverse_workers`
  exports and the call stub, and stop/liveness go through hook pointers
  (`stopFn`, `wakeFn`, `generationFn`) that stay nil until a start.
- `clearImpls` no longer waits; the recycle path polls `inFlight()` with
  `RecycleTimeout` from the async loop (no blocking on the dispatcher).
- Tests that leak or quarantine a slot use a module-level pool: a quarantined
  slot keeps its threads, so the pool must outlive the test.

1. `ffi/ffi_reverse.nim`: `ReverseInvocation`, state enum, queue (push/pop/purge),
   worker descriptor, `startReverseWorkers[T]`/`stopReverseWorkers[T]`/
   `checkReverseWorkers[T]`, hook slot; rewrite `ffiReverseCall` (cancel path,
   record lifetime); wake coalescing in `pushReply`
   → verify: `test_ffi_reverse_state.nim` reworked for the queue + state machine
   (cancel-before-dequeue skipped, expired skipped, running→late reply dropped,
   explicit `cancelSoon`).
2. Revert `ekReverse`/`callId` from `ffi/ffi_events.nim` and the dispatch branch
   from `ffi/event_thread.nim`; add the liveness hook call in `eventRun`
   → verify: `test_event_dispatch`, `test_event_thread` unchanged and green.
3. `ffi/ffi_thread.nim` + `ffi/ffi_context.nim`: hook nil-checks at recycle
   (bounded `clearImpls`, new failure reason) and destroy (stop + join)
   → verify: `test_ffi_reverse.nim` + `test_ffi_teardown.nim` new cases
   (destroy with a blocked impl leaks-and-reports within `ThreadExitTimeout`;
   recycle with a blocked impl quarantines).
4. `ffi_macro.nim`: `ffiReverse` installs the hook once per library, `set_impl`
   starts workers lazily, new `<lib>_start_reverse_workers` export; C/C++/Rust
   generators emit the start helper
   → verify: `test_ffi_reverse_macro.nim` (lazy start on `set_impl`, explicit
   start), codegen goldens.
5. Concurrency proof: two 100 ms impls awaited by two concurrent requests finish
   in ≈100 ms with `N=2`; C++ e2e adds the same test with `std::this_thread::sleep_for`
   inside the closure (R1/R2 end-to-end)
   → verify: `test_ffi_reverse.nim`, `nimble test_cpp_e2e`, `test_c_e2e`, rust client.
6. Sanitizers: ASAN/TSAN × orc/refc on the reverse test files; `check_bindings`;
   nph; README/CHANGELOG (semantics table: cancel, skip, blocked-worker event,
   worker knobs).
