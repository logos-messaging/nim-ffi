## Rust binding generator for the nim-ffi framework.
## Generates a complete Rust crate from compile-time FFI metadata.

import std/[os, strutils]
import ./meta

# ---------------------------------------------------------------------------
# Name conversion helpers
# ---------------------------------------------------------------------------

proc toSnakeCase*(s: string): string =
  ## Converts camelCase to snake_case.
  ## e.g. "delayMs" → "delay_ms", "timerName" → "timer_name"
  result = ""
  for i, c in s:
    if c.isUpperAscii() and i > 0:
      result.add('_')
    result.add(c.toLowerAscii())

proc toPascalCase*(s: string): string =
  ## Converts the first letter to uppercase.
  if s.len == 0:
    return s
  result = s
  result[0] = s[0].toUpperAscii()

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
  of "string", "cstring": "String"
  of "int", "int64": "i64"
  of "int32": "i32"
  of "bool": "bool"
  of "float", "float64": "f64"
  of "pointer": "usize"
  else: toPascalCase(t)

proc deriveLibName*(procs: seq[FFIProcMeta]): string =
  ## Extracts the common prefix before the first `_` from proc names.
  ## e.g. ["nimtimer_create", "nimtimer_echo"] → "nimtimer"
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
  ## e.g. "nimtimer_echo", "nimtimer" → "echo"
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

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
serde_json = "1"
tokio = { version = "1", features = ["sync"] }
""" %
    [libName]

proc generateBuildRs*(libName: string, nimSrcRelPath: string): string =
  ## Generates build.rs that compiles the Nim library.
  ## nimSrcRelPath is relative to the output (crate) directory.
  let escapedSrc = nimSrcRelPath.replace("\\", "\\\\")
  result =
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
  result = """mod ffi;
