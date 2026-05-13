## C++ binding generator for the nim-ffi framework.
## Generates a header-only C++ binding and CMakeLists.txt. Requests/responses
## travel as CBOR (encoded via nlohmann::json::to_cbor / from_cbor on the C++
## side, matching the Nim-side cbor_serial codec).

import std/[os, strutils]
import ./meta

proc genericInnerType(typeName, prefix: string): string =
  if typeName.startsWith(prefix) and typeName.endsWith("]"):
    let start = prefix.len
    let lastIndex = typeName.len - 2
    return typeName[start .. lastIndex]
  return ""

proc nimTypeToCpp*(typeName: string): string =
  let trimmed = typeName.strip()
  if trimmed.startsWith("ptr "):
    return "uint64_t"
  else:
    let seqInner = genericInnerType(trimmed, "seq[")
    if seqInner.len > 0:
      return "std::vector<" & nimTypeToCpp(seqInner) & ">"
    let optionInner = genericInnerType(trimmed, "Option[")
    if optionInner.len > 0:
      return "std::optional<" & nimTypeToCpp(optionInner) & ">"
    let maybeInner = genericInnerType(trimmed, "Maybe[")
    if maybeInner.len > 0:
      return "std::optional<" & nimTypeToCpp(maybeInner) & ">"
  case trimmed
  of "string", "cstring": "std::string"
  of "int", "int64": "int64_t"
  of "int32": "int32_t"
  of "bool": "bool"
  of "float": "float"
  of "float64": "double"
  of "pointer": "uint64_t"
  else: trimmed

proc capitalizeFirstLetter(s: string): string =
  if s.len == 0:
    return s
  result = s
  result[0] = s[0].toUpperAscii()

proc toCamelCase(s: string): string =
  var parts = s.split('_')
  result = ""
  for p in parts:
    result.add capitalizeFirstLetter(p)

proc stripLibPrefixCpp(procName, libName: string): string =
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc reqStructName(p: FFIProcMeta): string =
  let camel = toCamelCase(p.procName)
  if p.kind == ffiCtorKind: camel & "CtorReq" else: camel & "Req"

