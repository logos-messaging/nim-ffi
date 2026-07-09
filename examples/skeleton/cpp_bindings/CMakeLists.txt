cmake_minimum_required(VERSION 3.14)
project(skeleton_cpp_bindings CXX C)

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

# Build the Nim dylib + vendored TinyCBOR (shared with the C backend).
set(NIM_FFI_LIB skeleton)
set(NIM_FFI_SRC ../skeleton.nim)
include("${REPO_ROOT}/ffi/codegen/templates/nim_ffi_lib.cmake")

add_library(skeleton_headers INTERFACE)
target_include_directories(skeleton_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(skeleton_headers INTERFACE skeleton tinycbor)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    add_executable(skeleton_example main.cpp)
    target_link_libraries(skeleton_example PRIVATE skeleton_headers)
    add_dependencies(skeleton_example skeleton_nim_lib)
    if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        add_custom_command(TARGET skeleton_example POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${skeleton_RUNTIME_LIB}"
                "$<TARGET_FILE_DIR:skeleton_example>"
            COMMENT "Staging skeleton.dll next to skeleton_example.exe")
    endif()
endif()
