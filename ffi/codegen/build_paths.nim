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

func buildSplitPath(path: string): seq[string] =
  ## Components of `path`, split on either separator: a build path may carry
  ## both when it came from a config file written elsewhere.
  var
    components: seq[string] = @[]
    part = ""
  for c in path:
    if c in {'/', '\\'}:
      if part.len > 0:
        components.add(part)
        part = ""
    else:
      part.add(c)
  if part.len > 0:
    components.add(part)
  return components

func buildIsAbsolute*(path: string): bool =
  ## Absolute for `buildOS`. `std/os.isAbsolute` answers for the target, which
  ## is the wrong question for a path the compiler itself writes.
  if path.len == 0:
    return false
  when buildOS == "windows":
    path[0] in {'/', '\\'} or
      (path.len >= 3 and path[1] == ':' and path[2] in {'/', '\\'})
  else:
    path[0] == '/'

func buildRelativePath*(path, base: string): string =
  ## `path` seen from `base`, joined for `buildOS`. Unlike `std/os.relativePath`
  ## it never consults the current directory and never emits a target separator;
  ## a non-absolute argument is returned unchanged rather than guessed at.
  if not buildIsAbsolute(path) or not buildIsAbsolute(base):
    return path
  let
    pathParts = buildSplitPath(path)
    baseParts = buildSplitPath(base)
  var shared = 0
  while shared < pathParts.len and shared < baseParts.len and
      pathParts[shared] == baseParts[shared]:
    inc(shared)
  var parts: seq[string]
  for _ in shared ..< baseParts.len:
    parts.add("..")
  for i in shared ..< pathParts.len:
    parts.add(pathParts[i])
  if parts.len == 0:
    return "."
  var relative = parts[0]
  for i in 1 ..< parts.len:
    relative = buildPath(relative, parts[i])
  return relative

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
