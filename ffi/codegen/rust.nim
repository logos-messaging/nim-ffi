## Rust binding generator: emits a complete Rust crate using CBOR (ciborium).

import std/strutils
import
  ./meta,
  ./string_helpers,
  ./types_ir,
  ./consts,
  ./build_paths,
  ../ret_codes,
  ../ffi_msg

## Wire-format Rust type for any Nim `ptr T`/`pointer`; fixed 64-bit for a
## host-independent CBOR payload size (mirrors CppPtrType).
const RustPtrType* = "u64"

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

proc deriveLibName*(procs: seq[FFIProcMeta]): string =
  ## Common prefix before the first `_` in proc names, e.g. "timer_create" → "timer".
  if currentLibName.len > 0:
    return currentLibName
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
    """[package]
name = "$1"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }$2
ciborium = "0.2"
flume = { version = "0.11", default-features = false, features = ["async"] }
tokio = { version = "1", features = ["sync", "time"] }

[dev-dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "macros", "sync", "time"] }
""" %
    [libName, serdeBytesDep]

proc generateBuildRs*(libName: string, nimSrcRelPath: string): string =
  ## Generates build.rs that compiles the Nim library; nimSrcRelPath is relative
  ## to the crate directory.
  let escapedSrc = nimSrcRelPath.replace("\\", "\\\\")
  return
    """use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let nim_src = manifest.join("$1");
    let nim_src = nim_src.canonicalize().unwrap_or(manifest.join("$1"));

    // Walk up to find the nim-ffi repo root (directory containing nim_src's library)
    // The repo root is where nim c should be run from (contains config.nims).
    // We assume nim_src lives somewhere under repo_root.
    // Derive repo_root as the ancestor that contains the .nimble file or config.nims.
    let mut repo_root = nim_src.clone();
    loop {
        repo_root = match repo_root.parent() {
            Some(p) => p.to_path_buf(),
            None => break,
        };
        if repo_root.join("config.nims").exists() || repo_root.join("ffi.nimble").exists() {
            break;
        }
    }

    #[cfg(target_os = "macos")]
    let lib_ext = "dylib";
    #[cfg(target_os = "linux")]
    let lib_ext = "so";

    let out_lib = repo_root.join(format!("lib$2.{lib_ext}"));

    let mut cmd = Command::new("nim");
    cmd.arg("c")
        .arg("--mm:orc")
        .arg("-d:chronicles_log_level=WARN")
        .arg("--app:lib")
        .arg("--noMain")
        .arg(format!("--nimMainPrefix:lib$2"))
        .arg(format!("-o:{}", out_lib.display()));
    cmd.arg(&nim_src).current_dir(&repo_root);

    let status = cmd.status().expect("failed to run nim compiler");
    assert!(status.success(), "Nim compilation failed");

    println!("cargo:rustc-link-search={}", repo_root.display());
    println!("cargo:rustc-link-lib=$2");
    println!("cargo:rerun-if-changed={}", nim_src.display());
}
""" %
    [escapedSrc, libName]

proc generateLibRs*(): string =
  return """mod ffi;
mod types;
mod api;
pub use types::*;
pub use api::*;
"""

const PollDoc =
  """Take the context's next message, waiting up to `timeout_ms` (0 never blocks,
negative waits until a message or the end of the context). One consumer per
context: a second concurrent poll gets NIMFFI_RET_BUSY.
`msg` and its payload belong to the library and stay valid until the next poll
on the same context.
Returns NIMFFI_RET_OK, NIMFFI_RET_TIMEOUT, NIMFFI_RET_CLOSED (`msg` holds the
CLOSED message), NIMFFI_RET_INVALID_CTX, NIMFFI_RET_BUSY or NIMFFI_RET_ERR."""

const PollFdDoc =
  """A wake handle the caller owns and closes: an epoll fd on Linux, a kqueue fd
on macOS/BSD, an Event HANDLE on Windows; -1 on failure. It is ready while a
message waits or the context is closed: wait on it, then poll with a timeout of
0 until NIMFFI_RET_TIMEOUT."""

