## Thin wrapper around `cbor_serialization` (vacp2p/nim-cbor-serialization) that
## adapts the library's exception-based API to the `Result[T, string]` shape the
## FFI plumbing expects, and adds the few transport-only details the FFI layer
## needs on top:
##
##   - `cborEncodeShared` writes into an `allocShared` buffer so the FFI thread
##     can take ownership of the bytes without a second copy.
##   - `CborNullByte` is the canonical "successful but no value" wire sentinel.
##
## `cborEncode` / `cborDecode` are the public API the macros and tests use.
##
## Type contract for `.ffi.` payloads:
##
##   - Plain `object` types flow as value copies — fields are serialized and
##     the foreign side reconstructs an independent value.
##   - `ref T` is *also* a value copy: `cbor_serialization`'s default `ref T`
##     writer dereferences and encodes the pointee, so the receiving side
##     allocates a fresh `ref` local to its own GC heap. No object identity
##     is preserved across the boundary — the two sides own independent
##     copies after decode.
##   - Raw `pointer` / `ptr T` are rejected at macro-expansion time (see
##     `rejectRawPtrType` in `internal/ffi_macro.nim`). The only address that
##     legitimately crosses the boundary is the opaque ctx handle returned by
##     `.ffiCtor.`, which is validated against `FFIContextPool` on every
##     re-entry. Arbitrary user pointers would lack that validation.

import cbor_serialization, cbor_serialization/std/options, results

export cbor_serialization, options, results

const CborNullByte*: byte = 0xf6'u8
  ## CBOR encoding of `null` — used as the wire sentinel for empty OK payloads.

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

