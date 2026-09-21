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
  # flume: the channel a reply waits in (recv_timeout + recv_async), default-features off. tokio: only the async timeout.
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

const StaticCtxDoc =
  """The token of the static context, where the reply of every static request
arrives; poll it like any other context. Null on failure."""

const LastErrorDoc =
  """Why the calling thread's last request was refused. Never null, empty when
nothing was refused; valid until the thread's next refusal."""

proc generateFFIRs*(procs: seq[FFIProcMeta]): string =
  ## Generates ffi.rs with extern "C" declarations; each proc takes one CBOR
  ## buffer (ptr+len) as its request payload.
  var lines: seq[string] = @[]
  # The whole ABI is declared here; the wrapper in api.rs does not use all of it.
  lines.add("#![allow(dead_code)]")
  lines.add("")
  lines.add("use std::os::raw::{c_char, c_int, c_void};")
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
  lines.add("// A request returns once it is queued. NIMFFI_RET_OK promises one")
  lines.add(
    "// NIMFFI_MSG_REPLY whose `id` is `*req_id_out`; any other return means no"
  )
  lines.add("// reply will come, and `$1_last_error` says why." % [linkLibName])
  lines.add("#[link(name = \"$1\")]" % [linkLibName])
  lines.add("extern \"C\" {")

  for p in procs:
    var params: seq[string] = @[]
    lines.add(renderMemberDocComment(p.doc))
    case p.kind
    of FFIKind.FFI, FFIKind.STATIC:
      if not p.isStatic():
        params.add("ctx: *mut c_void")
      params.add("req_cbor: *const u8")
      params.add("req_cbor_len: usize")
      params.add("req_id_out: *mut u64")
    of FFIKind.CTOR:
      # The token comes back at once so the host can poll it; the reply says
      # whether construction worked.
      params.add("req_cbor: *const u8")
      params.add("req_cbor_len: usize")
      params.add("ctx_out: *mut *mut c_void")
      params.add("req_id_out: *mut u64")
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
  lines.add(renderMemberDocComment(StaticCtxDoc))
  lines.add("    pub fn $1_static_ctx() -> *mut c_void;" % [linkLibName])
  lines.add(renderMemberDocComment(LastErrorDoc))
  lines.add("    pub fn $1_last_error() -> *const c_char;" % [linkLibName])
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
    "/// Everything `$1` sends to the host besides replies: its events, the" % [libName]
  )
  lines.add(
    "/// progress and liveness reports and the end of the context. The pump thread"
  )
  lines.add(
    "/// of a context decodes each message into one of these before a listener runs."
  )
  lines.add(
    "/// A reply is not listed: it goes to the call that waits for it, which decodes"
  )
  lines.add("/// it into that call's return type.")
  lines.add("#[derive(Debug, Clone)]")
  lines.add("pub enum $1 {" % [msgTypeName])
  for ev in events:
    lines.add(renderMemberDocComment(ev.doc))
    lines.add(
      "    $1($2)," % [capitalizeFirstLetter(ev.nimProcName), ev.payloadTypeName]
    )
  lines.add(
    "    /// Request `req_id` has been running for `elapsed_ms`. Not a reply: the"
  )
  lines.add("    /// request still runs and its call still returns.")
  lines.add("    StaleWarn { req_id: u64, elapsed_ms: u64 },")
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
    "    /// library could not recycle the context, and `reason` then says why. Every"
  )
  lines.add(
    "    /// call still waiting for its reply has failed by the time a listener sees it."
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
  lines.add("unsafe fn payload_bytes(msg: &ffi::NimFfiMsg) -> &[u8] {")
  lines.add("    if msg.payload.is_null() || msg.len == 0 {")
  lines.add("        &[]")
  lines.add("    } else {")
  lines.add("        slice::from_raw_parts(msg.payload, msg.len)")
  lines.add("    }")
  lines.add("}")
  lines.add("")
  lines.add("unsafe fn decode_message(msg: &ffi::NimFfiMsg) -> $1 {" % [msgTypeName])
  lines.add("    let bytes = payload_bytes(msg);")
  lines.add("    let decoded = match msg.kind {")
  lines.add("        ffi::NIMFFI_MSG_EVENT => match msg.name_id {")
  for ev in events:
    lines.add(
      "            $1 => decode_cbor(bytes).map($2::$3)," %
        [evConstName(libName, ev), msgTypeName, capitalizeFirstLetter(ev.nimProcName)]
    )
  lines.add("            _ => Err(\"unknown event\".to_string()),")
  lines.add("        },")
  lines.add("        ffi::NIMFFI_MSG_STALE_WARN => Ok($1::StaleWarn {" % [msgTypeName])
  lines.add("            req_id: msg.id,")
  lines.add("            elapsed_ms: msg.aux,")
  lines.add("        }),")
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
const PumpTemplate =
  """// A reply: the CBOR of the return value, or the library's error text.
type FFIResult = Result<Vec<u8>, String>;
type Handler = Arc<dyn Fn(&$2) + Send + Sync>;

const CONTEXT_CLOSED: &str = "context closed before the reply arrived";

/// Returned by every `add_*_listener`; pass it to `remove_event_listener`.
#[derive(Debug, Clone, Copy)]
pub struct ListenerHandle { pub id: u64 }

// What a context shares with its pump thread.
struct Inner {
    ptr: *mut c_void,
    listeners: Mutex<Vec<(u64, Handler)>>,
    // The calls that wait for a reply, by request id.
    waiters: Mutex<HashMap<u64, flume::Sender<FFIResult>>>,
    next_id: AtomicU64,
    stop: AtomicBool,
    // Written under the `waiters` lock: no reply can be delivered any more.
    ended: AtomicBool,
    pump_thread: OnceLock<ThreadId>,
}

// SAFETY: `ptr` is a token the library validates on every call, never
// dereferenced here. `$1_poll` admits one consumer per context and only the
// pump thread polls; everything else in `Inner` is already Sync.
unsafe impl Send for Inner {}
unsafe impl Sync for Inner {}

// No lock here is held while foreign code of the host runs, so a panic cannot poison one; recover anyway.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

// Why the library refused a request. `$1_last_error` is per thread: call this
// on the refused thread, before its next request.
fn last_error(ret: c_int) -> String {
    let text = unsafe { CStr::from_ptr(ffi::$1_last_error()) }.to_string_lossy().into_owned();
    if text.is_empty() { format!("request refused (NIMFFI_RET {ret})") } else { text }
}

fn spawn_pump(name: &str, inner: Arc<Inner>) -> Result<JoinHandle<()>, String> {
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || pump_loop(inner))
        .map_err(|e| e.to_string())
}

impl Inner {
    fn new(ptr: *mut c_void) -> Self {
        Inner {
            ptr,
            listeners: Mutex::new(Vec::new()),
            waiters: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            stop: AtomicBool::new(false),
            ended: AtomicBool::new(false),
            pump_thread: OnceLock::new(),
        }
    }

    fn add(&self, handler: Handler) -> ListenerHandle {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        lock(&self.listeners).push((id, handler));
        ListenerHandle { id }
    }

    fn remove(&self, id: u64) -> bool {
        let mut listeners = lock(&self.listeners);
        let before = listeners.len();
        listeners.retain(|(lid, _)| *lid != id);
        listeners.len() != before
    }

    fn dispatch(&self, message: &$2) {
        // Cloned out so a handler may add or remove listeners.
        let handlers: Vec<Handler> = lock(&self.listeners).iter().map(|(_, h)| h.clone()).collect();
        for handler in handlers {
            // A panicking handler must not end the pump; the panic hook already reported it.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handler(message)));
        }
    }

    // Sends a request with `send(ctx, req_id_out)` and registers the waiter of its reply.
    fn submit<F>(&self, send: F) -> Result<(u64, flume::Receiver<FFIResult>), String>
    where
        F: FnOnce(*mut c_void, *mut u64) -> c_int,
    {
        let (tx, rx) = flume::bounded::<FFIResult>(1);
        let mut req_id: u64 = 0;
        // Held across the call: the pump can poll the reply before the call
        // returns, and takes this lock before it looks the waiter up.
        let mut waiters = lock(&self.waiters);
        let ret = send(self.ptr, &mut req_id);
        if ret != NIMFFI_RET_OK {
            // Refused: no reply will come, so nothing is registered.
            return Err(last_error(ret));
        }
        if self.ended.load(Ordering::Acquire) {
            return Err(CONTEXT_CLOSED.into());
        }
        waiters.insert(req_id, tx);
        Ok((req_id, rx))
    }

    // Hands a reply to its waiter. One without a waiter is dropped: its call timed out.
    unsafe fn complete(&self, msg: &ffi::NimFfiMsg) {
        let waiter = lock(&self.waiters).remove(&msg.id);
        if let Some(tx) = waiter {
            let bytes = payload_bytes(msg);
            let reply = if msg.ret_code == NIMFFI_RET_OK {
                Ok(bytes.to_vec())
            } else {
                // Lossy: the text comes from a Nim `string`, so invalid UTF-8 is a library bug.
                Err(String::from_utf8_lossy(bytes).into_owned())
            };
            // The call may have gone away meanwhile (a dropped future).
            let _ = tx.send(reply);
        }
    }

    // No reply can arrive any more: dropping a sender fails its call with CONTEXT_CLOSED.
    fn fail_waiters(&self) {
        let mut waiters = lock(&self.waiters);
        self.ended.store(true, Ordering::Release);
        waiters.clear();
    }

    // Forgets the waiter so a late reply is dropped; a reply that raced the timeout still counts.
    fn timed_out(&self, req_id: u64, rx: &flume::Receiver<FFIResult>, timeout: Duration) -> FFIResult {
        lock(&self.waiters).remove(&req_id);
        rx.try_recv().unwrap_or_else(|_| Err(format!("timed out after {:?}", timeout)))
    }

    fn wait(&self, req_id: u64, rx: &flume::Receiver<FFIResult>, timeout: Duration) -> FFIResult {
        if self.pump_thread.get() == Some(&std::thread::current().id()) {
            return self.wait_on_pump(req_id, rx, timeout);
        }
        match rx.recv_timeout(timeout) {
            Ok(reply) => reply,
            Err(flume::RecvTimeoutError::Timeout) => self.timed_out(req_id, rx, timeout),
            Err(flume::RecvTimeoutError::Disconnected) => Err(CONTEXT_CLOSED.into()),
        }
    }

    // A blocking call made by a listener runs on the pump thread, the only one
    // that can deliver its reply: keep pumping here until that reply arrives.
    fn wait_on_pump(&self, req_id: u64, rx: &flume::Receiver<FFIResult>, timeout: Duration) -> FFIResult {
        let deadline = Instant::now() + timeout;
        loop {
            match rx.try_recv() {
                Ok(reply) => return reply,
                Err(flume::TryRecvError::Disconnected) => return Err(CONTEXT_CLOSED.into()),
                Err(flume::TryRecvError::Empty) => {}
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return self.timed_out(req_id, rx, timeout);
            }
            let slice_ms = left.as_millis().clamp(1, $3) as i32;
            pump_step(self, slice_ms);
        }
    }

    // The `.await` of an `_async` call. It must not run on the pump thread (inside
    // a listener): nothing would pump the reply, and the call would time out.
    async fn wait_async(&self, req_id: u64, rx: flume::Receiver<FFIResult>, timeout: Duration) -> FFIResult {
        match tokio::time::timeout(timeout, rx.recv_async()).await {
            Ok(Ok(reply)) => reply,
            Ok(Err(_)) => Err(CONTEXT_CLOSED.into()),
            Err(_) => self.timed_out(req_id, &rx, timeout),
        }
    }
}

enum Step { Message, Idle, Ended }

// One poll: a reply goes to its waiter, anything else to the listeners.
fn pump_step(inner: &Inner, timeout_ms: i32) -> Step {
    if inner.ended.load(Ordering::Acquire) {
        return Step::Ended;
    }
    // The library owns the message; it is valid until the next poll.
    let mut msg: *const ffi::NimFfiMsg = std::ptr::null();
    let ret = unsafe { ffi::$1_poll(inner.ptr, timeout_ms, &mut msg) };
    match ret {
        NIMFFI_RET_OK | NIMFFI_RET_CLOSED if !msg.is_null() => {
            let msg = unsafe { &*msg };
            if msg.kind == ffi::NIMFFI_MSG_REPLY {
                unsafe { inner.complete(msg) };
                return Step::Message;
            }
            // Decoded before a listener runs: a listener's blocking call polls again.
            let message = unsafe { decode_message(msg) };
            if ret == NIMFFI_RET_CLOSED {
                inner.fail_waiters();
            }
            inner.dispatch(&message);
            if ret == NIMFFI_RET_CLOSED { Step::Ended } else { Step::Message }
        }
        NIMFFI_RET_TIMEOUT => Step::Idle,
        NIMFFI_RET_INVALID_CTX => {
            // The context ended between two polls, so its CLOSED message was never seen.
            inner.fail_waiters();
            inner.dispatch(&$2::Closed { ok: true, reason: String::new() });
            Step::Ended
        }
        // NIMFFI_RET_BUSY, NIMFFI_RET_ERR: try again, without spinning.
        _ => {
            std::thread::sleep(Duration::from_millis(10));
            Step::Idle
        }
    }
}

// The context's only poller.
fn pump_loop(inner: Arc<Inner>) {
    let _ = inner.pump_thread.set(std::thread::current().id());
    loop {
        // Once asked to stop, only take what already waits: a teardown's last messages.
        let stopping = inner.stop.load(Ordering::Acquire);
        let timeout_ms = if stopping { 0 } else { $3 };
        match pump_step(&inner, timeout_ms) {
            Step::Message => {}
            Step::Idle => {
                if stopping {
                    break;
                }
            }
            Step::Ended => break,
        }
    }
    // Nobody delivers a reply from here on.
    inner.fail_waiters();
}
"""

# $1 lib name.
const StaticPumpTemplate = """struct StaticPump {
    inner: Arc<Inner>,
    thread: JoinHandle<()>,
}

// The reply of a static request arrives on the library's static context: one
// pump per process, started by the first static call and stopped by `shutdown`.
// Its thread does not keep the process alive.
static STATIC_PUMP: Mutex<Option<StaticPump>> = Mutex::new(None);

fn static_inner() -> Result<Arc<Inner>, String> {
    let mut slot = lock(&STATIC_PUMP);
    if let Some(pump) = slot.as_ref() {
        if !pump.inner.ended.load(Ordering::Acquire) {
            return Ok(pump.inner.clone());
        }
    }
    let ptr = unsafe { ffi::$1_static_ctx() };
    if ptr.is_null() {
        return Err(last_error(NIMFFI_RET_ERR));
    }
    let inner = Arc::new(Inner::new(ptr));
    let thread = spawn_pump("$1-static-pump", inner.clone())?;
    *slot = Some(StaticPump { inner: inner.clone(), thread });
    Ok(inner)
}

fn stop_static_pump(slot: &mut Option<StaticPump>) {
    if let Some(pump) = slot.take() {
        pump.inner.stop.store(true, Ordering::Release);
        if pump.thread.thread().id() != std::thread::current().id() {
            let _ = pump.thread.join();
        }
    }
}
"""

# $1 lib name.
const StartTemplate =
  """    // `submit` is the ctor export. The waiter of its reply is registered before
    // the pump starts, so the pump cannot see the reply first.
    fn start(
        req_bytes: &[u8],
        timeout: Duration,
        submit: unsafe extern "C" fn(*const u8, usize, *mut *mut c_void, *mut u64) -> c_int,
    ) -> Result<(Self, u64, flume::Receiver<FFIResult>), String> {
        let mut ptr: *mut c_void = std::ptr::null_mut();
        let mut req_id: u64 = 0;
        let ret = unsafe { submit(req_bytes.as_ptr(), req_bytes.len(), &mut ptr, &mut req_id) };
        if ret != NIMFFI_RET_OK || ptr.is_null() {
            // Nothing was claimed, so there is nothing to destroy.
            return Err(last_error(ret));
        }
        let inner = Arc::new(Inner::new(ptr));
        let (tx, rx) = flume::bounded::<FFIResult>(1);
        lock(&inner.waiters).insert(req_id, tx);
        // Built before the thread: from here on, an early return drops it, which destroys the context.
        let mut ctx = Self { ptr, timeout, inner: inner.clone(), pump: None };
        ctx.pump = Some(spawn_pump("$1-pump", inner)?);
        Ok((ctx, req_id, rx))
    }
"""

# $1 message enum.
const ListenersTemplate =
  """    /// Register a listener for `StaleWarn`; it receives the request id and the
    /// milliseconds the request has been running.
    pub fn add_stale_warn_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(u64, u64) + Send + Sync + 'static,
    {
        self.inner.add(Arc::new(move |m: &$1| {
            if let $1::StaleWarn { req_id, elapsed_ms } = m { handler(*req_id, *elapsed_ms) }
        }))
    }

    /// Register a listener for `NotResponding`; it receives the reason.
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
  # Only a context made by a ctor has listeners; the static one just delivers replies.
  let hasCtor = ctors.len > 0
  let hasStatics = classified.statics.len > 0

  if not hasCtor:
    # No context to hang the listeners on, so that half of the pump goes unused.
    lines.add("#![allow(dead_code)]")
    lines.add("")
  lines.add("use std::collections::HashMap;")
  lines.add("use std::ffi::CStr;")
  lines.add("use std::os::raw::{c_int, c_void};")
  lines.add("use std::slice;")
  lines.add("use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};")
  lines.add("use std::sync::{Arc, Mutex, MutexGuard, OnceLock};")
  lines.add("use std::thread::{JoinHandle, ThreadId};")
  lines.add("use std::time::{Duration, Instant};")
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
  lines.add("// nim-ffi status codes, emitted from ffi/ret_codes.nim.")
  lines.add(rustRetCodeConsts())
  lines.add("")

  lines.add(generateMessages(events, libName, msgTypeName))
  lines.add(PumpTemplate % [libName, msgTypeName, $PumpSliceMs])
  if hasStatics:
    lines.add(StaticPumpTemplate % [libName])

  lines.add("/// High-level context for `$1`." % [libTypeName])
  lines.add("///")
  lines.add(
    "/// Every request has a blocking method and an `_async` one. Both send the request,"
  )
  lines.add("/// then wait for its reply, which the context's pump thread takes out of")
  lines.add(
    "/// `$1_poll`; `Err` carries the library's error text, the reason a request was" %
      [libName]
  )
  lines.add("/// refused, a timeout, or the end of the context.")
  lines.add("///")
  lines.add(
    "/// Listeners run on the pump thread. One may make a blocking call on its own"
  )
  lines.add(
    "/// context: the call pumps the context itself until its reply arrives, so other"
  )
  lines.add(
    "/// listeners can run meanwhile. It must not block on an `_async` call: nothing"
  )
  lines.add(
    "/// pumps the reply while the pump thread is parked, so the call times out."
  )
  lines.add("pub struct $1 {" % [ctxTypeName])
  lines.add("    ptr: *mut c_void,")
  lines.add("    timeout: Duration,")
  if hasCtor:
    lines.add("    inner: Arc<Inner>,")
    lines.add("    pump: Option<JoinHandle<()>>,")
  lines.add("}")
  lines.add("")
  # SAFETY block applies to both impls below.
  lines.add(
    "// SAFETY: `ptr` is a token the library validates on every call; it is never"
  )
  lines.add("// dereferenced here. A request export only checks the token and puts the")
  lines.add(
    "// request on a lock-guarded queue, which is sound from any number of threads;"
  )
  lines.add(
    "// the library's single FFI thread runs every handler. Replies and events come"
  )
  lines.add(
    "// back through the pump thread alone, and the waiter table and the listeners"
  )
  lines.add("// it shares with the callers are behind mutexes.")
  lines.add("unsafe impl Send for $1 {}" % [ctxTypeName])
  lines.add("unsafe impl Sync for $1 {}" % [ctxTypeName])
  lines.add("")

  # Drop tears down the Nim runtime when the ctx goes out of scope; without it, forgetting the ctx leaks the entire runtime (FFI thread, watchdog, chronos).
  if dtorProcName.len > 0 or hasCtor:
    lines.add("impl Drop for $1 {" % [ctxTypeName])
    lines.add("    fn drop(&mut self) {")
    if dtorProcName.len > 0:
      if hasCtor:
        lines.add(
          "        // Before the pump stops: the teardown may still send events, and it wakes a blocked poll."
        )
      lines.add("        if !self.ptr.is_null() {")
      lines.add("            unsafe { ffi::$1(self.ptr); }" % [dtorProcName])
      lines.add("            self.ptr = std::ptr::null_mut();")
      lines.add("        }")
    if hasCtor:
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

    # The ctor's reply only says whether construction worked.
    lines.add(renderMemberDocComment(ctor.doc))
    lines.add("    pub fn create($1) -> Result<Self, String> {" % [ctorParamsStr])
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add(
      "        let (ctx, req_id, rx) = Self::start(&req_bytes, timeout, ffi::$1)?;" %
        [ctor.procName]
    )
    lines.add(
      "        // An error reply or a timeout drops `ctx`, which destroys the context."
    )
    lines.add("        ctx.inner.wait(req_id, &rx, timeout)?;")
    lines.add("        Ok(ctx)")
    lines.add("    }")
    lines.add("")

    lines.add(renderMemberDocComment(ctor.doc))
    lines.add(
      "    pub async fn new_async($1) -> Result<Self, String> {" % [ctorParamsStr]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add(
      "        let (ctx, req_id, rx) = Self::start(&req_bytes, timeout, ffi::$1)?;" %
        [ctor.procName]
    )
    lines.add(
      "        // An error reply or a timeout drops `ctx`, which destroys the context."
    )
    lines.add("        ctx.inner.wait_async(req_id, rx, timeout).await?;")
    lines.add("        Ok(ctx)")
    lines.add("    }")
    lines.add("")

  if hasCtor:
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
    var timeoutExpr = "self.timeout"
    var innerExpr = "self.inner"
    # The static export takes no ctx: its replies arrive on the static context.
    var submitCall =
      "|ctx, req_id| unsafe { ffi::$1(ctx, req_bytes.as_ptr(), req_bytes.len(), req_id) }" %
      [m.procName]
    if isStatic:
      timeoutExpr = "timeout"
      innerExpr = "inner"
      submitCall =
        "|_, req_id| unsafe { ffi::$1(req_bytes.as_ptr(), req_bytes.len(), req_id) }" %
        [m.procName]

    for isAsync in [false, true]:
      lines.add(renderMemberDocComment(m.doc))
      if isAsync:
        lines.add(
          "    pub async fn $1_async($2) -> Result<$3, String> {" %
            [methodName, paramsStr, retTypeForApi]
        )
      else:
        lines.add(
          "    pub fn $1($2) -> Result<$3, String> {" %
            [methodName, paramsStr, retTypeForApi]
        )
      lines.add("        let req = $1;" % [reqLit])
      lines.add("        let req_bytes = encode_cbor(&req)?;")
      if isStatic:
        lines.add("        let inner = static_inner()?;")
      lines.add("        let (req_id, rx) = $1.submit(" % [innerExpr])
      lines.add("            $1," % [submitCall])
      lines.add("        )?;")
      if isAsync:
        lines.add(
          "        let raw_bytes = $1.wait_async(req_id, rx, $2).await?;" %
            [innerExpr, timeoutExpr]
        )
      else:
        lines.add(
          "        let raw_bytes = $1.wait(req_id, &rx, $2)?;" % [
            innerExpr, timeoutExpr
          ]
        )
      lines.add("        decode_cbor::<$1>(&raw_bytes)" % [retTypeForApi])
      lines.add("    }")
      lines.add("")

  # An associated fn, not a method: a host calls it with no context left to call it on.
  lines.add(renderMemberDocComment(ShutdownDoc))
  lines.add("    /// This wrapper reports that as true.")
  lines.add("    pub fn shutdown() -> bool {")
  if hasStatics:
    lines.add(
      "        // Held across the shutdown, so no static call starts a pump on a context about to go."
    )
    lines.add("        let mut static_pump = lock(&STATIC_PUMP);")
    lines.add("        stop_static_pump(&mut static_pump);")
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
