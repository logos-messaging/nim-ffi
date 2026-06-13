## Unit tests for the `{.ffiHost.}` macro (roadmap #1, increment 3) — the
## generated proc that dispatches to a host-registered function and awaits the
## answer over the raw (zero-serialization) ABI.
##
## These drive the generated proc directly with a synchronous "host": the
## registered fn completes the pending future inline (its userData carries the
## pending table), so the await resolves without the full FFI thread. The
## cross-thread bridge is covered separately by the FFIContext wiring.

import std/strutils
import unittest2
import chronos
import ffi

# A {.ffiHost.} declaration: the host implements `echoHost`, Nim awaits it.
proc echoHost(s: string): Future[Result[string, string]] {.ffiHost.}

# Synchronous host impls. `userData` carries the pending table so the fn can
# resolve the token inline (a real host answers later via <lib>_host_complete).
proc echoFn(
    token: uint64, req: ptr cchar, reqLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let tbl = cast[ptr FFIPendingTable](userData)
  var b = newSeq[byte](int(reqLen))
  if reqLen > 0'u:
    copyMem(addr b[0], req, int(reqLen))
  discard completePending(tbl[], token, okResult(b))

proc failFn(
    token: uint64, req: ptr cchar, reqLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let tbl = cast[ptr FFIPendingTable](userData)
  discard completePending(tbl[], token, errResult("host said no"))

suite "ffiHost macro":
  test "round-trips the value through the registered host fn":
    var reg: FFIHostRegistry
    var tbl: FFIPendingTable
    initHostRegistry(reg)
    initPendingTable(tbl)
    defer:
      deinitHostRegistry(reg)
      deinitPendingTable(tbl)
    ffiCurrentHostRegistry = addr reg
    ffiCurrentPendingTable = addr tbl
    check registerHostFn(reg, "echo_host", echoFn, addr tbl)

    let r = waitFor echoHost("hello host")
    check r.isOk
    check r.get == "hello host"

  test "empty argument is handled":
    var reg: FFIHostRegistry
    var tbl: FFIPendingTable
    initHostRegistry(reg)
    initPendingTable(tbl)
    defer:
      deinitHostRegistry(reg)
      deinitPendingTable(tbl)
    ffiCurrentHostRegistry = addr reg
    ffiCurrentPendingTable = addr tbl
    discard registerHostFn(reg, "echo_host", echoFn, addr tbl)
    let r = waitFor echoHost("")
    check r.isOk
    check r.get == ""

  test "unregistered host fn yields an error":
    var reg: FFIHostRegistry
    var tbl: FFIPendingTable
    initHostRegistry(reg)
    initPendingTable(tbl)
    defer:
      deinitHostRegistry(reg)
      deinitPendingTable(tbl)
    ffiCurrentHostRegistry = addr reg
    ffiCurrentPendingTable = addr tbl
    let r = waitFor echoHost("x")
    check r.isErr
    check "not registered" in r.error

  test "host-reported error propagates as the Result error":
    var reg: FFIHostRegistry
    var tbl: FFIPendingTable
    initHostRegistry(reg)
    initPendingTable(tbl)
    defer:
      deinitHostRegistry(reg)
      deinitPendingTable(tbl)
    ffiCurrentHostRegistry = addr reg
    ffiCurrentPendingTable = addr tbl
    discard registerHostFn(reg, "echo_host", failFn, addr tbl)
    let r = waitFor echoHost("x")
    check r.isErr
    check r.error == "host said no"

  test "no host context on the thread yields an error":
    ffiCurrentHostRegistry = nil
    ffiCurrentPendingTable = nil
    let r = waitFor echoHost("x")
    check r.isErr
    check "no host context" in r.error
