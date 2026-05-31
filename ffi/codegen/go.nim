## Go (cgo) binding generator for the nim-ffi framework.
##
## Emits a single `<lib>.go` file that wraps the native C ABI behind idiomatic
## Go. It includes the C codegen's `<lib>.h` (the native typed-arg declarations)
## and adds the piece every async-only consumer needs: a per-call response
## capture that BLOCKS until the FFI callback fires, then copies the raw result.
##
## nim-ffi 0.2.0 dispatches every `{.ffi.}` call through the FFI thread (no sync
## fast-path), so a caller cannot read the result immediately after the call —
## the generated `<lib>Call_*` C bridges register a condvar-backed callback and
## wait on it, turning each async export into a blocking Go method.
##
## Generated surface (libName = "waku" → package waku):
##   - type WakuNode struct { ctx unsafe.Pointer }
##   - func NewWaku(<ctor args...>) (*WakuNode, error)
##   - func (n *WakuNode) <Method>(<args...>) (string, error)   per {.ffi.} proc
##   - func (n *WakuNode) Destroy() error
##   - func (n *WakuNode) SetEventHandler(h func(string))       raw-JSON events
##
## Only scalar/string params are supported (matching the C codegen); a proc with
## struct/seq/Option params is skipped with a // SKIPPED comment.

import std/[os, strutils]
import ./meta, ./string_helpers
import ./c as cgen

proc nimTypeToGo(typeName: string): string =
  let t = typeName.strip()
  case t
  of "string", "cstring": "string"
  of "int", "int64", "clong": "int64"
  of "int32", "cint": "int32"
  of "int16": "int16"
  of "int8": "int8"
  of "uint", "uint64", "csize_t": "uint64"
  of "uint32", "cuint": "uint32"
  of "uint16": "uint16"
  of "uint8", "byte": "uint8"
  of "bool": "bool"
  of "float", "float32": "float32"
  of "float64": "float64"
  else: t

proc nimTypeToCParam(typeName: string): string =
  ## C type used in the generated cgo bridge signature.
  let t = typeName.strip()
  case t
  of "string", "cstring": "const char*"
  of "int", "int64", "clong": "int64_t"
  of "int32", "cint": "int32_t"
  of "int16": "int16_t"
  of "int8": "int8_t"
  of "uint", "uint64", "csize_t": "uint64_t"
  of "uint32", "cuint": "uint32_t"
  of "uint16": "uint16_t"
  of "uint8", "byte": "uint8_t"
  of "bool": "int"
  else: t

proc cgoArgType(typeName: string): string =
  ## The `C.<type>` a Go value is converted to before calling a bridge.
  let t = typeName.strip()
  case t
  of "string", "cstring": "*C.char"
  of "int", "int64", "clong": "C.int64_t"
  of "int32", "cint": "C.int32_t"
  of "int16": "C.int16_t"
  of "int8": "C.int8_t"
  of "uint", "uint64", "csize_t": "C.uint64_t"
  of "uint32", "cuint": "C.uint32_t"
  of "uint16": "C.uint16_t"
  of "uint8", "byte": "C.uint8_t"
  of "bool": "C.int"
  else: ""

proc supported(typeName: string): bool =
  cgoArgType(typeName).len > 0 or typeName.strip() in ["string", "cstring"]

# --- {.ffi.}-struct param support -------------------------------------------
# A registered {.ffi.} type is passed to the native ABI as a flat C-POD struct
# (see codegen/c.emitCStructs); cgo exposes it as `C.<Type>`. We mirror each
# type as an idiomatic Go struct and marshal it into the C struct per call,
# freeing the C-side allocations once the call returns (the native path deep-
# copies every argument, so the C buffers are safe to release immediately).

proc isFFIStruct(typeName: string, types: seq[FFITypeMeta]): bool =
  let t = typeName.strip()
  for ty in types:
    if ty.name == t:
      return true
  return false

proc isSeqT(t: string): bool =
  t.strip().startsWith("seq[") and t.strip().endsWith("]")

