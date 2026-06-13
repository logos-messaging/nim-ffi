## Swift binding generator for the nim-ffi framework.
##
## Emits an idiomatic Swift wrapper (`<Lib>.swift`) over the *native*
## (zero-serialization) C ABI declared in `<lib>.h` (produced by the C
## generator, see `c.nim`). The Swift side imports the C header through a
## `C<Lib>` clang module (see the package's module map) and never touches CBOR.
##
## Shape mirrors the proven hand-written iOS example: each call is dispatched on
## the library's background FFI thread and its result arrives on a callback; we
## bridge that to a synchronous Swift API with a `DispatchSemaphore`. The wrapper
## blocks on the semaphore until the callback fires, so a by-value request struct
## and any `strdup`'d C strings stay alive on the caller's stack for the whole
## call.
##
## Result decoding follows the native ABI's three callback shapes, picked per
## proc from its metadata:
##   - ctor / void proc -> only `ret` (+ raw error text on RET_ERR)
##   - `string` return  -> `(msg, len)` is the raw UTF-8 string bytes
##   - struct return    -> `msg` is a `const <Type>*`; fields are copied out
##     INSIDE the callback (valid only for its lifetime) into a native Swift
##     value.
##
## Scope (first increment): procs whose parameters are scalars / strings / bools
## / floats, or a single `{.ffi.}` struct whose fields are all of those. Procs
## that need `seq[T]` / `Option[T]` parameter marshaling (or more than one struct
## parameter) are skipped with a logged notice — that marshaling is the next
## increment, kept out so the generated wrapper always compiles.

import std/[os, strutils]
import ./meta, ./string_helpers

proc swiftModuleName(libName: string): string =
  ## The clang-module name the wrapper imports, e.g. "my_timer" -> "CMyTimer".
  ## Must match the package's module map.
  return "C" & snakeToPascalCase(libName)

proc isSimpleScalar(typeName: string): bool =
  ## A field/param type that crosses by value with no array/option marshaling.
  let t = typeName.strip()
  case t
  of "string", "cstring", "bool", "float", "float32", "float64", "int", "int64",
      "int32", "int16", "int8", "clong", "cint", "uint", "uint64", "uint32",
      "uint16", "uint8", "byte", "csize_t":
    return true
  else:
    return false

proc swiftType(typeName: string): string =
  ## Maps a simple Nim type to the Swift type used in the public API surface.
  let t = typeName.strip()
  case t
  of "string", "cstring": "String"
  of "bool": "Bool"
  of "float", "float32": "Float"
  of "float64": "Double"
  of "uint", "uint64", "uint32", "uint16", "uint8", "byte", "csize_t": "UInt"
  else: "Int" # all the signed integer aliases

proc swiftDefault(typeName: string): string =
  ## Default value so flattened numeric/bool params are optional at the call
  ## site (matches the hand-written `delayMs: Int = 0`). Strings get no default.
  let t = typeName.strip()
  if t == "bool":
    return "false"
  if t in ["string", "cstring"]:
    return ""
  return "0"

type FieldPlan = object
  name: string
  typeName: string

proc structFields(types: seq[FFITypeMeta], typeName: string): seq[FieldPlan] =
  var plan: seq[FieldPlan] = @[]
  for t in types:
    if t.name == typeName:
      for f in t.fields:
        plan.add(FieldPlan(name: f.name, typeName: f.typeName))
  return plan

proc allFieldsSimple(types: seq[FFITypeMeta], typeName: string): bool =
  let fields = structFields(types, typeName)
  if fields.len == 0:
    return false # not a known {.ffi.} struct
  for f in fields:
    if not isSimpleScalar(f.typeName):
      return false
  return true

proc isKnownStruct(types: seq[FFITypeMeta], typeName: string): bool =
  for t in types:
    if t.name == typeName:
      return true
  return false

proc canEmit(p: FFIProcMeta, types: seq[FFITypeMeta]): bool =
  ## True when the proc's parameters are entirely covered by this increment:
  ## zero params, all-scalar params, or exactly one struct param of simple
  ## fields. Multiple struct params or seq/Option fields are deferred.
  var structParams = 0
  for ep in p.extraParams:
    if isSimpleScalar(ep.typeName):
      continue
    if isKnownStruct(types, ep.typeName):
      inc structParams
      if not allFieldsSimple(types, ep.typeName):
        return false
    else:
      return false # ptr / unknown type
  return structParams <= 1

# --- Swift value emitted for a flattened parameter list -----------------------

