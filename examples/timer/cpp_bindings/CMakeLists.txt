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
# library unless told to. Without it, CMake puts `my_timer-NOTFOUND` into
# the link line for any MSVC consumer of this target.
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
add_custom_target(nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

add_library(my_timer SHARED IMPORTED GLOBAL)
set_target_properties(my_timer PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    # The Visual Studio generator is multi-config: at generation time CMake
    # looks up IMPORTED_LOCATION_<CONFIG> / IMPORTED_IMPLIB_<CONFIG> for each
    # consumer config and emits `<target>-NOTFOUND.obj` into the link line if
    # missing. The Nim build produces a single .dll + .lib pair regardless of
    # the consumer config, so point every standard VS config at the same pair.
    set_target_properties(my_timer PROPERTIES
        IMPORTED_CONFIGURATIONS "DEBUG;RELEASE;MINSIZEREL;RELWITHDEBINFO"
        IMPORTED_IMPLIB "${NIM_IMPLIB_FILE}"
        IMPORTED_LOCATION_DEBUG "${NIM_LIB_FILE}"
        IMPORTED_LOCATION_RELEASE "${NIM_LIB_FILE}"
        IMPORTED_LOCATION_MINSIZEREL "${NIM_LIB_FILE}"
        IMPORTED_LOCATION_RELWITHDEBINFO "${NIM_LIB_FILE}"
        IMPORTED_IMPLIB_DEBUG "${NIM_IMPLIB_FILE}"
        IMPORTED_IMPLIB_RELEASE "${NIM_IMPLIB_FILE}"
        IMPORTED_IMPLIB_MINSIZEREL "${NIM_IMPLIB_FILE}"
        IMPORTED_IMPLIB_RELWITHDEBINFO "${NIM_IMPLIB_FILE}")
endif()
add_dependencies(my_timer nim_lib)

# ── TinyCBOR (vendored at ffi/codegen/templates/cpp/vendor/tinycbor) ─────────
set(TINYCBOR_SRC_DIR "${REPO_ROOT}/ffi/codegen/templates/cpp/vendor")
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

add_library(my_timer_headers INTERFACE)
target_include_directories(my_timer_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(my_timer_headers INTERFACE my_timer tinycbor)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    add_executable(example main.cpp)
    target_link_libraries(example PRIVATE my_timer_headers)
    add_dependencies(example nim_lib)
endif()
