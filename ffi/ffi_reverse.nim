## Reverse FFI runtime: host impls, the per-context worker pool and the reply mailbox.

import system/ansi_c
import std/[atomics, locks, monotimes, os, tables]
import chronos, results
import ./ffi_types

const ReverseMailboxDepth* {.intdefine: "ffiReverseMailboxDepth".} = 1024
  ## Replies parked between two FFI-thread drains; a full mailbox rejects the reply,
  ## so the caller's future then times out. Override `-d:ffiReverseMailboxDepth=<n>`.

const ReverseQueueDepth* {.intdefine: "ffiReverseQueueDepth".} = 1024
  ## Calls waiting for a free reverse worker; a call past it fails at once.
  ## Override `-d:ffiReverseQueueDepth=<n>`.

const ReverseCallTimeoutMs* {.intdefine: "ffiReverseCallTimeoutMs".} = 10000
  ## Default deadline of one `{.ffiReverse.}` call; `timeout = N` overrides it per proc.
  ## Override the default with `-d:ffiReverseCallTimeoutMs=<ms>`.

const ReverseWorkersDefault* {.intdefine: "ffiReverseWorkers".} = 1
  ## Workers a context starts on the first `registerImpl`; this many impls run at once.
  ## Override `-d:ffiReverseWorkers=<n>`.

const ReverseMaxImpls* {.intdefine: "ffiReverseMaxImpls".} = 64
  ## Registry slots per context: at least the `{.ffiReverse.}` procs of the library.
  ## Override `-d:ffiReverseMaxImpls=<n>`.

const ReverseWorkerStallMs* {.intdefine: "ffiReverseWorkerStallMs".} =
  ReverseCallTimeoutMs
  ## A worker inside one impl for longer emits `reverse_worker_blocked`.
  ## Override `-d:ffiReverseWorkerStallMs=<ms>`.

const ReverseWorkerJoinTimeoutMs* {.intdefine: "ffiReverseWorkerJoinTimeoutMs".} = 1500
  ## Per-worker join wait at stop; past it the worker is leaked, not waited on.
  ## Override `-d:ffiReverseWorkerJoinTimeoutMs=<ms>`.

static:
  doAssert ReverseWorkersDefault >= 1, "-d:ffiReverseWorkers must be at least 1"
  doAssert ReverseMailboxDepth >= 1, "-d:ffiReverseMailboxDepth must be at least 1"
  doAssert ReverseQueueDepth >= 1, "-d:ffiReverseQueueDepth must be at least 1"
  doAssert ReverseCallTimeoutMs > 0, "-d:ffiReverseCallTimeoutMs must be positive"
  doAssert ReverseMaxImpls >= 1, "-d:ffiReverseMaxImpls must be at least 1"

