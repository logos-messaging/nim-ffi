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

const RequestsDoc =
  """A request returns as soon as it is queued. NIMFFI_RET_OK promises exactly one
NIMFFI_MSG_REPLY out of `<lib>_poll` whose `id` is `*req_id_out`, unless the
context closes first; the reply can be polled before the request call returns.
Any other return means no reply will come; `<lib>_last_error` says why.
A reply's `ret_code` is NIMFFI_RET_OK and its payload the CBOR return value, or
NIMFFI_RET_ERR and its payload UTF-8 error text.
The constructor sets `*ctx_out` at once, so it can be polled; whether the
construction worked is the reply `*req_id_out` on it. After a NIMFFI_RET_ERR
reply the context is still claimed and must be destroyed.
The context class below does all of this: one typed method per request."""

const StaticCtxDoc =
  """The context the replies of the static procs arrive on; NULL on failure."""

const LastErrorDoc =
  """Why the last request of the calling thread was refused. Never NULL."""

## Trailing param of every call that can't inherit a ctx's `timeout_`.
const ListenerRulesDoc =
  """    // Listeners run on the dispatch thread, in the order they were added. One may add
    // or remove listeners, destroy the context, or make a blocking call on this
    // context: the call then polls in place, so other listeners can run before it
    // returns. It must never wait on a future of this context (`xAsync().get()`):
    // only the dispatch thread, which it is blocking, can fulfil that future."""

const CppTimeoutParam = "std::chrono::milliseconds timeout = std::chrono::seconds{30}"