proc generateCppHeader*(
    procs: seq[FFIProcMeta], types: seq[FFITypeMeta], libName: string
): string =
  var lines: seq[string] = @[]

  lines.add("#pragma once")
  lines.add("#include <string>")
  lines.add("#include <cstdint>")
  lines.add("#include <chrono>")
  lines.add("#include <stdexcept>")
  lines.add("#include <mutex>")
  lines.add("#include <condition_variable>")
  lines.add("#include <memory>")
  lines.add("#include <functional>")
  lines.add("#include <future>")
  lines.add("#include <vector>")
  lines.add("#include <optional>")
  lines.add("#include <nlohmann/json.hpp>")
  lines.add("")

  # ── nlohmann optional<T> support ──────────────────────────────────────────
  lines.add("namespace nlohmann {")
  lines.add("    template<typename T>")
  lines.add("    void to_json(json& j, const std::optional<T>& opt) {")
  lines.add("        if (opt) j = *opt;")
  lines.add("        else j = nullptr;")
  lines.add("    }")
  lines.add("")
  lines.add("    template<typename T>")
  lines.add("    void from_json(const json& j, std::optional<T>& opt) {")
  lines.add("        if (j.is_null()) opt = std::nullopt;")
  lines.add("        else opt = j.get<T>();")
  lines.add("    }")
  lines.add("}")
  lines.add("")

  # ── Types ──────────────────────────────────────────────────────────────────
  if types.len > 0:
    lines.add("// ============================================================")
    lines.add("// User-declared FFI types")
    lines.add("// ============================================================")
    lines.add("")
    for t in types:
      lines.add("struct $1 {" % [t.name])
      for f in t.fields:
        lines.add("    $1 $2;" % [nimTypeToCpp(f.typeName), f.name])
      lines.add("};")
      var fieldNames: seq[string] = @[]
      for f in t.fields:
        fieldNames.add(f.name)
      if fieldNames.len > 0:
        lines.add(
          "NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE($1, $2)" % [t.name, fieldNames.join(", ")]
        )
      lines.add("")

  # ── Per-proc Req structs (CBOR transport units) ───────────────────────────
  lines.add("// ============================================================")
  lines.add("// Per-proc request envelopes (CBOR encoded on the wire)")
  lines.add("// ============================================================")
  lines.add("")
  for p in procs:
    if p.kind == ffiDtorKind:
      continue
    let reqName = reqStructName(p)
    lines.add("struct $1 {" % [reqName])
    for ep in p.extraParams:
      let cppType =
        if ep.isPtr: "uint64_t"
        else: nimTypeToCpp(ep.typeName)
      lines.add("    $1 $2;" % [cppType, ep.name])
    lines.add("};")
    var fieldNames: seq[string] = @[]
    for ep in p.extraParams:
      fieldNames.add(ep.name)
    if fieldNames.len > 0:
      lines.add(
        "NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE($1, $2)" % [reqName, fieldNames.join(", ")]
      )
    else:
      # Empty struct round-trips trivially via inline helpers below.
      lines.add("inline void to_json(nlohmann::json& j, const $1&) { j = nlohmann::json::object(); }" % [reqName])
      lines.add("inline void from_json(const nlohmann::json&, $1&) {}" % [reqName])
    lines.add("")

  # ── C FFI declarations ─────────────────────────────────────────────────────
  lines.add("// ============================================================")
  lines.add("// C FFI declarations")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("extern \"C\" {")
  lines.add(
    "typedef void (*FfiCallback)(int ret, const char* msg, size_t len, void* user_data);"
  )
  lines.add("")
  for p in procs:
    case p.kind
    of ffiFfiKind:
      lines.add(
        "int $1(void* ctx, FfiCallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);" %
          [p.procName]
      )
    of ffiCtorKind:
      lines.add(
        "void* $1(const uint8_t* req_cbor, size_t req_cbor_len, FfiCallback callback, void* user_data);" %
          [p.procName]
      )
    of ffiDtorKind:
      lines.add(
        "int $1(void* ctx, FfiCallback callback, void* user_data);" % [p.procName]
      )
  lines.add("} // extern \"C\"")
  lines.add("")

  # ── CBOR helpers ───────────────────────────────────────────────────────────
  lines.add("template<typename T>")
  lines.add("inline std::vector<std::uint8_t> encodeCborFfi(const T& value) {")
  lines.add("    return nlohmann::json::to_cbor(nlohmann::json(value));")
  lines.add("}")
  lines.add("")
  lines.add("template<typename T>")
  lines.add("inline T decodeCborFfi(const std::vector<std::uint8_t>& bytes) {")
  lines.add("    try {")
  lines.add("        return nlohmann::json::from_cbor(bytes).get<T>();")
  lines.add("    } catch (const nlohmann::json::exception& e) {")
  lines.add("        throw std::runtime_error(std::string(\"FFI CBOR decode failed: \") + e.what());")
  lines.add("    }")
  lines.add("}")
  lines.add("")

  # ── Call helper (anonymous namespace, header-only) ─────────────────────────
  lines.add("// ============================================================")
  lines.add("// Synchronous call helper")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("namespace {")
  lines.add("")
  lines.add("struct FfiCallState_ {")
  lines.add("    std::mutex              mtx;")
  lines.add("    std::condition_variable cv;")
  lines.add("    bool                    done{false};")
  lines.add("    bool                    ok{false};")
  lines.add("    std::vector<std::uint8_t> bytes;")
  lines.add("    std::string             err;")
  lines.add("};")
  lines.add("")
  lines.add("inline void ffi_cb_(int ret, const char* msg, size_t len, void* ud) {")
  lines.add("    auto* sptr = static_cast<std::shared_ptr<FfiCallState_>*>(ud);")
  lines.add("    {")
  lines.add("        auto& s = **sptr;")
  lines.add("        std::lock_guard<std::mutex> lock(s.mtx);")
  lines.add("        s.ok   = (ret == 0);")
  lines.add("        if (msg && len > 0) {")
  lines.add("            if (s.ok) {")
  lines.add("                s.bytes.assign(")
  lines.add("                    reinterpret_cast<const std::uint8_t*>(msg),")
  lines.add("                    reinterpret_cast<const std::uint8_t*>(msg) + len);")
  lines.add("            } else {")
  lines.add("                s.err.assign(msg, len);")
  lines.add("            }")
  lines.add("        }")
  lines.add("        s.done = true;")
  lines.add("        s.cv.notify_one();")
  lines.add("    }")
  lines.add("    delete sptr;")
  lines.add("}")
  lines.add("")
  lines.add(
    "inline std::vector<std::uint8_t> ffi_call_(std::function<int(FfiCallback, void*)> f,"
  )
  lines.add("                                          std::chrono::milliseconds timeout) {")
  lines.add("    auto state = std::make_shared<FfiCallState_>();")
  lines.add("    auto* cb_ref = new std::shared_ptr<FfiCallState_>(state);")
  lines.add("    const int ret = f(ffi_cb_, cb_ref);")
  lines.add("    if (ret == 2) {")
  lines.add("        delete cb_ref;")
  lines.add(
    "        throw std::runtime_error(\"RET_MISSING_CALLBACK (internal error)\");"
  )
  lines.add("    }")
  lines.add("    std::unique_lock<std::mutex> lock(state->mtx);")
  lines.add(
    "    const bool fired = state->cv.wait_for(lock, timeout, [&]{ return state->done; });"
  )
  lines.add("    if (!fired)")
  lines.add(
    "        throw std::runtime_error(\"FFI call timed out after \" + std::to_string(timeout.count()) + \"ms\");"
  )
  lines.add("    if (!state->ok)")
  lines.add("        throw std::runtime_error(state->err);")
  lines.add("    return state->bytes;")
  lines.add("}")
  lines.add("")
  lines.add("} // anonymous namespace")
  lines.add("")

  # ── High-level C++ context class ──────────────────────────────────────────
  var ctors: seq[FFIProcMeta] = @[]
  var methods: seq[FFIProcMeta] = @[]
  for p in procs:
    if p.kind == ffiCtorKind: ctors.add(p)
    elif p.kind == ffiFfiKind: methods.add(p)

  let libTypeName =
    if ctors.len > 0: ctors[0].libTypeName
    else: libName[0 .. 0].toUpperAscii() & libName[1 .. ^1]

  let ctxTypeName = libTypeName & "Ctx"

  lines.add("// ============================================================")
  lines.add("// High-level C++ context class")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("class $1 {" % [ctxTypeName])
  lines.add("public:")

  # ── Constructors ────────────────────────────────────────────────────────
  for ctor in ctors:
    let reqName = reqStructName(ctor)
    var ctorParams: seq[string] = @[]
    var epNames: seq[string] = @[]
    for ep in ctor.extraParams:
      let cppType =
        if ep.isPtr: "uint64_t"
        else: nimTypeToCpp(ep.typeName)
      ctorParams.add("const $1& $2" % [cppType, ep.name])
      epNames.add(ep.name)
    let timeoutParam = "std::chrono::milliseconds timeout = std::chrono::seconds{30}"
    let ctorParamsWithTimeout =
      if ctorParams.len > 0: ctorParams.join(", ") & ", " & timeoutParam
      else: timeoutParam

    var initList: seq[string] = @[]
    for n in epNames:
      initList.add(n)
    let reqInit =
      if initList.len > 0:
        reqName & "{" & initList.join(", ") & "}"
      else:
        reqName & "{}"

    lines.add("    static $1 create($2) {" % [ctxTypeName, ctorParamsWithTimeout])
    lines.add("        const auto req = $1;" % [reqInit])
    lines.add("        const auto req_bytes = encodeCborFfi(req);")
    lines.add("        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {")
    lines.add(
      "            return $1(req_bytes.data(), req_bytes.size(), cb, ud);" %
        [ctor.procName]
    )
    lines.add("        }, timeout);")
    lines.add("        const auto addr_str = decodeCborFfi<std::string>(raw);")
    lines.add("        try {")
    lines.add("            const auto addr = std::stoull(addr_str);")
    lines.add(
      "            return $1(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout);" %
        [ctxTypeName]
    )
    lines.add("        } catch (const std::exception&) {")
    lines.add(
      "            throw std::runtime_error(\"FFI create returned non-numeric address: \" + addr_str);"
    )
    lines.add("        }")
    lines.add("    }")
    lines.add("")

    let captureList =
      if epNames.len > 0: epNames.join(", ") & ", timeout"
      else: "timeout"
    let callList =
      if epNames.len > 0: epNames.join(", ") & ", timeout"
      else: "timeout"
    lines.add(
      "    static std::future<$1> createAsync($2) {" %
        [ctxTypeName, ctorParamsWithTimeout]
    )
    lines.add(
      "        return std::async(std::launch::async, [$1]() { return create($2); });" %
        [captureList, callList]
    )
    lines.add("    }")
    lines.add("")

  # ── Rule of 5 ──────────────────────────────────────────────────────────
  lines.add("    ~$1() {" % [ctxTypeName])
  lines.add("        if (ptr_) {")
  lines.add("            $1_destroy(ptr_, nullptr, nullptr);" % [libName])
  lines.add("            ptr_ = nullptr;")
  lines.add("        }")
  lines.add("    }")
  lines.add("")
  lines.add("    $1(const $1&) = delete;" % [ctxTypeName])
  lines.add("    $1& operator=(const $1&) = delete;" % [ctxTypeName])
  lines.add("")
  lines.add(
    "    $1($1&& other) noexcept : ptr_(other.ptr_), timeout_(other.timeout_) {" %
      [ctxTypeName]
  )
  lines.add("        other.ptr_ = nullptr;")
  lines.add("    }")
  lines.add("    $1& operator=($1&& other) noexcept {" % [ctxTypeName])
  lines.add("        if (this != &other) {")
  lines.add("            if (ptr_) $1_destroy(ptr_, nullptr, nullptr);" % [libName])
  lines.add("            ptr_ = other.ptr_;")
  lines.add("            timeout_ = other.timeout_;")
  lines.add("            other.ptr_ = nullptr;")
  lines.add("        }")
  lines.add("        return *this;")
  lines.add("    }")
  lines.add("")

  # ── Instance methods ────────────────────────────────────────────────────
  for m in methods:
    let methodName = stripLibPrefixCpp(m.procName, libName)
    let retCppType =
      if m.returnIsPtr: "uint64_t"
      else: nimTypeToCpp(m.returnTypeName)
    let reqName = reqStructName(m)

    var methParams: seq[string] = @[]
    var methParamNames: seq[string] = @[]
    for ep in m.extraParams:
      let cppType =
        if ep.isPtr: "uint64_t"
        else: nimTypeToCpp(ep.typeName)
      methParams.add("const $1& $2" % [cppType, ep.name])
      methParamNames.add(ep.name)
    let methParamsStr = methParams.join(", ")
    let methParamNamesStr = methParamNames.join(", ")

    var initList: seq[string] = @[]
    for n in methParamNames:
      initList.add(n)
    let reqInit =
      if initList.len > 0:
        reqName & "{" & initList.join(", ") & "}"
      else:
        reqName & "{}"

    lines.add("    $1 $2($3) const {" % [retCppType, methodName, methParamsStr])
    lines.add("        const auto req = $1;" % [reqInit])
    lines.add("        const auto req_bytes = encodeCborFfi(req);")
    lines.add("        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {")
    lines.add(
      "            return $1(ptr_, cb, ud, req_bytes.data(), req_bytes.size());" %
        [m.procName]
    )
    lines.add("        }, timeout_);")
    lines.add("        return decodeCborFfi<$1>(raw);" % [retCppType])
    lines.add("    }")
    lines.add("")
    if methParamsStr.len > 0:
      lines.add(
        "    std::future<$1> $2Async($3) const {" %
          [retCppType, methodName, methParamsStr]
      )
      lines.add(
        "        return std::async(std::launch::async, [this, $1]() { return $2($3); });" %
          [methParamNamesStr, methodName, methParamNamesStr]
      )
      lines.add("    }")
    else:
      lines.add("    std::future<$1> $2Async() const {" % [retCppType, methodName])
      lines.add(
        "        return std::async(std::launch::async, [this]() { return $1(); });" %
          [methodName]
      )
      lines.add("    }")
    lines.add("")

  lines.add("private:")
  lines.add("    void* ptr_;")
  lines.add("    std::chrono::milliseconds timeout_;")
  lines.add(
    "    explicit $1(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}" %
      [ctxTypeName]
  )
  lines.add("};")
  lines.add("")

  result = lines.join("\n")

