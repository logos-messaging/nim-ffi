import std/[json, macros, options]
import results
import ./codegen/meta

proc ffiSerialize*(x: string): string =
  $(%*x)

proc ffiSerialize*(x: cstring): string =
  if x.isNil:
    "null"
  else:
    ffiSerialize($x)

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
  try:
    let node = parseJson($s)
    if node.kind != JString:
      return err("expected JSON string")
    ok(node.getStr())
  except Exception as e:
    err(e.msg)

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

macro ffiType*(body: untyped): untyped =
  ## Statement macro applied to a type declaration block.
  ## Registers the type in ffiTypeRegistry for binding generation.
  ## Serialization is handled by the generic ffiSerialize/ffiDeserialize overloads.
  ## Usage:
  ##   ffiType:
  ##     type Foo = object
  ##       field: int
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
  result = body