const
  HeaderPreludeTpl = staticRead("templates/cpp/header_prelude.hpp.tpl")
  ResultTpl = staticRead("templates/cpp/result.hpp.tpl")
  CborHelpersTpl = staticRead("templates/cpp/cbor_helpers.hpp.tpl")
  MsgTpl = staticRead("templates/cpp/msg.hpp.tpl")
  DispatcherTpl = staticRead("templates/cpp/dispatcher.hpp.tpl")
  ContextCreateTpl = staticRead("templates/cpp/context_create.hpp.tpl")
  ContextCreateAsyncTpl = staticRead("templates/cpp/context_create_async.hpp.tpl")
  ContextRuleOf5Tpl = staticRead("templates/cpp/context_rule_of_5.hpp.tpl")
  ContextShutdownTpl = staticRead("templates/cpp/context_shutdown.hpp.tpl")
  ContextStaticTpl = staticRead("templates/cpp/context_static.hpp.tpl")
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
    "    // Everything $1 sends comes out of $1_poll on this context's dispatch thread:" %
      [libName]
  )
  lines.add("    //   NIMFFI_MSG_REPLY           -> the method that made the request")
  lines.add("    //   NIMFFI_MSG_STALE_WARN      -> addStaleWarnListener")
  for ev in events:
    lines.add(
      "    //   event \"$1\" ($2)  -> $3" %
        [ev.wireName, ev.payloadTypeName, eventListenerMethod(ev)]
    )
  lines.add("    //   NIMFFI_MSG_NOT_RESPONDING  -> addNotRespondingListener")
  lines.add("    //   NIMFFI_MSG_RESPONDING      -> addRespondingListener")
  lines.add("    //   NIMFFI_MSG_CLOSED          -> addClosedListener")
  lines.add(ListenerRulesDoc)
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
  lines.add(renderBlockDocComment(RequestsDoc))
  lines.add("")
  for p in procs:
    lines.add(renderBlockDocComment(p.doc))
    case p.kind
    of FFIKind.FFI:
      lines.add(
        "int $1(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);" %
          [p.procName]
      )
    of FFIKind.STATIC:
      lines.add(
        "int $1(const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);" %
          [p.procName]
      )
    of FFIKind.CTOR:
      lines.add(
        "int $1(const uint8_t* req_cbor, size_t req_cbor_len, void** ctx_out, uint64_t* req_id_out);" %
          [p.procName]
      )
    of FFIKind.DTOR:
      lines.add("int $1(void* ctx);" % [p.procName])
  lines.add(renderBlockDocComment(StaticCtxDoc))
  lines.add("void* $1_static_ctx(void);" % [libName])
  lines.add(renderBlockDocComment(LastErrorDoc))
  lines.add("const char* $1_last_error(void);" % [libName])
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

    let ctorSubst = [
      ("{{CTX}}", ctxTypeName),
      ("{{LIB}}", libName),
      ("{{CREATE}}", ctor.procName),
      ("{{PARAMS}}", ctorParamsWithTimeout),
      ("{{REQ_INIT}}", cppBracedInit(reqName, epNames)),
    ]
    lines.add(renderMemberDocComment(ctor.doc))
    lines.add(ContextCreateTpl.multiReplace(ctorSubst))
    lines.add(renderMemberDocComment(ctor.doc))
    lines.add(ContextCreateAsyncTpl.multiReplace(ctorSubst))

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
    let methParamsStr =
      if not isStatic:
        methParams.join(", ")
      elif methParams.len > 0:
        methParams.join(", ") & ", " & CppTimeoutParam
      else:
        CppTimeoutParam

    let reqInit = cppBracedInit(reqName, methParamNames)

    let methRet = "Result<$1>" % [retCppType]
    let ctxArg = if isStatic: "" else: "ptr_, "
    let timeoutArg = if isStatic: "timeout" else: "timeout_"
    let syncDecl = if isStatic: "    static $1 $2($3) {" else: "    $1 $2($3) const {"
    let asyncDecl =
      if isStatic:
        "    static std::future<$1> $2Async($3) {"
      else:
        "    std::future<$1> $2Async($3) const {"

    # The blocking and the future flavour differ in how a failure is returned
    # and in which dispatch entry point waits for the reply.
    for isAsync in [false, true]:
      var errFmt = "return $1::err($2);"
      if isAsync:
        errFmt = "return NimFfiDispatcher::ready($1::err($2));"
      lines.add(renderMemberDocComment(m.doc))
      lines.add(
        (if isAsync: asyncDecl else: syncDecl) % [methRet, methodName, methParamsStr]
      )
      lines.add("        const auto ffi_req_ = $1;" % [reqInit])
      lines.add("        auto ffi_enc_ = encodeCborFFI(ffi_req_);")
      lines.add(
        "        if (ffi_enc_.isErr()) " & errFmt % [methRet, "ffi_enc_.error()"]
      )
      lines.add("        const auto& ffi_req_bytes_ = ffi_enc_.value();")
      var dispatcherExpr = "dispatcher_"
      if isStatic:
        lines.add("        auto ffi_dispatcher_ = staticDispatcher_();")
        lines.add(
          "        if (ffi_dispatcher_.isErr()) " &
            errFmt % [methRet, "ffi_dispatcher_.error()"]
        )
        dispatcherExpr = "ffi_dispatcher_.value()"
      lines.add(
        "        return $1->$2<$3>([&](std::uint64_t* ffi_id_) {" %
          [dispatcherExpr, (if isAsync: "callAsync" else: "call"), retCppType]
      )
      lines.add(
        "            return $1($2ffi_req_bytes_.data(), ffi_req_bytes_.size(), ffi_id_);" %
          [m.procName, ctxArg]
      )
      lines.add("        }, $1);" % [timeoutArg])
      lines.add("    }")
      lines.add("")

  lines.add(renderMemberDocComment(ShutdownDoc))
  lines.add(ContextShutdownTpl.replace("{{LIB}}", libName))

  lines.add("private:")
  emitEventDecoder(lines, events)
  lines.add("")
  lines.add(ContextStaticTpl.replace("{{LIB}}", libName))
  lines.add("    void* ptr_;")
  lines.add("    std::chrono::milliseconds timeout_;")
  # Shared with the dispatch thread, which outlives `this` when a listener destroys the context.
  lines.add("    std::shared_ptr<NimFfiDispatcher> dispatcher_;")
  # `create` starts the dispatch thread, once the waiter of the constructor's reply is in place.
  lines.add("    explicit $1(void* p, std::chrono::milliseconds t)" % [ctxTypeName])
  lines.add("        : ptr_(p), timeout_(t),")
  lines.add(
    "          dispatcher_(std::make_shared<NimFfiDispatcher>(&$1_poll, &$1_last_error, p, &$2::dispatchEvent_)) {}" %
      [libName, ctxTypeName]
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
