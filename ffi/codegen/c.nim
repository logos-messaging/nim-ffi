## C99 binding generator: emits the three CBOR headers. C lacks generics, so
## each distinct `seq[T]`/`Option[T]` is monomorphised per type.

import std/[strutils, tables, sets, options]
import
  ./meta,
  ./string_helpers,
  ./c_cpp_common,
  ./types_ir,
  ./consts,
  ./build_paths,
  ../ret_codes,
  ../ffi_msg

## Fixed 64-bit wire type for any Nim `ptr T`/`pointer` (mirrors CppPtrType).
const CPtrType* = "uint64_t"

## Nim `string`/`cstring` crosses as a plain NUL-terminated C string: borrowed
## on the request side, binding-owned on the response side.
const CStrType* = "const char*"

const
  HeaderPreludeTpl = staticRead("templates/c/header_prelude.h.tpl")
  CborHelpersTpl = staticRead("templates/c/cbor_helpers.h.tpl")
  CMakeListsTpl = staticRead("templates/c/CMakeLists.txt.tpl")
  CtxAwaitTpl = staticRead("templates/c/ctx_await.h.tpl")
  StaticCtxTpl = staticRead("templates/c/static_ctx.h.tpl")
  FindRepoRootTpl = staticRead("templates/find_repo_root.cmake.part")

  # Shared header names; must match the include guards baked into the templates.
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
  ## Leaf codec suffix for `cType`; "" for composites.
  for s in ScalarKind:
    if scalarCInfoTable[s].cType == cType:
      return scalarCInfoTable[s].suffix
  return
    case cType
    of CStrType: "str"
    of "NimFfiBytes": "bytes"
    else: ""

func byPtrConst(cType: string): string =
  ## Read-only by-pointer spelling of `cType`; the string leaf already carries
  ## its own `const`, so the pointer itself is what gains one.
  if cType == CStrType:
    return CStrType & " const*"
  return "const " & cType & "*"

func cToken(cType: string): string =
  ## PascalCase token for monomorphised names.
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return capitalizeFirstLetter(suffix)
  return cType

type CTypeReg = object
  libName: string ## snake_case symbol prefix
  libType: string ## PascalCase container-name prefix
  typeTable: Table[string, FFITypeMeta]
  emitted: HashSet[string]
  owns: Table[string, bool] ## C type name → owns-heap-memory
  decls: seq[string]
  codecs: seq[string]

func encFn(reg: CTypeReg, cType: string): string =
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return "nimffi_enc_" & suffix
  return reg.libName & "_enc_" & cType

func decFn(reg: CTypeReg, cType: string): string =
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return "nimffi_dec_" & suffix
  return reg.libName & "_dec_" & cType

func freeStmt(reg: CTypeReg, cType, lvalue: string): string =
  ## Statement reclaiming `lvalue`, or "" when `cType` owns no heap memory.
  ## The string leaf frees in place, nulling the pointer so freeing the owning
  ## struct twice stays a no-op as it is for every other leaf; the cast drops
  ## the `const` it was decoded with, and `do/while` keeps the pair a single
  ## statement for the brace-less seq free loop.
  return
    case cType
    of CStrType:
      "do { free((void*)" & lvalue & "); " & lvalue & " = NULL; } while (0);"
    of "NimFfiBytes":
      "nimffi_free_bytes(&" & lvalue & ");"
    else:
      if leafSuffix(cType).len > 0:
        ""
      elif reg.owns.getOrDefault(cType, false):
        reg.libName & "_free_" & cType & "(&" & lvalue & ");"
      else:
        ""

proc emitSeqType(reg: var CTypeReg, name, elemC: string) =
  let eEnc = encFn(reg, elemC)
  let eDec = decFn(reg, elemC)
  let eFree = freeStmt(reg, elemC, "v->data[i]")
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
    body.add("    for (size_t i = 0; i < v->len; i++) " & eFree)
  body.add("    free(v->data);")
  body.add("    v->data = NULL;")
  body.add("    v->len = 0;")
  body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[name] = true

proc emitOptType(reg: var CTypeReg, name, elemC: string, elemOwns: bool) =
  let eEnc = encFn(reg, elemC)
  let eDec = decFn(reg, elemC)
  let eFree = freeStmt(reg, elemC, "v->value")
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
    body.add("    " & eFree)
    body.add("    v->has_value = false;")
    body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[name] = elemOwns

proc ensureCType(reg: var CTypeReg, nimType: string): tuple[cType: string, owns: bool]

func enumConstName*(typeName, valueName: string): string =
  ## C/CDDL-safe constant name for an enum value, e.g. ("Color", "cRed") → COLOR_C_RED.
  return identToUpperSnake(typeName) & "_" & identToUpperSnake(valueName)

proc emitEnumType(reg: var CTypeReg, t: FFITypeMeta) =
  ## A `{.ffi.}` enum becomes a C enum whose codec maps to the CBOR text form
  ## (the value's Nim symbol name, or its associated string) that
  ## cbor_serialization writes.
  var members: seq[string] = @[]
  for v in t.enumValues:
    members.add("    " & enumConstName(t.name, v.name) & " = " & $v.ord & ",")
  members[^1].removeSuffix(',')
  reg.decls.add("typedef enum {\n" & members.join("\n") & "\n} " & t.name & ";")

  var longest = 0
  for v in t.enumValues:
    longest = max(longest, v.wire.len)

  var body: seq[string] = @[]
  body.add("static inline CborError " & reg.libName & "_enc_" & t.name & "(")
  body.add("        CborEncoder* e, const " & t.name & "* v) {")
  body.add("    switch (*v) {")
  for v in t.enumValues:
    body.add(
      "    case " & enumConstName(t.name, v.name) &
        ": return cbor_encode_text_stringz(e, \"" & v.wire & "\");"
    )
  body.add("    }")
  body.add("    return CborErrorImproperValue;")
  body.add("}")

  body.add("static inline CborError " & reg.libName & "_dec_" & t.name & "(")
  body.add("        CborValue* it, " & t.name & "* out) {")
  body.add("    if (!cbor_value_is_text_string(it)) return CborErrorImproperValue;")
  body.add("    size_t len = 0;")
  body.add("    CborError err = cbor_value_get_string_length(it, &len);")
  body.add("    if (err) return err;")
  body.add("    char buf[" & $(longest + 1) & "];")
  body.add("    if (len >= sizeof(buf)) return CborErrorImproperValue;")
  body.add("    size_t copied = sizeof(buf);")
  body.add("    err = cbor_value_copy_text_string(it, buf, &copied, NULL);")
  body.add("    if (err) return err;")
  body.add("    buf[len] = '\\0';")
  for v in t.enumValues:
    body.add(
      "    if (strcmp(buf, \"" & v.wire & "\") == 0) { *out = " &
        enumConstName(t.name, v.name) & "; return cbor_value_advance(it); }"
    )
  body.add("    return CborErrorImproperValue;")
  body.add("}")

  reg.codecs.add(body.join("\n"))
  reg.owns[t.name] = false

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
      let ff = freeStmt(reg, mem.cType, "v->" & mem.name)
      if mem.owns and ff.len > 0:
        body.add("    " & ff)
    body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[t.name] = owns

