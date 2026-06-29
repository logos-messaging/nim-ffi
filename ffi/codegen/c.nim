## C99 binding generator for the nim-ffi framework.
## Emits a header-only C binding plus a CMakeLists.txt. Requests/responses
## travel as CBOR (encoded with the same vendored TinyCBOR the C++ backend
## uses, matching the Nim-side cbor_serial codec — both ends speak RFC 8949).
##
## C has neither generics nor overloading, so the codecs the C++ backend gets
## from templates are monomorphised here: every distinct `seq[T]` / `Option[T]`
## becomes its own struct + encode/decode/free triple, and each leaf type has a
## distinctly-named codec emitted by the cbor_helpers template.

import std/[os, strutils, tables, sets]
import ./meta, ./string_helpers, ./common

## Wire-format C type for any Nim `ptr T` / `pointer`. Fixed 64-bit so the CBOR
## payload size is stable regardless of host architecture (mirrors CppPtrType).
const CPtrType* = "uint64_t"

const
  HeaderPreludeTpl = staticRead("templates/c/header_prelude.h.tpl")
  CborHelpersTpl = staticRead("templates/c/cbor_helpers.h.tpl")
  SyncCallHelperTpl = staticRead("templates/c/sync_call_helper.h.tpl")
  CMakeListsTpl = staticRead("templates/c/CMakeLists.txt.tpl")

type LeafInfo = tuple[ok: bool, cType: string, suffix: string, owns: bool]

proc leafCType(t: string): LeafInfo =
  ## Maps a Nim leaf type to its C type, codec suffix and whether a decoded
  ## value owns heap memory. `ok` is false for composite types (seq/Option/
  ## user structs), which are monomorphised separately.
  case t
  of "int", "int64":
    (true, "int64_t", "i64", false)
  of "int32":
    (true, "int32_t", "i32", false)
  of "int16":
    (true, "int16_t", "i16", false)
  of "int8":
    (true, "int8_t", "i8", false)
  of "uint", "uint64":
    (true, "uint64_t", "u64", false)
  of "uint32":
    (true, "uint32_t", "u32", false)
  of "uint16":
    (true, "uint16_t", "u16", false)
  of "uint8", "byte":
    (true, "uint8_t", "u8", false)
  of "bool":
    (true, "bool", "bool", false)
  of "float", "float64":
    (true, "double", "f64", false)
  of "float32":
    (true, "float", "f32", false)
  of "pointer":
    (true, CPtrType, "u64", false)
  of "string", "cstring":
    (true, "NimFfiStr", "str", true)
  else:
    (false, "", "", false)

proc cToken(cType: string): string =
  ## Short PascalCase token used to build monomorphised container names and
  ## codec-adapter symbols. Composite C type names are already unique C
  ## identifiers, so they pass through verbatim.
  case cType
  of "int64_t": "I64"
  of "int32_t": "I32"
  of "int16_t": "I16"
  of "int8_t": "I8"
  of "uint64_t": "U64"
  of "uint32_t": "U32"
  of "uint16_t": "U16"
  of "uint8_t": "U8"
  of "bool": "Bool"
  of "double": "F64"
  of "float": "F32"
  of "NimFfiStr": "Str"
  of "NimFfiBytes": "Bytes"
  else: cType

proc leafSuffix(cType: string): string =
  ## Inverse of leafCType's cType→suffix for the leaf codecs the template
  ## provides; empty string for composite types.
  case cType
  of "int64_t": "i64"
  of "int32_t": "i32"
  of "int16_t": "i16"
  of "int8_t": "i8"
  of "uint64_t": "u64"
  of "uint32_t": "u32"
  of "uint16_t": "u16"
  of "uint8_t": "u8"
  of "bool": "bool"
  of "double": "f64"
  of "float": "f32"
  of "NimFfiStr": "str"
  of "NimFfiBytes": "bytes"
  else: ""

type CTypeReg = object
  libName: string ## snake_case symbol prefix, e.g. "my_timer"
  libType: string ## PascalCase container-name prefix, e.g. "MyTimer"
  typeTable: Table[string, FFITypeMeta] ## user structs + synthetic Req structs
  emitted: HashSet[string] ## composite C type names already emitted
  owns: Table[string, bool] ## C type name → owns-heap-memory
  decls: seq[string] ## struct typedefs, dependency order
  codecs: seq[string] ## enc/dec/free defs, dependency order

proc encFn(reg: CTypeReg, cType: string): string =
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return "nimffi_enc_" & suffix
  reg.libName & "_enc_" & cType

proc decFn(reg: CTypeReg, cType: string): string =
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return "nimffi_dec_" & suffix
  reg.libName & "_dec_" & cType

proc freeFn(reg: CTypeReg, cType: string): string =
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
  if members.len == 0:
    body.add("        CborEncoder* e, const " & t.name & "* v) {")
    body.add("    (void)v;")
  else:
    body.add("        CborEncoder* e, const " & t.name & "* v) {")
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

