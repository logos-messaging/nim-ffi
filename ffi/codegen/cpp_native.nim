## Native (zero-serialization) C++ binding generator.
##
## Emits `<lib>.hpp`: an idiomatic C++ wrapper over the *native* C ABI (the
## `<name>` entry points + flat C structs declared in `<lib>.h`). Each `{.ffi.}`
## type is mirrored as a C++ struct with `toC` / `fromC` converters to the C-POD
## layout, and methods marshal typed args in / read typed struct returns out —
## no CBOR. Companion to the CBOR generator in `cpp.nim` (`<lib>_cbor.hpp`).
##
## Commit 1 covers scalar / string / bool / nested-struct fields and the procs
## that use only those (the timer's create / version / echo). Sequences,
## optionals and native events are layered on next.

import std/[os, strutils]
import ./meta, ./string_helpers
import ./c as cgen

proc isSeqT(t: string): bool =
  t.strip().startsWith("seq[") and t.strip().endsWith("]")

proc isOptT(t: string): bool =
  let s = t.strip()
  (s.startsWith("Option[") or s.startsWith("Maybe[")) and s.endsWith("]")

proc seqElem(t: string): string =
  t.strip()["seq[".len .. ^2].strip()

proc optElem(t: string): string =
  let s = t.strip()
  let p = if s.startsWith("Maybe["): "Maybe[".len else: "Option[".len
  s[p .. ^2].strip()

proc isStringT(t: string): bool =
  t.strip() in ["string", "cstring"]

proc isStructT(t: string, types: seq[FFITypeMeta]): bool =
  for ty in types:
    if ty.name == t.strip():
      return true
  false

proc scalarCpp(t: string): string =
  case t.strip()
  of "int", "int64", "clong": "int64_t"
  of "int32", "cint": "int32_t"
  of "int16": "int16_t"
  of "int8": "int8_t"
  of "uint", "uint64", "csize_t": "uint64_t"
  of "uint32", "cuint": "uint32_t"
  of "uint16": "uint16_t"
  of "uint8", "byte": "uint8_t"
  of "bool": "bool"
  of "float", "float32": "float"
  of "float64": "double"
  else: t.strip() # nested struct -> its C++ name

proc cppType(t: string): string =
  ## Idiomatic C++ type for an `{.ffi.}` field / param.
  let s = t.strip()
  if isSeqT(s): "std::vector<" & cppType(seqElem(s)) & ">"
  elif isOptT(s): "std::optional<" & cppType(optElem(s)) & ">"
  elif isStringT(s): "std::string"
  else: scalarCpp(s)

proc cElemCpp(t: string, types: seq[FFITypeMeta]): string =
  ## The C type used for one seq element / option payload (matches emitCStructs).
  let s = t.strip()
  if isStringT(s): "const char*"
  elif isStructT(s, types): "::" & s
  elif s == "bool": "int"
  else: scalarCpp(s)

# Element-granular converters. `src` yields one element on the source side.
proc toCElem(t, src: string, types: seq[FFITypeMeta]): string =
  let s = t.strip()
  if isStringT(s): src & ".c_str()"
  elif s == "bool": "(" & src & " ? 1 : 0)"
  elif isStructT(s, types): "toC(" & src & ").c"
  else: src

proc fromCElem(t, src: string, types: seq[FFITypeMeta]): string =
  let s = t.strip()
  if isStringT(s): "(" & src & " ? std::string(" & src & ") : std::string())"
  elif s == "bool": "(" & src & " != 0)"
  elif isStructT(s, types): "fromC(" & src & ")"
  else: src

