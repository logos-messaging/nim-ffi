## Registry + in-flight table backing typed host callbacks (`{.ffiHost.}`).
##
## This is the data-structure layer of roadmap item #1 (see
## docs/design-host-callbacks.md). It owns two per-context concerns and nothing
## else — the FFI-thread completion bridge and the `{.ffiHost.}` macro land in
## later increments and build on these primitives:
##
## 1. `FFIHostRegistry` — maps a wire name (e.g. "fetch_profile") to the host's
##    registered function pointer + userData. A missing entry is a normal,
##    non-fatal outcome (the imported proc resolves to an error), never a crash.
## 2. `FFIPendingTable` — maps a monotonic `token` to the chronos `Future` an
##    awaiting `{.ffiHost.}` proc is blocked on. The host answers later (on any
##    thread) by `token`; the FFI thread drains and completes the future.
##
## Both structures are lock-guarded so a host thread (registering / completing)
## and the FFI thread (looking up / completing) can touch them concurrently.
## Futures themselves are only ever completed on the FFI thread — `complete*`
## here is called from the loop drain, not from the host thread directly.

import std/[locks, tables]
import chronos
import ./ffi_types, ./alloc

# ---------------------------------------------------------------------------
# Host function pointer
# ---------------------------------------------------------------------------

type FFIHostFn* = proc(
  token: uint64, req: ptr cchar, reqLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}
  ## A host-implemented function. `req`/`reqLen` carry the marshaled request
  ## (valid only for the duration of the call — the host copies what it needs).
  ## The host answers asynchronously via `<lib>_host_complete(ctx, token, …)`.

type HostResult* = object
  ## The raw outcome the host delivered for one token: a return code plus the
  ## response bytes (native POD or CBOR — decoded by the awaiting proc).
  ret*: cint
  bytes*: seq[byte]

proc okResult*(bytes: seq[byte]): HostResult =
  return HostResult(ret: RET_OK, bytes: bytes)

proc resultText*(res: HostResult): string =
  ## The payload bytes as a string — used by the raw `{.ffiHost.}` path for both
  ## the success value (string return) and the error text.
  var s = newString(res.bytes.len)
  if res.bytes.len > 0:
    copyMem(addr s[0], unsafeAddr res.bytes[0], res.bytes.len)
  return s

proc errResult*(msg: string): HostResult =
  var b = newSeq[byte](msg.len)
  if msg.len > 0:
    copyMem(addr b[0], unsafeAddr msg[0], msg.len)
  return HostResult(ret: RET_ERR, bytes: b)

# ---------------------------------------------------------------------------
# Host function registry
# ---------------------------------------------------------------------------

type
  HostFnEntry = object
    fn: FFIHostFn
    userData: pointer

  FFIHostRegistry* = object
    lock: Lock
    fns: Table[string, HostFnEntry]

proc initHostRegistry*(reg: var FFIHostRegistry) =
  ## Call exactly once on the owning thread before sharing. The embedded `Lock`
  ## wraps a platform primitive that cannot be safely double-initialised.
  reg.lock.initLock()
  reg.fns = initTable[string, HostFnEntry]()

proc deinitHostRegistry*(reg: var FFIHostRegistry) =
  ## Mirror of `initHostRegistry`; call once, after all other threads have
  ## stopped using the registry. Resets the GC-managed table so pool slot reuse
  ## on another thread doesn't run a destructor against this thread's heap.
  reg.lock.deinitLock()
  reg.fns = default(Table[string, HostFnEntry])

proc registerHostFn*(
    reg: var FFIHostRegistry, name: string, fn: FFIHostFn, userData: pointer
): bool {.raises: [].} =
  ## Registers (or replaces) the host implementation for `name`. Returns false
  ## if `fn` is nil — the only documented failure — so a foreign caller can
  ## treat a nil pointer as "unregister intent" without crashing.
  if fn.isNil():
    withLock reg.lock:
      reg.fns.del(name)
    return false
  withLock reg.lock:
    reg.fns[name] = HostFnEntry(fn: fn, userData: userData)
  return true

proc lookupHostFn*(
    reg: var FFIHostRegistry, name: string
): tuple[fn: FFIHostFn, userData: pointer, found: bool] {.raises: [].} =
  ## Returns the registered `(fn, userData)` for `name`, or `found == false` when
  ## no host implementation exists — the awaiting proc turns that into an error.
  var entry: HostFnEntry
  var got = false
  withLock reg.lock:
    if reg.fns.hasKey(name):
      entry = reg.fns.getOrDefault(name)
      got = true
  return (entry.fn, entry.userData, got)

proc clearHostFns*(reg: var FFIHostRegistry) {.raises: [].} =
  withLock reg.lock:
    reg.fns.clear()

# ---------------------------------------------------------------------------
# In-flight completion table
# ---------------------------------------------------------------------------

type FFIPendingTable* = object
  lock: Lock
  nextToken: uint64 ## Monotonic; 0 is reserved as "invalid", tokens start at 1.
  pending: Table[uint64, Future[HostResult]]

# Set by the FFI thread at startup (see ffi_context.ffiThreadBody) so the body a
# `{.ffiHost.}` macro generates can reach its context's host registry + pending
# table without threading a ctx pointer through the user's signature.
var ffiCurrentHostRegistry* {.threadvar.}: ptr FFIHostRegistry
var ffiCurrentPendingTable* {.threadvar.}: ptr FFIPendingTable

