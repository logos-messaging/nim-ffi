## Rust binding generator for the nim-ffi framework.
## Generates a complete Rust crate that uses CBOR (ciborium) on the wire.

import std/[os, strutils]
import ./meta, ./string_helpers

## Wire-format Rust type used for any Nim `ptr T` / `pointer`. Fixed 64-bit so
## the CBOR payload size is stable regardless of host architecture (mirrors
## CppPtrType in cpp.nim).
const RustPtrType* = "u64"

proc nimTypeToRust*(typeName: string): string =
  ## Maps Nim type names to Rust type names, including generics.
  let t = typeName.strip()
  if t.startsWith("seq[") and t.endsWith("]"):
    return "Vec<" & nimTypeToRust(t[4 .. ^2]) & ">"
  if t.startsWith("Option[") and t.endsWith("]"):
    return "Option<" & nimTypeToRust(t[7 .. ^2]) & ">"
  if t.startsWith("Maybe[") and t.endsWith("]"):
    return "Option<" & nimTypeToRust(t[6 .. ^2]) & ">"
  case t
  of "string", "cstring":
    "String"
  of "int", "int64":
    "i64"
  of "int32":
    "i32"
  of "bool":
    "bool"
  of "float", "float64":
    "f64"
  of "pointer":
    RustPtrType
  else:
    capitalizeFirstLetter(t)

proc deriveLibName*(procs: seq[FFIProcMeta]): string =
  ## Extracts the common prefix before the first `_` from proc names.
  ## e.g. ["timer_create", "timer_echo"] → "timer"
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
  ## Strips the library prefix from a proc name.
  ## e.g. "timer_echo", "timer" → "echo"
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

# ---------------------------------------------------------------------------
# File generators
# ---------------------------------------------------------------------------

proc generateCargoToml*(libName: string): string =
  # `flume` is the unified callback channel (PR #23 Rust review, item 8): one
  # primitive that supports both `recv_timeout` (blocking trampoline) and
  # `recv_async` (async trampoline). Default-features disabled to avoid
  # pulling its async-std/futures shims.
  # `tokio` is needed only for `tokio::time::timeout` around the async
  # `recv_async`. Feature-gating tokio (item 11) is a follow-up commit.
  return
    """[package]
name = "$1"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }
ciborium = "0.2"
flume = { version = "0.11", default-features = false, features = ["async"] }
tokio = { version = "1", features = ["sync", "time"] }
""" %
    [libName]

proc generateBuildRs*(libName: string, nimSrcRelPath: string): string =
  ## Generates build.rs that compiles the Nim library.
  ## nimSrcRelPath is relative to the output (crate) directory.
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

proc generateFFIRs*(procs: seq[FFIProcMeta]): string =
  ## Generates ffi.rs with extern "C" declarations. Each Nim FFI proc takes a
  ## single CBOR buffer (ptr+len) for its request payload.
  var lines: seq[string] = @[]
  lines.add("use std::os::raw::{c_char, c_int, c_void};")
  lines.add("")
  lines.add("pub type FFICallback = unsafe extern \"C\" fn(")
  lines.add("    ret: c_int,")
  lines.add("    msg: *const c_char,")
  lines.add("    len: usize,")
  lines.add("    user_data: *mut c_void,")
  lines.add(");")
  lines.add("")

  # Collect unique lib names for #[link(...)]
  var libNames: seq[string] = @[]
  for p in procs:
    if p.libName notin libNames:
      libNames.add(p.libName)

  # Derive lib name from proc names if not set
  var linkLibName = ""
  if libNames.len > 0 and libNames[0].len > 0:
    linkLibName = libNames[0]
  else:
    # derive from first proc name
    if procs.len > 0:
      let parts = procs[0].procName.split('_')
      if parts.len > 0:
        linkLibName = parts[0]

  lines.add("#[link(name = \"$1\")]" % [linkLibName])
  lines.add("extern \"C\" {")

  for p in procs:
    var params: seq[string] = @[]
    case p.kind
    of FFIKind.FFI:
      # Method/destructor-style: ctx comes first
      params.add("ctx: *mut c_void")
      params.add("callback: FFICallback")
      params.add("user_data: *mut c_void")
      params.add("req_cbor: *const u8")
      params.add("req_cbor_len: usize")
      lines.add("    pub fn $1($2) -> c_int;" % [p.procName, params.join(", ")])
    of FFIKind.CTOR:
      # Constructor: no ctx; returns the freshly-allocated handle
      params.add("req_cbor: *const u8")
      params.add("req_cbor_len: usize")
      params.add("callback: FFICallback")
      params.add("user_data: *mut c_void")
      lines.add("    pub fn $1($2) -> *mut c_void;" % [p.procName, params.join(", ")])
    of FFIKind.DTOR:
      params.add("ctx: *mut c_void")
      lines.add("    pub fn $1($2) -> c_int;" % [p.procName, params.join(", ")])

  lines.add("}")
  return lines.join("\n") & "\n"

