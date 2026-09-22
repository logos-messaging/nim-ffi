## The state a context keeps for a host that pulls its messages: the wake, the
## message order and the event a host is still reading.

import std/[atomics, strutils]
import results
import unittest2
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

proc enqueue(q: var EventQueue, name: string, seq: uint64, body: string): bool =
  var bytes = bytesOf(body)
  let src =
    if bytes.len > 0:
      cast[pointer](addr bytes[0])
    else:
      nil
  return q.tryEnqueueEvent(cstring(name), nameId(name), seq, src, bytes.len)

suite "the wake fires once per burst":
  test "a second enqueue does not fire it again until the poller disarms":
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    outb.notifyOutbound()
    check outb.wakeArmed.load()
    check outb.wake.waitFor(0)

    outb.notifyOutbound() # still armed: no second syscall
    check outb.wake.waitFor(0)

    # What a poller does once it finds the queues empty.
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
  test "seq starts at 1 and never repeats":
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

    check q.enqueue("on_echo_fired", outb.nextSeq(), "first")
    check q.enqueue("on_echo_fired", outb.nextSeq(), "second")
    check q.count == 2

    check q.popEventInto(outb.held)
    check q.count == 1 # the slot is free again, with the bytes still readable
    check outb.held.event.nameId == nameId("on_echo_fired")
    check outb.held.event.seq == 1'u64
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
    check q.enqueue("on_echo_fired", 1'u64, big)
    check q.popEventInto(outb.held)
    check payloadOf(outb.held) == big

  test "clearing drops what the next owner of the slot must not see":
    var q: EventQueue
    check initEventQueue(q).isOk()
    defer:
      deinitEventQueue(q)
    var outb = FFIOutbound()
    check initOutbound(outb).isOk()

    check q.enqueue("on_echo_fired", 1'u64, "stale")
    outb.dropQueuedMessages(q)
    check q.count == 0
    check not q.popEventInto(outb.held)
