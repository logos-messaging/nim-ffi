## C99 binding generator for the nim-ffi framework.
## Emits a header-only C binding plus a CMakeLists.txt. The binding is split
## into three headers so the example reads cleanly: `nim_ffi_prelude.h` (owned
## string/byte types + libc includes), `nim_ffi_cbor.h` (leaf CBOR codecs and
## buffer drivers, includes the prelude), and `<lib>.h` (the library-specific
## structs, codecs and async API, includes the cbor header). Requests/responses
## travel as CBOR (encoded with the same vendored TinyCBOR the C++ backend
## uses, matching the Nim-side cbor_serial codec — both ends speak RFC 8949).
##
## C has neither generics nor overloading, so the codecs the C++ backend gets
## from templates are monomorphised here: every distinct `seq[T]` / `Option[T]`
## becomes its own struct + encode/decode/free triple, and each leaf type has a
## distinctly-named codec emitted by the cbor_helpers template.

import std/[os, strutils, tables, sets]
import ./meta, ./string_helpers, ./c_cpp_common, ./types_ir

## Wire-format C type for any Nim `ptr T` / `pointer`. Fixed 64-bit so the CBOR
## payload size is stable regardless of host architecture (mirrors CppPtrType).
const CPtrType* = "uint64_t"

const
  HeaderPreludeTpl = staticRead("templates/c/header_prelude.h.tpl")
  CborHelpersTpl = staticRead("templates/c/cbor_helpers.h.tpl")
  CMakeListsTpl = staticRead("templates/c/CMakeLists.txt.tpl")

  # Shared headers written alongside the library header. Their names match the
  # include guards baked into the templates and the `#include` the cbor header
  # emits for the prelude.
  PreludeHeaderName* = "nim_ffi_prelude.h"
  CborHeaderName* = "nim_ffi_cbor.h"

const scalarCInfoTable: array[ScalarKind, tuple[cType, suffix: string]] = [
  skBool: ("bool", "bool"),
  skI8: ("int8_t", "i8"),
  skI16: ("int16_t", "i16"),
  skI32: ("int32_t", "i32"),
  skI64: ("int64_t", "i64"),
  skU8: ("uint8_t", "u8"),
  skU16: ("uint16_t", "u16"),
  skU32: ("uint32_t", "u32"),
  skU64: ("uint64_t", "u64"),
  skF32: ("float", "f32"),
  skF64: ("double", "f64"),
]

func leafSuffix(cType: string): string =
  ## C type name → leaf codec suffix for the leaf codecs the template provides;
  ## empty string for composite types. Driven off the shared scalar table so it
  ## can't drift from the IR's scalar set.
  for s in ScalarKind:
    if scalarCInfoTable[s].cType == cType:
      return scalarCInfoTable[s].suffix
  case cType
  of "NimFfiStr": "str"
  of "NimFfiBytes": "bytes"
  else: ""

func cToken(cType: string): string =
  ## Short PascalCase token used to build monomorphised container names and
  ## codec-adapter symbols. Leaf types reuse their codec suffix (e.g.
  ## `int64_t`→`I64`); composite C type names are already unique C identifiers,
  ## so they pass through verbatim.
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    capitalizeFirstLetter(suffix)
  else:
    cType

type CTypeReg = object
  libName: string ## snake_case symbol prefix, e.g. "my_timer"
  libType: string ## PascalCase container-name prefix, e.g. "MyTimer"
  typeTable: Table[string, FFITypeMeta] ## user structs + synthetic Req structs
  emitted: HashSet[string] ## composite C type names already emitted
  owns: Table[string, bool] ## C type name → owns-heap-memory
  decls: seq[string] ## struct typedefs, dependency order
  codecs: seq[string] ## enc/dec/free defs, dependency order

func encFn(reg: CTypeReg, cType: string): string =
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return "nimffi_enc_" & suffix
  reg.libName & "_enc_" & cType

func decFn(reg: CTypeReg, cType: string): string =
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return "nimffi_dec_" & suffix
  reg.libName & "_dec_" & cType

func freeFn(reg: CTypeReg, cType: string): string =
  ## Free-function name for `cType`, or "" when the type owns no heap memory.
  case cType
  of "NimFfiStr":
    "nimffi_free_str"
  of "NimFfiBytes":
    "nimffi_free_bytes"
  else:
    if leafSuffix(cType).len > 0:
      ""
    elif reg.owns.getOrDefault(cType, false):
      reg.libName & "_free_" & cType
    else:
      ""

