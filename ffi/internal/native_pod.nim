## Compile-time generator for the native "POD mirror" machinery of a `{.ffi.}`
## type. For each registered type T it emits a C-struct-layout mirror `TPod`
## plus four overloads that move data across the FFI-thread boundary as a
## deep-copied POD graph in shared (`c_malloc`) memory — never GC'd memory,
## never aliasing the caller's or Nim's buffers:
##
##   clonePod(TPod): TPod   deep-copy incoming args off caller memory (request)
##   podToNim(TPod): T      rebuild the Nim object on the FFI thread
##   nimToPod(T): TPod      build a shared POD graph from a result / event
##   freePod(var TPod)      recursive free; generated from the same field list
##                          as the copy so the two cannot drift
##
## The emitted source is parsed with `parseStmt`; the shape mirrors the
## hand-validated scratch (ASAN- and leak-clean) so the codegen stays auditable.
## Runtime helpers (`alloc`/`dealloc`/`ffiCAllocArray`/`ffiCFree`) come from
## `ffi/alloc` and are visible wherever the user did `import ffi`.

import std/[strutils, macros]
import ../codegen/meta

proc podName(t: string): string =
  t.strip() & "Pod"

proc isStringType(t: string): bool =
  t in ["string", "cstring"]

proc isOptionType(t: string): bool =
  (t.startsWith("Option[") or t.startsWith("Maybe[")) and t.endsWith("]")

proc isSeqType(t: string): bool =
  t.startsWith("seq[") and t.endsWith("]")

proc optionInner(t: string): string =
  let p = if t.startsWith("Maybe["): 6 else: 7
  t[p .. ^2].strip()

proc seqInner(t: string): string =
  t[4 .. ^2].strip()

proc podScalarType(t: string): string =
  case t.strip()
  of "int", "int64", "clong": "int64"
  of "int32", "cint": "int32"
  of "int16": "int16"
  of "int8": "int8"
  of "uint", "uint64", "csize_t": "uint64"
  of "uint32", "cuint": "uint32"
  of "uint16": "uint16"
  of "uint8", "byte": "uint8"
  of "bool": "cint"
  of "float", "float64": "cdouble"
  of "float32": "cfloat"
  else: t.strip()

proc elemPodType(t: string, known: seq[string]): string =
  ## C-struct field type used for one element of a seq / payload of an Option.
  let s = t.strip()
  if isStringType(s):
    "cstring"
  elif s in known:
    podName(s)
  else:
    podScalarType(s)

# --- element-granular conversion expressions --------------------------------
# `src` is an expression yielding the element on the source side.

proc cloneElem(t, src: string, known: seq[string]): string =
  let s = t.strip()
  if isStringType(s): "alloc(" & src & ")"
  elif s in known: "clonePod(" & src & ")"
  else: src

proc toNimElem(t, src: string, known: seq[string]): string =
  let s = t.strip()
  if s == "string": "(if " & src & ".isNil: \"\" else: $" & src & ")"
  elif s == "cstring": src
  elif s in known: "podToNim(" & src & ")"
  elif s == "bool": "(" & src & " != 0)"
  else: src & "." & s

proc toPodElem(t, src: string, known: seq[string]): string =
  let s = t.strip()
  if isStringType(s): "alloc(" & src & ")"
  elif s in known: "nimToPod(" & src & ")"
  elif s == "bool": "(if " & src & ": 1 else: 0).cint"
  else: src & "." & podScalarType(s)

proc freeElem(t, access: string, known: seq[string]): string =
  ## Statement (or "" when nothing to free) releasing one element.
  let s = t.strip()
  if isStringType(s): "dealloc(" & access & ")"
  elif s in known: "freePod(" & access & ")"
  else: ""

proc elemUserType(t: string): string =
  t.strip()

# ---------------------------------------------------------------------------
# Per-field source fragments. Each returns indented lines (2 spaces).
# ---------------------------------------------------------------------------

type FieldSrc = object
  podDecl: seq[string]
  clone: seq[string]
  toNim: seq[string]
  toPod: seq[string]
  free: seq[string]

