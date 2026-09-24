## `cbor_serialization` wrapper adapting its exception API to `Result[T, string]` for the FFI layer.
## `.ffi.` payloads (plain `object` and `ref T`) cross as value copies; raw `pointer`/`ptr T` are
## rejected at macro-expansion time (see `rejectRawPtrType`).

import system/ansi_c
import cbor_serialization, cbor_serialization/std/options, results

when defined(ffiDeterministicCbor):
  ## LOGOS-MODULE-INTERFACE 4.4 requires every payload at a module boundary to
  ## be deterministic CBOR, and `cbor_serialization` is not: it orders map keys
  ## by declaration. Rather than fork a shared library's writer, outgoing bytes
  ## are canonicalised here and incoming bytes are rejected per 4.5.
  import ./dcbor as ldcbor

export cbor_serialization, options, results

const CborNullByte*: byte = 0xf6'u8
  ## CBOR `null` — wire sentinel for empty OK payloads.

proc cborEncode*[T](x: T): seq[byte] =
  when defined(ffiDeterministicCbor):
    return ldcbor.canonicalise(Cbor.encode(x))
  else:
    return Cbor.encode(x)

proc cborEncodeShared*[T](x: T): tuple[data: ptr UncheckedArray[byte], len: int] =
  ## Encodes `x` into a caller-owned `c_malloc` buffer, freed by `deleteRequest`.
  ## Empty payloads return `(nil, 0)` without allocating, and so does a failed
  ## allocation: the receiver reads an empty payload and answers a decode error.
  let bytes =
    when defined(ffiDeterministicCbor):
      ldcbor.canonicalise(Cbor.encode(x))
    else:
      Cbor.encode(x)
  if bytes.len == 0:
    return (nil, 0)
  let buf = cast[ptr UncheckedArray[byte]](c_malloc(csize_t(bytes.len)))
  if buf.isNil():
    return (nil, 0)
  copyMem(buf, unsafeAddr bytes[0], bytes.len)
  return (buf, bytes.len)

proc cborDecode*[T](data: openArray[byte], _: typedesc[T]): Result[T, string] =
  ## Decode `data` into a `T`, mapping any exception to `Result.err`.
  try:
    when defined(ffiDeterministicCbor):
      # 4.5: bytes that break the profile are refused, not repaired. The caller
      # turns this into INVALID_PARAMS.
      if not ldcbor.validate(@data):
        return err("payload is not Logos deterministic CBOR")
    let v = Cbor.decode(data, T)
    return ok(v)
  except CatchableError as exc:
    return err(exc.msg)

proc cborDecodePtr*[T](
    data: ptr UncheckedArray[byte], dataLen: int, _: typedesc[T]
): Result[T, string] =
  ## Convenience for ptr+len buffers.
  if dataLen <= 0:
    return cborDecode(default(seq[byte]), T)
  cborDecode(toOpenArray(data, 0, dataLen - 1), T)
