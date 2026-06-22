## Runtime cstring alloc/free for the macro-generated `*_CWire` companions.
## String fields cross as `malloc`ed cstrings; seq/Option memory is inline.

import ../alloc

proc cwireAllocStr*(s: string): cstring =
  ## malloc-backed NUL-terminated copy of `s`, owned by the caller.
  ## Empty input still yields a non-NULL 1-byte buffer.
  alloc.alloc(s)

proc cwireFreeStr*(s: cstring) {.inline.} =
  ## Idempotent free matching `cwireAllocStr`; `nil` is a no-op.
  if not s.isNil():
    alloc.dealloc(s)
