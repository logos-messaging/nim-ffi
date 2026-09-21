## Regression tests for the Rust type mapping: `nimTypeToRust` renders through
## the shared `parseFFIType` IR, so the full scalar set is pinned here.

import std/strutils
import unittest2
import ffi/codegen/[rust, meta]

suite "nimTypeToRust: scalar set":
  test "every scalar maps to its Rust primitive (the drift that regressed)":
    check nimTypeToRust("bool") == "bool"
    check nimTypeToRust("int8") == "i8"
    check nimTypeToRust("int16") == "i16"
    check nimTypeToRust("int32") == "i32"
    check nimTypeToRust("int") == "i64"
    check nimTypeToRust("int64") == "i64"
    check nimTypeToRust("uint8") == "u8"
    check nimTypeToRust("byte") == "u8"
    check nimTypeToRust("uint16") == "u16"
    check nimTypeToRust("uint32") == "u32"
    check nimTypeToRust("uint") == "u64"
    check nimTypeToRust("uint64") == "u64"
    check nimTypeToRust("float32") == "f32"
    check nimTypeToRust("float") == "f64"
    check nimTypeToRust("float64") == "f64"

suite "nimTypeToRust: strings, pointers and containers":
  test "string types render to String":
    check nimTypeToRust("string") == "String"
    check nimTypeToRust("cstring") == "String"

  test "seq[byte] rides as serde_bytes::ByteBuf (CBOR byte string) and ptr/pointer to the wire int":
    check nimTypeToRust("seq[byte]") == "serde_bytes::ByteBuf"
    check nimTypeToRust("seq[uint8]") == "serde_bytes::ByteBuf"
    check nimTypeToRust("ptr Foo") == RustPtrType
    check nimTypeToRust("pointer") == RustPtrType

  test "generics nest and Maybe aliases Option":
    check nimTypeToRust("seq[Option[int8]]") == "Vec<Option<i8>>"
    check nimTypeToRust("Maybe[uint16]") == "Option<u16>"
    check nimTypeToRust("seq[seq[byte]]") == "Vec<serde_bytes::ByteBuf>"
    check nimTypeToRust("Option[seq[byte]]") == "Option<serde_bytes::ByteBuf>"

  test "an unknown user type is capitalised, not mistaken for a scalar":
    check nimTypeToRust("echoRequest") == "EchoRequest"

suite "generateTypesRs: seq[byte] rides as a CBOR byte string":
  ## A struct with a `seq[byte]` field can be a `seq` element. For that shape the
  ## Rust backend wrote a `Vec<u8>` integer array (CBOR major type 4). The Nim
  ## decoder rejects that array with the error "value encoded in non-canonical
  ## form". ByteBuf makes ciborium write a byte string (major type 2), the same
  ## as every other backend.
  setup:
    let types = @[
      FFITypeMeta(
        name: "ServiceInfoEntry",
        fields: @[
          FFIFieldMeta(name: "id", typeName: "string"),
          FFIFieldMeta(name: "data", typeName: "seq[byte]"),
        ],
      ),
      FFITypeMeta(
        name: "CreateXprRequest",
        fields: @[FFIFieldMeta(name: "services", typeName: "seq[ServiceInfoEntry]")],
      ),
    ]
    let procs = @[
      FFIProcMeta(
        procName: "lib_create_xpr",
        libName: "lib",
        kind: FFIKind.FFI,
        libTypeName: "Lib",
        extraParams: @[FFIParamMeta(name: "req", typeName: "CreateXprRequest")],
        returnTypeName: "seq[byte]",
      )
    ]
    let rs = generateTypesRs(types, procs)

  test "a nested seq[byte] struct field becomes serde_bytes::ByteBuf":
    check "pub data: serde_bytes::ByteBuf," in rs
    check "pub data: Vec<u8>," notin rs

  test "the seq-of-struct wrapper stays a Vec of the struct":
    check "pub services: Vec<ServiceInfoEntry>," in rs

  test "Cargo.toml pulls in serde_bytes only when a type needs a byte string":
    check needsSerdeBytes(types, procs)
    check "serde_bytes = " in generateCargoToml("lib", needsBytes = true)
    check "serde_bytes = " notin generateCargoToml("lib", needsBytes = false)

  test "a byte-less registry keeps serde_bytes out of Cargo.toml":
    let plain = @[
      FFITypeMeta(
        name: "Plain", fields: @[FFIFieldMeta(name: "name", typeName: "string")]
      )
    ]
    check not needsSerdeBytes(plain, @[])
    check "serde_bytes" notin generateCargoToml("lib", needsSerdeBytes(plain, @[]))

suite "events arrive through <lib>_poll":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "lib_create", libName: "lib", kind: FFIKind.CTOR, libTypeName: "Lib"
      ),
      FFIProcMeta(
        procName: "lib_destroy", libName: "lib", kind: FFIKind.DTOR, libTypeName: "Lib"
      ),
    ]
    let events = @[
      FFIEventMeta(
        wireName: "on_echo_fired",
        nimProcName: "onEchoFired",
        libName: "lib",
        payloadTypeName: "EchoEvent",
        doc: "Fired once the reply is ready.",
      )
    ]
    let ffiRs = generateFFIRs(procs)
    let apiRs = generateApiRs(procs, "lib", events)

  test "ffi.rs declares poll and the message, not the listener registry":
    check "pub fn lib_poll(ctx: *mut c_void, timeout_ms: i32, msg: *mut *const NimFfiMsg) -> c_int;" in
      ffiRs
    check "pub fn lib_poll_fd(ctx: *mut c_void) -> isize;" in ffiRs
    check "pub struct NimFfiMsg {" in ffiRs
    check "_event_listener" notin ffiRs

  test "every event has a name id, a message variant and a typed listener":
    check "pub const LIB_EVT_ON_ECHO_FIRED: u64 = 0xcdfdf536356b2a2b;" in apiRs
    check "    /// Fired once the reply is ready.\n    OnEchoFired(EchoEvent)," in apiRs
    check "LIB_EVT_ON_ECHO_FIRED => decode_cbor(bytes).map(LibMessage::OnEchoFired)," in
      apiRs
    check "pub fn add_on_echo_fired_listener<F>(&self, handler: F) -> ListenerHandle" in
      apiRs
    check "struct Envelope" notin apiRs

  test "liveness and the end of the context have listeners too":
    check "NotResponding { reason: u64 }," in apiRs
    check "Closed { ok: bool, reason: String }," in apiRs
    for name in ["not_responding", "responding", "closed", "message"]:
      check ("pub fn add_" & name & "_listener<F>") in apiRs

  test "a library without a ctor gets no pump":
    let staticOnly = @[
      FFIProcMeta(
        procName: "lib_version",
        libName: "lib",
        kind: FFIKind.STATIC,
        libTypeName: "Lib",
        returnTypeName: "string",
      )
    ]
    check "pump_loop" notin generateApiRs(staticOnly, "lib")
