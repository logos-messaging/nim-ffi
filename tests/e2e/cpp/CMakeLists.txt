cmake_minimum_required(VERSION 3.14)
project(nim_ffi_cpp_e2e CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Reuse the timer cpp_bindings (compiles libtimer + exposes timer_headers) ──
get_filename_component(_cpp_bindings_dir
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/timer/cpp_bindings"
    ABSOLUTE)
add_subdirectory("${_cpp_bindings_dir}" cpp_bindings_build)

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
target_link_libraries(timer_e2e_tests PRIVATE timer_headers GTest::gtest_main)
add_dependencies(timer_e2e_tests nim_lib)

include(GoogleTest)
gtest_discover_tests(timer_e2e_tests)
