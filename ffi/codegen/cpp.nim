## C++ binding generator for the nim-ffi framework.
## Generates a header-only C++ binding and CMakeLists.txt from compile-time FFI metadata.

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
    return "void*"
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
  of "pointer": "void*"
  else: trimmed

proc stripLibPrefixCpp(procName, libName: string): string =
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc generateCppHeader*(
    procs: seq[FFIProcMeta], types: seq[FFITypeMeta], libName: string
): string =
  var lines: seq[string] = @[]

  # ── Includes ───────────────────────────────────────────────────────────────
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
  lines.add("#include <type_traits>")
  lines.add("#include <vector>")
  lines.add("#include <optional>")
  lines.add("#include <nlohmann/json.hpp>")
  lines.add("")

  # ── nlohmann optional<T> support ──────────────────────────────────────────
  # Use nlohmann's documented extension point (adl_serializer specialization)
  # rather than free-function to_json/from_json in namespace nlohmann -- the
  # latter is ODR-fragile across libraries that all do the same. Three
  # guards layer the protection:
  #   * NIM_FFI_NO_OPTIONAL_SERIALIZER : consumer opt-out for conflicts.
  #   * NIM_FFI_OPTIONAL_SERIALIZER_DEFINED_ : TU-level guard so multiple
  #     nim-ffi-generated headers don't redefine within one translation unit.
  #   * nlohmann version check : nlohmann >= 3.12 ships this specialization
  #     natively, so we skip to avoid an ODR violation against it.
  lines.add("#if !defined(NIM_FFI_NO_OPTIONAL_SERIALIZER) \\")
  lines.add("    && !defined(NIM_FFI_OPTIONAL_SERIALIZER_DEFINED_) \\")
  lines.add("    && (!defined(NLOHMANN_JSON_VERSION_MAJOR) \\")
  lines.add("        || (NLOHMANN_JSON_VERSION_MAJOR < 3) \\")
  lines.add("        || (NLOHMANN_JSON_VERSION_MAJOR == 3 && NLOHMANN_JSON_VERSION_MINOR < 12))")
  lines.add("#define NIM_FFI_OPTIONAL_SERIALIZER_DEFINED_")
  lines.add("namespace nlohmann {")
  lines.add("    template<typename T>")
  lines.add("    struct adl_serializer<std::optional<T>> {")
  lines.add("        static void to_json(json& j, const std::optional<T>& opt) {")
  lines.add("            if (opt) j = *opt;")
  lines.add("            else j = nullptr;")
  lines.add("        }")
  lines.add("        static void from_json(const json& j, std::optional<T>& opt) {")
  lines.add("            if (j.is_null()) opt = std::nullopt;")
  lines.add("            else opt = j.get<T>();")
  lines.add("        }")
  lines.add("    };")
  lines.add("}")
  lines.add("#endif")
  lines.add("")

  # ── Types ──────────────────────────────────────────────────────────────────
  if types.len > 0:
    lines.add("// ============================================================")
    lines.add("// Types")
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
      lines.add(
        "NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE($1, $2)" % [t.name, fieldNames.join(", ")]
      )
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
    var params: seq[string] = @[]
    if p.kind in {ffiFfiKind, ffiDtorKind}:
      params.add("void* ctx")
      params.add("FfiCallback callback")
      params.add("void* user_data")
      for ep in p.extraParams:
        params.add("const char* $1_json" % [ep.name])
    else: # ffiCtorKind
      for ep in p.extraParams:
        params.add("const char* $1_json" % [ep.name])
      params.add("FfiCallback callback")
      params.add("void* user_data")
    lines.add("int $1($2);" % [p.procName, params.join(", ")])
  lines.add("} // extern \"C\"")
  lines.add("")

  # ── Serialization helpers ──────────────────────────────────────────────────
  lines.add("template<typename T>")
  lines.add("inline std::string serializeFfiArg(const T& value) {")
  lines.add("    return nlohmann::json(value).dump();")
  lines.add("}")
  lines.add("")
  lines.add("inline std::string serializeFfiArg(void* value) {")
  lines.add("    return std::to_string(reinterpret_cast<uintptr_t>(value));")
  lines.add("}")
  lines.add("")
  # Wrap parse + get in a single try/catch so callers get a clear FFI error
  # rather than a raw nlohmann exception with an opaque JSON pointer message.
  lines.add("template<typename T>")
  lines.add("inline T deserializeFfiResult(const std::string& raw) {")
  lines.add("    try {")
  lines.add("        return nlohmann::json::parse(raw).get<T>();")
  lines.add("    } catch (const nlohmann::json::exception& e) {")
  lines.add(
    "        throw std::runtime_error(std::string(\"FFI response deserialization failed: \") + e.what());"
  )
  lines.add("    }")
  lines.add("}")
  lines.add("")
  lines.add("template<>")
  lines.add("inline void* deserializeFfiResult<void*>(const std::string& raw) {")
  lines.add("    try {")
  lines.add(
    "        return reinterpret_cast<void*>(static_cast<uintptr_t>(std::stoull(raw)));"
  )
  lines.add("    } catch (const std::exception& e) {")
  lines.add(
    "        throw std::runtime_error(std::string(\"FFI returned non-numeric address: \") + raw);"
  )
  lines.add("    }")
  lines.add("}")
  lines.add("")

  # ── Call helper (anonymous namespace, header-only) ─────────────────────────
  lines.add("// ============================================================")
  lines.add("// Synchronous call helper (anonymous namespace, header-only)")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("namespace {")
  lines.add("")
  lines.add("struct FfiCallState_ {")
  lines.add("    std::mutex              mtx;")
  lines.add("    std::condition_variable cv;")
  lines.add("    bool                    done{false};")
  lines.add("    bool                    ok{false};")
  lines.add("    std::string             msg;")
  lines.add("};")
  lines.add("")
  # user_data is a heap-allocated shared_ptr<FfiCallState_>.
  # Ownership: ffi_call_ holds one copy; this callback holds the other.
  # When ffi_call_ times out and returns before the callback fires, the
  # state stays alive (refcount 1) until Nim eventually calls back and
  # deletes cb_ref — eliminating the UAF that a stack-allocated state has.
  lines.add("inline void ffi_cb_(int ret, const char* msg, size_t /*len*/, void* ud) {")
  lines.add("    auto* sptr = static_cast<std::shared_ptr<FfiCallState_>*>(ud);")
  lines.add("    {")
  lines.add("        auto& s = **sptr;")
  lines.add("        std::lock_guard<std::mutex> lock(s.mtx);")
  lines.add("        s.ok   = (ret == 0);")
  lines.add("        s.msg  = msg ? std::string(msg) : std::string{};")
  lines.add("        s.done = true;")
  lines.add("        s.cv.notify_one();")
  lines.add("    }")
  lines.add("    delete sptr;")
  lines.add("}")
  lines.add("")
  lines.add(
    "inline std::string ffi_call_(std::function<int(FfiCallback, void*)> f,"
  )
  lines.add("                             std::chrono::milliseconds timeout) {")
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
  lines.add("        throw std::runtime_error(state->msg);")
  lines.add("    return state->msg;")
  lines.add("}")
  lines.add("")

  # ── True-async helpers ────────────────────────────────────────────────────
  # std::promise<T> + std::future<T> mirror the Rust tokio::sync::oneshot
  # design: the FFI callback completes the promise directly, so the returned
  # future becomes ready without ever blocking a thread.
  #
  # Type erasure: the C ABI callback (ffi_cb_async_) cannot be a template,
  # so the per-T completion logic is stored in a std::function held inside
  # FfiAsyncState_. The trampoline just dispatches to it and frees the state.
  lines.add("struct FfiAsyncState_ {")
  lines.add("    std::function<void(int, const char*)> complete;")
  lines.add("};")
  lines.add("")
  lines.add("inline void ffi_cb_async_(int ret, const char* msg, size_t /*len*/, void* ud) {")
  lines.add("    auto* state = static_cast<FfiAsyncState_*>(ud);")
  lines.add("    state->complete(ret, msg);")
  lines.add("    delete state;")
  lines.add("}")
  lines.add("")
  # Generic per-T helper. JSON deserialization happens in the callback (the
  # same Nim/chronos thread that already runs the blocking path's notify);
  # this keeps the returned future correctly waitable via wait_for/wait_until.
  lines.add("template<typename T>")
  lines.add("inline std::future<T> ffi_call_async_(std::function<int(FfiCallback, void*)> f) {")
  lines.add("    auto promise = std::make_shared<std::promise<T>>();")
  lines.add("    auto future  = promise->get_future();")
  lines.add("    auto* state  = new FfiAsyncState_{")
  lines.add("        [promise](int ret, const char* msg) {")
  lines.add("            const std::string s = msg ? std::string(msg) : std::string{};")
  lines.add("            try {")
  lines.add("                if (ret == 0) {")
  lines.add("                    if constexpr (std::is_same_v<T, std::string>) {")
  lines.add("                        promise->set_value(s);")
  lines.add("                    } else if constexpr (std::is_same_v<T, void*>) {")
  lines.add("                        promise->set_value(deserializeFfiResult<void*>(s));")
  lines.add("                    } else {")
  lines.add("                        promise->set_value(deserializeFfiResult<T>(s));")
  lines.add("                    }")
  lines.add("                } else {")
  lines.add("                    promise->set_exception(std::make_exception_ptr(std::runtime_error(s)));")
  lines.add("                }")
  lines.add("            } catch (...) {")
  lines.add("                promise->set_exception(std::current_exception());")
  lines.add("            }")
  lines.add("        }")
  lines.add("    };")
  lines.add("    const int ret = f(ffi_cb_async_, state);")
  lines.add("    if (ret == 2) {")
  lines.add("        delete state;")
  lines.add("        throw std::runtime_error(\"RET_MISSING_CALLBACK (internal error)\");")
  lines.add("    }")
  lines.add("    return future;")
  lines.add("}")
  lines.add("")
  lines.add("} // anonymous namespace")
  lines.add("")

  # ── High-level C++ context class ──────────────────────────────────────────
  var ctors: seq[FFIProcMeta] = @[]
  var methods: seq[FFIProcMeta] = @[]
  for p in procs:
    if p.kind == ffiCtorKind: ctors.add(p)
    else: methods.add(p)

  let libTypeName =
    if ctors.len > 0: ctors[0].libTypeName
    else: libName[0 .. 0].toUpperAscii() & libName[1 .. ^1]

  let ctxTypeName = libTypeName & "Ctx"

  lines.add("// ============================================================")
  lines.add("// High-level C++ context class")
  lines.add("//")
  lines.add("// Async methods (createAsync / <name>Async) return a std::future<T>")
  lines.add("// that becomes ready when the Nim callback fires. No thread is")
  lines.add("// spawned for the wait: the FFI callback completes the underlying")
  lines.add("// std::promise directly, mirroring the Rust tokio::oneshot path.")
  lines.add("// Apply timeouts via future.wait_for(...) on the caller's side.")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("class $1 {" % [ctxTypeName])
  lines.add("public:")

  # ── Constructors ────────────────────────────────────────────────────────
  for ctor in ctors:
    var ctorParams: seq[string] = @[]
    var epNames: seq[string] = @[]
    for ep in ctor.extraParams:
      ctorParams.add("const $1& $2" % [nimTypeToCpp(ep.typeName), ep.name])
      epNames.add(ep.name)
    let timeoutParam = "std::chrono::milliseconds timeout = std::chrono::seconds{30}"
    let ctorParamsWithTimeout =
      if ctorParams.len > 0: ctorParams.join(", ") & ", " & timeoutParam
      else: timeoutParam

    # -- create() factory --
    lines.add("    static $1 create($2) {" % [ctxTypeName, ctorParamsWithTimeout])
    for ep in ctor.extraParams:
      lines.add("        const auto $1_json = serializeFfiArg($1);" % [ep.name])
    var callArgs: seq[string] = @[]
    for ep in ctor.extraParams:
      callArgs.add("$1_json.c_str()" % [ep.name])
    callArgs.add("cb")
    callArgs.add("ud")
    lines.add("        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {")
    lines.add("            return $1($2);" % [ctor.procName, callArgs.join(", ")])
    lines.add("        }, timeout);")
    lines.add("        try {")
    lines.add("            const auto addr = std::stoull(raw);")
    lines.add(
      "            return $1(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout);" %
        [ctxTypeName]
    )
    lines.add("        } catch (const std::exception&) {")
    lines.add(
      "            throw std::runtime_error(\"FFI create returned non-numeric address: \" + raw);"
    )
    lines.add("        }")
    lines.add("    }")
    lines.add("")

    # -- createAsync() factory: true async via std::promise; no thread is
    # spawned, the FFI callback constructs the Ctx and completes the promise.
    lines.add(
      "    static std::future<$1> createAsync($2) {" %
        [ctxTypeName, ctorParamsWithTimeout]
    )
    for ep in ctor.extraParams:
      lines.add("        const auto $1_json = serializeFfiArg($1);" % [ep.name])
    lines.add("        auto promise = std::make_shared<std::promise<$1>>();" % [ctxTypeName])
    lines.add("        auto future  = promise->get_future();")
    lines.add("        auto* state  = new FfiAsyncState_{")
    lines.add("            [promise, timeout](int ret, const char* msg) {")
    lines.add("                const std::string s = msg ? std::string(msg) : std::string{};")
    lines.add("                try {")
    lines.add("                    if (ret == 0) {")
    lines.add("                        const auto addr = std::stoull(s);")
    lines.add(
      "                        promise->set_value($1(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout));" %
        [ctxTypeName]
    )
    lines.add("                    } else {")
    lines.add("                        promise->set_exception(std::make_exception_ptr(std::runtime_error(s)));")
    lines.add("                    }")
    lines.add("                } catch (...) {")
    lines.add("                    promise->set_exception(std::current_exception());")
    lines.add("                }")
    lines.add("            }")
    lines.add("        };")
    var ctorCallArgs: seq[string] = @[]
    for ep in ctor.extraParams:
      ctorCallArgs.add("$1_json.c_str()" % [ep.name])
    ctorCallArgs.add("ffi_cb_async_")
    ctorCallArgs.add("state")
    lines.add("        const int ret = $1($2);" % [ctor.procName, ctorCallArgs.join(", ")])
    lines.add("        if (ret == 2) {")
    lines.add("            delete state;")
    lines.add("            throw std::runtime_error(\"RET_MISSING_CALLBACK (internal error)\");")
    lines.add("        }")
    lines.add("        return future;")
    lines.add("    }")
    lines.add("")

  # ── Rule of 5 ──────────────────────────────────────────────────────────
  # Destructor tears down Nim threads; copies are deleted; moves transfer ownership.
  lines.add("    ~$1() {" % [ctxTypeName])
  lines.add("        if (ptr_) {")
  lines.add("            $1_destroy(ptr_);" % [libName])
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
  lines.add("            if (ptr_) $1_destroy(ptr_);" % [libName])
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
    let retCppType = nimTypeToCpp(m.returnTypeName)

    var methParams: seq[string] = @[]
    for ep in m.extraParams:
      methParams.add("const $1& $2" % [nimTypeToCpp(ep.typeName), ep.name])
    let methParamsStr = methParams.join(", ")

    lines.add("    $1 $2($3) const {" % [retCppType, methodName, methParamsStr])
    for ep in m.extraParams:
      lines.add("        const auto $1_json = serializeFfiArg($1);" % [ep.name])
    var callArgs = @["ptr_", "cb", "ud"]
    for ep in m.extraParams:
      callArgs.add("$1_json.c_str()" % [ep.name])
    lines.add("        const auto raw = ffi_call_([&](FfiCallback cb, void* ud) {")
    lines.add("            return $1($2);" % [m.procName, callArgs.join(", ")])
    lines.add("        }, timeout_);")
    if retCppType == "void*":
      lines.add("        return deserializeFfiResult<void*>(raw);")
    else:
      lines.add("        return deserializeFfiResult<$1>(raw);" % [retCppType])
    lines.add("    }")
    lines.add("")
    # -- <method>Async: true async via std::promise; the FFI callback
    # completes the promise on the Nim thread. No std::thread is spawned.
    lines.add(
      "    std::future<$1> $2Async($3) const {" %
        [retCppType, methodName, methParamsStr]
    )
    for ep in m.extraParams:
      lines.add("        const auto $1_json = serializeFfiArg($1);" % [ep.name])
    lines.add("        return ffi_call_async_<$1>([&](FfiCallback cb, void* ud) {" % [retCppType])
    var asyncCallArgs = @["ptr_", "cb", "ud"]
    for ep in m.extraParams:
      asyncCallArgs.add("$1_json.c_str()" % [ep.name])
    lines.add("            return $1($2);" % [m.procName, asyncCallArgs.join(", ")])
    lines.add("        });")
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
  ## Generates CMakeLists.txt for the C++ bindings directory.
  ## CMake uses ${...} which would clash with Nim's % format operator,
  ## so we build the file line by line using string concatenation.
  let src = nimSrcRelPath.replace("\\", "/")
  let cv = "${CMAKE_CURRENT_SOURCE_DIR}" # CMake variable shorthand
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
  L.add(
    "# ── Nim source path ───────────────────────────────────────────────────────────"
  )
  L.add("get_filename_component(NIM_SRC")
  L.add("    \"" & cv & "/" & src & "\"")
  L.add("    ABSOLUTE)")
  L.add("")
  L.add(
    "# ── Compile the Nim shared library ───────────────────────────────────────────"
  )
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
  L.add(
    "# ── Interface target exposing the generated header ────────────────────────────"
  )
  L.add("add_library(" & libName & "_headers INTERFACE)")
  L.add("target_include_directories(" & libName & "_headers INTERFACE \"" & cv & "\")")
  L.add(
    "target_link_libraries(" & libName & "_headers INTERFACE " & libName &
      " nlohmann_json::nlohmann_json)"
  )
  L.add("")
  L.add(
    "# ── Optional example executable ───────────────────────────────────────────────"
  )
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
