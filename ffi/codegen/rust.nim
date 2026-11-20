## Rust binding generator: emits a complete Rust crate using CBOR (ciborium).

import std/[strutils, sequtils]
import ./meta, ./string_helpers, ./types_ir, ./consts, ./build_paths, ../ret_codes

## Wire-format Rust type for any Nim `ptr T`/`pointer`; fixed 64-bit for a
## host-independent CBOR payload size (mirrors CppPtrType).
const RustPtrType* = "u64"

const
  CargoTomlTpl = staticRead("templates/rust/Cargo.toml.tpl")
  BuildRsTpl = staticRead("templates/rust/build.rs.tpl")
  LibRsTpl = staticRead("templates/rust/lib.rs.tpl")
  FfiPreludeTpl = staticRead("templates/rust/ffi_prelude.rs.tpl")
  FfiReverseTypesTpl = staticRead("templates/rust/ffi_reverse_types.rs.tpl")
  RuntimeTpl = staticRead("templates/rust/runtime.rs.tpl")
  EventTrampolineTpl = staticRead("templates/rust/event_trampoline.rs.tpl")
  ReverseCallTpl = staticRead("templates/rust/reverse_call.rs.tpl")
  ReverseReplyTpl = staticRead("templates/rust/reverse_reply.rs.tpl")
  ReverseReplyVoidTpl = staticRead("templates/rust/reverse_reply_void.rs.tpl")
  ReverseInvokeTpl = staticRead("templates/rust/reverse_invoke.rs.tpl")
  ReverseInvokeNoArgsTpl = staticRead("templates/rust/reverse_invoke_no_args.rs.tpl")
  CtxStructTpl = staticRead("templates/rust/ctx_struct.rs.tpl")
  CtxDropTpl = staticRead("templates/rust/ctx_drop.rs.tpl")
  CtxDropListenersTpl = staticRead("templates/rust/ctx_drop_listeners.rs.tpl")
  DispatchScopeTpl = staticRead("templates/rust/dispatch_scope.rs.tpl")
  CtorTpl = staticRead("templates/rust/ctor.rs.tpl")
  ListenerInnerTpl = staticRead("templates/rust/listener_inner.rs.tpl")
  ListenerApiTpl = staticRead("templates/rust/listener_api.rs.tpl")
  RemoveListenerTpl = staticRead("templates/rust/remove_listener.rs.tpl")
  ReverseSetImplTpl = staticRead("templates/rust/reverse_set_impl.rs.tpl")
  ReverseEmitTpl = staticRead("templates/rust/reverse_emit.rs.tpl")
  MethodSyncTpl = staticRead("templates/rust/method_sync.rs.tpl")
  MethodAsyncTpl = staticRead("templates/rust/method_async.rs.tpl")
  ShutdownTpl = staticRead("templates/rust/shutdown.rs.tpl")

func rustScalar(s: ScalarKind): string =
  case s
  of skBool: "bool"
  of skI8: "i8"
  of skI16: "i16"
  of skI32: "i32"
  of skI64: "i64"
  of skU8: "u8"
  of skU16: "u16"
  of skU32: "u32"
  of skU64: "u64"
  of skF32: "f32"
  of skF64: "f64"

func rustSeq(elem: string): string =
  "Vec<" & elem & ">"

func rustOpt(elem: string): string =
  "Option<" & elem & ">"

const rustMap = NativeTypeMap(
  scalar: rustScalar,
  str: "String",
  # serde encodes a plain Vec<u8> as a CBOR integer array, and Nim rejects that
  # array. ByteBuf gives the CBOR byte string that Nim decodes.
  bytes: "serde_bytes::ByteBuf",
  ptrType: RustPtrType,
  seqOf: rustSeq,
  optOf: rustOpt,
  structName: capitalizeFirstLetter,
)

proc nimTypeToRust*(typeName: string): string =
  ## Maps Nim type names to Rust type names, including generics.
  renderNative(rustMap, parseFFIType(typeName))

proc deriveLibName*(procs: seq[FFIProcMeta]): string {.compileTime.} =
  ## Common prefix before the first `_` in proc names, e.g. "timer_create" → "timer".
  if currentLibName().len > 0:
    return currentLibName()
  if procs.len == 0:
    return "unknown"
  let first = procs[0].procName
  let parts = first.split('_')
  if parts.len > 0:
    return parts[0]
  return "unknown"