proc flattenedParams(
    p: FFIProcMeta, types: seq[FFITypeMeta]
): seq[FieldPlan] =
  ## The Swift method's parameters: scalar params verbatim, plus the fields of
  ## the single struct param flattened in (matching the example's
  ## `echo(_ message:, delayMs:)`).
  var params: seq[FieldPlan] = @[]
  for ep in p.extraParams:
    if isSimpleScalar(ep.typeName):
      params.add(FieldPlan(name: ep.name, typeName: ep.typeName))
    else:
      params.add(structFields(types, ep.typeName))
  return params

proc swiftParamList(params: seq[FieldPlan], labelFirst: bool): string =
  ## `labelFirst` keeps the first parameter labeled (ctors read `init(name:)`);
  ## methods leave it unlabeled for an idiomatic `echo("msg")` call site.
  var parts: seq[string] = @[]
  for i, fp in params:
    let label = if i == 0 and not labelFirst: "_ " & fp.name else: fp.name
    var decl = label & ": " & swiftType(fp.typeName)
    if fp.typeName.strip() notin ["string", "cstring"]:
      decl &= " = " & swiftDefault(fp.typeName)
    parts.add(decl)
  return parts.join(", ")

# --- Marshaling a flattened param into its C representation -------------------

proc emitParamMarshal(
    lines: var seq[string], p: FFIProcMeta, types: seq[FFITypeMeta], modName: string
): seq[string] =
  ## Emits the C-side locals for the call and returns the list of C argument
  ## expressions to pass after `(ctx, cb, ud, ...)`. String params are `strdup`'d
  ## and freed via `defer`; struct params are built field by field.
  var cArgs: seq[string] = @[]
  for ep in p.extraParams:
    if isSimpleScalar(ep.typeName):
      if ep.typeName.strip() in ["string", "cstring"]:
        let cvar = "c_" & ep.name
        lines.add("        let " & cvar & " = strdup(" & ep.name & ")")
        lines.add("        defer { free(" & cvar & ") }")
        cArgs.add("UnsafePointer(" & cvar & ")")
      else:
        cArgs.add(swiftType(ep.typeName) & "(" & ep.name & ")")
    else:
      # single struct param: build it field by field from the flattened args
      let sv = "c_" & ep.name
      lines.add("        var " & sv & " = " & modName & "." & ep.typeName & "()")
      for f in structFields(types, ep.typeName):
        if f.typeName.strip() in ["string", "cstring"]:
          let cvar = "c_" & ep.name & "_" & f.name
          lines.add("        let " & cvar & " = strdup(" & f.name & ")")
          lines.add("        defer { free(" & cvar & ") }")
          lines.add("        " & sv & "." & f.name & " = UnsafePointer(" & cvar & ")")
        elif f.typeName.strip() == "bool":
          lines.add("        " & sv & "." & f.name & " = " & f.name & " ? 1 : 0")
        else:
          let ct =
            if f.typeName.strip() in [
              "uint", "uint64", "uint32", "uint16", "uint8", "byte", "csize_t"
            ]: "UInt64"
            elif f.typeName.strip() in ["float", "float32"]: "Float"
            elif f.typeName.strip() == "float64": "Double"
            else: "Int64"
          lines.add("        " & sv & "." & f.name & " = " & ct & "(" & f.name & ")")
      cArgs.add(sv)
  return cArgs

# --- Result structs (one Swift value type per struct-returning proc) ----------

proc emitResultStruct(lines: var seq[string], typeName: string, fields: seq[FieldPlan]) =
  lines.add("public struct " & typeName & ": Equatable {")
  for f in fields:
    lines.add("    public let " & f.name & ": " & swiftType(f.typeName))
  lines.add("}")
  lines.add("")

# --- Per-proc method bodies ---------------------------------------------------

proc returnsString(p: FFIProcMeta): bool =
  return p.returnTypeName.strip() == "string"

proc returnsStruct(p: FFIProcMeta, types: seq[FFITypeMeta]): bool =
  return isKnownStruct(types, p.returnTypeName.strip())

proc boxName(p: FFIProcMeta): string =
  return snakeToPascalCase(p.procName) & "Box"

proc callbackName(p: FFIProcMeta): string =
  return p.procName & "Callback"

proc stripLibPrefix(procName, libName: string): string =
  ## "my_timer_echo" -> "echo"; collapses the remaining snake_case to camelCase.
  var base = procName
  if base.startsWith(libName & "_"):
    base = base[libName.len + 1 .. ^1]
  let parts = base.split('_')
  var s = parts[0]
  for i in 1 ..< parts.len:
    s &= capitalizeFirstLetter(parts[i])
  return s

