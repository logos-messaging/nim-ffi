## CBOR-free C99 binding generator for the nim-ffi framework (`-d:targetLang=c_abi`).
## Where the `c` backend speaks CBOR on the wire (vendoring TinyCBOR), this one
## emits a single self-contained header whose flat structs *are* the C ABI:
## they mirror the macro-generated `*_CWire` layout byte-for-byte, so the C
## consumer passes native structs and links no CBOR at all. The Nim dylib
## converts flat struct ⇄ Nim object at the boundary (see the `abi = c` dispatch
## in `ffi/internal/c_macro_helpers.nim`) and keeps CBOR purely as an internal
## transport detail.
##
## Layout contract (must stay in lock-step with `c_macro_helpers.wireValueType`
## / `wireFieldsFor`): `string`→`const char*`, `seq[T]`→`<wireT>* <f>_items` +
## `ptrdiff_t <f>_len`, `Option[T]`→`<wireT>*` (NULL = none), nested `{.ffi.}`
## type → its flat struct, `ptr`/`pointer`→`void*`, POD unchanged.

import std/[os, strutils, tables, sets]
import ./meta, ./string_helpers, ./c_cpp_common, ./types_ir

const CPtrType = "void*"
  ## Wire C type for any Nim `ptr T` / `pointer` (mirrors the `_CWire` `pointer`).

const CMakeListsTpl = staticRead("templates/c_abi/CMakeLists.txt.tpl")

func leafCTypeAbi(t: string): tuple[ok: bool, cType: string] =
  ## Maps a Nim leaf type to the flat C type used in a wire struct. `ok` is
  ## false for composites (seq/Option/user structs), handled separately.
  case t
  of "int", "int64":
    (true, "int64_t")
  of "int32":
    (true, "int32_t")
  of "int16":
    (true, "int16_t")
  of "int8":
    (true, "int8_t")
  of "uint", "uint64":
    (true, "uint64_t")
  of "uint32":
    (true, "uint32_t")
  of "uint16":
    (true, "uint16_t")
  of "uint8", "byte":
    (true, "uint8_t")
  of "bool":
    (true, "bool")
  of "float", "float64":
    (true, "double")
  of "float32":
    (true, "float")
  of "pointer":
    (true, CPtrType)
  of "string", "cstring":
    (true, "const char*")
  else:
    (false, "")

type AbiReg = object
  typeTable: Table[string, FFITypeMeta] ## user structs + synthetic Req structs
  emitted: HashSet[string] ## struct names already emitted
  decls: seq[string] ## struct typedefs, dependency order

proc ensureAbiStruct(reg: var AbiReg, typeName: string)

proc wireValueCType(reg: var AbiReg, nimType: string): string =
  ## Flat C type for a value-position field (everything except a top-level
  ## `seq`, which splits into two fields — see `fieldDecls`).
  let t = nimType.strip()
  if t.startsWith("ptr ") or t == "pointer":
    return CPtrType
  let leaf = leafCTypeAbi(t)
  if leaf.ok:
    return leaf.cType
  var optInner = genericInnerType(t, "Option[")
  if optInner.len == 0:
    optInner = genericInnerType(t, "Maybe[")
  if optInner.len > 0:
    return wireValueCType(reg, optInner.strip()) & "*"
  if genericInnerType(t, "seq[").len > 0:
    raise newException(
      ValueError,
      "abi = c: `seq` has no single-field wire form, so it can't nest inside " &
        "another container: " & t,
    )
  if genericInnerType(t, "array[").len > 0:
    raise newException(
      ValueError, "abi = c: array fields are not yet supported by the C backend: " & t
    )
  if t in reg.typeTable:
    ensureAbiStruct(reg, t)
    return t
  raise newException(ValueError, "abi = c: unknown field type: " & t)

proc fieldDecls(reg: var AbiReg, name, nimType: string): seq[string] =
  ## C struct member line(s) for one Nim field. A `seq[T]` becomes the
  ## `<name>_items` pointer + `<name>_len` count pair; everything else is one
  ## member.
  let seqInner = genericInnerType(nimType.strip(), "seq[")
  if seqInner.len > 0:
    let elemC = wireValueCType(reg, seqInner.strip())
    return @[elemC & "* " & name & "_items;", "ptrdiff_t " & name & "_len;"]
  @[wireValueCType(reg, nimType) & " " & name & ";"]