proc generateFFIRs*(procs: seq[FFIProcMeta]): string =
  ## Generates ffi.rs with extern "C" declarations; each proc takes one CBOR
  ## buffer (ptr+len) as its request payload.
  var lines: seq[string] = @[]
  # The whole ABI is declared here; the wrapper in api.rs does not use all of it.
  lines.add("#![allow(dead_code)]")
  lines.add("")
  lines.add("use std::os::raw::{c_char, c_int, c_void};")
  lines.add("")
  lines.add("pub type FFICallback = unsafe extern \"C\" fn(")
  lines.add("    ret: c_int,")
  lines.add("    msg: *const c_char,")
  lines.add("    len: usize,")
  lines.add("    user_data: *mut c_void,")
  lines.add(");")
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

  lines.add(
    "// What `$1_poll` hands out, emitted from ffi/ffi_msg.nim." % [linkLibName]
  )
  lines.add(rustMsgDecl())
  lines.add("")
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

  lines.add(renderMemberDocComment(PollDoc))
  lines.add(
    "    pub fn $1_poll(ctx: *mut c_void, timeout_ms: i32, msg: *mut *const NimFfiMsg) -> c_int;" %
      [linkLibName]
  )
  lines.add(renderMemberDocComment(PollFdDoc))
  lines.add("    pub fn $1_poll_fd(ctx: *mut c_void) -> isize;" % [linkLibName])
  lines.add(renderMemberDocComment(ShutdownDoc))
  lines.add("    pub fn $1_shutdown() -> c_int;" % [linkLibName])

  lines.add("}")
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

const PumpSliceMs = 250 ## A waiting pump looks at its stop flag this often.

func evConstName(libName: string, ev: FFIEventMeta): string =
  return
    libName.toUpperAscii() & "_EVT_" & camelToSnakeCase(ev.nimProcName).toUpperAscii()

proc generateMessages(events: seq[FFIEventMeta], libName, msgTypeName: string): string =
  ## The one place that lists what the library sends: a name id per event, the
  ## message enum and its decoder.
  var lines: seq[string] = @[]
  if events.len > 0:
    lines.add("// `NimFfiMsg.name_id` of each event: FNV-1a 64 of its wire name.")
  for ev in events:
    lines.add(
      "pub const $1: u64 = $2; // \"$3\"" %
        [evConstName(libName, ev), nameIdLiteral(ev.wireName), ev.wireName]
    )
  lines.add(
    "pub use super::ffi::{NIMFFI_NOT_RESPONDING_EVENT_QUEUE_FULL, NIMFFI_NOT_RESPONDING_HEARTBEAT};"
  )
  lines.add("")

  lines.add(
    "/// Everything `$1` sends to the host: its events, the liveness reports" % [
      libName
    ]
  )
  lines.add("/// and the end of the context. The pump thread of a context decodes each")
  lines.add("/// message into one of these before a listener runs.")
  lines.add("#[derive(Debug, Clone)]")
  lines.add("pub enum $1 {" % [msgTypeName])
  for ev in events:
    lines.add(renderMemberDocComment(ev.doc))
    lines.add(
      "    $1($2)," % [capitalizeFirstLetter(ev.nimProcName), ev.payloadTypeName]
    )
  lines.add(
    "    /// The library stopped making progress. `reason` is a `NIMFFI_NOT_RESPONDING_*`:"
  )
  lines.add(
    "    /// the FFI thread stalled, or the event queue overflowed and requests are"
  )
  lines.add("    /// refused from now on.")
  lines.add("    NotResponding { reason: u64 },")
  lines.add("    /// The FFI thread's heartbeat resumed.")
  lines.add("    Responding,")
  lines.add(
    "    /// The context is gone; always the last message. `ok` is false when the"
  )
  lines.add(
    "    /// library could not recycle the context, and `reason` then says why."
  )
  lines.add("    Closed { ok: bool, reason: String },")
  lines.add(
    "    /// Not sent by the library: a message this binding could not decode, such"
  )
  lines.add("    /// as an event of a newer library.")
  lines.add("    Undecodable { kind: u32, name_id: u64, error: String },")
  lines.add("}")
  lines.add("")

  # The message belongs to the library until the next poll, so this copies everything out.
  lines.add("unsafe fn decode_message(msg: &ffi::NimFfiMsg) -> $1 {" % [msgTypeName])
  lines.add("    let bytes: &[u8] = if msg.payload.is_null() || msg.len == 0 {")
  lines.add("        &[]")
  lines.add("    } else {")
  lines.add("        slice::from_raw_parts(msg.payload, msg.len)")
  lines.add("    };")
  lines.add("    let decoded = match msg.kind {")
  lines.add("        ffi::NIMFFI_MSG_EVENT => match msg.name_id {")
  for ev in events:
    lines.add(
      "            $1 => decode_cbor(bytes).map($2::$3)," %
        [evConstName(libName, ev), msgTypeName, capitalizeFirstLetter(ev.nimProcName)]
    )
  lines.add("            _ => Err(\"unknown event\".to_string()),")
  lines.add("        },")
  lines.add(
    "        ffi::NIMFFI_MSG_NOT_RESPONDING => Ok($1::NotResponding { reason: msg.aux })," %
      [msgTypeName]
  )
  lines.add("        ffi::NIMFFI_MSG_RESPONDING => Ok($1::Responding)," % [msgTypeName])
  lines.add("        ffi::NIMFFI_MSG_CLOSED => Ok($1::Closed {" % [msgTypeName])
  lines.add("            ok: msg.ret_code == NIMFFI_RET_OK,")
  lines.add("            reason: String::from_utf8_lossy(bytes).into_owned(),")
  lines.add("        }),")
  lines.add("        _ => Err(\"unknown message kind\".to_string()),")
  lines.add("    };")
  lines.add("    decoded.unwrap_or_else(|error| $1::Undecodable {" % [msgTypeName])
  lines.add("        kind: msg.kind,")
  lines.add("        name_id: msg.name_id,")
  lines.add("        error,")
  lines.add("    })")
  lines.add("}")
  lines.add("")
  return lines.join("\n")

