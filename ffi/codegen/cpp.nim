## C++ binding generator: header-only binding + CMakeLists, CBOR over the wire.

import std/[os, strutils]
import ./meta, ./string_helpers, ./c_cpp_common, ./types_ir, ./consts, ../ret_codes

## Fixed 64-bit wire type for any Nim `ptr T` / `pointer`.
const CppPtrType* = "uint64_t"

## Trailing param of every call that can't inherit a ctx's `timeout_`.
const CppTimeoutParam = "std::chrono::milliseconds timeout = std::chrono::seconds{30}"

const
  HeaderPreludeTpl = staticRead("templates/cpp/header_prelude.hpp.tpl")
  ResultTpl = staticRead("templates/cpp/result.hpp.tpl")
  CborHelpersTpl = staticRead("templates/cpp/cbor_helpers.hpp.tpl")
  SyncCallHelperTpl = staticRead("templates/cpp/sync_call_helper.hpp.tpl")
  ContextRuleOf5Tpl = staticRead("templates/cpp/context_rule_of_5.hpp.tpl")
  CMakeListsTpl = staticRead("templates/cpp/CMakeLists.txt.tpl")
  FindRepoRootTpl = staticRead("templates/find_repo_root.cmake.part")

func cppScalar(s: ScalarKind): string =
  case s
  of skBool: "bool"
  of skI8: "int8_t"
  of skI16: "int16_t"
  of skI32: "int32_t"
  of skI64: "int64_t"
  of skU8: "uint8_t"
  of skU16: "uint16_t"
  of skU32: "uint32_t"
  of skU64: "uint64_t"
  of skF32: "float"
  of skF64: "double"

func cppSeq(elem: string): string =
  "std::vector<" & elem & ">"

func cppOpt(elem: string): string =
  "std::optional<" & elem & ">"

const cppMap = NativeTypeMap(
  scalar: cppScalar,
  str: "std::string",
  bytes: "std::vector<uint8_t>",
  ptrType: CppPtrType,
  seqOf: cppSeq,
  optOf: cppOpt,
) ## structName omitted: C++ uses the user type name verbatim

proc nimTypeToCpp*(typeName: string): string =
  renderNative(cppMap, parseFFIType(typeName))

proc emitEnumCborCodec(lines: var seq[string], t: FFITypeMeta) =
  ## Appends the `enum class` plus its TinyCBOR codec pair. The wire form is the
  ## CBOR text `$value` yields on the Nim side, so the codec maps name ↔ value.
  lines.add("enum class $1 {" % [t.name])
  for v in t.enumValues:
    lines.add("    $1 = $2," % [v.name, $v.ord])
  lines.add("};")

  lines.add("inline CborError encode_cbor(CborEncoder& e, const $1& v) {" % [t.name])
  lines.add("    switch (v) {")
  for v in t.enumValues:
    lines.add(
      "    case $1::$2: return cbor_encode_text_stringz(&e, \"$3\");" %
        [t.name, v.name, v.wire]
    )
  lines.add("    }")
  lines.add("    return CborErrorImproperValue;")
  lines.add("}")

  lines.add("inline CborError decode_cbor(CborValue& it, $1& v) {" % [t.name])
  lines.add("    std::string name;")
  lines.add("    CborError err = decode_cbor(it, name);")
  lines.add("    if (err) return err;")
  for v in t.enumValues:
    lines.add(
      "    if (name == \"$1\") { v = $2::$3; return CborNoError; }" %
        [v.wire, t.name, v.name]
    )
  lines.add("    return CborErrorImproperValue;")
  lines.add("}")
  lines.add("")

proc emitStructCborCodec(
    lines: var seq[string], structName: string, fields: seq[(string, string)]
) =
  ## Appends per-struct TinyCBOR encode_cbor + decode_cbor functions emitting a
  ## text-keyed CBOR map. The C++ type in `fields` is unused (overloads dispatch).
  let n = fields.len
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
  ## C++ braced-init for a Req struct, e.g. `TimerEchoReq{message, count}`.
  return structName & "{" & fieldNames.join(", ") & "}"

