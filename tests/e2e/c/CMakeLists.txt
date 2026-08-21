cmake_minimum_required(VERSION 3.14)
project(nim_ffi_c_e2e C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# MSVC gates <stdatomic.h> behind this flag (C11 atomics, VS 2022 17.5+).
if(MSVC)
    add_compile_options(/experimental:c11atomics)
endif()

include("${CMAKE_CURRENT_SOURCE_DIR}/../sanitizer.cmake")

# Thread the sanitizer into every Nim dylib built below. `CACHE ... FORCE` is
# required (see the note in nim_ffi_lib.cmake).
set(NIM_FFI_EXTRA_ARGS ${NIM_SAN_ARGS}
    CACHE STRING "Extra nim c args when building the dylib" FORCE)

# Directory scope, not per target: the bindings subdir adds targets of its own
# (the example client, tinycbor), and linking any of them against the
# instrumented dylib fails unless they carry the same flags.
if(SAN_CFLAGS)
    add_compile_options(${SAN_CFLAGS})
    add_link_options(${SAN_CFLAGS})
endif()

# ── Reuse the timer c_bindings (exposes my_timer_headers / my_timer_nim_lib) ──
get_filename_component(_timer_c_bindings_dir
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/timer/c_bindings"
    ABSOLUTE)
add_subdirectory("${_timer_c_bindings_dir}" timer_c_bindings_build)

# The echo c_bindings are the second generated C header. Compiling them here is
# what keeps `genbindings_c_echo` honest: a diff check alone accepts a header
# that no compiler has ever seen.
get_filename_component(_echo_c_bindings_dir
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/echo/c_bindings"
    ABSOLUTE)
add_subdirectory("${_echo_c_bindings_dir}" echo_c_bindings_build)

enable_testing()

add_executable(timer_e2e_c test_timer_e2e.c)
target_link_libraries(timer_e2e_c PRIVATE my_timer_headers)
add_dependencies(timer_e2e_c my_timer_nim_lib)

add_executable(echo_e2e_c test_echo_e2e.c)
target_link_libraries(echo_e2e_c PRIVATE echo_headers)
add_dependencies(echo_e2e_c echo_nim_lib)

# Nim-built dylibs use `@rpath/lib*.so|dylib`, so embed the IMPORTED target's
# build-tree dir as an rpath. Windows has no rpath — stage the DLL next to the
# exe instead.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Windows")
    get_target_property(_my_timer_loc my_timer IMPORTED_LOCATION)
    get_filename_component(_my_timer_dir "${_my_timer_loc}" DIRECTORY)
    set_target_properties(timer_e2e_c PROPERTIES
        BUILD_RPATH   "${_my_timer_dir}"
        INSTALL_RPATH "${_my_timer_dir}")
    get_target_property(_echo_loc echo IMPORTED_LOCATION)
    get_filename_component(_echo_dir "${_echo_loc}" DIRECTORY)
    set_target_properties(echo_e2e_c PROPERTIES
        BUILD_RPATH   "${_echo_dir}"
        INSTALL_RPATH "${_echo_dir}")
else()
    add_custom_command(TARGET timer_e2e_c POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${my_timer_RUNTIME_LIB}"
            "$<TARGET_FILE_DIR:timer_e2e_c>"
        COMMENT "Staging my_timer.dll next to timer_e2e_c.exe")
    add_custom_command(TARGET echo_e2e_c POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${echo_RUNTIME_LIB}"
            "$<TARGET_FILE_DIR:echo_e2e_c>"
        COMMENT "Staging echo.dll next to echo_e2e_c.exe")
endif()

add_test(NAME timer_e2e_c COMMAND timer_e2e_c)
add_test(NAME echo_e2e_c COMMAND echo_e2e_c)
if(_san_test_env)
    set_tests_properties(timer_e2e_c echo_e2e_c
        PROPERTIES ENVIRONMENT "${_san_test_env}")
endif()
