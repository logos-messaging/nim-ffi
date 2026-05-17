## Runtime helpers used by the macro-generated *_CWire companion types.
##
## When `-d:ffiMode=raw` is active, the {.ffi.} macro emits — alongside
## every user-declared {.ffi.} type and every per-proc Req/Resp — a parallel
## `*_CWire` Nim object whose field layout matches the C struct emitted by
## ffi/codegen/c.nim. Strings become `cstring`, `seq[T]` becomes the
## `<name>_items + <name>_len` pair, and so on.
##
## These wire structs live in **shared memory** (allocShared) so they can
## travel from the foreign caller's thread through the FFI thread channel
## and back to the callback without touching either side's GC heap. This
## module concentrates the alloc/copy/free primitives in one place so the
## generated code stays narrow.
##
## Naming convention:
##   - `cwireAllocStr`  — copy a Nim `string` into a fresh shared-memory cstring.
##   - `cwireFreeStr`   — release a shared-memory cstring (nil-safe).
##   - `cwireCopyOpt[T]`/`cwireFreeOpt[T]` — Phase 2 helpers for `Option[T]`.
##   - `cwireAllocSeq[T]`/`cwireFreeSeq[T]` — Phase 2 helpers for `seq[T]`.
##
## All allocation is via `allocShared`; freeing uses `deallocShared`. Lifetimes
## are owned by the surrounding wire struct: pack→use→free is the lifecycle.

import ../alloc

# ---------------------------------------------------------------------------
# String helpers
# ---------------------------------------------------------------------------

proc cwireAllocStr*(s: string): cstring =
  ## Allocate a NUL-terminated copy of `s` in shared memory. Returns a
  ## `cstring` owned by the caller — pair with `cwireFreeStr`. Empty input
  ## produces a 1-byte buffer holding only the terminator (so the C side
  ## never sees a NULL when the user supplied "").
  return alloc.alloc(s)

proc cwireFreeStr*(s: cstring) {.inline.} =
  ## Idempotent free for a shared-memory cstring. `nil` is a no-op so the
  ## generated cwireFree procs can call this on every field without
  ## tracking which were ever assigned.
  if not s.isNil:
    deallocShared(s)

# ---------------------------------------------------------------------------
# Option helpers (Phase 2)
# ---------------------------------------------------------------------------

proc cwireAllocOpt*[T](src: pointer): pointer {.inline.} =
  ## Placeholder; Phase 2 implements typed Option allocations via the
  ## macro-generated cwireFree for the inner type.
  return src

proc cwireFreeOpt*[T](
    p: pointer, freeInner: proc(p: pointer) {.nimcall, raises: [], gcsafe.}
) =
  if p.isNil:
    return
  freeInner(p)
  deallocShared(p)
