## Pure-C binding generator for the nim-ffi framework.
## Emits a single `<lib>.h` header (and CMakeLists.txt) that exposes the
## library's exportc symbols as flat C structs + function pointers — no
## CBOR, no serialization, no third-party deps. Intended for in-process
## linking where the consumer wants a plain C ABI.
##
## Counterpart to ffi/codegen/cpp.nim, which serves the inter-process case
## via CBOR-on-the-wire. The two paths are independent.

import std/[os, strutils]
import ./meta, ./string_helpers

## Static template blocks live as real C / CMake files under templates/c/
## and are slurped into the binary at compile time.
const
  HeaderPreludeTpl = staticRead("templates/c/header_prelude.h.tpl")
  CMakeListsTpl    = staticRead("templates/c/CMakeLists.txt.tpl")

proc genericInnerType(typeName, prefix: string): string =
  ## If `typeName` looks like `Prefix[Inner]`, return `Inner`. Otherwise "".
  if typeName.startsWith(prefix) and typeName.endsWith("]"):
    let start = prefix.len
    let lastIndex = typeName.len - 2
    return typeName[start .. lastIndex]
  return ""

proc nimTypeToC*(typeName: string): string =
  ## Map a Nim type name (as captured by FFIFieldMeta.typeName) to its C form.
  ## Mirrors the cpp.nim mapper but emits plain C.
  let trimmed = typeName.strip()
  if trimmed.startsWith("ptr "):
    return "void*"
  let seqInner = genericInnerType(trimmed, "seq[")
  if seqInner.len > 0:
    # seq[T] is rendered as a two-field group at the use site; surface a
    # sentinel here so callers detect this and emit the (items, count) pair.
    return "__SEQ__" & nimTypeToC(seqInner)
  let optionInner = genericInnerType(trimmed, "Option[")
  if optionInner.len > 0:
    let inner = nimTypeToC(optionInner)
    # Avoid `const const char**` when inner already encodes a const-pointer.
    if inner.startsWith("const "):
      return inner & "*"
    return "const " & inner & "*"
  let maybeInner = genericInnerType(trimmed, "Maybe[")
  if maybeInner.len > 0:
    let inner = nimTypeToC(maybeInner)
    if inner.startsWith("const "):
      return inner & "*"
    return "const " & inner & "*"
  case trimmed
  of "string", "cstring": "const char*"
  of "int", "int64": "int64_t"
  of "int32": "int32_t"
  of "int16": "int16_t"
  of "int8":  "int8_t"
  of "uint", "uint64": "uint64_t"
  of "uint32": "uint32_t"
  of "uint16": "uint16_t"
  of "uint8":  "uint8_t"
  of "bool":   "bool"
  of "float", "float32": "float"
  of "float64": "double"
  of "pointer": "void*"
  else: trimmed

proc isPrimitiveC*(typeName: string): bool =
  ## True if `typeName` (Nim form) maps to a POD C type — used by the
  ## generator to decide whether `Option[T]` becomes a nullable ptr to a
  ## primitive or to a struct (semantics are the same in C but readability
  ## differs).
  let t = typeName.strip()
  case t
  of "int", "int64", "int32", "int16", "int8",
     "uint", "uint64", "uint32", "uint16", "uint8",
     "bool", "float", "float32", "float64", "pointer":
    true
  else:
    false

proc stripLibPrefixC(procName, libName: string): string =
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc reqStructName*(p: FFIProcMeta): string =
  ## Per-proc Req struct name — same convention as cpp.nim so callers
  ## consuming both generators see consistent names.
  let camel = snakeToPascalCase(p.procName)
  if p.kind == FFIKind.CTOR: camel & "CtorReq" else: camel & "Req"

proc respStructName*(p: FFIProcMeta): string =
  ## Per-proc Resp struct name. The C target wraps every non-ctor return in
  ## a `<Proc>Resp` struct with a single `value` field, so the callback
  ## always delivers `(const <Proc>Resp*, sizeof(<Proc>Resp))`.
  let camel = snakeToPascalCase(p.procName)
  return camel & "Resp"

proc emitFieldDecl(typeName, fieldName: string, indent: string): seq[string] =
  ## Emit one or two C field declarations for a single Nim field. `seq[T]`
  ## expands to `(T* <name>; size_t <name>_len;)`; everything else is a
  ## single line.
  let cType = nimTypeToC(typeName)
  if cType.startsWith("__SEQ__"):
    let inner = cType[7 .. ^1]
    # Avoid double-const for seq[string] (inner already has `const`).
    let qualified =
      if inner.startsWith("const "): inner
      else: "const " & inner
    return @[
      indent & qualified & "* " & fieldName & ";",
      indent & "size_t " & fieldName & "_len;",
    ]
  return @[indent & cType & " " & fieldName & ";"]