proc stripLibPrefix*(procName: string, libName: string): string =
  ## Strips the library prefix, e.g. ("timer_echo", "timer") → "echo".
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc reqStructName(p: FFIProcMeta): string =
  ## Mirrors the Nim macro: <CamelCase(procName)>Req or CtorReq for ctors.
  let camel = snakeToPascalCase(p.procName)
  if p.kind == FFIKind.CTOR:
    camel & "CtorReq"
  else:
    camel & "Req"

func typeUsesBytes(typeName: string): bool =
  ## True if `typeName` is a `seq[byte]` at any depth of Seq or Option.
  var t = parseFFIType(typeName)
  while t.kind in {ftSeq, ftOpt}:
    t = t.elem
  t.kind == ftBytes

func needsSerdeBytes*(types: seq[FFITypeMeta], procs: seq[FFIProcMeta]): bool =
  ## True if a field, a parameter or a return type maps to `serde_bytes::ByteBuf`.
  ## `types` holds every struct. Thus a scan of the fields also finds the bytes
  ## in a nested struct.
  for t in types:
    for f in t.fields:
      if typeUsesBytes(f.typeName):
        return true
  for p in procs:
    for ep in p.extraParams:
      if typeUsesBytes(ep.typeName):
        return true
    if p.returnTypeName.len > 0 and typeUsesBytes(p.returnTypeName):
      return true
  false

proc generateCargoToml*(libName: string, needsBytes = false): string =
  # flume: callback channel (recv_timeout + recv_async), default-features off. tokio: only the async timeout.
  # Add serde_bytes only when a `seq[byte]` goes on the wire as a CBOR byte string.
  let serdeBytesDep = if needsBytes: "\nserde_bytes = \"0.11\"" else: ""
  return
    CargoTomlTpl.fillTpl(("{{LIB}}", libName), ("{{SERDE_BYTES_DEP}}", serdeBytesDep)) &
    "\n"

proc generateBuildRs*(libName: string, nimSrcRelPath: string): string =
  ## Generates build.rs that compiles the Nim library; nimSrcRelPath is relative
  ## to the crate directory.
  let escapedSrc = nimSrcRelPath.replace("\\", "\\\\")
  return BuildRsTpl.fillTpl(("{{NIM_SRC}}", escapedSrc), ("{{LIB}}", libName)) & "\n"

proc generateLibRs*(): string =
  return LibRsTpl

func reverseCallStruct(r: FFIReverseMeta): string =
  capitalizeFirstLetter(r.nimProcName) & "Call"

func reverseBoxStruct(r: FFIReverseMeta): string =
  capitalizeFirstLetter(r.nimProcName) & "ImplBox"

func reverseSnake(r: FFIReverseMeta): string =
  camelToSnakeCase(r.nimProcName)

func reverseArgsRust(r: FFIReverseMeta): string =
  ## "" when the interface takes no arguments.
  if r.argsTypeName.len == 0:
    ""
  else:
    nimTypeToRust(r.argsTypeName)

func reverseImplBound(r: FFIReverseMeta): string =
  ## The `Fn` trait of the host callable: `Fn(Call, Args)`, or `Fn(Call)` with no args.
  let argsRust = reverseArgsRust(r)
  if argsRust.len == 0:
    "Fn($1) + Send + Sync" % [reverseCallStruct(r)]
  else:
    "Fn($1, $2) + Send + Sync" % [reverseCallStruct(r), argsRust]

