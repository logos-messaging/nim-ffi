## Reverse-FFI runtime: host-registered implementations for `{.ffiReverse.}`
## procs, the per-context worker pool that invokes them, monotonic call ids,
## and the reply mailbox host threads push into for the FFI thread to drain.
##
## Threads: the FFI thread produces invocation records; N reverse workers
## (started lazily, owned by the context) consume them and run the host impl;
## any host thread answers through the mailbox. Every cross-thread buffer is
## libc malloc'd (same rule as ffi_thread_request); no Nim ref crosses a thread.
##
## Nothing here references the worker procs from the always-compiled context
## code: they are reached only through the hook pointers `startReverseWorkers`
## installs, so a library without `{.ffiReverse.}` never links the harness.

import system/ansi_c
import std/[atomics, locks, monotimes, os, tables]
import chronos, results
import ./ffi_types

const ReverseMailboxDepth* {.intdefine: "ffiReverseMailboxDepth".} = 1024
  ## Replies parked between two FFI-thread drains. A full mailbox rejects the
  ## reply (the caller's future then times out). Override with
  ## `-d:ffiReverseMailboxDepth=<n>`.

const ReverseCallTimeoutMs* {.intdefine: "ffiReverseCallTimeoutMs".} = 10000
  ## Default deadline for one `{.ffiReverse.}` call; per-proc override via
  ## `{.ffiReverse("wire", timeout = N).}`. Override with
  ## `-d:ffiReverseCallTimeoutMs=<ms>`.

const ReverseWorkersDefault* {.intdefine: "ffiReverseWorkers".} = 2
  ## Reverse workers per context, started lazily on the first `set_impl` (or
  ## explicitly via `startReverseWorkers`). Override with `-d:ffiReverseWorkers=<n>`.

const ReverseWorkerStallMs* {.intdefine: "ffiReverseWorkerStallMs".} =
  ReverseCallTimeoutMs
  ## A worker inside one host impl longer than this is reported as blocked
  ## (`reverse_worker_blocked` liveness event). Override with
  ## `-d:ffiReverseWorkerStallMs=<ms>`.

const ReverseWorkerJoinTimeoutMs* {.intdefine: "ffiReverseWorkerJoinTimeoutMs".} = 1500
  ## How long `stopReverseWorkers` waits for each worker before leaking it.

## `<lib>_reverse_reply` / `<lib>_set_*_impl` / `<lib>_start_reverse_workers`
## status codes (C-visible).
const
  REVERSE_ACCEPTED*: cint = 0
  REVERSE_INVALID_CTX*: cint = 1
  REVERSE_NOT_ACTIVE*: cint = 2
  REVERSE_PAYLOAD_TOO_LARGE*: cint = 3
  REVERSE_MAILBOX_FULL*: cint = 4
  REVERSE_WORKERS_FAILED*: cint = 5