proc isOptT(t: string): bool =
  let s = t.strip()
  (s.startsWith("Option[") or s.startsWith("Maybe[")) and s.endsWith("]")

proc seqElemT(t: string): string =
  t.strip()["seq[".len .. ^2].strip()

proc optElemT(t: string): string =
  let s = t.strip()
  let p = if s.startsWith("Maybe["): "Maybe[".len else: "Option[".len
  s[p .. ^2].strip()

proc isStringT(t: string): bool =
  t.strip() in ["string", "cstring"]

proc goFieldType(typeName: string, types: seq[FFITypeMeta]): string =
  ## Idiomatic Go type for a struct field: seq -> slice, Option -> pointer,
  ## string -> string, scalar -> mapped, nested {.ffi.} struct -> its Go name.
  let t = typeName.strip()
  if isSeqT(t):
    "[]" & goFieldType(seqElemT(t), types)
  elif isOptT(t):
    "*" & goFieldType(optElemT(t), types)
  else:
    nimTypeToGo(t)

proc cgoElemType(typeName: string, types: seq[FFITypeMeta]): string =
  ## The cgo type for one scalar/element value.
  let t = typeName.strip()
  if isFFIStruct(t, types): "C." & t
  elif isStringT(t): "*C.char"
  else: cgoArgType(t)

proc paramSupported(typeName: string, types: seq[FFITypeMeta]): bool =
  let t = typeName.strip()
  supported(t) or isFFIStruct(t, types)

proc allSupported(p: FFIProcMeta, types: seq[FFITypeMeta]): bool =
  for ep in p.extraParams:
    if ep.isPtr or not paramSupported(ep.typeName, types):
      return false
  return true

proc methodName(procName, libName: string): string =
  let prefix = libName & "_"
  let bare =
    if procName.startsWith(prefix):
      procName[prefix.len .. ^1]
    else:
      procName
  return snakeToPascalCase(bare)

# --- Go marshalling code generators -----------------------------------------
# All emit tab-indented Go lines. `dst` is a cgo l-value, `src` a Go expression.
# String/struct/seq marshalling appends a cleanup to the local `frees` slice.

proc marshalValue(
    dst, src, typeName: string, types: seq[FFITypeMeta], tok: string
): seq[string] =
  ## Convert a single Go value `src` into the cgo field `dst`.
  var lines: seq[string] = @[]
  let t = typeName.strip()
  if isStringT(t):
    lines.add("\tcs_" & tok & " := C.CString(" & src & ")")
    lines.add(
      "\tfrees = append(frees, func() { C.free(unsafe.Pointer(cs_" & tok & ")) })"
    )
    lines.add("\t" & dst & " = cs_" & tok)
  elif isFFIStruct(t, types):
    lines.add("\tcf_" & tok & ", ff_" & tok & " := (" & src & ").toC()")
    lines.add("\tfrees = append(frees, ff_" & tok & "...)")
    lines.add("\t" & dst & " = cf_" & tok)
  elif t == "bool":
    lines.add("\tif " & src & " {")
    lines.add("\t\t" & dst & " = 1")
    lines.add("\t} else {")
    lines.add("\t\t" & dst & " = 0")
    lines.add("\t}")
  else:
    lines.add("\t" & dst & " = " & cgoArgType(t) & "(" & src & ")")
  return lines

proc cgoZeroVal(typeName: string, types: seq[FFITypeMeta]): string =
  ## A zero value of the element type, for `unsafe.Sizeof` in C array allocation.
  let t = typeName.strip()
  if isFFIStruct(t, types): "C." & t & "{}"
  elif isStringT(t): "(*C.char)(nil)"
  else: cgoArgType(t) & "(0)"