proc emitTypes(types: seq[FFITypeMeta]): seq[string] =
  var L: seq[string] = @[]
  for t in types:
    # C++ struct.
    L.add("struct " & t.name & " {")
    for f in t.fields:
      L.add("    " & cppType(f.typeName) & " " & f.name & "{};")
    L.add("};")

    # Holder: owns the backing storage for any seq fields and exposes the C-POD
    # struct. Returned by value from `toC`; the std::vector buffers survive the
    # move/NRVO, and string pointers borrow the source `v` (kept alive by the
    # caller for the duration of the call).
    L.add("struct " & t.name & "C {")
    L.add("    ::" & t.name & " c{};")
    for f in t.fields:
      if isSeqT(f.typeName):
        L.add("    std::vector<" & cElemCpp(seqElem(f.typeName), types) & "> _" &
          f.name & ";")
        if isStructT(seqElem(f.typeName), types):
          L.add("    std::vector<" & cppType(seqElem(f.typeName)) & "C> _" &
            f.name & "H;")
    L.add("};")

    L.add("inline " & t.name & "C toC(const " & t.name & "& v) {")
    L.add("    " & t.name & "C h;")
    for f in t.fields:
      let ft = f.typeName.strip()
      if isSeqT(ft):
        let e = seqElem(ft)
        L.add("    for (const auto& it : v." & f.name & ") {")
        if isStructT(e, types):
          # Keep element holders alive, then collect their C structs.
          L.add("        h._" & f.name & "H.push_back(toC(it));")
        else:
          L.add("        h._" & f.name & ".push_back(" & toCElem(e, "it", types) & ");")
        L.add("    }")
        if isStructT(e, types):
          L.add("    for (const auto& hh : h._" & f.name & "H) h._" & f.name &
            ".push_back(hh.c);")
        L.add("    h.c." & f.name & " = h._" & f.name & ".empty() ? nullptr : h._" &
          f.name & ".data();")
        L.add("    h.c." & f.name & "_len = h._" & f.name & ".size();")
      elif isOptT(ft):
        let e = optElem(ft)
        L.add("    if (v." & f.name & ".has_value()) {")
        L.add("        h.c." & f.name & "_present = 1;")
        L.add("        h.c." & f.name & " = " & toCElem(e, "(*v." & f.name & ")", types) & ";")
        L.add("    }")
      elif isStringT(ft):
        L.add("    h.c." & f.name & " = v." & f.name & ".c_str();")
      elif ft == "bool":
        L.add("    h.c." & f.name & " = v." & f.name & " ? 1 : 0;")
      elif isStructT(ft, types):
        L.add("    h.c." & f.name & " = toC(v." & f.name & ").c;")
      else:
        L.add("    h.c." & f.name & " = v." & f.name & ";")
    L.add("    return h;")
    L.add("}")

    L.add("inline " & t.name & " fromC(const ::" & t.name & "& c) {")
    L.add("    " & t.name & " v{};")
    for f in t.fields:
      let ft = f.typeName.strip()
      if isSeqT(ft):
        let e = seqElem(ft)
        L.add("    for (std::size_t i = 0; i < c." & f.name & "_len; i++)")
        L.add("        v." & f.name & ".push_back(" &
          fromCElem(e, "c." & f.name & "[i]", types) & ");")
      elif isOptT(ft):
        let e = optElem(ft)
        L.add("    if (c." & f.name & "_present)")
        L.add("        v." & f.name & " = " &
          fromCElem(e, "c." & f.name, types) & ";")
      elif isStringT(ft):
        L.add("    v." & f.name & " = c." & f.name & " ? std::string(c." & f.name &
          ") : std::string();")
      elif ft == "bool":
        L.add("    v." & f.name & " = c." & f.name & " != 0;")
      elif isStructT(ft, types):
        L.add("    v." & f.name & " = fromC(c." & f.name & ");")
      else:
        L.add("    v." & f.name & " = c." & f.name & ";")
    L.add("    return v;")
    L.add("}")
    L.add("")
  return L

proc methodName(procName, libName: string): string =
  let prefix = libName & "_"
  let bare =
    if procName.startsWith(prefix):
      procName[prefix.len .. ^1]
    else:
      procName
  capitalizeFirstLetter(snakeToPascalCase(bare))

proc procSupported(p: FFIProcMeta, types: seq[FFITypeMeta]): bool =
  ## Scalar / string / `{.ffi.}`-struct params are supported (structs may carry
  ## seq/Option fields now). Bare seq/Option top-level params and raw pointers
  ## are not (the native ABI doesn't expose them either).
  for ep in p.extraParams:
    let t = ep.typeName.strip()
    if ep.isPtr or isSeqT(t) or isOptT(t):
      return false
  true

