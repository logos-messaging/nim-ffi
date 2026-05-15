cmake_minimum_required(VERSION 3.14)
project(timer_cpp_bindings CXX C)

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
    set(NIM_LIB_FILE "${REPO_ROOT}/libtimer.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${REPO_ROOT}/timer.dll")
else()
    set(NIM_LIB_FILE "${REPO_ROOT}/libtimer.so")
endif()

add_custom_command(
    OUTPUT  "${NIM_LIB_FILE}"
    COMMAND "${NIM_EXECUTABLE}" c
                --mm:orc
                -d:chronicles_log_level=WARN
                --app:lib
                --noMain
                "--nimMainPrefix:libtimer"
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    COMMENT "Compiling Nim library libtimer"
    VERBATIM
)
add_custom_target(nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

add_library(timer SHARED IMPORTED GLOBAL)
set_target_properties(timer PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
add_dependencies(timer nim_lib)

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

add_library(timer_headers INTERFACE)
target_include_directories(timer_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(timer_headers INTERFACE timer tinycbor)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    add_executable(example main.cpp)
    target_link_libraries(example PRIVATE timer_headers)
    add_dependencies(example nim_lib)
endif()