proc goMarshalField(f: FFIFieldMeta, types: seq[FFITypeMeta]): seq[string] =
  ## Populate `c.<field>` (and `c.<field>_len` / `c.<field>_present`) from
  ## `v.<Field>`, matching the C-POD layout in codegen/c.emitCStructs.
  var lines: seq[string] = @[]
  let cname = f.name
  let gofld = capitalizeFirstLetter(f.name)
  let t = f.typeName.strip()
  if isSeqT(t):
    let elem = seqElemT(t)
    let cElem = cgoElemType(elem, types)
    lines.add("\tif n_" & cname & " := len(v." & gofld & "); n_" & cname & " > 0 {")
    lines.add(
      "\t\tarr_" & cname & " := C.malloc(C.size_t(n_" & cname &
        ") * C.size_t(unsafe.Sizeof(" & cgoZeroVal(elem, types) & ")))"
    )
    lines.add(
      "\t\tsl_" & cname & " := unsafe.Slice((*" & cElem & ")(arr_" & cname & "), n_" &
        cname & ")"
    )
    lines.add("\t\tfor i := 0; i < n_" & cname & "; i++ {")
    for ln in marshalValue(
      "sl_" & cname & "[i]", "v." & gofld & "[i]", elem, types, cname & "_e"
    ):
      lines.add("\t\t" & ln)
    lines.add("\t\t}")
    lines.add("\t\tc." & cname & " = (*" & cElem & ")(arr_" & cname & ")")
    lines.add("\t\tc." & cname & "_len = C.size_t(n_" & cname & ")")
    lines.add("\t\ta_" & cname & " := arr_" & cname)
    lines.add("\t\tfrees = append(frees, func() { C.free(a_" & cname & ") })")
    lines.add("\t}")
  elif isOptT(t):
    let elem = optElemT(t)
    lines.add("\tif v." & gofld & " != nil {")
    lines.add("\t\tc." & cname & "_present = 1")
    for ln in marshalValue("c." & cname, "*v." & gofld, elem, types, cname & "_o"):
      lines.add("\t" & ln)
    lines.add("\t}")
  else:
    for ln in marshalValue("c." & cname, "v." & gofld, t, types, cname):
      lines.add(ln)
  return lines

proc emitGoTypesAndToC(types: seq[FFITypeMeta]): seq[string] =
  ## A Go struct + `toC()` marshaller for every {.ffi.} type.
  var lines: seq[string] = @[]
  for ty in types:
    lines.add("// " & ty.name & " mirrors the {.ffi.} type of the same name.")
    lines.add("type " & ty.name & " struct {")
    for f in ty.fields:
      lines.add("\t" & capitalizeFirstLetter(f.name) & " " & goFieldType(f.typeName, types))
    lines.add("}")
    lines.add("")
    lines.add(
      "// toC marshals " & ty.name &
        " into its C-POD form, returning cleanup funcs to run after the call."
    )
    lines.add("func (v " & ty.name & ") toC() (C." & ty.name & ", []func()) {")
    lines.add("\tvar c C." & ty.name)
    lines.add("\tvar frees []func()")
    for f in ty.fields:
      for ln in goMarshalField(f, types):
        lines.add(ln)
    lines.add("\treturn c, frees")
    lines.add("}")
    lines.add("")
  return lines

proc goParamConv(
    extraParams: seq[FFIParamMeta], types: seq[FFITypeMeta]
): tuple[goParams, conv, callArgs: seq[string]] =
  ## Go method/ctor parameter list, the conversion lines that turn each Go arg
  ## into a cgo value, and the resulting call-argument expressions.
  var goParams, conv, callArgs: seq[string] = @[]
  for ep in extraParams:
    let nm = ep.name
    let t = ep.typeName.strip()
    goParams.add(nm & " " & goFieldType(t, types))
    if isFFIStruct(t, types):
      conv.add("\tc_" & nm & ", free_" & nm & " := " & nm & ".toC()")
      conv.add("\tdefer func() { for _, f := range free_" & nm & " { f() } }()")
      callArgs.add("c_" & nm)
    elif isStringT(t):
      conv.add("\tc_" & nm & " := C.CString(" & nm & ")")
      conv.add("\tdefer C.free(unsafe.Pointer(c_" & nm & "))")
      callArgs.add("c_" & nm)
    elif t == "bool":
      conv.add("\tc_" & nm & " := C.int(0)")
      conv.add("\tif " & nm & " { c_" & nm & " = 1 }")
      callArgs.add("c_" & nm)
    else:
      callArgs.add(cgoArgType(t) & "(" & nm & ")")
  return (goParams, conv, callArgs)