proc ffiNoopCallback*(
    callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Stands in for the reply callback of a fire-and-forget `{.ffiReverseEvent.}`
  ## request: the host gets the enqueue status from the emit call itself.
  discard

type FFIReverseImpl* = proc(
  callId: uint64,
  argsCbor: ptr UncheckedArray[byte],
  argsLen: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}
  ## Host-registered implementation of a `{.ffiReverse.}` proc. Invoked on one
  ## of the context's reverse worker threads; it may block (that worker is then
  ## unavailable, and reported when it stalls) and answers, inline or later
  ## from any thread, via `<lib>_reverse_reply`.

type
  FFIReverseImplEntry* = object
    fn*: FFIReverseImpl
    userData*: pointer

  ReverseReply* = object
    ## Intrusive c_malloc node: reply doubles as its own queue link, zero Nim refs.
    callId*: uint64
    retCode*: cint
    data*: ptr UncheckedArray[byte] # c_malloc'd copy; freed by the draining thread
    dataLen*: int
    next*: ptr ReverseReply

  ReverseCallState* {.pure.} = enum
    Pending ## queued; a worker may still claim it, the FFI thread may still cancel it
    Running ## a worker claimed it; the reply, if any, is dropped by id once abandoned
    Cancelled ## deadline or explicit cancel won the race; skipped at dequeue

  ReverseInvocation* = object
    ## Intrusive c_malloc record with two owners: the queue (later the worker
    ## that dequeues it, or the purge path) and the FFI thread's pending entry.
    ## Each side releases once; the last release frees, so a timeout racing a
    ## worker that has just finished the impl never touches freed memory.
    refs: Atomic[int]
    callId*: uint64
    generation*: uint # claim it was issued under; a mismatch is dropped at dequeue
    deadlineNs*: int64 # monotonic; expired records are dropped at dequeue
    state*: Atomic[ReverseCallState]
    name*: cstring # c_malloc copy
    args*: ptr UncheckedArray[byte] # c_malloc copy, nil when empty
    argsLen*: int
    next*: ptr ReverseInvocation

  FFIReverseWorker* = object
    thread: Thread[tuple[st: ptr FFIReverseState, idx: int]]
    exited: Atomic[bool]
    busySinceNs*: Atomic[int64] # 0 when idle
    currentCall*: Atomic[uint64]
    stalled*: bool # event-thread-only latch for the liveness report

  ReverseWakeFn* = proc(ud: pointer) {.nimcall, gcsafe, raises: [].}
  ReverseGenerationFn* = proc(ud: pointer): uint {.nimcall, gcsafe, raises: [].}
  ReverseStopFn* = proc(st: var FFIReverseState): tuple[stopped, leaked: int] {.
    nimcall, gcsafe, raises: []
  .}

  FFIReverseState* = object
    lock*: Lock
    impls*: Table[string, FFIReverseImplEntry]
    dispatching*: int # invocations in flight on the worker threads
    dispatchDone*: Cond
    nextCallId*: Atomic[uint64] # never reused within a slot claim; ids start at 1
    mailbox: ptr ReverseReply # LIFO; replies are independent, order is irrelevant
    mailboxCount: int
    # Context hooks, installed by initContextResources; nil-safe.
    wakeFn*: ReverseWakeFn # fires the context's reqSignal (empty→non-empty mailbox)
    generationFn*: ReverseGenerationFn
    hookUd*: pointer # the FFIContext
    # Invocation queue (FFI thread produces, workers consume).
    qLock*: Lock
    qCond*: Cond
    qHead, qTail: ptr ReverseInvocation
    qCount: int
    stopping*: Atomic[bool]
    workers: ptr UncheckedArray[FFIReverseWorker] # c_malloc, nil until started
    workerCount*: int
    leakedWorkers*: int # workers that never exited at stop; their memory stays
    stopFn*: ReverseStopFn # installed by startReverseWorkers, nil otherwise

var reverseInDispatch {.threadvar.}: int
  # Dispatch depth of this thread, so an impl unregistering itself never waits
  # for its own invocation (mirrors ffiInDispatch in ffi_events).

proc nowNs(): int64 {.inline.} =
  getMonoTime().ticks

proc initReverseState*(st: var FFIReverseState) =
  ## Run once on the owning thread before sharing (re-initLock is UB).
  st.lock.initLock()
  st.dispatchDone.initCond()
  st.qLock.initLock()
  st.qCond.initCond()
  st.impls = initTable[string, FFIReverseImplEntry]()
  st.dispatching = 0
  st.nextCallId.store(0'u64)
  st.mailbox = nil
  st.mailboxCount = 0
  st.wakeFn = nil
  st.generationFn = nil
  st.hookUd = nil
  st.qHead = nil
  st.qTail = nil
  st.qCount = 0
  st.stopping.store(false)
  st.workers = nil
  st.workerCount = 0
  st.leakedWorkers = 0
  st.stopFn = nil

proc installContextHooks*(
    st: var FFIReverseState, wake: ReverseWakeFn, gen: ReverseGenerationFn, ud: pointer
) =
  st.wakeFn = wake
  st.generationFn = gen
  st.hookUd = ud

proc freeReply*(r: ptr ReverseReply) {.raises: [].} =
  if r.isNil():
    return
  if not r[].data.isNil():
    c_free(r[].data)
  c_free(r)

proc freeInvocation(r: ptr ReverseInvocation) {.raises: [].} =
  if r.isNil():
    return
  if not r[].name.isNil():
    c_free(cast[pointer](r[].name))
  if not r[].args.isNil():
    c_free(r[].args)
  c_free(r)

proc releaseInvocation*(r: ptr ReverseInvocation) {.raises: [].} =
  ## Drops one of the two owner references; the last one frees.
  if r.isNil():
    return
  if r[].refs.fetchSub(1) == 1:
    freeInvocation(r)

proc takeReplies*(st: var FFIReverseState): ptr ReverseReply {.raises: [], gcsafe.} =
  ## Detaches the whole mailbox; the caller walks the list and frees every node.
  withLock st.lock:
    result = st.mailbox
    st.mailbox = nil
    st.mailboxCount = 0

proc freeAllReplies*(st: var FFIReverseState) {.raises: [], gcsafe.} =
  var node = st.takeReplies()
  while not node.isNil():
    let next = node[].next
    freeReply(node)
    node = next

proc purgeQueue*(st: var FFIReverseState) {.raises: [], gcsafe.} =
  ## Frees every queued invocation. Their futures were failed (or are being
  ## failed) by the FFI thread; nothing is owed to anyone.
  var node: ptr ReverseInvocation
  withLock st.qLock:
    node = st.qHead
    st.qHead = nil
    st.qTail = nil
    st.qCount = 0
  while not node.isNil():
    let next = node[].next
    releaseInvocation(node)
    node = next

proc queueLen*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.qLock:
    return st.qCount

proc workersStarted*(st: var FFIReverseState): bool {.raises: [], gcsafe.} =
  withLock st.qLock:
    return st.workerCount > 0

proc deinitReverseState*(st: var FFIReverseState) =
  ## Mirror of `initReverseState`; resets GC fields so slot reuse sees no dtor.
  ## Workers must have been stopped (`stopReverseWorkers`); a stop that leaked a
  ## worker keeps the locks and the worker array alive for it.
  if not st.stopFn.isNil() and st.workerCount > 0:
    discard st.stopFn(st)
  st.purgeQueue()
  st.freeAllReplies()
  st.impls = default(Table[string, FFIReverseImplEntry])
  st.dispatching = 0
  if st.leakedWorkers > 0:
    return
  if not st.workers.isNil():
    c_free(st.workers)
    st.workers = nil
  st.qCond.deinitCond()
  st.qLock.deinitLock()
  st.dispatchDone.deinitCond()
  st.lock.deinitLock()

proc awaitReverseDispatch(st: var FFIReverseState) {.raises: [].} =
  ## Call with `st.lock` held.
  while st.dispatching > 0 and reverseInDispatch == 0:
    wait(st.dispatchDone, st.lock)

proc setImpl*(
    st: var FFIReverseState, name: string, fn: FFIReverseImpl, userData: pointer
) {.raises: [], gcsafe.} =
  ## Registers (or with `fn == nil` unregisters) the host implementation of
  ## `name`, replacing any previous one. Waits an in-flight invocation of the
  ## OLD impl out before returning, so the host may free the old userData as
  ## soon as this returns. A blocking old impl blocks this call for as long.
  withLock st.lock:
    if fn.isNil():
      st.impls.del(name)
    else:
      st.impls[name] = FFIReverseImplEntry(fn: fn, userData: userData)
    st.awaitReverseDispatch()

proc hasImpl*(st: var FFIReverseState, name: string): bool {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.impls.contains(name)

proc clearImpls*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  ## Removes all implementations without waiting; returns the invocations still
  ## running on workers. The recycle path polls `inFlight` with a deadline
  ## instead of blocking the FFI thread on a wedged host impl.
  withLock st.lock:
    st.impls.clear()
    return st.dispatching

proc inFlight*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.dispatching

proc beginReverseDispatch*(
    st: var FFIReverseState, name: string
): tuple[entry: FFIReverseImplEntry, found: bool] {.raises: [], gcsafe.} =
  ## Looks the impl up and, when found, counts the invocation in. The caller
  ## invokes the callback with the lock released and pairs every FOUND result
  ## with `endReverseDispatch`; a not-found result must not be paired.
  withLock st.lock:
    if not st.impls.contains(name):
      return (default(FFIReverseImplEntry), false)
    st.dispatching.inc()
    result = (st.impls.getOrDefault(name), true)
  reverseInDispatch.inc()

proc endReverseDispatch*(st: var FFIReverseState) {.raises: [], gcsafe.} =
  reverseInDispatch.dec()
  withLock st.lock:
    st.dispatching.dec()
    broadcast(st.dispatchDone)

proc allocCallId*(st: var FFIReverseState): uint64 {.raises: [].} =
  ## Monotonic within the slot's life; 0 is reserved as "invalid".
  st.nextCallId.fetchAdd(1'u64) + 1'u64

proc pushReply*(
    st: var FFIReverseState, callId: uint64, retCode: cint, data: pointer, dataLen: int
): cint {.raises: [], gcsafe.} =
  ## Copies the reply into a c_malloc node and parks it for the FFI thread,
  ## waking it only when the mailbox was empty (one wake per drain, not per
  ## reply). Callable from any thread. Returns a REVERSE_* status.
  let node = cast[ptr ReverseReply](c_malloc(csize_t(sizeof(ReverseReply))))
  if node.isNil():
    return REVERSE_MAILBOX_FULL
  node[].callId = callId
  node[].retCode = retCode
  node[].data = nil
  node[].dataLen = 0
  node[].next = nil
  if dataLen > 0 and not data.isNil():
    let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(dataLen)))
    if buf.isNil():
      c_free(node)
      return REVERSE_MAILBOX_FULL
    copyMem(buf, data, dataLen)
    node[].data = buf
    node[].dataLen = dataLen
  var wasEmpty = false
  withLock st.lock:
    if st.mailboxCount >= ReverseMailboxDepth:
      freeReply(node)
      return REVERSE_MAILBOX_FULL
    wasEmpty = st.mailboxCount == 0
    node[].next = st.mailbox
    st.mailbox = node
    st.mailboxCount.inc()
  if wasEmpty and not st.wakeFn.isNil():
    st.wakeFn(st.hookUd)
  REVERSE_ACCEPTED

proc mailboxLen*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.mailboxCount

## ── Invocation queue + worker pool ─────────────────────────────────────────

proc allocInvocation(
    callId: uint64, generation: uint, deadlineNs: int64, name: string, args: seq[byte]
): ptr ReverseInvocation {.raises: [].} =
  ## Nil when an allocation fails.
  let rec = cast[ptr ReverseInvocation](c_malloc(csize_t(sizeof(ReverseInvocation))))
  if rec.isNil():
    return nil
  rec[].refs.store(2) # queue/worker + FFI-thread pending entry
  rec[].callId = callId
  rec[].generation = generation
  rec[].deadlineNs = deadlineNs
  rec[].state.store(ReverseCallState.Pending)
  rec[].args = nil
  rec[].argsLen = 0
  rec[].next = nil
  let nameBuf = cast[ptr UncheckedArray[char]](c_malloc(csize_t(name.len + 1)))
  if nameBuf.isNil():
    c_free(rec)
    return nil
  if name.len > 0:
    copyMem(nameBuf, unsafeAddr name[0], name.len)
  nameBuf[name.len] = '\0'
  rec[].name = cast[cstring](nameBuf)
  if args.len > 0:
    let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(args.len)))
    if buf.isNil():
      freeInvocation(rec)
      return nil
    copyMem(buf, unsafeAddr args[0], args.len)
    rec[].args = buf
    rec[].argsLen = args.len
  rec

