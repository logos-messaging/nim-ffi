## Kotlin/JNI binding generator for the nim-ffi framework.
##
## Emits the two artifacts an Android consumer needs over the *native*
## (zero-serialization) C ABI from `c.nim`:
##   - `<Lib>Node.kt` — an idiomatic Kotlin `AutoCloseable` wrapper. Each call is
##     a blocking `external fun` into the JNI shim; a struct return surfaces as a
##     Kotlin `data class`.
##   - `<lib>_jni.c` — the JNI shim. The library calls back on its own FFI
##     thread; each bridge function blocks on a condvar until the callback fires,
##     then returns a plain Java value, so the Kotlin side stays synchronous. A
##     struct return is read out of the typed C-POD inside the callback (valid
##     only there).
##
## Callback-shape selection is per proc, from its metadata: ctor/void -> `ack_cb`
## (ret + error text), `string` return -> `string_cb`, struct return -> a
## per-proc `<proc>_cb` that copies fields out inside the callback.
##
## Scope (first increment): procs whose params are scalars / strings (or a single
## `{.ffi.}` struct of those), and — for struct returns — structs whose fields
## are all strings (surfaced as a `String[]` across JNI). Procs needing
## seq/Option params, multiple struct params, or a non-string struct return are
## skipped with a logged notice so the generated code always compiles. That
## marshaling, events, and async are the next increments.

import std/[os, strutils]
import ./meta, ./string_helpers

const OrgPrefix = "org.logos"

proc pkgName(libName: string): string =
  ## "my_timer" -> "org.logos.mytimer". Underscores are dropped from the leaf so
  ## the JNI symbol needs no `_1` mangling.
  return OrgPrefix & "." & libName.replace("_", "")

proc className(libName: string): string =
  return snakeToPascalCase(libName) & "Node"

proc jniPrefix(libName: string): string =
  return "Java_" & pkgName(libName).replace(".", "_") & "_" & className(libName)

# --- shared metadata helpers --------------------------------------------------

type FieldPlan = object
  name: string
  typeName: string

proc isSimpleScalar(typeName: string): bool =
  let t = typeName.strip()
  case t
  of "string", "cstring", "bool", "float", "float32", "float64", "int", "int64",
      "int32", "int16", "int8", "clong", "cint", "uint", "uint64", "uint32",
      "uint16", "uint8", "byte", "csize_t":
    return true
  else:
    return false

proc isStringy(typeName: string): bool =
  return typeName.strip() in ["string", "cstring"]

proc structFields(types: seq[FFITypeMeta], typeName: string): seq[FieldPlan] =
  var plan: seq[FieldPlan] = @[]
  for t in types:
    if t.name == typeName:
      for f in t.fields:
        plan.add(FieldPlan(name: f.name, typeName: f.typeName))
  return plan

proc isKnownStruct(types: seq[FFITypeMeta], typeName: string): bool =
  for t in types:
    if t.name == typeName:
      return true
  return false

proc allFieldsSimple(types: seq[FFITypeMeta], typeName: string): bool =
  let fields = structFields(types, typeName)
  if fields.len == 0:
    return false
  for f in fields:
    if not isSimpleScalar(f.typeName):
      return false
  return true

proc allFieldsString(types: seq[FFITypeMeta], typeName: string): bool =
  let fields = structFields(types, typeName)
  if fields.len == 0:
    return false
  for f in fields:
    if not isStringy(f.typeName):
      return false
  return true

proc returnsString(p: FFIProcMeta): bool =
  return p.returnTypeName.strip() == "string"

proc returnsStruct(p: FFIProcMeta, types: seq[FFITypeMeta]): bool =
  return isKnownStruct(types, p.returnTypeName.strip())

proc canEmit(p: FFIProcMeta, types: seq[FFITypeMeta]): bool =
  ## Covered by this increment: simple params (with at most one struct param),
  ## and — when the return is a struct — an all-string struct.
  var structParams = 0
  for ep in p.extraParams:
    if isSimpleScalar(ep.typeName):
      continue
    if isKnownStruct(types, ep.typeName):
      inc structParams
      if not allFieldsSimple(types, ep.typeName):
        return false
    else:
      return false
  if structParams > 1:
    return false
  if returnsStruct(p, types) and not allFieldsString(types, p.returnTypeName.strip()):
    return false
  return true