proc generateCppCMakeLists*(libName: string, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  let cv = "${CMAKE_CURRENT_SOURCE_DIR}"
  let rv = "${REPO_ROOT}"
  let lf = "${NIM_LIB_FILE}"
  let nm = "${NIM_EXECUTABLE}"
  let ns = "${NIM_SRC}"
  let sd = "${_search_dir}"
  var L: seq[string] = @[]
  L.add("cmake_minimum_required(VERSION 3.14)")
  L.add("project(" & libName & "_cpp_bindings CXX)")
  L.add("")
  L.add("set(CMAKE_CXX_STANDARD 17)")
  L.add("set(CMAKE_CXX_STANDARD_REQUIRED ON)")
  L.add("")
  L.add(
    "# ── nlohmann/json ─────────────────────────────────────────────────────────────"
  )
  L.add("include(FetchContent)")
  L.add("FetchContent_Declare(")
  L.add("    nlohmann_json")
  L.add("    GIT_REPOSITORY https://github.com/nlohmann/json.git")
  L.add("    GIT_TAG        v3.11.3")
  L.add("    GIT_SHALLOW    TRUE")
  L.add(")")
  L.add("FetchContent_MakeAvailable(nlohmann_json)")
  L.add("")
  L.add(
    "# ── Locate the repository root (contains ffi.nimble) ─────────────────────────"
  )
  L.add("set(_search_dir \"" & cv & "\")")
  L.add("set(REPO_ROOT \"\")")
  L.add("foreach(_i RANGE 10)")
  L.add("    if(EXISTS \"" & sd & "/ffi.nimble\")")
  L.add("        set(REPO_ROOT \"" & sd & "\")")
  L.add("        break()")
  L.add("    endif()")
  L.add("    get_filename_component(_search_dir \"" & sd & "\" DIRECTORY)")
  L.add("endforeach()")
  L.add("if(\"${REPO_ROOT}\" STREQUAL \"\")")
  L.add(
    "    message(FATAL_ERROR \"Cannot find repo root (no ffi.nimble in any ancestor)\")"
  )
  L.add("endif()")
  L.add("")
  L.add("get_filename_component(NIM_SRC")
  L.add("    \"" & cv & "/" & src & "\"")
  L.add("    ABSOLUTE)")
  L.add("")
  L.add("find_program(NIM_EXECUTABLE nim REQUIRED)")
  L.add("")
  L.add("if(CMAKE_SYSTEM_NAME STREQUAL \"Darwin\")")
  L.add("    set(NIM_LIB_FILE \"" & rv & "/lib" & libName & ".dylib\")")
  L.add("elseif(CMAKE_SYSTEM_NAME STREQUAL \"Windows\")")
  L.add("    set(NIM_LIB_FILE \"" & rv & "/" & libName & ".dll\")")
  L.add("else()")
  L.add("    set(NIM_LIB_FILE \"" & rv & "/lib" & libName & ".so\")")
  L.add("endif()")
  L.add("")
  L.add("add_custom_command(")
  L.add("    OUTPUT  \"" & lf & "\"")
  L.add("    COMMAND \"" & nm & "\" c")
  L.add("                --mm:orc")
  L.add("                -d:chronicles_log_level=WARN")
  L.add("                --app:lib")
  L.add("                --noMain")
  L.add("                \"--nimMainPrefix:lib" & libName & "\"")
  L.add("                \"-o:" & lf & "\"")
  L.add("                \"" & ns & "\"")
  L.add("    WORKING_DIRECTORY \"" & rv & "\"")
  L.add("    DEPENDS \"" & ns & "\"")
  L.add("    COMMENT \"Compiling Nim library lib" & libName & "\"")
  L.add("    VERBATIM")
  L.add(")")
  L.add("add_custom_target(nim_lib ALL DEPENDS \"" & lf & "\")")
  L.add("")
  L.add("add_library(" & libName & " SHARED IMPORTED GLOBAL)")
  L.add(
    "set_target_properties(" & libName & " PROPERTIES IMPORTED_LOCATION \"" & lf & "\")"
  )
  L.add("add_dependencies(" & libName & " nim_lib)")
  L.add("")
  L.add("add_library(" & libName & "_headers INTERFACE)")
  L.add("target_include_directories(" & libName & "_headers INTERFACE \"" & cv & "\")")
  L.add(
    "target_link_libraries(" & libName & "_headers INTERFACE " & libName &
      " nlohmann_json::nlohmann_json)"
  )
  L.add("")
  L.add("if(EXISTS \"" & cv & "/main.cpp\")")
  L.add("    add_executable(example main.cpp)")
  L.add("    target_link_libraries(example PRIVATE " & libName & "_headers)")
  L.add("    add_dependencies(example nim_lib)")
  L.add("endif()")
  L.add("")
  result = L.join("\n")

proc generateCppBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
) =
  createDir(outputDir)
  writeFile(outputDir / (libName & ".hpp"), generateCppHeader(procs, types, libName))
  writeFile(outputDir / "CMakeLists.txt", generateCppCMakeLists(libName, nimSrcRelPath))
