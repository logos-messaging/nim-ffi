## Reverse-FFI runtime state: host-registered implementations for
## `{.ffiReverse.}` procs, monotonic call-id allocation, and the reply mailbox
## host threads push into for the FFI thread to drain. Payloads use libc malloc
## so they survive cross-thread heap reuse (same rule as ffi_thread_request).

import system/ansi_c
import std/[atomics, locks, tables]
import chronos, results
import ./ffi_types, ./ffi_events

const ReverseMailboxDepth* {.intdefine: "ffiReverseMailboxDepth".} = 1024
  ## Replies parked between two FFI-thread drains. A full mailbox rejects the
  ## reply (the caller's future then times out). Override with
  ## `-d:ffiReverseMailboxDepth=<n>`.

const ReverseCallTimeoutMs* {.intdefine: "ffiReverseCallTimeoutMs".} = 10000
  ## Default deadline for one `{.ffiReverse.}` call; per-proc override via
  ## `{.ffiReverse, timeout = N.}`. Override with `-d:ffiReverseCallTimeoutMs=<ms>`.

## `<lib>_reverse_reply` status codes (C-visible).
const
  REVERSE_ACCEPTED*: cint = 0
  REVERSE_INVALID_CTX*: cint = 1
  REVERSE_NOT_ACTIVE*: cint = 2
  REVERSE_PAYLOAD_TOO_LARGE*: cint = 3
  REVERSE_MAILBOX_FULL*: cint = 4

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
  ## Host-registered implementation of a `{.ffiReverse.}` proc. Invoked on the
  ## event dispatch thread; must return promptly and answer (inline or later,
  ## from any thread) via `<lib>_reverse_reply`.

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

  FFIReverseState* = object
    lock*: Lock
    impls*: Table[string, FFIReverseImplEntry]
    dispatching*: int # invocations in flight on the event thread
    dispatchDone*: Cond
    nextCallId*: Atomic[uint64] # never reused within a slot claim; ids start at 1
    mailbox: ptr ReverseReply # LIFO; replies are independent, order is irrelevant
    mailboxCount: int

var reverseInDispatch {.threadvar.}: int
  # Dispatch depth of this thread, so an impl unregistering itself never waits
  # for its own invocation (mirrors ffiInDispatch in ffi_events).

proc initReverseState*(st: var FFIReverseState) =
  ## Run once on the owning thread before sharing (re-initLock is UB).
  st.lock.initLock()
  st.dispatchDone.initCond()
  st.impls = initTable[string, FFIReverseImplEntry]()
  st.dispatching = 0
  st.nextCallId.store(0'u64)
  st.mailbox = nil
  st.mailboxCount = 0

proc freeReply*(r: ptr ReverseReply) {.raises: [].} =
  if r.isNil():
    return
  if not r[].data.isNil():
    c_free(r[].data)
  c_free(r)

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

proc deinitReverseState*(st: var FFIReverseState) =
  ## Mirror of `initReverseState`; resets GC fields so slot reuse sees no dtor.
  st.freeAllReplies()
  st.dispatchDone.deinitCond()
  st.lock.deinitLock()
  st.impls = default(Table[string, FFIReverseImplEntry])
  st.dispatching = 0

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
  ## soon as this returns.
  withLock st.lock:
    if fn.isNil():
      st.impls.del(name)
    else:
      st.impls[name] = FFIReverseImplEntry(fn: fn, userData: userData)
    st.awaitReverseDispatch()

proc hasImpl*(st: var FFIReverseState, name: string): bool {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.impls.contains(name)

proc clearImpls*(st: var FFIReverseState) {.raises: [], gcsafe.} =
  ## Removes all implementations; the pool calls this when it recycles a context.
  ## The lock stays in place, because the event thread uses it across recycles.
  withLock st.lock:
    st.impls.clear()
    st.awaitReverseDispatch()

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
  ## Copies the reply into a c_malloc node and parks it for the FFI thread.
  ## Callable from any thread. Returns a REVERSE_* status.
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
  withLock st.lock:
    if st.mailboxCount >= ReverseMailboxDepth:
      freeReply(node)
      return REVERSE_MAILBOX_FULL
    node[].next = st.mailbox
    st.mailbox = node
    st.mailboxCount.inc()
  REVERSE_ACCEPTED

proc mailboxLen*(st: var FFIReverseState): int {.raises: [], gcsafe.} =
  withLock st.lock:
    return st.mailboxCount

## ── FFI-thread side: pending futures and the call helper ────────────────────
## The parked futures are refs and must never leave the FFI thread's heap, so
## the table is a threadvar; call-id lookup needs no lock.

var ffiCurrentReverseState* {.threadvar.}: ptr FFIReverseState
  # Installed by the FFI thread body, like ffiCurrentEventQueue.

var ffiPendingReverse {.threadvar.}: Table[uint64, Future[Result[seq[byte], string]]]

proc ffiPendingReverseLen*(): int =
  ffiPendingReverse.len

proc drainReverseReplies*() {.gcsafe, raises: [].} =
  ## FFI thread only: completes the parked futures from the mailbox. A reply
  ## whose call-id is absent (timed out, recycled, or bogus) is freed and dropped.
  let st = ffiCurrentReverseState
  if st.isNil():
    return
  var node = st[].takeReplies()
  while not node.isNil():
    let next = node[].next
    let fut = ffiPendingReverse.getOrDefault(node[].callId)
    if not fut.isNil():
      ffiPendingReverse.del(node[].callId)
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
  ## FFI thread only: fails every parked reverse call, e.g. on recycle so a
  ## handler awaiting the host cannot hold the drain until its timeout.
  for _, fut in ffiPendingReverse.mpairs:
    if not fut.finished():
      fut.complete(Result[seq[byte], string].err(reason))
  ffiPendingReverse.clear()

proc ffiReverseCall*(
    name: string, argsCbor: seq[byte], timeoutMs: int
): Future[Result[seq[byte], string]] {.async.} =
  ## FFI thread only (called by the `{.ffiReverse.}` generated stub): parks a
  ## future keyed by a fresh call-id, rides the event ring to the host impl and
  ## awaits the reply under `timeoutMs`. The FFI thread itself stays free.
  let st = ffiCurrentReverseState
  if st.isNil():
    return err("reverse call " & name & " outside an FFI processing thread")
  if not st[].hasImpl(name):
    return err("no host implementation registered for " & name)
  let callId = st[].allocCallId()
  let fut = newFuture[Result[seq[byte], string]]("ffiReverseCall")
  ffiPendingReverse[callId] = fut

  let q = ffiCurrentEventQueue
  let src: pointer =
    if argsCbor.len > 0:
      unsafeAddr argsCbor[0]
    else:
      nil
  if q.isNil() or not q[].tryEnqueueReverse(cstring(name), src, argsCbor.len, callId):
    ffiPendingReverse.del(callId)
    return err("event queue full; reverse call not delivered: " & name)
  if not ffiCurrentNotifyEventEnqueued.isNil():
    ffiCurrentNotifyEventEnqueued()

  let completed = await fut.withTimeout(chronos.milliseconds(timeoutMs))
  if not completed:
    # Late replies now find no parked future and are dropped by the drain.
    ffiPendingReverse.del(callId)
    return err("reverse call " & name & " timed out after " & $timeoutMs & " ms")
  # `fut` is finished here, so this await just unwraps it.
  return await fut
