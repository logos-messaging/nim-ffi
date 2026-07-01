## Helpers shared by the language-specific binding generators (cpp.nim, c.nim).
## Kept here so the per-proc envelope naming, lib-prefix stripping and
## proc-classification logic live in one place rather than being copy-pasted
## into each backend.

import std/strutils
import ./meta, ./string_helpers

proc genericInnerType*(typeName, prefix: string): string =
  ## Inner type of a single-parameter generic written `Prefix[Inner]`, e.g.
  ## `genericInnerType("seq[int]", "seq[")` → `"int"`. Empty string when
  ## `typeName` is not of that shape.
  if typeName.startsWith(prefix) and typeName.endsWith("]"):
    let start = prefix.len
    let lastIndex = typeName.len - 2
    return typeName[start .. lastIndex]
  return ""

proc stripLibPrefix*(procName, libName: string): string =
  ## Drops the `<lib>_` prefix from an exported C symbol, e.g.
  ## `stripLibPrefix("timer_echo", "timer")` → `"echo"`.
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc reqStructName*(p: FFIProcMeta): string =
  ## Mirrors the Nim macro: `<PascalCase(procName)>Req`, or `...CtorReq` for a
  ## constructor. The per-proc envelope every backend encodes onto the wire.
  let camel = snakeToPascalCase(p.procName)
  if p.kind == FFIKind.CTOR:
    camel & "CtorReq"
  else:
    camel & "Req"

type ClassifiedProcs* = object
  ctors*: seq[FFIProcMeta]
  methods*: seq[FFIProcMeta]
  dtorProcName*: string

proc classifyProcs*(procs: seq[FFIProcMeta]): ClassifiedProcs =
  ## Splits the registry into constructors, instance methods and (the first)
  ## destructor symbol — the split every backend needs before emitting a
  ## high-level context wrapper.
  var c: ClassifiedProcs
  for p in procs:
    case p.kind
    of FFIKind.CTOR:
      c.ctors.add(p)
    of FFIKind.FFI:
      c.methods.add(p)
    of FFIKind.DTOR:
      if c.dtorProcName.len == 0:
        c.dtorProcName = p.procName
  c

proc libTypeName*(ctors: seq[FFIProcMeta], libName: string): string =
  ## The user's library type name (e.g. `MyTimer`), taken from the first ctor
  ## or derived from `libName` when the library declares none.
  if ctors.len > 0:
    return ctors[0].libTypeName
  capitalizeFirstLetter(libName)
