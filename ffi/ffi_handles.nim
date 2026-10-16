## Per-context registry of live `{.ffiHandle.}` objects; only the `uint64` id crosses the
## boundary. Ids are monotonic, never recycled (0 = null). FFI-thread-only, so no locking.

import std/tables
import results
import ./cbor_serial

type
  FFIHandleRoot* = ref object of RootObj ## Base of every `{.ffiHandle.}` type.

  FFIHandleEntry = object
    obj: FFIHandleRoot
    typeName: string

  FFIHandleRegistry* = object
    nextId*: uint64
    byHandle*: Table[uint64, FFIHandleEntry]

proc initHandleRegistry*(reg: var FFIHandleRegistry) =
  ## The table is left unallocated on purpose: `register` runs on the FFI thread,
  ## and under refc a table allocated on the creating thread would be freed from
  ## the FFI thread, or outlive the heap of a host thread that has since exited.
  reg.nextId = 0'u64

proc deinitHandleRegistry*(reg: var FFIHandleRegistry) =
  ## Runs on the thread that destroys the context, once the FFI thread has been
  ## joined: `releaseAll` left the table empty, so this drops no reference that
  ## belongs to that thread's heap.
  reg.byHandle = default(Table[uint64, FFIHandleEntry])
  reg.nextId = 0'u64

proc register*(
    reg: var FFIHandleRegistry, obj: FFIHandleRoot, typeName: string
): uint64 =
  reg.nextId.inc()
  reg.byHandle[reg.nextId] = FFIHandleEntry(obj: obj, typeName: typeName)
  reg.nextId

proc lookup*(
    reg: var FFIHandleRegistry, handle: uint64, typeName: string
): Result[FFIHandleRoot, string] =
  ## Live ref for `handle`; err if absent or registered under another type.
  let entry = reg.byHandle.getOrDefault(handle)
  if entry.obj.isNil():
    return err("no ffiHandle with id " & $handle)
  if entry.typeName != typeName:
    return err(
      "ffiHandle " & $handle & " has type '" & entry.typeName & "', expected '" &
        typeName & "'"
    )
  ok(entry.obj)

proc release*(
    reg: var FFIHandleRegistry, handle: uint64, typeName: string
): bool {.discardable.} =
  ## Drops `handle`; false if absent or registered under another type. Same tag
  ## check as `lookup`, so a release cannot cross types either.
  let entry = reg.byHandle.getOrDefault(handle)
  if entry.obj.isNil() or entry.typeName != typeName:
    return false
  reg.byHandle.del(handle)
  return true

proc releaseAll*(reg: var FFIHandleRegistry) =
  ## Must run on the FFI thread that allocated the refs, and drops the table with
  ## them: under refc its storage belongs to that thread, so no other thread may
  ## be left holding the last reference to it.
  reg.byHandle = default(Table[uint64, FFIHandleEntry])

proc encodeHandle*(id: uint64): seq[byte] =
  ## Single ABI seam for the handle-id wire format.
  cborEncode(id)
