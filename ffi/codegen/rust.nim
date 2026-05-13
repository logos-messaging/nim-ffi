## Rust binding generator for the nim-ffi framework.
## Generates a complete Rust crate that uses CBOR (ciborium) on the wire.

import std/[os, strutils]
import ./meta

proc nimTypeToRust*(typeName: string): string =
  let t = typeName.strip()
  if t.startsWith("seq[") and t.endsWith("]"):
    return "Vec<" & nimTypeToRust(t[4 .. ^2]) & ">"
  if t.startsWith("Option[") and t.endsWith("]"):
    return "Option<" & nimTypeToRust(t[7 .. ^2]) & ">"
  if t.startsWith("Maybe[") and t.endsWith("]"):
    return "Option<" & nimTypeToRust(t[6 .. ^2]) & ">"
  case t
  of "string", "cstring": "String"
  of "int", "int64": "i64"
  of "int32": "i32"
  of "bool": "bool"
  of "float", "float64": "f64"
  of "pointer": "u64"
  else: toPascalCase(t)

proc deriveLibName*(procs: seq[FFIProcMeta]): string =
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
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc reqStructName(p: FFIProcMeta): string =
  ## Mirrors the Nim macro: <CamelCase(procName)>Req or CtorReq for ctors.
  let camel = toCamelCase(p.procName)
  if p.kind == ffiCtorKind: camel & "CtorReq" else: camel & "Req"

# ---------------------------------------------------------------------------
# File generators
# ---------------------------------------------------------------------------

proc generateCargoToml*(libName: string): string =
  result =
    """[package]
name = "$1"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }
ciborium = "0.2"
tokio = { version = "1", features = ["sync"] }
""" %
    [libName]

proc generateBuildRs*(libName: string, nimSrcRelPath: string): string =
  let escapedSrc = nimSrcRelPath.replace("\\", "\\\\")
  result =
    """use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let nim_src = manifest.join("$1");
    let nim_src = nim_src.canonicalize().unwrap_or(manifest.join("$1"));

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
  result = """mod ffi;
