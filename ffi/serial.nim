import std/[json, options]
import results
import ./codegen/meta

proc ffiSerialize*(x: string): string =
  x

proc ffiSerialize*(x: cstring): string =
  if x.isNil: "" else: $x

proc ffiSerialize*(x: int): string =
  $x

proc ffiSerialize*(x: int32): string =
  $x

proc ffiSerialize*(x: bool): string =
  if x: "true" else: "false"

proc ffiSerialize*(x: float): string =
  $(%*x)

proc ffiSerialize*(x: pointer): string =
  $cast[uint](x)

proc ffiDeserialize*(s: cstring, _: typedesc[string]): Result[string, string] =
  ok($s)

proc ffiDeserialize*(s: cstring, _: typedesc[int]): Result[int, string] =
  try:
    ok(int(parseJson($s).getBiggestInt()))
  except Exception as e:
    err(e.msg)

proc ffiDeserialize*(s: cstring, _: typedesc[int32]): Result[int32, string] =
  try:
    ok(int32(parseJson($s).getBiggestInt()))
  except Exception as e:
    err(e.msg)

proc ffiDeserialize*(s: cstring, _: typedesc[bool]): Result[bool, string] =
  try:
    ok(parseJson($s).getBool())
  except Exception as e:
    err(e.msg)

proc ffiDeserialize*(s: cstring, _: typedesc[float]): Result[float, string] =
  try:
    ok(parseJson($s).getFloat())
  except Exception as e:
    err(e.msg)

proc ffiDeserialize*(s: cstring, _: typedesc[pointer]): Result[pointer, string] =
  try:
    let address = cast[pointer](uint(parseJson($s).getBiggestInt()))
    ok(address)
  except Exception as e:
    err(e.msg)

proc ffiSerialize*[T](x: ptr T): string =
  $cast[uint](x)

proc ffiSerialize*[T](x: seq[T]): string =
  var arr = newJArray()
  for item in x:
    arr.add(parseJson(ffiSerialize(item)))
  result = $arr

proc ffiSerialize*[T](x: Option[T]): string =
  if x.isSome:
    ffiSerialize(x.get)
  else:
    "null"

proc ffiSerialize*[T: object](x: T): string =
  $(%*x)

proc ffiDeserialize*[T](s: cstring, _: typedesc[ptr T]): Result[ptr T, string] =
  try:
    let address = cast[ptr T](uint(parseJson($s).getBiggestInt()))
    ok(address)
  except Exception as e:
    err(e.msg)

proc ffiDeserialize*[T](s: cstring, _: typedesc[seq[T]]): Result[seq[T], string] =
  try:
    let node = parseJson($s)
    if node.kind != JArray:
      return err("expected JSON array")
    var resultSeq: seq[T] = @[]
    for item in node:
      let itemJson = $item
      let parsed = ffiDeserialize(itemJson.cstring, typedesc[T])
      if parsed.isOk:
        resultSeq.add(parsed.get)
      else:
        return err(parsed.error)
    ok(resultSeq)
  except Exception as e:
    err(e.msg)

proc ffiDeserialize*[T](s: cstring, _: typedesc[Option[T]]): Result[Option[T], string] =
  try:
    let node = parseJson($s)
    if node.kind == JNull:
      ok(none(T))
    else:
      let itemJson = $node
      let parsed = ffiDeserialize(itemJson.cstring, typedesc[T])
      if parsed.isOk:
        ok(some(parsed.get))
      else:
        err(parsed.error)
  except Exception as e:
    err(e.msg)

proc ffiDeserialize*[T: object](s: cstring, _: typedesc[T]): Result[T, string] =
  try:
    ok(parseJson($s).to(T))
  except Exception as e:
    err(e.msg)
