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

  test "a library with only statics gets the static pump and no listeners":
    let staticOnly = @[
      FFIProcMeta(
        procName: "lib_version",
        libName: "lib",
        kind: FFIKind.STATIC,
        libTypeName: "Lib",
        returnTypeName: "string",
      )
    ]
    let staticApi = generateApiRs(staticOnly, "lib")
    check "static STATIC_PUMP: Mutex<Option<StaticPump>>" in staticApi
    check "_listener<F>" notin staticApi
    check "static STATIC_PUMP" notin apiRs

suite "replies arrive through <lib>_poll":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "lib_create",
        libName: "lib",
        kind: FFIKind.CTOR,
        libTypeName: "Lib",
        extraParams: @[FFIParamMeta(name: "config", typeName: "LibConfig")],
      ),
      FFIProcMeta(
        procName: "lib_echo",
        libName: "lib",
        kind: FFIKind.FFI,
        libTypeName: "Lib",
        extraParams: @[FFIParamMeta(name: "req", typeName: "EchoRequest")],
        returnTypeName: "EchoResponse",
      ),
      FFIProcMeta(
        procName: "lib_version",
        libName: "lib",
        kind: FFIKind.STATIC,
        libTypeName: "Lib",
        returnTypeName: "string",
      ),
      FFIProcMeta(
        procName: "lib_destroy", libName: "lib", kind: FFIKind.DTOR, libTypeName: "Lib"
      ),
    ]
    let ffiRs = generateFFIRs(procs)
    let apiRs = generateApiRs(procs, "lib")

  test "ffi.rs declares the exports without a callback":
    check "pub fn lib_create(req_cbor: *const u8, req_cbor_len: usize, ctx_out: *mut *mut c_void, req_id_out: *mut u64) -> c_int;" in
      ffiRs
    check "pub fn lib_echo(ctx: *mut c_void, req_cbor: *const u8, req_cbor_len: usize, req_id_out: *mut u64) -> c_int;" in
      ffiRs
    check "pub fn lib_version(req_cbor: *const u8, req_cbor_len: usize, req_id_out: *mut u64) -> c_int;" in
      ffiRs
    check "pub fn lib_destroy(ctx: *mut c_void) -> c_int;" in ffiRs
    check "pub fn lib_static_ctx() -> *mut c_void;" in ffiRs
    check "pub fn lib_last_error() -> *const c_char;" in ffiRs
    check "FFICallback" notin ffiRs
    check "user_data" notin ffiRs

  test "the callback plumbing is gone from api.rs":
    for gone in [
      "on_result", "FFICallback", "Box::into_raw", "Box::from_raw", "user_data",
      "NIMFFI_RET_MISSING_CALLBACK", "NIMFFI_RET_STALE_WARN",
    ]:
      check gone notin apiRs

  test "the public request API keeps its shape":
    check "    pub fn create(config: LibConfig, timeout: Duration) -> Result<Self, String> {" in
      apiRs
    check "    pub async fn new_async(config: LibConfig, timeout: Duration) -> Result<Self, String> {" in
      apiRs
    check "    pub fn echo(&self, req: EchoRequest) -> Result<EchoResponse, String> {" in
      apiRs
    check "    pub async fn echo_async(&self, req: EchoRequest) -> Result<EchoResponse, String> {" in
      apiRs
    check "    pub fn version(timeout: Duration) -> Result<String, String> {" in apiRs
    check "    pub async fn version_async(timeout: Duration) -> Result<String, String> {" in
      apiRs
    check "decode_cbor::<EchoResponse>(&raw_bytes)" in apiRs

  test "a waiter is registered under the lock held across the submit":
    check "waiters: Mutex<HashMap<u64, flume::Sender<FFIResult>>>," in apiRs
    let submit = apiRs.find("fn submit<F>")
    let lockAt = apiRs.find("let mut waiters = lock(&self.waiters);", submit)
    let sendAt = apiRs.find("let ret = send(self.ptr, &mut req_id);", submit)
    let insertAt = apiRs.find("waiters.insert(req_id, tx);", submit)
    check submit >= 0
    check lockAt > submit
    check sendAt > lockAt
    check insertAt > sendAt
    # A refusal returns the library's words before anything is registered.
    let refusedAt = apiRs.find("return Err(last_error(ret));", submit)
    check refusedAt > sendAt
    check refusedAt < insertAt
    check "CStr::from_ptr(ffi::lib_last_error())" in apiRs

  test "a request goes through submit and its reply through wait":
    check "ffi::lib_echo(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id)" in apiRs
    check "self.inner.wait(req_id, &rx, self.timeout)?;" in apiRs
    check "self.inner.wait_async(req_id, rx, self.timeout).await?;" in apiRs
    check "rx.recv_timeout(timeout)" in apiRs
    check "tokio::time::timeout(timeout, rx.recv_async()).await" in apiRs

  test "the pump hands a reply to its waiter and never to a listener":
    check "if msg.kind == ffi::NIMFFI_MSG_REPLY {" in apiRs
    check "let waiter = lock(&self.waiters).remove(&msg.id);" in apiRs
    check "Reply" notin
      apiRs.substr(
        apiRs.find("pub enum LibMessage {"), apiRs.find("unsafe fn payload_bytes")
      )

  test "a timeout forgets the waiter, so the late reply is dropped":
    let timedOut = apiRs.find("fn timed_out(")
    check timedOut >= 0
    check apiRs.find("lock(&self.waiters).remove(&req_id);", timedOut) > timedOut
    check "Err(flume::RecvTimeoutError::Timeout) => self.timed_out(req_id, rx, timeout)," in
      apiRs
    check "Err(_) => self.timed_out(req_id, &rx, timeout)," in apiRs

  test "the end of the context fails the waiters before the Closed listeners run":
    let step = apiRs.find("fn pump_step(")
    let failAt = apiRs.find("inner.fail_waiters();", step)
    let dispatchAt = apiRs.find("inner.dispatch(&message);", step)
    check failAt > step
    check dispatchAt > failAt
    check "Err(flume::RecvTimeoutError::Disconnected) => Err(CONTEXT_CLOSED.into())," in
      apiRs
    # The pump's exit, whatever its cause, leaves no call waiting.
    let loopAt = apiRs.find("fn pump_loop(")
    check apiRs.find("inner.fail_waiters();", loopAt) > loopAt

  test "a blocking call on the pump thread pumps its own reply":
    check "if self.pump_thread.get() == Some(&std::thread::current().id()) {" in apiRs
    check "return self.wait_on_pump(req_id, rx, timeout);" in apiRs
    check "pump_step(self, slice_ms);" in apiRs
    check "inner.pump_thread.set(std::thread::current().id());" in apiRs

  test "STALE_WARN is a message with a listener":
    check "StaleWarn { req_id: u64, elapsed_ms: u64 }," in apiRs
    check "ffi::NIMFFI_MSG_STALE_WARN => Ok(LibMessage::StaleWarn {" in apiRs
    check "pub fn add_stale_warn_listener<F>" in apiRs

  test "the ctor registers its waiter before the pump starts, and an error destroys the context":
    let start = apiRs.find("    fn start(")
    let submitAt = apiRs.find(
      "submit(req_bytes.as_ptr(), req_bytes.len(), &mut ptr, &mut req_id)", start
    )
    let insertAt = apiRs.find("lock(&inner.waiters).insert(req_id, tx);", start)
    let spawnAt = apiRs.find("spawn_pump(\"lib-pump\", inner)", start)
    check submitAt > start
    check insertAt > submitAt
    check spawnAt > insertAt
    check "Self::start(&req_bytes, timeout, ffi::lib_create)?;" in apiRs
    check "ctx.inner.wait(req_id, &rx, timeout)?;" in apiRs
    check "ctx.inner.wait_async(req_id, rx, timeout).await?;" in apiRs

  test "statics wait on the static context's pump, which shutdown stops first":
    check "let ptr = unsafe { ffi::lib_static_ctx() };" in apiRs
    check "let inner = static_inner()?;" in apiRs
    check "ffi::lib_version(req_bytes.as_ptr(), req_bytes.len(), req_id)" in apiRs
    let shutdown = apiRs.find("pub fn shutdown() -> bool {")
    let stopAt = apiRs.find("stop_static_pump(&mut static_pump);", shutdown)
    let callAt = apiRs.find("ffi::lib_shutdown()", shutdown)
    check stopAt > shutdown
    check callAt > stopAt

  test "drop destroys the context before it stops the pump":
    let dropAt = apiRs.find("impl Drop for LibCtx {")
    let destroyAt = apiRs.find("ffi::lib_destroy(self.ptr);", dropAt)
    let stopAt = apiRs.find("self.inner.stop.store(true, Ordering::Release);", dropAt)
    check destroyAt > dropAt
    check stopAt > destroyAt
