cmake_minimum_required(VERSION 3.14)
project(nim_ffi_c_e2e C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ── Reuse the timer c_bindings (exposes my_timer_headers / my_timer_nim_lib) ──
get_filename_component(_timer_c_bindings_dir
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/timer/c_bindings"
    ABSOLUTE)
add_subdirectory("${_timer_c_bindings_dir}" timer_c_bindings_build)

enable_testing()

add_executable(timer_e2e_c test_timer_e2e.c)
target_link_libraries(timer_e2e_c PRIVATE my_timer_headers)
add_dependencies(timer_e2e_c my_timer_nim_lib)

if(NIM_FFI_SAN_CFLAGS)
    target_compile_options(timer_e2e_c PRIVATE ${NIM_FFI_SAN_CFLAGS})
    target_link_options(timer_e2e_c PRIVATE ${NIM_FFI_SAN_LFLAGS})
endif()

# Nim-built dylibs use `@rpath/lib*.so|dylib`, so embed the IMPORTED target's
# build-tree dir as an rpath. Windows has no rpath — stage the DLL next to the
# exe instead.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Windows")
    get_target_property(_my_timer_loc my_timer IMPORTED_LOCATION)
    get_filename_component(_my_timer_dir "${_my_timer_loc}" DIRECTORY)
    set_target_properties(timer_e2e_c PROPERTIES
        BUILD_RPATH   "${_my_timer_dir}"
        INSTALL_RPATH "${_my_timer_dir}")
else()
    add_custom_command(TARGET timer_e2e_c POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${my_timer_RUNTIME_LIB}"
            "$<TARGET_FILE_DIR:timer_e2e_c>"
        COMMENT "Staging my_timer.dll next to timer_e2e_c.exe")
endif()

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

add_test(NAME timer_e2e_c COMMAND timer_e2e_c)
if(_san_test_env)
    set_tests_properties(timer_e2e_c PROPERTIES ENVIRONMENT "${_san_test_env}")
endif()
