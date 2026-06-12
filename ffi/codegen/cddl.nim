## CDDL (RFC 8610) schema generator for the nim-ffi framework.
## Mirrors the CBOR wire format produced by ffi/cbor_serial.nim: every
## user-declared {.ffi.} type becomes a CDDL rule, every {.ffi.} / {.ffiCtor.}
## proc gets a request envelope rule plus a response shape rule.

import std/[os, strutils, unicode]
import ./meta

proc innerOf(typeName, prefix: string): string =
  if typeName.startsWith(prefix) and typeName.endsWith("]"):
    return typeName[prefix.len .. ^2]
  return ""

proc capitalizeFirstLetter(s: string): string =
  if s.len == 0:
    return s
  return s.capitalize()

proc toCamelCase(s: string): string =
  ## "testlib_create" → "TestlibCreate"
  var parts = s.split('_')
  var res = ""
  for p in parts:
    res.add capitalizeFirstLetter(p)
  return res

proc nimTypeToCddl*(typeName: string): string =
  ## Maps a Nim type name (as recorded in the compile-time registries) to its
  ## CDDL equivalent. Unknown PascalCase names are passed through as references
  ## to other CDDL rules in the same document.
  let t = typeName.strip()
  let seqI = innerOf(t, "seq[")
  if seqI.len > 0:
    return "[* " & nimTypeToCddl(seqI) & "]"
  let arrI = innerOf(t, "array[")
  if arrI.len > 0:
    # CDDL has no fixed-length array literal as ergonomic as Nim's array; emit
    # an unbounded array whose element type is the user-declared element type.
    let commaIdx = arrI.find(',')
    let elemT =
      if commaIdx >= 0:
        arrI[commaIdx + 1 .. ^1].strip()
      else:
        arrI
    return "[* " & nimTypeToCddl(elemT) & "]"
  let optI = innerOf(t, "Option[")
  if optI.len > 0:
    return nimTypeToCddl(optI) & " / nil"
  let mayI = innerOf(t, "Maybe[")
  if mayI.len > 0:
    return nimTypeToCddl(mayI) & " / nil"
  case t
  of "bool": "bool"
  of "int", "int64", "int32", "int16", "int8": "int"
  of "uint", "uint64", "uint32", "uint16", "uint8": "uint"
  of "string", "cstring": "tstr"
  of "float", "float64": "float64"
  of "float32": "float32"
  of "pointer": "uint"
  else: t
    # reference to another rule in this CDDL document

proc reqStructName(p: FFIProcMeta): string =
  ## Mirrors the Nim macro: <CamelCase(procName)>{Ctor}Req.
  let camel = toCamelCase(p.procName)
  if p.kind == FFIKind.CTOR:
    camel & "CtorReq"
  else:
    camel & "Req"

proc emitMap(
    fields: openArray[tuple[name: string, typeName: string, isPtr: bool]]
): string =
  if fields.len == 0:
    return "{ }"
  var parts: seq[string] = @[]
  for f in fields:
    let cddlType =
      if f.isPtr:
        "uint"
      else:
        nimTypeToCddl(f.typeName)
    parts.add(f.name & ": " & cddlType)
  "{ " & parts.join(", ") & " }"

proc emitObjectFields(t: FFITypeMeta): string =
  var fields: seq[tuple[name: string, typeName: string, isPtr: bool]] = @[]
  for f in t.fields:
    fields.add((name: f.name, typeName: f.typeName, isPtr: false))
  emitMap(fields)

proc emitReqFields(p: FFIProcMeta): string =
  var fields: seq[tuple[name: string, typeName: string, isPtr: bool]] = @[]
  for ep in p.extraParams:
    fields.add((name: ep.name, typeName: ep.typeName, isPtr: ep.ridesAsPtr()))
  emitMap(fields)

proc responseRule(p: FFIProcMeta): string =
  ## CDDL shape of the success payload returned by the FFI callback.
  ## Error payloads stay as raw UTF-8 and are intentionally absent from the schema.
  case p.kind
  of FFIKind.CTOR:
    # The ctor returns the FFI context address as a CBOR-encoded decimal string.
    "tstr"
  of FFIKind.DTOR:
    # The dtor has no meaningful payload — handleRes sends a CBOR null sentinel.
    "nil"
  of FFIKind.FFI:
    if p.returnRidesAsPtr():
      "uint"
    else:
      nimTypeToCddl(p.returnTypeName)

proc generateCddlSchema*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    nimSrcRelPath: string,
): string =
  var L: seq[string] = @[]
  L.add("; CDDL schema for `" & libName & "` — auto-generated from " & nimSrcRelPath)
  L.add("; Wire format: CBOR (RFC 8949). Errors return raw UTF-8 (not CBOR) and")
  L.add("; are intentionally absent from this schema.")
  L.add("")

  if types.len > 0:
    L.add(
      "; ─── User-declared FFI types ──────────────────────────────────────"
    )
    for t in types:
      L.add(t.name & " = " & emitObjectFields(t))
    L.add("")

  # Per-proc request envelopes (one CBOR blob per request).
  let nonDtor = block:
    var r: seq[FFIProcMeta] = @[]
    for p in procs:
      if p.kind != FFIKind.DTOR:
        r.add(p)
    r
  if nonDtor.len > 0:
    L.add(
      "; ─── Request envelopes (one CBOR blob per request) ────────────────"
    )
    for p in nonDtor:
      L.add(reqStructName(p) & " = " & emitReqFields(p))
    L.add("")

  # Per-proc request/response rules.
  L.add(
    "; ─── Procs ─────────────────────────────────────────────────────────"
  )
  for p in procs:
    let kindTag =
      case p.kind
      of FFIKind.CTOR: "ctor"
      of FFIKind.DTOR: "dtor"
      of FFIKind.FFI: "ffi"
    L.add("; " & p.procName & " (" & kindTag & ")")
    if p.kind != FFIKind.DTOR:
      L.add(p.procName & "-request = " & reqStructName(p))
    L.add(p.procName & "-response = " & responseRule(p))
    L.add("")

  return L.join("\n")

proc generateCddlBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
) =
  createDir(outputDir)
  writeFile(
    outputDir / (libName & ".cddl"),
    generateCddlSchema(procs, types, libName, nimSrcRelPath),
  )
