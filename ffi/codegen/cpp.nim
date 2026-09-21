## C++ binding generator: header-only binding + CMakeLists, CBOR over the wire.

import std/strutils
import
  ./meta,
  ./string_helpers,
  ./c_cpp_common,
  ./types_ir,
  ./consts,
  ./build_paths,
  ../ret_codes,
  ../ffi_msg

## Fixed 64-bit wire type for any Nim `ptr T` / `pointer`.
const CppPtrType* = "uint64_t"

## Trailing param of every call that can't inherit a ctx's `timeout_`.
const PollDoc =
  """Take the next message of `ctx` out, waiting up to `timeout_ms` (0 never
blocks, negative waits until a message or the end of the context).
NIMFFI_RET_OK: `*msg` is set. The message and its payload belong to the library
and stay valid until the next poll on `ctx`.
NIMFFI_RET_TIMEOUT: nothing arrived in time.
NIMFFI_RET_CLOSED: the context ended; `*msg` is a NIMFFI_MSG_CLOSED whose
`ret_code` is NIMFFI_RET_OK, or NIMFFI_RET_ERR with the reason as UTF-8 payload.
NIMFFI_RET_INVALID_CTX: `ctx` names no live context.
NIMFFI_RET_BUSY: another thread is polling `ctx`; there is one consumer at a time.
The context class below already polls from its dispatch thread."""

const PollFdDoc =
  """A handle that is ready while a message waits or `ctx` is closed: an epoll fd
on Linux, a kqueue fd on macOS/BSD, an Event HANDLE on Windows, -1 on failure.
The caller owns it and closes it. Wait on it, then poll with a timeout of 0
until NIMFFI_RET_TIMEOUT."""

const CppTimeoutParam = "std::chrono::milliseconds timeout = std::chrono::seconds{30}"

const
  HeaderPreludeTpl = staticRead("templates/cpp/header_prelude.hpp.tpl")
  ResultTpl = staticRead("templates/cpp/result.hpp.tpl")
  CborHelpersTpl = staticRead("templates/cpp/cbor_helpers.hpp.tpl")
  SyncCallHelperTpl = staticRead("templates/cpp/sync_call_helper.hpp.tpl")
  MsgTpl = staticRead("templates/cpp/msg.hpp.tpl")
  DispatcherTpl = staticRead("templates/cpp/dispatcher.hpp.tpl")
  ContextRuleOf5Tpl = staticRead("templates/cpp/context_rule_of_5.hpp.tpl")
  ContextListenersTpl = staticRead("templates/cpp/context_listeners.hpp.tpl")
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

func eventListenerMethod(ev: FFIEventMeta): string =
  return "addOn" & capitalizeFirstLetter(ev.nimProcName).substr(2) & "Listener"

func eventNameIdConst(ev: FFIEventMeta): string =
  return identToUpperSnake(ev.nimProcName) & "_NAME_ID"

proc emitListenerApi(
    lines: var seq[string], libName: string, events: seq[FFIEventMeta]
) =
  ## Emits the public listener API: one name-id constant and one typed
  ## `addOn<X>Listener` per event, then the liveness/closed hooks every library has.
  lines.add(
    "    // ── Messages from the library ───────────────────────────"
  )
  lines.add(
    "    // Everything $1 sends comes out of $1_poll on this context's dispatch thread," %
      [libName]
  )
  lines.add("    // which calls the listeners below, in the order they were added:")
  for ev in events:
    lines.add(
      "    //   event \"$1\" ($2)  -> $3" %
        [ev.wireName, ev.payloadTypeName, eventListenerMethod(ev)]
    )
  lines.add("    //   NIMFFI_MSG_NOT_RESPONDING  -> addNotRespondingListener")
  lines.add("    //   NIMFFI_MSG_RESPONDING      -> addRespondingListener")
  lines.add("    //   NIMFFI_MSG_CLOSED          -> addClosedListener")
  lines.add(
    "    // A listener may call back into this context, add or remove listeners, or"
  )
  lines.add("    // destroy the context.")
  lines.add("    struct ListenerHandle { std::uint64_t id = 0; };")
  lines.add("")
  for ev in events:
    lines.add(
      "    /// FNV-1a 64 of \"$1\": the NimFfiMsg.name_id of this event." % [
        ev.wireName
      ]
    )
    lines.add(
      "    static constexpr std::uint64_t $1 = $2ULL;" %
        [eventNameIdConst(ev), nameIdLiteral(ev.wireName)]
    )
    lines.add(renderMemberDocComment(ev.doc))
    lines.add(
      "    ListenerHandle $1(std::function<void(const $2&)> handler) {" %
        [eventListenerMethod(ev), ev.payloadTypeName]
    )
    lines.add(
      "        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_EVENT, $1, std::move(handler))};" %
        [eventNameIdConst(ev)]
    )
    lines.add("    }")
    lines.add("")
  lines.add(ContextListenersTpl)

