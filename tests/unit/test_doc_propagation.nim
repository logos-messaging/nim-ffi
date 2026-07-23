## FFIProcMeta.doc → each target's comment syntax. Extraction: test_doc_extraction.nim.

import std/strutils
import unittest2
import ffi/codegen/[meta, c, cpp, rust, cddl]

const
  CtorDoc = "Builds a widget from `config`."
  MethodDoc = "Echoes `req` back.\nSecond line."
  DtorDoc = "Releases the widget."
  EventDoc = "Fires once the echo lands."
  ScalarDoc = "Adds two numbers, no CBOR in sight."

let types = @[
  FFITypeMeta(
    name: "EchoRequest", fields: @[FFIFieldMeta(name: "message", typeName: "string")]
  ),
  FFITypeMeta(
    name: "EchoResponse", fields: @[FFIFieldMeta(name: "echoed", typeName: "string")]
  ),
]

let procs = @[
  FFIProcMeta(
    procName: "widget_create",
    libName: "widget",
    kind: FFIKind.CTOR,
    libTypeName: "Widget",
    extraParams: @[FFIParamMeta(name: "config", typeName: "EchoRequest")],
    returnTypeName: "Widget",
    doc: CtorDoc,
  ),
  FFIProcMeta(
    procName: "widget_echo",
    libName: "widget",
    kind: FFIKind.FFI,
    libTypeName: "Widget",
    extraParams: @[FFIParamMeta(name: "req", typeName: "EchoRequest")],
    returnTypeName: "EchoResponse",
    doc: MethodDoc,
  ),
  FFIProcMeta(
    procName: "widget_destroy",
    libName: "widget",
    kind: FFIKind.DTOR,
    libTypeName: "Widget",
    returnTypeName: "",
    doc: DtorDoc,
  ),
]

let events = @[
  FFIEventMeta(
    wireName: "on_echoed",
    nimProcName: "onEchoed",
    libName: "widget",
    payloadTypeName: "EchoResponse",
    doc: EventDoc,
  )
]

let undocumented = block:
  var stripped = procs
  for p in stripped.mitems:
    p.doc = ""
  stripped

func withoutDocLines(s: string): string =
  ## Drops `///` lines by content, so a generator's own hardcoded ones survive.
  var rendered: seq[string] = @[]
  for doc in [CtorDoc, MethodDoc, DtorDoc]:
    for line in doc.splitLines():
      rendered.add(("/// " & line).strip())
  var kept: seq[string] = @[]
  for line in s.splitLines():
    if line.strip() notin rendered:
      kept.add(line)
  return kept.join("\n")

proc checkNoDocText(rendered: string) =
  for doc in [CtorDoc, MethodDoc, DtorDoc]:
    for line in doc.splitLines():
      check line notin rendered

suite "doc comments reach the C header":
  setup:
    let header = generateCLibHeader(procs, types, "widget")

  test "the exported symbol carries the doc":
    check "/** " & CtorDoc & " */\nvoid* widget_create(" in header

  test "the high-level wrapper carries the doc":
    check "/** " & CtorDoc & " */\nstatic inline int widget_ctx_create(" in header
    check "/** " & DtorDoc & " */\nstatic inline int widget_ctx_destroy(" in header

  test "a multi-line doc becomes a star block":
    check "/**\n * Echoes `req` back.\n * Second line.\n */\nstatic inline int widget_ctx_echo(" in
      header

  test "the listener registration carries the event's doc":
    let withEvents = generateCLibHeader(procs, types, "widget", events)
    check "/** " & EventDoc &
      " */\nstatic inline uint64_t widget_ctx_add_on_echoed_listener(" in withEvents

  test "an undocumented registry leaks no doc text":
    checkNoDocText(generateCLibHeader(undocumented, types, "widget"))

