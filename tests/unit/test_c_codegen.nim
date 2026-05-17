## Unit tests for the pure-C binding generator at `ffi/codegen/c.nim`.
##
## The generator is a pure-input → pure-output function: it takes the
## compile-time `FFIProcMeta` / `FFITypeMeta` registries plus a library
## name and returns a header string. That makes it straightforward to
## drive without touching the runtime — these tests construct synthetic
## metadata and assert structural properties on the emitted text.

import std/[unittest, strutils]
import ../../ffi/codegen/[meta, c]

suite "nimTypeToC":
  test "primitives map to their fixed-width C names":
    check nimTypeToC("int") == "int64_t"
    check nimTypeToC("int64") == "int64_t"
    check nimTypeToC("int32") == "int32_t"
    check nimTypeToC("int16") == "int16_t"
    check nimTypeToC("int8") == "int8_t"
    check nimTypeToC("uint") == "uint64_t"
    check nimTypeToC("uint32") == "uint32_t"
    check nimTypeToC("uint8") == "uint8_t"
    check nimTypeToC("bool") == "bool"
    check nimTypeToC("float") == "float"
    check nimTypeToC("float64") == "double"
    check nimTypeToC("pointer") == "void*"

  test "strings collapse to const char*":
    check nimTypeToC("string") == "const char*"
    check nimTypeToC("cstring") == "const char*"

  test "ptr T becomes void* (opaque)":
    check nimTypeToC("ptr Foo") == "void*"

  test "seq[T] returns the __SEQ__ sentinel for two-field expansion":
    check nimTypeToC("seq[int]").startsWith("__SEQ__")
    check nimTypeToC("seq[int]") == "__SEQ__int64_t"
    check nimTypeToC("seq[string]") == "__SEQ__const char*"

  test "Option[T] becomes nullable const ptr without double-const":
    check nimTypeToC("Option[int]") == "const int64_t*"
    check nimTypeToC("Option[string]") == "const char**"
    check nimTypeToC("Maybe[int64]") == "const int64_t*"

  test "user-declared struct names pass through":
    check nimTypeToC("EchoRequest") == "EchoRequest"

suite "isPrimitiveC":
  test "matches PODs and rejects user types":
    check isPrimitiveC("int")
    check isPrimitiveC("bool")
    check isPrimitiveC("float64")
    check isPrimitiveC("pointer")
    check not isPrimitiveC("string")
    check not isPrimitiveC("EchoRequest")
    check not isPrimitiveC("seq[int]")

suite "reqStructName / respStructName":
  test "mirror the per-proc naming convention used by the macro":
    let ctorMeta = FFIProcMeta(
      procName: "timer_create",
      kind: FFIKind.CTOR,
      libName: "timer",
      libTypeName: "Timer",
      extraParams: @[],
      returnTypeName: "Timer",
    )
    let methodMeta = FFIProcMeta(
      procName: "timer_echo",
      kind: FFIKind.FFI,
      libName: "timer",
      libTypeName: "Timer",
      extraParams: @[],
      returnTypeName: "EchoResponse",
    )
    check reqStructName(ctorMeta) == "TimerCreateCtorReq"
    check reqStructName(methodMeta) == "TimerEchoReq"
    check respStructName(methodMeta) == "TimerEchoResp"