proc generateCHeader*(
    procs: seq[FFIProcMeta], types: seq[FFITypeMeta], libName: string
): string =
  ## Build the full `<lib>.h` text from the compile-time FFI registries.
  ## Layout: prelude (incs + FfiCallback typedef) → user-declared FFI type
  ## structs → per-proc Req/Resp structs → extern function declarations →
  ## closing `extern "C"` brace.
  var lines: seq[string] = @[]

  lines.add(HeaderPreludeTpl)

  # ── User-declared FFI types ───────────────────────────────────────────────
  if types.len > 0:
    lines.add("/* ============================================================")
    lines.add(" * User-declared FFI types")
    lines.add(" * ============================================================ */")
    lines.add("")
    for t in types:
      lines.add("typedef struct " & t.name & " {")
      if t.fields.len == 0:
        # C forbids empty struct bodies (it's a GNU extension). Keep parity
        # with the per-proc Req placeholder so layout never surprises callers.
        lines.add("    uint8_t _placeholder;")
      else:
        for f in t.fields:
          for line in emitFieldDecl(f.typeName, f.name, "    "):
            lines.add(line)
      lines.add("} " & t.name & ";")
      lines.add("")

  # ── Per-proc Req / Resp structs ──────────────────────────────────────────
  lines.add("/* ============================================================")
  lines.add(" * Per-proc request envelopes")
  lines.add(" * ============================================================ */")
  lines.add("")
  for p in procs:
    if p.kind == FFIKind.DTOR:
      continue
    let reqName = reqStructName(p)
    lines.add("typedef struct " & reqName & " {")
    if p.extraParams.len == 0:
      lines.add("    uint8_t _placeholder;")
    else:
      for ep in p.extraParams:
        let typeForC =
          if ep.isPtr: "void*"
          else: ep.typeName
        for line in emitFieldDecl(typeForC, ep.name, "    "):
          lines.add(line)
    lines.add("} " & reqName & ";")
    lines.add("")

  # ── Per-proc Resp structs (FFI procs only; ctors return void*, dtors void) ─
  lines.add("/* ============================================================")
  lines.add(" * Per-proc response envelopes")
  lines.add(" * (delivered through the FfiCallback's `msg` pointer)")
  lines.add(" * ============================================================ */")
  lines.add("")
  for p in procs:
    if p.kind != FFIKind.FFI:
      continue
    if p.returnTypeName.len == 0 or p.returnTypeName == "void":
      continue
    let respName = respStructName(p)
    let typeForC =
      if p.returnIsPtr: "void*"
      else: p.returnTypeName
    lines.add("typedef struct " & respName & " {")
    for line in emitFieldDecl(typeForC, "value", "    "):
      lines.add(line)
    lines.add("} " & respName & ";")
    lines.add("")

  # ── Function declarations ─────────────────────────────────────────────────
  lines.add("/* ============================================================")
  lines.add(" * Function declarations")
  lines.add(" * ============================================================ */")
  lines.add("")
  for p in procs:
    let reqName = reqStructName(p)
    case p.kind
    of FFIKind.CTOR:
      lines.add(
        "void* " & p.procName & "(const " & reqName & "* req, " &
          "FfiCallback cb, void* user_data);"
      )
    of FFIKind.FFI:
      lines.add(
        "int " & p.procName & "(void* ctx, const " & reqName & "* req, " &
          "FfiCallback cb, void* user_data);"
      )
    of FFIKind.DTOR:
      lines.add("int " & p.procName & "(void* ctx);")
  lines.add("")

  lines.add("#ifdef __cplusplus")
  lines.add("} /* extern \"C\" */")
  lines.add("#endif")
  lines.add("")

  return lines.join("\n")

proc generateCCMakeLists*(libName: string, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  return CMakeListsTpl.multiReplace(("{{LIB}}", libName), ("{{SRC}}", src))

proc generateCBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
) =
  createDir(outputDir)
  writeFile(outputDir / (libName & ".h"), generateCHeader(procs, types, libName))
  writeFile(outputDir / "CMakeLists.txt", generateCCMakeLists(libName, nimSrcRelPath))
