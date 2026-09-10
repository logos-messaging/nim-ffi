cmake_minimum_required(VERSION 3.14)
project({{LIB}}_c_bindings C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

{{FIND_REPO_ROOT}}

# Build the Nim dylib + vendored TinyCBOR (shared with the C++ backend).
set(NIM_FFI_LIB {{LIB}})
set(NIM_FFI_SRC {{SRC}})
include("${REPO_ROOT}/ffi/codegen/templates/nim_ffi_lib.cmake")

find_package(Threads REQUIRED)

add_library({{LIB}}_headers INTERFACE)
target_include_directories({{LIB}}_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries({{LIB}}_headers INTERFACE {{LIB}} tinycbor Threads::Threads)
# The generated header is async (no blocking helper), but consumer code that
# waits on a result callback typically uses nanosleep / pthreads, which need a
# POSIX feature level that strict `-std=c11` hides. Define it for consumers.
target_compile_definitions({{LIB}}_headers INTERFACE _POSIX_C_SOURCE=200809L)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.c")
    add_executable({{LIB}}_example main.c)
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