proc generateGoFile*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
): string =
  let nodeType = capitalizeFirstLetter(libName) & "Node"
  let respT = capitalizeFirstLetter(libName) & "Resp"
  var L: seq[string] = @[]

  # Locate ctor / dtor.
  var ctor, dtor: FFIProcMeta
  var haveCtor, haveDtor = false
  for p in procs:
    if p.kind == FFIKind.CTOR:
      ctor = p
      haveCtor = true
    elif p.kind == FFIKind.DTOR:
      dtor = p
      haveDtor = true

  # ---- file + cgo preamble -------------------------------------------------
  L.add("// Code generated by nim-ffi Go codegen. DO NOT EDIT.")
  L.add("package " & libName)
  L.add("")
  L.add("/*")
  # ${SRCDIR} expands to this package's directory, so the native header and the
  # built lib (staged next to the .go) are found without extra env vars; the
  # rpath lets the dylib/.so load at runtime from the same directory.
  L.add("#cgo CFLAGS: -I${SRCDIR}")
  L.add("#cgo LDFLAGS: -L${SRCDIR} -l" & libName & " -Wl,-rpath,${SRCDIR}")
  L.add("#include \"" & libName & ".h\"")
  L.add("#include <stdlib.h>")
  L.add("#include <string.h>")
  L.add("#include <pthread.h>")
  L.add("")
  # cgo emits the exported callback with `char*` (it drops const); the forward
  # declaration must match exactly or the C compiler reports conflicting types.
  L.add(
    "extern void " & libName & "GoEvent(int ret, char* msg, size_t len, void* userData);"
  )
  L.add("")
  L.add("typedef struct {")
  L.add("  int ret; char* msg; size_t len; int done;")
  L.add("  pthread_mutex_t mu; pthread_cond_t cv;")
  L.add("} " & respT & ";")
  L.add("")
  L.add("static " & respT & "* " & libName & "RespNew() {")
  L.add("  " & respT & "* r = (" & respT & "*)calloc(1, sizeof(" & respT & "));")
  L.add("  pthread_mutex_init(&r->mu, NULL); pthread_cond_init(&r->cv, NULL);")
  L.add("  return r;")
  L.add("}")
  L.add("static void " & libName & "RespFree(" & respT & "* r) {")
  L.add("  if (!r) return;")
  L.add("  if (r->msg) free(r->msg);")
  L.add("  pthread_mutex_destroy(&r->mu); pthread_cond_destroy(&r->cv); free(r);")
  L.add("}")
  L.add("static int " & libName & "RespRet(" & respT & "* r) { return r->ret; }")
  L.add("static char* " & libName & "RespMsg(" & respT & "* r) { return r->msg; }")
  L.add("static size_t " & libName & "RespLen(" & respT & "* r) { return r->len; }")
  L.add("")
  L.add(
    "static void " & libName & "RespCb(int ret, const char* msg, size_t len, void* ud) {"
  )
  L.add("  " & respT & "* r = (" & respT & "*)ud;")
  L.add("  pthread_mutex_lock(&r->mu);")
  L.add("  r->ret = ret;")
  L.add("  // Native ABI: (msg, len) is the raw result (RET_OK) or error (RET_ERR).")
  L.add("  // Copy it so it survives past the callback.")
  L.add(
    "  char* e = (char*)malloc(len + 1); if (e) { memcpy(e, msg, len); e[len] = 0; }"
  )
  L.add("  r->msg = e; r->len = len;")
  L.add("  r->done = 1; pthread_cond_signal(&r->cv); pthread_mutex_unlock(&r->mu);")
  L.add("}")
  L.add("static void " & libName & "RespWait(" & respT & "* r) {")
  L.add("  pthread_mutex_lock(&r->mu);")
  L.add("  while (!r->done) pthread_cond_wait(&r->cv, &r->mu);")
  L.add("  pthread_mutex_unlock(&r->mu);")
  L.add("}")
  L.add("")

  # ctor bridge
  if haveCtor:
    var cparams: seq[string] = @[]
    for ep in ctor.extraParams:
      cparams.add(nimTypeToCParam(ep.typeName) & " " & ep.name)
    let cparamsStr =
      if cparams.len > 0:
        cparams.join(", ") & ", "
      else:
        ""
    var callArgs: seq[string] = @[]
    for ep in ctor.extraParams:
      callArgs.add(ep.name)
    let callArgsStr =
      if callArgs.len > 0:
        callArgs.join(", ") & ", "
      else:
        ""
    L.add(
      "static void* " & libName & "Call_" & ctor.procName & "(" & cparamsStr & respT &
        "* r) {"
    )
    L.add(
      "  void* ctx = " & ctor.procName & "(" & callArgsStr & libName & "RespCb, r);"
    )
    L.add("  " & libName & "RespWait(r);")
    L.add("  return ctx;")
    L.add("}")

  # per-proc bridges
  for p in procs:
    if p.kind != FFIKind.FFI or not allSupported(p, types):
      continue
    var cparams: seq[string] = @[]
    var callArgs: seq[string] = @[]
    for ep in p.extraParams:
      cparams.add(nimTypeToCParam(ep.typeName) & " " & ep.name)
      callArgs.add(ep.name)
    let cparamsStr =
      if cparams.len > 0:
        ", " & cparams.join(", ")
      else:
        ""
    let callArgsStr =
      if callArgs.len > 0:
        ", " & callArgs.join(", ")
      else:
        ""
    L.add(
      "static int " & libName & "Call_" & p.procName & "(void* ctx" & cparamsStr & ", " &
        respT & "* r) {"
    )
    L.add(
      "  int rc = " & p.procName & "(ctx, " & libName & "RespCb, r" & callArgsStr & ");"
    )
    L.add("  if (rc == RET_OK) " & libName & "RespWait(r);")
    L.add("  return rc;")
    L.add("}")

  # dtor + event registration bridges
  if haveDtor:
    L.add(
      "static int " & libName & "Call_" & dtor.procName & "(void* ctx) { return " &
        dtor.procName & "(ctx); }"
    )
  L.add(
    "static uint64_t " & libName & "RegisterEvents(void* ctx) { return " & libName &
      "_add_event_listener(ctx, \"\", (FFICallBack)" & libName & "GoEvent, ctx); }"
  )
  L.add("*/")
  L.add("import \"C\"")
  L.add("")
  L.add("import (")
  L.add("\t\"errors\"")
  L.add("\t\"sync\"")
  L.add("\t\"unsafe\"")
  L.add(")")
  L.add("")

  # ---- Go mirrors of the {.ffi.} types (with C-POD marshalling) ------------
  for line in emitGoTypesAndToC(types):
    L.add(line)

  # ---- Go types + helpers --------------------------------------------------
  L.add("type " & nodeType & " struct {")
  L.add("\tctx unsafe.Pointer")
  L.add("}")
  L.add("")
  L.add("// goStr extracts and frees the captured response string.")
  L.add("func respStr(r *C." & respT & ") string {")
  L.add(
    "\treturn C.GoStringN(C." & libName & "RespMsg(r), C.int(C." & libName &
      "RespLen(r)))"
  )
  L.add("}")
  L.add("")

  # event handler registry (raw JSON events)
  L.add("var (")
  L.add("\teventMu      sync.Mutex")
  L.add("\teventHandler func(string)")
  L.add(")")
  L.add("")
  L.add("// SetEventHandler installs the catch-all handler for library-initiated")
  L.add("// events (delivered as raw JSON strings).")
  L.add("func (n *" & nodeType & ") SetEventHandler(h func(string)) {")
  L.add("\teventMu.Lock()")
  L.add("\teventHandler = h")
  L.add("\teventMu.Unlock()")
  L.add("\tC." & libName & "RegisterEvents(n.ctx)")
  L.add("}")
  L.add("")
  L.add("//export " & libName & "GoEvent")
  L.add(
    "func " & libName &
      "GoEvent(ret C.int, msg *C.char, length C.size_t, userData unsafe.Pointer) {"
  )
  L.add("\teventMu.Lock()")
  L.add("\th := eventHandler")
  L.add("\teventMu.Unlock()")
  L.add("\tif h != nil && ret == C.RET_OK {")
  L.add("\t\th(C.GoStringN(msg, C.int(length)))")
  L.add("\t}")
  L.add("}")
  L.add("")

  # ---- constructor ---------------------------------------------------------
  if haveCtor:
    let (goParams, conv, callArgs) = goParamConv(ctor.extraParams, types)
    let callArgsStr =
      if callArgs.len > 0:
        callArgs.join(", ") & ", "
      else:
        ""
    L.add(
      "func New" & capitalizeFirstLetter(libName) & "(" & goParams.join(", ") & ") (*" &
        nodeType & ", error) {"
    )
    for c in conv:
      L.add(c)
    L.add("\tr := C." & libName & "RespNew()")
    L.add("\tdefer C." & libName & "RespFree(r)")
    L.add("\tctx := C." & libName & "Call_" & ctor.procName & "(" & callArgsStr & "r)")
    L.add("\tif C." & libName & "RespRet(r) != C.RET_OK {")
    L.add("\t\treturn nil, errors.New(respStr(r))")
    L.add("\t}")
    L.add("\treturn &" & nodeType & "{ctx: ctx}, nil")
    L.add("}")
    L.add("")

  # ---- methods -------------------------------------------------------------
  for p in procs:
    if p.kind != FFIKind.FFI:
      continue
    if not allSupported(p, types):
      L.add(
        "// SKIPPED " & p.procName &
          ": unsupported param (raw pointer or bare seq/Option) for Go codegen"
      )
      L.add("")
      continue
    let mName = methodName(p.procName, libName)
    let (goParams, conv, callArgs) = goParamConv(p.extraParams, types)
    let callArgsStr =
      if callArgs.len > 0:
        ", " & callArgs.join(", ")
      else:
        ""
    L.add(
      "func (n *" & nodeType & ") " & mName & "(" & goParams.join(", ") &
        ") (string, error) {"
    )
    for c in conv:
      L.add(c)
    L.add("\tr := C." & libName & "RespNew()")
    L.add("\tdefer C." & libName & "RespFree(r)")
    L.add("\tC." & libName & "Call_" & p.procName & "(n.ctx" & callArgsStr & ", r)")
    L.add("\tif C." & libName & "RespRet(r) != C.RET_OK {")
    L.add("\t\treturn \"\", errors.New(respStr(r))")
    L.add("\t}")
    L.add("\treturn respStr(r), nil")
    L.add("}")
    L.add("")

  # ---- destructor ----------------------------------------------------------
  if haveDtor:
    L.add("func (n *" & nodeType & ") Destroy() error {")
    L.add("\tif C." & libName & "Call_" & dtor.procName & "(n.ctx) != C.RET_OK {")
    L.add("\t\treturn errors.New(\"" & libName & " destroy failed\")")
    L.add("\t}")
    L.add("\treturn nil")
    L.add("}")
    L.add("")

  return L.join("\n")

proc generateGoBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
) =
  writeFile(
    outputDir / (libName & ".go"), generateGoFile(procs, types, libName, events)
  )
  # cgo `#include "<lib>.h"` resolves against this package directory, so emit the
  # native C header here too — the Go package is then self-contained (just stage
  # the built lib next to it).
  writeFile(
    outputDir / (libName & ".h"), generateCHeader(procs, types, libName, events)
  )
  # Emit a go.mod so the generated package is an importable module (parity with
  # the Rust/C++ generators that emit Cargo.toml / CMakeLists.txt). Consumers can
  # `replace <libName> => <path to this dir>`.
  let goMod = outputDir / "go.mod"
  if not fileExists(goMod):
    writeFile(goMod, "module " & libName & "\n\ngo 1.21\n")
