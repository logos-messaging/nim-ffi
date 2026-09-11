## Fixture for test_foreign_thread_gc. It drives `foreignThreadGc` the way the
## FFI and event threads do: a long-lived Nim thread enters the template once per
## delivered result and keeps allocating between and after those blocks.
##
## A `tearDownForeignThreadGc()` at the end of the template releases this
## thread's allocator region handle, so the next allocation mints chunks with a
## nil owner. Under `--mm:orc --threads:on` on Nim >= 2.2.12 that is a hard
## crash (SIGSEGV on Linux, an endless spin on macOS); earlier compilers stubbed
## the teardown out and never noticed.

import ffi/ffi_types

var thr: Thread[void]

proc deliver(round: int): string =
  ## Stands in for a foreign callback: allocates, and is called from inside the
  ## `foreignThreadGc` block just as `fireCallback` calls into C.
  result = "round-" & $round

proc worker() {.thread.} =
  # Grown past SmallChunkSize (one page) so rawAlloc takes the big-chunk path
  # as well as the small-cell path.
  var pending: seq[string] = @[]

  for round in 0 ..< 200:
    foreignThreadGc:
      let msg = deliver(round)
      pending.add(msg)

    # The thread keeps working after the block returns. This is the allocation
    # that a trailing teardown turns into a nil-owner dereference.
    for i in 0 ..< 32:
      pending.add("filler-" & $round & "-" & $i)

  echo "rounds completed, pending=", pending.len

createThread(thr, worker)
joinThread(thr)
echo "fixture OK"