proc methodBase(p: FFIProcMeta): string =
  ## "my_timer_echo" -> "echo"; snake_case tail collapsed to camelCase.
  var base = p.procName
  if base.startsWith(p.libName & "_"):
    base = base[p.libName.len + 1 .. ^1]
  let parts = base.split('_')
  var s = parts[0]
  for i in 1 ..< parts.len:
    s &= capitalizeFirstLetter(parts[i])
  return s

proc nativeName(p: FFIProcMeta): string =
  return "native" & capitalizeFirstLetter(methodBase(p))

proc cbName(p: FFIProcMeta): string =
  return methodBase(p) & "_cb"

# --- flattened parameters (a single struct param's fields flatten in) ---------

proc flatParams(p: FFIProcMeta, types: seq[FFITypeMeta]): seq[FieldPlan] =
  var params: seq[FieldPlan] = @[]
  for ep in p.extraParams:
    if isSimpleScalar(ep.typeName):
      params.add(FieldPlan(name: ep.name, typeName: ep.typeName))
    else:
      params.add(structFields(types, ep.typeName))
  return params

# === Kotlin side ==============================================================

proc ktType(typeName: string): string =
  let t = typeName.strip()
  if isStringy(t):
    return "String"
  case t
  of "bool": "Boolean"
  of "float", "float32": "Float"
  of "float64": "Double"
  else: "Long" # all integer aliases cross as int64 in the native ABI

proc ktDefault(typeName: string): string =
  let t = typeName.strip()
  if t == "bool":
    return "false"
  return "0"

proc ktParamList(params: seq[FieldPlan], withDefaults: bool): string =
  var parts: seq[string] = @[]
  for fp in params:
    var decl = fp.name & ": " & ktType(fp.typeName)
    if withDefaults and not isStringy(fp.typeName):
      decl &= " = " & ktDefault(fp.typeName)
    parts.add(decl)
  return parts.join(", ")

proc ktArgs(params: seq[FieldPlan]): string =
  var parts: seq[string] = @[]
  for fp in params:
    parts.add(fp.name)
  return parts.join(", ")

proc generateKotlin(
    procs: seq[FFIProcMeta], types: seq[FFITypeMeta], libName: string
): string =
  let cls = className(libName)
  var lines: seq[string] = @[]
  lines.add("// Generated by nim-ffi Kotlin codegen. Do not edit by hand.")
  lines.add("package " & pkgName(libName))
  lines.add("")

  # data class per all-string struct return type
  var emitted: seq[string] = @[]
  for p in procs:
    if not canEmit(p, types):
      continue
    let rt = p.returnTypeName.strip()
    if returnsStruct(p, types) and rt notin emitted:
      emitted.add(rt)
      var fieldDecls: seq[string] = @[]
      for f in structFields(types, rt):
        fieldDecls.add("val " & f.name & ": " & ktType(f.typeName))
      lines.add("/** Typed result mirroring the library's " & rt & ". */")
      lines.add("data class " & rt & "(" & fieldDecls.join(", ") & ")")
      lines.add("")

  # find the ctor to drive the primary constructor
  var ctor: FFIProcMeta
  var haveCtor = false
  for p in procs:
    if p.kind == FFIKind.CTOR and canEmit(p, types):
      ctor = p
      haveCtor = true

  let ctorParams = if haveCtor: flatParams(ctor, types) else: @[]
  lines.add(
    "class " & cls & "(" & ktParamList(ctorParams, withDefaults = false) &
      ") : AutoCloseable {"
  )
  if haveCtor:
    lines.add(
      "    private val ctx: Long = " & nativeName(ctor) & "(" & ktArgs(ctorParams) & ")"
    )
  lines.add("")

  # public methods
  for p in procs:
    if not canEmit(p, types) or p.kind != FFIKind.FFI:
      continue
    let params = flatParams(p, types)
    let pl = ktParamList(params, withDefaults = true)
    let callArgs =
      if params.len > 0: "ctx, " & ktArgs(params) else: "ctx"
    if returnsStruct(p, types):
      let rt = p.returnTypeName.strip()
      let fields = structFields(types, rt)
      lines.add("    fun " & methodBase(p) & "(" & pl & "): " & rt & " {")
      lines.add("        val a = " & nativeName(p) & "(" & callArgs & ")")
      var ctorArgs: seq[string] = @[]
      for i in 0 ..< fields.len:
        ctorArgs.add("a[" & $i & "]")
      lines.add("        return " & rt & "(" & ctorArgs.join(", ") & ")")
      lines.add("    }")
    elif returnsString(p):
      lines.add(
        "    fun " & methodBase(p) & "(" & pl & "): String = " & nativeName(p) & "(" &
          callArgs & ")"
      )
    else:
      lines.add(
        "    fun " & methodBase(p) & "(" & pl & ") = " & nativeName(p) & "(" & callArgs &
          ")"
      )

  # close()
  for p in procs:
    if p.kind == FFIKind.DTOR and canEmit(p, types):
      lines.add("    override fun close() = " & nativeName(p) & "(ctx)")
  lines.add("")

  # external declarations
  for p in procs:
    if not canEmit(p, types):
      continue
    let params = flatParams(p, types)
    case p.kind
    of FFIKind.CTOR:
      lines.add(
        "    private external fun " & nativeName(p) & "(" &
          ktParamList(params, withDefaults = false) & "): Long"
      )
    of FFIKind.DTOR:
      lines.add("    private external fun " & nativeName(p) & "(ctx: Long)")
    of FFIKind.FFI:
      let lead = if params.len > 0: "ctx: Long, " else: "ctx: Long"
      let ret =
        if returnsStruct(p, types): "): Array<String>"
        elif returnsString(p): "): String"
        else: ")"
      lines.add(
        "    private external fun " & nativeName(p) & "(" & lead &
          ktParamList(params, withDefaults = false) & ret
      )

  lines.add("")
  lines.add("    companion object {")
  lines.add("        init {")
  lines.add("            System.loadLibrary(\"" & libName & "\")")
  lines.add("            System.loadLibrary(\"" & libName & "_jni\")")
  lines.add("        }")
  lines.add("    }")
  lines.add("}")
  return lines.join("\n")