proc ensureCType(reg: var CTypeReg, nimType: string): tuple[cType: string, owns: bool] =
  let t = nimType.strip()
  if t.startsWith("ptr ") or t == "pointer":
    return (CPtrType, false)
  let leaf = leafCType(t)
  if leaf.ok:
    return (leaf.cType, leaf.owns)

  let seqInner = genericInnerType(t, "seq[")
  if seqInner.len > 0:
    let inner = seqInner.strip()
    if inner == "byte" or inner == "uint8":
      return ("NimFfiBytes", true)
    let (elemC, _) = ensureCType(reg, inner)
    let name = reg.libType & "Seq_" & cToken(elemC)
    if name notin reg.emitted:
      reg.emitted.incl(name)
      emitSeqType(reg, name, elemC)
    return (name, true)

  var optInner = genericInnerType(t, "Option[")
  if optInner.len == 0:
    optInner = genericInnerType(t, "Maybe[")
  if optInner.len > 0:
    let (elemC, elemOwns) = ensureCType(reg, optInner.strip())
    let name = reg.libType & "Opt_" & cToken(elemC)
    if name notin reg.emitted:
      reg.emitted.incl(name)
      emitOptType(reg, name, elemC, elemOwns)
    return (name, reg.owns.getOrDefault(name, false))

  if t notin reg.emitted:
    reg.emitted.incl(t)
    if t in reg.typeTable:
      emitStructType(reg, reg.typeTable[t])
    else:
      reg.decls.add("/* unknown type referenced: " & t & " */")
  (t, reg.owns.getOrDefault(t, false))

proc reqTypeMeta(p: FFIProcMeta): FFITypeMeta =
  ## Synthesises the per-proc Req struct as an FFITypeMeta so it flows through
  ## the same monomorphisation path as user-declared types. Pointer/handle
  ## params ride the wire as the opaque uint64 pointer type.
  var fields: seq[FFIFieldMeta] = @[]
  for ep in p.extraParams:
    let typeName = if ep.ridesAsPtr(): "pointer" else: ep.typeName
    fields.add(FFIFieldMeta(name: ep.name, typeName: typeName))
  FFITypeMeta(name: reqStructName(p), fields: fields)

proc paramByValue(reg: CTypeReg, nimType: string, ridesAsPtr: bool): bool =
  ## Scalars / opaque pointers / string views pass by value; composite
  ## aggregates (seq, Option, user structs) pass by const pointer.
  if ridesAsPtr:
    return true
  leafCType(nimType.strip()).ok

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
    if paramByValue(reg, ep.typeName, rides):
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
  lines.add("    uint32_t timeout_ms;")
  if events.len > 0:
    lines.add("    " & ctxType & "Listener* listeners;")
    lines.add("    size_t listeners_len;")
    lines.add("    size_t listeners_cap;")
  lines.add("} " & ctxType & ";")
  lines.add("")

