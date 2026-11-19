## The state a context keeps for a host that pulls its messages: the wake, the
## message order and the event a host is still reading.

import std/[atomics, strutils]
import results
import unittest2
import ../../ffi
import ../../ffi/[ffi_events, ffi_msg, ffi_outbound, ffi_wake]

proc bytesOf(s: string): seq[byte] =
  var out0: seq[byte] = @[]
  for c in s:
    out0.add(byte(ord(c)))
  return out0

proc payloadOf(held: HeldEvent): string =
  var out0 = ""
  for i in 0 ..< held.event.dataLen:
    out0.add(char(held.event.data[i]))
  return out0

proc enqueue(
    q: var EventQueue, name: string, seqNum: uint64, body: string
): EnqueueResult =
  var bytes = bytesOf(body)
  let src =
    if bytes.len > 0:
      cast[pointer](addr bytes[0])
    else:
      nil
  return q.tryEnqueueEvent(cstring(name), nameId(name), seqNum, src, bytes.len)

suite "the wake fires once per burst":
  test "a second enqueue does not fire it again until the poller disarms":
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    outb.notifyOutbound()
    check outb.wakeArmed.load()
    check outb.wake.waitFor(0)

    outb.notifyOutbound() # still armed: no second syscall
    check outb.wake.waitFor(0)

    # What a poller disarms, then re-checks the queues, then waits
    outb.wakeArmed.store(false)
    outb.wake.clear()
    check not outb.wake.waitFor(0)

    outb.notifyOutbound()
    check outb.wake.waitFor(0)

  test "closing wakes a poller whatever the wake was doing":
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()
    outb.closeOutbound(7'u)
    check outb.closedGeneration.load() == 7'u
    check outb.wake.waitFor(0)

suite "messages are numbered in production order":
  test "seqNum starts at 1 and never repeats":
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()
    check outb.nextSeq() == 1'u64
    check outb.nextSeq() == 2'u64
    check outb.nextSeq() == 3'u64

suite "an event the host reads outlives its ring slot":
  test "a pop moves the bytes out and frees the slot":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    check q.enqueue("on_echo_fired", outb.nextSeq(), "first") == EnqueueResult.Queued
    check q.enqueue("on_echo_fired", outb.nextSeq(), "second") == EnqueueResult.Queued
    check q.count == 2

    check q.popEventInto(outb.held)
    check q.count == 1 # the slot is free again, with the bytes still readable
    check outb.held.event.nameId == nameId("on_echo_fired")
    check outb.held.event.seqNum == 1'u64
    check payloadOf(outb.held) == "first"
    check $outb.held.event.name == "on_echo_fired"

    check q.popEventInto(outb.held)
    check payloadOf(outb.held) == "second"
    check not q.popEventInto(outb.held)

  test "a payload too big for the slab survives the same way":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    let big = repeat('x', MaxEventPayloadBytes + 32)
    check q.enqueue("on_echo_fired", 1'u64, big) == EnqueueResult.Queued
    check q.popEventInto(outb.held)
    check payloadOf(outb.held) == big

  test "an event named \"\" keeps its name when its slot is reused":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    check q.enqueue("", 1'u64, "empty-named") == EnqueueResult.Queued
    check q.popEventInto(outb.held)
    # A full lap of the ring writes into the slot the popped event came from.
    for i in 0 ..< EventQueueCapacity:
      check q.enqueue("on_echo_fired", uint64(i + 2), "next") == EnqueueResult.Queued
    check $outb.held.event.name == ""
    check payloadOf(outb.held) == "empty-named"

  test "clearing drops what the next owner of the slot must not see":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    check q.enqueue("on_echo_fired", 1'u64, "stale") == EnqueueResult.Queued
    outb.dropQueuedMessages(q)
    check q.count == 0
    check not q.popEventInto(outb.held)

suite "event queue limits":
  test "a full ring drops and counts, and takes events again once drained":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    for i in 0 ..< EventQueueCapacity:
      check q.enqueue("on_echo_fired", uint64(i + 1), "x") == EnqueueResult.Queued
    check q.enqueue("on_echo_fired", 0'u64, "lost") == EnqueueResult.DroppedSlots
    check q.dropCounts() == EventDrops(ringFull: 1)

    check q.popEventInto(outb.held)
    check q.enqueue("on_echo_fired", 0'u64, "fits") == EnqueueResult.Queued

    q.resetDropCounts()
    check q.dropCounts() == EventDrops()

  test "the byte cap drops what would pass it, and frees on pop":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    let half = repeat('x', MaxEventQueueBytes div 2)
    check q.enqueue("e", 1'u64, half) == EnqueueResult.Queued
    # The name bytes take the second half over the cap.
    check q.enqueue("e", 2'u64, half) == EnqueueResult.DroppedBytes
    check q.dropCounts() == EventDrops(byteCapExceeded: 1)
    check q.count == 1

    check q.popEventInto(outb.held)
    check q.bytes == 0
    check q.enqueue("e", 3'u64, half) == EnqueueResult.Queued

template withThreadQueue(q: untyped) =
  var q: EventQueue
  check initEventQueue(q).isOk()
  ffiCurrentEventQueue = addr q
  defer:
    ffiCurrentEventQueue = nil
    deinitEventQueue(q)

suite "producing an event on the FFI thread":
  test "enqueueFFIEvent reports DroppedNoQueue when the thread has no queue":
    ffiCurrentEventQueue = nil
    check enqueueFFIEvent("e", nil, 0) == EnqueueResult.DroppedNoQueue

  test "enqueueFFIEvent reports Queued and stores the event":
    withThreadQueue(q)

    var payload = bytesOf("abc")
    check enqueueFFIEvent("e", addr payload[0], payload.len) == EnqueueResult.Queued
    check q.count == 1
    check q.bytes == 2 + 3

  test "enqueueFFIEvent reports DroppedSlots when the ring is full":
    withThreadQueue(q)

    for i in 0 ..< EventQueueCapacity:
      check enqueueFFIEvent("e", nil, 0) == EnqueueResult.Queued
    check enqueueFFIEvent("e", nil, 0) == EnqueueResult.DroppedSlots
    check q.dropCounts() == EventDrops(ringFull: 1)

  test "dispatchFFIEvent yields the enqueue result":
    ffiCurrentEventQueue = nil
    let dropped = dispatchFFIEvent("e"):
      "x"
    check dropped == EnqueueResult.DroppedNoQueue

    withThreadQueue(q)
    let queued = dispatchFFIEvent("e"):
      "x"
    check queued == EnqueueResult.Queued
    check q.count == 1

  test "dispatchFFIEventCbor yields the enqueue result":
    ffiCurrentEventQueue = nil
    let dropped = dispatchFFIEventCbor("e", 0)
    check dropped == EnqueueResult.DroppedNoQueue

    withThreadQueue(q)
    let queued = dispatchFFIEventCbor("e", 0)
    check queued == EnqueueResult.Queued
    check q.count == 1

suite "the byte count follows every way out of the queue":
  test "clearing returns the byte count to 0":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)

    check q.enqueue("e", 1'u64, "abc") == EnqueueResult.Queued
    check q.enqueue("e", 2'u64, repeat('x', MaxEventPayloadBytes + 32)) ==
      EnqueueResult.Queued
    check q.bytes == (2 + 3) + (2 + MaxEventPayloadBytes + 32)
    q.clearEventQueue()
    check q.bytes == 0
    check q.count == 0

  test "committing a dequeue returns the byte count to 0":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)

    check q.enqueue("e", 1'u64, "abc") == EnqueueResult.Queued
    check q.bytes == 5
    q.commitDequeue()
    check q.bytes == 0
    check q.count == 0

suite "overflow watch":
  test "a burst is no notice, sustained drops are one, quiet clears it":
    const S = EventOverflowSustainMs
    var w = OverflowWatch()
    check w.step(5, 0) == OverflowChange.NoChange # primes on what is already counted
    check w.step(6, 10) == OverflowChange.NoChange
    check w.step(6, 10 + S + 1) == OverflowChange.NoChange # the burst ended silently

    check w.step(7, 2 * S) == OverflowChange.NoChange
    check w.step(8, 3 * S) == OverflowChange.Sustained
    check w.step(9, 3 * S + 1) == OverflowChange.NoChange
    check w.step(9, 4 * S + 2) == OverflowChange.Cleared
    check w.step(9, 5 * S) == OverflowChange.NoChange