proc ffiNoopCallback*(
    callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

type FFIReverseImpl* = proc(
  callId: uint64, args: ptr UncheckedArray[byte], argsLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}
  ## Runs on a reverse worker and may block; answers through `<lib>_reverse_reply`.

type FFIReverseRelease* = proc(userData: pointer) {.cdecl, gcsafe, raises: [].}
  ## Frees an impl's `userData`. Runs on whichever thread drops the last
  ## reference: a reverse worker, a `registerImpl` caller or the FFI thread.

type
  ReverseImplEntry* = object
    ## c_malloc'd: one reference for the registry slot, one per running dispatch.
    refs: Atomic[int]
    fn*: FFIReverseImpl
    userData*: pointer
    release: FFIReverseRelease

  ReverseImplSlot = object
    name: cstring # c_malloc'd; nil for a free slot
    entry: ptr ReverseImplEntry

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
    deadlineNs*: int64
    state*: Atomic[ReverseCallState]
    name*: cstring
    args*: ptr UncheckedArray[byte]
    argsLen*: int
    next*: ptr ReverseInvocation

  ReverseWorkerArg = object
    st: ptr FFIReverseState
    me: ptr FFIReverseWorker # fixed at creation: a claimed stop clears `st.workers`
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

  ReverseWorkerTransition* = object
    idx*: int
    callId*: uint64
    blocked*: bool

  ReverseWakeFn* = proc(ud: pointer) {.nimcall, gcsafe, raises: [].}
  ReverseGenerationFn* = proc(ud: pointer): uint {.nimcall, gcsafe, raises: [].}

  ReverseContextHooks = object
    wake: ReverseWakeFn
    generation: ReverseGenerationFn
    ffiCtx: pointer

  ReverseMailbox = object ## FIFO of host replies: the first reply for a call id wins
    head, tail: ptr ReverseReply
    count: int

  ReverseStopFn* = proc(st: var FFIReverseState, timeoutMs: int): ReverseStopResult {.
    nimcall, gcsafe, raises: []
  .}

  FFIReverseState* = object
    lock*: Lock
    impls: array[ReverseMaxImpls, ReverseImplSlot] # no GC memory: any thread may free
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
    leakedWorkers*: int # never joined: the worker array and the locks stay alive
    stopFn*: ReverseStopFn # nil until startReverseWorkers

var onReverseWorker* {.threadvar.}: bool
var myWorkerIdx {.threadvar.}: int # 1-based; 0 off a worker
var myReverseState {.threadvar.}: ptr FFIReverseState # nil off a worker

proc onOwnReverseWorker*(st: var FFIReverseState): bool {.raises: [], gcsafe.} =
  ## True on a worker of `st`: tearing its context down from here waits on this very impl.
  return onReverseWorker and myReverseState == addr st

proc nowNs(): int64 =
  return getMonoTime().ticks

proc initReverseState*(st: var FFIReverseState) =
  ## Once, before any thread sees `st`: a second initLock is UB.
  st.lock.initLock()
  st.qLock.initLock()
  st.qCond.initCond()
  for i in 0 ..< ReverseMaxImpls:
    st.impls[i] = ReverseImplSlot()
  st.dispatching = 0
  st.nextCallId.store(0'u64)
  st.mailbox = ReverseMailbox()
  st.hooks = ReverseContextHooks()
  st.qHead = nil
  st.qTail = nil
  st.qCount = 0
  st.stopping.store(false)
  st.stopClaimed = false
  st.closing.store(false)
  st.workers = nil
  st.workerCount = 0
  st.leakedWorkers = 0
  st.stopFn = nil

func installContextHooks*(
    st: var FFIReverseState, wake: ReverseWakeFn, gen: ReverseGenerationFn, ud: pointer
) {.raises: [].} =
  st.hooks = ReverseContextHooks(wake: wake, generation: gen, ffiCtx: ud)

proc freeReply*(r: ptr ReverseReply) {.raises: [].} =
  c_free(r)

proc destroy(r: ptr ReverseInvocation) {.raises: [].} =
  if r.isNil():
    return

  if not r[].name.isNil():
    c_free(cast[pointer](r[].name))
  if not r[].args.isNil():
    c_free(r[].args)
  c_free(r)

proc decRef*(r: ptr ReverseInvocation) {.raises: [].} =
  if r.isNil():
    return

  if r[].refs.fetchSub(1) == 1:
    destroy(r)

proc takeReplies*(st: var FFIReverseState): ptr ReverseReply {.raises: [], gcsafe.} =
  ## Detaches the mailbox; the caller frees every node.
  withLock st.lock:
    let head = st.mailbox.head
    st.mailbox = ReverseMailbox()
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
    decRef(node)
    node = next

proc queueLen*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.qLock:
    return st.qCount

proc workersStarted*(st: var FFIReverseState): bool {.raises: [], gcsafe.} =
  withLock st.qLock:
    return st.workerCount > 0

proc dupName(name: string): cstring {.raises: [].} =
  ## A c_malloc'd copy, so any thread may free it; nil when the allocation fails.
  let buf = c_malloc(csize_t(name.len + 1))
  if buf.isNil():
    return nil
  copyMem(buf, cstring(name), name.len + 1) # a Nim string keeps its terminating NUL
  return cast[cstring](buf)

proc destroy(e: ptr ReverseImplEntry) {.raises: [], gcsafe.} =
  ## Hands `userData` back through the host's `release`, then frees the entry itself.
  if not e[].release.isNil():
    e[].release(e[].userData)
  c_free(e)

proc decRef(e: ptr ReverseImplEntry) {.raises: [], gcsafe.} =
  ## Drops one reference; the last one hands `userData` back to the host.
  if e.isNil():
    return

  if e[].refs.fetchSub(1) == 1:
    destroy(e)

func findSlotByName(st: FFIReverseState, name: cstring): int {.raises: [].} =
  ## Call with `st.lock` held; -1 when `name` has no impl.
  for i in 0 ..< ReverseMaxImpls:
    if not st.impls[i].name.isNil() and c_strcmp(st.impls[i].name, name) == 0:
      return i
  return -1

func findEmptySlot(st: FFIReverseState): int {.raises: [].} =
  ## Call with `st.lock` held; -1 when the registry is full.
  for i in 0 ..< ReverseMaxImpls:
    if st.impls[i].name.isNil():
      return i
  return -1

proc clearImpls*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  ## Unregisters every impl without waiting; returns the invocations still running.
  ## A running invocation keeps its entry, and releases it when it returns.
  var entries: array[ReverseMaxImpls, ptr ReverseImplEntry]
  var names: array[ReverseMaxImpls, cstring]
  var running = 0
  withLock st.lock:
    for i in 0 ..< ReverseMaxImpls:
      entries[i] = st.impls[i].entry
      names[i] = st.impls[i].name
      st.impls[i] = ReverseImplSlot()
    running = st.dispatching
  for i in 0 ..< ReverseMaxImpls:
    if not names[i].isNil():
      c_free(names[i])
    decRef(entries[i])
  return running

proc deinitReverseState*(st: var FFIReverseState): Result[void, string] =
  ## Err while a leaked worker or a running impl may still take the locks: they and
  ## the worker array then stay alive, and a later call may free them.
  if not st.stopFn.isNil() and st.workerCount > 0:
    # A worker that does not exit in time is counted in `leakedWorkers`.
    discard st.stopFn(st, ReverseWorkerJoinTimeoutMs)
  st.purgeQueue()
  st.freeAllReplies()
  let running = st.clearImpls()
  if st.leakedWorkers > 0 or running > 0:
    return err(
      "reverse state kept alive: " & $st.leakedWorkers & " leaked worker(s), " & $running &
        " impl(s) still running"
    )

  if not st.workers.isNil():
    c_free(st.workers)
    st.workers = nil
  st.qCond.deinitCond()
  st.qLock.deinitLock()
  st.lock.deinitLock()
  return ok()

proc startReverseWorkers*(
  st: var FFIReverseState, n: int = 0
): bool {.raises: [], gcsafe.}

type ReverseError* {.pure.} = enum
  OutOfMemory
  RegistryFull
  WorkersFailed

func toRetCode*(e: ReverseError): cint =
  ## The REVERSE_* status the C exports return for `e`.
  case e
  of ReverseError.OutOfMemory: REVERSE_OUT_OF_MEMORY
  of ReverseError.RegistryFull: REVERSE_REGISTRY_FULL
  of ReverseError.WorkersFailed: REVERSE_WORKERS_FAILED

proc registerImpl*(
    st: var FFIReverseState,
    name: string,
    fn: FFIReverseImpl,
    userData: pointer,
    release: FFIReverseRelease = nil,
): Result[void, ReverseError] {.raises: [], gcsafe.} =
  ## Registers `fn` (not nil) for `name`, replacing any impl it had. Never waits.
  ##
  ## With a `release`, Nim owns `userData`: the last invocation still running the
  ## replaced entry calls its `release`. With a nil `release` the host keeps
  ## ownership and Nim never frees `userData`: keep it valid while an invocation
  ## may still run it, i.e. until the context is destroyed.
  ##
  ## On an error the caller still owns `userData`, and `release` is never called for it.
  doAssert not fn.isNil(), "registerImpl needs an impl; use unregisterImpl"
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
  var failure = Opt.none(ReverseError)
  withLock st.lock:
    var idx = st.findSlotByName(cstring(name))
    if idx < 0:
      idx = st.findEmptySlot()
      if idx < 0:
        failure = Opt.some(ReverseError.RegistryFull)
      else:
        st.impls[idx].name = dupName(name)
        if st.impls[idx].name.isNil():
          idx = -1
          failure = Opt.some(ReverseError.OutOfMemory)
    if idx >= 0:
      old = st.impls[idx].entry
      st.impls[idx].entry = fresh

  if failure.isSome():
    c_free(fresh) # never published, so its release must not run
    return err(failure.get())
  decRef(old)
  return ok()

proc unregisterImpl*(st: var FFIReverseState, name: string) {.raises: [], gcsafe.} =
  ## Removes the impl of `name`, if any. Never waits: an invocation still running
  ## it keeps its entry and releases it when it returns.
  var old: ptr ReverseImplEntry = nil
  var oldName: cstring = nil
  withLock st.lock:
    let idx = st.findSlotByName(cstring(name))
    if idx >= 0:
      old = st.impls[idx].entry
      oldName = st.impls[idx].name
      st.impls[idx] = ReverseImplSlot()
  if not oldName.isNil():
    c_free(oldName)
  decRef(old)

proc isRegistered*(st: var FFIReverseState, name: string): bool {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.findSlotByName(cstring(name)) >= 0

proc inFlight*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.dispatching

proc beginReverseDispatch*(
    st: var FFIReverseState, name: cstring
): ptr ReverseImplEntry {.raises: [], gcsafe.} =
  ## Nil when `name` has no impl; pair every other result with `endReverseDispatch`.
  withLock st.lock:
    let idx = st.findSlotByName(name)
    if idx < 0:
      return nil

    let entry = st.impls[idx].entry
    discard entry[].refs.fetchAdd(1)
    st.dispatching.inc()
    return entry

proc endReverseDispatch*(
    st: var FFIReverseState, entry: ptr ReverseImplEntry
) {.raises: [], gcsafe.} =
  # Release first: the dispatch counts as in flight until the host's `release` has run.
  decRef(entry)
  withLock st.lock:
    st.dispatching.dec()

proc allocCallId*(st: var FFIReverseState): uint64 {.raises: [].} =
  ## Monotonic for the life of the slot; 0 is the invalid id.
  return st.nextCallId.fetchAdd(1'u64) + 1'u64

proc pushReply*(
    st: var FFIReverseState, callId: uint64, retCode: cint, data: pointer, dataLen: int
): cint {.raises: [], gcsafe.} =
  ## Any thread. Wakes the FFI thread only when the mailbox was empty.
  let payloadLen = if dataLen > 0 and not data.isNil(): dataLen else: 0
  let node =
    cast[ptr ReverseReply](c_malloc(csize_t(sizeof(ReverseReply) + payloadLen)))
  if node.isNil():
    return REVERSE_OUT_OF_MEMORY

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
      return REVERSE_MAILBOX_FULL
    wasEmpty = st.mailbox.count == 0
    if st.mailbox.tail.isNil():
      st.mailbox.head = node
    else:
      st.mailbox.tail[].next = node
    st.mailbox.tail = node
    st.mailbox.count.inc()

  if wasEmpty and not st.hooks.wake.isNil():
    st.hooks.wake(st.hooks.ffiCtx)
  return REVERSE_ACCEPTED

proc mailboxLen*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.mailbox.count

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

  rec[].name = dupName(name)
  if rec[].name.isNil():
    c_free(rec)
    return nil

  if args.len > 0:
    let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(args.len)))
    if buf.isNil():
      destroy(rec)
      return nil
    copyMem(buf, unsafeAddr args[0], args.len)
    rec[].args = buf
    rec[].argsLen = args.len
  return rec

proc pushInvocation(
    st: var FFIReverseState, rec: ptr ReverseInvocation
): bool {.raises: [].} =
  ## False when `ReverseQueueDepth` calls already wait; the record is then not queued.
  withLock st.qLock:
    if st.qCount >= ReverseQueueDepth:
      return false
    if st.qTail.isNil():
      st.qHead = rec
    else:
      st.qTail[].next = rec
    st.qTail = rec
    st.qCount.inc()
    signal(st.qCond)
  return true

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
  me[].busySinceNs.store(nowNs())
  defer:
    me[].busySinceNs.store(0'i64)
    me[].currentCall.store(0'u64)

  let entry = st.beginReverseDispatch(rec[].name)
  if entry.isNil():
    let msg =
      "host implementation for " & $rec[].name & " was unregistered before dispatch"
    discard
      st.pushReply(rec[].callId, RET_ERR, cast[pointer](unsafeAddr msg[0]), msg.len)
    return

  defer:
    st.endReverseDispatch(entry)
  foreignThreadGc:
    entry[].fn(rec[].callId, rec[].args, csize_t(rec[].argsLen), entry[].userData)

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
    st: var FFIReverseState, timeoutMs: int = ReverseWorkerJoinTimeoutMs
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
    if onReverseWorker and myWorkerIdx == i + 1:
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
    st: var FFIReverseState, n: int = 0
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
    st: var FFIReverseState, stallNs: int64
): seq[ReverseWorkerTransition] {.raises: [], gcsafe.} =
  ## Event thread only: reports once each worker that just stalled or just recovered.
  var count = 0
  var workers: ptr UncheckedArray[FFIReverseWorker]
  withLock st.qLock:
    count = st.workerCount
    workers = st.workers
  if count == 0 or workers.isNil():
    return @[]

  var transitions: seq[ReverseWorkerTransition] = @[]
  let now = nowNs()
  for i in 0 ..< count:
    let w = addr workers[i]
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

proc releasePendingReverse*() {.gcsafe, raises: [].} =
  ## FFI thread exit: under ORC a threadvar outlives its thread, so free the table's storage.
  failPendingReverse("FFI thread exited; the reverse call was abandoned")
  reset(ffiPendingReverse)

proc abandonCall(callId: uint64) =
  let p = ffiPendingReverse.getOrDefault(callId)
  if p.fut.isNil():
    return

  if not p.rec.isNil():
    discard cancelInvocation(p.rec)
    decRef(p.rec)
  ffiPendingReverse.del(callId)

proc ffiReverseCall*(
    name: string, argsCbor: seq[byte], timeoutMs: int
): Future[Result[seq[byte], string]] {.async.} =
  ## FFI thread only: queues the call for the workers and awaits the reply under `timeoutMs`.
  let st = ffiCurrentReverseState
  if st.isNil():
    return err("reverse call " & name & " outside an FFI processing thread")
  if st[].closing.load():
    # Set before the teardown fails the parked calls, so nothing parks behind it.
    return err("reverse call " & name & " abandoned: the FFI context is closing")
  if not st[].isRegistered(name):
    return err("no host implementation registered for " & name)
  if not st[].startReverseWorkers():
    return err("reverse workers could not be started for " & name)

  let generation =
    if st[].hooks.generation.isNil():
      0'u
    else:
      st[].hooks.generation(st[].hooks.ffiCtx)
  let callId = st[].allocCallId()
  let deadlineNs = nowNs() + int64(timeoutMs) * 1_000_000'i64
  let rec = allocInvocation(callId, generation, deadlineNs, name, argsCbor)
  if rec.isNil():
    return err("out of memory: could not queue reverse call " & name)

  if not st[].pushInvocation(rec):
    destroy(rec) # neither the queue nor a pending entry holds it
    return err("reverse call queue full (" & $ReverseQueueDepth & " waiting): " & name)
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
    return err("reverse call " & name & " timed out after " & $timeoutMs & " ms")

  return await fut
