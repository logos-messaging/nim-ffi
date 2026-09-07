# Body of one sanitizer_symbol_check test (see sanitizer.cmake), run as
# `cmake -DSAN_CHECK_… -P`. Fails when SAN_CHECK_FILE holds no SAN_CHECK_SYMBOL.

if(NOT EXISTS "${SAN_CHECK_FILE}")
    message(FATAL_ERROR "sanitizer symbol check: no such file: ${SAN_CHECK_FILE}")
endif()

# Two passes: the sanitizer runtime is linked statically into an executable
# (defined symbols, plain `nm`) and left undefined in a shared library
# (dynamic symbols, `nm -D`).
set(_syms "")
if(SAN_CHECK_NM)
    execute_process(COMMAND "${SAN_CHECK_NM}" "${SAN_CHECK_FILE}"
        OUTPUT_VARIABLE _plain ERROR_QUIET)
    execute_process(COMMAND "${SAN_CHECK_NM}" -D "${SAN_CHECK_FILE}"
        OUTPUT_VARIABLE _dynamic ERROR_QUIET)
    set(_syms "${_plain}${_dynamic}")
endif()
if("${_syms}" STREQUAL "" AND SAN_CHECK_OBJDUMP)
    execute_process(COMMAND "${SAN_CHECK_OBJDUMP}" -T "${SAN_CHECK_FILE}"
        OUTPUT_VARIABLE _syms ERROR_QUIET)
endif()

string(FIND "${_syms}" "${SAN_CHECK_SYMBOL}" _found)
if(_found EQUAL -1)
    message(FATAL_ERROR
        "SANITIZER_NOT_LINKED: ${SAN_CHECK_FILE} references no "
        "${SAN_CHECK_SYMBOL}* symbol: it was built without the sanitizer")
endif()