proc emitSeqType(reg: var CTypeReg, name, elemC: string) =
  let eEnc = encFn(reg, elemC)
  let eDec = decFn(reg, elemC)
  let eFree = freeFn(reg, elemC)
  reg.decls.add(
    "typedef struct {\n    " & elemC & "* data;\n    size_t len;\n} " & name & ";"
  )
  var body: seq[string] = @[]
  body.add("static inline CborError " & reg.libName & "_enc_" & name & "(")
  body.add("        CborEncoder* e, const " & name & "* v) {")
  body.add("    CborEncoder arr;")
  body.add("    CborError err = cbor_encoder_create_array(e, &arr, v->len);")
  body.add("    if (err) return err;")
  body.add("    for (size_t i = 0; i < v->len; i++) {")
  body.add("        err = " & eEnc & "(&arr, &v->data[i]);")
  body.add("        if (err) return err;")
  body.add("    }")
  body.add("    return cbor_encoder_close_container(e, &arr);")
  body.add("}")
  body.add("static inline CborError " & reg.libName & "_dec_" & name & "(")
  body.add("        CborValue* it, " & name & "* out) {")
  body.add("    if (!cbor_value_is_array(it)) return CborErrorImproperValue;")
  body.add("    size_t len = 0;")
  body.add("    CborError err = cbor_value_get_array_length(it, &len);")
  body.add("    if (err) return err;")
  body.add(
    "    out->data = (" & elemC & "*)calloc(len ? len : 1, sizeof(" & elemC & "));"
  )
  body.add("    if (!out->data) return CborErrorOutOfMemory;")
  body.add("    out->len = len;")
  body.add("    CborValue inner;")
  body.add("    err = cbor_value_enter_container(it, &inner);")
  body.add("    if (err) return err;")
  body.add("    for (size_t i = 0; i < len; i++) {")
  body.add("        err = " & eDec & "(&inner, &out->data[i]);")
  body.add("        if (err) return err;")
  body.add("    }")
  body.add("    return cbor_value_leave_container(it, &inner);")
  body.add("}")
  body.add(
    "static inline void " & reg.libName & "_free_" & name & "(" & name & "* v) {"
  )
  body.add("    if (!v || !v->data) return;")
  if eFree.len > 0:
    body.add("    for (size_t i = 0; i < v->len; i++) " & eFree & "(&v->data[i]);")
  body.add("    free(v->data);")
  body.add("    v->data = NULL;")
  body.add("    v->len = 0;")
  body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[name] = true

proc emitOptType(reg: var CTypeReg, name, elemC: string, elemOwns: bool) =
  let eEnc = encFn(reg, elemC)
  let eDec = decFn(reg, elemC)
  let eFree = freeFn(reg, elemC)
  reg.decls.add(
    "typedef struct {\n    bool has_value;\n    " & elemC & " value;\n} " & name & ";"
  )
  var body: seq[string] = @[]
  body.add("static inline CborError " & reg.libName & "_enc_" & name & "(")
  body.add("        CborEncoder* e, const " & name & "* v) {")
  body.add("    if (!v->has_value) return cbor_encode_null(e);")
  body.add("    return " & eEnc & "(e, &v->value);")
  body.add("}")
  body.add("static inline CborError " & reg.libName & "_dec_" & name & "(")
  body.add("        CborValue* it, " & name & "* out) {")
  body.add("    if (cbor_value_is_null(it)) {")
  body.add("        out->has_value = false;")
  body.add("        memset(&out->value, 0, sizeof(out->value));")
  body.add("        return cbor_value_advance(it);")
  body.add("    }")
  body.add("    out->has_value = true;")
  body.add("    return " & eDec & "(it, &out->value);")
  body.add("}")
  if elemOwns and eFree.len > 0:
    body.add(
      "static inline void " & reg.libName & "_free_" & name & "(" & name & "* v) {"
    )
    body.add("    if (!v || !v->has_value) return;")
    body.add("    " & eFree & "(&v->value);")
    body.add("    v->has_value = false;")
    body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[name] = elemOwns

proc ensureCType(reg: var CTypeReg, nimType: string): tuple[cType: string, owns: bool]