# $1 lib name, $2 message enum, $3 poll slice in ms.
const PumpTemplate = """type Handler = Arc<dyn Fn(&$2) + Send + Sync>;

/// Returned by every `add_*_listener`; pass it to `remove_event_listener`.
#[derive(Debug, Clone, Copy)]
pub struct ListenerHandle { pub id: u64 }

// What a context shares with its pump thread.
struct Inner {
    ptr: *mut c_void,
    listeners: Mutex<Vec<(u64, Handler)>>,
    next_id: AtomicU64,
    stop: AtomicBool,
}

// SAFETY: `ptr` is a token the library validates on every call, never
// dereferenced here. `$1_poll` admits one consumer per context and the pump
// thread is the only poller; everything else in `Inner` is already Sync.
unsafe impl Send for Inner {}
unsafe impl Sync for Inner {}

impl Inner {
    // Handlers run with the lock released, so a panic cannot poison it; recover anyway.
    fn lock(&self) -> MutexGuard<'_, Vec<(u64, Handler)>> {
        self.listeners.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn add(&self, handler: Handler) -> ListenerHandle {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.lock().push((id, handler));
        ListenerHandle { id }
    }

    fn remove(&self, id: u64) -> bool {
        let mut listeners = self.lock();
        let before = listeners.len();
        listeners.retain(|(lid, _)| *lid != id);
        listeners.len() != before
    }

    fn dispatch(&self, message: &$2) {
        // Cloned out so a handler may add or remove listeners.
        let handlers: Vec<Handler> = self.lock().iter().map(|(_, h)| h.clone()).collect();
        for handler in handlers {
            // A panicking handler must not end the pump; the panic hook already reported it.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handler(message)));
        }
    }
}

// The context's only poller: takes each message out, decodes it and runs the listeners.
fn pump_loop(inner: Arc<Inner>) {
    loop {
        // The library owns the message; it is valid until the next poll.
        let mut msg: *const ffi::NimFfiMsg = std::ptr::null();
        // Once asked to stop, only take what already waits: a teardown's last messages.
        let stopping = inner.stop.load(Ordering::Acquire);
        let timeout_ms = if stopping { 0 } else { $3 };
        let ret = unsafe { ffi::$1_poll(inner.ptr, timeout_ms, &mut msg) };
        match ret {
            NIMFFI_RET_OK | NIMFFI_RET_CLOSED if !msg.is_null() => {
                let message = unsafe { decode_message(&*msg) };
                inner.dispatch(&message);
                if ret == NIMFFI_RET_CLOSED {
                    return;
                }
                continue;
            }
            NIMFFI_RET_TIMEOUT => {}
            NIMFFI_RET_INVALID_CTX => {
                // The context ended between two polls, so its CLOSED message was never seen.
                inner.dispatch(&$2::Closed { ok: true, reason: String::new() });
                return;
            }
            // NIMFFI_RET_BUSY, NIMFFI_RET_ERR: try again, without spinning.
            _ => std::thread::sleep(Duration::from_millis(10)),
        }
        if stopping {
            return;
        }
    }
}
"""

