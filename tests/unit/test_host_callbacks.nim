## Unit tests for the host-callback primitives (`FFIHostRegistry` /
## `FFIPendingTable`) that back `{.ffiHost.}` — roadmap item #1, increment 1
## (see docs/design-host-callbacks.md).
##
## These exercise the data structures directly: no FFI thread, no macro, no
## completion bridge. They pin down registration, lookup, token allocation, and
## future completion semantics in isolation.

import std/locks
import unittest2
import chronos
import ffi

# A host fn does nothing here — we only assert it round-trips through the
# registry. `userData` carries a tag we read back to prove identity.
proc noopHostFn(
    token: uint64, req: ptr cchar, reqLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

proc bytesToStr(b: seq[byte]): string =
  var s = newString(b.len)
  if b.len > 0:
    copyMem(addr s[0], unsafeAddr b[0], b.len)
  return s

suite "FFIHostRegistry":
  test "register, lookup, replace, and remove":
    var reg: FFIHostRegistry
    initHostRegistry(reg)
    defer:
      deinitHostRegistry(reg)

    var tag = 42
    check registerHostFn(reg, "fetch_profile", noopHostFn, addr tag)

    let hit = lookupHostFn(reg, "fetch_profile")
    check hit.found
    check hit.userData == addr tag
    check not hit.fn.isNil()

    # missing name -> found == false (never a crash)
    check not lookupHostFn(reg, "does_not_exist").found

    # nil fn unregisters and reports false
    check not registerHostFn(reg, "fetch_profile", nil, nil)
    check not lookupHostFn(reg, "fetch_profile").found

  test "clear drops every registration":
    var reg: FFIHostRegistry
    initHostRegistry(reg)
    defer:
      deinitHostRegistry(reg)
    check registerHostFn(reg, "a", noopHostFn, nil)
    check registerHostFn(reg, "b", noopHostFn, nil)
    clearHostFns(reg)
    check not lookupHostFn(reg, "a").found
    check not lookupHostFn(reg, "b").found

suite "FFIPendingTable":
  test "tokens are monotonic and start at 1":
    var tbl: FFIPendingTable
    initPendingTable(tbl)
    defer:
      deinitPendingTable(tbl)
    let a = newPending(tbl)
    let b = newPending(tbl)
    check a.token == 1'u64
    check b.token == 2'u64
    check tbl.pendingCount == 2

  test "completePending resolves the awaiting future and removes it":
    var tbl: FFIPendingTable
    initPendingTable(tbl)
    defer:
      deinitPendingTable(tbl)
    let p = newPending(tbl)
    check completePending(tbl, p.token, okResult(@[byte 1, 2, 3]))
    check p.fut.finished()
    check waitFor(p.fut).ret == RET_OK
    check waitFor(p.fut).bytes == @[byte 1, 2, 3]
    check tbl.pendingCount == 0

  test "unknown or double completion is dropped, not fatal":
    var tbl: FFIPendingTable
    initPendingTable(tbl)
    defer:
      deinitPendingTable(tbl)
    check not completePending(tbl, 999'u64, okResult(@[]))
    let p = newPending(tbl)
    check completePending(tbl, p.token, okResult(@[]))
    check not completePending(tbl, p.token, okResult(@[])) # second time: dropped

  test "failAllPending errors every outstanding future":
    var tbl: FFIPendingTable
    initPendingTable(tbl)
    defer:
      deinitPendingTable(tbl)
    let p1 = newPending(tbl)
    let p2 = newPending(tbl)
    failAllPending(tbl, "context shutting down")
    check p1.fut.finished()
    check p2.fut.finished()
    let r = waitFor(p1.fut)
    check r.ret == RET_ERR
    check bytesToStr(r.bytes) == "context shutting down"
    check tbl.pendingCount == 0
