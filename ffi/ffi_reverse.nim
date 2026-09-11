## Reverse FFI runtime: host impls, the per-context worker pool and the reply mailbox.

import system/ansi_c
import std/[atomics, locks, monotimes, os, tables]
import chronos, results
import ./ffi_types

const ReverseMailboxDepth* {.intdefine: "ffiReverseMailboxDepth".} = 1024
  ## Replies parked between two FFI-thread drains; a full mailbox rejects the reply.

const ReverseCallTimeoutMs* {.intdefine: "ffiReverseCallTimeoutMs".} = 10000
  ## Default deadline of one `{.ffiReverse.}` call; `timeout = N` overrides it per proc.

const ReverseWorkersDefault* {.intdefine: "ffiReverseWorkers".} = 2

const ReverseWorkerStallMs* {.intdefine: "ffiReverseWorkerStallMs".} =
  ReverseCallTimeoutMs
  ## A worker inside one impl for longer emits `reverse_worker_blocked`.

const ReverseWorkerJoinTimeoutMs* {.intdefine: "ffiReverseWorkerJoinTimeoutMs".} = 1500

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
  discard

type FFIReverseImpl* = proc(
  callId: uint64,
  argsCbor: ptr UncheckedArray[byte],
  argsLen: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}
  ## Runs on a reverse worker and may block; answers through `<lib>_reverse_reply`.

type
  FFIReverseImplEntry* = object
    fn*: FFIReverseImpl
    userData*: pointer

  ReverseReply* = object
    callId*: uint64
    retCode*: cint
    data*: ptr UncheckedArray[byte] # c_malloc'd; freed by the draining thread
    dataLen*: int
    next*: ptr ReverseReply

  ReverseCallState* {.pure.} = enum
    Pending
    Running
    Cancelled

  ReverseInvocation* = object
    ## Two owners, the queue side and the FFI thread's pending entry; the last release frees.
    refs: Atomic[int]
    callId*: uint64
    generation*: uint
    deadlineNs*: int64
    state*: Atomic[ReverseCallState]
    name*: cstring
    args*: ptr UncheckedArray[byte]
    argsLen*: int
    next*: ptr ReverseInvocation

  ReverseWorkerArg = object
    st: ptr FFIReverseState
    idx: int

  FFIReverseWorker* = object
    thread: Thread[ReverseWorkerArg]
    exited: Atomic[bool]
    busySinceNs*: Atomic[int64] # 0 when idle
    currentCall*: Atomic[uint64]
    stalled*: bool # event thread only

  ReverseStopResult* = object
    stopped*: int
    leaked*: int

  ReverseDispatch* = object
    entry*: FFIReverseImplEntry
    found*: bool

  ReverseWorkerTransition* = object
    idx*: int
    callId*: uint64
    blocked*: bool

  ReverseWakeFn* = proc(ud: pointer) {.nimcall, gcsafe, raises: [].}
  ReverseGenerationFn* = proc(ud: pointer): uint {.nimcall, gcsafe, raises: [].}
  ReverseStopFn* = proc(st: var FFIReverseState, timeoutMs: int): ReverseStopResult {.
    nimcall, gcsafe, raises: []
  .}

  FFIReverseState* = object
    lock*: Lock
    impls*: Table[string, FFIReverseImplEntry]
    dispatching*: int # invocations in flight on the workers
    dispatchDone*: Cond
    nextCallId*: Atomic[uint64]
    mailbox: ptr ReverseReply # LIFO: replies are independent
    mailboxCount: int
    wakeFn*: ReverseWakeFn
    generationFn*: ReverseGenerationFn
    hookUd*: pointer # the FFIContext
    qLock*: Lock
    qCond*: Cond
    qHead, qTail: ptr ReverseInvocation
    qCount: int
    stopping*: Atomic[bool]
    workers: ptr UncheckedArray[FFIReverseWorker] # c_malloc'd, nil until started
    workerCount*: int
    leakedWorkers*: int # never joined: the worker array and the locks stay alive
    stopFn*: ReverseStopFn # nil until startReverseWorkers

var onReverseWorker* {.threadvar.}: bool
var myWorkerIdx {.threadvar.}: int # 1-based; 0 off a worker
var reverseInDispatch {.threadvar.}: int # lets an impl unregister itself

proc nowNs(): int64 =
  return getMonoTime().ticks

proc initReverseState*(st: var FFIReverseState) =
  ## Once, before any thread sees `st`: a second initLock is UB.
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
  if r.isNil():
    return

  if r[].refs.fetchSub(1) == 1:
    freeInvocation(r)

