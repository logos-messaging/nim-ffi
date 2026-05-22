cmake_minimum_required(VERSION 3.14)
project(nim_ffi_cpp_e2e CXX)

# Test harness compiles at C++20 so we can use designated initializers
# (`.field = …`) in test bodies; MSVC rejects them under /std:c++17.
# The generated example bindings and the CMake template they ship with
# stay at C++17, so library consumers aren't forced onto a newer std.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Reuse the timer cpp_bindings (compiles libmy_timer + exposes the
#    my_timer_headers INTERFACE target) ──
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
target_link_libraries(timer_e2e_tests PRIVATE my_timer_headers GTest::gtest_main)
add_dependencies(timer_e2e_tests nim_lib)

if(NIM_FFI_SAN_CFLAGS)
    target_compile_options(timer_e2e_tests PRIVATE ${NIM_FFI_SAN_CFLAGS})
    target_link_options(timer_e2e_tests PRIVATE ${NIM_FFI_SAN_LFLAGS})
endif()

# The Nim-built shared library has install_name `@rpath/libmy_timer.dylib`
# (set by `declareLibrary` on macOS for portability). The test binary must
# therefore know where to find that dylib at load time — embed the build-tree
# directory of the IMPORTED `my_timer` target as an rpath.
get_target_property(_my_timer_loc my_timer IMPORTED_LOCATION)
get_filename_component(_my_timer_dir "${_my_timer_loc}" DIRECTORY)
set_target_properties(timer_e2e_tests PROPERTIES
    BUILD_RPATH   "${_my_timer_dir}"
    INSTALL_RPATH "${_my_timer_dir}")

# Per-sanitizer runtime options: halt and exit non-zero on any report so
# ctest fails the job. The matching ASAN_OPTIONS / UBSAN_OPTIONS /
# LSAN_OPTIONS / TSAN_OPTIONS in CI provide the same defaults; we set them
# here too so local `ctest` runs behave identically.
#
# `asan-ubsan` runs LSan as part of ASan (detect_leaks=1). LSAN_OPTIONS
# is still honoured for suppressions when LSan runs under ASan's runtime.
set(_san_test_env "")
if(NIM_FFI_SANITIZER STREQUAL "asan-ubsan")
    list(APPEND _san_test_env
        "ASAN_OPTIONS=halt_on_error=1:abort_on_error=1:detect_leaks=1:strict_string_checks=1"
        "UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"
        "LSAN_OPTIONS=suppressions=${CMAKE_CURRENT_SOURCE_DIR}/lsan.supp:print_suppressions=0")
elseif(NIM_FFI_SANITIZER STREQUAL "tsan")
    list(APPEND _san_test_env
        "TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1:history_size=7")
endif()

include(GoogleTest)
if(_san_test_env)
    gtest_discover_tests(timer_e2e_tests PROPERTIES ENVIRONMENT "${_san_test_env}")
else()
    gtest_discover_tests(timer_e2e_tests)
endif()
