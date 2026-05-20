cmake_minimum_required(VERSION 3.14)
project(nim_ffi_bench_raw C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

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

set(NIM_SRC "${REPO_ROOT}/examples/timer/timer.nim")
find_program(NIM_EXECUTABLE nim REQUIRED)

set(DYLIB_DIR "${CMAKE_CURRENT_BINARY_DIR}/raw_lib")
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
                -d:ffiMode=raw
                -d:ffiLang=cpp
                --app:lib
                --noMain
                "--nimMainPrefix:libmy_timer"
                "--nimcache:${CMAKE_CURRENT_BINARY_DIR}/nimcache_raw"
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    COMMENT "Compiling Nim library libmy_timer (raw mode, release)"
    VERBATIM
)
add_custom_target(bench_raw_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

add_library(my_timer SHARED IMPORTED GLOBAL)
set_target_properties(my_timer PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
add_dependencies(my_timer bench_raw_nim_lib)

add_executable(bench_timer_raw bench_timer_raw.c)
target_include_directories(bench_timer_raw PRIVATE
    "${REPO_ROOT}/examples/timer/c_bindings")
target_link_libraries(bench_timer_raw PRIVATE my_timer)
add_dependencies(bench_timer_raw bench_raw_nim_lib)

set_target_properties(bench_timer_raw PROPERTIES
    BUILD_RPATH   "${DYLIB_DIR}"
    INSTALL_RPATH "${DYLIB_DIR}")

# pthreads
find_package(Threads REQUIRED)
target_link_libraries(bench_timer_raw PRIVATE Threads::Threads)