proc takeReplies*(st: var FFIReverseState): ptr ReverseReply {.raises: [], gcsafe.} =
  ## Detaches the mailbox; the caller frees every node.
  withLock st.lock:
    let head = st.mailbox
    st.mailbox = nil
    st.mailboxCount = 0
    return head

proc freeAllReplies*(st: var FFIReverseState) {.raises: [], gcsafe.} =
  var node = st.takeReplies()
  while not node.isNil():
    let next = node[].next
    freeReply(node)
    node = next

proc purgeQueue*(st: var FFIReverseState) {.raises: [], gcsafe.} =
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
  ## A stop that leaked a worker keeps the locks and the worker array alive for it.
  if not st.stopFn.isNil() and st.workerCount > 0:
    discard st.stopFn(st, ReverseWorkerJoinTimeoutMs)
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

proc startReverseWorkers*(
  st: var FFIReverseState, n: int = 0
): bool {.raises: [], gcsafe.}

proc setImpl*(
    st: var FFIReverseState, name: string, fn: FFIReverseImpl, userData: pointer
): bool {.discardable, raises: [], gcsafe.} =
  ## Waits out every in-flight invocation. False when the workers did not start.
  let started = fn.isNil() or st.startReverseWorkers()
  withLock st.lock:
    if fn.isNil():
      st.impls.del(name)
    else:
      st.impls[name] = FFIReverseImplEntry(fn: fn, userData: userData)
    st.awaitReverseDispatch()
  return started