proc emitEventDispatcher(
    lines: var seq[string], ctxTypeName, libName: string, events: seq[FFIEventMeta]
) =
  ## Emits the public per-event `addOn<X>Listener` / `removeEventListener` API.
  ## Callables are owned by `listeners_` (unique_ptr keyed by id); the raw
  ## pointer is the dylib's `user_data`, stable until removal.
  if events.len == 0:
    return
  lines.add(
    "    // ── Event listener API ──────────────────────────────────"
  )
  lines.add("    struct ListenerHandle { std::uint64_t id = 0; };")
  lines.add("")
  for ev in events:
    let methodName =
      "addOn" & capitalizeFirstLetter(ev.nimProcName).substr(2) & "Listener"
    lines.add(renderMemberDocComment(ev.doc))
    lines.add(
      "    ListenerHandle $1(std::function<void(const $2&)> handler) {" %
        [methodName, ev.payloadTypeName]
    )
    lines.add(
      "        auto owned = std::make_unique<TypedListener<$1>>(std::move(handler));" %
        [ev.payloadTypeName]
    )
    lines.add("        auto* raw = owned.get();")
    lines.add("        const auto id = $1_add_event_listener(" % [libName])
    lines.add(
      "            ptr_, \"$1\", &$2::typedTrampoline<$3>, raw);" %
        [ev.wireName, ctxTypeName, ev.payloadTypeName]
    )
    lines.add("        if (id == 0) return ListenerHandle{0};")
    lines.add("        listeners_.emplace(id, std::move(owned));")
    lines.add("        return ListenerHandle{id};")
    lines.add("    }")
    lines.add("")
  lines.add(renderMemberDocComment(CtxRemoveListenerDoc))
  lines.add("    bool removeEventListener(ListenerHandle handle) {")
  lines.add("        if (handle.id == 0) return false;")
  lines.add(
    "        const auto rc = $1_remove_event_listener(ptr_, handle.id);" % [libName]
  )
  lines.add("        listeners_.erase(handle.id);")
  lines.add("        return rc == 0;")
  lines.add("    }")
  lines.add("")

proc emitEventTrampoline(lines: var seq[string], events: seq[FFIEventMeta]) =
  ## Private listener machinery for `emitEventDispatcher`: polymorphic
  ## `ListenerBase`, `TypedListener<T>` and the `typedTrampoline<T>` decoder.
  if events.len == 0:
    return
  lines.add("    struct ListenerBase {")
  lines.add("        virtual ~ListenerBase() = default;")
  lines.add("    };")
  lines.add("")
  lines.add("    template <class T>")
  lines.add("    struct TypedListener : ListenerBase {")
  lines.add("        std::function<void(const T&)> fn;")
  lines.add(
    "        explicit TypedListener(std::function<void(const T&)> f) : fn(std::move(f)) {}"
  )
  lines.add("    };")
  lines.add("")
  lines.add("    template <class T>")
  lines.add(
    "    static void typedTrampoline(int ret, const char* msg, std::size_t len, void* ud) {"
  )
  lines.add("        if (!ud || ret != 0 || !msg || len == 0) return;")
  lines.add("        auto* listener = static_cast<TypedListener<T>*>(ud);")
  lines.add("        if (!listener->fn) return;")
  lines.add("        CborParser parser; CborValue it;")
  lines.add(
    "        if (cbor_parser_init(reinterpret_cast<const std::uint8_t*>(msg), len, 0, &parser, &it) != CborNoError) return;"
  )
  lines.add("        if (!cbor_value_is_map(&it)) return;")
  lines.add("        CborValue payloadField;")
  lines.add(
    "        if (cbor_value_map_find_value(&it, \"payload\", &payloadField) != CborNoError) return;"
  )
  lines.add("        T payload{};")
  lines.add("        if (decode_cbor(payloadField, payload) != CborNoError) return;")
  lines.add("        listener->fn(payload);")
  lines.add("    }")
  lines.add("")

func reverseCallStruct(r: FFIReverseMeta): string =
  ## Nested per-interface call token, e.g. `FetchHostClockCall`.
  capitalizeFirstLetter(r.nimProcName) & "Call"

func reverseBoxStruct(r: FFIReverseMeta): string =
  capitalizeFirstLetter(r.nimProcName) & "ImplBox"