proc generateCppNativeHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
): string =
  let guard = "NIM_FFI_GEN_" & libName.toUpper() & "_NATIVE_HPP"
  let nodeT = capitalizeFirstLetter(libName) & "Node"
  var L: seq[string] = @[]
  L.add("// Generated by nim-ffi native C++ codegen. Do not edit by hand.")
  L.add("//")
  L.add("// Native (zero-serialization) wrapper over the C ABI in \"" & libName &
    ".h\". Struct params/returns cross as flat C-POD structs — no CBOR. For the")
  L.add("// inter-process path use the CBOR header (" & libName & "_cbor.hpp).")
  L.add("#ifndef " & guard)
  L.add("#define " & guard)
  L.add("")
  L.add("#include \"" & libName & ".h\"")
  L.add("#include <cstdint>")
  L.add("#include <functional>")
  L.add("#include <future>")
  L.add("#include <map>")
  L.add("#include <memory>")
  L.add("#include <optional>")
  L.add("#include <stdexcept>")
  L.add("#include <string>")
  L.add("#include <vector>")
  L.add("")
  L.add("namespace " & libName & " {")
  L.add("")

  for line in emitTypes(types):
    L.add(line)

  # Per-call blocking capture, parameterised by the C++ return type.
  L.add("namespace detail {")
  L.add("template <typename T> struct Capture {")
  L.add("    int ret = RET_ERR;")
  L.add("    T value{};")
  L.add("    std::string err;")
  L.add("    std::promise<void> done;")
  L.add("};")
  L.add("struct AckCapture {")
  L.add("    int ret = RET_ERR;")
  L.add("    std::string err;")
  L.add("    std::promise<void> done;")
  L.add("};")
  L.add("inline std::string rawText(const char* msg, std::size_t len) {")
  L.add("    return (msg && len) ? std::string(msg, len) : std::string();")
  L.add("}")
  if events.len > 0:
    L.add("// Event listener storage: a heap handler kept alive by the node so the")
    L.add("// native callback's userData stays valid until removed.")
    L.add("struct ListenerBase { virtual ~ListenerBase() = default; };")
    L.add("template <typename T> struct EventListener : ListenerBase {")
    L.add("    std::function<void(const T&)> handler;")
    L.add("    explicit EventListener(std::function<void(const T&)> h)")
    L.add("        : handler(std::move(h)) {}")
    L.add("};")
  L.add("} // namespace detail")
  if events.len > 0:
    L.add("struct ListenerHandle { std::uint64_t id = 0; };")
  L.add("")

  # Find ctor / dtor.
  var ctor, dtor: FFIProcMeta
  var haveCtor, haveDtor = false
  for p in procs:
    if p.kind == FFIKind.CTOR:
      (ctor, haveCtor) = (p, true)
    elif p.kind == FFIKind.DTOR:
      (dtor, haveDtor) = (p, true)

  # Exported C callbacks (one per struct-returning method + shared ack/string).
  L.add("extern \"C\" {")
  L.add("inline void " & libName &
    "_native_ack(int ret, const char* msg, std::size_t len, void* ud) {")
  L.add("    auto* c = static_cast<detail::AckCapture*>(ud);")
  L.add("    c->ret = ret;")
  L.add("    if (ret == RET_ERR) c->err = detail::rawText(msg, len);")
  L.add("    c->done.set_value();")
  L.add("}")
  L.add("inline void " & libName &
    "_native_str(int ret, const char* msg, std::size_t len, void* ud) {")
  L.add("    auto* c = static_cast<detail::Capture<std::string>*>(ud);")
  L.add("    c->ret = ret;")
  L.add("    if (ret == RET_OK) c->value = detail::rawText(msg, len);")
  L.add("    else c->err = detail::rawText(msg, len);")
  L.add("    c->done.set_value();")
  L.add("}")
  for p in procs:
    if p.kind != FFIKind.FFI or not procSupported(p, types):
      continue
    if not isStructT(p.returnTypeName, types):
      continue
    let rt = p.returnTypeName
    L.add("inline void " & libName & "_native_" & p.procName &
      "(int ret, const char* msg, std::size_t len, void* ud) {")
    L.add("    auto* c = static_cast<detail::Capture<" & rt & ">*>(ud);")
    L.add("    c->ret = ret;")
    L.add("    if (ret == RET_OK) c->value = fromC(*reinterpret_cast<const ::" &
      rt & "*>(msg));")
    L.add("    else c->err = detail::rawText(msg, len);")
    L.add("    c->done.set_value();")
    L.add("}")
  # One native event trampoline per event: read the typed POD, call the handler.
  for e in events:
    if not isStructT(e.payloadTypeName, types):
      continue
    let pt = e.payloadTypeName
    L.add("inline void " & libName & "_evt_" & snakeToPascalCase(e.wireName) &
      "(int ret, const char* msg, std::size_t, void* ud) {")
    L.add("    auto* l = static_cast<detail::EventListener<" & pt & ">*>(ud);")
    L.add("    if (ret == RET_OK && l->handler)")
    L.add("        l->handler(fromC(*reinterpret_cast<const ::" & pt & "*>(msg)));")
    L.add("}")
  L.add("} // extern \"C\"")
  L.add("")

  # The node class.
  L.add("class " & nodeT & " {")
  L.add(" public:")
  if haveCtor:
    var params: seq[string] = @[]
    var conv: seq[string] = @[]
    var args: seq[string] = @[]
    for ep in ctor.extraParams:
      params.add("const " & cppType(ep.typeName) & "& " & ep.name)
      if isStructT(ep.typeName, types):
        conv.add("        auto c_" & ep.name & " = toC(" & ep.name & ");")
        args.add("c_" & ep.name & ".c")
      else:
        args.add(ep.name)
    let argsStr = if args.len > 0: args.join(", ") & ", " else: ""
    L.add("    explicit " & nodeT & "(" & params.join(", ") & ") {")
    L.add("        detail::AckCapture cap;")
    L.add("        auto fut = cap.done.get_future();")
    for c in conv:
      L.add(c)
    L.add("        ctx_ = " & ctor.procName & "(" & argsStr &
      libName & "_native_ack, &cap);")
    L.add("        if (!ctx_) throw std::runtime_error(\"" & ctor.procName &
      " returned null\");")
    L.add("        fut.wait();")
    L.add("        if (cap.ret != RET_OK) throw std::runtime_error(cap.err);")
    L.add("    }")
    L.add("")

  for p in procs:
    if p.kind != FFIKind.FFI:
      continue
    if not procSupported(p, types):
      L.add("    // SKIPPED " & p.procName &
        ": seq/Option/multi-struct params not yet supported by native C++ codegen")
      continue
    let mName = methodName(p.procName, libName)
    var params: seq[string] = @[]
    var conv: seq[string] = @[]
    var args: seq[string] = @[]
    for ep in p.extraParams:
      params.add("const " & cppType(ep.typeName) & "& " & ep.name)
      if isStructT(ep.typeName, types):
        conv.add("        auto c_" & ep.name & " = toC(" & ep.name & ");")
        args.add("c_" & ep.name & ".c")
      else:
        args.add(ep.name)
    let argsStr = if args.len > 0: ", " & args.join(", ") else: ""
    let structRet = isStructT(p.returnTypeName, types)
    let retT = if structRet: p.returnTypeName else: "std::string"
    let capT = if structRet: p.returnTypeName else: "std::string"
    let cbName =
      if structRet: libName & "_native_" & p.procName else: libName & "_native_str"
    L.add("    " & retT & " " & mName & "(" & params.join(", ") & ") {")
    L.add("        detail::Capture<" & capT & "> cap;")
    L.add("        auto fut = cap.done.get_future();")
    for c in conv:
      L.add(c)
    L.add("        if (" & p.procName & "(ctx_, " & cbName & ", &cap" & argsStr &
      ") != RET_OK)")
    L.add("            throw std::runtime_error(\"" & p.procName &
      " dispatch failed\");")
    L.add("        fut.wait();")
    L.add("        if (cap.ret != RET_OK) throw std::runtime_error(cap.err);")
    L.add("        return cap.value;")
    L.add("    }")
    L.add("")

  # Native typed event handlers: On<Event>(handler) registers a native listener
  # that delivers the typed payload (read via fromC). The handler is owned by the
  # node so its address stays valid until removeEventListener.
  for e in events:
    if not isStructT(e.payloadTypeName, types):
      continue
    let pascal = snakeToPascalCase(e.wireName)
    let pt = e.payloadTypeName
    L.add("    ListenerHandle " & pascal &
      "(std::function<void(const " & pt & "&)> handler) {")
    L.add("        auto l = std::make_unique<detail::EventListener<" & pt &
      ">>(std::move(handler));")
    L.add("        auto* raw = l.get();")
    L.add("        const auto id = " & libName &
      "_add_event_listener(ctx_, \"" & e.wireName & "\", &" & libName & "_evt_" &
      pascal & ", raw);")
    L.add("        if (id == 0) return ListenerHandle{0};")
    L.add("        listeners_.emplace(id, std::move(l));")
    L.add("        return ListenerHandle{id};")
    L.add("    }")
    L.add("")
  if events.len > 0:
    L.add("    bool removeEventListener(ListenerHandle handle) {")
    L.add("        if (handle.id == 0) return false;")
    L.add("        const auto rc = " & libName &
      "_remove_event_listener(ctx_, handle.id);")
    L.add("        listeners_.erase(handle.id);")
    L.add("        return rc == 0;")
    L.add("    }")
    L.add("")

  if haveDtor:
    L.add("    ~" & nodeT & "() { if (ctx_) " & dtor.procName & "(ctx_); }")
    L.add("    " & nodeT & "(const " & nodeT & "&) = delete;")
    L.add("    " & nodeT & "& operator=(const " & nodeT & "&) = delete;")
    L.add("")
  L.add(" private:")
  L.add("    void* ctx_ = nullptr;")
  if events.len > 0:
    L.add("    std::map<std::uint64_t, std::unique_ptr<detail::ListenerBase>> listeners_;")
  L.add("};")
  L.add("")
  L.add("} // namespace " & libName)
  L.add("")
  L.add("#endif // " & guard)
  return L.join("\n")

proc generateCppNativeBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
) =
  # `<lib>_native.hpp` for now so it coexists with the CBOR `<lib>.hpp`; the
  # native-bare / `_cbor` rename (matching C) is a follow-up. Emit the native C
  # header too (the structs + entry points the .hpp includes), so the binding is
  # self-contained.
  writeFile(
    outputDir / (libName & ".h"),
    cgen.generateCHeader(procs, types, libName, events),
  )
  writeFile(
    outputDir / (libName & "_native.hpp"),
    generateCppNativeHeader(procs, types, libName, events),
  )
