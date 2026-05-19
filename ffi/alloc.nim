## Cross-thread allocation helpers backed by libc `malloc`/`free`.
##
## We deliberately avoid Nim's `allocShared`/`deallocShared` here. Under
## `--mm:orc` they delegate to the per-thread `allocator` MemRegion stored
## in TLS; freeing such a buffer from a different thread later walks
## `chunk.owner` back to that MemRegion. If the original thread has exited
## by then (e.g. a `std::async` worker that produced the FFI request and
## was destroyed before the FFI thread ran `deleteRequest`), `chunk.owner`
## dangles into reclaimed TLS and `addToSharedFreeList` segfaults — TSan on
## ARM reproduces this from `TimerE2E.ThreadedHammer`. `malloc`/`free` are
## process-global and thread-lifetime-independent, so freeing on a different
## thread is safe.

import system/ansi_c

## Can be shared safely between threads
type SharedSeq*[T] = tuple[data: ptr UncheckedArray[T], len: int]

proc alloc*(str: cstring): cstring =
  ## Allocates a fresh null-terminated copy of `str` via `c_malloc`. The
  ## returned pointer must be released with `dealloc(cstring)`.
  if str.isNil():
    var ret = cast[cstring](c_malloc(1))
    ret[0] = '\0'
    return ret

  let ret = cast[cstring](c_malloc(csize_t(len(str) + 1)))
  copyMem(ret, str, len(str) + 1)
  return ret

proc alloc*(str: string): cstring =
  ## Allocates a fresh null-terminated copy of `str` via `c_malloc`. The
  ## returned pointer must be released with `dealloc(cstring)`.
  var ret = cast[cstring](c_malloc(csize_t(str.len + 1)))
  let s = cast[seq[char]](str)
  for i in 0 ..< str.len:
    ret[i] = s[i]
  ret[str.len] = '\0'
  return ret

proc dealloc*(p: cstring) {.inline.} =
  ## Frees a buffer obtained from one of the `alloc(...)` overloads above.
  ## Nil-safe.
  if not p.isNil():
    c_free(cast[pointer](p))

proc allocSharedSeq*[T](s: seq[T]): SharedSeq[T] =
  if s.len == 0:
    return (cast[ptr UncheckedArray[T]](nil), 0)

  let data = c_malloc(csize_t(sizeof(T) * s.len))
  copyMem(data, unsafeAddr s[0], sizeof(T) * s.len)
  return (cast[ptr UncheckedArray[T]](data), s.len)

proc deallocSharedSeq*[T](s: var SharedSeq[T]) =
  if not s.data.isNil():
    c_free(s.data)
  s.len = 0

proc toSeq*[T](s: SharedSeq[T]): seq[T] =
  ## Creates a seq[T] from a SharedSeq[T]. No explicit dealloc is required
  ## as req[T] is a GC managed type.
  var ret = newSeq[T]()
  for i in 0 ..< s.len:
    ret.add(s.data[i])
  return ret
