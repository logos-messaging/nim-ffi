## Reverse FFI runtime: host impls, the per-context worker pool and the reply mailbox.

import system/ansi_c
import std/[atomics, locks]
import results
import ./ffi_types

const ReverseMailboxDepth* {.intdefine: "ffiReverseMailboxDepth".} = 1024
  ## Replies parked between two FFI-thread drains; a full mailbox rejects the reply,
  ## so the caller's future then times out. Override `-d:ffiReverseMailboxDepth=<n>`.

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
    impls: array[ReverseMaxImpls, ReverseImplSlot] # no GC memory: any thread may free
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

proc dupName(name: string): cstring {.raises: [].} =
  ## A c_malloc'd copy, so any thread may free it; nil when the allocation fails.
  let buf = c_malloc(csize_t(name.len + 1))
  if buf.isNil():
    return nil
  copyMem(buf, cstring(name), name.len + 1) # a Nim string keeps its terminating NUL
  return cast[cstring](buf)

proc free(e: ptr ReverseImplEntry) {.raises: [], gcsafe.} =
  ## Hands `userData` back through the host's `release`, then frees the entry itself.
  if not e[].release.isNil():
    e[].release(e[].userData)
  c_free(e)

proc decRef(e: ptr ReverseImplEntry) {.raises: [], gcsafe.} =
  ## Drops one reference; the last one hands `userData` back to the host.
  if e.isNil():
    return

  if e[].refs.fetchSub(1) == 1:
    free(e)

proc free(slot: ReverseImplSlot) {.raises: [], gcsafe.} =
  ## Call once the slot is unlinked and the lock is dropped.
  if not slot.name.isNil():
    c_free(slot.name)
  decRef(slot.entry)

func findSlotByName(st: FFIReverseContext, name: cstring): int {.raises: [].} =
  ## Call with `st.lock` held; -1 when `name` has no impl.
  for i in 0 ..< ReverseMaxImpls:
    if not st.impls[i].name.isNil() and c_strcmp(st.impls[i].name, name) == 0:
      return i
  return -1

func findEmptySlot(st: FFIReverseContext): int {.raises: [].} =
  ## Call with `st.lock` held; -1 when the registry is full.
  for i in 0 ..< ReverseMaxImpls:
    if st.impls[i].name.isNil():
      return i
  return -1

proc clearImpls*(st: var FFIReverseContext): int {.raises: [], gcsafe.} =
  ## Unregisters every impl without waiting; returns the invocations still running.
  ## A running invocation keeps its entry, and releases it when it returns.
  var old: typeof(st.impls)
  var running = 0
  withLock st.lock:
    swap(old, st.impls)
    running = st.dispatching
  for slot in old:
    free(slot)
  return running

proc deinitReverseContext*(st: var FFIReverseContext): Result[void, string] =
  ## Err while a running impl may still take the lock: it then stays alive, and a
  ## later call may free it.
  st.freeAllReplies()
  let running = st.clearImpls()
  if running > 0:
    return err("reverse context kept alive: " & $running & " impl(s) still running")

  st.lock.deinitLock()
  return ok()

type ReverseError* {.pure.} = enum
  OutOfMemory
  RegistryFull

func toRetCode*(e: ReverseError): cint =
  ## The REVERSE_* status the C exports return for `e`.
  case e
  of ReverseError.OutOfMemory: REVERSE_OUT_OF_MEMORY
  of ReverseError.RegistryFull: REVERSE_REGISTRY_FULL

proc registerImpl*(
    st: var FFIReverseContext,
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
  let fresh = cast[ptr ReverseImplEntry](c_malloc(csize_t(sizeof(ReverseImplEntry))))
  if fresh.isNil():
    return err(ReverseError.OutOfMemory)
  fresh[].refs.store(1)
  fresh[].fn = fn
  fresh[].userData = userData
  fresh[].release = release

  var old: ptr ReverseImplEntry = nil
  withLock st.lock:
    var idx = st.findSlotByName(cstring(name))
    if idx < 0:
      idx = st.findEmptySlot()
      if idx < 0:
        c_free(fresh) # never published, so its release must not run
        return err(ReverseError.RegistryFull)
      st.impls[idx].name = dupName(name)
      if st.impls[idx].name.isNil():
        c_free(fresh)
        return err(ReverseError.OutOfMemory)
    old = st.impls[idx].entry
    st.impls[idx].entry = fresh
  decRef(old)
  return ok()

proc unregisterImpl*(st: var FFIReverseContext, name: string) {.raises: [], gcsafe.} =
  ## Removes the impl of `name`, if any. Never waits: an invocation still running
  ## it keeps its entry and releases it when it returns.
  var old: ReverseImplSlot
  withLock st.lock:
    let idx = st.findSlotByName(cstring(name))
    if idx >= 0:
      swap(old, st.impls[idx])
  free(old)

proc isRegistered*(
    st: var FFIReverseContext, name: string
): bool {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.findSlotByName(cstring(name)) >= 0

proc inFlight*(st: var FFIReverseContext): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.dispatching

proc beginReverseDispatch*(
    st: var FFIReverseContext, name: cstring
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
    st: var FFIReverseContext, entry: ptr ReverseImplEntry
) {.raises: [], gcsafe.} =
  # Release first: the dispatch counts as in flight until the host's `release` has run.
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
    wasEmpty = st.mailbox.head.isNil()
    if wasEmpty:
      st.mailbox.head = node
    else:
      st.mailbox.tail[].next = node
    st.mailbox.tail = node
    st.mailbox.count.inc()

  if wasEmpty and not st.hooks.wake.isNil():
    st.hooks.wake(st.hooks.ffiCtx)
  return REVERSE_ACCEPTED

proc mailboxLen*(st: var FFIReverseContext): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.mailbox.count
