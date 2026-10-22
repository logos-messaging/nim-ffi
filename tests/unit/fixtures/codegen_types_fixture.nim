## Compile fixture for the generated bindings' type and name handling (see
## tests/unit/test_codegen_types.nim): an `{.ffi.}` object whose fields are
## exported, the shape a library's public API types usually take.

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

proc typeslib_peer*(lib: TypesLib, id: string): Future[Result[PeerRecord, string]] {.ffi.} =
  return ok(PeerRecord(peerId: id, addrs: @[], seqNo: 1))

genBindings()