proc ensureCType(reg: var CTypeReg, t: FFIType): tuple[cType: string, owns: bool] =
  ## Lowers an `FFIType` to a C type, monomorphising each `seq[T]`/`Option[T]`
  ## on first sight. `owns` marks a type the caller must free.
  case t.kind
  of ftPtr:
    return (CPtrType, false)
  of ftScalar:
    return (scalarCInfoTable[t.scalar].cType, false)
  of ftStr:
    return (CStrType, true)
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
        let meta = reg.typeTable[name]
        if meta.isEnum():
          emitEnumType(reg, meta)
        else:
          emitStructType(reg, meta)
      else:
        reg.decls.add("/* unknown type referenced: " & name & " */")
    return (name, reg.owns.getOrDefault(name, false))

proc ensureCType(reg: var CTypeReg, nimType: string): tuple[cType: string, owns: bool] =
  return ensureCType(reg, parseFFIType(nimType))

proc reqTypeMeta(p: FFIProcMeta): FFITypeMeta =
  ## Synthesises the per-proc Req struct; pointer/handle params ride as uint64.
  var fields: seq[FFIFieldMeta] = @[]
  for ep in p.extraParams:
    let typeName = if ep.ridesAsPtr(): "pointer" else: ep.typeName
    fields.add(FFIFieldMeta(name: ep.name, typeName: typeName))
  return FFITypeMeta(name: reqStructName(p), fields: fields)

func paramByValue(reg: CTypeReg, nimType: string, ridesAsPtr: bool): bool =
  ## Scalars/pointers/string views and enums pass by value; aggregates by const pointer.
  if ridesAsPtr:
    return true
  let t = parseFFIType(nimType)
  if t.kind == ftStruct and reg.typeTable.getOrDefault(t.name).isEnum():
    return true
  return t.kind in {ftScalar, ftStr, ftPtr}

proc cReturnType(reg: var CTypeReg, p: FFIProcMeta): string =
  if p.returnRidesAsPtr():
    return CPtrType
  return ensureCType(reg, p.returnTypeName).cType

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
  return (params, assigns)

const
  RequestDoc = """A request export queues the request and returns; it never calls back.
NIMFFI_RET_OK: exactly one NIMFFI_MSG_REPLY whose `id` is `*req_id_out` will come
out of poll on that context, unless the context closes first. The reply of a
static request arrives on the static context, the reply of the constructor on
the context it hands out in `*ctx_out`.
Anything else: the request was refused and no reply will come. NIMFFI_RET_ERR
(bad argument, undecodable request, context not accepting requests),
NIMFFI_RET_INVALID_CTX, NIMFFI_RET_QUEUE_FULL or NIMFFI_RET_TOO_LARGE; the text
is in last_error(). `req_id_out` must not be NULL. Request ids are never 0.
A reply can be polled before the submitting call has returned: a host that
polls on another thread registers its waiter under a lock held across the call.
When the constructor's reply is NIMFFI_RET_ERR the context still has to be
destroyed; after a refused constructor `*ctx_out` is NULL and nothing does."""

  StaticCtxDoc =
    """The token of the static context, where the replies of the static requests
arrive: poll it like any other context. Never destroy it; shutdown ends it.
NULL on failure, with the text in last_error()."""

  LastErrorDoc =
    """Why the last request of the calling thread was refused. Thread-local, never
NULL, empty when nothing was refused, valid until that thread's next call into
the library. Owned by the library: never free it."""

  PollDoc = """Take the next message of `ctx` out of the library: a reply, an event, a
liveness report or the end of the context. `*msg` is set to a message the library owns, or to NULL.
`timeout_ms` 0 never blocks; a negative value waits until a message arrives or
the context closes.
Returns NIMFFI_RET_OK (`*msg` is set), NIMFFI_RET_TIMEOUT (nothing arrived in
time), NIMFFI_RET_CLOSED (the context was destroyed or recycled; `*msg` is a
NIMFFI_MSG_CLOSED whose ret_code is NIMFFI_RET_OK, or NIMFFI_RET_ERR with UTF-8
text in the payload saying why), NIMFFI_RET_INVALID_CTX (`ctx` is NULL, forged
or already destroyed), NIMFFI_RET_BUSY (another thread is inside poll on this
context) or NIMFFI_RET_ERR (`msg` is NULL).
Lifetime: the message and its payload belong to the library and stay valid until the next
poll on the same context, whatever that poll returns. Never free it, and decode
it before polling again.
Single consumer: one thread at a time polls a context. Any host thread will do;
it needs no setup."""

  PollFdDoc =
    """A handle to wait on instead of blocking in poll, for a host with an event loop
of its own. It is ready while a message waits or the context is closed.
Linux: an epoll fd. macOS/BSD: a kqueue fd. Wait until it is readable with
poll(2), select(2) or the host's own epoll/kqueue; never read from it.
Windows: an Event HANDLE (cast the returned value) that can only be waited on,
with WaitForSingleObject or WaitForMultipleObjects.
Once it is ready, poll with a timeout of 0 until NIMFFI_RET_TIMEOUT.
A stalled FFI thread is only noticed inside poll, so the handle does not become
ready for it: a host that wants NIMFFI_MSG_NOT_RESPONDING also polls about once
a second.
Returns -1 on failure. Each call returns a new handle, which the caller owns
and closes with close(), or CloseHandle on Windows."""