func reverseBoxMember(r: FFIReverseMeta): string =
  r.nimProcName & "ImplBox_"

func reverseArgsCpp(r: FFIReverseMeta): string =
  ## "" when the interface takes no arguments.
  if r.argsTypeName.len == 0:
    ""
  else:
    nimTypeToCpp(r.argsTypeName)

func reverseImplFnType(r: FFIReverseMeta): string =
  ## The host-side callable: `(Call, const Args&)`, or `(Call)` with no args.
  let argsCpp = reverseArgsCpp(r)
  if argsCpp.len == 0:
    "std::function<void($1)>" % [reverseCallStruct(r)]
  else:
    "std::function<void($1, const $2&)>" % [reverseCallStruct(r), argsCpp]

proc emitReverseApi(
    lines: var seq[string],
    ctxTypeName, libName: string,
    reverse: seq[FFIReverseMeta],
    reverseEvents: seq[FFIReverseEventMeta],
) =
  ## Public reverse surface: per-interface call tokens with typed reply/fail,
  ## set/clear registration, and flattened emit methods for reverse events.
  if reverse.len > 0:
    lines.add(
      "    // ── Reverse FFI: host-implemented interfaces ────────────"
    )
    lines.add(
      "    // Impls run on the context's reverse worker threads (started lazily"
    )
    lines.add(
      "    // by the first set…Impl); start them ahead of time with n workers,"
    )
    lines.add("    // n <= 0 for the library default.")
    lines.add("    bool startReverseWorkers(int n = 0) const {")
    lines.add("        return $1_start_reverse_workers(ptr_, n) == 0;" % [libName])
    lines.add("    }")
    lines.add("")
    for r in reverse:
      let callStruct = reverseCallStruct(r)
      lines.add(
        "    // Copyable answer token for one `$1` invocation; reply once," %
          [r.wireName]
      )
      lines.add("    // inline or later from any thread.")
      lines.add("    struct $1 {" % [callStruct])
      lines.add("        void* ctx = nullptr;")
      lines.add("        std::uint64_t id = 0;")
      if r.replyTypeName.len > 0:
        let replyCpp = nimTypeToCpp(r.replyTypeName)
        lines.add("        bool reply(const $1& r) const {" % [replyCpp])
        lines.add("            auto enc = encodeCborFFI(r);")
        lines.add("            if (enc.isErr()) return fail(enc.error());")
        lines.add("            const auto& b = enc.value();")
        lines.add(
          "            return $1_reverse_reply(ctx, id, 0, b.data(), b.size()) == 0;" %
            [libName]
        )
        lines.add("        }")
      else:
        lines.add("        bool reply() const {")
        lines.add(
          "            return $1_reverse_reply(ctx, id, 0, nullptr, 0) == 0;" % [
            libName
          ]
        )
        lines.add("        }")
      lines.add("        bool fail(const std::string& msg) const {")
      lines.add(
        "            return $1_reverse_reply(ctx, id, 1, reinterpret_cast<const std::uint8_t*>(msg.data()), msg.size()) == 0;" %
          [libName]
      )
      lines.add("        }")
      lines.add("    };")
      lines.add("")
    for r in reverse:
      let pascal = capitalizeFirstLetter(r.nimProcName)
      lines.add(renderMemberDocComment(r.doc))
      lines.add("    bool set$1Impl($2 fn) {" % [pascal, reverseImplFnType(r)])
      lines.add(
        "        auto owned = std::make_unique<$1>($1{ptr_, std::move(fn)});" %
          [reverseBoxStruct(r)]
      )
      lines.add("        auto* raw = owned.get();")
      lines.add(
        "        if ($1_set_$2_impl(ptr_, &$3::$4ImplTrampoline, raw) != 0) return false;" %
          [libName, r.wireName, ctxTypeName, r.nimProcName]
      )
      # set_impl waits an in-flight invocation of the OLD impl out, so replacing
      # the box here cannot free it under a running trampoline.
      lines.add("        $1 = std::move(owned);" % [reverseBoxMember(r)])
      lines.add("        return true;")
      lines.add("    }")
      lines.add("")
      lines.add("    bool clear$1Impl() {" % [pascal])
      lines.add(
        "        if ($1_set_$2_impl(ptr_, nullptr, nullptr) != 0) return false;" %
          [libName, r.wireName]
      )
      lines.add("        $1.reset();" % [reverseBoxMember(r)])
      lines.add("        return true;")
      lines.add("    }")
      lines.add("")
  if reverseEvents.len > 0:
    lines.add("    // ── Reverse FFI: host-emitted events (fire-and-forget) ──")
    for rev in reverseEvents:
      let pascal = capitalizeFirstLetter(rev.nimProcName)
      var params: seq[string] = @[]
      var names: seq[string] = @[]
      for p in rev.params:
        params.add("const $1& $2" % [nimTypeToCpp(p.typeName), p.name])
        names.add(p.name)
      lines.add(renderMemberDocComment(rev.doc))
      lines.add("    bool emit$1($2) const {" % [pascal, params.join(", ")])
      lines.add(
        "        const auto payload_ = $1;" % [cppBracedInit(rev.reqTypeName, names)]
      )
      lines.add("        auto enc = encodeCborFFI(payload_);")
      lines.add("        if (enc.isErr()) return false;")
      lines.add("        const auto& b = enc.value();")
      lines.add(
        "        return $1_emit_$2(ptr_, b.data(), b.size()) == 0;" %
          [libName, rev.wireName]
      )
      lines.add("    }")
      lines.add("")

