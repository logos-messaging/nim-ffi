## Intrusive multi-producer / single-consumer queue of `ptr FFIThreadRequest`
## (Vyukov's MPSC algorithm). It replaces the single-slot SPSC channel plus the
## global submit lock that used to serialise every foreign-thread call: foreign
## threads `push` concurrently with a single atomic exchange (wait-free), while
## the FFI thread is the sole `pop`per.
##
## The request *is* the queue node — its `next` link is reused intrusively — so
## enqueueing allocates nothing. The one node the algorithm needs of its own,
## the stub sentinel, is embedded inline in the queue (hence inline in the
## owning `FFIContext`): it carries no separate heap allocation, so a context
## that is intentionally abandoned (wedged-thread shutdown) leaks nothing extra,
## and it never sits on a per-thread ORC `MemRegion` the way `allocShared` would
## (the dangling-TLS hazard documented in `ffi_thread_request.nim`).

import std/atomics
import ./ffi_thread_request

type FFIRequestQueue* = object
  head: Atomic[ptr FFIThreadRequest] ## producers swap here
  tail: ptr FFIThreadRequest ## consumer-only cursor
  stub: FFIThreadRequest ## inline dummy sentinel, never dispatched

proc initRequestQueue*(q: var FFIRequestQueue) =
  q.stub.next.store(nil, moRelaxed)
  q.head.store(addr q.stub, moRelaxed)
  q.tail = addr q.stub

proc push*(q: var FFIRequestQueue, node: ptr FFIThreadRequest) =
  ## Wait-free enqueue, safe from any number of producer threads.
  node[].next.store(nil, moRelease)
  let prev = q.head.exchange(node, moAcquireRelease)
  prev[].next.store(node, moRelease)

proc pop*(q: var FFIRequestQueue): ptr FFIThreadRequest =
  ## Single-consumer dequeue. Returns nil when empty, or transiently when a
  ## producer's exchange has linked a node but its `prev.next` store hasn't
  ## landed yet — the caller (polling FFI thread) simply retries next wake.
  let stub = addr q.stub
  var tail = q.tail
  var next = tail[].next.load(moAcquire)
  if tail == stub:
    if next.isNil():
      return nil
    q.tail = next
    tail = next
    next = next[].next.load(moAcquire)
  if not next.isNil():
    q.tail = next
    return tail
  if tail != q.head.load(moAcquire):
    return nil
  q.push(stub)
  next = tail[].next.load(moAcquire)
  if not next.isNil():
    q.tail = next
    return tail
  nil
