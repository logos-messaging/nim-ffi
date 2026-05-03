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
  if s.len == 0: return s
  result = s
  result[0] = s[0].toUpperAscii()

proc nimTypeToRust*(typeName: string): string =
  ## Maps Nim type names to Rust type names.
  case typeName
  of "string", "cstring": "String"
  of "int", "int64": "i64"
  of "int32": "i32"
  of "bool": "bool"
  of "float", "float64": "f64"
  of "pointer": "usize"
  else: toPascalCase(typeName)

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
  result = """[package]
name = "$1"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
""" % [libName]

proc generateBuildRs*(libName: string, nimSrcRelPath: string): string =
  ## Generates build.rs that compiles the Nim library.
  ## nimSrcRelPath is relative to the output (crate) directory.
  let escapedSrc = nimSrcRelPath.replace("\\", "\\\\")
  result = """use std::path::PathBuf;
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
""" % [escapedSrc, libName]

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
  ## Generates api.rs with the high-level Rust API.
  var lines: seq[string] = @[]

  # Find ctor and method procs
  var ctors: seq[FFIProcMeta] = @[]
  var methods: seq[FFIProcMeta] = @[]
  for p in procs:
    if p.kind == ffiCtorKind:
      ctors.add(p)
    else:
      methods.add(p)

  # Derive the lib type name from ctor or from libName
  var libTypeName = ""
  if ctors.len > 0:
    libTypeName = ctors[0].libTypeName
  else:
    # Fallback: PascalCase of libName
    libTypeName = toPascalCase(libName)

  let ctxTypeName = libTypeName & "Ctx"

  # Imports
  lines.add("use std::ffi::{CStr, CString};")
  lines.add("use std::os::raw::{c_char, c_int, c_void};")
  lines.add("use std::sync::{Arc, Condvar, Mutex};")
  lines.add("use std::time::Duration;")
  lines.add("use super::ffi;")
  lines.add("use super::types::*;")
  lines.add("")

  # FfiCallbackResult struct
  lines.add("#[derive(Default)]")
  lines.add("struct FfiCallbackResult {")
  lines.add("    payload: Option<Result<String, String>>,")
  lines.add("}")
  lines.add("")
  lines.add("type Pair = Arc<(Mutex<FfiCallbackResult>, Condvar)>;")
  lines.add("")

  # on_result callback
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

  # ffi_call helper
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

  # Ctx struct
  lines.add("/// High-level context for `$1`." % [libTypeName])
  lines.add("pub struct $1 {" % [ctxTypeName])
  lines.add("    ptr: *mut c_void,")
  lines.add("    timeout: Duration,")
  lines.add("}")
  lines.add("")
  lines.add("unsafe impl Send for $1 {}" % [ctxTypeName])
  lines.add("unsafe impl Sync for $1 {}" % [ctxTypeName])
  lines.add("")

  # impl block
  lines.add("impl $1 {" % [ctxTypeName])

  # Constructor method(s)
  for ctor in ctors:
    var paramsList: seq[string] = @[]
    for ep in ctor.extraParams:
      let rustType = nimTypeToRust(ep.typeName)
      let snakeName = toSnakeCase(ep.name)
      paramsList.add("$1: $2" % [snakeName, rustType])
    paramsList.add("timeout: Duration")
    let paramsStr = paramsList.join(", ")

    lines.add("    pub fn create($1) -> Result<Self, String> {" % [paramsStr])

    # Serialize extra params
    for ep in ctor.extraParams:
      let snakeName = toSnakeCase(ep.name)
      let rustType = nimTypeToRust(ep.typeName)
      if rustType == "String":
        # Primitive string — wrap it in JSON
        lines.add("        let $1_json_str = serde_json::to_string(&$1).map_err(|e| e.to_string())?;" % [snakeName])
        lines.add("        let $1_c = CString::new($1_json_str).unwrap();" % [snakeName])
      else:
        lines.add("        let $1_json = serde_json::to_string(&$1).map_err(|e| e.to_string())?;" % [snakeName])
        lines.add("        let $1_c = CString::new($1_json).unwrap();" % [snakeName])

    # Build the ffi_call closure
    var ffiCallArgs: seq[string] = @[]
    for ep in ctor.extraParams:
      let snakeName = toSnakeCase(ep.name)
      ffiCallArgs.add("$1_c.as_ptr()" % [snakeName])
    ffiCallArgs.add("cb")
    ffiCallArgs.add("ud")
    let ffiCallArgsStr = ffiCallArgs.join(", ")

    lines.add("        let raw = ffi_call(timeout, |cb, ud| unsafe {")
    lines.add("            ffi::$1($2)" % [ctor.procName, ffiCallArgsStr])
    lines.add("        })?;")
    lines.add("        // ctor returns the context address as a plain decimal string")
    lines.add("        let addr: usize = raw.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;")
    lines.add("        Ok(Self { ptr: addr as *mut c_void, timeout })")
    lines.add("    }")
    lines.add("")

  # Method implementations
  for m in methods:
    let methodName = stripLibPrefix(m.procName, libName)
    let retRustType = nimTypeToRust(m.returnTypeName)

    var paramsList: seq[string] = @[]
    for ep in m.extraParams:
      let rustType = nimTypeToRust(ep.typeName)
      let snakeName = toSnakeCase(ep.name)
      paramsList.add("$1: $2" % [snakeName, rustType])
    let paramsStr = if paramsList.len > 0: ", " & paramsList.join(", ") else: ""

    lines.add("    pub fn $1(&self$2) -> Result<$3, String> {" % [methodName, paramsStr, retRustType])

    # Serialize extra params
    for ep in m.extraParams:
      let snakeName = toSnakeCase(ep.name)
      let rustType = nimTypeToRust(ep.typeName)
      if rustType == "String":
        lines.add("        let $1_json_str = serde_json::to_string(&$1).map_err(|e| e.to_string())?;" % [snakeName])
        lines.add("        let $1_c = CString::new($1_json_str).unwrap();" % [snakeName])
      else:
        lines.add("        let $1_json = serde_json::to_string(&$1).map_err(|e| e.to_string())?;" % [snakeName])
        lines.add("        let $1_c = CString::new($1_json).unwrap();" % [snakeName])

    # Build ffi call args: ctx first, then callback/ud, then json args
    var ffiArgs: seq[string] = @["self.ptr", "cb", "ud"]
    for ep in m.extraParams:
      let snakeName = toSnakeCase(ep.name)
      ffiArgs.add("$1_c.as_ptr()" % [snakeName])
    let ffiArgsStr = ffiArgs.join(", ")

    lines.add("        let raw = ffi_call(self.timeout, |cb, ud| unsafe {")
    lines.add("            ffi::$1($2)" % [m.procName, ffiArgsStr])
    lines.add("        })?;")

    # Deserialize return value
    if retRustType == "String":
      lines.add("        serde_json::from_str::<String>(&raw).map_err(|e| e.to_string())")
    elif retRustType == "usize":
      lines.add("        raw.parse::<usize>().map_err(|e| e.to_string())")
    else:
      lines.add("        serde_json::from_str::<$1>(&raw).map_err(|e| e.to_string())" % [retRustType])
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