proc emitStructType(reg: var CTypeReg, t: FFITypeMeta) =
  var fieldDecls: seq[string] = @[]
  var members: seq[tuple[name, cType: string, owns: bool]] = @[]
  for f in t.fields:
    let (cType, owns) = ensureCType(reg, f.typeName)
    fieldDecls.add("    " & cType & " " & f.name & ";")
    members.add((f.name, cType, owns))
  if members.len == 0:
    fieldDecls.add("    char _nimffi_empty; /* C forbids empty structs */")
  reg.decls.add("typedef struct {\n" & fieldDecls.join("\n") & "\n} " & t.name & ";")

  var body: seq[string] = @[]
  body.add("static inline CborError " & reg.libName & "_enc_" & t.name & "(")
  body.add("        CborEncoder* e, const " & t.name & "* v) {")
  if members.len == 0:
    body.add("    (void)v;")
  body.add("    CborEncoder m;")
  body.add("    CborError err = cbor_encoder_create_map(e, &m, " & $members.len & ");")
  body.add("    if (err) return err;")
  for mem in members:
    body.add("    err = cbor_encode_text_stringz(&m, \"" & mem.name & "\");")
    body.add("    if (err) return err;")
    body.add("    err = " & encFn(reg, mem.cType) & "(&m, &v->" & mem.name & ");")
    body.add("    if (err) return err;")
  body.add("    return cbor_encoder_close_container(e, &m);")
  body.add("}")

  body.add("static inline CborError " & reg.libName & "_dec_" & t.name & "(")
  body.add("        CborValue* it, " & t.name & "* out) {")
  body.add("    if (!cbor_value_is_map(it)) return CborErrorImproperValue;")
  if members.len == 0:
    body.add("    (void)out;")
    body.add("    return cbor_value_advance(it);")
  else:
    body.add("    CborValue field;")
    body.add("    CborError err;")
    for mem in members:
      body.add("    err = cbor_value_map_find_value(it, \"" & mem.name & "\", &field);")
      body.add("    if (err) return err;")
      body.add("    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;")
      body.add(
        "    err = " & decFn(reg, mem.cType) & "(&field, &out->" & mem.name & ");"
      )
      body.add("    if (err) return err;")
    body.add("    return cbor_value_advance(it);")
  body.add("}")

  var owns = false
  for mem in members:
    if mem.owns:
      owns = true
  if owns:
    body.add(
      "static inline void " & reg.libName & "_free_" & t.name & "(" & t.name & "* v) {"
    )
    body.add("    if (!v) return;")
    for mem in members:
      let ff = freeFn(reg, mem.cType)
      if mem.owns and ff.len > 0:
        body.add("    " & ff & "(&v->" & mem.name & ");")
    body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[t.name] = owns

proc ensureCType(reg: var CTypeReg, t: FFIType): tuple[cType: string, owns: bool] =
  ## Walks the shared type IR into a C type, monomorphising each distinct
  ## `seq[T]` / `Option[T]` into its own struct + codec triple on first sight.
  ## `owns` marks a C type that carries heap-allocated payload the caller must
  ## release with its generated free function (strings, byte buffers, and any
  ## seq/opt/struct transitively containing one); plain scalars and pointers own
  ## nothing and need no cleanup.
  case t.kind
  of ftPtr:
    return (CPtrType, false)
  of ftScalar:
    return (scalarCInfoTable[t.scalar].cType, false)
  of ftStr:
    return ("NimFfiStr", true)
  of ftBytes:
    return ("NimFfiBytes", true)
  of ftSeq:
    let (elemC, _) = ensureCType(reg, t.elem)
    let name = reg.libType & "Seq_" & cToken(elemC)
    if name notin reg.emitted:
      reg.emitted.incl(name)
      emitSeqType(reg, name, elemC)
    return (name, true)
  of ftOpt:
    let (elemC, elemOwns) = ensureCType(reg, t.elem)
    let name = reg.libType & "Opt_" & cToken(elemC)
    if name notin reg.emitted:
      reg.emitted.incl(name)
      emitOptType(reg, name, elemC, elemOwns)
    return (name, reg.owns.getOrDefault(name, false))
  of ftStruct:
    let name = t.name
    if name notin reg.emitted:
      reg.emitted.incl(name)
      if name in reg.typeTable:
        emitStructType(reg, reg.typeTable[name])
      else:
        reg.decls.add("/* unknown type referenced: " & name & " */")
    return (name, reg.owns.getOrDefault(name, false))

proc ensureCType(reg: var CTypeReg, nimType: string): tuple[cType: string, owns: bool] =
  ensureCType(reg, parseFFIType(nimType))

proc reqTypeMeta(p: FFIProcMeta): FFITypeMeta =
  ## Synthesises the per-proc Req struct as an FFITypeMeta so it flows through
  ## the same monomorphisation path as user-declared types. Pointer/handle
  ## params ride the wire as the opaque uint64 pointer type.
  var fields: seq[FFIFieldMeta] = @[]
  for ep in p.extraParams:
    let typeName = if ep.ridesAsPtr(): "pointer" else: ep.typeName
    fields.add(FFIFieldMeta(name: ep.name, typeName: typeName))
  FFITypeMeta(name: reqStructName(p), fields: fields)

