cmake_minimum_required(VERSION 3.14)
project({{LIB}}_cpp_bindings CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── nlohmann/json ─────────────────────────────────────────────────────────────
include(FetchContent)
FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG        v3.11.3
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(nlohmann_json)

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
                --app:lib
                --noMain
                "--nimMainPrefix:lib{{LIB}}"
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    COMMENT "Compiling Nim library lib{{LIB}}"
    VERBATIM
)
add_custom_target(nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

add_library({{LIB}} SHARED IMPORTED GLOBAL)
set_target_properties({{LIB}} PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
add_dependencies({{LIB}} nim_lib)

add_library({{LIB}}_headers INTERFACE)
target_include_directories({{LIB}}_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries({{LIB}}_headers INTERFACE {{LIB}} nlohmann_json::nlohmann_json)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    add_executable(example main.cpp)
    target_link_libraries(example PRIVATE {{LIB}}_headers)
    add_dependencies(example nim_lib)
endif()