proc initPendingTable*(tbl: var FFIPendingTable) =
  tbl.lock.initLock()
  tbl.nextToken = 0'u64
  tbl.pending = initTable[uint64, Future[HostResult]]()

proc deinitPendingTable*(tbl: var FFIPendingTable) =
  tbl.lock.deinitLock()
  tbl.pending = default(Table[uint64, Future[HostResult]])
  tbl.nextToken = 0'u64

proc newPending*(
    tbl: var FFIPendingTable
): tuple[token: uint64, fut: Future[HostResult]] =
  ## Allocates a token and registers a fresh, uncompleted future under it. The
  ## `{.ffiHost.}` proc awaits the returned future; the host answers by token.
  let fut = newFuture[HostResult]("ffiHostCall")
  var assigned: uint64 = 0
  withLock tbl.lock:
    tbl.nextToken.inc()
    assigned = tbl.nextToken
    tbl.pending[assigned] = fut
  return (assigned, fut)

proc completePending*(
    tbl: var FFIPendingTable, token: uint64, res: HostResult
): bool =
  ## Completes and removes the future for `token`. Returns false for an unknown
  ## or already-completed token — a late / double completion is dropped, not a
  ## crash. MUST be called on the FFI (event-loop) thread: it touches the
  ## chronos future.
  var fut: Future[HostResult] = nil
  withLock tbl.lock:
    if tbl.pending.hasKey(token):
      fut = tbl.pending.getOrDefault(token)
      tbl.pending.del(token)
  if fut.isNil() or fut.finished():
    return false
  fut.complete(res)
  return true

proc failAllPending*(tbl: var FFIPendingTable, msg: string) =
  ## Completes every outstanding future with an error and clears the table —
  ## used on context teardown so no awaiting handler is abandoned. FFI thread
  ## only.
  var futs: seq[Future[HostResult]] = @[]
  withLock tbl.lock:
    for _, fut in tbl.pending:
      futs.add(fut)
    tbl.pending.clear()
  for fut in futs:
    if not fut.isNil() and not fut.finished():
      fut.complete(errResult(msg))

proc pendingCount*(tbl: var FFIPendingTable): int {.raises: [].} =
  var n = 0
  withLock tbl.lock:
    n = tbl.pending.len
  return n

# ---------------------------------------------------------------------------
# Cross-thread completion queue
# ---------------------------------------------------------------------------
#
# `<lib>_host_complete` runs on the host's thread, but a chronos `Future` can
# only be completed on the FFI (event-loop) thread. So the host's answer is
# parked here and drained on the FFI thread. The producer side is **GC-free** —
# node and payload are `c_malloc`'d (ffiCMalloc / ffiCAllocArray) so no Nim GC
# runs on the foreign thread — mirroring how the rest of the boundary allocates.

type
  CompletionNode = object
    token: uint64
    ret: cint
    buf: ptr UncheckedArray[byte] ## c_malloc'd copy of the host payload (or nil)
    bufLen: int
    next: ptr CompletionNode

  FFICompletionQueue* = object
    lock: Lock
    head: ptr CompletionNode
    tail: ptr CompletionNode

proc initCompletionQueue*(q: var FFICompletionQueue) =
  q.lock.initLock()
  q.head = nil
  q.tail = nil

proc pushCompletion*(
    q: var FFICompletionQueue, token: uint64, ret: cint, msg: ptr cchar, len: csize_t
) {.raises: [].} =
  ## Enqueue one host answer. Safe to call from **any** thread; allocates only
  ## via c_malloc so it never touches the Nim GC on a foreign thread. The FFI
  ## thread copies the payload into a `seq[byte]` and frees the node on drain.
  let node = ffiCMalloc(CompletionNode)
  node.token = token
  node.ret = ret
  node.bufLen = int(len)
  node.next = nil
  if len > 0'u and not msg.isNil():
    node.buf = ffiCAllocArray(byte, int(len))
    copyMem(node.buf, msg, int(len))
  else:
    node.buf = nil
  withLock q.lock:
    if q.tail.isNil():
      q.head = node
    else:
      q.tail.next = node
    q.tail = node

proc drainCompletions*(
    q: var FFICompletionQueue, tbl: var FFIPendingTable
): int {.discardable.} =
  ## FFI-thread only. Detaches the whole queue, then for each entry resolves the
  ## pending future by token (copying the payload into GC memory here, on the FFI
  ## thread) and frees the c_malloc'd node. Returns the number drained.
  var head: ptr CompletionNode = nil
  withLock q.lock:
    head = q.head
    q.head = nil
    q.tail = nil

  var n = 0
  while not head.isNil():
    let node = head
    head = node.next
    var b = newSeq[byte](node.bufLen)
    if node.bufLen > 0:
      copyMem(addr b[0], node.buf, node.bufLen)
    discard completePending(tbl, node.token, HostResult(ret: node.ret, bytes: b))
    if not node.buf.isNil():
      ffiCFree(node.buf)
    ffiCFree(node)
    inc n
  return n

proc deinitCompletionQueue*(q: var FFICompletionQueue) =
  ## Frees any still-queued nodes (their futures are handled separately by
  ## `failAllPending` on teardown) and releases the lock.
  var head: ptr CompletionNode = nil
  withLock q.lock:
    head = q.head
    q.head = nil
    q.tail = nil
  while not head.isNil():
    let node = head
    head = node.next
    if not node.buf.isNil():
      ffiCFree(node.buf)
    ffiCFree(node)
  q.lock.deinitLock()
