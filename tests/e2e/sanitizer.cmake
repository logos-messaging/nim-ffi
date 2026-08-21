# Sanitizer wiring for the e2e suites, selected by NIM_FFI_SANITIZER.
# Sets three variables in the including scope:
#
#   NIM_SAN_ARGS   extra `nim c` arguments — push them into the bindings subdir
#                  through `set(NIM_FFI_EXTRA_ARGS ... CACHE STRING "" FORCE)`
#                  so the Nim dylib itself is instrumented.
#   SAN_CFLAGS     compile + link flags for the C/C++ side of the test.
#   _san_test_env  runtime options, for the ENVIRONMENT property of each test.
#
# The first two are both required: instrumenting only the consumer leaves every
# allocation and every thread inside the dylib invisible to the sanitizer.

get_filename_component(_repo_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)

set(NIM_SAN_ARGS "")
set(SAN_CFLAGS "")
set(_san_test_env "")

if("${NIM_FFI_SANITIZER}" STREQUAL "asan-ubsan")
    # -d:useMalloc routes Nim's allocator through malloc so ASan sees the
    # heap traffic the dylib generates.
    # -fno-sanitize-recover matches ffi.nimble's sanFlags: a UBSan report aborts
    # instead of printing and continuing, whatever the env says.
    set(NIM_SAN_ARGS -d:useMalloc
        "--passC:-fsanitize=address,undefined"
        "--passC:-fno-sanitize-recover=all"
        "--passC:-fno-omit-frame-pointer"
        "--passC:-g"
        "--passL:-fsanitize=address,undefined")
    set(SAN_CFLAGS -fsanitize=address,undefined -fno-sanitize-recover=all
        -fno-omit-frame-pointer -g)
    # Halt and exit non-zero on any report so ctest fails the job. The matching
    # env block in tests-sanitized.yml keeps the unit runs in agreement; set here
    # too so a local `ctest` behaves the same. LSan runs inside ASan under
    # detect_leaks=1 and still honours LSAN_OPTIONS for its suppressions.
    list(APPEND _san_test_env
        "ASAN_OPTIONS=halt_on_error=1:abort_on_error=1:detect_leaks=1:strict_string_checks=1"
        "UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"
        "LSAN_OPTIONS=suppressions=${_repo_root}/lsan.supp:print_suppressions=0")
elseif("${NIM_FFI_SANITIZER}" STREQUAL "tsan")
    set(NIM_SAN_ARGS "--passC:-fsanitize=thread"
        "--passC:-fno-omit-frame-pointer"
        "--passC:-g"
        "--passL:-fsanitize=thread")
    set(SAN_CFLAGS -fsanitize=thread -fno-omit-frame-pointer -g)
    list(APPEND _san_test_env
        "TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1:history_size=7:suppressions=${_repo_root}/tsan.supp")
elseif(NOT "${NIM_FFI_SANITIZER}" STREQUAL "" AND NOT "${NIM_FFI_SANITIZER}" STREQUAL "none")
    message(FATAL_ERROR "unknown NIM_FFI_SANITIZER: ${NIM_FFI_SANITIZER}")
endif()