proc emitEventDecoder(lines: var seq[string], events: seq[FFIEventMeta]) =
  ## The dispatch loop's per-library half: maps a name id to the payload type to decode.
  if events.len == 0:
    lines.add("    static void dispatchEvent_(NimFfiDispatcher&, const NimFfiMsg&) {}")
    return
  lines.add(
    "    static void dispatchEvent_(NimFfiDispatcher& dispatcher, const NimFfiMsg& msg) {"
  )
  lines.add("        switch (msg.name_id) {")
  for ev in events:
    lines.add(
      "        case $1: dispatcher.deliverEvent<$2>(msg); break;" %
        [eventNameIdConst(ev), ev.payloadTypeName]
    )
  lines.add("        default: break; // an event from a newer library")
  lines.add("        }")
  lines.add("    }")

proc generateCppHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
    consts: seq[FFIConstMeta] = @[],
): string =
  var lines: seq[string] = @[]

  lines.add(HeaderPreludeTpl.replace("{{RET_CODES}}", cRetCodeDefines()))

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

  lines.add(MsgTpl.replace("{{MSG_DECL}}", cMsgDecl()))

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
  lines.add(renderBlockDocComment(PollDoc))
  lines.add(
    "int $1_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);" % [libName]
  )
  lines.add(renderBlockDocComment(PollFdDoc))
  lines.add("intptr_t $1_poll_fd(void* ctx);" % [libName])
  lines.add(renderBlockDocComment(ShutdownDoc))
  lines.add("int $1_shutdown(void);" % [libName])
  lines.add("} // extern \"C\"")
  lines.add("")

  lines.add(SyncCallHelperTpl)

  lines.add(DispatcherTpl)

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
      "        auto ffi_ctx_ = std::unique_ptr<$1>(new $1(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout));" %
        [ctxTypeName]
    )
    lines.add("        if (!ffi_ctx_->dispatchThread_.joinable()) {")
    lines.add(
      "            return $1::err(\"could not start the event dispatch thread\");" %
        [createRet]
    )
    lines.add("        }")
    lines.add("        return $1::ok(std::move(ffi_ctx_));" % [createRet])
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

  emitListenerApi(lines, libName, events)

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
  emitEventDecoder(lines, events)
  lines.add("")
  lines.add("    void* ptr_;")
  lines.add("    std::chrono::milliseconds timeout_;")
  # Shared with the dispatch thread, which outlives `this` when a listener destroys the context.
  lines.add("    std::shared_ptr<NimFfiDispatcher> dispatcher_;")
  lines.add("    std::thread dispatchThread_;")
  lines.add("    explicit $1(void* p, std::chrono::milliseconds t)" % [ctxTypeName])
  lines.add(
    "        : ptr_(p), timeout_(t), dispatcher_(std::make_shared<NimFfiDispatcher>()) {"
  )
  lines.add(
    "        dispatchThread_ = NimFfiDispatcher::start(dispatcher_, &$1_poll, ptr_, &$2::dispatchEvent_);" %
      [libName, ctxTypeName]
  )
  lines.add("    }")
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
) =
  ensureOutputDir(outputDir)
  writeOutputFile(
    buildPath(outputDir, libName & ".hpp"),
    generateCppHeader(procs, types, libName, events, consts),
  )
  writeOutputFile(
    buildPath(outputDir, "CMakeLists.txt"),
    generateCppCMakeLists(libName, nimSrcRelPath),
  )