proc emitReverseMachinery(
    lines: var seq[string], ctxTypeName: string, reverse: seq[FFIReverseMeta]
) =
  ## Private reverse machinery: per-interface impl boxes and cdecl trampolines
  ## (invoked on the library's event dispatch thread) that decode the CBOR args
  ## and hand the host callable a typed call token.
  if reverse.len == 0:
    return
  lines.add("    template <class T>")
  lines.add(
    "    static CborError decodeReverseArgs_(const std::uint8_t* data, std::size_t len, T& out) {"
  )
  lines.add("        CborParser parser; CborValue it;")
  lines.add("        CborError err = cbor_parser_init(data, len, 0, &parser, &it);")
  lines.add("        if (err) return err;")
  lines.add("        return decode_cbor(it, out);")
  lines.add("    }")
  lines.add("")
  for r in reverse:
    let box = reverseBoxStruct(r)
    let callStruct = reverseCallStruct(r)
    let argsCpp = reverseArgsCpp(r)
    lines.add("    struct $1 {" % [box])
    lines.add("        void* ctx = nullptr;")
    lines.add("        $1 fn;" % [reverseImplFnType(r)])
    lines.add("    };")
    lines.add(
      "    static void $1ImplTrampoline(std::uint64_t call_id, const std::uint8_t* args, std::size_t len, void* ud) {" %
        [r.nimProcName]
    )
    lines.add("        auto* box = static_cast<$1*>(ud);" % [box])
    lines.add("        $1 call{box->ctx, call_id};" % [callStruct])
    lines.add("        if (!box->fn) { call.fail(\"no C++ impl callable\"); return; }")
    if argsCpp.len == 0:
      lines.add("        (void)args; (void)len;")
      lines.add("        box->fn(call);")
    else:
      lines.add("        $1 a{};" % [argsCpp])
      lines.add("        if (decodeReverseArgs_(args, len, a) != CborNoError) {")
      lines.add("            call.fail(\"reverse args decode failed\");")
      lines.add("            return;")
      lines.add("        }")
      lines.add("        box->fn(call, a);")
    lines.add("    }")
    lines.add("")

