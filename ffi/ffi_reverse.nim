## Reverse FFI runtime: host impls, the per-context worker pool and the reply mailbox.

import system/ansi_c
import std/[atomics, locks]
import results
import ./ffi_types

const ReverseMailboxDepth* {.intdefine: "ffiReverseMailboxDepth".} = 1024
  ## Replies parked between two FFI-thread drains; past it a reply is refused.

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

  ReverseWakeFn* = proc(ud: pointer) {.nimcall, gcsafe, raises: [].}
  ReverseGenerationFn* = proc(ud: pointer): uint {.nimcall, gcsafe, raises: [].}

  ReverseContextHooks = object
    wake: ReverseWakeFn
    generation: ReverseGenerationFn
    ffiCtx: pointer

  ReverseMailbox = object ## FIFO of host replies: the first reply for a call id wins
    head, tail: ptr ReverseReply
    count: int

  FFIReverseContext* = object
    lock*: Lock
    impls: ptr UncheckedArray[ptr ReverseImplEntry] # c_malloc'd, indexed by impl id
    implCap: int
    dispatching*: int # invocations in flight on the workers
    nextCallId*: Atomic[uint64]
    mailbox: ReverseMailbox
    hooks: ReverseContextHooks

proc initReverseContext*(st: var FFIReverseContext) =
  ## Once, before any thread sees `st`: a second initLock is UB.
  st = FFIReverseContext()
  st.lock.initLock()

func installContextHooks*(
    st: var FFIReverseContext,
    wake: ReverseWakeFn,
    gen: ReverseGenerationFn,
    ud: pointer,
) {.raises: [].} =
  st.hooks = ReverseContextHooks(wake: wake, generation: gen, ffiCtx: ud)

proc freeReply*(r: ptr ReverseReply) {.raises: [].} =
  c_free(r)

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
  ## Err, keeping the lock alive, while a running impl may still take it.
  st.freeAllReplies()
  let running = st.clearImpls()
  if running > 0:
    return err("reverse context kept alive: " & $running & " impl(s) still running")

  st.lock.deinitLock()
  return ok()

type ReverseError* {.pure.} = enum
  OutOfMemory

func toRetCode*(e: ReverseError): cint =
  ## The `RET_*` status a C export returns for `e`.
  case e
  of ReverseError.OutOfMemory: RET_OUT_OF_MEMORY

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
  doAssert not fn.isNil(), "registerImpl needs an impl; use unregisterImpl"
  doAssert id >= 0, "registerImpl: negative impl id"
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
