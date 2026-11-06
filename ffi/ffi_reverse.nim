## Reverse FFI runtime: host impls, the per-context worker pool and the reply mailbox.

import system/ansi_c
import std/[atomics, locks, monotimes, os, strutils, tables]
import chronos, results
import ./ffi_types

const ReverseMailboxDepth* {.intdefine: "ffiReverseMailboxDepth".} = 1024
  ## Replies parked between two FFI-thread drains; past it a reply is refused.

const ReverseQueueDepth* {.intdefine: "ffiReverseQueueDepth".} = 1024
  ## Calls waiting for a free reverse worker; a call past it fails at once.

const ReverseCallTimeoutMs* {.intdefine: "ffiReverseCallTimeoutMs".} = 10000
  ## Default deadline of a `{.ffiReverse.}` call; `timeout = <ms>` overrides it per proc.

const ReverseWorkersDefault* {.intdefine: "ffiReverseWorkers".} = 1
  ## Reverse workers per context, started by the first `registerImpl`.

const ReverseWorkerStallMs* = ReverseCallTimeoutMs
  ## A worker inside one impl for longer emits `reverse_worker_blocked`.

const ReverseWorkerJoinTimeoutMs* {.intdefine: "ffiReverseWorkerJoinTimeoutMs".} = 1500
  ## Join wait per worker at stop; a worker still running then is leaked.

static:
  doAssert ReverseWorkersDefault >= 1, "-d:ffiReverseWorkers must be at least 1"
  doAssert ReverseMailboxDepth >= 1, "-d:ffiReverseMailboxDepth must be at least 1"
  doAssert ReverseQueueDepth >= 1, "-d:ffiReverseQueueDepth must be at least 1"
  doAssert ReverseCallTimeoutMs > 0, "-d:ffiReverseCallTimeoutMs must be positive"