proc generateFFIRs*(
    procs: seq[FFIProcMeta],
    reverse: seq[FFIReverseMeta] = @[],
    reverseEvents: seq[FFIReverseEventMeta] = @[],
): string =
  ## Generates ffi.rs with extern "C" declarations; each proc takes one CBOR
  ## buffer (ptr+len) as its request payload.
  var lines: seq[string] = @[]
  lines.add(FfiPreludeTpl.fillTpl())
  lines.add("")

  var libNames: seq[string] = @[]
  for p in procs:
    if p.libName notin libNames:
      libNames.add(p.libName)

  var linkLibName = ""
  if libNames.len > 0 and libNames[0].len > 0:
    linkLibName = libNames[0]
  else:
    if procs.len > 0:
      let parts = procs[0].procName.split('_')
      if parts.len > 0:
        linkLibName = parts[0]

  lines.add("#[link(name = \"$1\")]" % [linkLibName])
  lines.add("extern \"C\" {")

  for p in procs:
    var params: seq[string] = @[]
    lines.add(renderMemberDocComment(p.doc))
    case p.kind
    of FFIKind.FFI, FFIKind.STATIC:
      if not p.isStatic():
        params.add("ctx: *mut c_void")
      params.add("callback: FFICallback")
      params.add("user_data: *mut c_void")
      params.add("req_cbor: *const u8")
      params.add("req_cbor_len: usize")
      lines.add("    pub fn $1($2) -> c_int;" % [p.procName, params.join(", ")])
    of FFIKind.CTOR:
      # Ctor: no ctx; returns the freshly-allocated handle.
      params.add("req_cbor: *const u8")
      params.add("req_cbor_len: usize")
      params.add("callback: FFICallback")
      params.add("user_data: *mut c_void")
      lines.add("    pub fn $1($2) -> *mut c_void;" % [p.procName, params.join(", ")])
    of FFIKind.DTOR:
      params.add("ctx: *mut c_void")
      lines.add("    pub fn $1($2) -> c_int;" % [p.procName, params.join(", ")])

  # Listener-registration ABI, always present in the dylib.
  lines.add(
    "    pub fn $1_add_event_listener(ctx: *mut c_void, event_name: *const c_char, callback: FFICallback, user_data: *mut c_void) -> u64;" %
      [linkLibName]
  )
  lines.add(
    "    pub fn $1_remove_event_listener(ctx: *mut c_void, listener_id: u64) -> c_int;" %
      [linkLibName]
  )
  lines.add(renderMemberDocComment(ShutdownDoc))
  lines.add("    pub fn $1_shutdown() -> c_int;" % [linkLibName])

  # Reverse FFI: host-implemented interfaces + host-emitted events.
  if reverse.len > 0:
    for r in reverse:
      lines.add(
        "    pub fn $1_set_$2_impl(ctx: *mut c_void, imp: Option<FFIReverseImpl>, user_data: *mut c_void, release: Option<FFIReverseRelease>) -> c_int;" %
          [linkLibName, r.wireName]
      )
    lines.add(
      "    pub fn $1_reverse_reply(ctx: *mut c_void, call_id: u64, ret_code: c_int, reply_cbor: *const u8, reply_len: usize) -> c_int;" %
        [linkLibName]
    )
  for rev in reverseEvents:
    lines.add(
      "    pub fn $1_emit_$2(ctx: *mut c_void, payload_cbor: *const u8, payload_len: usize) -> c_int;" %
        [linkLibName, rev.wireName]
    )

  lines.add("}")

  if reverse.len > 0:
    lines.add("")
    lines.add(FfiReverseTypesTpl.fillTpl())

  return lines.join("\n") & "\n"

func rustConstType(typeName: string): string =
  ## `&str` rather than `String`: a `pub const` can't own a heap value. The
  ## 'static lifetime is implied, and spelling it out trips clippy.
  let t = parseFFIType(typeName)
  if t.kind == ftStr:
    return "&str"
  return renderNative(rustMap, t)

proc generateTypesRs*(
    types: seq[FFITypeMeta], procs: seq[FFIProcMeta], consts: seq[FFIConstMeta] = @[]
): string =
  ## Generates types.rs: Rust structs for user FFI types and each per-proc Req.
  var lines: seq[string] = @[]
  lines.add("use serde::{Deserialize, Serialize};")
  lines.add("")

  for c in consts:
    let t = parseFFIType(c.typeName)
    lines.add(
      "pub const $1: $2 = $3;" % [
        identToUpperSnake(c.name), rustConstType(c.typeName), rustConstValue(t, c.value)
      ]
    )
  if consts.len > 0:
    lines.add("")

  for t in types:
    if not t.isEnum():
      continue
    lines.add("#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]")
    lines.add("pub enum $1 {" % [t.name])
    for v in t.enumValues:
      let variant = capitalizeFirstLetter(v.name)
      # serde carries the same text form Nim's cbor_serialization writes.
      if variant != v.wire:
        lines.add("    #[serde(rename = \"$1\")]" % [v.wire])
      lines.add("    $1," % [variant])
    lines.add("}")
    lines.add("")

  for t in types:
    if t.isEnum():
      continue
    lines.add("#[derive(Debug, Clone, Serialize, Deserialize)]")
    lines.add("pub struct $1 {" % [t.name])
    for f in t.fields:
      let snakeName = camelToSnakeCase(f.name)
      let rustType = nimTypeToRust(f.typeName)
      # serde rename when camelCase differs from snake_case.
      if snakeName != f.name:
        lines.add("    #[serde(rename = \"$1\")]" % [f.name])
      lines.add("    pub $1: $2," % [snakeName, rustType])
    lines.add("}")
    lines.add("")

  # Per-proc Req structs: the unit of CBOR encoding sent across the boundary.
  for p in procs:
    if p.kind == FFIKind.DTOR:
      continue
    let reqName = reqStructName(p)
    lines.add("#[derive(Debug, Clone, Serialize, Deserialize)]")
    if p.extraParams.len == 0:
      lines.add("pub struct $1 {}" % [reqName])
    else:
      lines.add("pub struct $1 {" % [reqName])
      for ep in p.extraParams:
        let snake = camelToSnakeCase(ep.name)
        let rustType =
          if ep.ridesAsPtr():
            RustPtrType
          else:
            nimTypeToRust(ep.typeName)
        if snake != ep.name:
          lines.add("    #[serde(rename = \"$1\")]" % [ep.name])
        lines.add("    pub $1: $2," % [snake, rustType])
      lines.add("}")
    lines.add("")

  return lines.join("\n")