# === JNI C shim ===============================================================

proc cScalarType(typeName: string): string =
  let t = typeName.strip()
  if t in ["float", "float32"]:
    return "float"
  if t == "float64":
    return "double"
  if t == "bool":
    return "int"
  return "int64_t"

proc jniScalarType(typeName: string): string =
  let t = typeName.strip()
  if t in ["float", "float32"]:
    return "jfloat"
  if t == "float64":
    return "jdouble"
  if t == "bool":
    return "jboolean"
  return "jlong"

proc maxReturnFields(procs: seq[FFIProcMeta], types: seq[FFITypeMeta]): int =
  var m = 1
  for p in procs:
    if canEmit(p, types) and returnsStruct(p, types):
      m = max(m, structFields(types, p.returnTypeName.strip()).len)
  return m

proc emitJniMarshal(
    p: FFIProcMeta, types: seq[FFITypeMeta]
): tuple[params, pre, post, args: seq[string]] =
  ## Builds the JNI signature params, the prologue (GetStringUTFChars + struct
  ## literals), the epilogue (ReleaseStringUTFChars), and the C call arguments.
  var params, pre, post, args: seq[string] = @[]
  for ep in p.extraParams:
    if isSimpleScalar(ep.typeName):
      params.add(jniScalarType(ep.typeName) & " " & ep.name)
      args.add("(" & cScalarType(ep.typeName) & ")" & ep.name)
    else:
      var inits: seq[string] = @[]
      for f in structFields(types, ep.typeName):
        if isStringy(f.typeName):
          params.add("jstring j_" & f.name)
          pre.add(
            "  const char *" & f.name & " = (*env)->GetStringUTFChars(env, j_" &
              f.name & ", NULL);"
          )
          post.add(
            "  (*env)->ReleaseStringUTFChars(env, j_" & f.name & ", " & f.name & ");"
          )
          inits.add("." & f.name & " = " & f.name)
        else:
          params.add(jniScalarType(f.typeName) & " " & f.name)
          inits.add("." & f.name & " = (" & cScalarType(f.typeName) & ")" & f.name)
      pre.add("  " & ep.typeName & " " & ep.name & " = {" & inits.join(", ") & "};")
      args.add(ep.name)
  return (params, pre, post, args)

