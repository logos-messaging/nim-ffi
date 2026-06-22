## Runtime helpers for the macro-generated `*_CWire` companion types: only the
## `cstring` fields need allocation here (seq/Option are alloc'd inline by the
## macro), packed on pack and released on free.

import ../alloc

proc cwireAllocStr*(s: string): cstring {.inline.} =
  ## NUL-terminated `malloc` copy of `s` (see `ffi/alloc.nim`); pair with
  ## `cwireFreeStr`. Empty input still yields a valid buffer, never NULL.
  alloc.alloc(s)

proc cwireFreeStr*(s: cstring) {.inline.} =
  ## Idempotent free for a `cwireAllocStr` cstring; `nil` is a no-op.
  if not s.isNil():
    alloc.dealloc(s)
