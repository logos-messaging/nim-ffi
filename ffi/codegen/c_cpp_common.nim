## Helpers shared by the C/C++ binding generators (cpp.nim, c.nim).

import std/[strutils, options]
import ./meta, ./string_helpers

proc stripLibPrefix*(procName, libName: string): string =
  ## Drops the `<lib>_` prefix from an exported C symbol.
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc reqStructName*(p: FFIProcMeta): string =
  ## Per-proc wire envelope name: `<PascalCase(procName)>Req` (`...CtorReq` for ctors).
  let camel = snakeToPascalCase(p.procName)
  if p.kind == FFIKind.CTOR:
    camel & "CtorReq"
  else:
    camel & "Req"

type ClassifiedProcs* = object
  ctors*: seq[FFIProcMeta]
  methods*: seq[FFIProcMeta]
  dtor*: Option[FFIProcMeta]

proc classifyProcs*(procs: seq[FFIProcMeta]): ClassifiedProcs =
  ## Splits the registry into constructors, methods and the first destructor.
  var c: ClassifiedProcs
  for p in procs:
    case p.kind
    of FFIKind.CTOR:
      c.ctors.add(p)
    of FFIKind.FFI:
      c.methods.add(p)
    of FFIKind.DTOR:
      if c.dtor.isNone():
        c.dtor = some(p)
  c

proc libTypeName*(ctors: seq[FFIProcMeta], libName: string): string =
  ## The library type name, from the first ctor or derived from `libName`.
  if ctors.len > 0:
    return ctors[0].libTypeName
  capitalizeFirstLetter(libName)
