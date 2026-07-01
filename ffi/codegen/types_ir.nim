## Structured type IR shared by the C / C++ / Rust binding generators.
##
## The metadata registry spells Nim types as text (`"seq[Option[int]]"`). Each
## backend used to re-parse those strings with its own `startsWith`/slice logic,
## three copies that had already drifted apart. `parseFFIType` is the single
## parser; `renderNative` walks the resulting tree into a backend's native type
## string given a small per-language `NativeTypeMap`. C drives off `FFIType`
## directly (it monomorphises containers rather than rendering generics).

import std/[strutils, sets]

type
  ScalarKind* = enum
    skBool
    skI8
    skI16
    skI32
    skI64
    skU8
    skU16
    skU32
    skU64
    skF32
    skF64

  FFITypeKind* = enum
    ftScalar
    ftStr
    ftBytes
    ftSeq
    ftOpt
    ftPtr
    ftHandle
    ftStruct

  FFIType* = ref object
    case kind*: FFITypeKind
    of ftScalar:
      scalar*: ScalarKind
    of ftSeq, ftOpt:
      elem*: FFIType
    of ftStruct, ftHandle:
      name*: string
    else:
      discard

  NativeTypeMap* = object
    ## A backend's answer to "what do you call this kind?". `seqOf`/`optOf`
    ## wrap an already-rendered element (generic languages only); `structName`
    ## maps a user type name (e.g. Rust capitalises it).
    scalar*: proc(s: ScalarKind): string {.nimcall.}
    str*: string
    bytes*: string
    ptrType*: string
    seqOf*: proc(elem: string): string {.nimcall.}
    optOf*: proc(elem: string): string {.nimcall.}
    structName*: proc(name: string): string {.nimcall.}

func genericInnerType(typeName, prefix: string): string =
  ## Inner type of a single-parameter generic written `Prefix[Inner]`, e.g.
  ## `genericInnerType("seq[int]", "seq[")` → `"int"`. Empty string when
  ## `typeName` is not of that shape.
  if typeName.startsWith(prefix) and typeName.endsWith("]"):
    return typeName[prefix.len .. ^2]
  ""

func scalarKind(t: string): tuple[ok: bool, kind: ScalarKind] =
  ## Single source of truth for the scalar leaf set every backend shares.
  case t
  of "bool":
    (true, skBool)
  of "int8":
    (true, skI8)
  of "int16":
    (true, skI16)
  of "int32":
    (true, skI32)
  of "int", "int64":
    (true, skI64)
  of "uint8", "byte":
    (true, skU8)
  of "uint16":
    (true, skU16)
  of "uint32":
    (true, skU32)
  of "uint", "uint64":
    (true, skU64)
  of "float32":
    (true, skF32)
  of "float", "float64":
    (true, skF64)
  else:
    (false, skBool)

func parseFFIType*(
    typeName: string, handleNames: HashSet[string] = initHashSet[string]()
): FFIType =
  ## Single source of truth for turning a Nim type spelled as text into the
  ## shared IR. `ptr T`/`pointer` ⇒ ftPtr; `seq[byte]`/`seq[uint8]` ⇒ ftBytes;
  ## `seq[T]` ⇒ ftSeq; `Option[T]`/`Maybe[T]` ⇒ ftOpt; the scalar set ⇒
  ## ftScalar; `string`/`cstring` ⇒ ftStr; a name in `handleNames` ⇒ ftHandle;
  ## anything else ⇒ ftStruct.
  let t = typeName.strip()
  if t.startsWith("ptr ") or t == "pointer":
    return FFIType(kind: ftPtr)

  let seqInner = genericInnerType(t, "seq[")
  if seqInner.len > 0:
    let inner = seqInner.strip()
    if inner == "byte" or inner == "uint8":
      return FFIType(kind: ftBytes)
    return FFIType(kind: ftSeq, elem: parseFFIType(inner, handleNames))

  var optInner = genericInnerType(t, "Option[")
  if optInner.len == 0:
    optInner = genericInnerType(t, "Maybe[")
  if optInner.len > 0:
    return FFIType(kind: ftOpt, elem: parseFFIType(optInner.strip(), handleNames))

  let sc = scalarKind(t)
  if sc.ok:
    return FFIType(kind: ftScalar, scalar: sc.kind)
  if t == "string" or t == "cstring":
    return FFIType(kind: ftStr)
  if t in handleNames:
    return FFIType(kind: ftHandle, name: t)
  FFIType(kind: ftStruct, name: t)

proc renderNative*(m: NativeTypeMap, t: FFIType): string =
  ## Recursively walks `t` into a native type string for the backend `m`.
  case t.kind
  of ftScalar:
    m.scalar(t.scalar)
  of ftStr:
    m.str
  of ftBytes:
    m.bytes
  of ftPtr, ftHandle:
    m.ptrType
  of ftSeq:
    m.seqOf(renderNative(m, t.elem))
  of ftOpt:
    m.optOf(renderNative(m, t.elem))
  of ftStruct:
    m.structName(t.name)