proc emitAbiStruct(reg: var AbiReg, t: FFITypeMeta) =
  var members: seq[string] = @[]
  for f in t.fields:
    for line in fieldDecls(reg, f.name, f.typeName):
      members.add("    " & line)
  if members.len == 0:
    members.add("    uint8_t _placeholder; /* C forbids empty structs */")
  reg.decls.add("typedef struct {\n" & members.join("\n") & "\n} " & t.name & ";")

proc ensureAbiStruct(reg: var AbiReg, typeName: string) =
  if typeName in reg.emitted:
    return
  reg.emitted.incl(typeName)
  if typeName in reg.typeTable:
    emitAbiStruct(reg, reg.typeTable[typeName])
  else:
    reg.decls.add("/* unknown type referenced: " & typeName & " */")

proc reqTypeMeta(p: FFIProcMeta): FFITypeMeta =
  ## The per-proc Req envelope as an FFITypeMeta, mirroring the Nim macro. A
  ## pointer/handle param rides as the opaque `pointer` wire type.
  var fields: seq[FFIFieldMeta] = @[]
  for ep in p.extraParams:
    let typeName = if ep.ridesAsPtr(): "pointer" else: ep.typeName
    fields.add(FFIFieldMeta(name: ep.name, typeName: typeName))
  FFITypeMeta(name: reqStructName(p), fields: fields)

proc newAbiReg(types: seq[FFITypeMeta], procs: seq[FFIProcMeta]): AbiReg =
  var reg = AbiReg()
  for t in types:
    reg.typeTable[t.name] = t
  for p in procs:
    if p.kind != FFIKind.DTOR:
      let rt = reqTypeMeta(p)
      reg.typeTable[rt.name] = rt
  reg

func paramByValue(nimType: string, ridesAsPtr: bool): bool =
  ## Scalars / opaque pointers / string views pass by value; composite
  ## aggregates (seq, Option, user structs) pass by const pointer.
  if ridesAsPtr:
    return true
  leafCTypeAbi(nimType.strip()).ok

proc reqParamsAndAssigns(
    reg: var AbiReg, extraParams: seq[FFIParamMeta]
): tuple[params, assigns: seq[string]] =
  ## The C parameter list + `ffi_req` field assignments shared by the ctor and
  ## method wrappers: by-value params copy straight into the request struct,
  ## by-const-pointer aggregates are dereferenced in.
  var params, assigns: seq[string] = @[]
  for ep in extraParams:
    let rides = ep.ridesAsPtr()
    let cType =
      if rides:
        CPtrType
      else:
        wireValueCType(reg, ep.typeName)
    if paramByValue(ep.typeName, rides):
      params.add(cType & " " & ep.name)
      assigns.add("    ffi_req." & ep.name & " = " & ep.name & ";")
    else:
      params.add("const " & cType & "* " & ep.name)
      assigns.add("    ffi_req." & ep.name & " = *" & ep.name & ";")
  (params, assigns)

proc methodReplyInfo(
    reg: var AbiReg, libType: string, m: FFIProcMeta
): tuple[fnType, replyParam: string] =
  ## The reply-callback typedef name plus the C type of its `reply` argument.
  ## An object return hands back a `const <Struct>*`; a string return a
  ## `const char*`. Both are the raw callback the dylib invokes directly.
  let pascal = snakeToPascalCase(stripLibPrefix(m.procName, m.libName))
  let fnType = libType & pascal & "ReplyFn"
  if m.returnRidesAsPtr():
    raise newException(
      ValueError,
      "abi = c: handle/pointer returns are not yet supported by the C backend: " &
        m.procName,
    )
  let rt = m.returnTypeName.strip()
  let replyParam =
    if rt == "string" or rt == "cstring":
      "const char*"
    elif leafCTypeAbi(rt).ok:
      "const " & leafCTypeAbi(rt).cType & "*"
    else:
      ensureAbiStruct(reg, rt)
      "const " & rt & "*"
  (fnType, replyParam)

proc emitReplyTypedefs(
    lines: var seq[string], reg: var AbiReg, libType: string, methods: seq[FFIProcMeta]
) =
  for m in methods:
    let info = methodReplyInfo(reg, libType, m)
    lines.add(
      "typedef void (*" & info.fnType & ")(int err_code, " & info.replyParam &
        " reply, const char* err_msg, void* user_data);"
    )