# $1 lib name.
const StartTemplate =
  """    fn start(ptr: *mut c_void, timeout: Duration) -> Result<Self, String> {
        let inner = Arc::new(Inner {
            ptr,
            listeners: Mutex::new(Vec::new()),
            next_id: AtomicU64::new(1),
            stop: AtomicBool::new(false),
        });
        // Built first: if the thread cannot start, dropping it destroys the context.
        let mut ctx = Self { ptr, timeout, inner: inner.clone(), pump: None };
        let pump = std::thread::Builder::new()
            .name("$1-pump".into())
            .spawn(move || pump_loop(inner))
            .map_err(|e| e.to_string())?;
        ctx.pump = Some(pump);
        Ok(ctx)
    }
"""

# $1 message enum.
const ListenersTemplate =
  """    /// Register a listener for `NotResponding`; it receives the reason.
    pub fn add_not_responding_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(u64) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &$1| {
            if let $1::NotResponding { reason } = m { handler(*reason) }
        }))
    }

    /// Register a listener for `Responding`.
    pub fn add_responding_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn() + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &$1| {
            if let $1::Responding = m { handler() }
        }))
    }

    /// Register a listener for `Closed`; it receives `ok` and `reason`.
    pub fn add_closed_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(bool, &str) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &$1| {
            if let $1::Closed { ok, reason } = m { handler(*ok, reason) }
        }))
    }

    /// Register a listener that sees every message the library sends.
    pub fn add_message_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(&$1) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(handler))
    }

    /// Remove a previously-registered listener by handle. Returns true
    /// if the listener existed and was removed; false otherwise.
    /// Listeners run on the context's pump thread, one message at a time, and may
    /// call this for any listener: a dispatch in flight still runs the handlers it
    /// took, so a removed handler can run once more.
    pub fn remove_event_listener(&self, handle: ListenerHandle) -> bool {
        self.inner.remove(handle.id)
    }
"""

