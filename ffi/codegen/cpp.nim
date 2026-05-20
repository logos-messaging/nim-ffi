## C++ binding generator for the nim-ffi framework.
## Generates a header-only C++ binding and CMakeLists.txt. Requests/responses
## travel as CBOR (encoded with vendored TinyCBOR on the C++ side, matching
## the Nim-side cbor_serial codec on the wire — both ends speak RFC 8949).

import std/[os, strutils]
import ./meta, ./string_helpers

## Wire-format C++ type used for any Nim `ptr T` / `pointer`. Fixed 64-bit so
## the CBOR payload size is stable regardless of host architecture.
const CppPtrType* = "uint64_t"

## Static template blocks live as real C++ / CMake files under templates/cpp/
## and are slurped into the binary at compile time. Edits to those files are
## reflected in the generated bindings without touching this codegen.
const
  HeaderPreludeTpl = staticRead("templates/cpp/header_prelude.hpp.tpl")
  CborHelpersTpl = staticRead("templates/cpp/cbor_helpers.hpp.tpl")
  SyncCallHelperTpl = staticRead("templates/cpp/sync_call_helper.hpp.tpl")
  ContextRuleOf5Tpl = staticRead("templates/cpp/context_rule_of_5.hpp.tpl")
  CMakeListsTpl = staticRead("templates/cpp/CMakeLists.txt.tpl")

proc genericInnerType(typeName, prefix: string): string =
  if typeName.startsWith(prefix) and typeName.endsWith("]"):
    let start = prefix.len
    let lastIndex = typeName.len - 2
    return typeName[start .. lastIndex]
  return ""

proc nimTypeToCpp*(typeName: string): string =
  let trimmed = typeName.strip()
  if trimmed.startsWith("ptr "):
    return CppPtrType
  else:
    let seqInner = genericInnerType(trimmed, "seq[")
    if seqInner.len > 0:
      return "std::vector<" & nimTypeToCpp(seqInner) & ">"
    let optionInner = genericInnerType(trimmed, "Option[")
    if optionInner.len > 0:
      return "std::optional<" & nimTypeToCpp(optionInner) & ">"
    let maybeInner = genericInnerType(trimmed, "Maybe[")
    if maybeInner.len > 0:
      return "std::optional<" & nimTypeToCpp(maybeInner) & ">"
  case trimmed
  of "string", "cstring": "std::string"
  of "int", "int64": "int64_t"
  of "int32": "int32_t"
  of "uint", "uint64": "uint64_t"
  of "uint32": "uint32_t"
  of "uint16": "uint16_t"
  of "uint8", "byte": "uint8_t"
  of "bool": "bool"
  of "float": "float"
  of "float64": "double"
  of "pointer": CppPtrType
  else: trimmed

proc stripLibPrefixCpp(procName, libName: string): string =
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc reqStructName(p: FFIProcMeta): string =
  let camel = snakeToPascalCase(p.procName)
  if p.kind == FFIKind.CTOR:
    camel & "CtorReq"
  else:
    camel & "Req"

proc emitStructCborCodec(
    lines: var seq[string], structName: string, fields: seq[(string, string)]
) =
  ## Appends per-struct TinyCBOR encode_cbor + decode_cbor free functions for
  ## `structName`. `fields` is a sequence of (field-name, ignored C++ type)
  ## pairs — the type is unused at the codec layer because the generic
  ## encode_cbor / decode_cbor overloads in cbor_helpers.hpp.tpl dispatch on
  ## the struct member's type. We emit a CBOR map with text-string keys to
  ## match the wire format produced by Nim's cbor_serialization.
  let n = fields.len
  # ── encode ────────────────────────────────────────────────────────────────
  if n == 0:
    lines.add(
      "inline CborError encode_cbor(CborEncoder& e, const $1&) {" % [structName]
    )
  else:
    lines.add(
      "inline CborError encode_cbor(CborEncoder& e, const $1& v) {" % [structName]
    )
  lines.add("    CborEncoder m;")
  lines.add("    CborError err = cbor_encoder_create_map(&e, &m, $1);" % [$n])
  lines.add("    if (err) return err;")
  for (name, _) in fields:
    lines.add(
      "    err = cbor_encode_text_stringz(&m, \"$1\"); if (err) return err;" % [name]
    )
    lines.add(
      "    err = encode_cbor(m, v.$1);              if (err) return err;" % [name]
    )
  lines.add("    return cbor_encoder_close_container(&e, &m);")
  lines.add("}")
  # ── decode ────────────────────────────────────────────────────────────────
  if n == 0:
    lines.add("inline CborError decode_cbor(CborValue& it, $1&) {" % [structName])
    lines.add("    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;")
    lines.add("    return cbor_value_advance(&it);")
    lines.add("}")
    return
  lines.add("inline CborError decode_cbor(CborValue& it, $1& v) {" % [structName])
  lines.add("    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;")
  lines.add("    CborValue field;")
  lines.add("    CborError err;")
  for (name, _) in fields:
    lines.add(
      "    err = cbor_value_map_find_value(&it, \"$1\", &field); if (err) return err;" %
        [name]
    )
    lines.add("    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;")
    lines.add("    err = decode_cbor(field, v.$1); if (err) return err;" % [name])
  lines.add("    return cbor_value_advance(&it);")
  lines.add("}")