suite "generateCHeader":
  setup:
    let types = @[
      FFITypeMeta(
        name: "TimerConfig", fields: @[FFIFieldMeta(name: "name", typeName: "string")]
      ),
      FFITypeMeta(
        name: "EchoRequest",
        fields: @[
          FFIFieldMeta(name: "message", typeName: "string"),
          FFIFieldMeta(name: "delayMs", typeName: "int"),
        ],
      ),
      FFITypeMeta(
        name: "EchoResponse",
        fields: @[FFIFieldMeta(name: "echoed", typeName: "string")],
      ),
      FFITypeMeta(
        name: "ComplexRequest",
        fields: @[
          FFIFieldMeta(name: "messages", typeName: "seq[EchoRequest]"),
          FFIFieldMeta(name: "note", typeName: "Option[string]"),
        ],
      ),
    ]
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        kind: FFIKind.CTOR,
        libName: "timer",
        libTypeName: "Timer",
        extraParams: @[FFIParamMeta(name: "config", typeName: "TimerConfig")],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_version",
        kind: FFIKind.FFI,
        libName: "timer",
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "string",
      ),
      FFIProcMeta(
        procName: "timer_echo",
        kind: FFIKind.FFI,
        libName: "timer",
        libTypeName: "Timer",
        extraParams: @[FFIParamMeta(name: "req", typeName: "EchoRequest")],
        returnTypeName: "EchoResponse",
      ),
      FFIProcMeta(
        procName: "timer_destroy",
        kind: FFIKind.DTOR,
        libName: "timer",
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "",
      ),
    ]
    let header = generateCHeader(procs, types, "timer")

  test "header begins with the prelude (no CBOR symbols)":
    check header.contains("#pragma once")
    check header.contains("typedef void (*FfiCallback)")
    check not header.contains("nlohmann")
    check not header.contains("cbor")
    check not header.contains("tinycbor")

  test "user types are emitted as typedef structs in declaration order":
    let cfgIdx = header.find("typedef struct TimerConfig {")
    let echoReqIdx = header.find("typedef struct EchoRequest {")
    let echoRespIdx = header.find("typedef struct EchoResponse {")
    check cfgIdx > 0
    check echoReqIdx > cfgIdx
    check echoRespIdx > echoReqIdx

  test "string fields are emitted as const char*":
    check header.contains("const char* name;")
    check header.contains("const char* message;")
    check header.contains("int64_t delayMs;")

  test "seq[T] expands into items+len fields without double const":
    check header.contains("const EchoRequest* messages;")
    check header.contains("size_t messages_len;")
    # double-const regression guard
    check not header.contains("const const")

  test "Option[T] for a string is const char**":
    check header.contains("const char** note;")

  test "per-proc Req structs follow the naming convention":
    check header.contains("typedef struct TimerCreateCtorReq {")
    check header.contains("typedef struct TimerVersionReq {")
    check header.contains("typedef struct TimerEchoReq {")
    # dtor has no Req struct
    check not header.contains("TimerDestroyReq")

  test "version's empty Req gets a single placeholder field":
    let head = header.find("typedef struct TimerVersionReq {")
    let tail = header.find("} TimerVersionReq;")
    check head > 0 and tail > head
    let body = header[head .. tail]
    check body.contains("uint8_t _placeholder;")

  test "per-proc Resp structs are emitted for FFI methods only":
    check header.contains("typedef struct TimerVersionResp {")
    check header.contains("typedef struct TimerEchoResp {")
    # No Resp for ctor or dtor
    check not header.contains("TimerCreateCtorResp")
    check not header.contains("TimerDestroyResp")

  test "extern function signatures match the C-target ABI":
    check header.contains(
      "void* timer_create(const TimerCreateCtorReq* req, " &
        "FfiCallback cb, void* user_data);"
    )
    check header.contains(
      "int timer_echo(void* ctx, FfiCallback cb, void* user_data, " &
        "const TimerEchoReq* req);"
    )
    check header.contains("int timer_destroy(void* ctx);")

  test "extern \"C\" guards wrap the body for C++ callers":
    check header.contains("#ifdef __cplusplus\nextern \"C\" {")
    check header.contains("} /* extern \"C\" */")

suite "generateCCMakeLists":
  test "substitutes lib name and source-path placeholders":
    let cm = generateCCMakeLists("my_timer", "../timer.nim")
    check cm.contains("project(my_timer_c_bindings C)")
    check cm.contains("lib{{LIB}}".replace("{{LIB}}", "my_timer"))
    check cm.contains("-d:ffiMode=raw")
    check cm.contains("-d:ffiLang=cpp")