func evSnake(ev: FFIEventMeta): string =
  return camelToSnakeCase(ev.nimProcName)

func evConstName(libName: string, ev: FFIEventMeta): string =
  return libName.toUpperAscii() & "_EVT_" & evSnake(ev).toUpperAscii()

func evDecodeName(libName: string, ev: FFIEventMeta): string =
  return libName & "_decode_" & evSnake(ev)

func wrapperName(libName: string, m: FFIProcMeta): string =
  ## `<lib>_ctx_<name>`, or `<lib>_static_<name>` for a static; `<lib>_<name>`
  ## itself is the raw symbol the dylib exports.
  var prefix = libName & "_ctx_"
  if m.isStatic():
    prefix = libName & "_static_"
  return prefix & stripLibPrefix(m.procName, libName)

func replyDecodeName(libName: string, m: FFIProcMeta): string =
  return libName & "_decode_" & stripLibPrefix(m.procName, libName) & "_reply"

proc emitApiIndex(
    lines: var seq[string],
    ctxType, libType, libName: string,
    classified: ClassifiedProcs,
    events: seq[FFIEventMeta],
) =
  lines.add("/* ============================================================ */")
  lines.add("/* " & alignLeft(libName & " API", 60) & " */")
  lines.add("/* ============================================================ */")
  lines.add(
    "/* The library calls nothing back and the binding starts no thread: a reply,"
  )
  lines.add(
    " * an event or a liveness report reaches the host inside " & libName &
      "_ctx_pump_once(),"
  )
  lines.add(" * on the thread that calls it.")
  lines.add(" *")
  lines.add(
    " * Threads: a context of this binding is single-threaded by design. Submit and"
  )
  lines.add(
    " * pump it from one thread, or hold one lock around both. A host that wants"
  )
  lines.add(
    " * something else uses the raw " & libName & "_<proc>() and " & libName &
      "_poll() exports with the"
  )
  lines.add(" * decoders below.")
  lines.add(" *")
  if classified.ctors.len > 0:
    lines.add(
      " * Context: " & libName & "_ctx_create_sync(), " & libName & "_ctx_create(), " &
        libName & "_ctx_destroy()."
    )
  else:
    lines.add(" * Context: " & libName & "_ctx_destroy().")
  lines.add(" *")
  lines.add(
    " * Requests. Each has an asynchronous form, whose on_reply runs inside the pump;"
  )
  lines.add(" * a _sync form for a sequential program, which pumps until its own reply")
  lines.add(" * arrives; and a decoder of the raw reply:")
  for m in classified.replyProcs():
    let name = wrapperName(libName, m)
    lines.add(
      " *   " & name & "()  " & name & "_sync()  " & replyDecodeName(libName, m) & "()"
    )
  if classified.statics.len > 0:
    lines.add(
      " * The replies of the static requests arrive on the static context: " & libName &
        "_static_pump_once()."
    )
  lines.add(" *")
  lines.add(" * on_reply(ret, reply, err, user_data) runs once, with `ret`:")
  lines.add(" *   NIMFFI_RET_OK      `reply` is set and `err` is NULL")
  lines.add(
    " *   NIMFFI_RET_ERR     the library answered with an error: `err` is its text"
  )
  lines.add(" *   NIMFFI_RET_CLOSED  the context closed before the reply came")
  lines.add(" *   -1                 the reply did not decode: `err` says why")
  lines.add(
    " * Submitting returns NIMFFI_RET_OK; or the code of the library's refusal, with"
  )
  lines.add(
    " * the text in " & libName &
      "_last_error(); or -1 when the binding could not encode the"
  )
  lines.add(
    " * request or is out of memory. After anything but NIMFFI_RET_OK nothing was"
  )
  lines.add(" * recorded and on_reply never runs.")
  lines.add(
    " * A _sync form returns the same codes, and NIMFFI_RET_TIMEOUT when `timeout_ms`"
  )
  lines.add(
    " * passed first (negative waits forever; the late reply is then dropped). On"
  )
  lines.add(
    " * NIMFFI_RET_OK the caller owns `*out`; otherwise `*out` is zeroed and `*err`,"
  )
  lines.add(
    " * when `err` is not NULL, is a text the caller frees with free(). Every other"
  )
  lines.add(" * message that arrives meanwhile goes to `handlers`, which may be NULL.")
  lines.add(" *")
  lines.add(
    " * Messages from the library, each an entry of " & libType &
      "Handlers. A handler may"
  )
  lines.add(" * submit requests, _sync ones included:")
  for ev in events:
    lines.add(
      " *   " & evSnake(ev) & "(const " & ev.payloadTypeName & "*)  " &
        evConstName(libName, ev)
    )
  lines.add(" *   stale_warn, not_responding, responding, closed")
  lines.add(" */")
  lines.add("typedef struct {")
  lines.add("    void* ptr;             /* the library's token, for the raw exports */")
  lines.add("    NimFfiPending pending; /* requests waiting for their reply */")
  lines.add("} " & ctxType & ";")
  lines.add("")

