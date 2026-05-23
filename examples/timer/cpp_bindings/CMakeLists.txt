cmake_minimum_required(VERSION 3.14)
project(my_timer_cpp_bindings CXX C)

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
    "${CMAKE_CURRENT_SOURCE_DIR}/../timer.nim"
    ABSOLUTE)

find_program(NIM_EXECUTABLE nim REQUIRED)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(NIM_LIB_FILE "${REPO_ROOT}/libmy_timer.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${REPO_ROOT}/my_timer.dll")
    # MSVC consumers link against the `.lib` import library, not the DLL.
    # MinGW's ld emits one when asked via `--out-implib`; the resulting COFF
    # archive is readable by MSVC's link.exe.
    set(NIM_IMPLIB_FILE "${REPO_ROOT}/my_timer.lib")
else()
    set(NIM_LIB_FILE "${REPO_ROOT}/libmy_timer.so")
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
                "--nimMainPrefix:libmy_timer"
                ${NIM_IMPLIB_PASSL}
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    BYPRODUCTS "${NIM_IMPLIB_FILE}"
    COMMENT "Compiling Nim library libmy_timer"
    VERBATIM
)
add_custom_target(my_timer_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

# On Windows, an `IMPORTED SHARED` target needs IMPORTED_IMPLIB pointing at
# the `.lib` import library so MSVC's `link.exe` can resolve symbols. The
# Visual Studio multi-config generator did not pick up `IMPORTED_IMPLIB` —
# nor per-config `IMPORTED_IMPLIB_<CONFIG>` variants — and emitted
# `my_timer-NOTFOUND.obj` into every link line. Side-step the IMPORTED
# machinery on Windows by exposing the import library through a plain
# INTERFACE library that links the `.lib` by path.
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    add_library(my_timer INTERFACE)
    target_link_libraries(my_timer INTERFACE "${NIM_IMPLIB_FILE}")
else()
    add_library(my_timer SHARED IMPORTED GLOBAL)
    set_target_properties(my_timer PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
endif()
add_dependencies(my_timer my_timer_nim_lib)

# Absolute path to the runtime library (DLL/dylib/so). Exposed via the cache
# so consumers in other directories (e.g. tests/e2e/cpp) can stage the DLL
# next to their executable on Windows.
set(my_timer_RUNTIME_LIB "${NIM_LIB_FILE}" CACHE INTERNAL
    "Absolute path to the my_timer runtime library")

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

add_library(my_timer_headers INTERFACE)
target_include_directories(my_timer_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(my_timer_headers INTERFACE my_timer tinycbor)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    add_executable(my_timer_example main.cpp)
    target_link_libraries(my_timer_example PRIVATE my_timer_headers)
    add_dependencies(my_timer_example my_timer_nim_lib)
    if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        add_custom_command(TARGET my_timer_example POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${my_timer_RUNTIME_LIB}"
                "$<TARGET_FILE_DIR:my_timer_example>"
            COMMENT "Staging my_timer.dll next to my_timer_example.exe")
    endif()
endif()
