cmake_minimum_required(VERSION 3.14)
project({{LIB}}_cpp_bindings CXX C)

# The generated bindings target C++20: designated initializers and other
# C++20 constructs are used throughout the emitted code.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# MSVC defaults __cplusplus to 199711L regardless of the active /std:c++XX
# level — the generated header's C++20 guard would then misfire. /Zc:__cplusplus
# makes MSVC report the actual standard. Harmless on every other compiler.
if(MSVC)
    add_compile_options(/Zc:__cplusplus)
endif()

# ── Locate the repository root (contains ffi.nimble) ─────────────────────────
set(_search_dir "${CMAKE_CURRENT_SOURCE_DIR}")
set(REPO_ROOT "")
foreach(_i RANGE 10)
    if(EXISTS "${_search_dir}/ffi.nimble")
        set(REPO_ROOT "${_search_dir}")
        break()
    endif()
    get_filename_component(_search_dir "${_search_dir}" DIRECTORY)
endforeach()
if("${REPO_ROOT}" STREQUAL "")
    message(FATAL_ERROR "Cannot find repo root (no ffi.nimble in any ancestor)")
endif()

get_filename_component(NIM_SRC
    "${CMAKE_CURRENT_SOURCE_DIR}/{{SRC}}"
    ABSOLUTE)

find_program(NIM_EXECUTABLE nim REQUIRED)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(NIM_LIB_FILE "${REPO_ROOT}/lib{{LIB}}.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${REPO_ROOT}/{{LIB}}.dll")
    # MSVC consumers link against the `.lib` import library, not the DLL.
    # MinGW's ld emits one when asked via `--out-implib`; the resulting COFF
    # archive is readable by MSVC's link.exe.
    set(NIM_IMPLIB_FILE "${REPO_ROOT}/{{LIB}}.lib")
else()
    set(NIM_LIB_FILE "${REPO_ROOT}/lib{{LIB}}.so")
endif()

# On Windows the default Nim toolchain (mingw gcc) doesn't emit an import
# library unless told to. Without it, MSVC consumers can't resolve any
# symbol exported by the DLL at link time.
set(NIM_IMPLIB_PASSL "")
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_IMPLIB_PASSL "--passL:-Wl,--out-implib,${NIM_IMPLIB_FILE}")
endif()

add_custom_command(
    OUTPUT  "${NIM_LIB_FILE}"
    COMMAND "${NIM_EXECUTABLE}" c
                --mm:orc
                -d:chronicles_log_level=WARN
                --app:lib
                --noMain
                "--nimMainPrefix:lib{{LIB}}"
                ${NIM_IMPLIB_PASSL}
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    BYPRODUCTS "${NIM_IMPLIB_FILE}"
    COMMENT "Compiling Nim library lib{{LIB}}"
    VERBATIM
)
add_custom_target({{LIB}}_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

# On Windows, an `IMPORTED SHARED` target needs IMPORTED_IMPLIB pointing at
# the `.lib` import library so MSVC's `link.exe` can resolve symbols. The
# Visual Studio multi-config generator did not pick up `IMPORTED_IMPLIB` —
# nor per-config `IMPORTED_IMPLIB_<CONFIG>` variants — and emitted
# `{{LIB}}-NOTFOUND.obj` into every link line. Side-step the IMPORTED
# machinery on Windows by exposing the import library through a plain
# INTERFACE library that links the `.lib` by path.
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    add_library({{LIB}} INTERFACE)
    target_link_libraries({{LIB}} INTERFACE "${NIM_IMPLIB_FILE}")
else()
    add_library({{LIB}} SHARED IMPORTED GLOBAL)
    set_target_properties({{LIB}} PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
endif()
add_dependencies({{LIB}} {{LIB}}_nim_lib)

# Absolute path to the runtime library (DLL/dylib/so). Exposed via the cache
# so consumers in other directories (e.g. tests/e2e/cpp) can stage the DLL
# next to their executable on Windows.
set({{LIB}}_RUNTIME_LIB "${NIM_LIB_FILE}" CACHE INTERNAL
    "Absolute path to the {{LIB}} runtime library")

# ── TinyCBOR (vendored at ffi/codegen/templates/cpp/vendor/tinycbor) ─────────
# Guarded so two sibling cpp_bindings dirs in one parent project don't redefine
# the `tinycbor` target.
set(TINYCBOR_SRC_DIR "${REPO_ROOT}/ffi/codegen/templates/cpp/vendor")
if(NOT TARGET tinycbor)
    add_library(tinycbor STATIC
        "${TINYCBOR_SRC_DIR}/tinycbor/cborencoder.c"
        "${TINYCBOR_SRC_DIR}/tinycbor/cborencoder_close_container_checked.c"
        "${TINYCBOR_SRC_DIR}/tinycbor/cborparser.c"
        "${TINYCBOR_SRC_DIR}/tinycbor/cborparser_dup_string.c"
        "${TINYCBOR_SRC_DIR}/tinycbor/cborerrorstrings.c"
    )
    target_include_directories(tinycbor PUBLIC
        "${TINYCBOR_SRC_DIR}"            # consumer uses #include <tinycbor/cbor.h>
        "${TINYCBOR_SRC_DIR}/tinycbor"   # internal _p.h includes resolve here
    )
    set_property(TARGET tinycbor PROPERTY C_STANDARD 99)
    set_property(TARGET tinycbor PROPERTY POSITION_INDEPENDENT_CODE ON)
endif()

add_library({{LIB}}_headers INTERFACE)
target_include_directories({{LIB}}_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries({{LIB}}_headers INTERFACE {{LIB}} tinycbor)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    add_executable({{LIB}}_example main.cpp)
    target_link_libraries({{LIB}}_example PRIVATE {{LIB}}_headers)
    add_dependencies({{LIB}}_example {{LIB}}_nim_lib)
    if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        add_custom_command(TARGET {{LIB}}_example POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${{{LIB}}_RUNTIME_LIB}"
                "$<TARGET_FILE_DIR:{{LIB}}_example>"
            COMMENT "Staging {{LIB}}.dll next to {{LIB}}_example.exe")
    endif()
endif()