proc emitEventDecoders(
    lines: var seq[string], reg: CTypeReg, libName: string, events: seq[FFIEventMeta]
) =
  ## Per event: the name id constant and a decoder of the bare payload.
  if events.len > 0:
    lines.add("/* ---- events ---- */")
  for ev in events:
    let constName = evConstName(libName, ev)
    let payC = ev.payloadTypeName
    let ownsHeap = freeStmt(reg, payC, "*out").len > 0
    let freeFn = libName & "_free_" & payC
    lines.add(renderBlockDocComment(ev.doc))
    lines.add(
      "#define " & constName & " " & nameIdLiteral(ev.wireName) & "ULL  /* \"" &
        ev.wireName & "\" */"
    )
    lines.add("/* Decodes the payload of a " & constName & " message.")
    lines.add(" * Returns 0, or -1 when `msg` is not that event or does not decode.")
    if ownsHeap:
      lines.add(" * On success the caller frees `out` with " & freeFn & "(). */")
    else:
      lines.add(" * `out` owns no heap memory. */")
    lines.add(
      "static inline int " & evDecodeName(libName, ev) & "(const NimFfiMsg* msg, " & payC &
        "* out) {"
    )
    lines.add("    if (!msg || !out) return -1;")
    lines.add(
      "    if (msg->kind != NIMFFI_MSG_EVENT || msg->name_id != " & constName &
        ") return -1;"
    )
    lines.add("    memset(out, 0, sizeof(*out));")
    lines.add("    CborParser parser;")
    lines.add("    CborValue it;")
    lines.add(
      "    if (cbor_parser_init(msg->payload, msg->len, 0, &parser, &it) != CborNoError) return -1;"
    )
    lines.add("    if (" & decFn(reg, payC) & "(&it, out) != CborNoError) {")
    # Reclaim fields a partial decode allocated (out is zeroed).
    if ownsHeap:
      lines.add("        " & freeFn & "(out);")
    lines.add("        return -1;")
    lines.add("    }")
    lines.add("    return 0;")
    lines.add("}")
    lines.add("")

func fillLibTpl(tpl, ctxType, libType, libName: string): string =
  return tpl.strip(leading = false).multiReplace(
      ("{{LIB}}", libName), ("{{CTX}}", ctxType), ("{{HANDLERS}}", libType & "Handlers")
    )

proc emitHandlers(
    lines: var seq[string],
    reg: CTypeReg,
    ctxType, libType, libName: string,
    events: seq[FFIEventMeta],
    hasStatics: bool,
) =
  ## The one place that lists everything the library sends, and the pump over it.
  let handlersType = libType & "Handlers"
  lines.add("/* ---- everything the library can send ---- */")
  lines.add(
    "/* Replies go to the on_reply of their request; the rest is listed here. A NULL"
  )
  lines.add(
    " * entry means \"ignore\". Each handler runs on the thread that pumps; what it is"
  )
  lines.add(" * handed belongs to the binding and is valid only until it returns. */")
  lines.add("typedef struct {")
  for ev in events:
    lines.add(renderBlockDocComment(ev.doc, "    "))
    lines.add(
      "    void (*" & evSnake(ev) & ")(const " & ev.payloadTypeName &
        "* ev, void* user_data);"
    )
  lines.add(
    "    /* Request `req_id` is still running after `elapsed_ms`; its reply still comes. */"
  )
  lines.add(
    "    void (*stale_warn)(uint64_t req_id, uint64_t elapsed_ms, void* user_data);"
  )
  lines.add(
    "    /* `reason` is a NIMFFI_NOT_RESPONDING_*: the FFI thread stalled, or the event"
  )
  lines.add("     * queue overflowed and requests are refused from now on. */")
  lines.add("    void (*not_responding)(uint64_t reason, void* user_data);")
  lines.add("    /* The FFI thread's heartbeat resumed. */")
  lines.add("    void (*responding)(void* user_data);")
  lines.add(
    "    /* The context is gone. `ret` is NIMFFI_RET_OK, or NIMFFI_RET_ERR with `reason`"
  )
  lines.add(
    "     * (a NUL-terminated copy, NULL when none) saying why it was quarantined. Runs"
  )
  lines.add(
    "     * after every request still waiting was settled with NIMFFI_RET_CLOSED. */"
  )
  lines.add("    void (*closed)(int ret, const char* reason, void* user_data);")
  lines.add("    void* user_data;")
  lines.add("} " & handlersType & ";")
  lines.add("")

  lines.add(
    "/* Decodes `msg` fully, then calls its on_reply or its handler, then frees what"
  )
  lines.add(
    " * it decoded. Returns 0, also for an event this header does not know and for a"
  )
  lines.add(
    " * reply nobody waits for, or -1 on a decode error or an unknown message kind. */"
  )
  lines.add(
    "static inline int " & libName & "_ctx_dispatch(" & ctxType &
      "* ctx, const NimFfiMsg* msg, const " & handlersType & "* handlers) {"
  )
  lines.add("    if (!ctx || !msg) return -1;")
  lines.add("    switch (msg->kind) {")
  lines.add("    case NIMFFI_MSG_REPLY: {")
  lines.add("        NimFfiPendingEntry entry;")
  lines.add(
    "        /* Nobody waits: given up on by a _sync timeout, or sent through the raw export. */"
  )
  lines.add(
    "        if (!nimffi_pending_take(&ctx->pending, msg->id, &entry)) return 0;"
  )
  lines.add("        entry.settle(msg, entry.on_reply, entry.user_data);")
  lines.add("        return 0;")
  lines.add("    }")
  lines.add("    case NIMFFI_MSG_STALE_WARN:")
  lines.add(
    "        if (handlers && handlers->stale_warn) handlers->stale_warn(msg->id, msg->aux, handlers->user_data);"
  )
  lines.add("        return 0;")
  lines.add("    case NIMFFI_MSG_EVENT:")
  for ev in events:
    let payC = ev.payloadTypeName
    let payFree = freeStmt(reg, payC, "ev")
    lines.add("        if (msg->name_id == " & evConstName(libName, ev) & ") {")
    lines.add("            " & payC & " ev;")
    lines.add(
      "            if (" & evDecodeName(libName, ev) & "(msg, &ev) != 0) return -1;"
    )
    lines.add(
      "            if (handlers && handlers->" & evSnake(ev) & ") handlers->" &
        evSnake(ev) & "(&ev, handlers->user_data);"
    )
    if payFree.len > 0:
      lines.add("            " & payFree)
    lines.add("            return 0;")
    lines.add("        }")
  lines.add("        return 0;")
  lines.add("    case NIMFFI_MSG_NOT_RESPONDING:")
  lines.add(
    "        if (handlers && handlers->not_responding) handlers->not_responding(msg->aux, handlers->user_data);"
  )
  lines.add("        return 0;")
  lines.add("    case NIMFFI_MSG_RESPONDING:")
  lines.add(
    "        if (handlers && handlers->responding) handlers->responding(handlers->user_data);"
  )
  lines.add("        return 0;")
  lines.add("    case NIMFFI_MSG_CLOSED: {")
  lines.add(
    "        /* Copied first: a callback below may poll, which ends the life of `msg`. */"
  )
  lines.add("        int ret = (int)msg->ret_code;")
  lines.add("        char* reason = NULL;")
  lines.add(
    "        if (msg->len > 0) reason = nimffi_dup_cstr_n((const char*)msg->payload, msg->len);"
  )
  lines.add("        nimffi_pending_close(&ctx->pending);")
  lines.add(
    "        if (handlers && handlers->closed) handlers->closed(ret, reason, handlers->user_data);"
  )
  lines.add("        free(reason);")
  lines.add("        return 0;")
  lines.add("    }")
  lines.add("    default:")
  lines.add("        return -1;")
  lines.add("    }")
  lines.add("}")
  lines.add("")

  lines.add("/* One " & libName & "_poll() and the dispatch of what it returned.")
  lines.add(
    " * Returns the poll code (NIMFFI_RET_OK, _TIMEOUT, _CLOSED after the `closed`"
  )
  lines.add(
    " * handler ran, _INVALID_CTX, _BUSY, _ERR), or -1 when the message did not"
  )
  lines.add(
    " * dispatch. `ctx` must stay alive for the whole call: stop pumping before"
  )
  lines.add(" * " & libName & "_ctx_destroy(). */")
  lines.add(
    "static inline int " & libName & "_ctx_pump_once(" & ctxType &
      "* ctx, int32_t timeout_ms, const " & handlersType & "* handlers) {"
  )
  lines.add("    if (!ctx) return NIMFFI_RET_INVALID_CTX;")
  lines.add("    const NimFfiMsg* msg = NULL;")
  lines.add("    int rc = " & libName & "_poll(ctx->ptr, timeout_ms, &msg);")
  lines.add("    if (rc != NIMFFI_RET_OK && rc != NIMFFI_RET_CLOSED) return rc;")
  lines.add("    if (" & libName & "_ctx_dispatch(ctx, msg, handlers) != 0) return -1;")
  lines.add("    return rc;")
  lines.add("}")
  lines.add("")
  lines.add(
    "/* See " & libName & "_poll_fd(): the caller owns and closes the handle. */"
  )
  lines.add(
    "static inline intptr_t " & libName & "_ctx_poll_fd(const " & ctxType & "* ctx) {"
  )
  lines.add("    if (!ctx) return -1;")
  lines.add("    return " & libName & "_poll_fd(ctx->ptr);")
  lines.add("}")
  lines.add("")
  lines.add(fillLibTpl(CtxAwaitTpl, ctxType, libType, libName))
  lines.add("")
  if hasStatics:
    lines.add(fillLibTpl(StaticCtxTpl, ctxType, libType, libName))
    lines.add("")

