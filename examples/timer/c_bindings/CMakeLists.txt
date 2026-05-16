cmake_minimum_required(VERSION 3.14)
project(my_timer_c_bindings C)

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
    "${CMAKE_CURRENT_SOURCE_DIR}/../timer.nim"
    ABSOLUTE)

find_program(NIM_EXECUTABLE nim REQUIRED)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(NIM_LIB_FILE "${REPO_ROOT}/libmy_timer.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${REPO_ROOT}/my_timer.dll")
else()
    set(NIM_LIB_FILE "${REPO_ROOT}/libmy_timer.so")
endif()

add_custom_command(
    OUTPUT  "${NIM_LIB_FILE}"
    COMMAND "${NIM_EXECUTABLE}" c
                --mm:orc
                -d:chronicles_log_level=WARN
                -d:targetLang=c
                --app:lib
                --noMain
                "--nimMainPrefix:libmy_timer"
                "--nimcache:${CMAKE_CURRENT_BINARY_DIR}/nimcache_my_timer_c"
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    COMMENT "Compiling Nim library libmy_timer (C target)"
    VERBATIM
)
add_custom_target(my_timer_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

add_library(my_timer SHARED IMPORTED GLOBAL)
set_target_properties(my_timer PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
add_dependencies(my_timer my_timer_nim_lib)

# Headers-only INTERFACE target — pure C, no extra deps.
add_library(my_timer_headers INTERFACE)
target_include_directories(my_timer_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(my_timer_headers INTERFACE my_timer)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.c")
    add_executable(my_timer_example main.c)
    target_link_libraries(my_timer_example PRIVATE my_timer_headers)
    add_dependencies(my_timer_example my_timer_nim_lib)
endif()