proc rustParamDecls(params: seq[FFIParamMeta]): seq[string] =
  var decls: seq[string] = @[]
  for ep in params:
    let rustType =
      if ep.ridesAsPtr():
        RustPtrType
      else:
        nimTypeToRust(ep.typeName)
    decls.add("$1: $2" % [camelToSnakeCase(ep.name), rustType])
  return decls

proc reqLiteral(reqName: string, params: seq[FFIParamMeta]): string =
  if params.len == 0:
    return reqName & " {}"
  return reqName & " { " & params.mapIt(camelToSnakeCase(it.name)).join(", ") & " }"

func docBlock(doc: string): string =
  ## `doc` as `///` lines, each newline-ended, for a `{{DOC}}` that leads a line.
  var rendered = ""
  for line in renderMemberDocComment(doc):
    rendered.add(line & "\n")
  return rendered

proc emitReverseCall(lines: var seq[string], libName: string, r: FFIReverseMeta) =
  let reply =
    if r.replyTypeName.len > 0:
      ReverseReplyTpl.fillTpl(
        ("{{REPLY_TYPE}}", nimTypeToRust(r.replyTypeName)),
        ("{{WIRE}}", r.wireName),
        ("{{LIB}}", libName),
      )
    else:
      ReverseReplyVoidTpl.fillTpl(("{{WIRE}}", r.wireName), ("{{LIB}}", libName))
  let argsRust = reverseArgsRust(r)
  let invoke =
    if argsRust.len == 0:
      ReverseInvokeNoArgsTpl.fillTpl()
    else:
      ReverseInvokeTpl.fillTpl(("{{ARGS}}", argsRust))
  lines.add(
    ReverseCallTpl.fillTpl(
      ("{{WIRE}}", r.wireName),
      ("{{CALL}}", reverseCallStruct(r)),
      ("{{BOX}}", reverseBoxStruct(r)),
      ("{{BOUND}}", reverseImplBound(r)),
      ("{{SNAKE}}", reverseSnake(r)),
      ("{{LIB}}", libName),
      ("{{REPLY}}", reply),
      ("{{INVOKE}}", invoke),
    )
  )
  lines.add("")