proc emitStructCb(
    lines: var seq[string], p: FFIProcMeta, types: seq[FFITypeMeta]
) =
  let rt = p.returnTypeName.strip()
  let fields = structFields(types, rt)
  lines.add("static void " & cbName(p) & "(int ret, const char *msg, size_t len, void *ud) {")
  lines.add("  Resp *r = ud;")
  lines.add("  pthread_mutex_lock(&r->mu);")
  lines.add("  r->ret = ret;")
  lines.add("  if (ret == RET_OK) {")
  lines.add("    const " & rt & " *e = (const " & rt & " *)msg;")
  for i, f in fields:
    lines.add(
      "    strncpy(r->fields[" & $i & "], e->" & f.name & ", sizeof(r->fields[" & $i &
        "]) - 1);"
    )
  lines.add("  } else {")
  lines.add("    copy_raw(r->text, sizeof(r->text), msg, len);")
  lines.add("  }")
  lines.add("  r->done = 1;")
  lines.add("  pthread_cond_signal(&r->cv);")
  lines.add("  pthread_mutex_unlock(&r->mu);")
  lines.add("}")

proc emitJniFunc(
    lines: var seq[string], p: FFIProcMeta, types: seq[FFITypeMeta], libName: string
) =
  let (params, pre, post, args) = emitJniMarshal(p, types)
  let sig = if params.len > 0: ", " & params.join(", ") else: ""
  let callArgs = if args.len > 0: ", " & args.join(", ") else: ""
  let fn = jniPrefix(libName) & "_" & nativeName(p)
  case p.kind
  of FFIKind.CTOR:
    # Native ctor ABI: void *<name>(<typed args...>, cb, ud).
    let lead = if args.len > 0: args.join(", ") & ", " else: ""
    lines.add("JNIEXPORT jlong JNICALL")
    lines.add(fn & "(JNIEnv *env, jobject thiz" & sig & ") {")
    lines.add(pre)
    lines.add("  Resp r;")
    lines.add("  resp_init(&r);")
    lines.add("  void *ctx = " & p.procName & "(" & lead & "ack_cb, &r);")
    lines.add("  resp_wait(&r);")
    lines.add(post)
    lines.add("  resp_destroy(&r);")
    lines.add("  (void)thiz;")
    lines.add("  return (jlong)(intptr_t)ctx;")
    lines.add("}")
  of FFIKind.DTOR:
    lines.add("JNIEXPORT void JNICALL")
    lines.add(fn & "(JNIEnv *env, jobject thiz, jlong ctx) {")
    lines.add("  " & p.procName & "((void *)(intptr_t)ctx);")
    lines.add("  (void)env;")
    lines.add("  (void)thiz;")
    lines.add("}")
  of FFIKind.FFI:
    if returnsStruct(p, types):
      let n = structFields(types, p.returnTypeName.strip()).len
      lines.add("JNIEXPORT jobjectArray JNICALL")
      lines.add(fn & "(JNIEnv *env, jobject thiz, jlong ctx" & sig & ") {")
      lines.add(pre)
      lines.add("  Resp r;")
      lines.add("  resp_init(&r);")
      lines.add(
        "  if (" & p.procName & "((void *)(intptr_t)ctx, " & cbName(p) & ", &r" &
          callArgs & ") == RET_OK)"
      )
      lines.add("    resp_wait(&r);")
      lines.add(post)
      lines.add("  jclass strClass = (*env)->FindClass(env, \"java/lang/String\");")
      lines.add(
        "  jobjectArray arr = (*env)->NewObjectArray(env, " & $n & ", strClass, NULL);"
      )
      for i in 0 ..< n:
        lines.add(
          "  (*env)->SetObjectArrayElement(env, arr, " & $i &
            ", (*env)->NewStringUTF(env, r.fields[" & $i & "]));"
        )
      lines.add("  resp_destroy(&r);")
      lines.add("  (void)thiz;")
      lines.add("  return arr;")
      lines.add("}")
    elif returnsString(p):
      lines.add("JNIEXPORT jstring JNICALL")
      lines.add(fn & "(JNIEnv *env, jobject thiz, jlong ctx" & sig & ") {")
      lines.add(pre)
      lines.add("  Resp r;")
      lines.add("  resp_init(&r);")
      lines.add(
        "  if (" & p.procName & "((void *)(intptr_t)ctx, string_cb, &r" & callArgs &
          ") == RET_OK)"
      )
      lines.add("    resp_wait(&r);")
      lines.add(post)
      lines.add("  jstring out = (*env)->NewStringUTF(env, r.text);")
      lines.add("  resp_destroy(&r);")
      lines.add("  (void)thiz;")
      lines.add("  return out;")
      lines.add("}")
    else:
      lines.add("JNIEXPORT void JNICALL")
      lines.add(fn & "(JNIEnv *env, jobject thiz, jlong ctx" & sig & ") {")
      lines.add(pre)
      lines.add("  Resp r;")
      lines.add("  resp_init(&r);")
      lines.add(
        "  if (" & p.procName & "((void *)(intptr_t)ctx, ack_cb, &r" & callArgs &
          ") == RET_OK)"
      )
      lines.add("    resp_wait(&r);")
      lines.add(post)
      lines.add("  resp_destroy(&r);")
      lines.add("  (void)env;")
      lines.add("  (void)thiz;")
      lines.add("}")
  lines.add("")