proc emitExternDecls(
    lines: var seq[string],
    reg: var AbiReg,
    libName, libType: string,
    procs: seq[FFIProcMeta],
) =
  let createRawFn = libType & "CreateRawFn"
  var haveCtor = false
  for p in procs:
    if p.kind == FFIKind.CTOR:
      haveCtor = true
  if haveCtor:
    lines.add(
      "typedef void (*" & createRawFn &
        ")(int err_code, const char* ctx_addr, const char* err_msg, void* user_data);"
    )
  lines.add("#ifdef __cplusplus")
  lines.add("extern \"C\" {")
  lines.add("#endif")
  lines.add("")
  for p in procs:
    let reqStruct = reqStructName(p)
    case p.kind
    of FFIKind.FFI:
      let info = methodReplyInfo(reg, libType, p)
      lines.add(
        "int " & p.procName & "(void* ctx, " & info.fnType &
          " on_reply, void* user_data, const " & reqStruct & "* req);"
      )
    of FFIKind.CTOR:
      lines.add(
        "void* " & p.procName & "(const " & reqStruct & "* req, " & createRawFn &
          " on_created, void* user_data);"
      )
    of FFIKind.DTOR:
      lines.add("int " & p.procName & "(void* ctx);")
  lines.add("")
  lines.add("#ifdef __cplusplus")
  lines.add("} /* extern \"C\" */")
  lines.add("#endif")
  lines.add("")

proc emitCtxAndCtor(
    lines: var seq[string],
    reg: var AbiReg,
    libName, libType, ctxType: string,
    ctors: seq[FFIProcMeta],
) =
  lines.add("typedef struct {")
  lines.add("    void* ptr;")
  lines.add("} " & ctxType & ";")
  lines.add("")
  if ctors.len == 0:
    return
  let createFn = libType & "CreateFn"
  let createBox = libType & "CreateBox"
  let createRawFn = libType & "CreateRawFn"
  let tramp = libName & "_create_trampoline"
  lines.add(
    "typedef void (*" & createFn & ")(int err_code, " & ctxType &
      "* ctx, const char* err_msg, void* user_data);"
  )
  lines.add(
    "typedef struct { " & createFn & " fn; void* user_data; } " & createBox & ";"
  )
  lines.add(
    "static void " & tramp &
      "(int ret, const char* ctx_addr, const char* err_msg, void* ud) {"
  )
  lines.add("    " & createBox & "* box = (" & createBox & "*)ud;")
  lines.add("    if (!box) return;")
  lines.add("    if (!box->fn) { free(box); return; }")
  lines.add("    if (ret != 0) {")
  lines.add(
    "        box->fn(ret, NULL, err_msg ? err_msg : \"FFI create failed\", box->user_data);"
  )
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    char* endp = NULL;")
  lines.add("    unsigned long long a = ctx_addr ? strtoull(ctx_addr, &endp, 10) : 0;")
  lines.add("    bool ok = ctx_addr && *ctx_addr && endp && *endp == '\\0';")
  lines.add("    if (!ok) {")
  lines.add(
    "        box->fn(-1, NULL, \"FFI create returned non-numeric address\", box->user_data);"
  )
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add(
    "    " & ctxType & "* ctx = (" & ctxType & "*)calloc(1, sizeof(" & ctxType & "));"
  )
  lines.add("    if (!ctx) {")
  lines.add("        box->fn(-1, NULL, \"out of memory\", box->user_data);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    ctx->ptr = (void*)(uintptr_t)a;")
  lines.add("    box->fn(NIMFFI_RET_OK, ctx, NULL, box->user_data);")
  lines.add("    free(box);")
  lines.add("}")
  lines.add("")
  for ctor in ctors:
    let reqStruct = reqStructName(ctor)
    let (params, assigns) = reqParamsAndAssigns(reg, ctor.extraParams)
    let head = "static inline int " & libName & "_ctx_create("
    let sig =
      if params.len > 0:
        head & params.join(", ") & ", " & createFn & " on_created, void* user_data) {"
      else:
        head & createFn & " on_created, void* user_data) {"
    lines.add(sig)
    lines.add("    " & reqStruct & " ffi_req;")
    lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
    for a in assigns:
      lines.add(a)
    lines.add(
      "    " & createBox & "* box = (" & createBox & "*)malloc(sizeof(" & createBox &
        "));"
    )
    lines.add("    if (!box) {")
    lines.add(
      "        if (on_created) on_created(-1, NULL, \"out of memory\", user_data);"
    )
    lines.add("        return -1;")
    lines.add("    }")
    lines.add("    box->fn = on_created;")
    lines.add("    box->user_data = user_data;")
    lines.add("    (void)" & ctor.procName & "(&ffi_req, " & tramp & ", box);")
    lines.add("    return 0;")
    lines.add("}")
    lines.add("")

