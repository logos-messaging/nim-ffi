## Per-context registry of live `{.ffiHandle.}` objects. The object stays here,
## in `FFIContext.handles`; only its `uint64` id crosses the boundary. Ids are
## monotonic and never recycled (0 = null), so a stale/forged id misses cleanly.
## FFI-thread-only access, so no locking.

import std/tables

type
  FFIHandleRoot* = ref object of RootObj
    ## Base every `{.ffiHandle.}` type inherits from, so handle refs are storable
    ## under one static type.

  FFIHandleEntry = object
    obj: FFIHandleRoot
    typeName: string

  FFIHandleRegistry* = object
    nextId*: uint64
    byHandle*: Table[uint64, FFIHandleEntry]

proc initHandleRegistry*(reg: var FFIHandleRegistry) =
  reg.nextId = 0'u64
  reg.byHandle = initTable[uint64, FFIHandleEntry]()

proc deinitHandleRegistry*(reg: var FFIHandleRegistry) =
  reg.byHandle = default(Table[uint64, FFIHandleEntry])
  reg.nextId = 0'u64

proc register*(
    reg: var FFIHandleRegistry, obj: FFIHandleRoot, typeName: string
): uint64 =
  ## Stores `obj`, returns its fresh handle id (>0).
  reg.nextId.inc()
  reg.byHandle[reg.nextId] = FFIHandleEntry(obj: obj, typeName: typeName)
  reg.nextId

proc lookup*(
    reg: var FFIHandleRegistry, handle: uint64, typeName: string
): FFIHandleRoot =
  ## Live ref for `handle`, or nil if absent or registered under another type.
  let entry = reg.byHandle.getOrDefault(handle)
  if entry.obj.isNil() or entry.typeName != typeName:
    return nil
  entry.obj

proc release*(reg: var FFIHandleRegistry, handle: uint64): bool {.discardable.} =
  ## Drops the entry; true iff it existed.
  if not reg.byHandle.hasKey(handle):
    return false
  reg.byHandle.del(handle)
  true

proc releaseAll*(reg: var FFIHandleRegistry) =
  ## Drops every entry. Must run on the FFI thread that allocated the refs.
  reg.byHandle.clear()
