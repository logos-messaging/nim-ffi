import chronos
import ./ret_codes

export ret_codes

type FFICallBack* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}
  ## Result-delivery callback. `RET_OK`/`RET_ERR` fire once and end the request;
  ## `RET_STALE_WARN` may fire repeatedly before them.

type FFIRequestProc* = proc(
  request: pointer, reqHandler: pointer
): Future[Result[seq[byte], string]] {.async.}
  ## OK payload is a CBOR-encoded response body; errors are plain UTF-8.

const ffiForeignGcTeardownIsDestructive* =
  defined(gcDestructors) and compileOption("threads") and
  (NimMajor, NimMinor, NimPatch) >= (2, 2, 12)
  ## True when `tearDownForeignThreadGc()` releases the calling thread's
  ## allocator region instead of doing nothing.
  ##
  ## Nim 2.2.12 (commit 4feb16edf, "Memregion pool no handle",
  ## nim-lang/Nim#26110) gates a new chunk layout on
  ## `hasThreadSupport and defined(gcDestructors)`. Chunk owners become
  ## `ptr RegionHandle`, kept in `allocator.regionHandle`, and the teardown
  ## becomes `releaseMemRegion`: it zeroes the thread's whole `MemRegion`, that
  ## handle included, and returns the handle to a global pool. Nothing
  ## re-acquires it, so the thread's next allocation mints chunks with a nil
  ## owner and then dereferences it in `fetchSharedCells`
  ## (`lib/system/alloc.nim`).
  ##
  ## Both older configurations are unaffected, which is why this is a version
  ## and memory-manager test rather than an unconditional change:
  ##
  ## - ARC/ORC up to 2.2.10 stubbed both procs out as no-op templates
  ##   (`lib/system/arc.nim`).
  ## - refc, on every version, still early-returns from the teardown unless the
  ##   calling thread really is foreign (`lib/system/gc_common.nim`).
  ##
  ## Nim exposes no way to detect this from user code: `releaseThreadAllocator`
  ## is not exported, so `declared()` cannot see it, and `threadType` exists
  ## only under refc. Erring towards `true` is the safe direction — skipping a
  ## teardown that would have done nothing costs nothing, while making a
  ## destructive one corrupts the heap.

template foreignThreadGc*(body: untyped) =
  ## Registers the calling thread with the Nim runtime for the duration of
  ## `body`, for blocks that hand control to a foreign callback.
  ##
  ## Every call site in this library runs on a thread the Nim runtime created —
  ## the FFI thread and the event thread (`createThread`, `ffi/ffi_context.nim`),
  ## or the main thread in tests — and each keeps allocating long after the block
  ## returns, so the teardown is skipped wherever it would be destructive. A
  ## genuinely foreign host thread enters through `initializeLibrary`
  ## (`ffi/internal/ffi_library.nim`), which calls `setupForeignThreadGc()` once
  ## for the life of the thread and never tears down.
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc) and not ffiForeignGcTeardownIsDestructive:
    tearDownForeignThreadGc()