suite "doc comments reach the abi = c header":
  setup:
    var abiProcs = procs
    abiProcs.add(
      FFIProcMeta(
        procName: "widget_add",
        libName: "widget",
        kind: FFIKind.FFI,
        libTypeName: "Widget",
        extraParams: @[
          FFIParamMeta(name: "a", typeName: "int"),
          FFIParamMeta(name: "b", typeName: "int"),
        ],
        returnTypeName: "int",
        scalarFastPath: true,
        doc: ScalarDoc,
      )
    )
    for p in abiProcs.mitems:
      p.abiFormat = ABIFormat.C
    var abiTypes = types
    for t in abiTypes.mitems:
      t.abiFormat = ABIFormat.C
    let header = generateCAbiLibHeader(abiProcs, abiTypes, "widget")

  test "the exported symbol carries the doc":
    check "/** " & CtorDoc & " */\nvoid* widget_create(" in header

  test "the high-level wrapper carries the doc":
    check "/** " & CtorDoc & " */\nstatic inline int widget_ctx_create(" in header
    check "/** " & DtorDoc & " */\nstatic inline int widget_ctx_destroy(" in header

  test "the scalar fast path carries the doc":
    check "/** " & ScalarDoc & " */\nstatic inline int widget_ctx_add(" in header

suite "doc comments reach the C++ header":
  setup:
    let header = generateCppHeader(procs, types, "widget")

  test "the extern \"C\" declaration carries the doc":
    check "/** " & CtorDoc & " */\nvoid* widget_create(" in header

  test "class members carry an indented /// doc":
    check "    /// " & CtorDoc &
      "\n    static Result<std::unique_ptr<WidgetCtx>> create(" in header
    check "    /// Echoes `req` back.\n    /// Second line.\n    Result<EchoResponse> echo(" in
      header

  test "the async variant repeats the doc":
    check "    /// Echoes `req` back.\n    /// Second line.\n    std::future<Result<EchoResponse>> echoAsync(" in
      header

  test "the listener registration carries the event's doc":
    check "    /// " & EventDoc & "\n    ListenerHandle addOnEchoedListener(" in
      generateCppHeader(procs, types, "widget", events)

  test "an undocumented registry leaks no doc text":
    checkNoDocText(generateCppHeader(undocumented, types, "widget"))

suite "doc comments reach the Rust bindings":
  test "the extern \"C\" block carries the doc":
    let ffiRs = generateFFIRs(procs)
    check "    /// " & CtorDoc & "\n    pub fn widget_create(" in ffiRs
    check "    /// Echoes `req` back.\n    /// Second line.\n    pub fn widget_echo(" in
      ffiRs

  test "the high-level api carries the doc":
    let apiRs = generateApiRs(procs, "widget")
    check "    /// " & CtorDoc & "\n    pub fn create(" in apiRs
    check "    /// Echoes `req` back.\n    /// Second line.\n    pub fn echo(" in apiRs
    check "    /// Echoes `req` back.\n    /// Second line.\n    pub async fn echo_async(" in
      apiRs

  test "the listener registration carries the event's doc above the generated one":
    check "    /// " & EventDoc & "\n    /// Register a typed listener for `on_echoed`" in
      generateApiRs(procs, "widget", events)

  test "docs are purely additive — stripping them reproduces the undocumented output":
    check withoutDocLines(generateFFIRs(procs)) == generateFFIRs(undocumented)
    check withoutDocLines(generateApiRs(procs, "widget")) ==
      generateApiRs(undocumented, "widget")

suite "doc comments reach the CDDL schema":
  test "each documented rule gets a `;` comment under its header":
    let schema = generateCddlSchema(procs, types, "widget", "widget.nim")
    check "; widget_create (ctor)\n; " & CtorDoc & "\n" in schema
    check "; widget_echo (ffi)\n; Echoes `req` back.\n; Second line.\n" in schema
    check "; widget_destroy (dtor)\n; " & DtorDoc & "\n" in schema