const RoomCond = "nimffi_pending_reserve(&ctx->pending) != 0"

const SettleParams = "(const NimFfiMsg* msg, nimffi_generic_fn fn, void* user_data) {"

proc emitSubmit(
    lines: var seq[string],
    libName, head, reqName: string,
    prologue, assigns: seq[string],
    target, roomCond, rawCall: string,
    onRefused: seq[string],
) =
  ## `<x>_submit_`: encode, make room, call the raw export, record who waits.
  ## Room is made before the call so that an accepted request is never lost.
  lines.add(
    head &
      "nimffi_settle_fn settle, nimffi_generic_fn fn, void* user_data, uint64_t* req_id_out, char** err) {"
  )
  for l in prologue:
    lines.add(l)
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
  if target.len > 0:
    lines.add(target)
  lines.add("    if (" & roomCond & ") {")
  lines.add("        free(req_buf);")
  for l in onRefused:
    lines.add("    " & l)
  lines.add("        if (err) *err = nimffi_dup_cstr(\"out of memory\");")
  lines.add("        return -1;")
  lines.add("    }")
  lines.add("    int rc = " & rawCall & ";")
  lines.add("    free(req_buf);")
  lines.add("    if (rc != NIMFFI_RET_OK) {")
  lines.add("        if (err) *err = nimffi_dup_cstr(" & libName & "_last_error());")
  for l in onRefused:
    lines.add("    " & l)
  lines.add("        return rc;")
  lines.add("    }")
  lines.add("    NimFfiPendingEntry entry = {*req_id_out, settle, fn, user_data};")
  lines.add("    nimffi_pending_add(&ctx->pending, entry);")

