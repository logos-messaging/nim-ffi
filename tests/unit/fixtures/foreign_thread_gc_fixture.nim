## Fixture for test_foreign_thread. A long-lived Nim thread allocates inside and after `foreignThreadGc`, like the FFI and event threads.

import ffi/ffi_types

var thr: Thread[void]

proc worker() {.thread.} =
  var pending: seq[string] = @[]

  for round in 0 ..< 200:
    foreignThreadGc:
      pending.add("round-" & $round)

    # Nim 2.2.12 ARC/ORC crashes here if the block tore down the thread allocator.
    for i in 0 ..< 32:
      pending.add("filler-" & $round & "-" & $i)

createThread(thr, worker)
joinThread(thr)
