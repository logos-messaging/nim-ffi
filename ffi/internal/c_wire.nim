## Runtime helpers used by the macro-generated *_CWire companion types.
##
## For every `{.ffi: "abi = c".}` type (and every per-proc Req/Resp), the
## {.ffi.} macro emits — alongside the user-declared type — a parallel
## `*_CWire` Nim object whose field layout matches a flat C struct.
## Strings become `cstring`, `seq[T]` becomes the
## `<name>_items + <name>_len` pair, and so on.
##
## These wire structs live in **shared memory** (allocShared) so they can
## travel from the foreign caller's thread through the FFI thread channel
## and back to the callback without touching either side's GC heap. This
## module concentrates the alloc/copy/free primitives in one place so the
## generated code stays narrow.
##
## Only string fields need a runtime helper here: `seq[T]` and `Option[T]`
## are allocated/freed inline by the macro (`allocShared` of a
## `ptr UncheckedArray[T_CWire]` for seq, `allocShared(sizeof(T_CWire))`
## for the Option pointer). Lifetimes are owned by the surrounding wire
## struct: pack→use→free is the lifecycle.

import ../alloc

proc cwireAllocStr*(s: string): cstring =
  ## Allocate a NUL-terminated copy of `s` via the process-global `malloc`
  ## allocator (see `ffi/alloc.nim` for why not `allocShared`). Returns a
  ## `cstring` owned by the caller — pair with `cwireFreeStr`. Empty input
  ## produces a 1-byte buffer holding only the terminator (so the C side
  ## never sees a NULL when the user supplied "").
  alloc.alloc(s)

proc cwireFreeStr*(s: cstring) {.inline.} =
  ## Idempotent free for a cstring obtained from `cwireAllocStr`. Must match
  ## that allocator (`malloc`/`free`), so it routes through `alloc.dealloc`,
  ## not `deallocShared`. `nil` is a no-op so the generated cwireFree procs
  ## can call this on every field without tracking which were ever assigned.
  if not s.isNil():
    alloc.dealloc(s)