proc ffiNoopCallback*(
    callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

type FFIReverseImpl* = proc(
  ctx: pointer,
  callId: uint64,
  args: ptr UncheckedArray[byte],
  argsLen: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}
  ## Runs on a reverse worker, may block; reply with `ctx` via `<lib>_reverse_reply`.

type FFIReverseRelease* = proc(userData: pointer) {.cdecl, gcsafe, raises: [].}
  ## Frees an impl's `userData`, on whichever thread drops the last reference.

type
  ReverseImplEntry* = object
    ## c_malloc'd; refs: one for the registry, one per running dispatch.
    refs: Atomic[int]
    fn*: FFIReverseImpl
    userData*: pointer
    release: FFIReverseRelease

  ReverseReply* = object
    callId*: uint64
    retCode*: cint
    data*: ptr UncheckedArray[byte] # nil, or the bytes right after the node
    dataLen*: int
    next*: ptr ReverseReply

  ReverseCallState* {.pure.} = enum
    Pending ## queued; a worker may still claim it, the FFI thread may still cancel it
    Running ## a worker claimed it; the reply, if any, is dropped by id once abandoned
    Cancelled ## deadline or explicit cancel won the race; skipped at dequeue

  ReverseInvocation* = object
    ## Two owners, the queue side and the FFI thread's pending entry; the last release frees.
    refs: Atomic[int]
    callId*: uint64
    generation*: uint
    token*: pointer # the calling owner's context token, handed to the impl
    deadlineNs*: int64
    state*: Atomic[ReverseCallState]
    implId*: int
    name*: cstring # the macro's wire-name literal: static, never freed
    args*: ptr UncheckedArray[byte]
    argsLen*: int
    next*: ptr ReverseInvocation

  ReverseWorkerArg = object
    st: ptr FFIReverseContext
    me: ptr FFIReverseWorker # fixed at creation: a claimed stop clears `st.workers`
    idx: int

  FFIReverseWorker* = object
    thread: Thread[ReverseWorkerArg]
    exited: Atomic[bool]
    busySinceNs*: Atomic[int64] # 0 when idle
    currentCall*: Atomic[uint64]
    currentName*: Atomic[pointer] # static cstring of the running call, nil when idle
    stalled*: bool # event thread only

  ReverseStopResult* = object
    stopped*: int
    leaked*: int

  ReverseWorkerTransition* = object
    idx*: int
    callId*: uint64
    procName*: string
    elapsedMs*: int64
    blocked*: bool

  ReverseCallTimeout* = object
    ## A reverse call that failed unanswered: `reason` is "timeout" or "queue_full".
    callId*: uint64
    procName*: string
    elapsedMs*: int64
    timeoutMs*: int64
    reason*: string

  ReverseWakeFn* = proc(ud: pointer) {.nimcall, gcsafe, raises: [].}
  ReverseGenerationFn* = proc(ud: pointer): uint {.nimcall, gcsafe, raises: [].}
  ReverseTokenFn* = proc(ud: pointer): pointer {.nimcall, gcsafe, raises: [].}
  ReverseTimeoutFn* =
    proc(ud: pointer, ev: ReverseCallTimeout) {.nimcall, gcsafe, raises: [].}

  ReverseContextHooks = object
    wake: ReverseWakeFn
    generation: ReverseGenerationFn
    token: ReverseTokenFn
    timeout: ReverseTimeoutFn
    ffiCtx: pointer

  ReverseMailbox = object ## FIFO of host replies: the first reply for a call id wins
    head, tail: ptr ReverseReply
    count: int

  ReverseStopFn* = proc(st: var FFIReverseContext, timeoutMs: int): ReverseStopResult {.
    nimcall, gcsafe, raises: []
  .}

  FFIReverseContext* = object
    lock*: Lock
    impls: ptr UncheckedArray[ptr ReverseImplEntry] # c_malloc'd, indexed by impl id
    implCap: int
    dispatching*: int # invocations in flight on the workers
    nextCallId*: Atomic[uint64]
    mailbox: ReverseMailbox
    hooks: ReverseContextHooks
    qLock*: Lock
    qCond*: Cond
    qHead, qTail: ptr ReverseInvocation
    qCount: int
    stopping*: Atomic[bool]
    stopClaimed: bool # a stop is joining the workers; a start must not race it
    closing*: Atomic[bool] # recycle or shutdown began: new reverse calls fail fast
    workers: ptr UncheckedArray[FFIReverseWorker] # c_malloc'd, nil until started
    workerCount*: int
    leakedWorkers*: int
      ## Never decremented: a leaked worker may still run, so the worker array and the
      ## locks stay alive for the life of the slot, and no new pool starts.
    stopFn*: ReverseStopFn # nil until startReverseWorkers

var onReverseWorker* {.threadvar.}: bool
var myWorkerIdx {.threadvar.}: int # 1-based; 0 off a worker
var myReverseState {.threadvar.}: ptr FFIReverseContext # nil off a worker

proc ownsReverseWorker*(st: var FFIReverseContext): bool {.raises: [], gcsafe.} =
  ## True on a reverse worker of `st`: a teardown of its context from here waits on itself.
  return onReverseWorker and myReverseState == addr(st)

proc nowNs(): int64 =
  return getMonoTime().ticks

proc initReverseContext*(st: var FFIReverseContext) =
  ## Once, before any thread sees `st`: a second initLock is UB.
  st = FFIReverseContext()
  st.lock.initLock()
  st.qLock.initLock()
  st.qCond.initCond()

func installContextHooks*(
    st: var FFIReverseContext,
    wake: ReverseWakeFn,
    gen: ReverseGenerationFn,
    ud: pointer,
    token: ReverseTokenFn = nil,
    timeout: ReverseTimeoutFn = nil,
) {.raises: [].} =
  st.hooks = ReverseContextHooks(
    wake: wake, generation: gen, token: token, timeout: timeout, ffiCtx: ud
  )

proc freeReply*(r: ptr ReverseReply) {.raises: [].} =
  c_free(r)

proc free(r: ptr ReverseInvocation) {.raises: [].} =
  if r.isNil():
    return

  if not r[].args.isNil():
    c_free(r[].args)
  c_free(r)

proc decRef*(r: ptr ReverseInvocation) {.raises: [].} =
  if r.isNil():
    return

  if r[].refs.fetchSub(1) == 1:
    free(r)

proc takeReplies*(st: var FFIReverseContext): ptr ReverseReply {.raises: [], gcsafe.} =
  ## Detaches the mailbox; the caller frees every node.
  withLock st.lock:
    let head = st.mailbox.head
    st.mailbox = ReverseMailbox()
    return head

proc freeAllReplies*(st: var FFIReverseContext) {.raises: [], gcsafe.} =
  var node = st.takeReplies()
  while not node.isNil():
    let next = node[].next
    freeReply(node)
    node = next

proc purgeQueue*(st: var FFIReverseContext) {.raises: [], gcsafe.} =
  var node: ptr ReverseInvocation
  withLock st.qLock:
    node = st.qHead
    st.qHead = nil
    st.qTail = nil
    st.qCount = 0

  while not node.isNil():
    let next = node[].next
    decRef(node)
    node = next

proc queueLen*(st: var FFIReverseContext): int {.raises: [], gcsafe.} =
  withLock st.qLock:
    return st.qCount

proc workersStarted*(st: var FFIReverseContext): bool {.raises: [], gcsafe.} =
  withLock st.qLock:
    return st.workerCount > 0

proc free(e: ptr ReverseImplEntry) {.raises: [], gcsafe.} =
  ## Calls the host's `release`, then frees the entry.
  if not e[].release.isNil():
    e[].release(e[].userData)
  c_free(e)

proc decRef(e: ptr ReverseImplEntry) {.raises: [], gcsafe.} =
  ## Drops one reference; the last one hands `userData` back to the host.
  if e.isNil():
    return

  if e[].refs.fetchSub(1) == 1:
    free(e)

func entryAt(st: FFIReverseContext, id: int): ptr ReverseImplEntry {.raises: [].} =
  ## Call with `st.lock` held; nil when `id` has no impl.
  if id < 0 or id >= st.implCap:
    return nil
  return st.impls[id]

proc reserve(st: var FFIReverseContext, id: int): bool {.raises: [].} =
  ## Call with `st.lock` held: grows the registry to hold `id`; false when out of memory.
  if id < st.implCap:
    return true
  let cap = max(id + 1, 2 * st.implCap)
  let grown = cast[ptr UncheckedArray[ptr ReverseImplEntry]](c_realloc(
    st.impls, csize_t(cap * sizeof(pointer))
  ))
  if grown.isNil():
    return false
  zeroMem(addr grown[st.implCap], (cap - st.implCap) * sizeof(pointer))
  st.impls = grown
  st.implCap = cap
  return true

proc clearImpls*(st: var FFIReverseContext): int {.raises: [], gcsafe.} =
  ## Unregisters every impl without waiting; returns the invocations still running,
  ## which keep their entry until they return.
  var old: ptr UncheckedArray[ptr ReverseImplEntry]
  var oldCap = 0
  var running = 0
  withLock st.lock:
    swap(old, st.impls)
    swap(oldCap, st.implCap)
    running = st.dispatching
  for i in 0 ..< oldCap:
    decRef(old[i])
  if not old.isNil():
    c_free(old)
  return running

proc deinitReverseContext*(st: var FFIReverseContext): Result[void, string] =
  ## Err, keeping the locks and the worker array alive, while a leaked worker or a
  ## running impl may still take them.
  if not st.stopFn.isNil() and st.workerCount > 0:
    # A worker that does not exit in time is counted in `leakedWorkers`.
    discard st.stopFn(st, ReverseWorkerJoinTimeoutMs)
  st.purgeQueue()
  st.freeAllReplies()
  let running = st.clearImpls()
  if st.leakedWorkers > 0 or running > 0:
    return err(
      "reverse context kept alive: " & $st.leakedWorkers & " leaked worker(s), " &
        $running & " impl(s) still running"
    )

  if not st.workers.isNil():
    c_free(st.workers)
    st.workers = nil
  st.qCond.deinitCond()
  st.qLock.deinitLock()
  st.lock.deinitLock()
  return ok()

proc startReverseWorkers*(
  st: var FFIReverseContext, n: int = 0
): bool {.raises: [], gcsafe.}

type ReverseError* {.pure.} = enum
  OutOfMemory
  InvalidArgument
  WorkersFailed

func toRetCode*(e: ReverseError): cint =
  ## The `RET_*` status a C export returns for `e`.
  case e
  of ReverseError.OutOfMemory: RET_OUT_OF_MEMORY
  of ReverseError.InvalidArgument: RET_INVALID_ARGUMENT
  of ReverseError.WorkersFailed: RET_WORKERS_FAILED

proc registerImpl*(
    st: var FFIReverseContext,
    id: int,
    fn: FFIReverseImpl,
    userData: pointer,
    release: FFIReverseRelease = nil,
): Result[void, ReverseError] {.raises: [], gcsafe.} =
  ## Sets the impl of `{.ffiReverse.}` proc `id`, replacing any. Never waits.
  ##
  ## With a `release`, Nim owns `userData` and releases it after the replaced impl's
  ## last running call. With nil, the host keeps `userData` valid until the context
  ## is destroyed. On an error the caller keeps `userData`; `release` never runs.
  if fn.isNil() or id < 0: # a nil impl unregisters: use unregisterImpl
    return err(ReverseError.InvalidArgument)
  if not st.startReverseWorkers():
    return err(ReverseError.WorkersFailed)
  let fresh = cast[ptr ReverseImplEntry](c_malloc(csize_t(sizeof(ReverseImplEntry))))
  if fresh.isNil():
    return err(ReverseError.OutOfMemory)
  fresh[].refs.store(1)
  fresh[].fn = fn
  fresh[].userData = userData
  fresh[].release = release

  var old: ptr ReverseImplEntry = nil
  withLock st.lock:
    if not st.reserve(id):
      c_free(fresh) # never published, so its release must not run
      return err(ReverseError.OutOfMemory)
    old = st.impls[id]
    st.impls[id] = fresh
  decRef(old)
  return ok()

proc unregisterImpl*(st: var FFIReverseContext, id: int) {.raises: [], gcsafe.} =
  ## Removes the impl of `id`, if any. Never waits: a running call keeps its entry.
  var old: ptr ReverseImplEntry = nil
  withLock st.lock:
    old = st.entryAt(id)
    if not old.isNil():
      st.impls[id] = nil
  decRef(old)

proc isRegistered*(st: var FFIReverseContext, id: int): bool {.raises: [], gcsafe.} =
  withLock st.lock:
    return not st.entryAt(id).isNil()

proc inFlight*(st: var FFIReverseContext): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.dispatching

proc beginReverseDispatch*(
    st: var FFIReverseContext, id: int
): ptr ReverseImplEntry {.raises: [], gcsafe.} =
  ## Nil when `id` has no impl; pair every other result with `endReverseDispatch`.
  withLock st.lock:
    let entry = st.entryAt(id)
    if entry.isNil():
      return nil

    discard entry[].refs.fetchAdd(1)
    st.dispatching.inc()
    return entry

proc endReverseDispatch*(
    st: var FFIReverseContext, entry: ptr ReverseImplEntry
) {.raises: [], gcsafe.} =
  # Release first: the call stays in flight until the host's `release` returns.
  decRef(entry)
  withLock st.lock:
    st.dispatching.dec()

proc allocCallId*(st: var FFIReverseContext): uint64 {.raises: [].} =
  ## Monotonic for the life of the slot; 0 is the invalid id.
  return st.nextCallId.fetchAdd(1'u64) + 1'u64

proc pushReply*(
    st: var FFIReverseContext,
    callId: uint64,
    retCode: cint,
    data: pointer,
    dataLen: int,
): cint {.raises: [], gcsafe.} =
  ## Any thread. Wakes the FFI thread only when the mailbox was empty.
  let payloadLen = if dataLen > 0 and not data.isNil(): dataLen else: 0
  let node =
    cast[ptr ReverseReply](c_malloc(csize_t(sizeof(ReverseReply) + payloadLen)))
  if node.isNil():
    return RET_OUT_OF_MEMORY

  node[].callId = callId
  node[].retCode = retCode
  node[].data = nil
  node[].dataLen = payloadLen
  node[].next = nil
  if payloadLen > 0:
    node[].data =
      cast[ptr UncheckedArray[byte]](cast[uint](node) + uint(sizeof(ReverseReply)))
    copyMem(node[].data, data, payloadLen)

  var wasEmpty = false
  withLock st.lock:
    if st.mailbox.count >= ReverseMailboxDepth:
      freeReply(node)
      return RET_QUEUE_FULL
    wasEmpty = st.mailbox.head.isNil()
    if wasEmpty:
      st.mailbox.head = node
    else:
      st.mailbox.tail[].next = node
    st.mailbox.tail = node
    st.mailbox.count.inc()

  if wasEmpty and not st.hooks.wake.isNil():
    st.hooks.wake(st.hooks.ffiCtx)
  return RET_OK

proc mailboxLen*(st: var FFIReverseContext): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.mailbox.count

proc allocInvocation(
    callId: uint64,
    generation: uint,
    token: pointer,
    deadlineNs: int64,
    implId: int,
    name: cstring,
    args: seq[byte],
): ptr ReverseInvocation {.raises: [].} =
  ## Nil when an allocation fails.
  let rec = cast[ptr ReverseInvocation](c_malloc(csize_t(sizeof(ReverseInvocation))))
  if rec.isNil():
    return nil

  rec[].refs.store(2)
  rec[].callId = callId
  rec[].generation = generation
  rec[].token = token
  rec[].deadlineNs = deadlineNs
  rec[].state.store(ReverseCallState.Pending)
  rec[].args = nil
  rec[].argsLen = 0
  rec[].next = nil
  rec[].implId = implId
  rec[].name = name

  if args.len > 0:
    let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(args.len)))
    if buf.isNil():
      free(rec)
      return nil
    copyMem(buf, unsafeAddr args[0], args.len)
    rec[].args = buf
    rec[].argsLen = args.len
  return rec

