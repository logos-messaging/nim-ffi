cmake_minimum_required(VERSION 3.14)
project(echo_cpp_bindings CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

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
    "${CMAKE_CURRENT_SOURCE_DIR}/../echo.nim"
    ABSOLUTE)

find_program(NIM_EXECUTABLE nim REQUIRED)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(NIM_LIB_FILE "${REPO_ROOT}/libecho.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${REPO_ROOT}/echo.dll")
    # MSVC consumers link against the `.lib` import library, not the DLL.
    # MinGW's ld emits one when asked via `--out-implib`; the resulting COFF
    # archive is readable by MSVC's link.exe.
    set(NIM_IMPLIB_FILE "${REPO_ROOT}/echo.lib")
else()
    set(NIM_LIB_FILE "${REPO_ROOT}/libecho.so")
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
                "--nimMainPrefix:libecho"
                ${NIM_IMPLIB_PASSL}
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    BYPRODUCTS "${NIM_IMPLIB_FILE}"
    COMMENT "Compiling Nim library libecho"
    VERBATIM
)
add_custom_target(echo_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

# On Windows, an `IMPORTED SHARED` target needs IMPORTED_IMPLIB pointing at
# the `.lib` import library so MSVC's `link.exe` can resolve symbols. The
# Visual Studio multi-config generator did not pick up `IMPORTED_IMPLIB` —
# nor per-config `IMPORTED_IMPLIB_<CONFIG>` variants — and emitted
# `echo-NOTFOUND.obj` into every link line. Side-step the IMPORTED
# machinery on Windows by exposing the import library through a plain
# INTERFACE library that links the `.lib` by path.
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    add_library(echo INTERFACE)
    target_link_libraries(echo INTERFACE "${NIM_IMPLIB_FILE}")
else()
    add_library(echo SHARED IMPORTED GLOBAL)
    set_target_properties(echo PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
endif()
add_dependencies(echo echo_nim_lib)

# Absolute path to the runtime library (DLL/dylib/so). Exposed via the cache
# so consumers in other directories (e.g. tests/e2e/cpp) can stage the DLL
# next to their executable on Windows.
set(echo_RUNTIME_LIB "${NIM_LIB_FILE}" CACHE INTERNAL
    "Absolute path to the echo runtime library")

# ── TinyCBOR (vendored at ffi/codegen/templates/cpp/vendor/tinycbor) ─────────
# Guarded so a parent project can `add_subdirectory` two sibling cpp_bindings
# directories (e.g. the e2e suite loading libecho + libmy_timer together):
# both reach for the same vendored copy, so the second include would otherwise
# collide on the `tinycbor` target name.
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

add_library(echo_headers INTERFACE)
target_include_directories(echo_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(echo_headers INTERFACE echo tinycbor)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    add_executable(echo_example main.cpp)
    target_link_libraries(echo_example PRIVATE echo_headers)
    add_dependencies(echo_example echo_nim_lib)
    if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        add_custom_command(TARGET echo_example POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${echo_RUNTIME_LIB}"
                "$<TARGET_FILE_DIR:echo_example>"
            COMMENT "Staging echo.dll next to echo_example.exe")
    endif()
endif()
