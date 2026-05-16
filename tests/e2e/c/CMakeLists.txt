cmake_minimum_required(VERSION 3.14)
project(nim_ffi_c_e2e C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ── Reuse the timer c_bindings dir, which builds libmy_timer (with the C
#    target) and exposes the my_timer_headers INTERFACE target. ──────────
get_filename_component(_c_bindings_dir
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/timer/c_bindings"
    ABSOLUTE)
add_subdirectory("${_c_bindings_dir}" c_bindings_build)

# ── Echoer second library (drives the cross-library scenario) ─────────────
get_filename_component(_echoer_bindings_dir
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/echoer/c_bindings"
    ABSOLUTE)
add_subdirectory("${_echoer_bindings_dir}" echoer_bindings_build)

enable_testing()

# ── Single-library smoke ──────────────────────────────────────────────────
add_executable(timer_c_smoke "${_c_bindings_dir}/main.c")
target_link_libraries(timer_c_smoke PRIVATE my_timer_headers)
add_dependencies(timer_c_smoke my_timer_nim_lib)

# Embed the build-tree dir of libmy_timer.dylib as rpath so the loader can
# find it at run time (same trick the cpp e2e uses).
get_target_property(_my_timer_loc my_timer IMPORTED_LOCATION)
get_filename_component(_my_timer_dir "${_my_timer_loc}" DIRECTORY)
set_target_properties(timer_c_smoke PROPERTIES
    BUILD_RPATH   "${_my_timer_dir}"
    INSTALL_RPATH "${_my_timer_dir}")

add_test(NAME timer_c_smoke COMMAND timer_c_smoke)
set_tests_properties(timer_c_smoke PROPERTIES TIMEOUT 30)

# ── Cross-library test: libmy_timer + libechoer co-resident, talking
#    through pure-C structs only ───────────────────────────────────────────
add_executable(cross_lib_e2e
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/cross_lib/main.c")
target_link_libraries(cross_lib_e2e PRIVATE my_timer_headers echoer_headers)
add_dependencies(cross_lib_e2e my_timer_nim_lib echoer_nim_lib)

get_target_property(_echoer_loc echoer IMPORTED_LOCATION)
get_filename_component(_echoer_dir "${_echoer_loc}" DIRECTORY)
set_target_properties(cross_lib_e2e PROPERTIES
    BUILD_RPATH   "${_my_timer_dir};${_echoer_dir}"
    INSTALL_RPATH "${_my_timer_dir};${_echoer_dir}")

add_test(NAME cross_lib_e2e COMMAND cross_lib_e2e)
set_tests_properties(cross_lib_e2e PROPERTIES TIMEOUT 30)
