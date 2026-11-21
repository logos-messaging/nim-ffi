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

suite "reverse FFI: the Rust wrapper hands the impl box to the library":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "Timer",
      )
    ]
    let reverse = @[
      FFIReverseMeta(
        wireName: "host_note",
        nimProcName: "notifyHost",
        libName: "timer",
        argsTypeName: "string",
        replyTypeName: "",
      )
    ]
    let api = generateApiRs(procs, "timer", @[], reverse)
    let ffiRs = generateFFIRs(procs, reverse)

  test "set_impl passes a release that reclaims the box; no wrapper-side slot":
    check "Box::into_raw(Box::new(NotifyHostImplBox" in api
    check "Some(notify_host_impl_release)" in api
    check "drop(Box::from_raw(ud as *mut NotifyHostImplBox))" in api
    check "_impl: std::sync::Mutex" notin api

  test "the docs say the token is Copy and the closure owns its arguments":
    check "call (`Copy`)" in api
    check "owns its arguments" in api

  test "the trampoline catches a panic instead of unwinding into the library":
    check "std::panic::catch_unwind" in api
    check "host impl panicked" in api

  test "the reverse helpers check the shared codes; the release type is emitted":
    check "REVERSE_" notin api
    check "if rc == NIMFFI_RET_OK { Ok(()) }" in api
    check "fn ret_name(rc: c_int) -> &'static str" in api
    check "-> Result<(), String>" in api
    check "release: Option<FFIReverseRelease>" in ffiRs
    check "pub type FFIReverseRelease" in ffiRs
    check "start_reverse_workers" notin ffiRs

  test "build.rs sets an rpath and rebuilds on a runtime change":
    let buildRs = generateBuildRs("timer", "../timer.nim")
    check "cargo:rustc-link-arg=-Wl,-rpath," in buildRs
    check "repo_root.join(\"ffi\")" in buildRs