proc emitMethod(
    lines: var seq[string], p: FFIProcMeta, types: seq[FFITypeMeta], modName: string
) =
  let params = flattenedParams(p, types)
  let paramList = swiftParamList(params, labelFirst = p.kind == FFIKind.CTOR)
  case p.kind
  of FFIKind.CTOR:
    lines.add("    public init(" & paramList & ") throws {")
    lines.add("        let box = Box()")
    lines.add("        let ud = Unmanaged.passUnretained(box).toOpaque()")
    var marshalLines: seq[string] = @[]
    let cArgs = emitParamMarshal(marshalLines, p, types, modName)
    lines.add(marshalLines)
    let lead = if cArgs.len > 0: cArgs.join(", ") & ", " else: ""
    lines.add(
      "        guard let c = " & p.procName & "(" & lead & "ackCallback, ud) else {"
    )
    lines.add("            throw TimerError.failed(\"create returned null\")")
    lines.add("        }")
    lines.add("        box.sem.wait()")
    lines.add("        guard box.ret == 0 else { throw TimerError.failed(box.text) }")
    lines.add("        ctx = c")
    lines.add("    }")
    lines.add("")
  of FFIKind.DTOR:
    lines.add("    deinit { " & p.procName & "(ctx) }")
    lines.add("")
  of FFIKind.FFI:
    var marshalLines: seq[string] = @[]
    let cArgs = emitParamMarshal(marshalLines, p, types, modName)
    let tail = if cArgs.len > 0: ", " & cArgs.join(", ") else: ""
    let methodName = stripLibPrefix(p.procName, p.libName)
    if returnsStruct(p, types):
      let retFields = structFields(types, p.returnTypeName)
      lines.add(
        "    public func " & methodName & "(" & paramList & ") throws -> " &
          p.returnTypeName & " {"
      )
      lines.add("        let box = " & boxName(p) & "()")
      lines.add("        let ud = Unmanaged.passUnretained(box).toOpaque()")
      lines.add(marshalLines)
      lines.add(
        "        guard " & p.procName & "(ctx, " & callbackName(p) & ", ud" & tail &
          ") == 0 else {"
      )
      lines.add(
        "            throw TimerError.failed(\"" & methodName & " dispatch failed\")"
      )
      lines.add("        }")
      lines.add("        box.sem.wait()")
      lines.add("        guard box.ret == 0 else { throw TimerError.failed(box.text) }")
      var ctorArgs: seq[string] = @[]
      for f in retFields:
        ctorArgs.add(f.name & ": box." & f.name)
      lines.add("        return " & p.returnTypeName & "(" & ctorArgs.join(", ") & ")")
      lines.add("    }")
      lines.add("")
    elif returnsString(p):
      lines.add(
        "    public func " & methodName & "(" & paramList & ") throws -> String {"
      )
      lines.add("        let box = Box()")
      lines.add("        let ud = Unmanaged.passUnretained(box).toOpaque()")
      lines.add(marshalLines)
      lines.add(
        "        guard " & p.procName & "(ctx, stringCallback, ud" & tail &
          ") == 0 else {"
      )
      lines.add(
        "            throw TimerError.failed(\"" & methodName & " dispatch failed\")"
      )
      lines.add("        }")
      lines.add("        box.sem.wait()")
      lines.add("        guard box.ret == 0 else { throw TimerError.failed(box.text) }")
      lines.add("        return box.text")
      lines.add("    }")
      lines.add("")
    else:
      lines.add("    public func " & methodName & "(" & paramList & ") throws {")
      lines.add("        let box = Box()")
      lines.add("        let ud = Unmanaged.passUnretained(box).toOpaque()")
      lines.add(marshalLines)
      lines.add(
        "        guard " & p.procName & "(ctx, ackCallback, ud" & tail &
          ") == 0 else {"
      )
      lines.add(
        "            throw TimerError.failed(\"" & methodName & " dispatch failed\")"
      )
      lines.add("        }")
      lines.add("        box.sem.wait()")
      lines.add("        guard box.ret == 0 else { throw TimerError.failed(box.text) }")
      lines.add("    }")
      lines.add("")

# --- Per-struct-return callback + box -----------------------------------------

