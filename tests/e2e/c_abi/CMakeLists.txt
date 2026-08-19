cmake_minimum_required(VERSION 3.14)
project(echo_c_abi_e2e C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

include("${CMAKE_CURRENT_SOURCE_DIR}/../sanitizer.cmake")

# Force the shared echo example source into its `abi = c` variant and thread the
# sanitizer args through to the dylib build. Must be `CACHE ... FORCE`: the
# bindings subdir declares `NIM_FFI_EXTRA_ARGS` as a `CACHE` variable, and under
# CMP0126 OLD (our `cmake_minimum_required(VERSION 3.14)`) that `set(... CACHE)`
# deletes any same-named normal variable from this scope — so a plain `set` here
# would be wiped and the dylib would build with the default CBOR ABI, mismatching
# the flat `abi = c` header. Forcing the cache entry makes the child's non-FORCE
# cache set a no-op instead.
set(NIM_FFI_EXTRA_ARGS "-d:ffiEchoAbiC" ${NIM_SAN_ARGS}
    CACHE STRING "Extra nim c args when building the dylib" FORCE)
if(SAN_CFLAGS)
    add_compile_options(${SAN_CFLAGS})
    add_link_options(${SAN_CFLAGS})
endif()

set(ECHO_BINDINGS "${CMAKE_CURRENT_SOURCE_DIR}/../../../examples/echo/c_abi_bindings")
add_subdirectory("${ECHO_BINDINGS}" echo_c_abi_build)

enable_testing()
add_executable(test_echo_c_abi test_echo_c_abi.c)
target_link_libraries(test_echo_c_abi PRIVATE echo_headers)
add_dependencies(test_echo_c_abi echo_nim_lib)

# Nim-built dylibs use `@rpath/lib*.so|dylib`; embed the imported lib's dir so
# the test runs without LD_LIBRARY_PATH.
get_target_property(_echo_loc echo IMPORTED_LOCATION)
get_filename_component(_echo_dir "${_echo_loc}" DIRECTORY)
set_target_properties(test_echo_c_abi PROPERTIES
    BUILD_RPATH   "${_echo_dir}"
    INSTALL_RPATH "${_echo_dir}")

add_test(NAME echo_c_abi_e2e COMMAND test_echo_c_abi)
if(_san_test_env)
    set_tests_properties(echo_c_abi_e2e PROPERTIES ENVIRONMENT "${_san_test_env}")
endif()