proc emitConstructors(
    lines: var seq[string],
    reg: var CTypeReg,
    ctxType, libType, libName: string,
    ctors: seq[FFIProcMeta],
) =
  if ctors.len == 0:
    return
  let fnType = libType & "CreateFn"
  let settle = libName & "_create_settle_"
  let settleSync = libName & "_create_settle_sync_"
  lines.add(
    "/* `ret` as for a request's on_reply. The context is the caller's whatever `ret`"
  )
  lines.add(" * says: release it with " & libName & "_ctx_destroy(). */")
  lines.add(
    "typedef void (*" & fnType & ")(int ret, const char* err, void* user_data);"
  )
  lines.add("static inline void " & settle & SettleParams)
  lines.add("    " & fnType & " on_created = (" & fnType & ")fn;")
  lines.add("    if (!on_created) return;")
  lines.add("    if (!msg) {")
  lines.add("        on_created(NIMFFI_RET_CLOSED, \"context closed\", user_data);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    char* err = NULL;")
  lines.add("    int rc = nimffi_reply_status(msg, &err);")
  lines.add("    const char* text = NULL;")
  lines.add("    if (rc != NIMFFI_RET_OK) text = err ? err : \"\";")
  lines.add("    on_created(rc, text, user_data);")
  lines.add("    free(err);")
  lines.add("}")
  lines.add("static inline void " & settleSync & SettleParams)
  lines.add("    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;")
  lines.add("    (void)fn;")
  lines.add("    if (!msg) {")
  lines.add("        nimffi_sync_slot_closed(slot);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    slot->ret = nimffi_reply_status(msg, slot->err);")
  lines.add("    slot->done = true;")
  lines.add("}")
  for ctor in ctors:
    let reqName = reqStructName(ctor)
    let (params, assigns) = buildReqParams(reg, ctor.extraParams)
    var paramList = ""
    var argList = ""
    if params.len > 0:
      paramList = params.join(", ") & ", "
    for ep in ctor.extraParams:
      argList.add(ep.name & ", ")
    let submit = libName & "_create_submit_"

    emitSubmit(
      lines,
      libName,
      "static inline int " & submit & "(" & paramList & ctxType & "** ctx_out, ",
      reqName,
      @[],
      assigns,
      "    " & ctxType & "* ctx = (" & ctxType & "*)calloc(1, sizeof(" & ctxType & "));",
      "!ctx || " & RoomCond,
      ctor.procName & "(req_buf, req_len, &ctx->ptr, req_id_out)",
      @["    if (ctx) free(ctx->pending.items);", "    free(ctx);"],
    )
    lines.add("    *ctx_out = ctx;")
    lines.add("    return NIMFFI_RET_OK;")
    lines.add("}")

    lines.add(renderBlockDocComment(ctor.doc))
    lines.add(
      "static inline int " & libName & "_ctx_create(" & paramList & ctxType &
        "** ctx_out, " & fnType & " on_created, void* user_data) {"
    )
    lines.add("    if (!ctx_out) return -1;")
    lines.add("    *ctx_out = NULL;")
    lines.add("    uint64_t req_id = 0;")
    lines.add(
      "    return " & submit & "(" & argList & "ctx_out, " & settle &
        ", (nimffi_generic_fn)on_created, user_data, &req_id, NULL);"
    )
    lines.add("}")

    lines.add(renderBlockDocComment(ctor.doc))
    lines.add(
      "static inline int " & libName & "_ctx_create_sync(" & paramList & ctxType &
        "** out, char** err, int32_t timeout_ms) {"
    )
    lines.add("    if (err) *err = NULL;")
    lines.add("    if (!out) return -1;")
    lines.add("    *out = NULL;")
    lines.add("    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, NULL, err};")
    lines.add("    " & ctxType & "* ctx = NULL;")
    lines.add("    uint64_t req_id = 0;")
    lines.add(
      "    int rc = " & submit & "(" & argList & "&ctx, " & settleSync &
        ", NULL, &slot, &req_id, err);"
    )
    lines.add("    if (rc != NIMFFI_RET_OK) return rc;")
    lines.add(
      "    rc = " & libName & "_ctx_await_(ctx, req_id, &slot, timeout_ms, NULL);"
    )
    lines.add("    if (rc != NIMFFI_RET_OK) {")
    lines.add("        /* The slot is claimed even when construction failed. */")
    lines.add("        (void)" & libName & "_ctx_destroy(ctx);")
    lines.add("        return rc;")
    lines.add("    }")
    lines.add("    *out = ctx;")
    lines.add("    return NIMFFI_RET_OK;")
    lines.add("}")
    lines.add("")

proc emitDestructor(
    lines: var seq[string], ctxType, libName: string, dtor: Option[FFIProcMeta]
) =
  lines.add("/* ---- context ---- */")
  lines.add(
    "/* Requests still waiting are settled with NIMFFI_RET_CLOSED, after the library"
  )
  lines.add(
    " * let go of the context. Never call it from a handler or an on_reply of `ctx`. */"
  )
  if dtor.isSome():
    lines.add(renderBlockDocComment(dtor.get().doc))
  lines.add("static inline int " & libName & "_ctx_destroy(" & ctxType & "* ctx) {")
  lines.add("    if (!ctx) return NIMFFI_RET_OK;")
  lines.add("    int rc = NIMFFI_RET_OK;")
  if dtor.isSome():
    lines.add(
      "    if (ctx->ptr) { rc = " & dtor.get().procName &
        "(ctx->ptr); ctx->ptr = NULL; }"
    )
  lines.add("    nimffi_pending_close(&ctx->pending);")
  lines.add(
    "    /* A callback above may have made room for a request that was refused. */"
  )
  lines.add("    free(ctx->pending.items);")
  lines.add("    free(ctx);")
  lines.add("    return rc;")
  lines.add("}")
  lines.add("")