proc pushInvocation(
    st: var FFIReverseState, rec: ptr ReverseInvocation
) {.raises: [].} =
  withLock st.qLock:
    if st.qTail.isNil():
      st.qHead = rec
    else:
      st.qTail[].next = rec
    st.qTail = rec
    st.qCount.inc()
    signal(st.qCond)

proc popInvocation(st: var FFIReverseState): ptr ReverseInvocation {.raises: [].} =
  ## Blocks until a record is queued or `stopping` is set; nil means stop.
  withLock st.qLock:
    while st.qHead.isNil() and not st.stopping.load():
      wait(st.qCond, st.qLock)
    if st.qHead.isNil():
      return nil
    result = st.qHead
    st.qHead = result[].next
    if st.qHead.isNil():
      st.qTail = nil
    st.qCount.dec()
    result[].next = nil

proc cancelInvocation*(rec: ptr ReverseInvocation): bool {.raises: [].} =
  ## FFI thread: `Pending → Cancelled`. True when the call was still queued (it
  ## will be skipped); false when a worker already runs it (its late reply is
  ## dropped by id instead). Never frees: the queue owns the record.
  var expected = ReverseCallState.Pending
  rec[].state.compareExchange(expected, ReverseCallState.Cancelled)

proc runInvocation(
    st: var FFIReverseState, me: ptr FFIReverseWorker, rec: ptr ReverseInvocation
) =
  ## One dequeued record: skip when stale, expired or cancelled; otherwise claim
  ## it and run the host impl. Releases the queue's reference either way.
  defer:
    releaseInvocation(rec)
  if not st.generationFn.isNil() and rec[].generation != st.generationFn(st.hookUd):
    return
  if nowNs() > rec[].deadlineNs:
    # The FFI thread's timer may not have fired yet; the future fails there.
    var expected = ReverseCallState.Pending
    discard rec[].state.compareExchange(expected, ReverseCallState.Cancelled)
    return
  var expected = ReverseCallState.Pending
  if not rec[].state.compareExchange(expected, ReverseCallState.Running):
    return
  me[].currentCall.store(rec[].callId)
  me[].busySinceNs.store(nowNs())
  defer:
    me[].busySinceNs.store(0'i64)
    me[].currentCall.store(0'u64)
  let name = $rec[].name
  let (entry, found) = st.beginReverseDispatch(name)
  if not found:
    let msg = "host implementation for " & name & " was unregistered before dispatch"
    discard
      st.pushReply(rec[].callId, RET_ERR, cast[pointer](unsafeAddr msg[0]), msg.len)
    return
  defer:
    st.endReverseDispatch()
  foreignThreadGc:
    entry.fn(rec[].callId, rec[].args, csize_t(rec[].argsLen), entry.userData)

proc reverseWorkerBody(arg: tuple[st: ptr FFIReverseState, idx: int]) {.thread.} =
  let st = arg.st
  let me = addr st[].workers[arg.idx]
  defer:
    me[].exited.store(true)
  while true:
    let rec = st[].popInvocation()
    if rec.isNil():
      break
    try:
      st[].runInvocation(me, rec)
    except CatchableError:
      discard # the impl is cdecl raises: []; nothing else here can raise

proc stopReverseWorkers*(
    st: var FFIReverseState
): tuple[stopped, leaked: int] {.nimcall, gcsafe, raises: [].} =
  ## Explicit stop: purges the queue, wakes every worker, and joins each within
  ## `ReverseWorkerJoinTimeoutMs`. A worker still inside a host impl after that
  ## is leaked (its thread, the worker array and the locks stay alive) and
  ## counted in `leaked` / `st.leakedWorkers`. Idempotent.
  var count = 0
  withLock st.qLock:
    count = st.workerCount
    if count == 0:
      return (0, 0)
    st.stopping.store(true)
    broadcast(st.qCond)
  st.purgeQueue()
  var stopped = 0
  var leaked = 0
  for i in 0 ..< count:
    let w = addr st.workers[i]
    let deadline = nowNs() + int64(ReverseWorkerJoinTimeoutMs) * 1_000_000'i64
    while not w[].exited.load() and nowNs() < deadline:
      sleep(1)
    if w[].exited.load():
      joinThread(w[].thread)
      stopped.inc()
    else:
      leaked.inc()
  withLock st.qLock:
    st.workerCount = 0
    st.leakedWorkers += leaked
  if leaked == 0:
    c_free(st.workers)
    st.workers = nil
  (stopped, leaked)

proc startReverseWorkers*(st: var FFIReverseState, n: int = 0): bool {.raises: [].} =
  ## Starts `n` workers (≤ 0 → `ReverseWorkersDefault`); idempotent — a running
  ## pool keeps its size. False only when thread creation failed. Safe from any
  ## thread; the generated `set_impl` export calls it before registering.
  let count = if n <= 0: ReverseWorkersDefault else: n
  withLock st.qLock:
    if st.workerCount > 0 or st.leakedWorkers > 0:
      return st.workerCount > 0
    st.stopping.store(false)
    let bytes = csize_t(count * sizeof(FFIReverseWorker))
    st.workers = cast[ptr UncheckedArray[FFIReverseWorker]](c_malloc(bytes))
    if st.workers.isNil():
      return false
    zeroMem(st.workers, int(bytes))
    for i in 0 ..< count:
      st.workers[i].exited.store(false)
      st.workers[i].busySinceNs.store(0'i64)
      st.workers[i].currentCall.store(0'u64)
      st.workers[i].stalled = false
    var started = 0
    for i in 0 ..< count:
      try:
        createThread(st.workers[i].thread, reverseWorkerBody, (addr st, i))
        started.inc()
      except ValueError, ResourceExhaustedError:
        break
    if started == 0:
      c_free(st.workers)
      st.workers = nil
      return false
    st.workerCount = started
    st.stopFn = stopReverseWorkers
  true

proc scanReverseWorkers*(
    st: var FFIReverseState, stallNs: int64
): seq[tuple[idx: int, callId: uint64, blocked: bool]] {.raises: [], gcsafe.} =
  ## Event-thread liveness pass: reports each worker that just crossed
  ## `stallNs` inside one impl (blocked = true) or just came back (false).
  ## Each transition is reported once; `stalled` is this thread's latch.
  var count = 0
  withLock st.qLock:
    count = st.workerCount
  if count == 0 or st.workers.isNil():
    return @[]
  let now = nowNs()
  for i in 0 ..< count:
    let w = addr st.workers[i]
    let busy = w[].busySinceNs.load()
    if busy > 0 and now - busy > stallNs:
      if not w[].stalled:
        w[].stalled = true
        result.add((i, w[].currentCall.load(), true))
    elif w[].stalled and busy == 0:
      w[].stalled = false
      result.add((i, 0'u64, false))

## ── FFI-thread side: pending futures and the call helper ────────────────────
## The parked futures are refs and must never leave the FFI thread's heap, so
## the table is a threadvar; call-id lookup needs no lock.

var ffiCurrentReverseState* {.threadvar.}: ptr FFIReverseState
  # Installed by the FFI thread body, like ffiCurrentEventQueue.

type PendingReverse = object
  fut: Future[Result[seq[byte], string]]
  rec: ptr ReverseInvocation

var ffiPendingReverse {.threadvar.}: Table[uint64, PendingReverse]

proc ffiPendingReverseLen*(): int =
  ffiPendingReverse.len

proc drainReverseReplies*() {.gcsafe, raises: [].} =
  ## FFI thread only: completes the parked futures from the mailbox. A reply
  ## whose call-id is absent (timed out, cancelled, recycled, or bogus) is freed
  ## and dropped.
  let st = ffiCurrentReverseState
  if st.isNil():
    return
  var node = st[].takeReplies()
  while not node.isNil():
    let next = node[].next
    let pending = ffiPendingReverse.getOrDefault(node[].callId)
    let fut = pending.fut
    if not fut.isNil():
      ffiPendingReverse.del(node[].callId)
      releaseInvocation(pending.rec)
    if not fut.isNil() and not fut.finished():
      if node[].retCode == RET_OK:
        var bytes = newSeq[byte](node[].dataLen)
        if node[].dataLen > 0:
          copyMem(addr bytes[0], node[].data, node[].dataLen)
        fut.complete(Result[seq[byte], string].ok(bytes))
      else:
        var msg = newString(node[].dataLen)
        if node[].dataLen > 0:
          copyMem(addr msg[0], node[].data, node[].dataLen)
        if msg.len == 0:
          msg = "reverse call failed (host reported no message)"
        fut.complete(Result[seq[byte], string].err(msg))
    freeReply(node)
    node = next

proc failPendingReverse*(reason: string) {.gcsafe, raises: [].} =
  ## FFI thread only: fails every parked reverse call and cancels the queued
  ## ones, e.g. on recycle so a handler awaiting the host cannot hold the drain
  ## until its timeout and no queued call runs against the next owner.
  for _, p in ffiPendingReverse.mpairs:
    if not p.rec.isNil():
      discard cancelInvocation(p.rec)
      releaseInvocation(p.rec)
    if not p.fut.finished():
      p.fut.complete(Result[seq[byte], string].err(reason))
  ffiPendingReverse.clear()

proc abandonCall(callId: uint64) =
  ## Deadline or explicit cancel: a still-queued record is skipped by the worker
  ## that dequeues it; a running one keeps running and its reply is dropped.
  let p = ffiPendingReverse.getOrDefault(callId)
  if p.fut.isNil():
    return # already answered and drained
  if not p.rec.isNil():
    discard cancelInvocation(p.rec)
    releaseInvocation(p.rec)
  ffiPendingReverse.del(callId)

proc ffiReverseCall*(
    name: string, argsCbor: seq[byte], timeoutMs: int
): Future[Result[seq[byte], string]] {.async.} =
  ## FFI thread only (called by the `{.ffiReverse.}` generated stub): parks a
  ## future keyed by a fresh call-id, queues the invocation for the context's
  ## reverse workers and awaits the reply under `timeoutMs`. The FFI thread
  ## itself stays free. Cancelling the returned future (`cancelSoon`) cancels the
  ## queued invocation or, if it already runs, drops its eventual reply.
  let st = ffiCurrentReverseState
  if st.isNil():
    return err("reverse call " & name & " outside an FFI processing thread")
  if not st[].hasImpl(name):
    return err("no host implementation registered for " & name)
  if not st[].startReverseWorkers():
    return err("reverse workers could not be started for " & name)
  let generation =
    if st[].generationFn.isNil():
      0'u
    else:
      st[].generationFn(st[].hookUd)
  let callId = st[].allocCallId()
  let deadlineNs = nowNs() + int64(timeoutMs) * 1_000_000'i64
  let rec = allocInvocation(callId, generation, deadlineNs, name, argsCbor)
  if rec.isNil():
    return err("out of memory: could not queue reverse call " & name)
  let fut = newFuture[Result[seq[byte], string]]("ffiReverseCall")
  ffiPendingReverse[callId] = PendingReverse(fut: fut, rec: rec)
  st[].pushInvocation(rec)

  var completed = false
  try:
    completed = await fut.withTimeout(chronos.milliseconds(timeoutMs))
  except CancelledError as exc:
    abandonCall(callId)
    raise exc
  if not completed:
    abandonCall(callId)
    return err("reverse call " & name & " timed out after " & $timeoutMs & " ms")
  # `fut` is finished here, so this await just unwraps it.
  return await fut