func paramByValue(nimType: string, ridesAsPtr: bool): bool =
  ## Scalars / opaque pointers / string views pass by value; composite
  ## aggregates (seq, Option, user structs) pass by const pointer. Note `ptr T`
  ## rides by value as the 64-bit wire int (like `pointer`); production params
  ## reach here as `pointer` since handles are pre-converted upstream.
  if ridesAsPtr:
    return true
  parseFFIType(nimType).kind in {ftScalar, ftStr, ftPtr}

proc cReturnType(reg: var CTypeReg, p: FFIProcMeta): string =
  if p.returnRidesAsPtr():
    return CPtrType
  ensureCType(reg, p.returnTypeName).cType

proc buildReqParams(
    reg: var CTypeReg, eps: seq[FFIParamMeta]
): tuple[params, assigns: seq[string]] =
  var params: seq[string] = @[]
  var assigns: seq[string] = @[]
  for ep in eps:
    let rides = ep.ridesAsPtr()
    let cType =
      if rides:
        CPtrType
      else:
        ensureCType(reg, ep.typeName).cType
    if paramByValue(ep.typeName, rides):
      params.add(cType & " " & ep.name)
      assigns.add("    ffi_req." & ep.name & " = " & ep.name & ";")
    else:
      params.add("const " & cType & "* " & ep.name)
      assigns.add("    ffi_req." & ep.name & " = *" & ep.name & ";")
  (params, assigns)

proc evNames(
    libType, libName: string, ev: FFIEventMeta
): tuple[fnType, boxType, tramp, regName: string] =
  let pascal = capitalizeFirstLetter(ev.nimProcName)
  let snake = camelToSnakeCase(ev.nimProcName)
  (
    libType & pascal & "Fn",
    libType & pascal & "Box",
    libName & "_" & snake & "_trampoline",
    libName & "_ctx_add_" & snake & "_listener",
  )

proc emitEventMachinery(
    lines: var seq[string],
    reg: CTypeReg,
    libType, libName: string,
    events: seq[FFIEventMeta],
) =
  if events.len == 0:
    return
  lines.add("/* Event listener machinery */")
  for ev in events:
    let n = evNames(libType, libName, ev)
    let payC = ev.payloadTypeName
    let payFree = freeFn(reg, payC)
    lines.add(
      "typedef void (*" & n.fnType & ")(const " & payC & "* evt, void* user_data);"
    )
    lines.add(
      "typedef struct { " & n.fnType & " fn; void* user_data; } " & n.boxType & ";"
    )
    lines.add(
      "static void " & n.tramp & "(int ret, const char* msg, size_t len, void* ud) {"
    )
    lines.add("    if (!ud || ret != 0 || !msg || len == 0) return;")
    lines.add("    " & n.boxType & "* box = (" & n.boxType & "*)ud;")
    lines.add("    if (!box->fn) return;")
    lines.add("    CborParser parser;")
    lines.add("    CborValue it;")
    lines.add(
      "    if (cbor_parser_init((const uint8_t*)msg, len, 0, &parser, &it) != CborNoError) return;"
    )
    lines.add("    if (!cbor_value_is_map(&it)) return;")
    lines.add("    CborValue payloadField;")
    lines.add(
      "    if (cbor_value_map_find_value(&it, \"payload\", &payloadField) != CborNoError) return;"
    )
    lines.add("    " & payC & " payload;")
    lines.add("    memset(&payload, 0, sizeof(payload));")
    lines.add(
      "    if (" & decFn(reg, payC) & "(&payloadField, &payload) != CborNoError) return;"
    )
    lines.add("    box->fn(&payload, box->user_data);")
    if payFree.len > 0:
      lines.add("    " & payFree & "(&payload);")
    lines.add("}")
    lines.add("")

proc emitContextStruct(
    lines: var seq[string], ctxType: string, events: seq[FFIEventMeta]
) =
  lines.add("/* ============================================================ */")
  lines.add("/* High-level context wrapper                                   */")
  lines.add("/* ============================================================ */")
  if events.len > 0:
    lines.add("typedef struct {")
    lines.add("    uint64_t id;")
    lines.add("    void* box;")
    lines.add("} " & ctxType & "Listener;")
    lines.add("")
  lines.add("typedef struct {")
  lines.add("    void* ptr;")
  if events.len > 0:
    lines.add("    " & ctxType & "Listener* listeners;")
    lines.add("    size_t listeners_len;")
    lines.add("    size_t listeners_cap;")
  lines.add("} " & ctxType & ";")
  lines.add("")

