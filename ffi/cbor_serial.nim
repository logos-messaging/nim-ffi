## Minimal RFC 8949 CBOR codec used as the FFI request/response wire format.
##
## `CborNullByte` is the canonical sentinel for "successful but no value" —
## handlers that produce an empty payload emit a single 0xf6 byte (CBOR null)
## so the FFI callback never receives a nil msg pointer.
##
## Supported types:
##   - bool, signed/unsigned ints (8/16/32/64), int, uint
##   - float32, float64, float
##   - string, cstring (encode-only; decode returns string)
##   - pointer, ptr T (encoded as CBOR unsigned int holding the address;
##     in-process transport only — see notes in plan)
##   - seq[T], array[N, T]
##   - Option[T]
##   - enum (encoded as CBOR unsigned int = ord)
##   - object and tuple (encoded as CBOR map keyed by field-name strings)

import std/[macros, options]
import results
import ./codegen/meta

export results

const CborNullByte*: byte = 0xf6'u8
  ## CBOR encoding of `null` — used as the wire sentinel for empty OK payloads.

# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------

type CborWriter* = object
  buf*: seq[byte]

proc writeHead(w: var CborWriter, major: byte, value: uint64) =
  ## Emit a CBOR initial byte + argument for unsigned integer `value`.
  let mt = byte(major shl 5)
  if value < 24'u64:
    w.buf.add(mt or byte(value))
  elif value < 0x100'u64:
    w.buf.add(mt or 24'u8)
    w.buf.add(byte(value))
  elif value < 0x10000'u64:
    w.buf.add(mt or 25'u8)
    w.buf.add(byte((value shr 8) and 0xff))
    w.buf.add(byte(value and 0xff))
  elif value < 0x100000000'u64:
    w.buf.add(mt or 26'u8)
    w.buf.add(byte((value shr 24) and 0xff))
    w.buf.add(byte((value shr 16) and 0xff))
    w.buf.add(byte((value shr 8) and 0xff))
    w.buf.add(byte(value and 0xff))
  else:
    w.buf.add(mt or 27'u8)
    for i in countdown(7, 0):
      w.buf.add(byte((value shr (i * 8)) and 0xff))

# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------

type CborReader* = object
  data*: ptr UncheckedArray[byte]
  len*: int
  pos*: int

proc newReader*(data: openArray[byte]): CborReader =
  var rdr = CborReader(len: data.len, pos: 0)
  if data.len > 0:
    rdr.data = cast[ptr UncheckedArray[byte]](unsafeAddr data[0])
  return rdr

proc remaining(r: CborReader): int =
  r.len - r.pos

proc readByte(r: var CborReader): Result[byte, string] =
  if r.pos >= r.len:
    return err("CBOR: unexpected end of input")
  let b = r.data[r.pos]
  r.pos += 1
  ok(b)

proc readArgument(r: var CborReader, info: byte): Result[uint64, string] =
  ## Decode the integer argument that follows a CBOR initial byte's low-5 bits.
  case info
  of 0'u8 .. 23'u8:
    ok(uint64(info))
  of 24'u8:
    let b = ?r.readByte()
    ok(uint64(b))
  of 25'u8:
    if r.remaining < 2: return err("CBOR: truncated u16 argument")
    let v = (uint64(r.data[r.pos]) shl 8) or uint64(r.data[r.pos + 1])
    r.pos += 2
    ok(v)
  of 26'u8:
    if r.remaining < 4: return err("CBOR: truncated u32 argument")
    var v: uint64 = 0
    for i in 0 ..< 4:
      v = (v shl 8) or uint64(r.data[r.pos + i])
    r.pos += 4
    ok(v)
  of 27'u8:
    if r.remaining < 8: return err("CBOR: truncated u64 argument")
    var v: uint64 = 0
    for i in 0 ..< 8:
      v = (v shl 8) or uint64(r.data[r.pos + i])
    r.pos += 8
    ok(v)
  else:
    err("CBOR: unsupported additional info " & $info)

type CborHead = object
  major: byte
  info: byte
  arg: uint64

proc readHead(r: var CborReader): Result[CborHead, string] =
  let b = ?r.readByte()
  let major = byte(b shr 5)
  let info = byte(b and 0x1f)
  let arg = ?r.readArgument(info)
  ok(CborHead(major: major, info: info, arg: arg))

proc skipValue(r: var CborReader): Result[void, string] =
  let h = ?r.readHead()
  case h.major
  of 0, 1, 7:
    discard
  of 2, 3:
    if r.remaining < int(h.arg):
      return err("CBOR: truncated bytes/text")
    r.pos += int(h.arg)
  of 4:
    for i in 0 ..< int(h.arg):
      ?r.skipValue()
  of 5:
    for i in 0 ..< int(h.arg):
      ?r.skipValue()
      ?r.skipValue()
  of 6:
    ?r.skipValue() # tagged
  else:
    return err("CBOR: unknown major type " & $h.major)
  ok()

# ---------------------------------------------------------------------------
# Forward declarations
# ---------------------------------------------------------------------------

proc encodeValue*(w: var CborWriter, x: bool)
proc encodeValue*(w: var CborWriter, x: SomeUnsignedInt)
proc encodeValue*(w: var CborWriter, x: SomeSignedInt)
proc encodeValue*(w: var CborWriter, x: float32)
proc encodeValue*(w: var CborWriter, x: float64)
proc encodeValue*(w: var CborWriter, x: string)
proc encodeValue*(w: var CborWriter, x: cstring)
proc encodeValue*(w: var CborWriter, x: pointer)
proc encodeValue*[T](w: var CborWriter, x: ptr T)
proc encodeValue*[T](w: var CborWriter, x: seq[T])
proc encodeValue*[I, T](w: var CborWriter, x: array[I, T])
proc encodeValue*[T](w: var CborWriter, x: Option[T])
proc encodeValue*[T: enum](w: var CborWriter, x: T)
proc encodeValue*[T: object | tuple](w: var CborWriter, x: T)

proc decodeValue*(r: var CborReader, dest: var bool): Result[void, string]
proc decodeValue*[T: SomeUnsignedInt](r: var CborReader, dest: var T): Result[void, string]
proc decodeValue*[T: SomeSignedInt](r: var CborReader, dest: var T): Result[void, string]
proc decodeValue*(r: var CborReader, dest: var float32): Result[void, string]
proc decodeValue*(r: var CborReader, dest: var float64): Result[void, string]
proc decodeValue*(r: var CborReader, dest: var string): Result[void, string]
proc decodeValue*(r: var CborReader, dest: var pointer): Result[void, string]
proc decodeValue*[T](r: var CborReader, dest: var ptr T): Result[void, string]
proc decodeValue*[T](r: var CborReader, dest: var seq[T]): Result[void, string]
proc decodeValue*[I, T](r: var CborReader, dest: var array[I, T]): Result[void, string]
proc decodeValue*[T](r: var CborReader, dest: var Option[T]): Result[void, string]
proc decodeValue*[T: enum](r: var CborReader, dest: var T): Result[void, string]
proc decodeValue*[T: object | tuple](r: var CborReader, dest: var T): Result[void, string]

# ---------------------------------------------------------------------------
# Encoders
# ---------------------------------------------------------------------------

proc encodeValue*(w: var CborWriter, x: bool) =
  w.buf.add(if x: 0xf5'u8 else: 0xf4'u8)

proc encodeValue*(w: var CborWriter, x: SomeUnsignedInt) =
  w.writeHead(0, uint64(x))

proc encodeValue*(w: var CborWriter, x: SomeSignedInt) =
  if x >= 0:
    w.writeHead(0, uint64(x))
  else:
    let mag = uint64(-(x + 1))
    w.writeHead(1, mag)

proc encodeValue*(w: var CborWriter, x: float64) =
  w.buf.add(0xfb'u8)
  let bits = cast[uint64](x)
  for i in countdown(7, 0):
    w.buf.add(byte((bits shr (i * 8)) and 0xff))

proc encodeValue*(w: var CborWriter, x: float32) =
  w.buf.add(0xfa'u8)
  let bits = cast[uint32](x)
  for i in countdown(3, 0):
    w.buf.add(byte((bits shr (i * 8)) and 0xff))

proc encodeValue*(w: var CborWriter, x: string) =
  w.writeHead(3, uint64(x.len))
  if x.len > 0:
    let oldLen = w.buf.len
    w.buf.setLen(oldLen + x.len)
    copyMem(addr w.buf[oldLen], unsafeAddr x[0], x.len)

proc encodeValue*(w: var CborWriter, x: cstring) =
  if x.isNil:
    w.writeHead(3, 0)
  else:
    let s = $x
    w.writeHead(3, uint64(s.len))
    if s.len > 0:
      let oldLen = w.buf.len
      w.buf.setLen(oldLen + s.len)
      copyMem(addr w.buf[oldLen], unsafeAddr s[0], s.len)

proc encodeValue*(w: var CborWriter, x: pointer) =
  w.writeHead(0, uint64(cast[uint](x)))

proc encodeValue*[T](w: var CborWriter, x: ptr T) =
  w.writeHead(0, uint64(cast[uint](x)))

proc encodeValue*[T](w: var CborWriter, x: seq[T]) =
  w.writeHead(4, uint64(x.len))
  for item in x:
    encodeValue(w, item)

proc encodeValue*[I, T](w: var CborWriter, x: array[I, T]) =
  w.writeHead(4, uint64(x.len))
  for item in x:
    encodeValue(w, item)

proc encodeValue*[T](w: var CborWriter, x: Option[T]) =
  if x.isSome:
    encodeValue(w, x.get)
  else:
    w.buf.add(0xf6'u8)

proc encodeValue*[T: enum](w: var CborWriter, x: T) =
  w.writeHead(0, uint64(ord(x)))

proc encodeValue*[T: object | tuple](w: var CborWriter, x: T) =
  var fieldCount = 0
  for _, _ in fieldPairs(x):
    inc fieldCount
  w.writeHead(5, uint64(fieldCount))
  for name, value in fieldPairs(x):
    encodeValue(w, name)
    encodeValue(w, value)

# ---------------------------------------------------------------------------
# Decoders
# ---------------------------------------------------------------------------

proc decodeValue*(r: var CborReader, dest: var bool): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 7:
    return err("CBOR: expected bool, got major " & $h.major)
  case h.info
  of 20'u8:
    dest = false
  of 21'u8:
    dest = true
  else:
    return err("CBOR: expected bool simple value, got info " & $h.info)
  ok()

proc decodeValue*[T: SomeUnsignedInt](r: var CborReader, dest: var T): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 0:
    return err("CBOR: expected unsigned int, got major " & $h.major)
  dest = T(h.arg)
  ok()

proc decodeValue*[T: SomeSignedInt](r: var CborReader, dest: var T): Result[void, string] =
  let h = ?r.readHead()
  case h.major
  of 0:
    dest = T(h.arg)
  of 1:
    dest = T(-1) - T(h.arg)
  else:
    return err("CBOR: expected signed int, got major " & $h.major)
  ok()

proc decodeValue*(r: var CborReader, dest: var float64): Result[void, string] =
  let b = ?r.readByte()
  if b == 0xfb'u8:
    if r.remaining < 8: return err("CBOR: truncated f64")
    var bits: uint64 = 0
    for i in 0 ..< 8:
      bits = (bits shl 8) or uint64(r.data[r.pos + i])
    r.pos += 8
    dest = cast[float64](bits)
    ok()
  elif b == 0xfa'u8:
    if r.remaining < 4: return err("CBOR: truncated f32")
    var bits: uint32 = 0
    for i in 0 ..< 4:
      bits = (bits shl 8) or uint32(r.data[r.pos + i])
    r.pos += 4
    dest = float64(cast[float32](bits))
    ok()
  else:
    err("CBOR: expected float, got 0x" & $b)

proc decodeValue*(r: var CborReader, dest: var float32): Result[void, string] =
  var v: float64
  ?decodeValue(r, v)
  dest = float32(v)
  ok()

proc decodeValue*(r: var CborReader, dest: var string): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 3 and h.major != 2:
    return err("CBOR: expected text/byte string, got major " & $h.major)
  let n = int(h.arg)
  if r.remaining < n:
    return err("CBOR: truncated string body")
  dest.setLen(n)
  if n > 0:
    copyMem(addr dest[0], addr r.data[r.pos], n)
  r.pos += n
  ok()

proc decodeValue*(r: var CborReader, dest: var pointer): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 0:
    return err("CBOR: expected unsigned int for pointer, got major " & $h.major)
  dest = cast[pointer](uint(h.arg))
  ok()

proc decodeValue*[T](r: var CborReader, dest: var ptr T): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 0:
    return err("CBOR: expected unsigned int for ptr, got major " & $h.major)
  dest = cast[ptr T](uint(h.arg))
  ok()

proc decodeValue*[T](r: var CborReader, dest: var seq[T]): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 4:
    return err("CBOR: expected array, got major " & $h.major)
  let n = int(h.arg)
  dest.setLen(n)
  for i in 0 ..< n:
    ?decodeValue(r, dest[i])
  ok()

proc decodeValue*[I, T](r: var CborReader, dest: var array[I, T]): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 4:
    return err("CBOR: expected array, got major " & $h.major)
  let n = int(h.arg)
  if n != dest.len:
    return err("CBOR: array length " & $n & " != expected " & $dest.len)
  for i in 0 ..< n:
    ?decodeValue(r, dest[i])
  ok()

proc decodeValue*[T](r: var CborReader, dest: var Option[T]): Result[void, string] =
  if r.pos < r.len and r.data[r.pos] == 0xf6'u8:
    inc r.pos
    dest = none(T)
    return ok()
  var v: T
  ?decodeValue(r, v)
  dest = some(v)
  ok()

proc decodeValue*[T: enum](r: var CborReader, dest: var T): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 0:
    return err("CBOR: expected unsigned int for enum, got major " & $h.major)
  dest = T(int(h.arg))
  ok()

proc decodeValue*[T: object | tuple](r: var CborReader, dest: var T): Result[void, string] =
  let h = ?r.readHead()
  if h.major != 5:
    return err("CBOR: expected map for object, got major " & $h.major)
  let n = int(h.arg)
  for i in 0 ..< n:
    var key: string
    ?decodeValue(r, key)
    var matched = false
    for fname, fval in fieldPairs(dest):
      if not matched and fname == key:
        ?decodeValue(r, fval)
        matched = true
    if not matched:
      ?r.skipValue()
  ok()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc cborEncode*[T](x: T): seq[byte] =
  var w = CborWriter()
  encodeValue(w, x)
  w.buf

proc cborDecode*[T](data: openArray[byte], _: typedesc[T]): Result[T, string] =
  var r = newReader(data)
  var v: T
  ?decodeValue(r, v)
  ok(v)

proc cborDecodePtr*[T](
    data: ptr UncheckedArray[byte], dataLen: int, _: typedesc[T]
): Result[T, string] =
  ## Convenience for ptr+len buffers (used by the macro to avoid binding an
  ## openArray to a `let`).
  if dataLen <= 0:
    var r = CborReader(data: nil, len: 0, pos: 0)
    var v: T
    ?decodeValue(r, v)
    return ok(v)
  cborDecode(toOpenArray(data, 0, dataLen - 1), T)

# ---------------------------------------------------------------------------
# ffiType macro — unchanged surface (registers type for binding generation only)
# ---------------------------------------------------------------------------

macro ffiType*(body: untyped): untyped =
  ## Statement macro applied to a type declaration block.
  ## Registers the type in ffiTypeRegistry for binding generation.
  ## Serialization is handled by the generic cborEncode/cborDecode overloads.
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