proc emitConstructors(
    lines: var seq[string],
    reg: var CTypeReg,
    ctxType, libName: string,
    ctors: seq[FFIProcMeta],
) =
  for ctor in ctors:
    let reqName = reqStructName(ctor)
    let (params, assigns) = buildReqParams(reg, ctor.extraParams)
    let sig = block:
      let head = "static inline " & ctxType & "* " & libName & "_ctx_create("
      if params.len > 0:
        head & params.join(", ") & ", uint32_t timeout_ms, char** err) {"
      else:
        head & "uint32_t timeout_ms, char** err) {"
    lines.add(sig)
    lines.add("    if (err) *err = NULL;")
    lines.add("    " & reqName & " ffi_req;")
    lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
    for a in assigns:
      lines.add(a)
    lines.add("    uint8_t* req_buf = NULL;")
    lines.add("    size_t req_len = 0;")
    lines.add(
      "    if (nimffi_encode_to_buf(" & libName & "_encv_" & cToken(reqName) &
        ", &ffi_req, &req_buf, &req_len, err) != 0) return NULL;"
    )
    lines.add("    NimFfiCallState* st = nimffi_state_new();")
    lines.add(
      "    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr(\"out of memory\"); return NULL; }"
    )
    lines.add(
      "    (void)" & ctor.procName & "(req_buf, req_len, nimffi_on_result, st);"
    )
    lines.add("    free(req_buf);")
    lines.add("    uint8_t* resp = NULL;")
    lines.add("    size_t resp_len = 0;")
    lines.add(
      "    if (nimffi_wait_result(st, timeout_ms, &resp, &resp_len, err) != 0) return NULL;"
    )
    lines.add("    NimFfiStr addr;")
    lines.add("    memset(&addr, 0, sizeof(addr));")
    lines.add(
      "    if (nimffi_decode_from_buf(" & libName &
        "_decv_Str, resp, resp_len, &addr, err) != 0) { free(resp); return NULL; }"
    )
    lines.add("    free(resp);")
    lines.add("    char* endp = NULL;")
    lines.add(
      "    unsigned long long a = addr.data ? strtoull(addr.data, &endp, 10) : 0;"
    )
    lines.add("    bool ok = addr.data && addr.len > 0 && endp && *endp == '\\0';")
    lines.add("    nimffi_free_str(&addr);")
    lines.add(
      "    if (!ok) { if (err) *err = nimffi_dup_cstr(\"FFI create returned non-numeric address\"); return NULL; }"
    )
    lines.add(
      "    " & ctxType & "* ctx = (" & ctxType & "*)calloc(1, sizeof(" & ctxType & "));"
    )
    lines.add(
      "    if (!ctx) { if (err) *err = nimffi_dup_cstr(\"out of memory\"); return NULL; }"
    )
    lines.add("    ctx->ptr = (void*)(uintptr_t)a;")
    lines.add("    ctx->timeout_ms = timeout_ms;")
    lines.add("    return ctx;")
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
    lines: var seq[string], reg: var CTypeReg, ctxType, libName: string, m: FFIProcMeta
) =
  let stripped = stripLibPrefix(m.procName, libName)
  let reqName = reqStructName(m)
  let retC = cReturnType(reg, m)
  let (params, assigns) = buildReqParams(reg, m.extraParams)
  let head =
    "static inline int " & libName & "_ctx_" & stripped & "(const " & ctxType & "* ctx, "
  let sig =
    if params.len > 0:
      head & params.join(", ") & ", " & retC & "* out, char** err) {"
    else:
      head & retC & "* out, char** err) {"
  lines.add(sig)
  lines.add("    if (err) *err = NULL;")
  lines.add("    " & reqName & " ffi_req;")
  lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
  for a in assigns:
    lines.add(a)
  lines.add("    uint8_t* req_buf = NULL;")
  lines.add("    size_t req_len = 0;")
  lines.add(
    "    if (nimffi_encode_to_buf(" & libName & "_encv_" & cToken(reqName) &
      ", &ffi_req, &req_buf, &req_len, err) != 0) return -1;"
  )
  lines.add("    NimFfiCallState* st = nimffi_state_new();")
  lines.add(
    "    if (!st) { free(req_buf); if (err) *err = nimffi_dup_cstr(\"out of memory\"); return -1; }"
  )
  lines.add(
    "    int ret = " & m.procName & "(ctx->ptr, nimffi_on_result, st, req_buf, req_len);"
  )
  lines.add("    free(req_buf);")
  lines.add("    if (ret == NIMFFI_RET_MISSING_CALLBACK) {")
  lines.add("        nimffi_state_unref(st);")
  lines.add("        nimffi_state_unref(st);")
  lines.add(
    "        if (err) *err = nimffi_dup_cstr(\"RET_MISSING_CALLBACK (internal error)\");"
  )
  lines.add("        return -1;")
  lines.add("    }")
  lines.add("    uint8_t* resp = NULL;")
  lines.add("    size_t resp_len = 0;")
  lines.add(
    "    if (nimffi_wait_result(st, ctx->timeout_ms, &resp, &resp_len, err) != 0) return -1;"
  )
  lines.add("    memset(out, 0, sizeof(*out));")
  lines.add(
    "    int dec = nimffi_decode_from_buf(" & libName & "_decv_" & cToken(retC) &
      ", resp, resp_len, out, err);"
  )
  lines.add("    free(resp);")
  # Reclaim fields a partial decode already allocated (out is zeroed, so the
  # typed free skips the rest); re-zero so the caller can free again safely.
  let retFree = freeFn(reg, retC)
  if retFree.len > 0:
    lines.add("    if (dec != 0) {")
    lines.add("        " & retFree & "(out);")
    lines.add("        memset(out, 0, sizeof(*out));")
    lines.add("    }")
  lines.add("    return dec;")
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

proc generateCHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
): string =
  let classified = classifyProcs(procs)
  let ctors = classified.ctors
  let methods = classified.methods
  let libType = libTypeName(ctors, libName)
  let ctxType = libType & "Ctx"

  var reg = newCTypeReg(libName, libType, types, procs)
  let (reqTypes, respTypes) = monomorphiseAll(reg, types, procs, methods, events)

  var lines: seq[string] = @[]
  lines.add(HeaderPreludeTpl)
  lines.add(CborHelpersTpl)

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

  lines.add(SyncCallHelperTpl)
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
  emitConstructors(lines, reg, ctxType, libName, ctors)
  emitDestructor(lines, ctxType, libName, classified.dtorProcName, events)
  emitListenerApi(lines, ctxType, libType, libName, events)
  for m in methods:
    emitMethod(lines, reg, ctxType, libName, m)

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
  writeFile(
    outputDir / (libName & ".h"), generateCHeader(procs, types, libName, events)
  )
  writeFile(outputDir / "CMakeLists.txt", generateCCMakeLists(libName, nimSrcRelPath))