proc emitCallBox(lines: var seq[string], fnType, boxType: string) =
  lines.add("typedef struct { " & fnType & " fn; void* user_data; } " & boxType & ";")

proc emitReplyTrampolineHead(lines: var seq[string], tramp, boxType, fallback: string) =
  ## Opens a reply trampoline: cast the user-data back to the call box, bail if
  ## the caller passed no callback (nothing to deliver to, and leaving early
  ## avoids allocating a result nobody receives), then deliver a non-zero `ret`
  ## as an error. The error text in msg/len is not NUL-terminated, so copy it.
  lines.add(
    "static void " & tramp & "(int ret, const char* msg, size_t len, void* ud) {"
  )
  lines.add("    " & boxType & "* box = (" & boxType & "*)ud;")
  lines.add("    if (!box->fn) {")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    if (ret != 0) {")
  lines.add("        char* em = nimffi_dup_cstr_n(msg ? msg : \"\", msg ? len : 0);")
  lines.add(
    "        box->fn(ret, NULL, em ? em : \"" & fallback & "\", box->user_data);"
  )
  lines.add("        free(em);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")

proc emitConstructors(
    lines: var seq[string],
    reg: var CTypeReg,
    ctxType, libType, libName: string,
    ctors: seq[FFIProcMeta],
) =
  if ctors.len == 0:
    return
  let fnType = libType & "CreateFn"
  let boxType = libType & "CreateBox"
  let tramp = libName & "_create_trampoline"
  lines.add(
    "typedef void (*" & fnType & ")(int err_code, " & ctxType &
      "* ctx, const char* err_msg, void* user_data);"
  )
  emitCallBox(lines, fnType, boxType)
  emitReplyTrampolineHead(lines, tramp, boxType, "FFI create failed")
  lines.add("    char* err = NULL;")
  lines.add("    NimFfiStr addr;")
  lines.add("    memset(&addr, 0, sizeof(addr));")
  lines.add(
    "    if (nimffi_decode_from_buf(" & libName &
      "_decv_Str, (const uint8_t*)msg, len, &addr, &err) != 0) {"
  )
  lines.add("        box->fn(-1, NULL, err ? err : \"decode failed\", box->user_data);")
  lines.add("        free(err);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    char* endp = NULL;")
  lines.add(
    "    unsigned long long a = addr.data ? strtoull(addr.data, &endp, 10) : 0;"
  )
  lines.add("    bool ok = addr.data && addr.len > 0 && endp && *endp == '\\0';")
  lines.add("    nimffi_free_str(&addr);")
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
    let reqName = reqStructName(ctor)
    let (params, assigns) = buildReqParams(reg, ctor.extraParams)
    let head = "static inline int " & libName & "_ctx_create("
    let sig =
      if params.len > 0:
        head & params.join(", ") & ", " & fnType & " on_created, void* user_data) {"
      else:
        head & fnType & " on_created, void* user_data) {"
    lines.add(sig)
    lines.add("    " & reqName & " ffi_req;")
    lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
    for a in assigns:
      lines.add(a)
    lines.add("    uint8_t* req_buf = NULL;")
    lines.add("    size_t req_len = 0;")
    lines.add("    char* err = NULL;")
    lines.add(
      "    if (nimffi_encode_to_buf(" & libName & "_encv_" & cToken(reqName) &
        ", &ffi_req, &req_buf, &req_len, &err) != 0) {"
    )
    lines.add(
      "        if (on_created) on_created(-1, NULL, err ? err : \"encode failed\", user_data);"
    )
    lines.add("        free(err);")
    lines.add("        return -1;")
    lines.add("    }")
    lines.add(
      "    " & boxType & "* box = (" & boxType & "*)malloc(sizeof(" & boxType & "));"
    )
    lines.add("    if (!box) {")
    lines.add("        free(req_buf);")
    lines.add(
      "        if (on_created) on_created(-1, NULL, \"out of memory\", user_data);"
    )
    lines.add("        return -1;")
    lines.add("    }")
    lines.add("    box->fn = on_created;")
    lines.add("    box->user_data = user_data;")
    lines.add("    (void)" & ctor.procName & "(req_buf, req_len, " & tramp & ", box);")
    lines.add("    free(req_buf);")
    lines.add("    return 0;")
    lines.add("}")
    lines.add("")

proc emitDestructor(
    lines: var seq[string],
    ctxType, libName, dtorProcName: string,
    events: seq[FFIEventMeta],
) =
  lines.add("static inline void " & libName & "_ctx_destroy(" & ctxType & "* ctx) {")
  lines.add("    if (!ctx) return;")
  if dtorProcName.len > 0:
    lines.add("    if (ctx->ptr) { " & dtorProcName & "(ctx->ptr); ctx->ptr = NULL; }")
  if events.len > 0:
    lines.add(
      "    for (size_t i = 0; i < ctx->listeners_len; i++) free(ctx->listeners[i].box);"
    )
    lines.add("    free(ctx->listeners);")
  lines.add("    free(ctx);")
  lines.add("}")
  lines.add("")

proc emitListenerApi(
    lines: var seq[string], ctxType, libType, libName: string, events: seq[FFIEventMeta]
) =
  if events.len == 0:
    return
  for ev in events:
    let n = evNames(libType, libName, ev)
    lines.add(
      "static inline uint64_t " & n.regName & "(" & ctxType & "* ctx, " & n.fnType &
        " fn, void* user_data) {"
    )
    lines.add(
      "    " & n.boxType & "* box = (" & n.boxType & "*)malloc(sizeof(" & n.boxType &
        "));"
    )
    lines.add("    if (!box) return 0;")
    lines.add("    box->fn = fn;")
    lines.add("    box->user_data = user_data;")
    lines.add(
      "    uint64_t id = " & libName & "_add_event_listener(ctx->ptr, \"" & ev.wireName &
        "\", " & n.tramp & ", box);"
    )
    lines.add("    if (id == 0) { free(box); return 0; }")
    lines.add("    if (ctx->listeners_len == ctx->listeners_cap) {")
    lines.add("        size_t ncap = ctx->listeners_cap ? ctx->listeners_cap * 2 : 4;")
    lines.add(
      "        " & ctxType & "Listener* grown = (" & ctxType &
        "Listener*)realloc(ctx->listeners, ncap * sizeof(" & ctxType & "Listener));"
    )
    lines.add(
      "        if (!grown) { " & libName &
        "_remove_event_listener(ctx->ptr, id); free(box); return 0; }"
    )
    lines.add("        ctx->listeners = grown;")
    lines.add("        ctx->listeners_cap = ncap;")
    lines.add("    }")
    lines.add("    ctx->listeners[ctx->listeners_len].id = id;")
    lines.add("    ctx->listeners[ctx->listeners_len].box = box;")
    lines.add("    ctx->listeners_len++;")
    lines.add("    return id;")
    lines.add("}")
    lines.add("")
  lines.add(
    "static inline bool " & libName & "_ctx_remove_event_listener(" & ctxType &
      "* ctx, uint64_t id) {"
  )
  lines.add("    if (id == 0) return false;")
  lines.add("    int rc = " & libName & "_remove_event_listener(ctx->ptr, id);")
  lines.add("    for (size_t i = 0; i < ctx->listeners_len; i++) {")
  lines.add("        if (ctx->listeners[i].id == id) {")
  lines.add("            free(ctx->listeners[i].box);")
  lines.add("            ctx->listeners[i] = ctx->listeners[ctx->listeners_len - 1];")
  lines.add("            ctx->listeners_len--;")
  lines.add("            break;")
  lines.add("        }")
  lines.add("    }")
  lines.add("    return rc == 0;")
  lines.add("}")
  lines.add("")

proc emitMethod(
    lines: var seq[string],
    reg: var CTypeReg,
    ctxType, libType, libName: string,
    m: FFIProcMeta,
) =
  let stripped = stripLibPrefix(m.procName, libName)
  let reqName = reqStructName(m)
  let retC = cReturnType(reg, m)
  let retFree = freeFn(reg, retC)
  let (params, assigns) = buildReqParams(reg, m.extraParams)
  let methodPascal = snakeToPascalCase(stripped)
  let fnType = libType & methodPascal & "ReplyFn"
  let boxType = libType & methodPascal & "CallBox"
  let tramp = libName & "_" & stripped & "_reply_trampoline"

  lines.add(
    "typedef void (*" & fnType & ")(int err_code, const " & retC &
      "* reply, const char* err_msg, void* user_data);"
  )
  emitCallBox(lines, fnType, boxType)
  emitReplyTrampolineHead(lines, tramp, boxType, "FFI call failed")
  lines.add("    char* err = NULL;")
  lines.add("    " & retC & " out;")
  lines.add("    memset(&out, 0, sizeof(out));")
  lines.add(
    "    int dec = nimffi_decode_from_buf(" & libName & "_decv_" & cToken(retC) &
      ", (const uint8_t*)msg, len, &out, &err);"
  )
  lines.add("    if (dec != 0) {")
  lines.add("        box->fn(-1, NULL, err ? err : \"decode failed\", box->user_data);")
  lines.add("        free(err);")
  # A partial decode may have allocated some fields; reclaim them (out is
  # zeroed, so the typed free skips what was never written).
  if retFree.len > 0:
    lines.add("        " & retFree & "(&out);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);")
  if retFree.len > 0:
    lines.add("    " & retFree & "(&out);")
  lines.add("    free(box);")
  lines.add("}")

  let head =
    "static inline int " & libName & "_ctx_" & stripped & "(const " & ctxType & "* ctx, "
  let sig =
    if params.len > 0:
      head & params.join(", ") & ", " & fnType & " on_reply, void* user_data) {"
    else:
      head & fnType & " on_reply, void* user_data) {"
  lines.add(sig)
  lines.add("    " & reqName & " ffi_req;")
  lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
  for a in assigns:
    lines.add(a)
  lines.add("    uint8_t* req_buf = NULL;")
  lines.add("    size_t req_len = 0;")
  lines.add("    char* err = NULL;")
  lines.add(
    "    if (nimffi_encode_to_buf(" & libName & "_encv_" & cToken(reqName) &
      ", &ffi_req, &req_buf, &req_len, &err) != 0) {"
  )
  lines.add(
    "        if (on_reply) on_reply(-1, NULL, err ? err : \"encode failed\", user_data);"
  )
  lines.add("        free(err);")
  lines.add("        return -1;")
  lines.add("    }")
  lines.add(
    "    " & boxType & "* box = (" & boxType & "*)malloc(sizeof(" & boxType & "));"
  )
  lines.add("    if (!box) {")
  lines.add("        free(req_buf);")
  lines.add("        if (on_reply) on_reply(-1, NULL, \"out of memory\", user_data);")
  lines.add("        return -1;")
  lines.add("    }")
  lines.add("    box->fn = on_reply;")
  lines.add("    box->user_data = user_data;")
  lines.add(
    "    int ret = " & m.procName & "(ctx->ptr, " & tramp & ", box, req_buf, req_len);"
  )
  lines.add("    free(req_buf);")
  lines.add("    if (ret == NIMFFI_RET_MISSING_CALLBACK) {")
  lines.add(
    "        if (on_reply) on_reply(-1, NULL, \"RET_MISSING_CALLBACK (internal error)\", user_data);"
  )
  lines.add("        free(box);")
  lines.add("        return -1;")
  lines.add("    }")
  lines.add("    return 0;")
  lines.add("}")
  lines.add("")

proc newCTypeReg(
    libName, libType: string, types: seq[FFITypeMeta], procs: seq[FFIProcMeta]
): CTypeReg =
  var reg = CTypeReg(libName: libName, libType: libType)
  for t in types:
    reg.typeTable[t.name] = t
  for p in procs:
    if p.kind != FFIKind.DTOR:
      let rt = reqTypeMeta(p)
      reg.typeTable[rt.name] = rt
  reg

proc monomorphiseAll(
    reg: var CTypeReg,
    types: seq[FFITypeMeta],
    procs, methods: seq[FFIProcMeta],
    events: seq[FFIEventMeta],
): tuple[reqTypes, respTypes: seq[string]] =
  ## Walks every user type, per-proc Req envelope, return type and event
  ## payload through ensureCType, emitting their structs/codecs into `reg` in
  ## dependency order. Returns the Req and response C type names the buffer
  ## adapters need.
  for t in types:
    discard ensureCType(reg, t.name)
  var reqTypes: seq[string] = @[]
  for p in procs:
    if p.kind != FFIKind.DTOR:
      let n = reqStructName(p)
      discard ensureCType(reg, n)
      reqTypes.add(n)
  var respTypes: seq[string] = @[]
  for m in methods:
    respTypes.add(cReturnType(reg, m))
  for ev in events:
    discard ensureCType(reg, ev.payloadTypeName)
  (reqTypes, respTypes)

func generateCPreludeHeader*(): string =
  ## The `nim_ffi_prelude.h` shared header: owned string/byte types plus the
  ## libc/TinyCBOR includes every nim-ffi C binding needs. Identical across
  ## libraries, so it is emitted verbatim from the template.
  HeaderPreludeTpl & "\n"

func generateCCborHeader*(): string =
  ## The `nim_ffi_cbor.h` shared header: leaf CBOR codecs and buffer drivers.
  ## Includes the prelude (its guard is inside the template) and is library-
  ## agnostic, so it too is emitted verbatim.
  CborHelpersTpl & "\n"

proc generateCLibHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
): string =
  ## The `<lib>.h` header: library-specific structs, monomorphised codecs and
  ## the async API. Pulls the two shared headers in via the cbor header.
  let classified = classifyProcs(procs)
  let ctors = classified.ctors
  let methods = classified.methods
  let libType = libTypeName(ctors, libName)
  let ctxType = libType & "Ctx"

  var reg = newCTypeReg(libName, libType, types, procs)
  let (reqTypes, respTypes) = monomorphiseAll(reg, types, procs, methods, events)

  let guard = "NIM_FFI_LIB_" & libName.toUpperAscii() & "_H_INCLUDED"
  var lines: seq[string] = @[]
  lines.add("#ifndef " & guard)
  lines.add("#define " & guard)
  lines.add("#include \"" & CborHeaderName & "\"")
  lines.add("")

  lines.add("/* ============================================================ */")
  lines.add("/* Generated types (user-declared + per-proc request envelopes) */")
  lines.add("/* ============================================================ */")
  lines.add("")
  for decl in reg.decls:
    lines.add(decl)
  lines.add("")
  for codec in reg.codecs:
    lines.add(codec)
  lines.add("")

  lines.add("/* ============================================================ */")
  lines.add("/* C ABI declarations (symbols exported by the Nim dylib)       */")
  lines.add("/* ============================================================ */")
  lines.add("#ifdef __cplusplus")
  lines.add("extern \"C\" {")
  lines.add("#endif")
  lines.add("")
  for p in procs:
    case p.kind
    of FFIKind.FFI:
      lines.add(
        "int " & p.procName & "(void* ctx, FFICallback callback, void* user_data, " &
          "const uint8_t* req_cbor, size_t req_cbor_len);"
      )
    of FFIKind.CTOR:
      lines.add(
        "void* " & p.procName & "(const uint8_t* req_cbor, size_t req_cbor_len, " &
          "FFICallback callback, void* user_data);"
      )
    of FFIKind.DTOR:
      lines.add("int " & p.procName & "(void* ctx);")
  lines.add(
    "uint64_t " & libName & "_add_event_listener(void* ctx, const char* event_name, " &
      "FFICallback callback, void* user_data);"
  )
  lines.add(
    "int " & libName & "_remove_event_listener(void* ctx, uint64_t listener_id);"
  )
  lines.add("")
  lines.add("#ifdef __cplusplus")
  lines.add("} /* extern \"C\" */")
  lines.add("#endif")
  lines.add("")

  # Per-Req encode / per-response decode void* adapters for the buffer drivers.
  var adaptersDone = initHashSet[string]()
  lines.add("/* CBOR buffer adapters (typed codec → void* driver signature) */")
  for n in reqTypes:
    let tok = cToken(n)
    if ("enc" & tok) notin adaptersDone:
      adaptersDone.incl("enc" & tok)
      lines.add(
        "static inline CborError " & libName & "_encv_" & tok &
          "(CborEncoder* e, const void* v) { return " & reg.libName & "_enc_" & n &
          "(e, (const " & n & "*)v); }"
      )
  var respSet = respTypes
  respSet.add("NimFfiStr") # ctor address payload
  for n in respSet:
    let tok = cToken(n)
    if ("dec" & tok) notin adaptersDone:
      adaptersDone.incl("dec" & tok)
      lines.add(
        "static inline CborError " & libName & "_decv_" & tok &
          "(CborValue* it, void* v) { return " & decFn(reg, n) & "(it, (" & n & "*)v); }"
      )
  lines.add("")

  emitEventMachinery(lines, reg, libType, libName, events)
  emitContextStruct(lines, ctxType, events)
  emitConstructors(lines, reg, ctxType, libType, libName, ctors)
  emitDestructor(lines, ctxType, libName, classified.dtorProcName, events)
  emitListenerApi(lines, ctxType, libType, libName, events)
  for m in methods:
    emitMethod(lines, reg, ctxType, libType, libName, m)

  lines.add("#endif /* " & guard & " */")
  lines.join("\n") & "\n"

proc generateCCMakeLists*(libName, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  CMakeListsTpl.multiReplace(("{{LIB}}", libName), ("{{SRC}}", src))

proc generateCBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
) =
  createDir(outputDir)
  writeFile(outputDir / PreludeHeaderName, generateCPreludeHeader())
  writeFile(outputDir / CborHeaderName, generateCCborHeader())
  writeFile(
    outputDir / (libName & ".h"), generateCLibHeader(procs, types, libName, events)
  )
  writeFile(outputDir / "CMakeLists.txt", generateCCMakeLists(libName, nimSrcRelPath))
