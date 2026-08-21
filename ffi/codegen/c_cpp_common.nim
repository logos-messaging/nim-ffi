## Helpers shared by the C/C++ binding generators (cpp.nim, c.nim).

import std/strutils
import ../ffi_ret
import ./meta, ./string_helpers

func retCodeDefines*(): string =
  ## The `#define NIMFFI_RET_*` block both header preludes stamp, from the one
  ## Nim definition in `ffi/ffi_ret.nim`.
  var lines: seq[string] = @[]
  for code in ffiRetCodes:
    lines.add("#define NIMFFI_RET_" & code.name & " " & $code.value)
  return lines.join("\n")

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

proc libTypeName*(ctors: seq[FFIProcMeta], libName: string): string =
  ## The library type name, from the first ctor or derived from `libName`.
  if ctors.len > 0:
    return ctors[0].libTypeName
  capitalizeFirstLetter(libName)