proc hasImpl*(st: var FFIReverseState, name: string): bool {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.impls.contains(name)

proc clearImpls*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  ## Removes every impl without waiting; returns the invocations still running.
  withLock st.lock:
    st.impls.clear()
    return st.dispatching

proc inFlight*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.dispatching

proc beginReverseDispatch*(
    st: var FFIReverseState, name: string
): ReverseDispatch {.raises: [], gcsafe.} =
  ## Pair every found dispatch with `endReverseDispatch`.
  withLock st.lock:
    if not st.impls.contains(name):
      return ReverseDispatch(found: false)

    st.dispatching.inc()
    reverseInDispatch.inc()
    return ReverseDispatch(entry: st.impls.getOrDefault(name), found: true)

proc endReverseDispatch*(st: var FFIReverseState) {.raises: [], gcsafe.} =
  reverseInDispatch.dec()
  withLock st.lock:
    st.dispatching.dec()
    broadcast(st.dispatchDone)

proc allocCallId*(st: var FFIReverseState): uint64 {.raises: [].} =
  ## Monotonic for the life of the slot; 0 is the invalid id.
  return st.nextCallId.fetchAdd(1'u64) + 1'u64

proc pushReply*(
    st: var FFIReverseState, callId: uint64, retCode: cint, data: pointer, dataLen: int
): cint {.raises: [], gcsafe.} =
  ## Any thread. Wakes the FFI thread only when the mailbox was empty.
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
  return REVERSE_ACCEPTED

proc mailboxLen*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.mailboxCount

proc allocInvocation(
    callId: uint64, generation: uint, deadlineNs: int64, name: string, args: seq[byte]
): ptr ReverseInvocation {.raises: [].} =
  ## Nil when an allocation fails.
  let rec = cast[ptr ReverseInvocation](c_malloc(csize_t(sizeof(ReverseInvocation))))
  if rec.isNil():
    return nil

  rec[].refs.store(2)
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
  return rec

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

    let rec = st.qHead
    st.qHead = rec[].next
    if st.qHead.isNil():
      st.qTail = nil
    st.qCount.dec()
    rec[].next = nil
    return rec

proc cancelInvocation*(rec: ptr ReverseInvocation): bool {.raises: [].} =
  ## FFI thread: false when a worker already runs the call, so its reply is dropped by id.
  var expected = ReverseCallState.Pending
  return rec[].state.compareExchange(expected, ReverseCallState.Cancelled)

proc runInvocation(
    st: var FFIReverseState, me: ptr FFIReverseWorker, rec: ptr ReverseInvocation
) {.raises: [].} =
  ## Skips a stale, expired or cancelled record; releases the queue's reference either way.
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
  let dispatch = st.beginReverseDispatch(name)
  if not dispatch.found:
    let msg = "host implementation for " & name & " was unregistered before dispatch"
    discard
      st.pushReply(rec[].callId, RET_ERR, cast[pointer](unsafeAddr msg[0]), msg.len)
    return

  defer:
    st.endReverseDispatch()
  foreignThreadGc:
    dispatch.entry.fn(
      rec[].callId, rec[].args, csize_t(rec[].argsLen), dispatch.entry.userData
    )

proc reverseWorkerBody(arg: ReverseWorkerArg) {.thread.} =
  let st = arg.st
  let me = addr st[].workers[arg.idx]
  onReverseWorker = true
  myWorkerIdx = arg.idx + 1
  defer:
    onReverseWorker = false
    myWorkerIdx = 0
    me[].exited.store(true)

  while true:
    let rec = st[].popInvocation()
    if rec.isNil():
      break
    st[].runInvocation(me, rec)

proc stopReverseWorkers*(
    st: var FFIReverseState, timeoutMs: int = ReverseWorkerJoinTimeoutMs
): ReverseStopResult {.nimcall, gcsafe, raises: [].} =
  ## Idempotent. Joins each worker within `timeoutMs`; one still inside an impl leaks.
  var count = 0
  withLock st.qLock:
    count = st.workerCount
    if count == 0:
      return ReverseStopResult()
    st.stopping.store(true)
    broadcast(st.qCond)
  st.purgeQueue()

  var stopped = 0
  var leaked = 0
  for i in 0 ..< count:
    let w = addr st.workers[i]
    if onReverseWorker and myWorkerIdx == i + 1:
      # A host impl called a teardown export on this worker: a self-join would hang.
      leaked.inc()
      continue
    let deadline = nowNs() + int64(max(timeoutMs, 0)) * 1_000_000'i64
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
  return ReverseStopResult(stopped: stopped, leaked: leaked)

proc startReverseWorkers*(
    st: var FFIReverseState, n: int = 0
): bool {.raises: [], gcsafe.} =
  ## Idempotent: a running pool keeps its size. `n <= 0` starts `ReverseWorkersDefault`.
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
        createThread(
          st.workers[i].thread, reverseWorkerBody, ReverseWorkerArg(st: addr st, idx: i)
        )
        started.inc()
      except ValueError, ResourceExhaustedError:
        break
    if started == 0:
      c_free(st.workers)
      st.workers = nil
      return false

    st.workerCount = started
    st.stopFn = stopReverseWorkers
  return true

proc scanReverseWorkers*(
    st: var FFIReverseState, stallNs: int64
): seq[ReverseWorkerTransition] {.raises: [], gcsafe.} =
  ## Event thread only: reports once each worker that just stalled or just recovered.
  var count = 0
  withLock st.qLock:
    count = st.workerCount
  if count == 0 or st.workers.isNil():
    return @[]

  var transitions: seq[ReverseWorkerTransition] = @[]
  let now = nowNs()
  for i in 0 ..< count:
    let w = addr st.workers[i]
    let busy = w[].busySinceNs.load()
    if busy > 0 and now - busy > stallNs:
      if not w[].stalled:
        w[].stalled = true
        transitions.add(
          ReverseWorkerTransition(idx: i, callId: w[].currentCall.load(), blocked: true)
        )
    elif w[].stalled and busy == 0:
      w[].stalled = false
      transitions.add(ReverseWorkerTransition(idx: i, blocked: false))
  return transitions

var ffiCurrentReverseState* {.threadvar.}: ptr FFIReverseState

type PendingReverse = object
  fut: Future[Result[seq[byte], string]]
  rec: ptr ReverseInvocation

var ffiPendingReverse {.threadvar.}: Table[uint64, PendingReverse]
  # The futures live on the FFI thread's heap, so the table never leaves that thread.

proc ffiPendingReverseLen*(): int =
  return ffiPendingReverse.len

proc drainReverseReplies*() {.gcsafe, raises: [].} =
  ## FFI thread only: completes parked futures; a reply with an unknown call id is dropped.
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
  ## FFI thread only: fails every parked call and cancels its queued invocation.
  for _, p in ffiPendingReverse.mpairs:
    if not p.rec.isNil():
      discard cancelInvocation(p.rec)
      releaseInvocation(p.rec)
    if not p.fut.finished():
      p.fut.complete(Result[seq[byte], string].err(reason))
  ffiPendingReverse.clear()

proc abandonCall(callId: uint64) =
  let p = ffiPendingReverse.getOrDefault(callId)
  if p.fut.isNil():
    return

  if not p.rec.isNil():
    discard cancelInvocation(p.rec)
    releaseInvocation(p.rec)
  ffiPendingReverse.del(callId)

proc ffiReverseCall*(
    name: string, argsCbor: seq[byte], timeoutMs: int
): Future[Result[seq[byte], string]] {.async.} =
  ## FFI thread only: queues the call for the workers and awaits the reply under `timeoutMs`.
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
  except CancelledError as e:
    abandonCall(callId)
    raise e
  if not completed:
    abandonCall(callId)
    return err("reverse call " & name & " timed out after " & $timeoutMs & " ms")

  return await fut
