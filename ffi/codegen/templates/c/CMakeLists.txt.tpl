cmake_minimum_required(VERSION 3.14)
project({{LIB}}_c_bindings C)

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

get_filename_component(NIM_SRC
    "${CMAKE_CURRENT_SOURCE_DIR}/{{SRC}}"
    ABSOLUTE)

find_program(NIM_EXECUTABLE nim REQUIRED)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(NIM_LIB_FILE "${REPO_ROOT}/lib{{LIB}}.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${REPO_ROOT}/{{LIB}}.dll")
else()
    set(NIM_LIB_FILE "${REPO_ROOT}/lib{{LIB}}.so")
endif()

add_custom_command(
    OUTPUT  "${NIM_LIB_FILE}"
    COMMAND "${NIM_EXECUTABLE}" c
                --mm:orc
                -d:chronicles_log_level=WARN
                -d:targetLang=c
                --app:lib
                --noMain
                "--nimMainPrefix:lib{{LIB}}"
                "--nimcache:${CMAKE_CURRENT_BINARY_DIR}/nimcache_{{LIB}}_c"
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    COMMENT "Compiling Nim library lib{{LIB}} (C target)"
    VERBATIM
)
add_custom_target({{LIB}}_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

add_library({{LIB}} SHARED IMPORTED GLOBAL)
set_target_properties({{LIB}} PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
add_dependencies({{LIB}} {{LIB}}_nim_lib)

# Headers-only INTERFACE target — pure C, no extra deps.
add_library({{LIB}}_headers INTERFACE)
target_include_directories({{LIB}}_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries({{LIB}}_headers INTERFACE {{LIB}})

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.c")
    add_executable({{LIB}}_example main.c)
    target_link_libraries({{LIB}}_example PRIVATE {{LIB}}_headers)
    add_dependencies({{LIB}}_example {{LIB}}_nim_lib)
endif()