proc jniPreamble(libName: string, maxFields: int): string =
  return (
    """
// Generated by nim-ffi Kotlin/JNI codegen. Do not edit by hand.
//
// JNI bridge exposing the library's native (zero-serialization) C ABI to Kotlin.
// The library calls back on its own FFI thread; each bridge function blocks on a
// condvar until the callback fires, then returns a plain Java value — so the
// Kotlin side sees a simple synchronous API. A struct return is read out of the
// typed C-POD inside the callback (valid only there).
#include """" & libName &
    """.h"

#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  int ret, done;
  char text[1024];           // string return / error text
  char fields[""" & $maxFields &
    """][256];  // string fields of a struct return
  pthread_mutex_t mu;
  pthread_cond_t cv;
} Resp;

static void resp_init(Resp *r) {
  memset(r, 0, sizeof(*r));
  pthread_mutex_init(&r->mu, NULL);
  pthread_cond_init(&r->cv, NULL);
}
static void resp_destroy(Resp *r) {
  pthread_mutex_destroy(&r->mu);
  pthread_cond_destroy(&r->cv);
}
static void resp_wait(Resp *r) {
  pthread_mutex_lock(&r->mu);
  while (!r->done) pthread_cond_wait(&r->cv, &r->mu);
  pthread_mutex_unlock(&r->mu);
}

static void copy_raw(char *dst, size_t cap, const char *msg, size_t len) {
  size_t n = len < cap - 1 ? len : cap - 1;
  if (msg && n) memcpy(dst, msg, n);
  dst[n] = '\0';
}

static void ack_cb(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  if (ret == RET_ERR) copy_raw(r->text, sizeof(r->text), msg, len);
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}
static void string_cb(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  copy_raw(r->text, sizeof(r->text), msg, len);
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}
"""
  )

proc generateJni(
    procs: seq[FFIProcMeta], types: seq[FFITypeMeta], libName: string
): string =
  var lines: seq[string] = @[]
  lines.add(jniPreamble(libName, maxReturnFields(procs, types)))
  for p in procs:
    if canEmit(p, types) and returnsStruct(p, types):
      emitStructCb(lines, p, types)
  lines.add("")
  for p in procs:
    if canEmit(p, types):
      emitJniFunc(lines, p, types, libName)
  return lines.join("\n")

# === entry point ==============================================================

proc generateKotlinBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
) =
  ## `outputDir` is the Android module root. The Kotlin wrapper lands under its
  ## package path; the JNI shim under `jni/`. The C headers it includes come from
  ## the C generator (`genbindings_c`).
  for p in procs:
    if not canEmit(p, types):
      echo "kotlin codegen: skipping '" & p.procName &
        "' (needs seq/Option, multi-struct params, or a non-string struct return" &
        " — not yet supported)"

  let ktDir = outputDir / "src/main/kotlin" / pkgName(libName).replace(".", "/")
  createDir(ktDir)
  writeFile(ktDir / (className(libName) & ".kt"), generateKotlin(procs, types, libName))

  let jniDir = outputDir / "jni"
  createDir(jniDir)
  writeFile(jniDir / (libName & "_jni.c"), generateJni(procs, types, libName))