proc emitProcWrapper(
    lines: var seq[string],
    reg: var CTypeReg,
    ctxType, libType, libName: string,
    m: FFIProcMeta,
) =
  ## Per request: the reply callback type, the raw reply decoder, and the
  ## asynchronous and `_sync` wrappers over one internal submit.
  let isStatic = m.isStatic()
  let stripped = stripLibPrefix(m.procName, libName)
  let reqName = reqStructName(m)
  let retC = cReturnType(reg, m)
  let (params, assigns) = buildReqParams(reg, m.extraParams)
  let fnType = libType & snakeToPascalCase(stripped) & "ReplyFn"
  let decode = replyDecodeName(libName, m)
  let settle = libName & "_" & stripped & "_settle_"
  let settleSync = libName & "_" & stripped & "_settle_sync_"
  let submit = libName & "_" & stripped & "_submit_"
  let wrapper = wrapperName(libName, m)

  var paramList = ""
  if params.len > 0:
    paramList = params.join(", ") & ", "
  var argList = ""
  var ctxParam = ""
  var target = "    " & ctxType & "* ctx = " & libName & "_static_();"
  var prologue: seq[string] = @[]
  var rawCall = m.procName & "(req_buf, req_len, req_id_out)"
  if not isStatic:
    argList = "ctx, "
    ctxParam = ctxType & "* ctx, "
    target = ""
    prologue = @[
      "    if (!ctx) {", "        if (err) *err = nimffi_dup_cstr(\"ctx is NULL\");",
      "        return NIMFFI_RET_INVALID_CTX;", "    }",
    ]
    rawCall = m.procName & "(ctx->ptr, req_buf, req_len, req_id_out)"
  for ep in m.extraParams:
    argList.add(ep.name & ", ")

  lines.add(
    "typedef void (*" & fnType & ")(int ret, " & byPtrConst(retC) &
      " reply, const char* err, void* user_data);"
  )

  var freeOut = freeStmt(reg, retC, "*out")
  if freeOut.len > 0 and leafSuffix(retC).len == 0:
    freeOut = libName & "_free_" & retC & "(out);"
  lines.add(
    "/* Decodes the NIMFFI_MSG_REPLY that answers " & m.procName &
      "(); the caller matches"
  )
  lines.add(
    " * `msg->id` against the request id first. Returns NIMFFI_RET_OK; NIMFFI_RET_ERR"
  )
  lines.add(
    " * with the library's error text in `*err`; or -1 when `msg` is not a reply or"
  )
  lines.add(" * does not decode, `*err` saying why. `*err` is freed with free().")
  if retC == CStrType:
    lines.add(" * On success the caller frees `*out` with free(). */")
  elif freeOut.len > 0:
    lines.add(
      " * On success the caller frees `out` with " & libName & "_free_" & retC & "(). */"
    )
  else:
    lines.add(" * `out` owns no heap memory. */")
  lines.add(
    "static inline int " & decode & "(const NimFfiMsg* msg, " & retC &
      "* out, char** err) {"
  )
  lines.add("    if (out) memset(out, 0, sizeof(*out));")
  lines.add(
    "    int rc = nimffi_decode_reply(msg, " & libName & "_decv_" & cToken(retC) &
      ", out, err);"
  )
  # Reclaim fields a partial decode allocated (out is zeroed).
  if freeOut.len > 0:
    lines.add("    if (rc == -1 && out) " & freeOut)
  lines.add("    return rc;")
  lines.add("}")

  let freeLocal = freeStmt(reg, retC, "out")
  lines.add("static inline void " & settle & SettleParams)
  lines.add("    " & fnType & " on_reply = (" & fnType & ")fn;")
  lines.add("    if (!on_reply) return;")
  lines.add("    if (!msg) {")
  lines.add("        on_reply(NIMFFI_RET_CLOSED, NULL, \"context closed\", user_data);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    " & retC & " out;")
  lines.add("    char* err = NULL;")
  lines.add("    int rc = " & decode & "(msg, &out, &err);")
  lines.add("    if (rc != NIMFFI_RET_OK) {")
  lines.add("        on_reply(rc, NULL, err ? err : \"\", user_data);")
  lines.add("        free(err);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    on_reply(NIMFFI_RET_OK, &out, NULL, user_data);")
  if freeLocal.len > 0:
    lines.add("    " & freeLocal)
  lines.add("}")

  lines.add("static inline void " & settleSync & SettleParams)
  lines.add("    NimFfiSyncSlot* slot = (NimFfiSyncSlot*)user_data;")
  lines.add("    (void)fn;")
  lines.add("    if (!msg) {")
  lines.add("        nimffi_sync_slot_closed(slot);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    slot->ret = " & decode & "(msg, (" & retC & "*)slot->out, slot->err);")
  lines.add("    slot->done = true;")
  lines.add("}")

  emitSubmit(
    lines,
    libName,
    "static inline int " & submit & "(" & ctxParam & paramList,
    reqName,
    prologue,
    assigns,
    target,
    RoomCond,
    rawCall,
    @[],
  )
  lines.add("    return NIMFFI_RET_OK;")
  lines.add("}")

  lines.add(renderBlockDocComment(m.doc))
  lines.add(
    "static inline int " & wrapper & "(" & ctxParam & paramList & fnType &
      " on_reply, void* user_data, uint64_t* req_id_out) {"
  )
  # The id the reply and any stale warning carry; NULL when the caller does not
  # need to match a warning to this call.
  lines.add("    uint64_t req_id = 0;")
  lines.add("    if (req_id_out) *req_id_out = 0;")
  lines.add(
    "    const int rc_ = " & submit & "(" & argList & settle &
      ", (nimffi_generic_fn)on_reply, user_data, &req_id, NULL);"
  )
  lines.add("    if (rc_ == NIMFFI_RET_OK && req_id_out) *req_id_out = req_id;")
  lines.add("    return rc_;")
  lines.add("}")

  lines.add(renderBlockDocComment(m.doc))
  lines.add(
    "static inline int " & wrapper & "_sync(" & ctxParam & paramList & retC &
      "* out, char** err, int32_t timeout_ms, const " & libType & "Handlers* handlers) {"
  )
  lines.add("    if (err) *err = NULL;")
  lines.add("    if (!out) return -1;")
  lines.add("    memset(out, 0, sizeof(*out));")
  lines.add("    NimFfiSyncSlot slot = {false, NIMFFI_RET_OK, out, err};")
  lines.add("    uint64_t req_id = 0;")
  lines.add(
    "    int rc = " & submit & "(" & argList & settleSync &
      ", NULL, &slot, &req_id, err);"
  )
  lines.add("    if (rc != NIMFFI_RET_OK) return rc;")
  var awaitCtx = "ctx"
  if isStatic:
    awaitCtx = libName & "_static_()"
  lines.add(
    "    return " & libName & "_ctx_await_(" & awaitCtx &
      ", req_id, &slot, timeout_ms, handlers);"
  )
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
  return reg