proc emitStructCallback(
    lines: var seq[string], p: FFIProcMeta, types: seq[FFITypeMeta], modName: string
) =
  let retFields = structFields(types, p.returnTypeName)
  lines.add("final class " & boxName(p) & " {")
  lines.add("    var ret: Int32 = -1")
  lines.add("    var text = \"\"")
  for f in retFields:
    var init = ": " & swiftType(f.typeName) & " = 0"
    if f.typeName.strip() in ["string", "cstring"]:
      init = " = \"\""
    elif f.typeName.strip() == "bool":
      init = " = false"
    lines.add("    var " & f.name & init)
  lines.add("    let sem = DispatchSemaphore(value: 0)")
  lines.add("}")
  lines.add(
    "private func " & callbackName(p) &
      "(_ ret: Int32, _ msg: UnsafePointer<CChar>?,"
  )
  lines.add("                          _ len: Int, _ ud: UnsafeMutableRawPointer?) {")
  lines.add(
    "    let box = Unmanaged<" & boxName(p) & ">.fromOpaque(ud!).takeUnretainedValue()"
  )
  lines.add("    box.ret = ret")
  lines.add("    if ret == 0, let m = msg {")
  lines.add(
    "        let resp = UnsafeRawPointer(m).assumingMemoryBound(to: " & modName & "." &
      p.returnTypeName & ".self)"
  )
  for f in retFields:
    if f.typeName.strip() in ["string", "cstring"]:
      lines.add(
        "        box." & f.name & " = resp.pointee." & f.name &
          ".map { String(cString: $0) } ?? \"\""
      )
    elif f.typeName.strip() == "bool":
      lines.add("        box." & f.name & " = resp.pointee." & f.name & " != 0")
    else:
      lines.add(
        "        box." & f.name & " = " & swiftType(f.typeName) & "(resp.pointee." &
          f.name & ")"
      )
  lines.add("    } else {")
  lines.add("        box.text = rawText(msg, len)")
  lines.add("    }")
  lines.add("    box.sem.signal()")
  lines.add("}")
  lines.add("")

# --- Static preamble (shared error type, Box, rawText, ack/string callbacks) --

proc preamble(modName: string): string =
  return (
    """
// Generated by nim-ffi Swift codegen. Do not edit by hand.
//
// Idiomatic Swift wrapper over the library's native (zero-serialization) C ABI.
// Each call is dispatched on the library's background FFI thread; we block on a
// DispatchSemaphore until the result callback fires. A struct return is read out
// of the typed C-POD inside the callback — valid only for the callback's
// lifetime — and copied into a native Swift value.
import """ & modName & "\n" &
    """import Foundation

public enum TimerError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self { case let .failed(m): return m }
    }
}
"""
  )

const SharedPlumbing =
  """
// MARK: - shared callback plumbing
final class Box {
    var ret: Int32 = -1
    var text = ""
    let sem = DispatchSemaphore(value: 0)
}

func rawText(_ msg: UnsafePointer<CChar>?, _ len: Int) -> String {
    guard let m = msg, len > 0 else { return "" }
    let bytes = UnsafeRawPointer(m).assumingMemoryBound(to: UInt8.self)
    return String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
}

func ackCallback(_ ret: Int32, _ msg: UnsafePointer<CChar>?,
                 _ len: Int, _ ud: UnsafeMutableRawPointer?) {
    let box = Unmanaged<Box>.fromOpaque(ud!).takeUnretainedValue()
    box.ret = ret
    if ret != 0 { box.text = rawText(msg, len) }
    box.sem.signal()
}

func stringCallback(_ ret: Int32, _ msg: UnsafePointer<CChar>?,
                    _ len: Int, _ ud: UnsafeMutableRawPointer?) {
    let box = Unmanaged<Box>.fromOpaque(ud!).takeUnretainedValue()
    box.ret = ret
    box.text = rawText(msg, len)
    box.sem.signal()
}
"""

proc generateSwiftWrapper*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
): string =
  let modName = swiftModuleName(libName)
  let className = snakeToPascalCase(libName) & "Node"
  var lines: seq[string] = @[]
  lines.add(preamble(modName))

  # Emit a Swift result struct for every struct that appears as a return type.
  var emittedResults: seq[string] = @[]
  for p in procs:
    if not canEmit(p, types):
      continue
    let rt = p.returnTypeName.strip()
    if isKnownStruct(types, rt) and rt notin emittedResults:
      emittedResults.add(rt)
      emitResultStruct(lines, rt, structFields(types, rt))

  # The wrapper class.
  lines.add("public final class " & className & " {")
  lines.add("    private let ctx: UnsafeMutableRawPointer")
  lines.add("")
  for p in procs:
    if not canEmit(p, types):
      continue
    emitMethod(lines, p, types, modName)
  lines.add("}")
  lines.add("")

  lines.add(SharedPlumbing)
  lines.add("")

  # Per-struct-return callbacks + their boxes.
  for p in procs:
    if not canEmit(p, types):
      continue
    if returnsStruct(p, types):
      emitStructCallback(lines, p, types, modName)

  return lines.join("\n")

proc generateSwiftBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
) =
  # Report procs deferred to the seq/Option marshaling increment so coverage is
  # never silently dropped.
  for p in procs:
    if not canEmit(p, types):
      echo "swift codegen: skipping '" & p.procName &
        "' (needs seq/Option or multi-struct param marshaling — not yet supported)"
  writeFile(
    outputDir / (snakeToPascalCase(libName) & ".swift"),
    generateSwiftWrapper(procs, types, libName),
  )
