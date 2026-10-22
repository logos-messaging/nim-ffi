## Compile fixture for the generated bindings' type and name handling (see
## tests/unit/test_codegen_types.nim): an `{.ffi.}` object whose fields are
## exported, the shape a library's public API types usually take; fixed-width
## integers narrower than 64 bits; and a proc not named `<lib>_*`, whose C++
## method then has the same name as its raw export.

import ffi, chronos

type TypesLib = object
  calls: int

declareLibrary("typeslib", TypesLib)

type PeerRecord* {.ffi.} = object
  peerId*: string
  addrs*: seq[string]
  seqNo*: uint64

proc typeslib_create*(): Future[Result[TypesLib, string]] {.ffiCtor.} =
  return ok(TypesLib(calls: 0))

proc typeslib_destroy*(lib: TypesLib) {.ffiDtor.} =
  discard

proc typeslib_peer*(
    lib: TypesLib, id: string
): Future[Result[PeerRecord, string]] {.ffi.} =
  return ok(PeerRecord(peerId: id, addrs: @[], seqNo: 1))

type Shard {.ffi.} = object
  clusterId: uint16
  shardId: uint16
  weight: int16
  flags: uint8
  level: int8
  ratio: float32

# Unprefixed, like liblogosdelivery's kernel `waku_*` procs: the C++ method is
# `relay_publish` and so is the raw export it calls.
proc relay_publish*(
    lib: TypesLib, payload: string, timeoutMs: uint32
): Future[Result[Shard, string]] {.ffi.} =
  return ok(Shard(clusterId: 1, shardId: uint16(timeoutMs mod 8)))

genBindings()