proc fieldSrc(name, typ: string, known: seq[string]): FieldSrc =
  var fs = FieldSrc()
  let t = typ.strip()

  if isSeqType(t):
    let e = seqInner(t)
    let ept = elemPodType(e, known)
    fs.podDecl = @["  " & name & ": ptr UncheckedArray[" & ept & "]", "  " & name & "Len: csize_t"]
    fs.clone =
      @[
        "  r." & name & "Len = s." & name & "Len",
        "  if s." & name & "Len.int > 0 and not s." & name & ".isNil:",
        "    r." & name & " = ffiCAllocArray(" & ept & ", s." & name & "Len.int)",
        "    for i in 0 ..< s." & name & "Len.int:",
        "      r." & name & "[i] = " & cloneElem(e, "s." & name & "[i]", known),
        "  else:",
        "    r." & name & " = nil",
      ]
    fs.toNim =
      @[
        "  r." & name & " = newSeq[" & elemUserType(e) & "](s." & name & "Len.int)",
        "  for i in 0 ..< s." & name & "Len.int:",
        "    r." & name & "[i] = " & toNimElem(e, "s." & name & "[i]", known),
      ]
    fs.toPod =
      @[
        "  r." & name & "Len = s." & name & ".len.csize_t",
        "  if s." & name & ".len > 0:",
        "    r." & name & " = ffiCAllocArray(" & ept & ", s." & name & ".len)",
        "    for i in 0 ..< s." & name & ".len:",
        "      r." & name & "[i] = " & toPodElem(e, "s." & name & "[i]", known),
        "  else:",
        "    r." & name & " = nil",
      ]
    let fe = freeElem(e, "p." & name & "[i]", known)
    fs.free.add("  if not p." & name & ".isNil:")
    if fe.len > 0:
      fs.free.add("    for i in 0 ..< p." & name & "Len.int:")
      fs.free.add("      " & fe)
    fs.free.add("    ffiCFree(cast[pointer](p." & name & "))")
    fs.free.add("    p." & name & " = nil")
    return fs

  if isOptionType(t):
    let e = optionInner(t)
    let ept = elemPodType(e, known)
    fs.podDecl = @["  " & name & "Present: cint", "  " & name & ": " & ept]
    fs.clone =
      @[
        "  r." & name & "Present = s." & name & "Present",
        "  if s." & name & "Present != 0:",
        "    r." & name & " = " & cloneElem(e, "s." & name, known),
      ]
    fs.toNim =
      @[
        "  if s." & name & "Present != 0:",
        "    r." & name & " = some(" & toNimElem(e, "s." & name, known) & ")",
        "  else:",
        "    r." & name & " = none(" & elemUserType(e) & ")",
      ]
    fs.toPod =
      @[
        "  r." & name & "Present = (if s." & name & ".isSome: 1 else: 0).cint",
        "  if s." & name & ".isSome:",
        "    r." & name & " = " & toPodElem(e, "s." & name & ".get", known),
      ]
    let fe = freeElem(e, "p." & name, known)
    if fe.len > 0:
      fs.free = @["  if p." & name & "Present != 0:", "    " & fe]
    return fs

  if isStringType(t):
    fs.podDecl = @["  " & name & ": cstring"]
    fs.clone = @["  r." & name & " = alloc(s." & name & ")"]
    if t == "cstring":
      fs.toNim = @["  r." & name & " = s." & name]
    else:
      fs.toNim = @["  r." & name & " = (if s." & name & ".isNil: \"\" else: $s." & name & ")"]
    fs.toPod = @["  r." & name & " = alloc(s." & name & ")"]
    fs.free = @["  dealloc(p." & name & ")", "  p." & name & " = nil"]
    return fs

  if t in known: # nested {.ffi.} struct, by value
    fs.podDecl = @["  " & name & ": " & podName(t)]
    fs.clone = @["  r." & name & " = clonePod(s." & name & ")"]
    fs.toNim = @["  r." & name & " = podToNim(s." & name & ")"]
    fs.toPod = @["  r." & name & " = nimToPod(s." & name & ")"]
    fs.free = @["  freePod(p." & name & ")"]
    return fs

  # scalar / bool / float
  fs.podDecl = @["  " & name & ": " & podScalarType(t)]
  fs.clone = @["  r." & name & " = s." & name]
  if t == "bool":
    fs.toNim = @["  r." & name & " = (s." & name & " != 0)"]
    fs.toPod = @["  r." & name & " = (if s." & name & ": 1 else: 0).cint"]
  else:
    fs.toNim = @["  r." & name & " = s." & name & "." & t]
    fs.toPod = @["  r." & name & " = s." & name & "." & podScalarType(t)]
  return fs

proc buildPodSource*(
    typeName: string, fields: seq[FFIFieldMeta], known: seq[string]
): string =
  ## Emits the full POD-mirror + 4-overload source block for `typeName`.
  let pod = podName(typeName)
  var frags: seq[FieldSrc] = @[]
  for f in fields:
    frags.add(fieldSrc(f.name, f.typeName, known))

  var L: seq[string] = @[]

  # POD mirror type
  L.add("type " & pod & " {.bycopy.} = object")
  if frags.len == 0:
    L.add("  discardField: uint8") # keep the object non-empty / well-formed
  else:
    for fr in frags:
      L.add(fr.podDecl)
  L.add("")

  # freePod
  L.add("proc freePod(p: var " & pod & ") =")
  var freeBody: seq[string] = @[]
  for fr in frags:
    freeBody.add(fr.free)
  if freeBody.len == 0:
    L.add("  discard")
  else:
    L.add(freeBody)
  L.add("")

  # clonePod
  L.add("proc clonePod(s: " & pod & "): " & pod & " =")
  L.add("  var r: " & pod)
  for fr in frags:
    L.add(fr.clone)
  L.add("  return r")
  L.add("")

  # podToNim
  L.add("proc podToNim(s: " & pod & "): " & typeName & " =")
  L.add("  var r: " & typeName)
  for fr in frags:
    L.add(fr.toNim)
  L.add("  return r")
  L.add("")

  # nimToPod
  L.add("proc nimToPod(s: " & typeName & "): " & pod & " =")
  L.add("  var r: " & pod)
  for fr in frags:
    L.add(fr.toPod)
  L.add("  return r")
  L.add("")

  return L.join("\n")

var pendingPodSources* {.compileTime.}: seq[string]
  ## POD-machinery source queued by `{.ffi.}` type registration, drained into
  ## the next proc-macro expansion. A type-pragma macro can't return a
  ## `StmtList` of (type + procs) — Nim rejects it as illformed — so the procs
  ## ride along with the following `.ffi.`/ctor/dtor proc instead (statement
  ## context, where a `StmtList` is legal). Every type is declared before the
  ## proc that uses it, so its overloads are in scope by the time they're called.

proc queuePodMachinery*(
    typeName: string, fields: seq[FFIFieldMeta], known: seq[string]
) {.compileTime.} =
  pendingPodSources.add(buildPodSource(typeName, fields, known))

proc flushPendingPods*(): NimNode {.compileTime.} =
  ## Drains the queued POD machinery into an AST block (empty when none pending).
  if pendingPodSources.len == 0:
    return newStmtList()
  let src = pendingPodSources.join("\n")
  pendingPodSources.setLen(0)
  return parseStmt(src)
