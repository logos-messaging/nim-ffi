## Unicode-aware identifier casing and doc-comment rendering, shared by codegen
## and the FFI macro.

import std/[strutils, unicode]

func docLines(doc: string): seq[string] =
  ## `doc` split into lines, trailing blank ones dropped.
  if doc.strip().len == 0:
    return @[]
  var lines = doc.splitLines()
  while lines.len > 0 and lines[^1].strip().len == 0:
    lines.setLen(lines.len - 1)
  return lines

func renderDocComment*(doc, indent, prefix: string): seq[string] =
  ## `doc` as one `prefix`-led line comment per source line, at `indent`.
  var rendered: seq[string] = @[]
  for line in docLines(doc):
    # A trailing `\` would splice the next generated line into a `//` comment.
    rendered.add(
      indent & (prefix & line).strip(leading = false, chars = Whitespace + {'\\'})
    )
  return rendered

func renderMemberDocComment*(doc: string): seq[string] =
  ## `///` at the indent C++ class members and Rust `impl` items sit at.
  return doc.renderDocComment("    ", "/// ")

func escapeBlockComment(line: string): string =
  ## `*/` would close the comment early and splice the rest in as code.
  return line.replace("*/", "* /")

func renderBlockDocComment*(doc: string, indent = ""): seq[string] =
  ## `doc` as a `/** ... */` block at `indent`; one-liners stay on one line.
  let lines = docLines(doc)
  if lines.len == 0:
    return @[]
  if lines.len == 1:
    return @[indent & "/** " & escapeBlockComment(lines[0].strip()) & " */"]
  var rendered = @[indent & "/**"]
  for line in lines:
    rendered.add((indent & " * " & escapeBlockComment(line)).strip(leading = false))
  rendered.add(indent & " */")
  return rendered

const RemoveListenerDoc* = """Unregister a listener by id.
A call from another thread returns after the last delivery to that listener,
so its user data is then safe to free.
A call from inside a listener callback returns at once, and the dispatch in
flight can still deliver to a listener that you remove that way. Keep the user
data of that listener alive until the dispatch ends."""

const ShutdownDoc* =
  """Stop every context the library still holds and join their threads.
A host that destroys what it created needs no call here: the pool joins a
context's threads once no context is live. Call it before the process exits
when a context is still alive, or when a static proc built the shared context.
A context you had not destroyed is stopped where it stands and its handle
retired, so a later call on it fails instead of queueing to a dead thread. Its
library teardown still runs, so do not repeat that cleanup yourself.
Returns 0 when every context stopped, 1 when one was left running."""

const RemoveListenerBoxDoc* =
  """Call it from inside a listener callback only for the listener that runs.
A remove of a different listener releases a box that the dispatch in flight can
still call."""

const CtxRemoveListenerDoc* =
  "Unregister a listener and release the box that holds the handler.\n" &
  RemoveListenerBoxDoc

proc toLower*(s: string): string =
  ## Unicode-aware lowercase for an entire string.
  var buf = ""
  for r in runes(s):
    buf.add($r.toLower())
  return buf

proc camelToSnakeCase*(s: string): string =
  ## camelCase → snake_case, e.g. "delayMs" → "delay_ms".
  var snake = ""
  var first = true
  for r in runes(s):
    if r.isUpper() and not first:
      snake.add('_')
    snake.add($r.toLower())
    first = false
  return snake

func capitalizeFirstLetter*(s: string): string =
  ## Returns `s` with its first rune uppercased, rest unchanged.
  if s.len == 0:
    return s
  var runesSeq = toRunes(s)
  runesSeq[0] = runesSeq[0].toUpper()
  return $runesSeq

func identToUpperSnake*(s: string): string =
  ## Nim identifier → UPPER_SNAKE, keeping acronym runs intact: "maxPeers" and
  ## "MAX_PEERS" both give "MAX_PEERS", "httpTTL" gives "HTTP_TTL".
  var upper = ""
  let rs = toRunes(s)
  for i, r in rs:
    if r == Rune('_'):
      if upper.len > 0 and upper[^1] != '_':
        upper.add('_')
      continue
    let startsWord =
      i > 0 and r.isUpper() and
      (not rs[i - 1].isUpper() or (i + 1 < rs.len and rs[i + 1].isLower()))
    if startsWord and upper.len > 0 and upper[^1] != '_':
      upper.add('_')
    upper.add($r.toUpper())
  return upper

proc snakeToPascalCase*(s: string): string =
  ## snake_case → PascalCase, e.g. "hello_world" → "HelloWorld".
  let parts = s.split('_')
  var pascal = ""
  for p in parts:
    pascal.add capitalizeFirstLetter(p)
  return pascal