proc pushInvocation(
    st: var FFIReverseContext, rec: ptr ReverseInvocation
): bool {.raises: [].} =
  ## False, not queuing `rec`, when the pool is stopping or `ReverseQueueDepth` calls wait.
  withLock st.qLock:
    if st.stopping.load() or st.qCount >= ReverseQueueDepth:
      return false
    if st.qTail.isNil():
      st.qHead = rec
    else:
      st.qTail[].next = rec
    st.qTail = rec
    st.qCount.inc()
    signal(st.qCond)
  return true

proc popInvocation(st: var FFIReverseContext): ptr ReverseInvocation {.raises: [].} =
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
    st: var FFIReverseContext, me: ptr FFIReverseWorker, rec: ptr ReverseInvocation
) {.raises: [].} =
  ## Skips a stale, expired or cancelled record; releases the queue's reference either way.
  defer:
    decRef(rec)
  if not st.hooks.generation.isNil() and
      rec[].generation != st.hooks.generation(st.hooks.ffiCtx):
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
  me[].currentName.store(cast[pointer](rec[].name))
  me[].busySinceNs.store(nowNs())
  let entry = st.beginReverseDispatch(rec[].implId)
  # One defer, idle first: once `inFlight()` reads 0, the worker already reads idle.
  defer:
    me[].busySinceNs.store(0'i64)
    me[].currentName.store(nil)
    me[].currentCall.store(0'u64)
    if not entry.isNil():
      st.endReverseDispatch(entry)

  if entry.isNil():
    let msg =
      "host implementation for " & $rec[].name & " was unregistered before dispatch"
    discard
      st.pushReply(rec[].callId, RET_ERR, cast[pointer](unsafeAddr msg[0]), msg.len)
    return

  foreignThreadGc:
    entry[].fn(
      rec[].token, rec[].callId, rec[].args, csize_t(rec[].argsLen), entry[].userData
    )

proc reverseWorkerBody(arg: ReverseWorkerArg) {.thread.} =
  let st = arg.st
  let me = arg.me
  onReverseWorker = true
  myWorkerIdx = arg.idx + 1
  myReverseState = st
  defer:
    onReverseWorker = false
    myWorkerIdx = 0
    myReverseState = nil
    me[].exited.store(true)

  while true:
    let rec = st[].popInvocation()
    if rec.isNil():
      break
    st[].runInvocation(me, rec)

proc stopReverseWorkers*(
    st: var FFIReverseContext, timeoutMs: int = ReverseWorkerJoinTimeoutMs
): ReverseStopResult {.nimcall, gcsafe, raises: [].} =
  ## Idempotent. The caller that claims the pool joins it within one `timeoutMs`; a
  ## worker still inside an impl then leaks. A concurrent second call returns empty.
  var count = 0
  var workers: ptr UncheckedArray[FFIReverseWorker]
  withLock st.qLock:
    count = st.workerCount
    if count == 0:
      return ReverseStopResult()
    # The claim: a second stopper, or a start, now sees no running pool.
    workers = st.workers
    st.workerCount = 0
    st.workers = nil
    st.stopClaimed = true
    st.stopping.store(true)
    broadcast(st.qCond)
  st.purgeQueue()

  var stopped = 0
  var leaked = 0
  let deadline = nowNs() + int64(max(timeoutMs, 0)) * 1_000_000'i64
  for i in 0 ..< count:
    let w = addr workers[i]
    if st.ownsReverseWorker() and myWorkerIdx == i + 1:
      # A host impl called a teardown export on this worker: a self-join would hang.
      leaked.inc()
      continue
    while not w[].exited.load() and nowNs() < deadline:
      sleep(1)
    if w[].exited.load():
      joinThread(w[].thread)
      stopped.inc()
    else:
      leaked.inc()

  if leaked == 0:
    c_free(workers)
  withLock st.qLock:
    st.leakedWorkers += leaked
    st.stopClaimed = false
  return ReverseStopResult(stopped: stopped, leaked: leaked)

proc startReverseWorkers*(
    st: var FFIReverseContext, n: int = 0
): bool {.raises: [], gcsafe.} =
  ## Idempotent: a running pool keeps its size. `n <= 0` starts `ReverseWorkersDefault`.
  let count = if n <= 0: ReverseWorkersDefault else: n
  withLock st.qLock:
    if st.workerCount > 0 or st.leakedWorkers > 0 or st.stopClaimed:
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
      st.workers[i].currentName.store(nil)
      st.workers[i].stalled = false

    var started = 0
    for i in 0 ..< count:
      try:
        createThread(
          st.workers[i].thread,
          reverseWorkerBody,
          ReverseWorkerArg(st: addr st, me: addr st.workers[i], idx: i),
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
    st: var FFIReverseContext, stallNs: int64
): seq[ReverseWorkerTransition] {.raises: [], gcsafe.} =
  ## Event thread only: reports once each worker that just stalled or just recovered.
  ## Holds `qLock` throughout: a stop claims the pool under it, so the worker array
  ## cannot be freed during the scan.
  var transitions: seq[ReverseWorkerTransition] = @[]
  withLock st.qLock:
    if st.workers.isNil():
      return transitions
    let now = nowNs()
    for i in 0 ..< st.workerCount:
      let w = addr st.workers[i]
      let busy = w[].busySinceNs.load()
      if busy > 0 and now - busy > stallNs:
        if not w[].stalled:
          w[].stalled = true
          transitions.add(
            ReverseWorkerTransition(
              idx: i,
              callId: w[].currentCall.load(),
              procName: $cast[cstring](w[].currentName.load()),
              elapsedMs: (now - busy) div 1_000_000,
              blocked: true,
            )
          )
      elif w[].stalled and busy == 0:
        w[].stalled = false
        transitions.add(ReverseWorkerTransition(idx: i, blocked: false))
  return transitions

proc busySummary(st: var FFIReverseContext): string {.raises: [].} =
  ## Which procs hold the workers, and for how long: the root cause of a full queue.
  let now = nowNs()
  var parts: seq[string] = @[]
  withLock st.qLock:
    for i in 0 ..< st.workerCount:
      let busy = st.workers[i].busySinceNs.load()
      if busy > 0:
        parts.add(
          "worker " & $i & " in " & $cast[cstring](st.workers[i].currentName.load()) &
            " for " & $((now - busy) div 1_000_000) & " ms"
        )
  if parts.len == 0:
    return "no worker busy"
  return parts.join(", ")

var ffiCurrentReverseContext* {.threadvar.}: ptr FFIReverseContext

type PendingReverse = object
  fut: Future[Result[seq[byte], string]]
  rec: ptr ReverseInvocation

var ffiPendingReverse {.threadvar.}: Table[uint64, PendingReverse]
  # The futures live on the FFI thread's heap, so the table never leaves that thread.

proc ffiPendingReverseLen*(): int =
  return ffiPendingReverse.len

proc drainReverseReplies*() {.gcsafe, raises: [].} =
  ## FFI thread only: completes parked futures; a reply with an unknown call id is dropped.
  let st = ffiCurrentReverseContext
  if st.isNil():
    return

  var node = st[].takeReplies()
  while not node.isNil():
    let next = node[].next
    let pending = ffiPendingReverse.getOrDefault(node[].callId)
    let fut = pending.fut
    if not fut.isNil():
      ffiPendingReverse.del(node[].callId)
      decRef(pending.rec)
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
      decRef(p.rec)
    if not p.fut.finished():
      p.fut.complete(Result[seq[byte], string].err(reason))
  ffiPendingReverse.clear()

proc abandonCall(callId: uint64) =
  let p = ffiPendingReverse.getOrDefault(callId)
  if p.fut.isNil():
    return

  if not p.rec.isNil():
    discard cancelInvocation(p.rec)
    decRef(p.rec)
  ffiPendingReverse.del(callId)

proc reportTimeout(
    st: var FFIReverseContext,
    callId: uint64,
    name: cstring,
    elapsedMs, timeoutMs: int64,
    reason: string,
) {.raises: [].} =
  ## FFI thread: hands a call that failed unanswered to the context, which logs it and
  ## emits `reverse_call_timeout`. No logging here: chronicles slows worker start-up.
  if not st.hooks.timeout.isNil():
    st.hooks.timeout(
      st.hooks.ffiCtx,
      ReverseCallTimeout(
        callId: callId,
        procName: $name,
        elapsedMs: elapsedMs,
        timeoutMs: timeoutMs,
        reason: reason,
      ),
    )

proc ffiReverseCall*(
    implId: int, name: cstring, argsCbor: seq[byte], timeoutMs: int
): Future[Result[seq[byte], string]] {.async.} =
  ## FFI thread only: queues call `implId` for the workers and awaits the reply under
  ## `timeoutMs`. `name` must be a string literal (the macro's wire name).
  let st = ffiCurrentReverseContext
  if st.isNil():
    return err("reverse call " & $name & " outside an FFI processing thread")
  if st[].closing.load():
    # Set before the teardown fails the parked calls, so nothing parks behind it.
    return err("reverse call " & $name & " abandoned: the FFI context is closing")
  if not st[].isRegistered(implId):
    return err("no host implementation registered for " & $name)
  if not st[].startReverseWorkers():
    return err("reverse workers could not be started for " & $name)

  let generation =
    if st[].hooks.generation.isNil():
      0'u
    else:
      st[].hooks.generation(st[].hooks.ffiCtx)
  let token =
    if st[].hooks.token.isNil():
      nil
    else:
      st[].hooks.token(st[].hooks.ffiCtx)
  let callId = st[].allocCallId()
  let deadlineNs = nowNs() + int64(timeoutMs) * 1_000_000'i64
  let rec =
    allocInvocation(callId, generation, token, deadlineNs, implId, name, argsCbor)
  if rec.isNil():
    return err("out of memory: could not queue reverse call " & $name)

  if not st[].pushInvocation(rec):
    free(rec) # neither the queue nor a pending entry holds it
    if st[].stopping.load():
      return
        err("reverse call " & $name & " abandoned: the reverse workers are stopping")
    let busy = st[].busySummary()
    st[].reportTimeout(callId, name, 0, timeoutMs, "queue_full")
    return err(
      "reverse call queue full (" & $ReverseQueueDepth & " waiting): " & $name & "; " &
        busy
    )
  # No await since the push, so no reply for `callId` is drained before this.
  let fut = newFuture[Result[seq[byte], string]]("ffiReverseCall")
  ffiPendingReverse[callId] = PendingReverse(fut: fut, rec: rec)

  var completed = false
  try:
    completed = await fut.withTimeout(chronos.milliseconds(timeoutMs))
  except CancelledError as e:
    abandonCall(callId)
    raise e
  if not completed:
    abandonCall(callId)
    st[].reportTimeout(callId, name, timeoutMs, timeoutMs, "timeout")
    return err("reverse call " & $name & " timed out after " & $timeoutMs & " ms")

  return await fut