# ───────────────────────────────────────────────────────────────────────────
# ABI-hash content addressing — content of the hash, plus the header's
# hash-suffixed symbol + clean-name `#define` emission.
# ───────────────────────────────────────────────────────────────────────────
proc hashFor(
    name: string, params: seq[FFIParamMeta], ret: string
): string {.compileTime.} =
  return abiHashFor(name, params, ret)

const baselineHash =
  hashFor("foo", @[FFIParamMeta(name: "a", typeName: "int")], "string")
const baselineHashAgain =
  hashFor("foo", @[FFIParamMeta(name: "a", typeName: "int")], "string")
const addedParamHash = hashFor(
  "foo",
  @[FFIParamMeta(name: "a", typeName: "int"), FFIParamMeta(name: "b", typeName: "int")],
  "string",
)
const renamedParamHash =
  hashFor("foo", @[FFIParamMeta(name: "x", typeName: "int")], "string")
const retypedParamHash =
  hashFor("foo", @[FFIParamMeta(name: "a", typeName: "int32")], "string")
const renamedProcHash =
  hashFor("bar", @[FFIParamMeta(name: "a", typeName: "int")], "string")
const changedRetHash =
  hashFor("foo", @[FFIParamMeta(name: "a", typeName: "int")], "int")

suite "abiHashFor":
  test "is stable across invocations":
    check baselineHash == baselineHashAgain

  test "is 7 hex chars":
    check baselineHash.len == AbiHashPrefixLen
    for c in baselineHash:
      check c in '0' .. 'f'

  test "changes when a new param is added":
    check baselineHash != addedParamHash

  test "changes when a param is renamed":
    check baselineHash != renamedParamHash

  test "changes when a param's type changes":
    check baselineHash != retypedParamHash

  test "changes when the proc itself is renamed":
    check baselineHash != renamedProcHash

  test "changes when the return type changes":
    check baselineHash != changedRetHash

suite "generateCHeader — abiHash emission":
  setup:
    let procsHashed = @[
      FFIProcMeta(
        procName: "timer_create",
        kind: FFIKind.CTOR,
        libName: "timer",
        libTypeName: "Timer",
        extraParams: @[FFIParamMeta(name: "config", typeName: "TimerConfig")],
        returnTypeName: "Timer",
        abiHash: "1a2b3c4",
      ),
      FFIProcMeta(
        procName: "timer_echo",
        kind: FFIKind.FFI,
        libName: "timer",
        libTypeName: "Timer",
        extraParams: @[FFIParamMeta(name: "req", typeName: "EchoRequest")],
        returnTypeName: "EchoResponse",
        abiHash: "deadbee",
      ),
      FFIProcMeta(
        procName: "timer_destroy",
        kind: FFIKind.DTOR,
        libName: "timer",
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "",
        abiHash: "",
      ), # dtor signature invariant — no hash
    ]
    let typesH = @[
      FFITypeMeta(
        name: "TimerConfig", fields: @[FFIFieldMeta(name: "name", typeName: "string")]
      ),
      FFITypeMeta(
        name: "EchoRequest",
        fields: @[FFIFieldMeta(name: "message", typeName: "string")],
      ),
      FFITypeMeta(
        name: "EchoResponse",
        fields: @[FFIFieldMeta(name: "echoed", typeName: "string")],
      ),
    ]
    let header = generateCHeader(procsHashed, typesH, "timer")

  test "ffi proc declares the versioned symbol":
    check header.contains(
      "int timer_echo_vdeadbee(void* ctx, FfiCallback cb, void* user_data, " &
        "const TimerEchoReq* req);"
    )

  test "ctor declares the versioned symbol":
    check header.contains("void* timer_create_v1a2b3c4(const TimerCreateCtorReq* req,")

  test "clean-name `#define` is emitted for hashed procs":
    check header.contains("#define timer_echo timer_echo_vdeadbee")
    check header.contains("#define timer_create timer_create_v1a2b3c4")

  test "dtor stays unsuffixed (signature is invariant)":
    check header.contains("int timer_destroy(void* ctx);")
    check not header.contains("#define timer_destroy")
