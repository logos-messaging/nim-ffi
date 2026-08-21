cmake_minimum_required(VERSION 3.14)
project(nim_ffi_cpp_e2e CXX)

# Test harness compiles at C++20 so we can use designated initializers
# (`.field = …`) in test bodies; MSVC rejects them under /std:c++17.
# The generated example bindings and the CMake template they ship with
# stay at C++17, so library consumers aren't forced onto a newer std.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include("${CMAKE_CURRENT_SOURCE_DIR}/../sanitizer.cmake")

# Thread the sanitizer into every Nim dylib built below. `CACHE ... FORCE` is
# required (see the note in nim_ffi_lib.cmake).
set(NIM_FFI_EXTRA_ARGS ${NIM_SAN_ARGS}
    CACHE STRING "Extra nim c args when building the dylib" FORCE)

# Directory scope, not per target: gtest, tinycbor and the bindings' own example
# clients all link against the instrumented dylib and need the same flags.
if(SAN_CFLAGS)
    add_compile_options(${SAN_CFLAGS})
    add_link_options(${SAN_CFLAGS})
endif()

# ── Reuse the timer + echo cpp_bindings (exposing my_timer_headers / echo_headers) ──
get_filename_component(_timer_cpp_bindings_dir
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/timer/cpp_bindings"
    ABSOLUTE)
add_subdirectory("${_timer_cpp_bindings_dir}" timer_cpp_bindings_build)

get_filename_component(_echo_cpp_bindings_dir
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/echo/cpp_bindings"
    ABSOLUTE)
add_subdirectory("${_echo_cpp_bindings_dir}" echo_cpp_bindings_build)

# ── GoogleTest via FetchContent ───────────────────────────────────────────────
include(FetchContent)
FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.14.0
    GIT_SHALLOW    TRUE
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

enable_testing()

add_executable(timer_e2e_tests test_timer_e2e.cpp)
target_link_libraries(timer_e2e_tests PRIVATE my_timer_headers echo_headers GTest::gtest_main)
add_dependencies(timer_e2e_tests my_timer_nim_lib echo_nim_lib)

# Nim-built dylibs use `@rpath/lib*.dylib` install_names on macOS and Linux, so embed
# each IMPORTED target's build-tree dir as an rpath. Windows has no rpath —
# stage the DLLs next to the exe in the POST_BUILD branch below instead.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Windows")
    get_target_property(_my_timer_loc my_timer IMPORTED_LOCATION)
    get_filename_component(_my_timer_dir "${_my_timer_loc}" DIRECTORY)
    get_target_property(_echo_loc echo IMPORTED_LOCATION)
    get_filename_component(_echo_dir "${_echo_loc}" DIRECTORY)
    set_target_properties(timer_e2e_tests PROPERTIES
        BUILD_RPATH   "${_my_timer_dir};${_echo_dir}"
        INSTALL_RPATH "${_my_timer_dir};${_echo_dir}")
else()
    add_custom_command(TARGET timer_e2e_tests POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${my_timer_RUNTIME_LIB}"
            "$<TARGET_FILE_DIR:timer_e2e_tests>"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${echo_RUNTIME_LIB}"
            "$<TARGET_FILE_DIR:timer_e2e_tests>"
        COMMENT "Staging my_timer.dll + echo.dll next to timer_e2e_tests.exe")
endif()

# Discover at test time, not build time: a POST_BUILD discovery run launches the
# freshly-linked exe while Windows Defender is still scanning it (and its staged
# DLLs), which routinely overran the default 5s timeout on CI. PRE_TEST defers
# enumeration to `ctest`, and the bumped timeout absorbs first-launch scan delays.
include(GoogleTest)
if(_san_test_env)
    gtest_discover_tests(timer_e2e_tests
        DISCOVERY_MODE PRE_TEST
        DISCOVERY_TIMEOUT 120
        PROPERTIES ENVIRONMENT "${_san_test_env}")
else()
    gtest_discover_tests(timer_e2e_tests
        DISCOVERY_MODE PRE_TEST
        DISCOVERY_TIMEOUT 120)
endif()