suite "templates: every placeholder is filled":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        doc: "Make a timer.",
        extraParams: @[FFIParamMeta(name: "config", typeName: "TimerConfig")],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_destroy",
        libName: "timer",
        kind: FFIKind.DTOR,
        libTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_echo",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[FFIParamMeta(name: "req", typeName: "EchoRequest")],
        returnTypeName: "EchoResponse",
      ),
      FFIProcMeta(
        procName: "timer_version",
        libName: "timer",
        kind: FFIKind.STATIC,
        libTypeName: "Timer",
        returnTypeName: "string",
      ),
    ]
    let events = @[
      FFIEventMeta(
        wireName: "on_tick",
        nimProcName: "onTick",
        libName: "timer",
        payloadTypeName: "TickEvent",
      )
    ]
    let reverse = @[
      FFIReverseMeta(
        wireName: "fetch_config",
        nimProcName: "fetchConfig",
        libName: "timer",
        argsTypeName: "FetchConfigArgs",
        replyTypeName: "RevConfig",
      ),
      FFIReverseMeta(
        wireName: "host_note",
        nimProcName: "notifyHost",
        libName: "timer",
        argsTypeName: "",
        replyTypeName: "",
      ),
    ]
    let reverseEvents = @[
      FFIReverseEventMeta(
        wireName: "on_host_ping",
        nimProcName: "onHostPing",
        libName: "timer",
        reqTypeName: "OnHostPingReq",
        params: @[FFIParamMeta(name: "seqNo", typeName: "int")],
      )
    ]
    let files = [
      generateCargoToml("timer", true),
      generateBuildRs("timer", "../timer.nim"),
      generateLibRs(),
      generateFFIRs(procs, reverse, reverseEvents),
      generateApiRs(procs, "timer", events, reverse, reverseEvents),
      generateApiRs(procs, "timer"),
    ]

  test "no `{{` is left in any generated file":
    for i, f in files:
      checkpoint("file " & $i)
      check "{{" notin f

  test "the runtime block carries the return codes in place of its placeholder":
    let api = files[4]
    check "RET_CODES" notin api
    check "const NIMFFI_RET_OK: c_int = 0;" in api
    check "fn ret_name(rc: c_int)" in api
    check "fn ret_name(rc: c_int)" notin files[5]

  test "a doc sits flush above its fn and an empty doc leaves no blank line":
    let api = files[4]
    check "impl TimerCtx {\n    /// Make a timer.\n    pub fn create(config: TimerConfig, timeout: Duration)" in
      api
    check "    /// Make a timer.\n    pub async fn new_async(config: TimerConfig, timeout: Duration)" in
      api
    check "impl TimerCalls<'_> {\n    pub fn echo(&self, req: EchoRequest) -> Result<EchoResponse, String> {" in
      api
    for f in [files[3], files[4], files[5]]:
      check "\n\n\n" notin f

  test "an instance method passes self.ptr; its async twin copies the ptr as usize":
    let api = files[5]
    check "ffi_call_sync(self.timeout, self.progress.clone(), |cb, ud| unsafe {\n            ffi::timer_echo(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())" in
      api
    check "let ptr = self.ptr as usize;\n        let raw_bytes = ffi_call_async(self.timeout, self.progress.clone(), move |cb, ud| unsafe {\n            ffi::timer_echo(ptr as *mut c_void, cb, ud," in
      api
    check "let req = TimerEchoReq { req };" in api

  test "a static takes a timeout, has no self and no ptr copy":
    let api = files[5]
    check "pub fn version(timeout: Duration) -> Result<String, String> {" in api
    check "pub async fn version_async(timeout: Duration) -> Result<String, String> {" in
      api
    check "let req = TimerVersionReq {};" in api
    check "ffi::timer_version(cb, ud, req_bytes.as_ptr(), req_bytes.len())" in api
    check "ffi::timer_version(self.ptr" notin api
    check api.count("let ptr = self.ptr as usize;") == 1

  test "a ctor with no params takes only the timeout and a registry with no dtor has no Drop":
    let bare = generateApiRs(
      @[
        FFIProcMeta(
          procName: "timer_create",
          libName: "timer",
          kind: FFIKind.CTOR,
          libTypeName: "Timer",
          returnTypeName: "Timer",
        )
      ],
      "timer",
    )
    check "impl TimerCtx {\n    pub fn create(timeout: Duration) -> Result<Self, String> {\n        let req = TimerCreateCtorReq {};" in
      bare
    check "    pub async fn new_async(timeout: Duration) -> Result<Self, String> {" in
      bare
    check "impl Drop for" notin bare
    check "impl Drop for TimerCtx {" in files[4]
    check "ffi::timer_destroy(self.ptr)" in files[4]

  test "the listener machinery appears only with events":
    let withEv = files[4]
    let without = files[5]
    check "    calls: TimerCalls<'static>,\n    listeners: std::sync::Mutex<" in withEv
    check withEv.count(
      ", listeners: std::sync::Mutex::new(std::collections::HashMap::new()) })"
    ) == 2
    check "    calls: TimerCalls<'static>,\n}" in without
    check "progress: None, _ctx: std::marker::PhantomData } })" in without
    for needle in [
      "listeners", "ListenerHandle", "add_event_listener", "remove_event_listener",
      "_trampoline",
    ]:
      check needle notin without

  test "an event gets a handler struct, a trampoline and a listener fn named from its proc and wire":
    let api = files[4]
    check "struct OnTickHandler {\n    f: Box<dyn Fn(&TickEvent) + Send + Sync>,\n}" in
      api
    check "unsafe extern \"C\" fn on_tick_trampoline(" in api
    check "    pub fn add_on_tick_listener<F>(&self, handler: F) -> ListenerHandle\n    where F: Fn(&TickEvent) + Send + Sync + 'static," in
      api
    check "b\"on_tick\\0\".as_ptr() as *const c_char, on_tick_trampoline, raw, owned)" in
      api
    check "    }\n\n    /// Register a typed listener for `on_tick`." in api
    check "ffi::timer_add_event_listener(self.ptr, event_name, callback, raw)" in api
    check "ffi::timer_remove_event_listener(self.ptr, handle.id)" in api

  test "a reverse reply with a type takes it; a void reply takes none":
    let api = files[4]
    check api.count("pub fn reply(&self, r: &RevConfig) -> Result<(), String> {") == 1
    check api.count("pub fn reply(&self) -> Result<(), String> {") == 1
    check "self.id, 0, std::ptr::null(), 0)" in api
    check "format!(\"reply fetch_config: {e}\")" in api
    check "format!(\"reply host_note: {}\", ret_name(rc))" in api

  test "a reverse impl with args decodes them; one without args calls the closure bare":
    let api = files[4]
    check "match decode_cbor::<FetchConfigArgs>(bytes) {" in api
    check "Ok(a) => (b.f)(call, a)," in api
    check "f: Box<dyn Fn(FetchConfigCall, FetchConfigArgs) + Send + Sync>," in api
    check api.count("let _ = (args, len);\n        (b.f)(call);") == 1
    check "f: Box<dyn Fn(NotifyHostCall) + Send + Sync>," in api
    check "where F: Fn(NotifyHostCall) + Send + Sync + 'static," in api
    check "decode_cbor::<NotifyHost" notin api

  test "the owns-its-arguments doc follows a reverse doc only when the impl takes args":
    let api = files[4]
    let owns =
      "    /// The closure runs on a reverse worker and owns its arguments, so a deferred\n" &
      "    /// reply can move them to another thread.\n"
    check api.count(owns) == 1
    check (owns & "    pub fn set_fetch_config_impl<F>(&self, f: F)") in api
    let docced = generateApiRs(
      procs,
      "timer",
      @[],
      @[
        FFIReverseMeta(
          wireName: "host_note",
          nimProcName: "notifyHost",
          libName: "timer",
          doc: "Tell the host.\nTwice.",
        )
      ],
    )
    check "    /// Tell the host.\n    /// Twice.\n    pub fn set_notify_host_impl<F>(&self, f: F)" in
      docced
    check "owns its arguments" notin docced

  test "a reverse event emit takes its params; with none it builds an empty req":
    let api = files[4]
    check "pub fn emit_on_host_ping(&self, seq_no: i64) -> Result<(), String> {" in api
    check "let payload = OnHostPingReq { seq_no };" in api
    check "ffi::timer_emit_on_host_ping(self.ptr, b.as_ptr(), b.len())" in api
    let bare = generateApiRs(
      procs,
      "timer",
      @[],
      @[],
      @[
        FFIReverseEventMeta(
          wireName: "on_host_ping",
          nimProcName: "onHostPing",
          libName: "timer",
          reqTypeName: "OnHostPingReq",
          doc: "Ping.",
        )
      ],
    )
    check "    /// Ping.\n    pub fn emit_on_host_ping(&self) -> Result<(), String> {" in
      bare
    check "let payload = OnHostPingReq {};" in bare
    check "fn ret_name(rc: c_int)" in bare

  test "ffi.rs declares each kind with its own signature and gates the reverse ABI":
    let ffiRs = files[3]
    check "#[link(name = \"timer\")]" in ffiRs
    check "pub fn timer_create(req_cbor: *const u8, req_cbor_len: usize, callback: FFICallback, user_data: *mut c_void) -> *mut c_void;" in
      ffiRs
    check "pub fn timer_destroy(ctx: *mut c_void) -> c_int;" in ffiRs
    check "pub fn timer_echo(ctx: *mut c_void, callback: FFICallback," in ffiRs
    check "pub fn timer_version(callback: FFICallback, user_data: *mut c_void, req_cbor: *const u8, req_cbor_len: usize) -> c_int;" in
      ffiRs
    check "pub fn timer_set_fetch_config_impl(ctx: *mut c_void, imp: Option<FFIReverseImpl>," in
      ffiRs
    check "pub fn timer_set_host_note_impl(" in ffiRs
    check ffiRs.count("pub fn timer_reverse_reply(") == 1
    check "pub fn timer_emit_on_host_ping(ctx: *mut c_void, payload_cbor: *const u8, payload_len: usize) -> c_int;" in
      ffiRs
    let plain = generateFFIRs(procs)
    for needle in [
      "reverse_reply", "_impl(", "_emit_", "FFIReverseImpl", "FFIReverseRelease"
    ]:
      check needle notin plain

  test "Cargo.toml places serde_bytes right after serde; build.rs doubles a backslash in the nim path":
    check "features = [\"derive\"] }\nserde_bytes = \"0.11\"\nciborium = \"0.2\"" in
      generateCargoToml("timer", true)
    check "features = [\"derive\"] }\nciborium = \"0.2\"" in generateCargoToml("timer")
    check generateCargoToml("timer").startsWith("[package]\nname = \"timer\"\n")
    check generateCargoToml("timer").endsWith("\"time\"] }\n")
    let buildRs = generateBuildRs("timer", "..\\sub\\timer.nim")
    check buildRs.count("manifest.join(\"..\\\\sub\\\\timer.nim\")") == 2
    check "format!(\"libtimer.{lib_ext}\")" in buildRs
    check "--nimMainPrefix:libtimer" in buildRs
    check "cargo:rustc-link-lib=timer" in buildRs

  test "shutdown is an associated fn with its doc flush above":
    check "    /// This wrapper reports that as true.\n    pub fn shutdown() -> bool {\n        unsafe { ffi::timer_shutdown() == 0 }" in
      files[5]