proc cppBracedInit(structName: string, fieldNames: seq[string]): string =
  ## Produces a C++ braced-init expression for a per-proc Req struct.
  ## Used to construct the request value before CBOR-encoding it for the wire,
  ## as in `const auto req = TimerEchoReq{message, count};` in the generated
  ## header. The field order must match the struct's declaration order, which
  ## in turn mirrors the user's Nim FFI signature.
  ##
  ## Examples:
  ##   cppBracedInit("TimerEchoReq", @["message", "count"])
  ##     → "TimerEchoReq{message, count}"
  ##   cppBracedInit("TimerVersionReq", @[])
  ##     → "TimerVersionReq{}"
  ##   cppBracedInit("TimerCreateCtorReq", @["config"])
  ##     → "TimerCreateCtorReq{config}"
  ##
  ## Empty `fieldNames` collapses cleanly because `join` on an empty seq
  ## returns "", so the result is the well-formed empty-init `Name{}`.
  return structName & "{" & fieldNames.join(", ") & "}"

proc generateCppHeader*(
    procs: seq[FFIProcMeta], types: seq[FFITypeMeta], libName: string
): string =
  var lines: seq[string] = @[]

  lines.add(HeaderPreludeTpl)

  # CBOR primitive / container helpers must precede the per-struct codecs
  # below, because each emitted `encode_cbor`/`decode_cbor(T)` calls the
  # generic overloads for the struct's fields (std::string, std::vector,
  # std::optional, primitives). The struct codecs are non-template `inline`
  # functions, so name lookup happens at parse time — the overloads must be
  # in scope before the struct codecs are parsed.
  lines.add(CborHelpersTpl)

  # ── Types ──────────────────────────────────────────────────────────────────
  if types.len > 0:
    lines.add("// ============================================================")
    lines.add("// User-declared FFI types")
    lines.add("// ============================================================")
    lines.add("")
    for t in types:
      lines.add("struct $1 {" % [t.name])
      for f in t.fields:
        lines.add("    $1 $2;" % [nimTypeToCpp(f.typeName), f.name])
      lines.add("};")
      var fields: seq[(string, string)] = @[]
      for f in t.fields:
        fields.add((f.name, nimTypeToCpp(f.typeName)))
      emitStructCborCodec(lines, t.name, fields)
      lines.add("")

  # ── Per-proc Req structs (CBOR transport units) ───────────────────────────
  lines.add("// ============================================================")
  lines.add("// Per-proc request envelopes (CBOR encoded on the wire)")
  lines.add("// ============================================================")
  lines.add("")
  for p in procs:
    if p.kind == FFIKind.DTOR:
      continue
    let reqName = reqStructName(p)
    lines.add("struct $1 {" % [reqName])
    for ep in p.extraParams:
      let cppType =
        if ep.isPtr:
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      lines.add("    $1 $2;" % [cppType, ep.name])
    lines.add("};")
    var fields: seq[(string, string)] = @[]
    for ep in p.extraParams:
      let cppType =
        if ep.isPtr:
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      fields.add((ep.name, cppType))
    emitStructCborCodec(lines, reqName, fields)
    lines.add("")

  # ── C FFI declarations ─────────────────────────────────────────────────────
  lines.add("// ============================================================")
  lines.add("// C FFI declarations")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("extern \"C\" {")
  lines.add(
    "typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);"
  )
  lines.add("")
  for p in procs:
    case p.kind
    of FFIKind.FFI:
      lines.add(
        "int $1(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);" %
          [p.procName]
      )
    of FFIKind.CTOR:
      lines.add(
        "void* $1(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);" %
          [p.procName]
      )
    of FFIKind.DTOR:
      lines.add("int $1(void* ctx);" % [p.procName])
  lines.add("} // extern \"C\"")
  lines.add("")

  lines.add(SyncCallHelperTpl)

  # ── High-level C++ context class ──────────────────────────────────────────
  var ctors: seq[FFIProcMeta] = @[]
  var methods: seq[FFIProcMeta] = @[]
  for p in procs:
    case p.kind
    of FFIKind.CTOR:
      ctors.add(p)
    of FFIKind.FFI:
      methods.add(p)
    of FFIKind.DTOR:
      discard

  let libTypeName =
    if ctors.len > 0:
      ctors[0].libTypeName
    else:
      capitalizeFirstLetter(libName)

  let ctxTypeName = libTypeName & "Ctx"

  lines.add("// ============================================================")
  lines.add("// High-level C++ context class")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("class $1 {" % [ctxTypeName])
  lines.add("public:")

  # ── Constructors ────────────────────────────────────────────────────────
  for ctor in ctors:
    let reqName = reqStructName(ctor)
    var ctorParams: seq[string] = @[]
    var epNames: seq[string] = @[]
    for ep in ctor.extraParams:
      let cppType =
        if ep.isPtr:
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      ctorParams.add("const $1& $2" % [cppType, ep.name])
      epNames.add(ep.name)
    let timeoutParam = "std::chrono::milliseconds timeout = std::chrono::seconds{30}"
    let ctorParamsWithTimeout =
      if ctorParams.len > 0:
        ctorParams.join(", ") & ", " & timeoutParam
      else:
        timeoutParam

    let reqInit = cppBracedInit(reqName, epNames)

    # Same `ffi_*_` underscore convention as instance methods so that a ctor
    # parameter cannot collide with the local Req envelope name.
    #
    # The ctor's C symbol returns `void*` (the ctx pointer) synchronously, but
    # `ffi_call_` expects an int-returning lambda — and we want the callback
    # path anyway since it carries the CBOR-encoded ctx address. Discard the
    # synchronous return and yield 0 from the lambda; the address comes back
    # through the callback's CBOR text-string payload.
    lines.add("    static $1 create($2) {" % [ctxTypeName, ctorParamsWithTimeout])
    lines.add("        const auto ffi_req_ = $1;" % [reqInit])
    lines.add("        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);")
    lines.add("        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {")
    lines.add(
      "            (void)$1(ffi_req_bytes_.data(), ffi_req_bytes_.size(), cb, ud);" %
        [ctor.procName]
    )
    lines.add("            return 0;")
    lines.add("        }, timeout);")
    lines.add("        const auto addr_str = decodeCborFFI<std::string>(ffi_raw_);")
    lines.add("        try {")
    lines.add("            const auto addr = std::stoull(addr_str);")
    lines.add(
      "            return $1(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout);" %
        [ctxTypeName]
    )
    lines.add("        } catch (const std::exception&) {")
    lines.add(
      "            throw std::runtime_error(\"FFI create returned non-numeric address: \" + addr_str);"
    )
    lines.add("        }")
    lines.add("    }")
    lines.add("")

    let captureList =
      if epNames.len > 0:
        epNames.join(", ") & ", timeout"
      else:
        "timeout"
    let callList =
      if epNames.len > 0:
        epNames.join(", ") & ", timeout"
      else:
        "timeout"
    lines.add(
      "    static std::future<$1> createAsync($2) {" %
        [ctxTypeName, ctorParamsWithTimeout]
    )
    lines.add(
      "        return std::async(std::launch::async, [$1]() { return create($2); });" %
        [captureList, callList]
    )
    lines.add("    }")
    lines.add("")

  # ── Rule of 5 ──────────────────────────────────────────────────────────
  lines.add(
    ContextRuleOf5Tpl.multiReplace(("{{CTX}}", ctxTypeName), ("{{LIB}}", libName))
  )

  # ── Instance methods ────────────────────────────────────────────────────
  for m in methods:
    let methodName = stripLibPrefixCpp(m.procName, libName)
    let retCppType =
      if m.returnIsPtr:
        CppPtrType
      else:
        nimTypeToCpp(m.returnTypeName)
    let reqName = reqStructName(m)

    var methParams: seq[string] = @[]
    var methParamNames: seq[string] = @[]
    for ep in m.extraParams:
      let cppType =
        if ep.isPtr:
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      methParams.add("const $1& $2" % [cppType, ep.name])
      methParamNames.add(ep.name)
    let methParamsStr = methParams.join(", ")
    let methParamNamesStr = methParamNames.join(", ")

    let reqInit = cppBracedInit(reqName, methParamNames)

    # Use a single-underscore-suffixed local for the Req envelope so it can't
    # shadow a method parameter whose name happens to be `req` (or similar).
    lines.add("    $1 $2($3) const {" % [retCppType, methodName, methParamsStr])
    lines.add("        const auto ffi_req_ = $1;" % [reqInit])
    lines.add("        const auto ffi_req_bytes_ = encodeCborFFI(ffi_req_);")
    lines.add("        const auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {")
    lines.add(
      "            return $1(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());" %
        [m.procName]
    )
    lines.add("        }, timeout_);")
    lines.add("        return decodeCborFFI<$1>(ffi_raw_);" % [retCppType])
    lines.add("    }")
    lines.add("")
    # The async wrapper calls the sync method via `this->methodName(...)` so
    # a method param that happens to share the method's name doesn't shadow
    # the call target (e.g. `schedule(job, retry, schedule)` would otherwise
    # parse as invoking the `schedule` parameter).
    if methParamsStr.len > 0:
      lines.add(
        "    std::future<$1> $2Async($3) const {" %
          [retCppType, methodName, methParamsStr]
      )
      lines.add(
        "        return std::async(std::launch::async, [this, $1]() { return this->$2($3); });" %
          [methParamNamesStr, methodName, methParamNamesStr]
      )
      lines.add("    }")
    else:
      lines.add("    std::future<$1> $2Async() const {" % [retCppType, methodName])
      lines.add(
        "        return std::async(std::launch::async, [this]() { return this->$1(); });" %
          [methodName]
      )
      lines.add("    }")
    lines.add("")

  lines.add("private:")
  lines.add("    void* ptr_;")
  lines.add("    std::chrono::milliseconds timeout_;")
  lines.add(
    "    explicit $1(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}" %
      [ctxTypeName]
  )
  lines.add("};")
  lines.add("")

  return lines.join("\n")