mod types;
mod api;
pub use types::*;
pub use api::*;
"""

proc generateFfiRs*(procs: seq[FFIProcMeta]): string =
  ## Generates ffi.rs with extern "C" declarations. Each Nim FFI proc takes a
  ## single CBOR buffer (ptr+len) for its request payload.
  var lines: seq[string] = @[]
  lines.add("use std::os::raw::{c_char, c_int, c_void};")
  lines.add("")
  lines.add("pub type FfiCallback = unsafe extern \"C\" fn(")
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

  lines.add("#[link(name = \"$1\")]" % [linkLibName])
  lines.add("extern \"C\" {")

  for p in procs:
    var params: seq[string] = @[]
    case p.kind
    of ffiFfiKind:
      params.add("ctx: *mut c_void")
      params.add("callback: FfiCallback")
      params.add("user_data: *mut c_void")
      params.add("req_cbor: *const u8")
      params.add("req_cbor_len: usize")
      lines.add("    pub fn $1($2) -> c_int;" % [p.procName, params.join(", ")])
    of ffiCtorKind:
      params.add("req_cbor: *const u8")
      params.add("req_cbor_len: usize")
      params.add("callback: FfiCallback")
      params.add("user_data: *mut c_void")
      lines.add(
        "    pub fn $1($2) -> *mut c_void;" % [p.procName, params.join(", ")]
      )
    of ffiDtorKind:
      params.add("ctx: *mut c_void")
      lines.add("    pub fn $1($2) -> c_int;" % [p.procName, params.join(", ")])

  lines.add("}")
  result = lines.join("\n") & "\n"

proc generateTypesRs*(
    types: seq[FFITypeMeta], procs: seq[FFIProcMeta]
): string =
  ## Generates types.rs with Rust structs for all user-declared FFI types and
  ## for each per-proc Req struct (matching the Nim macro's generated types).
  var lines: seq[string] = @[]
  lines.add("use serde::{Deserialize, Serialize};")
  lines.add("")

  for t in types:
    lines.add("#[derive(Debug, Clone, Serialize, Deserialize)]")
    lines.add("pub struct $1 {" % [t.name])
    for f in t.fields:
      let snakeName = toSnakeCase(f.name)
      let rustType = nimTypeToRust(f.typeName)
      if snakeName != f.name:
        lines.add("    #[serde(rename = \"$1\")]" % [f.name])
      lines.add("    pub $1: $2," % [snakeName, rustType])
    lines.add("}")
    lines.add("")

  # Per-proc Req structs — these wrap the typed parameters and are the unit of
  # CBOR encoding sent across the FFI boundary.
  for p in procs:
    if p.kind == ffiDtorKind:
      continue
    let reqName = reqStructName(p)
    lines.add("#[derive(Debug, Clone, Serialize, Deserialize)]")
    if p.extraParams.len == 0:
      lines.add("pub struct $1 {}" % [reqName])
    else:
      lines.add("pub struct $1 {" % [reqName])
      for ep in p.extraParams:
        let snake = toSnakeCase(ep.name)
        let rustType =
          if ep.isPtr: "u64"
          else: nimTypeToRust(ep.typeName)
        if snake != ep.name:
          lines.add("    #[serde(rename = \"$1\")]" % [ep.name])
        lines.add("    pub $1: $2," % [snake, rustType])
      lines.add("}")
    lines.add("")

  result = lines.join("\n")

proc generateApiRs*(procs: seq[FFIProcMeta], libName: string): string =
  ## Generates api.rs with a blocking and a tokio-async high-level API.
  ## Requests/responses are CBOR (ciborium); errors are raw UTF-8 strings.
  var lines: seq[string] = @[]

  var ctors: seq[FFIProcMeta] = @[]
  var methods: seq[FFIProcMeta] = @[]
  for p in procs:
    if p.kind == ffiCtorKind: ctors.add(p)
    elif p.kind == ffiFfiKind: methods.add(p)

  var libTypeName = ""
  if ctors.len > 0: libTypeName = ctors[0].libTypeName
  else: libTypeName = toPascalCase(libName)

  let ctxTypeName = libTypeName & "Ctx"

  # ── Imports ────────────────────────────────────────────────────────────────
  lines.add("use std::os::raw::{c_char, c_int, c_void};")
  lines.add("use std::slice;")
  lines.add("use std::sync::{Arc, Condvar, Mutex};")
  lines.add("use std::time::Duration;")
  lines.add("use serde::de::DeserializeOwned;")
  lines.add("use serde::Serialize;")
  lines.add("use super::ffi;")
  lines.add("use super::types::*;")
  lines.add("")

  # ── CBOR helpers ───────────────────────────────────────────────────────────
  lines.add("fn encode_cbor<T: Serialize>(value: &T) -> Result<Vec<u8>, String> {")
  lines.add("    let mut buf = Vec::new();")
  lines.add("    ciborium::ser::into_writer(value, &mut buf).map_err(|e| e.to_string())?;")
  lines.add("    Ok(buf)")
  lines.add("}")
  lines.add("")
  lines.add(
    "fn decode_cbor<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, String> {"
  )
  lines.add("    ciborium::de::from_reader(bytes).map_err(|e| e.to_string())")
  lines.add("}")
  lines.add("")

  # ── Blocking trampoline ────────────────────────────────────────────────────
  # The callback payload is raw bytes — CBOR on RET_OK, UTF-8 on RET_ERR. We
  # buffer it as Vec<u8> and decode on the caller side.
  lines.add("#[derive(Default)]")
  lines.add("struct FfiCallbackResult {")
  lines.add("    payload: Option<Result<Vec<u8>, String>>,")
  lines.add("}")
  lines.add("")
  lines.add("type Pair = Arc<(Mutex<FfiCallbackResult>, Condvar)>;")
  lines.add("")
  lines.add("// Reconstruct the (ret, msg, len) tuple delivered by the C callback")
  lines.add("// into a Result<Vec<u8>, String>: payload on success, UTF-8 message on error.")
  lines.add("unsafe fn ffi_payload(ret: c_int, msg: *const c_char, len: usize) -> Result<Vec<u8>, String> {")
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
  lines.add("    // from_raw reclaims the strong ref that ffi_call's into_raw left behind;")
  lines.add("    // letting `pair` drop at end of scope releases it.")
  lines.add("    let pair = Arc::from_raw(user_data as *const (Mutex<FfiCallbackResult>, Condvar));")
  lines.add("    let (lock, cvar) = &*pair;")
  lines.add("    let mut state = lock.lock().unwrap();")
  lines.add("    state.payload = Some(ffi_payload(ret, msg, len));")
  lines.add("    cvar.notify_one();")
  lines.add("}")
  lines.add("")
  lines.add("fn ffi_call<F>(timeout: Duration, f: F) -> Result<Vec<u8>, String>")
  lines.add("where")
  lines.add("    F: FnOnce(ffi::FfiCallback, *mut c_void) -> c_int,")
  lines.add("{")
  lines.add("    let pair: Pair = Arc::new((Mutex::new(FfiCallbackResult::default()), Condvar::new()));")
  lines.add("    let raw = Arc::into_raw(pair.clone()) as *mut c_void;")
  lines.add("    let ret = f(on_result, raw);")
  lines.add("    if ret == 2 {")
  lines.add("        return Err(\"RET_MISSING_CALLBACK (internal error)\".into());")
  lines.add("    }")
  lines.add("    let (lock, cvar) = &*pair;")
  lines.add("    let guard = lock.lock().unwrap();")
  lines.add("    let (guard, timed_out) = cvar")
  lines.add("        .wait_timeout_while(guard, timeout, |s| s.payload.is_none())")
  lines.add("        .unwrap();")
  lines.add("    if timed_out.timed_out() {")
  lines.add("        return Err(format!(\"timed out after {:?}\", timeout));")
  lines.add("    }")
  lines.add("    guard.payload.clone().unwrap()")
  lines.add("}")
  lines.add("")

  # ── Async (tokio oneshot) trampoline ───────────────────────────────────────
  lines.add("unsafe extern \"C\" fn on_result_async(")
  lines.add("    ret: c_int,")
  lines.add("    msg: *const c_char,")
  lines.add("    len: usize,")
  lines.add("    user_data: *mut c_void,")
  lines.add(") {")
  lines.add("    // This fn represents the callback called internally in the Nim library function.")
  lines.add("    // We use a oneshot channel to deliver the result from the Nim-managed thread")
  lines.add("    // to the awaiting tokio task in ffi_call_async; the tx side is passed through")
  lines.add("    // the user_data pointer. The heap allocation behind Box::from_raw is released")
  lines.add("    // when `tx` drops (either consumed by `send` or at end of scope).")
  lines.add("    let tx = Box::from_raw(")
  lines.add("        user_data as *mut tokio::sync::oneshot::Sender<Result<Vec<u8>, String>>,")
  lines.add("    );")
  lines.add("")
  lines.add("    // `tx.send` returns Err only if the awaiting future was dropped (and with it")
  lines.add("    // the Receiver): e.g. tokio::time::timeout elapsed, a tokio::select! branch")
  lines.add("    // lost the race, or the future was dropped before being awaited. This cannot")
  lines.add("    // happen with the current rust_client demo but may occur in arbitrary")
  lines.add("    // downstream consumers, so we discard the Err safely.")
  lines.add("    // Given that this is invoked from a Nim thread, we can't propagate the error by panicking or")
  lines.add("    // returning a Result. Furthermore, an API dev may intentionally set a timeout in the await,")
  lines.add("    // in which case is also fine to discard the send error in this case because the API user will")
  lines.add("    // handle the timeout expiry in their own code.")
  lines.add("    // The important part is to ensure that the callback doesn't panic or block indefinitely if the")
  lines.add("    // receiver is gone.")
  lines.add("    let _ = tx.send(ffi_payload(ret, msg, len));")
  lines.add("}")
  lines.add("")
  lines.add("async fn ffi_call_async<F>(f: F) -> Result<Vec<u8>, String>")
  lines.add("where")
  lines.add("    F: FnOnce(ffi::FfiCallback, *mut c_void) -> c_int,")
  lines.add("{")
  lines.add("    let rx = {")
  lines.add("        let (tx, rx) = tokio::sync::oneshot::channel::<Result<Vec<u8>, String>>();")
  lines.add("        let raw = Box::into_raw(Box::new(tx)) as *mut c_void;")
  lines.add("        let ret = f(on_result_async, raw);")
  lines.add("        if ret == 2 {")
  lines.add("            drop(unsafe {")
  lines.add("                Box::from_raw(")
  lines.add("                    raw as *mut tokio::sync::oneshot::Sender<Result<Vec<u8>, String>>,")
  lines.add("                )")
  lines.add("            });")
  lines.add("            return Err(\"RET_MISSING_CALLBACK (internal error)\".into());")
  lines.add("        }")
  lines.add("        rx")
  lines.add("    };")
  lines.add("    rx.await.map_err(|_| \"channel closed before callback fired\".to_string())?")
  lines.add("}")
  lines.add("")

  # ── Context struct ─────────────────────────────────────────────────────────
  lines.add("/// High-level context for `$1`." % [libTypeName])
  lines.add("pub struct $1 {" % [ctxTypeName])
  lines.add("    ptr: *mut c_void,")
  lines.add("    timeout: Duration,")
  lines.add("}")
  lines.add("")
  lines.add("unsafe impl Send for $1 {}" % [ctxTypeName])
  lines.add("unsafe impl Sync for $1 {}" % [ctxTypeName])
  lines.add("")
  lines.add("impl $1 {" % [ctxTypeName])

  # ── Constructors ───────────────────────────────────────────────────────────
  for ctor in ctors:
    let reqName = reqStructName(ctor)
    var paramsList: seq[string] = @[]
    var fieldInits: seq[string] = @[]
    for ep in ctor.extraParams:
      let snake = toSnakeCase(ep.name)
      let rustType =
        if ep.isPtr: "u64"
        else: nimTypeToRust(ep.typeName)
      paramsList.add("$1: $2" % [snake, rustType])
      fieldInits.add(snake)
    let asyncParamsStr = paramsList.join(", ")
    let blockingParamsStr =
      if paramsList.len > 0: paramsList.join(", ") & ", timeout: Duration"
      else: "timeout: Duration"

    let reqLit =
      if fieldInits.len > 0:
        reqName & " { " & fieldInits.join(", ") & " }"
      else:
        reqName & " {}"

    # -- blocking create --
    lines.add("    pub fn create($1) -> Result<Self, String> {" % [blockingParamsStr])
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add("        let raw_bytes = ffi_call(timeout, |cb, ud| unsafe {")
    lines.add("            ffi::$1(req_bytes.as_ptr(), req_bytes.len(), cb, ud)" % [ctor.procName])
    lines.add("        })?;")
    # The ctor success payload is a CBOR text string holding the ctx address.
    lines.add("        let addr_str: String = decode_cbor(&raw_bytes)?;")
    lines.add("        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;")
    lines.add("        Ok(Self { ptr: addr as *mut c_void, timeout })")
    lines.add("    }")
    lines.add("")

    # -- async new_async --
    lines.add("    pub async fn new_async($1) -> Result<Self, String> {" % [asyncParamsStr])
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add("        let raw_bytes = ffi_call_async(move |cb, ud| unsafe {")
    lines.add("            ffi::$1(req_bytes.as_ptr(), req_bytes.len(), cb, ud)" % [ctor.procName])
    lines.add("        }).await?;")
    lines.add("        let addr_str: String = decode_cbor(&raw_bytes)?;")
    lines.add("        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;")
    lines.add("        Ok(Self { ptr: addr as *mut c_void, timeout: Duration::from_secs(30) })")
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
      let snake = toSnakeCase(ep.name)
      let rustType =
        if ep.isPtr: "u64"
        else: nimTypeToRust(ep.typeName)
      paramsList.add("$1: $2" % [snake, rustType])
      fieldInits.add(snake)
    let paramsStr = if paramsList.len > 0: ", " & paramsList.join(", ") else: ""

    let reqLit =
      if fieldInits.len > 0:
        reqName & " { " & fieldInits.join(", ") & " }"
      else:
        reqName & " {}"

    let retTypeForApi =
      if m.returnIsPtr: "u64"
      else: retRustType

    # -- blocking method --
    lines.add(
      "    pub fn $1(&self$2) -> Result<$3, String> {" %
        [methodName, paramsStr, retTypeForApi]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add("        let raw_bytes = ffi_call(self.timeout, |cb, ud| unsafe {")
    lines.add(
      "            ffi::$1(self.ptr, cb, ud, req_bytes.as_ptr(), req_bytes.len())" %
        [m.procName]
    )
    lines.add("        })?;")
    lines.add("        decode_cbor::<$1>(&raw_bytes)" % [retTypeForApi])
    lines.add("    }")
    lines.add("")

    # -- async method --
    lines.add(
      "    pub async fn $1_async(&self$2) -> Result<$3, String> {" %
        [methodName, paramsStr, retTypeForApi]
    )
    lines.add("        let req = $1;" % [reqLit])
    lines.add("        let req_bytes = encode_cbor(&req)?;")
    lines.add("        let ptr = self.ptr as usize;")
    lines.add("        let raw_bytes = ffi_call_async(move |cb, ud| unsafe {")
    lines.add(
      "            ffi::$1(ptr as *mut c_void, cb, ud, req_bytes.as_ptr(), req_bytes.len())" %
        [m.procName]
    )
    lines.add("        }).await?;")
    lines.add("        decode_cbor::<$1>(&raw_bytes)" % [retTypeForApi])
    lines.add("    }")
    lines.add("")

  lines.add("}")
  result = lines.join("\n") & "\n"

proc generateRustCrate*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
) =
  createDir(outputDir)
  createDir(outputDir / "src")

  writeFile(outputDir / "Cargo.toml", generateCargoToml(libName))
  writeFile(outputDir / "build.rs", generateBuildRs(libName, nimSrcRelPath))
  writeFile(outputDir / "src" / "lib.rs", generateLibRs())
  writeFile(outputDir / "src" / "ffi.rs", generateFfiRs(procs))
  writeFile(outputDir / "src" / "types.rs", generateTypesRs(types, procs))
  writeFile(outputDir / "src" / "api.rs", generateApiRs(procs, libName))