suite "per-call timeout: the calls view carries the limit":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_echo",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[FFIParamMeta(name: "req", typeName: "string")],
        returnTypeName: "string",
      ),
      FFIProcMeta(
        procName: "timer_lib_version",
        libName: "timer",
        kind: FFIKind.STATIC,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "string",
      ),
    ]
    let api = generateApiRs(procs, "timer")

  test "the ctx derefs to a calls view and with_timeout re-limits it":
    check "impl std::ops::Deref for TimerCtx" in api
    check "pub fn with_timeout(&self, timeout: Option<Duration>) -> TimerCalls<'_>" in
      api
    check "timeout: Option<Duration>,\n    progress: Option<Progress>,\n    _ctx: std::marker::PhantomData<&'a TimerCtx>," in
      api

  test "sync and async instance methods read the view's limit":
    check "impl TimerCalls<'_> {" in api
    check "ffi_call_sync(self.timeout, self.progress.clone(), |cb, ud| unsafe {\n            ffi::timer_echo(" in
      api
    check "ffi_call_async(self.timeout, self.progress.clone(), move |cb, ud| unsafe {" in
      api

  test "a static stays an associated fn of the ctx with a plain Duration":
    check "pub fn lib_version(timeout: Duration)" in api
    check "pub async fn lib_version_async(timeout: Duration)" in api

  test "the view cannot be copied out of the ctx":
    check "pub struct TimerCalls<'a>" in api
    check "derive(Clone, Copy)]\npub struct TimerCalls" notin api

suite "progress: the calls view carries the callback":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_echo",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[FFIParamMeta(name: "req", typeName: "string")],
        returnTypeName: "string",
      ),
      FFIProcMeta(
        procName: "timer_lib_version",
        libName: "timer",
        kind: FFIKind.STATIC,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "string",
      ),
    ]
    let api = generateApiRs(procs, "timer")

  test "an instance call forwards the view's progress":
    check "ffi_call_sync(self.timeout, self.progress.clone(), |cb, ud| unsafe {" in api
    check "ffi_call_async(self.timeout, self.progress.clone(), move |cb, ud| unsafe {" in
      api

  test "a static and a ctor take no progress":
    check "ffi_call_sync(Some(timeout), None, |cb, ud| unsafe {" in api
    check "ffi_call_async(Some(timeout), None, move |cb, ud| unsafe {" in api

  test "both the ctx and the view offer with_progress":
    check "impl TimerCtx {" in api
    check api.count("pub fn with_progress(") == 2
    check "pub type Progress = std::sync::Arc<dyn Fn(Duration) + Send + Sync>;" in api
