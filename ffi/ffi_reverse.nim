## Reverse FFI runtime: host impls, the per-context worker pool and the reply mailbox.

import system/ansi_c
import std/[atomics, locks]
import ./ffi_types

const ReverseMailboxDepth* {.intdefine: "ffiReverseMailboxDepth".} = 1024
  ## Replies parked between two FFI-thread drains; a full mailbox rejects the reply,
  ## so the caller's future then times out. Override `-d:ffiReverseMailboxDepth=<n>`.

const ReverseCallTimeoutMs* {.intdefine: "ffiReverseCallTimeoutMs".} = 10000
  ## Default deadline of one `{.ffiReverse.}` call; `timeout = N` overrides it per proc.
  ## Override the default with `-d:ffiReverseCallTimeoutMs=<ms>`.

const ReverseWorkersDefault* {.intdefine: "ffiReverseWorkers".} = 1
  ## Workers a context starts on the first `setImpl`; this many impls run at once.
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
  callId: uint64,
  argsCbor: ptr UncheckedArray[byte],
  argsLen: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}
  ## Runs on a reverse worker and may block; answers through `<lib>_reverse_reply`.

type FFIReverseRelease* = proc(userData: pointer) {.cdecl, gcsafe, raises: [].}
  ## Frees an impl's `userData` once no invocation uses it. Runs on whichever thread
  ## drops the last reference: a reverse worker, a `setImpl` caller or the FFI thread.

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
    data*: ptr UncheckedArray[byte] # c_malloc'd; freed by the draining thread
    dataLen*: int
    next*: ptr ReverseReply

  ReverseWakeFn* = proc(ud: pointer) {.nimcall, gcsafe, raises: [].}
  ReverseGenerationFn* = proc(ud: pointer): uint {.nimcall, gcsafe, raises: [].}

  FFIReverseState* = object
    lock*: Lock
    impls: array[ReverseMaxImpls, ReverseImplSlot] # no GC memory: any thread may free
    dispatching*: int # invocations in flight on the workers
    nextCallId*: Atomic[uint64]
    mailbox, mailboxTail: ptr ReverseReply # FIFO: the first reply for a call id wins
    mailboxCount: int
    wakeFn*: ReverseWakeFn
    generationFn*: ReverseGenerationFn
    hookUd*: pointer # the FFIContext