proc monomorphiseAll(
    reg: var CTypeReg,
    types: seq[FFITypeMeta],
    procs, replyProcs: seq[FFIProcMeta],
    events: seq[FFIEventMeta],
): tuple[reqTypes, respTypes: seq[string]] =
  ## Runs every type, Req, return type and event payload through ensureCType,
  ## returning the Req and response C type names the buffer adapters need.
  for t in types:
    discard ensureCType(reg, t.name)
  var reqTypes: seq[string] = @[]
  for p in procs:
    if p.kind != FFIKind.DTOR:
      let n = reqStructName(p)
      discard ensureCType(reg, n)
      reqTypes.add(n)
  var respTypes: seq[string] = @[]
  for p in replyProcs:
    respTypes.add(cReturnType(reg, p))
  for ev in events:
    discard ensureCType(reg, ev.payloadTypeName)
  return (reqTypes, respTypes)

func constDeclLines(consts: seq[FFIConstMeta]): seq[string] =
  ## `{.ffiConst.}` values as typed `static const` definitions.
  if consts.len == 0:
    return @[]
  var lines = @[
    "/* ============================================================ */",
    "/* Generated constants                                          */",
    "/* ============================================================ */", "",
  ]
  for c in consts:
    let t = parseFFIType(c.typeName)
    let name = identToUpperSnake(c.name)
    let value = cConstValue(t, c.value)
    case t.kind
    of ftStr:
      lines.add("static const char* const " & name & " = " & value & ";")
    of ftScalar:
      lines.add(
        "static const " & scalarCInfoTable[t.scalar].cType & " " & name & " = " & value &
          ";"
      )
    else:
      discard
  lines.add("")
  return lines

func generateCPreludeHeader*(): string =
  ## The library-agnostic `nim_ffi_prelude.h`.
  return HeaderPreludeTpl.replace("{{MSG_DECL}}", cMsgDecl()) & "\n"

func generateCCborHeader*(): string =
  ## The library-agnostic `nim_ffi_cbor.h`.
  return CborHelpersTpl.replace("{{RET_CODES}}", cRetCodeDefines()) & "\n"

proc generateCLibHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
    consts: seq[FFIConstMeta] = @[],
): string =
  ## The `<lib>.h` header: library structs, monomorphised codecs and async API.
  let classified = classifyProcs(procs)
  let ctors = classified.ctors
  let libType = libTypeName(ctors, libName)
  let ctxType = libType & "Ctx"

  var reg = newCTypeReg(libName, libType, types, procs)
  let (reqTypes, respTypes) =
    monomorphiseAll(reg, types, procs, classified.replyProcs(), events)

  let guard = "NIM_FFI_LIB_" & libName.toUpperAscii() & "_H_INCLUDED"
  var lines: seq[string] = @[]
  lines.add("#ifndef " & guard)
  lines.add("#define " & guard)
  lines.add("#include \"" & CborHeaderName & "\"")
  lines.add("")

  lines.add(constDeclLines(consts))

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
  # A plain comment: a doc comment would attach to the first declaration.
  lines.add("/*" & renderBlockDocComment(RequestDoc)[3 .. ^1])
  lines.add("")
  for p in procs:
    lines.add(renderBlockDocComment(p.doc))
    const ReqArgs = "const uint8_t* req_cbor, size_t req_cbor_len, "
    case p.kind
    of FFIKind.FFI:
      lines.add(
        "int " & p.procName & "(void* ctx, " & ReqArgs & "uint64_t* req_id_out);"
      )
    of FFIKind.STATIC:
      lines.add("int " & p.procName & "(" & ReqArgs & "uint64_t* req_id_out);")
    of FFIKind.CTOR:
      lines.add(
        "int " & p.procName & "(" & ReqArgs & "void** ctx_out, uint64_t* req_id_out);"
      )
    of FFIKind.DTOR:
      lines.add("int " & p.procName & "(void* ctx);")
  lines.add(renderBlockDocComment(StaticCtxDoc))
  lines.add("void* " & libName & "_static_ctx(void);")
  lines.add(renderBlockDocComment(LastErrorDoc))
  lines.add("const char* " & libName & "_last_error(void);")
  lines.add(renderBlockDocComment(PollDoc))
  lines.add(
    "int " & libName & "_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);"
  )
  lines.add(renderBlockDocComment(PollFdDoc))
  lines.add("intptr_t " & libName & "_poll_fd(void* ctx);")
  lines.add(renderBlockDocComment(ShutdownDoc))
  lines.add("int " & libName & "_shutdown(void);")
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
  for n in respTypes:
    let tok = cToken(n)
    if ("dec" & tok) notin adaptersDone:
      adaptersDone.incl("dec" & tok)
      lines.add(
        "static inline CborError " & libName & "_decv_" & tok &
          "(CborValue* it, void* v) { return " & decFn(reg, n) & "(it, (" & n & "*)v); }"
      )
  lines.add("")

  emitApiIndex(lines, ctxType, libType, libName, classified, events)
  emitEventDecoders(lines, reg, libName, events)
  emitHandlers(
    lines, reg, ctxType, libType, libName, events, classified.statics.len > 0
  )
  emitDestructor(lines, ctxType, libName, classified.dtor)
  emitConstructors(lines, reg, ctxType, libType, libName, ctors)
  if classified.replyProcs().len > 0:
    lines.add("/* ---- requests ---- */")
  for m in classified.replyProcs():
    emitProcWrapper(lines, reg, ctxType, libType, libName, m)

  lines.add("#endif /* " & guard & " */")
  return lines.join("\n") & "\n"

proc generateCCMakeLists*(libName, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  return CMakeListsTpl.multiReplace(
    ("{{LIB}}", libName),
    ("{{SRC}}", src),
    ("{{FIND_REPO_ROOT}}", FindRepoRootTpl.strip(leading = false)),
  )

proc generateCBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
    consts: seq[FFIConstMeta] = @[],
) =
  ## Emits the C binding for `libName`.
  ensureOutputDir(outputDir)
  writeOutputFile(buildPath(outputDir, PreludeHeaderName), generateCPreludeHeader())
  writeOutputFile(buildPath(outputDir, CborHeaderName), generateCCborHeader())
  writeOutputFile(
    buildPath(outputDir, libName & ".h"),
    generateCLibHeader(procs, types, libName, events, consts),
  )
  writeOutputFile(
    buildPath(outputDir, "CMakeLists.txt"), generateCCMakeLists(libName, nimSrcRelPath)
  )
