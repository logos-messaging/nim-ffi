cmake_minimum_required(VERSION 3.14)
project(echo_c_bindings C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

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

# Build the Nim dylib + vendored TinyCBOR (shared with the C++ backend).
set(NIM_FFI_LIB echo)
set(NIM_FFI_SRC ../echo.nim)
include("${REPO_ROOT}/ffi/codegen/templates/nim_ffi_lib.cmake")

find_package(Threads REQUIRED)

add_library(echo_headers INTERFACE)
target_include_directories(echo_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(echo_headers INTERFACE echo tinycbor Threads::Threads)
# The generated header is async (no blocking helper), but consumer code that
# waits on a result callback typically uses nanosleep / pthreads, which need a
# POSIX feature level that strict `-std=c11` hides. Define it for consumers.
target_compile_definitions(echo_headers INTERFACE _POSIX_C_SOURCE=200809L)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.c")
    add_executable(echo_example main.c)
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