proc generateApiRs*(
    procs: seq[FFIProcMeta], libName: string, events: seq[FFIEventMeta] = @[]
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
  let msgTypeName = libTypeName & "Message"
  # Only a context made by a ctor has messages to take out; the static one emits none.
  let hasPump = ctors.len > 0

  lines.add("use std::os::raw::{c_char, c_int, c_void};")
  lines.add("use std::slice;")
  if hasPump:
    lines.add("use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};")
    lines.add("use std::sync::{Arc, Mutex, MutexGuard};")
  lines.add("use std::time::Duration;")
  lines.add("use serde::de::DeserializeOwned;")
  lines.add("use serde::Serialize;")
  lines.add("use super::ffi;")
  lines.add("use super::types::*;")
  lines.add("")

  lines.add("fn encode_cbor<T: Serialize>(value: &T) -> Result<Vec<u8>, String> {")
  lines.add("    let mut buf = Vec::new();")
  lines.add(
    "    ciborium::ser::into_writer(value, &mut buf).map_err(|e| e.to_string())?;"
  )
  lines.add("    Ok(buf)")
  lines.add("}")
  lines.add("")
  lines.add("fn decode_cbor<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, String> {")
  lines.add("    ciborium::de::from_reader(bytes).map_err(|e| e.to_string())")
  lines.add("}")
  lines.add("")

  # FFI trampoline: user_data owns a Box<flume::Sender>; a late callback sends into a closed receiver, which is harmless.
  lines.add("type FFIResult = Result<Vec<u8>, String>;")
  lines.add("type FFISender = flume::Sender<FFIResult>;")
  lines.add("")
  lines.add("// Reconstruct the (ret, msg, len) tuple delivered by the C callback")
  lines.add(
    "// into a Result<Vec<u8>, String>: payload on success, UTF-8 message on error."
  )
  lines.add(
    "// `from_utf8_lossy` accepts non-UTF-8 error bytes by inserting U+FFFD; the"
  )
  lines.add(
    "// alternative would be to dispatch a separate Err for invalid UTF-8, but the"
  )
  lines.add("// codegen contract is that Nim handlers emit `string` error payloads, so")
  lines.add("// invalid UTF-8 here would be a Nim-side bug.")
  lines.add(
    "unsafe fn ffi_payload(ret: c_int, msg: *const c_char, len: usize) -> FFIResult {"
  )
  lines.add("    let bytes = if msg.is_null() || len == 0 {")
  lines.add("        Vec::new()")
  lines.add("    } else {")
  lines.add("        slice::from_raw_parts(msg as *const u8, len).to_vec()")
  lines.add("    };")
  lines.add("    if ret == NIMFFI_RET_OK { Ok(bytes) }")
  lines.add("    else        { Err(String::from_utf8_lossy(&bytes).into_owned()) }")
  lines.add("}")
  lines.add("")
  lines.add("// nim-ffi result-callback status codes, emitted from ffi/ret_codes.nim.")
  lines.add(rustRetCodeConsts())
  lines.add("")
  lines.add("unsafe extern \"C\" fn on_result(")
  lines.add("    ret: c_int,")
  lines.add("    msg: *const c_char,")
  lines.add("    len: usize,")
  lines.add("    user_data: *mut c_void,")
  lines.add(") {")
  lines.add(
    "    // NIMFFI_RET_STALE_WARN (3) is a non-terminal progress ping: the request"
  )
  lines.add(
    "    // is still running. This wrapper only delivers the final result, so ignore"
  )
  lines.add(
    "    // it WITHOUT reclaiming the box — a terminal callback still owns the Sender."
  )
  lines.add("    if ret == NIMFFI_RET_STALE_WARN { return; }")
  lines.add("")
  lines.add("    // Take ownership of the boxed Sender — dropping it at end of scope")
  lines.add("    // releases the only outstanding handle.")
  lines.add("    let tx = Box::from_raw(user_data as *mut FFISender);")
  lines.add("")
  lines.add(
    "    // `tx.send` returns Err only if the awaiting future was dropped (and with it"
  )
  lines.add(
    "    // the Receiver): e.g. tokio::time::timeout elapsed, a tokio::select! branch"
  )
  lines.add(
    "    // lost the race, or the future was dropped before being awaited. This cannot"
  )
  lines.add("    // happen with the crate's own examples but may occur in arbitrary")
  lines.add("    // downstream consumers, so we discard the Err safely.")
  lines.add(
    "    // Given that this is invoked from a Nim thread, we can't propagate the error by panicking or"
  )
  lines.add(
    "    // returning a Result. Furthermore, an API dev may intentionally set a timeout in the await,"
  )
  lines.add(
    "    // in which case is also fine to discard the send error in this case because the API user will"
  )
  lines.add("    // handle the timeout expiry in their own code.")
  lines.add(
    "    // The important part is to ensure that the callback doesn't panic or block indefinitely if the"
  )
  lines.add("    // receiver is gone.")
  lines.add("    let _ = tx.send(ffi_payload(ret, msg, len));")
  lines.add("}")
  lines.add("")
  lines.add("fn ffi_call_sync<F>(timeout: Duration, f: F) -> FFIResult")
  lines.add("where")
  lines.add("    F: FnOnce(ffi::FFICallback, *mut c_void) -> c_int,")
  lines.add("{")
  lines.add("    let (tx, rx) = flume::bounded::<FFIResult>(1);")
  lines.add("    let raw = Box::into_raw(Box::new(tx)) as *mut c_void;")
  lines.add("    let ret = f(on_result, raw);")
  lines.add("    if ret == NIMFFI_RET_MISSING_CALLBACK {")
  lines.add("        // Callback will never fire; reclaim the box to avoid a leak.")
  lines.add("        drop(unsafe { Box::from_raw(raw as *mut FFISender) });")
  lines.add("        return Err(\"RET_MISSING_CALLBACK (internal error)\".into());")
  lines.add("    }")
  lines.add("    match rx.recv_timeout(timeout) {")
  lines.add("        Ok(payload) => payload,")
  lines.add("        Err(flume::RecvTimeoutError::Timeout) =>")
  lines.add("            Err(format!(\"timed out after {:?}\", timeout)),")
  lines.add("        Err(flume::RecvTimeoutError::Disconnected) =>")
  lines.add(
    "            Err(\"callback channel disconnected before delivery\".into()),"
  )
  lines.add("    }")
  lines.add("}")
  lines.add("")
  lines.add("async fn ffi_call_async<F>(timeout: Duration, f: F) -> FFIResult")
  lines.add("where")
  lines.add("    F: FnOnce(ffi::FFICallback, *mut c_void) -> c_int,")
  lines.add("{")
  lines.add("    let (tx, rx) = flume::bounded::<FFIResult>(1);")
  lines.add("    let raw = Box::into_raw(Box::new(tx)) as *mut c_void;")
  lines.add("    let ret = f(on_result, raw);")
  lines.add("    if ret == NIMFFI_RET_MISSING_CALLBACK {")
  lines.add("        drop(unsafe { Box::from_raw(raw as *mut FFISender) });")
  lines.add("        return Err(\"RET_MISSING_CALLBACK (internal error)\".into());")
  lines.add("    }")
  lines.add("    match tokio::time::timeout(timeout, rx.recv_async()).await {")
  lines.add("        Ok(Ok(payload)) => payload,")
  lines.add(
    "        Ok(Err(_)) => Err(\"callback channel disconnected before delivery\".into()),"
  )
  lines.add("        Err(_) => Err(format!(\"timed out after {:?}\", timeout)),")
  lines.add("    }")
  lines.add("}")
  lines.add("")

  if hasPump:
    lines.add(generateMessages(events, libName, msgTypeName))
    lines.add(PumpTemplate % [libName, msgTypeName, $PumpSliceMs])

  lines.add("/// High-level context for `$1`." % [libTypeName])
  lines.add("pub struct $1 {" % [ctxTypeName])
  lines.add("    ptr: *mut c_void,")
  lines.add("    timeout: Duration,")
  if hasPump:
    lines.add("    inner: Arc<Inner>,")
    lines.add("    pump: Option<std::thread::JoinHandle<()>>,")
  lines.add("}")
  lines.add("")
  # SAFETY block applies to both impls below.
  lines.add(
    "// SAFETY: The `ptr` field points to an FFIContext owned by the Nim runtime."
  )
  lines.add("// Every call through the generated FFI proc goes through")
  lines.add(
    "// `sendRequestToFFIThread` on the Nim side, which only enqueues the request"
  )
  lines.add("// onto a mutex-guarded MPSC queue (sound from any number of threads) and")
  lines.add(
    "// wakes the single FFI thread that dispatches every handler. The context is"
  )
  lines.add(
    "// thus never mutated non-atomically from the caller's thread. The Nim-side"
  )
  lines.add("// reentrancy guard (`onFFIThread` threadvar) prevents handlers from")
  lines.add("// re-entering the dispatcher. These invariants make it sound to mark the")
  lines.add("// wrapper as Send + Sync.")
  lines.add("unsafe impl Send for $1 {}" % [ctxTypeName])
  lines.add("unsafe impl Sync for $1 {}" % [ctxTypeName])
  lines.add("")

  # Drop tears down the Nim runtime when the ctx goes out of scope; without it, forgetting the ctx leaks the entire runtime (FFI thread, watchdog, chronos).
  if dtorProcName.len > 0 or hasPump:
    lines.add("impl Drop for $1 {" % [ctxTypeName])
    lines.add("    fn drop(&mut self) {")
    if dtorProcName.len > 0:
      if hasPump:
        lines.add(
          "        // Before the pump stops: the teardown may still send events, and it wakes a blocked poll."
        )
      lines.add("        if !self.ptr.is_null() {")
      lines.add("            unsafe { ffi::$1(self.ptr); }" % [dtorProcName])
      lines.add("            self.ptr = std::ptr::null_mut();")
      lines.add("        }")
    if hasPump:
      lines.add("        self.inner.stop.store(true, Ordering::Release);")
      lines.add("        if let Some(pump) = self.pump.take() {")
      lines.add(
        "            // A listener that drops the context runs on the pump: it cannot join itself."
      )
      lines.add("            if pump.thread().id() != std::thread::current().id() {")
      lines.add("                let _ = pump.join();")
      lines.add("            }")
      lines.add("        }")
    lines.add("    }")
    lines.add("}")
    lines.add("")

  lines.add("impl $1 {" % [ctxTypeName])

  for ctor in ctors:
    let reqName = reqStructName(ctor)
    var paramsList: seq[string] = @[]
    var fieldInits: seq[string] = @[]
    for ep in ctor.extraParams:
      let snake = camelToSnakeCase(ep.name)
      let rustType =
        if ep.ridesAsPtr():
          RustPtrType
        else:
          nimTypeToRust(ep.typeName)
      paramsList.add("$1: $2" % [snake, rustType])
      fieldInits.add(snake)
    # `create` and `new_async` take an explicit `timeout: Duration` that flows into `self.timeout` so subsequent method calls inherit it.
    let ctorParamsStr =
      if paramsList.len > 0:
        paramsList.join(", ") & ", timeout: Duration"
      else:
        "timeout: Duration"

    let reqLit =
      if fieldInits.len > 0:
        reqName & " { " & fieldInits.join(", ") & " }"
      else:
        reqName & " {}"

    lines.add(renderMemberDocComment(ctor.doc))
    lines.add("    pub fn create($1) -> Result<Self, String> {" % [ctorParamsStr])
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    # Ctor also fires the callback carrying the payload, so discard the synchronous *mut c_void and yield RET_OK to wait on the callback.
    lines.add("        let raw_bytes = ffi_call_sync(timeout, |cb, ud| unsafe {")
    lines.add(
      "            let _ = ffi::$1(req_bytes.as_ptr(), req_bytes.len(), cb, ud);" %
        [ctor.procName]
    )
    lines.add("            0")
    lines.add("        })?;")
    # Ctor success payload is a CBOR text string holding the ctx address.
    lines.add("        let addr_str: String = decode_cbor(&raw_bytes)?;")
    lines.add(
      "        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;"
    )
    lines.add("        Self::start(addr as *mut c_void, timeout)")
    lines.add("    }")
    lines.add("")

    lines.add(renderMemberDocComment(ctor.doc))
    lines.add(
      "    pub async fn new_async($1) -> Result<Self, String> {" % [ctorParamsStr]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    # See `create`: discard the ctor's synchronous return; the callback delivers the ctx address.
    lines.add("        let raw_bytes = ffi_call_async(timeout, move |cb, ud| unsafe {")
    lines.add(
      "            let _ = ffi::$1(req_bytes.as_ptr(), req_bytes.len(), cb, ud);" %
        [ctor.procName]
    )
    lines.add("            0")
    lines.add("        }).await?;")
    lines.add("        let addr_str: String = decode_cbor(&raw_bytes)?;")
    lines.add(
      "        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;"
    )
    lines.add("        Self::start(addr as *mut c_void, timeout)")
    lines.add("    }")
    lines.add("")

  if hasPump:
    lines.add(StartTemplate % [libName])
    for ev in events:
      let methodName = "add_" & camelToSnakeCase(ev.nimProcName) & "_listener"
      lines.add(renderMemberDocComment(ev.doc))
      lines.add(
        "    /// Register a typed listener for `$1`. The returned handle can be" %
          [ev.wireName]
      )
      lines.add("    /// passed to `remove_event_listener` to unregister.")
      lines.add("    pub fn $1<F>(&self, handler: F) -> ListenerHandle" % [methodName])
      lines.add("    where F: Fn(&$1) + Send + Sync + 'static," % [ev.payloadTypeName])
      lines.add("    {")
      lines.add("        self.inner.add(Arc::new(move |m: &$1| {" % [msgTypeName])
      lines.add(
        "            if let $1::$2(payload) = m { handler(payload) }" %
          [msgTypeName, capitalizeFirstLetter(ev.nimProcName)]
      )
      lines.add("        }))")
      lines.add("    }")
      lines.add("")
    lines.add(ListenersTemplate % [msgTypeName])

  # A static is an associated fn: no `&self` to read `timeout` from, so it takes one.
  for m in classified.replyProcs():
    let isStatic = m.isStatic()
    let methodName = stripLibPrefix(m.procName, libName)
    let retRustType = nimTypeToRust(m.returnTypeName)
    let reqName = reqStructName(m)

    var paramsList: seq[string] = @[]
    var fieldInits: seq[string] = @[]
    for ep in m.extraParams:
      let snake = camelToSnakeCase(ep.name)
      let rustType =
        if ep.ridesAsPtr():
          RustPtrType
        else:
          nimTypeToRust(ep.typeName)
      paramsList.add("$1: $2" % [snake, rustType])
      fieldInits.add(snake)
    if isStatic:
      paramsList.add("timeout: Duration")
    let paramsStr =
      if isStatic:
        paramsList.join(", ")
      elif paramsList.len > 0:
        "&self, " & paramsList.join(", ")
      else:
        "&self"

    let reqLit =
      if fieldInits.len > 0:
        reqName & " { " & fieldInits.join(", ") & " }"
      else:
        reqName & " {}"

    let retTypeForApi = if m.returnRidesAsPtr(): RustPtrType else: retRustType
    let timeoutExpr = if isStatic: "timeout" else: "self.timeout"
    let ctxArg = if isStatic: "" else: "self.ptr, "

    lines.add(renderMemberDocComment(m.doc))
    lines.add(
      "    pub fn $1($2) -> Result<$3, String> {" %
        [methodName, paramsStr, retTypeForApi]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add(
      "        let raw_bytes = ffi_call_sync($1, |cb, ud| unsafe {" % [timeoutExpr]
    )
    lines.add(
      "            ffi::$1($2cb, ud, req_bytes.as_ptr(), req_bytes.len())" %
        [m.procName, ctxArg]
    )
    lines.add("        })?;")
    lines.add("        decode_cbor::<$1>(&raw_bytes)" % [retTypeForApi])
    lines.add("    }")
    lines.add("")

    # async method: ptr cast to usize (Copy + Send) keeps the move closure and returned future Send for multi-threaded tokio runtimes.
    lines.add(renderMemberDocComment(m.doc))
    lines.add(
      "    pub async fn $1_async($2) -> Result<$3, String> {" %
        [methodName, paramsStr, retTypeForApi]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    if not isStatic:
      lines.add("        let ptr = self.ptr as usize;")
    lines.add(
      "        let raw_bytes = ffi_call_async($1, move |cb, ud| unsafe {" % [
        timeoutExpr
      ]
    )
    lines.add(
      "            ffi::$1($2cb, ud, req_bytes.as_ptr(), req_bytes.len())" %
        [m.procName, if isStatic: "" else: "ptr as *mut c_void, "]
    )
    lines.add("        }).await?;")
    lines.add("        decode_cbor::<$1>(&raw_bytes)" % [retTypeForApi])
    lines.add("    }")
    lines.add("")

  # An associated fn, not a method: a host calls it with no context left to call it on.
  lines.add(renderMemberDocComment(ShutdownDoc))
  lines.add("    /// This wrapper reports that as true.")
  lines.add("    pub fn shutdown() -> bool {")
  lines.add("        unsafe { ffi::$1_shutdown() == 0 }" % [libName])
  lines.add("    }")
  lines.add("")

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
  writeOutputFile(buildPath(srcDir, "ffi.rs"), generateFFIRs(procs))
  writeOutputFile(buildPath(srcDir, "types.rs"), generateTypesRs(types, procs, consts))
  writeOutputFile(buildPath(srcDir, "api.rs"), generateApiRs(procs, libName, events))
