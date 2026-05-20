cmake_minimum_required(VERSION 3.14)
project(nim_ffi_bench_cbor CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Locate the repository root.
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

# Build a dedicated cbor-mode copy of the timer dylib into our own build dir.
# The shipped install_name (`@rpath/libmy_timer.dylib`, set by declareLibrary)
# forces the filename to be `libmy_timer.dylib` exactly — we just place it
# under a unique directory so it doesn't collide with the raw-mode build.
set(NIM_SRC "${REPO_ROOT}/examples/timer/timer.nim")
find_program(NIM_EXECUTABLE nim REQUIRED)

set(DYLIB_DIR "${CMAKE_CURRENT_BINARY_DIR}/cbor_lib")
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(NIM_LIB_FILE "${DYLIB_DIR}/libmy_timer.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${DYLIB_DIR}/my_timer.dll")
else()
    set(NIM_LIB_FILE "${DYLIB_DIR}/libmy_timer.so")
endif()

add_custom_command(
    OUTPUT "${NIM_LIB_FILE}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${DYLIB_DIR}"
    COMMAND "${NIM_EXECUTABLE}" c
                --mm:orc
                -d:release
                -d:chronicles_log_level=WARN
                -d:ffiMode=cbor
                --app:lib
                --noMain
                "--nimMainPrefix:libmy_timer"
                "--nimcache:${CMAKE_CURRENT_BINARY_DIR}/nimcache_cbor"
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    COMMENT "Compiling Nim library libmy_timer (cbor mode, release)"
    VERBATIM
)
add_custom_target(bench_cbor_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

add_library(my_timer SHARED IMPORTED GLOBAL)
set_target_properties(my_timer PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
add_dependencies(my_timer bench_cbor_nim_lib)

# tinycbor (vendored under ffi/codegen/templates/cpp/vendor).
set(TINYCBOR_SRC_DIR "${REPO_ROOT}/ffi/codegen/templates/cpp/vendor")
add_library(tinycbor STATIC
    "${TINYCBOR_SRC_DIR}/tinycbor/cborencoder.c"
    "${TINYCBOR_SRC_DIR}/tinycbor/cborencoder_close_container_checked.c"
    "${TINYCBOR_SRC_DIR}/tinycbor/cborparser.c"
    "${TINYCBOR_SRC_DIR}/tinycbor/cborparser_dup_string.c"
    "${TINYCBOR_SRC_DIR}/tinycbor/cborerrorstrings.c"
)
target_include_directories(tinycbor PUBLIC
    "${TINYCBOR_SRC_DIR}"
    "${TINYCBOR_SRC_DIR}/tinycbor"
)
set_property(TARGET tinycbor PROPERTY C_STANDARD 99)
set_property(TARGET tinycbor PROPERTY POSITION_INDEPENDENT_CODE ON)

add_executable(bench_timer_cbor bench_timer_cbor.cpp)
target_include_directories(bench_timer_cbor PRIVATE
    "${REPO_ROOT}/examples/timer/cpp_bindings")
target_link_libraries(bench_timer_cbor PRIVATE my_timer tinycbor)
add_dependencies(bench_timer_cbor bench_cbor_nim_lib)

# The Nim dylib's install_name is `@rpath/libmy_timer.dylib`. Point rpath
# at DYLIB_DIR so the binary finds *this* mode's copy at load time.
set_target_properties(bench_timer_cbor PROPERTIES
    BUILD_RPATH   "${DYLIB_DIR}"
    INSTALL_RPATH "${DYLIB_DIR}")