mod types;
mod api;
pub use types::*;
pub use api::*;
"""

proc generateFfiRs*(procs: seq[FFIProcMeta]): string =
  ## Generates ffi.rs with extern "C" declarations for all procs.
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
    if p.kind == ffiFfiKind:
      # Method: ctx comes first
      params.add("ctx: *mut c_void")
      params.add("callback: FfiCallback")
      params.add("user_data: *mut c_void")
      for ep in p.extraParams:
        params.add("$1_json: *const c_char" % [toSnakeCase(ep.name)])
    else:
      # Constructor: no ctx
      for ep in p.extraParams:
        params.add("$1_json: *const c_char" % [toSnakeCase(ep.name)])
      params.add("callback: FfiCallback")
      params.add("user_data: *mut c_void")

    let paramStr = params.join(", ")
    lines.add("    pub fn $1($2) -> c_int;" % [p.procName, paramStr])

  lines.add("}")
  result = lines.join("\n") & "\n"

proc generateTypesRs*(types: seq[FFITypeMeta]): string =
  ## Generates types.rs with Rust structs for all FFI types.
  var lines: seq[string] = @[]
  lines.add("use serde::{Deserialize, Serialize};")
  lines.add("")

  for t in types:
    lines.add("#[derive(Debug, Clone, Serialize, Deserialize)]")
    lines.add("pub struct $1 {" % [t.name])
    for f in t.fields:
      let snakeName = toSnakeCase(f.name)
      let rustType = nimTypeToRust(f.typeName)
      # Add serde rename if camelCase name differs from snake_case
      if snakeName != f.name:
        lines.add("    #[serde(rename = \"$1\")]" % [f.name])
      lines.add("    pub $1: $2," % [snakeName, rustType])
    lines.add("}")
    lines.add("")

  result = lines.join("\n")

proc generateApiRs*(procs: seq[FFIProcMeta], libName: string): string =
  ## Generates api.rs with both a blocking and a tokio-async high-level API.
  ##
  ## Blocking: ctx.echo(req)           — thread-blocks via Condvar
  ## Async:    ctx.echo_async(req).await — non-blocking via oneshot channel;
  ##           the FFI callback fires from the Nim/chronos thread and wakes
  ##           the awaiting task without ever blocking a thread.
  var lines: seq[string] = @[]

  var ctors: seq[FFIProcMeta] = @[]
  var methods: seq[FFIProcMeta] = @[]
  for p in procs:
    if p.kind == ffiCtorKind: ctors.add(p)
    else: methods.add(p)

  var libTypeName = ""
  if ctors.len > 0: libTypeName = ctors[0].libTypeName
  else: libTypeName = toPascalCase(libName)

  let ctxTypeName = libTypeName & "Ctx"

  # ── Imports ────────────────────────────────────────────────────────────────
  lines.add("use std::ffi::{CStr, CString};")
  lines.add("use std::os::raw::{c_char, c_int, c_void};")
  lines.add("use std::sync::{Arc, Condvar, Mutex};")
  lines.add("use std::time::Duration;")
  lines.add("use super::ffi;")
  lines.add("use super::types::*;")
  lines.add("")

  # ── Blocking trampoline ────────────────────────────────────────────────────
  lines.add("#[derive(Default)]")
  lines.add("struct FfiCallbackResult {")
  lines.add("    payload: Option<Result<String, String>>,")
  lines.add("}")
  lines.add("")
  lines.add("type Pair = Arc<(Mutex<FfiCallbackResult>, Condvar)>;")
  lines.add("")
  lines.add("unsafe extern \"C\" fn on_result(")
  lines.add("    ret: c_int,")
  lines.add("    msg: *const c_char,")
  lines.add("    _len: usize,")
  lines.add("    user_data: *mut c_void,")
  lines.add(") {")
  lines.add("    let pair = Arc::from_raw(user_data as *const (Mutex<FfiCallbackResult>, Condvar));")
  lines.add("    {")
  lines.add("        let (lock, cvar) = &*pair;")
  lines.add("        let mut state = lock.lock().unwrap();")
  lines.add("        state.payload = Some(if ret == 0 {")
  lines.add("            Ok(CStr::from_ptr(msg).to_string_lossy().into_owned())")
  lines.add("        } else {")
  lines.add("            Err(CStr::from_ptr(msg).to_string_lossy().into_owned())")
  lines.add("        });")
  lines.add("        cvar.notify_one();")
  lines.add("    }")
  lines.add("    std::mem::forget(pair);")
  lines.add("}")
  lines.add("")
  lines.add("fn ffi_call<F>(timeout: Duration, f: F) -> Result<String, String>")
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
  # The callback is invoked from the Nim/chronos thread and sends the result
  # through the oneshot channel, waking the awaiting tokio task without
  # blocking any thread.
  lines.add("unsafe extern \"C\" fn on_result_async(")
  lines.add("    ret: c_int,")
  lines.add("    msg: *const c_char,")
  lines.add("    _len: usize,")
  lines.add("    user_data: *mut c_void,")
  lines.add(") {")
  lines.add("    let tx = Box::from_raw(")
  lines.add("        user_data as *mut tokio::sync::oneshot::Sender<Result<String, String>>,")
  lines.add("    );")
  lines.add("    let value = if ret == 0 {")
  lines.add("        Ok(CStr::from_ptr(msg).to_string_lossy().into_owned())")
  lines.add("    } else {")
  lines.add("        Err(CStr::from_ptr(msg).to_string_lossy().into_owned())")
  lines.add("    };")
  lines.add("    let _ = tx.send(value);")
  lines.add("}")
  lines.add("")
  # Scoped block keeps raw/tx/F dead at the single await point so the
  # returned future is Send regardless of whether F itself is Send.
  lines.add("async fn ffi_call_async<F>(f: F) -> Result<String, String>")
  lines.add("where")
  lines.add("    F: FnOnce(ffi::FfiCallback, *mut c_void) -> c_int,")
  lines.add("{")
  lines.add("    let rx = {")
  lines.add("        let (tx, rx) = tokio::sync::oneshot::channel::<Result<String, String>>();")
  lines.add("        let raw = Box::into_raw(Box::new(tx)) as *mut c_void;")
  lines.add("        let ret = f(on_result_async, raw);")
  lines.add("        if ret == 2 {")
  lines.add("            drop(unsafe {")
  lines.add("                Box::from_raw(")
  lines.add("                    raw as *mut tokio::sync::oneshot::Sender<Result<String, String>>,")
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
    var asyncParamsList: seq[string] = @[]
    for ep in ctor.extraParams:
      asyncParamsList.add(
        "$1: $2" % [toSnakeCase(ep.name), nimTypeToRust(ep.typeName)]
      )
    let asyncParamsStr = asyncParamsList.join(", ")
    let blockingParamsStr =
      if asyncParamsList.len > 0: asyncParamsList.join(", ") & ", timeout: Duration"
      else: "timeout: Duration"

    # Helper: emit JSON serialization lines for extra params
    template emitSerialize(snakeName, rustType: string) =
      if rustType == "String":
        lines.add(
          "        let $1_json_str = serde_json::to_string(&$1).map_err(|e| e.to_string())?;" %
            [snakeName]
        )
        lines.add("        let $1_c = CString::new($1_json_str).unwrap();" % [snakeName])
      else:
        lines.add(
          "        let $1_json = serde_json::to_string(&$1).map_err(|e| e.to_string())?;" %
            [snakeName]
        )
        lines.add("        let $1_c = CString::new($1_json).unwrap();" % [snakeName])

    # Build the ordered arg list for the raw FFI call (ctor: params, cb, ud)
    var ffiCallArgs: seq[string] = @[]
    for ep in ctor.extraParams:
      ffiCallArgs.add("$1_c.as_ptr()" % [toSnakeCase(ep.name)])
    ffiCallArgs.add("cb")
    ffiCallArgs.add("ud")
    let ffiCallArgsStr = ffiCallArgs.join(", ")

    # -- blocking create --
    lines.add("    pub fn create($1) -> Result<Self, String> {" % [blockingParamsStr])
    for ep in ctor.extraParams:
      emitSerialize(toSnakeCase(ep.name), nimTypeToRust(ep.typeName))
    lines.add("        let raw = ffi_call(timeout, |cb, ud| unsafe {")
    lines.add("            ffi::$1($2)" % [ctor.procName, ffiCallArgsStr])
    lines.add("        })?;")
    lines.add("        let addr: usize = raw.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;")
    lines.add("        Ok(Self { ptr: addr as *mut c_void, timeout })")
    lines.add("    }")
    lines.add("")

    # -- async new_async --
    # move closure: each CString is moved in (Send), no raw ptr escapes the block
    lines.add("    pub async fn new_async($1) -> Result<Self, String> {" % [asyncParamsStr])
    for ep in ctor.extraParams:
      emitSerialize(toSnakeCase(ep.name), nimTypeToRust(ep.typeName))
    lines.add("        let raw = ffi_call_async(move |cb, ud| unsafe {")
    lines.add("            ffi::$1($2)" % [ctor.procName, ffiCallArgsStr])
    lines.add("        }).await?;")
    lines.add("        let addr: usize = raw.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;")
    lines.add("        Ok(Self { ptr: addr as *mut c_void, timeout: Duration::from_secs(30) })")
    lines.add("    }")
    lines.add("")

  # ── Methods ────────────────────────────────────────────────────────────────
  for m in methods:
    let methodName = stripLibPrefix(m.procName, libName)
    let retRustType = nimTypeToRust(m.returnTypeName)

    var paramsList: seq[string] = @[]
    for ep in m.extraParams:
      paramsList.add("$1: $2" % [toSnakeCase(ep.name), nimTypeToRust(ep.typeName)])
    let paramsStr = if paramsList.len > 0: ", " & paramsList.join(", ") else: ""

    template emitSerialize(snakeName, rustType: string) =
      if rustType == "String":
        lines.add(
          "        let $1_json_str = serde_json::to_string(&$1).map_err(|e| e.to_string())?;" %
            [snakeName]
        )
        lines.add("        let $1_c = CString::new($1_json_str).unwrap();" % [snakeName])
      else:
        lines.add(
          "        let $1_json = serde_json::to_string(&$1).map_err(|e| e.to_string())?;" %
            [snakeName]
        )
        lines.add("        let $1_c = CString::new($1_json).unwrap();" % [snakeName])

    template emitDeserialize(retRustType: string) =
      if retRustType == "String":
        lines.add("        serde_json::from_str::<String>(&raw).map_err(|e| e.to_string())")
      elif retRustType == "usize":
        lines.add("        raw.parse::<usize>().map_err(|e| e.to_string())")
      else:
        lines.add(
          "        serde_json::from_str::<$1>(&raw).map_err(|e| e.to_string())" % [retRustType]
        )

    # -- blocking method --
    lines.add("    pub fn $1(&self$2) -> Result<$3, String> {" % [methodName, paramsStr, retRustType])
    for ep in m.extraParams:
      emitSerialize(toSnakeCase(ep.name), nimTypeToRust(ep.typeName))
    var ffiArgs: seq[string] = @["self.ptr", "cb", "ud"]
    for ep in m.extraParams:
      ffiArgs.add("$1_c.as_ptr()" % [toSnakeCase(ep.name)])
    let ffiArgsStr = ffiArgs.join(", ")
    lines.add("        let raw = ffi_call(self.timeout, |cb, ud| unsafe {")
    lines.add("            ffi::$1($2)" % [m.procName, ffiArgsStr])
    lines.add("        })?;")
    emitDeserialize(retRustType)
    lines.add("    }")
    lines.add("")

    # -- async method --
    # ptr is cast to usize (Copy + Send) so the move closure is Send,
    # keeping the returned future Send for multi-threaded tokio runtimes.
    lines.add("    pub async fn $1_async(&self$2) -> Result<$3, String> {" %
      [methodName, paramsStr, retRustType])
    for ep in m.extraParams:
      emitSerialize(toSnakeCase(ep.name), nimTypeToRust(ep.typeName))
    lines.add("        let ptr = self.ptr as usize;")
    var asyncFfiArgs: seq[string] = @["ptr as *mut c_void", "cb", "ud"]
    for ep in m.extraParams:
      asyncFfiArgs.add("$1_c.as_ptr()" % [toSnakeCase(ep.name)])
    let asyncFfiArgsStr = asyncFfiArgs.join(", ")
    lines.add("        let raw = ffi_call_async(move |cb, ud| unsafe {")
    lines.add("            ffi::$1($2)" % [m.procName, asyncFfiArgsStr])
    lines.add("        }).await?;")
    emitDeserialize(retRustType)
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
  ## Generates a complete Rust crate in outputDir.
  createDir(outputDir)
  createDir(outputDir / "src")

  writeFile(outputDir / "Cargo.toml", generateCargoToml(libName))
  writeFile(outputDir / "build.rs", generateBuildRs(libName, nimSrcRelPath))
  writeFile(outputDir / "src" / "lib.rs", generateLibRs())
  writeFile(outputDir / "src" / "ffi.rs", generateFfiRs(procs))
  writeFile(outputDir / "src" / "types.rs", generateTypesRs(types))
  writeFile(outputDir / "src" / "api.rs", generateApiRs(procs, libName))
