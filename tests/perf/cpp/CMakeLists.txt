cmake_minimum_required(VERSION 3.16)
project(nim_ffi_cpp_perf CXX C)

# C++ -> Nim -> C++ e2e perf harness. Unlike tests/e2e/cpp this does NOT
# add_subdirectory the generated cpp_bindings: their nim_ffi_lib.cmake template
# builds the Nim dylib as a debug orc build, which would make the numbers
# meaningless. The `perf_cpp_e2e` nimble task builds libperfbench itself
# (-d:danger, NIM_FFI_MM matrix) into tests/perf/build/ and this project
# imports that prebuilt library.

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# MSVC defaults __cplusplus to 199711L regardless of the active /std:c++XX
# level — the generated header's C++20 guard would then misfire.
if(MSVC)
    add_compile_options(/Zc:__cplusplus)
endif()

# This file lives at tests/perf/cpp/, so the repo root is three levels up.
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

# ── Prebuilt libperfbench (built by the nimble task, not by cmake) ───────────
if(NOT PERF_LIB_DIR)
    set(PERF_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build")
endif()
get_filename_component(PERF_LIB_DIR "${PERF_LIB_DIR}" ABSOLUTE)

set(_bindings_dir "${CMAKE_CURRENT_SOURCE_DIR}/../benchlib/cpp_bindings")
if(NOT EXISTS "${_bindings_dir}/perfbench.hpp")
    message(FATAL_ERROR
        "perfbench.hpp not found in ${_bindings_dir}.\n"
        "Run `nimble perf_cpp_e2e` (or `nimble genbindings_cpp_perfbench`) first.")
endif()

set(_lib_file
    "${PERF_LIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}perfbench${CMAKE_SHARED_LIBRARY_SUFFIX}")
if(NOT EXISTS "${_lib_file}")
    message(FATAL_ERROR
        "${_lib_file} not found.\n"
        "Run `nimble perf_cpp_e2e` to build the bench library first.")
endif()

add_library(perfbench SHARED IMPORTED)
set_target_properties(perfbench PROPERTIES
    IMPORTED_LOCATION "${_lib_file}"
    INTERFACE_INCLUDE_DIRECTORIES "${_bindings_dir}")
if(WIN32)
    set_target_properties(perfbench PROPERTIES
        IMPORTED_IMPLIB "${PERF_LIB_DIR}/perfbench.lib")
endif()

# ── TinyCBOR (vendored; used by the generated CBOR codec) ────────────────────
set(TINYCBOR_SRC_DIR "${REPO_ROOT}/ffi/codegen/templates/cpp/vendor")
add_library(tinycbor STATIC
    "${TINYCBOR_SRC_DIR}/tinycbor/cborencoder.c"
    "${TINYCBOR_SRC_DIR}/tinycbor/cborencoder_close_container_checked.c"
    "${TINYCBOR_SRC_DIR}/tinycbor/cborparser.c"
    "${TINYCBOR_SRC_DIR}/tinycbor/cborparser_dup_string.c"
    "${TINYCBOR_SRC_DIR}/tinycbor/cborerrorstrings.c")
target_include_directories(tinycbor PUBLIC
    "${TINYCBOR_SRC_DIR}"
    "${TINYCBOR_SRC_DIR}/tinycbor")
set_property(TARGET tinycbor PROPERTY C_STANDARD 99)
set_property(TARGET tinycbor PROPERTY POSITION_INDEPENDENT_CODE ON)

# ── The driver ───────────────────────────────────────────────────────────────
add_executable(perf_driver perf_driver.cpp)
target_link_libraries(perf_driver PRIVATE perfbench tinycbor)
set_target_properties(perf_driver PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${PERF_LIB_DIR}")

# Nim-built dylibs use `@rpath/lib*.dylib|so` install_names on macOS and
# Linux; the driver sits in the same dir as the lib, so @loader_path/$ORIGIN
# resolves it. Windows has no rpath — the DLL already lives next to the exe.
if(APPLE)
    set_target_properties(perf_driver PROPERTIES
        BUILD_RPATH "@loader_path"
        INSTALL_RPATH "@loader_path")
elseif(UNIX)
    set_target_properties(perf_driver PROPERTIES
        BUILD_RPATH "$ORIGIN"
        INSTALL_RPATH "$ORIGIN")
endif()
