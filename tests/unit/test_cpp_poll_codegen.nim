## The C++ client generated for a `-d:ffiPollMode` library compiles and works:
## typed calls and typed events over nim_ffi::Host, against a scripted fake
## library (tests/host/test_poll_cpp_client_main.cpp), with no Nim library built.

import std/[os, osproc, strutils]
import unittest2
import ffi/codegen/[meta, cpp]

const
  repoDir = currentSourcePath().parentDir().parentDir().parentDir()
  hostDir = repoDir / "host"
  vendorDir = repoDir / "ffi" / "codegen" / "templates" / "cpp" / "vendor"
  mainSource = repoDir / "tests" / "host" / "test_poll_cpp_client_main.cpp"

proc field(n, t: string): FFIFieldMeta =
  FFIFieldMeta(name: n, typeName: t)

proc param(n, t: string): FFIParamMeta =
  FFIParamMeta(name: n, typeName: t)

let
  procs = @[
    FFIProcMeta(
      procName: "pollfake_create",
      libName: "pollfake",
      kind: FFIKind.CTOR,
      libTypeName: "Fake",
      extraParams: @[param("name", "string")],
      returnTypeName: "Fake",
    ),
    FFIProcMeta(
      procName: "pollfake_echo",
      libName: "pollfake",
      kind: FFIKind.FFI,
      libTypeName: "Fake",
      extraParams: @[param("msg", "string")],
      returnTypeName: "string",
    ),
    FFIProcMeta(
      procName: "pollfake_ping",
      libName: "pollfake",
      kind: FFIKind.STATIC,
      libTypeName: "Fake",
      extraParams: @[],
      returnTypeName: "string",
    ),
    FFIProcMeta(
      procName: "pollfake_destroy",
      libName: "pollfake",
      kind: FFIKind.DTOR,
      libTypeName: "Fake",
      extraParams: @[],
      returnTypeName: "",
    ),
  ]
  types = @[
    FFITypeMeta(name: "TickPayload", fields: @[field("n", "int")]),
    # What a poll-mode `{.ffiReverse.}` registers: the named map its arguments ride in.
    FFITypeMeta(name: "FetchHostHostCall", fields: @[field("url", "string")]),
  ]
  reverseCalls = @[
    FFIReverseMeta(
      wireName: "fetch_host",
      nimProcName: "fetchHost",
      libName: "pollfake",
      params: @[param("url", "string")],
      argsTypeName: "FetchHostHostCall",
      replyTypeName: "string",
    ),
    FFIReverseMeta(
      wireName: "host_tick",
      nimProcName: "hostTick",
      libName: "pollfake",
      argsTypeName: "",
      replyTypeName: "string",
    ),
    FFIReverseMeta(
      wireName: "host_notify",
      nimProcName: "hostNotify",
      libName: "pollfake",
      params: @[param("url", "string")],
      argsTypeName: "FetchHostHostCall",
      replyTypeName: "",
    ),
  ]
  events = @[
    FFIEventMeta(
      wireName: "on_tick",
      nimProcName: "onTick",
      libName: "pollfake",
      payloadTypeName: "TickPayload",
    )
  ]

suite "generateCppHeader: the poll mode":
  let header =
    generateCppHeader(procs, types, "pollfake", events = events, reverse = reverseCalls)

  test "the exports have the poll shape and no callback machinery":
    check "int pollfake_echo(void* ctx, const uint8_t* req_cbor, size_t req_cbor_len, uint64_t* req_id_out);" in
      header
    check "int pollfake_poll(void* ctx, int32_t timeout_ms, const PollResult** msg);" in
      header
    check "FFICallback" notin header
    check "pollfake_add_event_listener" notin header

  test "the client is built on nim_ffi::Host":
    check "#include \"nim_ffi_host.hpp\"" in header
    check "nim_ffi::Host" in header
    check "Result<std::string> echo(" in header
    check "addOnTickListener" in header

  test "each reverse call gets a typed handler and the Responder is emitted once":
    check "void onFetchHost(std::function<void(const FetchHostHostCall&, Responder<std::string>)> handler)" in
      header
    check "void onHostTick(std::function<void(Responder<std::string>)> handler)" in
      header
    check "void onHostNotify(std::function<void(const FetchHostHostCall&, Responder<void>)> handler)" in
      header
    check header.count("class Responder<void>") == 1
    check header.count("class ReverseAnswer") == 1

  test "a library without reverse calls has no Responder":
    let plain = generateCppHeader(procs, types, "pollfake", events = events)
    check "Responder" notin plain
    check "dispatchReverse_" notin plain

  test "a static proc is a static method on the host attached to the static ctx":
    check "static Result<std::string> ping(" in header
    check "pollfake_static_ctx" in header

  test "the generated client compiles and runs against a fake library":
    when defined(windows):
      skip() # builds with a POSIX cc/c++; the C++ E2E jobs cover Windows
    else:
      let cc = getEnv("CC", "cc")
      let cxx = getEnv("CXX", "c++")
      let dir = getTempDir() / ("nim_ffi_poll_cpp_" & $getCurrentProcessId())
      createDir(dir)
      defer:
        removeDir(dir)
      writeFile(dir / "pollfake.hpp", header)
      copyFile(hostDir / "nim_ffi_host.hpp", dir / "nim_ffi_host.hpp")
      copyFile(hostDir / "nim_ffi.h", dir / "nim_ffi.h")
      var objects: seq[string] = @[]
      # Every vendored tinycbor source, so a file added there needs no change here.
      for path in walkFiles(vendorDir / "tinycbor" / "*.c"):
        let obj = dir / (extractFilename(path) & ".o")
        let (cOut, cCode) = execCmdEx(
          cc & " -c -I" & quoteShell(vendorDir) & " -o " & quoteShell(obj) & " " &
            quoteShell(path)
        )
        check cCode == 0
        if cCode != 0:
          echo cOut
        objects.add(quoteShell(obj))
      let exe = dir / "client_test"
      let build =
        cxx & " -std=c++20 -Wall -Wextra -pthread -I" & quoteShell(dir) & " -I" &
        quoteShell(vendorDir) & " -o " & quoteShell(exe) & " " & quoteShell(mainSource) &
        " " & objects.join(" ")
      # Sanitizers where the toolchain has them; the test still runs without.
      var (output, code) = execCmdEx(
        build.replace(" -pthread ", " -pthread -fsanitize=address,undefined ")
      )
      if code != 0:
        (output, code) = execCmdEx(build)
      check code == 0
      if code != 0:
        echo output
      else:
        let (runOutput, runCode) = execCmdEx(quoteShell(exe))
        check runCode == 0
        check runOutput.contains("ok")
        if runCode != 0:
          echo runOutput