proc generateTypesRs*(types: seq[FFITypeMeta], procs: seq[FFIProcMeta]): string =
  ## Generates types.rs with Rust structs for all user-declared FFI types and
  ## for each per-proc Req struct (matching the Nim macro's generated types).
  var lines: seq[string] = @[]
  lines.add("use serde::{Deserialize, Serialize};")
  lines.add("")

  for t in types:
    lines.add("#[derive(Debug, Clone, Serialize, Deserialize)]")
    lines.add("pub struct $1 {" % [t.name])
    for f in t.fields:
      let snakeName = camelToSnakeCase(f.name)
      let rustType = nimTypeToRust(f.typeName)
      # Add serde rename if camelCase name differs from snake_case
      if snakeName != f.name:
        lines.add("    #[serde(rename = \"$1\")]" % [f.name])
      lines.add("    pub $1: $2," % [snakeName, rustType])
    lines.add("}")
    lines.add("")

  # Per-proc Req structs — these wrap the typed parameters and are the unit of
  # CBOR encoding sent across the FFI boundary.
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
          if ep.isPtr:
            RustPtrType
          else:
            nimTypeToRust(ep.typeName)
        if snake != ep.name:
          lines.add("    #[serde(rename = \"$1\")]" % [ep.name])
        lines.add("    pub $1: $2," % [snake, rustType])
      lines.add("}")
    lines.add("")

  return lines.join("\n")

