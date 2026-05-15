## Thin wrapper around `cbor_serialization` (vacp2p/nim-cbor-serialization) that
## adapts the library's exception-based API to the `Result[T, string]` shape the
## FFI plumbing expects, and adds the few transport-only details the FFI layer
## needs on top:
##
##   - `pointer` / `ptr T` are encoded as CBOR unsigned int holding the raw
##     address (in-process transport only — see notes in plan).
##   - `cborEncodeShared` writes into an `allocShared` buffer so the FFI thread
##     can take ownership of the bytes without a second copy.
##   - `CborNullByte` is the canonical "successful but no value" wire sentinel.
##
## `cborEncode` / `cborDecode` are the public API the macros and tests use.

import std/macros
import cbor_serialization, cbor_serialization/std/options, results
import ./codegen/meta

export cbor_serialization, options, results

const CborNullByte*: byte = 0xf6'u8
  ## CBOR encoding of `null` — used as the wire sentinel for empty OK payloads.

# ---------------------------------------------------------------------------
# Custom write/read for raw `pointer` and `ptr T`.
#
# The library's default `ref T` writer dereferences and encodes the pointee;
# we want the opposite for FFI transport — encode the address as a uint64 so
# the foreign side can round-trip it as an opaque handle.
# ---------------------------------------------------------------------------

proc write*(w: var CborWriter, val: pointer) {.raises: [IOError].} =
  w.write(cast[uint64](val))

proc read*(
    r: var CborReader, val: var pointer
) {.raises: [IOError, SerializationError].} =
  val = cast[pointer](r.readValue(uint64))

proc write*[PtrT](w: var CborWriter, val: ptr PtrT) {.raises: [IOError].} =
  w.write(cast[uint64](val))

proc read*[PtrT](
    r: var CborReader, val: var ptr PtrT
) {.raises: [IOError, SerializationError].} =
  val = cast[ptr PtrT](r.readValue(uint64))

Cbor.defaultSerialization(pointer)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc cborEncode*[T](x: T): seq[byte] =
  ## CBOR-encode any cbor_serialization-supported type (plus `pointer` / `ptr T`
  ## via our custom writers) into a fresh `seq[byte]`.
  return Cbor.encode(x)

proc cborEncodeShared*[T](
    x: T
): tuple[data: ptr UncheckedArray[byte], len: int] =
  ## Encodes `x` into a shared-memory buffer (`allocShared`).
  ##
  ## The returned `data` is owned by the caller and must be freed exactly once
  ## via `deallocShared` (the FFIThreadRequest `deleteRequest` path does this
  ## automatically). Empty payloads return `(nil, 0)` without allocating.
  let bytes = Cbor.encode(x)
  if bytes.len == 0:
    return (nil, 0)
  let buf = cast[ptr UncheckedArray[byte]](allocShared(bytes.len))
  copyMem(buf, unsafeAddr bytes[0], bytes.len)
  return (buf, bytes.len)

proc cborDecode*[T](
    data: openArray[byte], _: typedesc[T]
): Result[T, string] =
  ## Decode `data` into a `T`, converting any cbor_serialization exception
  ## into a `Result.err` carrying the exception message.
  try:
    let v = Cbor.decode(data, T)
    return ok(v)
  except CatchableError as exc:
    return err(exc.msg)

proc cborDecodePtr*[T](
    data: ptr UncheckedArray[byte], dataLen: int, _: typedesc[T]
): Result[T, string] =
  ## Convenience for ptr+len buffers (used by the macro to avoid binding an
  ## openArray to a `let`).
  if dataLen <= 0:
    return cborDecode(default(seq[byte]), T)
  cborDecode(toOpenArray(data, 0, dataLen - 1), T)

# ---------------------------------------------------------------------------
# ffiType macro — registers the type in ffiTypeRegistry for binding generation.
# Serialization itself is handled by cbor_serialization's generic machinery.
# ---------------------------------------------------------------------------

macro ffiType*(body: untyped): untyped =
  let typeSection = body[0]
  let typeDef = typeSection[0]
  let typeName =
    if typeDef[0].kind == nnkPostfix:
      typeDef[0][1]
    else:
      typeDef[0]

  let typeNameStr = $typeName
  var fieldMetas: seq[FFIFieldMeta] = @[]
  let objTy = typeDef[2]
  if objTy.kind == nnkObjectTy and objTy.len >= 3:
    let recList = objTy[2]
    if recList.kind == nnkRecList:
      for identDef in recList:
        if identDef.kind == nnkIdentDefs:
          let fieldType = identDef[^2]
          let fieldTypeName =
            if fieldType.kind == nnkIdent: $fieldType
            elif fieldType.kind == nnkPtrTy: "ptr " & $fieldType[0]
            else: fieldType.repr
          for i in 0 ..< identDef.len - 2:
            fieldMetas.add(FFIFieldMeta(name: $identDef[i], typeName: fieldTypeName))

  ffiTypeRegistry.add(FFITypeMeta(name: typeNameStr, fields: fieldMetas))
  return body
