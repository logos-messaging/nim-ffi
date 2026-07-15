## Runtime cstring alloc/free for the macro-generated `*_CWire` types.

import ../alloc

proc cwireAllocStr*(s: string): cstring {.inline.} =
  ## NUL-terminated `malloc` copy of `s`; pair with `cwireFreeStr`.
  alloc.alloc(s)

proc cwireFreeStr*(s: var cstring) {.inline.} =
  ## Idempotent free; reset to `nil` so a repeated call can't double-free.
  if s.isNil():
    return
  alloc.dealloc(s)
  s = nil