proc generateCppCMakeLists*(libName: string, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  return CMakeListsTpl.multiReplace(("{{LIB}}", libName), ("{{SRC}}", src))

proc cppHeaderBanner(nimSrcRelPath: string): string =
  ## /* ... */ banner stamped at the top of every generated `<lib>.hpp` so
  ## readers know the file is regenerated from Nim source via codegen.
  return
    "/* ============================================================\n" &
    " * AUTO-GENERATED by nim-ffi v" & NimFFIVersion & "  (ffiMode=cbor, ffiLang=cpp). DO NOT EDIT.\n" &
    " *\n" &
    " *   Source:     " & nimSrcRelPath & "\n" &
    " *   Generator:  ffi/codegen/cpp.nim\n" &
    " *   Regenerate: nimble genbindings_cpp_cbor\n" &
    " * ============================================================ */\n\n"

proc cppCMakeBanner(nimSrcRelPath: string): string =
  return
    "# ============================================================\n" &
    "# AUTO-GENERATED by nim-ffi v" & NimFFIVersion & "  (ffiMode=cbor, ffiLang=cpp). DO NOT EDIT.\n" &
    "#\n" &
    "#   Source:     " & nimSrcRelPath & "\n" &
    "#   Generator:  ffi/codegen/cpp.nim\n" &
    "#   Regenerate: nimble genbindings_cpp_cbor\n" &
    "# ============================================================\n\n"

proc generateCppBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
) =
  createDir(outputDir)
  writeFile(
    outputDir / (libName & ".hpp"),
    cppHeaderBanner(nimSrcRelPath) & generateCppHeader(procs, types, libName),
  )
  writeFile(
    outputDir / "CMakeLists.txt",
    cppCMakeBanner(nimSrcRelPath) & generateCppCMakeLists(libName, nimSrcRelPath),
  )