proc generateCppHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
    consts: seq[FFIConstMeta] = @[],
    reverse: seq[FFIReverseMeta] = @[],
    reverseEvents: seq[FFIReverseEventMeta] = @[],
): string =
  var lines: seq[string] = @[]

  lines.add(HeaderPreludeTpl.replace("{{RET_CODES}}", cRetCodeDefines()))
  if events.len > 0:
    lines.add("#include <unordered_map>")

  lines.add(ResultTpl)

  # Generic CBOR overloads must precede the non-template struct codecs that call them (parse-time name lookup).
  lines.add(CborHelpersTpl)

  if consts.len > 0:
    lines.add("// ============================================================")
    lines.add("// Generated constants")
    lines.add("// ============================================================")
    lines.add("")
    for c in consts:
      let t = parseFFIType(c.typeName)
      # A string const is a `const char*`, not std::string: constexpr can't own a heap value.
      let cppType =
        if t.kind == ftStr:
          "const char*"
        else:
          nimTypeToCpp(c.typeName)
      lines.add(
        "constexpr $1 $2 = $3;" %
          [cppType, identToUpperSnake(c.name), cConstValue(t, c.value)]
      )
    lines.add("")

  # Enums first: a struct codec that takes one must see its overload already declared.
  var structTypes: seq[FFITypeMeta] = @[]
  for t in types:
    if t.isEnum():
      emitEnumCborCodec(lines, t)
    else:
      structTypes.add(t)

  if structTypes.len > 0:
    lines.add("// ============================================================")
    lines.add("// User-declared FFI types")
    lines.add("// ============================================================")
    lines.add("")
    for t in structTypes:
      lines.add("struct $1 {" % [t.name])
      for f in t.fields:
        lines.add("    $1 $2;" % [nimTypeToCpp(f.typeName), f.name])
      lines.add("};")
      var fields: seq[(string, string)] = @[]
      for f in t.fields:
        fields.add((f.name, nimTypeToCpp(f.typeName)))
      emitStructCborCodec(lines, t.name, fields)
      lines.add("")

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
        if ep.ridesAsPtr():
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      lines.add("    $1 $2;" % [cppType, ep.name])
    lines.add("};")
    var fields: seq[(string, string)] = @[]
    for ep in p.extraParams:
      let cppType =
        if ep.ridesAsPtr():
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      fields.add((ep.name, cppType))
    emitStructCborCodec(lines, reqName, fields)
    lines.add("")

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
    lines.add(renderBlockDocComment(p.doc))
    case p.kind
    of FFIKind.FFI:
      lines.add(
        "int $1(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);" %
          [p.procName]
      )
    of FFIKind.STATIC:
      lines.add(
        "int $1(FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);" %
          [p.procName]
      )
    of FFIKind.CTOR:
      lines.add(
        "void* $1(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);" %
          [p.procName]
      )
    of FFIKind.DTOR:
      lines.add("int $1(void* ctx);" % [p.procName])
  # Listener-registration ABI is always exported.
  lines.add(
    "uint64_t $1_add_event_listener(void* ctx, const char* event_name, FFICallback callback, void* user_data);" %
      [libName]
  )
  lines.add(renderBlockDocComment(RemoveListenerDoc))
  lines.add(
    "int $1_remove_event_listener(void* ctx, uint64_t listener_id);" % [libName]
  )
  if reverse.len > 0 or reverseEvents.len > 0:
    lines.add("")
    lines.add("// Reverse FFI: host-implemented interfaces + host-emitted events")
  if reverse.len > 0:
    lines.add(
      "typedef void (*FFIReverseImpl)(uint64_t call_id, const uint8_t* args_cbor, size_t args_len, void* user_data);"
    )
    for r in reverse:
      lines.add(
        "int $1_set_$2_impl(void* ctx, FFIReverseImpl impl, void* user_data);" %
          [libName, r.wireName]
      )
    lines.add(
      "int $1_reverse_reply(void* ctx, uint64_t call_id, int ret_code, const uint8_t* reply_cbor, size_t reply_len);" %
        [libName]
    )
    lines.add("int $1_start_reverse_workers(void* ctx, int n);" % [libName])
  for rev in reverseEvents:
    lines.add(
      "int $1_emit_$2(void* ctx, const uint8_t* payload_cbor, size_t payload_len);" %
        [libName, rev.wireName]
    )
  lines.add(renderBlockDocComment(ShutdownDoc))
  lines.add("int $1_shutdown(void);" % [libName])
  lines.add("} // extern \"C\"")
  lines.add("")

  lines.add(SyncCallHelperTpl)

  let classified = classifyProcs(procs)
  let ctors = classified.ctors
  let ctxTypeName = libTypeName(ctors, libName) & "Ctx"

  lines.add("// ============================================================")
  lines.add("// High-level C++ context class")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("class $1 {" % [ctxTypeName])
  lines.add("public:")

  for ctor in ctors:
    let reqName = reqStructName(ctor)
    var ctorParams: seq[string] = @[]
    var epNames: seq[string] = @[]
    for ep in ctor.extraParams:
      let cppType =
        if ep.ridesAsPtr():
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      ctorParams.add("const $1& $2" % [cppType, ep.name])
      epNames.add(ep.name)
    let ctorParamsWithTimeout =
      if ctorParams.len > 0:
        ctorParams.join(", ") & ", " & CppTimeoutParam
      else:
        CppTimeoutParam

    let reqInit = cppBracedInit(reqName, epNames)

    # `create` yields the ctx via the callback's CBOR address (sync void* return discarded), owned as a unique_ptr since the class forbids copy/move.
    let createRet = "Result<std::unique_ptr<$1>>" % [ctxTypeName]
    lines.add(renderMemberDocComment(ctor.doc))
    lines.add("    static $1 create($2) {" % [createRet, ctorParamsWithTimeout])
    lines.add("        const auto ffi_req_ = $1;" % [reqInit])
    lines.add("        auto ffi_enc_ = encodeCborFFI(ffi_req_);")
    lines.add(
      "        if (ffi_enc_.isErr()) return $1::err(ffi_enc_.error());" % [createRet]
    )
    lines.add("        const auto& ffi_req_bytes_ = ffi_enc_.value();")
    lines.add("        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {")
    lines.add(
      "            (void)$1(ffi_req_bytes_.data(), ffi_req_bytes_.size(), cb, ud);" %
        [ctor.procName]
    )
    lines.add("            return 0;")
    lines.add("        }, timeout);")
    lines.add(
      "        if (ffi_raw_.isErr()) return $1::err(ffi_raw_.error());" % [createRet]
    )
    lines.add("        auto ffi_addr_ = decodeCborFFI<std::string>(ffi_raw_.value());")
    lines.add(
      "        if (ffi_addr_.isErr()) return $1::err(ffi_addr_.error());" % [createRet]
    )
    lines.add("        const auto& addr_str = ffi_addr_.value();")
    # from_chars (not stoull) so a bad payload is an err() Result, not a throw.
    lines.add("        std::uint64_t addr = 0;")
    lines.add("        const char* addr_begin = addr_str.data();")
    lines.add("        const char* addr_end = addr_begin + addr_str.size();")
    lines.add("        const auto fc_ = std::from_chars(addr_begin, addr_end, addr);")
    lines.add("        if (fc_.ec != std::errc() || fc_.ptr != addr_end) {")
    lines.add(
      "            return $1::err(\"FFI create returned non-numeric address: \" + addr_str);" %
        [createRet]
    )
    lines.add("        }")
    # `new` (not make_unique) so the ctor can stay private.
    lines.add(
      "        return $1::ok(std::unique_ptr<$2>(new $2(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout)));" %
        [createRet, ctxTypeName]
    )
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
    lines.add(renderMemberDocComment(ctor.doc))
    lines.add(
      "    static std::future<Result<std::unique_ptr<$1>>> createAsync($2) {" %
        [ctxTypeName, ctorParamsWithTimeout]
    )
    lines.add(
      "        return std::async(std::launch::async, [$1]() { return create($2); });" %
        [captureList, callList]
    )
    lines.add("    }")
    lines.add("")

  lines.add(
    ContextRuleOf5Tpl.multiReplace(("{{CTX}}", ctxTypeName), ("{{LIB}}", libName))
  )

  emitEventDispatcher(lines, ctxTypeName, libName, events)
  emitReverseApi(lines, ctxTypeName, libName, reverse, reverseEvents)

  # A static has no ctx to inherit `timeout_` from, so it takes its own `timeout`.
  for m in classified.replyProcs():
    let isStatic = m.isStatic()
    let methodName = stripLibPrefix(m.procName, libName)
    let retCppType =
      if m.returnRidesAsPtr():
        CppPtrType
      else:
        nimTypeToCpp(m.returnTypeName)
    let reqName = reqStructName(m)

    var methParams: seq[string] = @[]
    var methParamNames: seq[string] = @[]
    for ep in m.extraParams:
      let cppType =
        if ep.ridesAsPtr():
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      methParams.add("const $1& $2" % [cppType, ep.name])
      methParamNames.add(ep.name)
    let methParamNamesStr = methParamNames.join(", ")
    let methParamsStr =
      if not isStatic:
        methParams.join(", ")
      elif methParams.len > 0:
        methParams.join(", ") & ", " & CppTimeoutParam
      else:
        CppTimeoutParam

    let reqInit = cppBracedInit(reqName, methParamNames)

    let methRet = "Result<$1>" % [retCppType]
    lines.add(renderMemberDocComment(m.doc))
    let decl = if isStatic: "    static $1 $2($3) {" else: "    $1 $2($3) const {"
    lines.add(decl % [methRet, methodName, methParamsStr])
    lines.add("        const auto ffi_req_ = $1;" % [reqInit])
    lines.add("        auto ffi_enc_ = encodeCborFFI(ffi_req_);")
    lines.add(
      "        if (ffi_enc_.isErr()) return $1::err(ffi_enc_.error());" % [methRet]
    )
    lines.add("        const auto& ffi_req_bytes_ = ffi_enc_.value();")
    lines.add("        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {")
    let ctxArg = if isStatic: "" else: "ptr_, "
    lines.add(
      "            return $1($2cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());" %
        [m.procName, ctxArg]
    )
    lines.add("        }, $1);" % [if isStatic: "timeout" else: "timeout_"])
    lines.add(
      "        if (ffi_raw_.isErr()) return $1::err(ffi_raw_.error());" % [methRet]
    )
    lines.add("        return decodeCborFFI<$1>(ffi_raw_.value());" % [retCppType])
    lines.add("    }")
    lines.add("")

    # A method calls `this->methodName(...)` so a same-named param can't shadow
    # the call target; a static has no `this` and forwards its own `timeout`.
    let staticArgs =
      if methParamNames.len > 0:
        methParamNamesStr & ", timeout"
      else:
        "timeout"
    let asyncArgs = if isStatic: staticArgs else: methParamNamesStr
    let asyncCapture =
      if isStatic:
        staticArgs
      elif methParamNamesStr.len > 0:
        "this, " & methParamNamesStr
      else:
        "this"
    let asyncDecl =
      if isStatic:
        "    static std::future<$1> $2Async($3) {"
      else:
        "    std::future<$1> $2Async($3) const {"
    lines.add(renderMemberDocComment(m.doc))
    lines.add(asyncDecl % [methRet, methodName, methParamsStr])
    lines.add(
      "        return std::async(std::launch::async, [$1]() { return $2$3($4); });" %
        [asyncCapture, (if isStatic: "" else: "this->"), methodName, asyncArgs]
    )
    lines.add("    }")
    lines.add("")

  lines.add("private:")
  # Listener machinery must precede the `listeners_` member (its value type must be complete at declaration).
  emitEventTrampoline(lines, events)
  emitReverseMachinery(lines, ctxTypeName, reverse)
  lines.add("    void* ptr_;")
  lines.add("    std::chrono::milliseconds timeout_;")
  if events.len > 0:
    lines.add(
      "    std::unordered_map<std::uint64_t, std::unique_ptr<ListenerBase>> listeners_;"
    )
  for r in reverse:
    lines.add(
      "    std::unique_ptr<$1> $2;" % [reverseBoxStruct(r), reverseBoxMember(r)]
    )
  lines.add(
    "    explicit $1(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}" %
      [ctxTypeName]
  )
  lines.add("};")
  lines.add("")

  return lines.join("\n")

proc generateCppCMakeLists*(libName: string, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  return CMakeListsTpl.multiReplace(
    ("{{LIB}}", libName),
    ("{{SRC}}", src),
    ("{{FIND_REPO_ROOT}}", FindRepoRootTpl.strip(leading = false)),
  )

proc generateCppBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
    consts: seq[FFIConstMeta] = @[],
    reverse: seq[FFIReverseMeta] = @[],
    reverseEvents: seq[FFIReverseEventMeta] = @[],
) =
  createDir(outputDir)
  writeFile(
    outputDir / (libName & ".hpp"),
    generateCppHeader(procs, types, libName, events, consts, reverse, reverseEvents),
  )
  writeFile(outputDir / "CMakeLists.txt", generateCppCMakeLists(libName, nimSrcRelPath))
