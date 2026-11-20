## The C++ header: instance calls live on a `<Lib>Calls` view that carries the
## per-call limit and progress callback, and the async path owns no thread.

import std/strutils
import unittest2
import ffi/codegen/[cpp, meta]

suite "C++ calls view":
  setup:
    let procs = @[
      FFIProcMeta(
        procName: "timer_create",
        libName: "timer",
        kind: FFIKind.CTOR,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "Timer",
      ),
      FFIProcMeta(
        procName: "timer_echo",
        libName: "timer",
        kind: FFIKind.FFI,
        libTypeName: "Timer",
        extraParams: @[FFIParamMeta(name: "req", typeName: "string")],
        returnTypeName: "string",
      ),
      FFIProcMeta(
        procName: "timer_lib_version",
        libName: "timer",
        kind: FFIKind.STATIC,
        libTypeName: "Timer",
        extraParams: @[],
        returnTypeName: "string",
      ),
    ]
    let header = generateCppHeader(procs, @[], "timer")

  test "the ctx derives from the view and withTimeout re-limits it":
    check "class TimerCalls {" in header
    check "class TimerCtx : public TimerCalls {" in header
    check "TimerCalls withTimeout(std::optional<std::chrono::milliseconds> limit) const {" in
      header
    check "TimerCalls withProgress(FFIProgress onProgress) const {" in header

  test "an instance call reads the view's limit and progress, sync and async":
    check "}, timeout_, progress_);" in header
    check "return ffi_call_async_<std::string>(" in header
    check "}, timeout_, progress_, [](FFIBytes_&& b)" in header

  test "a static keeps a plain bounded timeout":
    check "static Result<std::string> lib_version(std::chrono::milliseconds timeout = std::chrono::seconds{30})" in
      header
    check "}, timeout, FFIProgress{}, [](FFIBytes_&& b)" in header

  test "the async path is not a thread over the sync call":
    check "return std::async(std::launch::async, [this" notin header