proc emitDestructor(lines: var seq[string], ctxType, libName, dtorProcName: string) =
  lines.add("static inline void " & libName & "_ctx_destroy(" & ctxType & "* ctx) {")
  lines.add("    if (!ctx) return;")
  if dtorProcName.len > 0:
    lines.add("    if (ctx->ptr) { " & dtorProcName & "(ctx->ptr); ctx->ptr = NULL; }")
  lines.add("    free(ctx);")
  lines.add("}")
  lines.add("")

proc emitMethod(
    lines: var seq[string],
    reg: var AbiReg,
    ctxType, libName, libType: string,
    m: FFIProcMeta,
) =
  let stripped = stripLibPrefix(m.procName, m.libName)
  let reqStruct = reqStructName(m)
  let info = methodReplyInfo(reg, libType, m)
  let (params, assigns) = reqParamsAndAssigns(reg, m.extraParams)
  let head =
    "static inline int " & libName & "_ctx_" & stripped & "(const " & ctxType & "* ctx, "
  let sig =
    if params.len > 0:
      head & params.join(", ") & ", " & info.fnType & " on_reply, void* user_data) {"
    else:
      head & info.fnType & " on_reply, void* user_data) {"
  lines.add(sig)
  lines.add("    " & reqStruct & " ffi_req;")
  lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
  for a in assigns:
    lines.add(a)
  lines.add("    return " & m.procName & "(ctx->ptr, on_reply, user_data, &ffi_req);")
  lines.add("}")
  lines.add("")

proc generateCAbiLibHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
): string =
  if events.len > 0:
    raise newException(
      ValueError, "abi = c: the C backend does not yet support {.ffiEvent.} listeners"
    )
  let classified = classifyProcs(procs)
  let libType = libTypeName(classified.ctors, libName)
  let ctxType = libType & "Ctx"

  var reg = newAbiReg(types, procs)
  for t in types:
    ensureAbiStruct(reg, t.name)
  for p in procs:
    if p.kind != FFIKind.DTOR:
      ensureAbiStruct(reg, reqStructName(p))

  let guard = "NIM_FFI_LIB_" & libName.toUpperAscii() & "_C_ABI_H_INCLUDED"
  var lines: seq[string] = @[]
  lines.add("#ifndef " & guard)
  lines.add("#define " & guard)
  lines.add("#include <stdint.h>")
  lines.add("#include <stddef.h>")
  lines.add("#include <stdbool.h>")
  lines.add("#include <stdlib.h>")
  lines.add("#include <string.h>")
  lines.add("")
  lines.add("#define NIMFFI_RET_OK 0")
  lines.add("#define NIMFFI_RET_ERR 1")
  lines.add("#define NIMFFI_RET_MISSING_CALLBACK 2")
  lines.add("")
  lines.add("/* Flat wire structs — the C ABI. Strings are borrowed, NUL-terminated")
  lines.add("   `const char*` valid only for the duration of the call they cross. */")
  for decl in reg.decls:
    lines.add(decl)
  lines.add("")

  emitReplyTypedefs(lines, reg, libType, classified.methods)
  lines.add("")
  emitExternDecls(lines, reg, libName, libType, procs)

  lines.add("/* High-level context wrapper */")
  emitCtxAndCtor(lines, reg, libName, libType, ctxType, classified.ctors)
  emitDestructor(lines, ctxType, libName, classified.dtorProcName)
  for m in classified.methods:
    emitMethod(lines, reg, ctxType, libName, libType, m)

  lines.add("#endif /* " & guard & " */")
  lines.join("\n") & "\n"

proc generateCAbiCMakeLists*(libName, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  CMakeListsTpl.multiReplace(("{{LIB}}", libName), ("{{SRC}}", src))

proc generateCAbiBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
) =
  createDir(outputDir)
  writeFile(
    outputDir / (libName & ".h"), generateCAbiLibHeader(procs, types, libName, events)
  )
  writeFile(
    outputDir / "CMakeLists.txt", generateCAbiCMakeLists(libName, nimSrcRelPath)
  )
