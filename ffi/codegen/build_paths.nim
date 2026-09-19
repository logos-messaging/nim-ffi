## Files emitted by `genBindings` are written by Nim's compile-time VM on the
## build machine. `std/os` path joins use the target OS, which is wrong while
## cross-compiling, so codegen filesystem paths must be joined explicitly for
## `buildOS`.

import std/os
from system/nimscript import buildOS

const BuildDirSep = when buildOS == "windows": '\\' else: '/'

func buildPath*(head, tail: string): string =
  ## Joins two path components without normalising them for the target OS.
  if head.len == 0:
    return tail
  if tail.len == 0:
    return head

  var joinedPath = head
  if joinedPath[^1] notin {'/', '\\'}:
    joinedPath.add(BuildDirSep)

  var tailStart = 0
  while tailStart < tail.len and tail[tailStart] in {'/', '\\'}:
    inc(tailStart)
  if tailStart < tail.len:
    joinedPath.add(tail[tailStart .. ^1])
  return joinedPath

proc ensureOutputDir*(path: string) =
  createDir(path)
  if not dirExists(path):
    raise newException(
      IOError,
      "nim-ffi could not create binding output directory: " & path &
        ". When generating through `nim check`, pass " &
        "`--experimental:vmopsDanger`; otherwise check directory permissions.",
    )

proc writeOutputFile*(path, contents: string) =
  writeFile(path, contents)
  if not fileExists(path) or readFile(path) != contents:
    raise newException(
      IOError,
      "nim-ffi could not write generated binding file: " & path &
        ". When generating through `nim check`, pass " &
        "`--experimental:vmopsDanger`; otherwise check directory permissions.",
    )