proc generateApiRs*(procs: seq[FFIProcMeta], libName: string): string =
  ## Generates api.rs with both a blocking and a tokio-async high-level API.
  ##
  ## Blocking: ctx.echo(req)             — thread-blocks via Condvar
  ## Async:    ctx.echo_async(req).await — non-blocking via oneshot channel;
  ##           the FFI callback fires from the Nim/chronos thread and wakes
  ##           the awaiting task without ever blocking a thread.
  ##
  ## Requests/responses are CBOR (ciborium); errors are raw UTF-8 strings.
  var lines: seq[string] = @[]

  var ctors: seq[FFIProcMeta] = @[]
  var methods: seq[FFIProcMeta] = @[]
  var dtorProcName = ""
  for p in procs:
    case p.kind
    of FFIKind.CTOR:
      ctors.add(p)
    of FFIKind.FFI:
      methods.add(p)
    of FFIKind.DTOR:
      if dtorProcName.len == 0:
        dtorProcName = p.procName

  var libTypeName = ""
  if ctors.len > 0:
    libTypeName = ctors[0].libTypeName
  else:
    libTypeName = capitalizeFirstLetter(libName)

  let ctxTypeName = libTypeName & "Ctx"

  # ── Imports ────────────────────────────────────────────────────────────────
  lines.add("use std::os::raw::{c_char, c_int, c_void};")
  lines.add("use std::slice;")
  lines.add("use std::time::Duration;")
  lines.add("use serde::de::DeserializeOwned;")
  lines.add("use serde::Serialize;")
  lines.add("use super::ffi;")
  lines.add("use super::types::*;")
  lines.add("")

  # ── CBOR helpers ───────────────────────────────────────────────────────────
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

  # ── Unified FFI trampoline (PR #23 Rust review, items 1, 2, 4, 8, 9) ───────
  # One callback shape used by both the blocking and async wrappers. The
  # `user_data` pointer owns a single `Box<flume::Sender<Result<Vec<u8>,
  # String>>>`; the callback reconstructs it, sends the payload, and drops
  # the box (releasing the sender). The receiver side then either
  # `recv_timeout` (sync) or `recv_async` under `tokio::time::timeout`
  # (async). A late callback that fires after the caller has already timed
  # out sends into a closed receiver, which is harmless: the Err is
  # discarded and the box drops cleanly. No Arc/Condvar; no Box leak; no
  # late-fire UAF; no double trampoline.
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
  lines.add("    if ret == 0 { Ok(bytes) }")
  lines.add("    else        { Err(String::from_utf8_lossy(&bytes).into_owned()) }")
  lines.add("}")
  lines.add("")
  lines.add("unsafe extern \"C\" fn on_result(")
  lines.add("    ret: c_int,")
  lines.add("    msg: *const c_char,")
  lines.add("    len: usize,")
  lines.add("    user_data: *mut c_void,")
  lines.add(") {")
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
  lines.add(
    "    // happen with the current rust_client demo but may occur in arbitrary"
  )
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
  lines.add("    if ret == 2 {")
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
  lines.add("    if ret == 2 {")
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

  # ── Context struct ─────────────────────────────────────────────────────────
  lines.add("/// High-level context for `$1`." % [libTypeName])
  lines.add("pub struct $1 {" % [ctxTypeName])
  lines.add("    ptr: *mut c_void,")
  lines.add("    timeout: Duration,")
  lines.add("}")
  lines.add("")
  # SAFETY block applies to both impls below (PR #23 Rust review, item 7).
  lines.add(
    "// SAFETY: The `ptr` field points to an FFIContext owned by the Nim runtime."
  )
  lines.add("// Every call through the generated FFI proc goes through")
  lines.add(
    "// `sendRequestToFFIThread` on the Nim side, which serialises every request"
  )
  lines.add(
    "// behind `ctx.lock` and dispatches handlers on a single FFI thread, so the"
  )
  lines.add(
    "// pointer is never accessed concurrently from Rust. The Nim-side reentrancy"
  )
  lines.add("// guard (`onFFIThread` threadvar) prevents handlers from re-entering the")
  lines.add(
    "// dispatcher and self-deadlocking. These invariants make it sound to mark"
  )
  lines.add("// the wrapper as Send + Sync.")
  lines.add("unsafe impl Send for $1 {}" % [ctxTypeName])
  lines.add("unsafe impl Sync for $1 {}" % [ctxTypeName])
  lines.add("")

  # ── Drop: tears down the Nim runtime when the ctx goes out of scope ──────
  # Without this, forgetting the ctx leaks the entire Nim runtime (FFI thread,
  # watchdog, chronos, lib state). Mirrors the C++ binding's `~$1()` dtor.
  # PR #23 review (Rust), Critical item 3.
  if dtorProcName.len > 0:
    lines.add("impl Drop for $1 {" % [ctxTypeName])
    lines.add("    fn drop(&mut self) {")
    lines.add("        if !self.ptr.is_null() {")
    lines.add("            unsafe { ffi::$1(self.ptr); }" % [dtorProcName])
    lines.add("            self.ptr = std::ptr::null_mut();")
    lines.add("        }")
    lines.add("    }")
    lines.add("}")
    lines.add("")

  lines.add("impl $1 {" % [ctxTypeName])

  # ── Constructors ───────────────────────────────────────────────────────────
  for ctor in ctors:
    let reqName = reqStructName(ctor)
    var paramsList: seq[string] = @[]
    var fieldInits: seq[string] = @[]
    for ep in ctor.extraParams:
      let snake = camelToSnakeCase(ep.name)
      let rustType =
        if ep.isPtr:
          RustPtrType
        else:
          nimTypeToRust(ep.typeName)
      paramsList.add("$1: $2" % [snake, rustType])
      fieldInits.add(snake)
    # Both `create` and `new_async` accept an explicit `timeout: Duration`; the
    # value flows into `self.timeout` so subsequent method calls inherit it.
    # (PR #23 Rust review, item 5: don't hardcode 30s for the async ctor.)
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

    # -- blocking create --
    lines.add("    pub fn create($1) -> Result<Self, String> {" % [ctorParamsStr])
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    # Ctor C ABI returns *mut c_void synchronously AND fires the callback;
    # the callback carries the success/error payload, so discard the
    # synchronous return value and yield RET_OK to make the trampoline wait
    # on the callback.
    lines.add("        let raw_bytes = ffi_call_sync(timeout, |cb, ud| unsafe {")
    lines.add(
      "            let _ = ffi::$1(req_bytes.as_ptr(), req_bytes.len(), cb, ud);" %
        [ctor.procName]
    )
    lines.add("            0")
    lines.add("        })?;")
    # The ctor success payload is a CBOR text string holding the ctx address.
    lines.add("        let addr_str: String = decode_cbor(&raw_bytes)?;")
    lines.add(
      "        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;"
    )
    lines.add("        Ok(Self { ptr: addr as *mut c_void, timeout })")
    lines.add("    }")
    lines.add("")

    # -- async new_async --
    lines.add(
      "    pub async fn new_async($1) -> Result<Self, String> {" % [ctorParamsStr]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    # See `create` above: discard the ctor's *mut c_void synchronous return
    # and rely on the callback to deliver the ctx address.
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
    lines.add("        Ok(Self { ptr: addr as *mut c_void, timeout })")
    lines.add("    }")
    lines.add("")

  # ── Methods ────────────────────────────────────────────────────────────────
  for m in methods:
    let methodName = stripLibPrefix(m.procName, libName)
    let retRustType = nimTypeToRust(m.returnTypeName)
    let reqName = reqStructName(m)

    var paramsList: seq[string] = @[]
    var fieldInits: seq[string] = @[]
    for ep in m.extraParams:
      let snake = camelToSnakeCase(ep.name)
      let rustType =
        if ep.isPtr:
          RustPtrType
        else:
          nimTypeToRust(ep.typeName)
      paramsList.add("$1: $2" % [snake, rustType])
      fieldInits.add(snake)
    let paramsStr =
      if paramsList.len > 0:
        ", " & paramsList.join(", ")
      else:
        ""

    let reqLit =
      if fieldInits.len > 0:
        reqName & " { " & fieldInits.join(", ") & " }"
      else:
        reqName & " {}"

    let retTypeForApi = if m.returnIsPtr: RustPtrType else: retRustType

    # -- blocking method --
    lines.add(
      "    pub fn $1(&self$2) -> Result<$3, String> {" %
        [methodName, paramsStr, retTypeForApi]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add("        let raw_bytes = ffi_call_sync(self.timeout, |cb, ud| unsafe {")
    lines.add(
      "            ffi::$1(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())" %
        [m.procName]
    )
    lines.add("        })?;")
    lines.add("        decode_cbor::<$1>(&raw_bytes)" % [retTypeForApi])
    lines.add("    }")
    lines.add("")

    # -- async method --
    # ptr is cast to usize (Copy + Send) so the move closure is Send,
    # keeping the returned future Send for multi-threaded tokio runtimes.
    lines.add(
      "    pub async fn $1_async(&self$2) -> Result<$3, String> {" %
        [methodName, paramsStr, retTypeForApi]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add("        let ptr = self.ptr as usize;")
    lines.add(
      "        let raw_bytes = ffi_call_async(self.timeout, move |cb, ud| unsafe {"
    )
    lines.add(
      "            ffi::$1(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())" %
        [m.procName]
    )
    lines.add("        }).await?;")
    lines.add("        decode_cbor::<$1>(&raw_bytes)" % [retTypeForApi])
    lines.add("    }")
    lines.add("")

  lines.add("}")
  return lines.join("\n") & "\n"

proc rustBanner(prefix, nimSrcRelPath: string): string =
  ## `prefix` is the per-file comment marker — `//` for .rs files, `#`
  ## for Cargo.toml. Same banner content otherwise.
  return
    prefix & " ============================================================\n" &
    prefix & " AUTO-GENERATED by nim-ffi v" & NimFFIVersion & "  (ffiMode=cbor, ffiLang=rust). DO NOT EDIT.\n" &
    prefix & "\n" &
    prefix & "   Source:     " & nimSrcRelPath & "\n" &
    prefix & "   Generator:  ffi/codegen/rust.nim\n" &
    prefix & "   Regenerate: nimble genbindings_rust_cbor\n" &
    prefix & " ============================================================\n\n"

proc generateRustCrate*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
) =
  ## Generates a complete Rust crate in outputDir.
  createDir(outputDir)
  createDir(outputDir / "src")

  let rsBanner = rustBanner("//", nimSrcRelPath)
  let tomlBanner = rustBanner("#", nimSrcRelPath)

  writeFile(outputDir / "Cargo.toml",     tomlBanner & generateCargoToml(libName))
  writeFile(outputDir / "build.rs",       rsBanner & generateBuildRs(libName, nimSrcRelPath))
  writeFile(outputDir / "src" / "lib.rs", rsBanner & generateLibRs())
  writeFile(outputDir / "src" / "ffi.rs", rsBanner & generateFFIRs(procs))
  writeFile(outputDir / "src" / "types.rs", rsBanner & generateTypesRs(types, procs))
  writeFile(outputDir / "src" / "api.rs", rsBanner & generateApiRs(procs, libName))