proc initReverseState*(st: var FFIReverseState) =
  ## Once, before any thread sees `st`: a second initLock is UB.
  st.lock.initLock()
  for i in 0 ..< ReverseMaxImpls:
    st.impls[i] = ReverseImplSlot()
  st.dispatching = 0
  st.nextCallId.store(0'u64)
  st.mailbox = nil
  st.mailboxTail = nil
  st.mailboxCount = 0
  st.wakeFn = nil
  st.generationFn = nil
  st.hookUd = nil

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

proc takeReplies*(st: var FFIReverseState): ptr ReverseReply {.raises: [], gcsafe.} =
  ## Detaches the mailbox; the caller frees every node.
  withLock st.lock:
    let head = st.mailbox
    st.mailbox = nil
    st.mailboxTail = nil
    st.mailboxCount = 0
    return head

proc freeAllReplies*(st: var FFIReverseState) {.raises: [], gcsafe.} =
  var node = st.takeReplies()
  while not node.isNil():
    let next = node[].next
    freeReply(node)
    node = next

proc dupName(name: string): cstring {.raises: [].} =
  ## A c_malloc'd copy, so any thread may free it; nil when the allocation fails.
  let buf = cast[ptr UncheckedArray[char]](c_malloc(csize_t(name.len + 1)))
  if buf.isNil():
    return nil
  if name.len > 0:
    copyMem(buf, unsafeAddr name[0], name.len)
  buf[name.len] = '\0'
  return cast[cstring](buf)

proc freeEntry(e: ptr ReverseImplEntry) {.raises: [], gcsafe.} =
  if not e[].release.isNil():
    e[].release(e[].userData)
  c_free(e)

proc releaseEntry(e: ptr ReverseImplEntry) {.raises: [], gcsafe.} =
  ## Drops one reference; the last one hands `userData` back to the host.
  if e.isNil():
    return

  if e[].refs.fetchSub(1) == 1:
    freeEntry(e)

proc findSlot(st: var FFIReverseState, name: cstring): int {.raises: [].} =
  ## Call with `st.lock` held; -1 when `name` has no impl.
  for i in 0 ..< ReverseMaxImpls:
    if not st.impls[i].name.isNil() and c_strcmp(st.impls[i].name, name) == 0:
      return i
  return -1

proc freeSlot(st: var FFIReverseState): int {.raises: [].} =
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
    releaseEntry(entries[i])
  return running

proc deinitReverseState*(st: var FFIReverseState) =
  st.freeAllReplies()
  discard st.clearImpls()
  st.lock.deinitLock()

proc setImplStatus*(
    st: var FFIReverseState,
    name: string,
    fn: FFIReverseImpl,
    userData: pointer,
    release: FFIReverseRelease = nil,
): cint {.raises: [], gcsafe.} =
  ## Registers `fn` for `name`, or unregisters it when `fn` is nil. Never waits.
  ##
  ## With a `release`, Nim owns `userData`: the last invocation still running the
  ## replaced entry calls its `release`. With a nil `release` the host keeps
  ## ownership and Nim never frees `userData`: keep it valid while an invocation
  ## may still run it, i.e. until the context is destroyed.
  ##
  ## REVERSE_ACCEPTED, or REVERSE_OUT_OF_MEMORY /
  ## REVERSE_REGISTRY_FULL; on an error the caller still owns `userData` and
  ## `release` is never called for it.
  var fresh: ptr ReverseImplEntry = nil
  if not fn.isNil():
    fresh = cast[ptr ReverseImplEntry](c_malloc(csize_t(sizeof(ReverseImplEntry))))
    if fresh.isNil():
      return REVERSE_OUT_OF_MEMORY
    fresh[].refs.store(1)
    fresh[].fn = fn
    fresh[].userData = userData
    fresh[].release = release

  var old: ptr ReverseImplEntry = nil
  var oldName: cstring = nil
  var status = REVERSE_ACCEPTED
  withLock st.lock:
    var idx = st.findSlot(cstring(name))
    if idx < 0 and not fresh.isNil():
      idx = st.freeSlot()
      if idx < 0:
        status = REVERSE_REGISTRY_FULL
      else:
        st.impls[idx].name = dupName(name)
        if st.impls[idx].name.isNil():
          idx = -1
          status = REVERSE_OUT_OF_MEMORY
    if idx >= 0:
      old = st.impls[idx].entry
      st.impls[idx].entry = fresh
      if fresh.isNil():
        oldName = st.impls[idx].name
        st.impls[idx].name = nil
    # idx < 0 with a nil `fn`: unregistering an absent name is not an error

  if status != REVERSE_ACCEPTED:
    c_free(fresh) # never published, so its release must not run
    return status
  if not oldName.isNil():
    c_free(oldName)
  releaseEntry(old)
  return REVERSE_ACCEPTED

proc setImpl*(
    st: var FFIReverseState,
    name: string,
    fn: FFIReverseImpl,
    userData: pointer,
    release: FFIReverseRelease = nil,
): bool {.discardable, raises: [], gcsafe.} =
  ## `setImplStatus` for Nim callers that only need success or failure.
  return st.setImplStatus(name, fn, userData, release) == REVERSE_ACCEPTED

proc hasImpl*(st: var FFIReverseState, name: string): bool {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.findSlot(cstring(name)) >= 0

proc inFlight*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.dispatching

proc beginReverseDispatch*(
    st: var FFIReverseState, name: cstring
): ptr ReverseImplEntry {.raises: [], gcsafe.} =
  ## Nil when `name` has no impl; pair every other result with `endReverseDispatch`.
  withLock st.lock:
    let idx = st.findSlot(name)
    if idx < 0:
      return nil

    let entry = st.impls[idx].entry
    discard entry[].refs.fetchAdd(1)
    st.dispatching.inc()
    return entry

proc endReverseDispatch*(
    st: var FFIReverseState, entry: ptr ReverseImplEntry
) {.raises: [], gcsafe.} =
  withLock st.lock:
    st.dispatching.dec()
  releaseEntry(entry)

proc allocCallId*(st: var FFIReverseState): uint64 {.raises: [].} =
  ## Monotonic for the life of the slot; 0 is the invalid id.
  return st.nextCallId.fetchAdd(1'u64) + 1'u64

proc pushReply*(
    st: var FFIReverseState, callId: uint64, retCode: cint, data: pointer, dataLen: int
): cint {.raises: [], gcsafe.} =
  ## Any thread. Wakes the FFI thread only when the mailbox was empty.
  let node = cast[ptr ReverseReply](c_malloc(csize_t(sizeof(ReverseReply))))
  if node.isNil():
    return REVERSE_OUT_OF_MEMORY

  node[].callId = callId
  node[].retCode = retCode
  node[].data = nil
  node[].dataLen = 0
  node[].next = nil
  if dataLen > 0 and not data.isNil():
    let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(dataLen)))
    if buf.isNil():
      c_free(node)
      return REVERSE_OUT_OF_MEMORY
    copyMem(buf, data, dataLen)
    node[].data = buf
    node[].dataLen = dataLen

  var wasEmpty = false
  withLock st.lock:
    if st.mailboxCount >= ReverseMailboxDepth:
      freeReply(node)
      return REVERSE_MAILBOX_FULL
    wasEmpty = st.mailboxCount == 0
    if st.mailboxTail.isNil():
      st.mailbox = node
    else:
      st.mailboxTail[].next = node
    st.mailboxTail = node
    st.mailboxCount.inc()

  if wasEmpty and not st.wakeFn.isNil():
    st.wakeFn(st.hookUd)
  return REVERSE_ACCEPTED

proc mailboxLen*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.mailboxCount