proc generateApiRs*(
    procs: seq[FFIProcMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
    reverse: seq[FFIReverseMeta] = @[],
    reverseEvents: seq[FFIReverseEventMeta] = @[],
): string =
  ## Generates api.rs with a blocking and a tokio-async high-level API.
  ## Requests/responses are CBOR (ciborium); errors are raw UTF-8 strings.
  var lines: seq[string] = @[]

  let classified = classifyProcs(procs)
  let ctors = classified.ctors
  let dtorProcName = classified.dtorProcName

  var libTypeName = ""
  if ctors.len > 0:
    libTypeName = ctors[0].libTypeName
  else:
    libTypeName = capitalizeFirstLetter(libName)

  let ctxTypeName = libTypeName & "Ctx"

  let retCodes =
    if reverse.len > 0 or reverseEvents.len > 0:
      rustRetCodeConsts() & "\n\n" & rustRetNameFn()
    else:
      rustRetCodeConsts()
  lines.add(RuntimeTpl.fillTpl(("// {{RET_CODES}}", retCodes)))
  lines.add("")

  # `listeners` keeps each Box alive; its raw pointer is the per-event `user_data`.
  if events.len > 0:
    # The outermost trampoline on a thread drops the boxes removed inside its dispatch.
    lines.add(DispatchScopeTpl.fillTpl())
    lines.add("")
    for ev in events:
      lines.add(
        EventTrampolineTpl.fillTpl(
          ("{{EVENT_SNAKE}}", camelToSnakeCase(ev.nimProcName)),
          ("{{EVENT}}", capitalizeFirstLetter(ev.nimProcName)),
          ("{{PAYLOAD}}", ev.payloadTypeName),
        )
      )
      lines.add("")

    lines.add("#[derive(Debug, Clone, Copy)]")
    lines.add("pub struct ListenerHandle { pub id: u64 }")
    lines.add("")

  for r in reverse:
    lines.emitReverseCall(libName, r)

  let callsTypeName = libTypeName & "Calls"
  let listenersField =
    if events.len > 0:
      "\n    listeners: std::sync::Mutex<std::collections::HashMap<u64, Box<dyn std::any::Any + Send>>>,"
    else:
      ""
  lines.add(
    CtxStructTpl.fillTpl(
      ("{{LIB_TYPE}}", libTypeName),
      ("{{CTX}}", ctxTypeName),
      ("{{CALLS}}", callsTypeName),
      ("{{LISTENERS_FIELD}}", listenersField),
    )
  )
  lines.add("")

  # `listeners` drops after `drop` returns, when the dylib has joined its threads.
  if dtorProcName.len > 0:
    # A failed destroy leaves the event thread live, and it still holds each box as user_data.
    let dtorTpl = if events.len > 0: CtxDropListenersTpl else: CtxDropTpl
    lines.add(dtorTpl.fillTpl(("{{CTX}}", ctxTypeName), ("{{DTOR}}", dtorProcName)))
    lines.add("")

  lines.add("impl $1 {" % [ctxTypeName])

  var selfExtras: seq[string] = @[]
  if events.len > 0:
    selfExtras.add("listeners: std::sync::Mutex::new(std::collections::HashMap::new())")
  let callsInit =
    "calls: $1 { ptr: addr as *mut c_void, timeout: Some(timeout), progress: None, _ctx: std::marker::PhantomData }" %
    [callsTypeName]
  let selfInit =
    "        Ok(Self { ptr: addr as *mut c_void, timeout, " & callsInit &
    (if selfExtras.len > 0: ", " & selfExtras.join(", ") else: "") & " })"

  for ctor in ctors:
    let paramsList = rustParamDecls(ctor.extraParams)
    # `create` and `new_async` take an explicit `timeout: Duration` that flows into `self.timeout` so subsequent method calls inherit it.
    let ctorParamsStr =
      if paramsList.len > 0:
        paramsList.join(", ") & ", timeout: Duration"
      else:
        "timeout: Duration"

    # The callback delivers the ctx address as a CBOR text string; the ctor's return value goes unused.
    lines.add(
      CtorTpl.fillTpl(
        ("{{DOC}}", docBlock(ctor.doc)),
        ("{{PARAMS}}", ctorParamsStr),
        ("{{REQ}}", reqLiteral(reqStructName(ctor), ctor.extraParams)),
        ("{{PROC}}", ctor.procName),
        ("{{SELF_INIT}}", selfInit),
      )
    )
    lines.add("")

  if events.len > 0:
    lines.add(ListenerInnerTpl.fillTpl(("{{LIB}}", libName)))
    lines.add("")

    for ev in events:
      lines.add(
        ListenerApiTpl.fillTpl(
          ("{{DOC}}", docBlock(ev.doc)),
          ("{{WIRE}}", ev.wireName),
          ("{{EVENT_SNAKE}}", camelToSnakeCase(ev.nimProcName)),
          ("{{EVENT}}", capitalizeFirstLetter(ev.nimProcName)),
          ("{{PAYLOAD}}", ev.payloadTypeName),
        )
      )
      lines.add("")

    lines.add(
      RemoveListenerTpl.fillTpl(
        ("{{DOC}}", docBlock(DeferredRemoveListenerDoc)), ("{{LIB}}", libName)
      )
    )
    lines.add("")

  for r in reverse:
    var doc = docBlock(r.doc)
    if reverseArgsRust(r).len > 0:
      doc.add(
        "    /// The closure runs on a reverse worker and owns its arguments, so a deferred\n" &
          "    /// reply can move them to another thread.\n"
      )
    lines.add(
      ReverseSetImplTpl.fillTpl(
        ("{{DOC}}", doc),
        ("{{SNAKE}}", reverseSnake(r)),
        ("{{BOUND}}", reverseImplBound(r)),
        ("{{BOX}}", reverseBoxStruct(r)),
        ("{{LIB}}", libName),
        ("{{WIRE}}", r.wireName),
      )
    )
    lines.add("")
  for rev in reverseEvents:
    let params = rustParamDecls(rev.params)
    let paramsStr =
      if params.len > 0:
        "&self, " & params.join(", ")
      else:
        "&self"
    lines.add(
      ReverseEmitTpl.fillTpl(
        ("{{DOC}}", docBlock(rev.doc)),
        ("{{NAME}}", camelToSnakeCase(rev.nimProcName)),
        ("{{PARAMS}}", paramsStr),
        ("{{REQ}}", reqLiteral(rev.reqTypeName, rev.params)),
        ("{{LIB}}", libName),
        ("{{WIRE}}", rev.wireName),
      )
    )
    lines.add("")

  # A static is an associated fn: no `&self` to read `timeout` from, so it takes one.
  var callsBody: seq[string] = @[]
  for m in classified.replyProcs():
    let isStatic = m.isStatic()
    var paramsList = rustParamDecls(m.extraParams)
    if isStatic:
      paramsList.add("timeout: Duration")
    let paramsStr =
      if isStatic:
        paramsList.join(", ")
      elif paramsList.len > 0:
        "&self, " & paramsList.join(", ")
      else:
        "&self"

    let retTypeForApi =
      if m.returnRidesAsPtr():
        RustPtrType
      else:
        nimTypeToRust(m.returnTypeName)
    let common = [
      ("{{DOC}}", docBlock(m.doc)),
      ("{{NAME}}", stripLibPrefix(m.procName, libName)),
      ("{{PARAMS}}", paramsStr),
      ("{{RET}}", retTypeForApi),
      ("{{REQ}}", reqLiteral(reqStructName(m), m.extraParams)),
      ("{{PROC}}", m.procName),
      ("{{TIMEOUT}}", if isStatic: "Some(timeout)" else: "self.timeout"),
      ("{{PROGRESS}}", if isStatic: "None" else: "self.progress.clone()"),
    ]

    # Statics stay associated fns of the ctx; instance methods live on the calls view.
    var blk: seq[string] = @[]
    blk.add(
      MethodSyncTpl.fillTpl(
        @common & ("{{CTX_ARG}}", if isStatic: "" else: "self.ptr, ")
      )
    )
    blk.add("")

    # The ptr rides as usize (Copy + Send), so the future is Send on a multi-threaded runtime.
    blk.add(
      MethodAsyncTpl.fillTpl(
        @common &
          @[
            ("{{CTX_ARG}}", if isStatic: "" else: "ptr as *mut c_void, "),
            (
              "{{PTR_COPY}}",
              if isStatic: "" else: "        let ptr = self.ptr as usize;\n",
            ),
          ]
      )
    )
    blk.add("")
    if isStatic:
      lines.add(blk)
    else:
      callsBody.add(blk)

  # An associated fn, not a method: a host calls it with no context left to call it on.
  lines.add(
    ShutdownTpl.fillTpl(("{{DOC}}", docBlock(ShutdownDoc)), ("{{LIB}}", libName))
  )
  lines.add("")

  lines.add("}")
  lines.add("")
  if callsBody.len > 0:
    lines.add("impl $1<'_> {" % [callsTypeName])
    lines.add(callsBody)
    lines.add("}")
  return lines.join("\n") & "\n"

proc generateRustCrate*(
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
  ## Generates a complete Rust crate in outputDir.
  ensureOutputDir(outputDir)
  let srcDir = buildPath(outputDir, "src")
  ensureOutputDir(srcDir)

  writeOutputFile(
    buildPath(outputDir, "Cargo.toml"),
    generateCargoToml(libName, needsSerdeBytes(types, procs)),
  )
  writeOutputFile(
    buildPath(outputDir, "build.rs"), generateBuildRs(libName, nimSrcRelPath)
  )
  writeOutputFile(buildPath(srcDir, "lib.rs"), generateLibRs())
  writeOutputFile(
    buildPath(srcDir, "ffi.rs"), generateFFIRs(procs, reverse, reverseEvents)
  )
  writeOutputFile(buildPath(srcDir, "types.rs"), generateTypesRs(types, procs, consts))
  writeOutputFile(
    buildPath(srcDir, "api.rs"),
    generateApiRs(procs, libName, events, reverse, reverseEvents),
  )
