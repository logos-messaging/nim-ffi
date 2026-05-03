import std/[json, macros]
import results
import ./codegen/meta

proc ffiSerialize*(x: string): string =
  $(%* x)

proc ffiSerialize*(x: cstring): string =
  if x.isNil: "null"
  else: ffiSerialize($x)

proc ffiSerialize*(x: int): string =
  $x

proc ffiSerialize*(x: int32): string =
  $x

proc ffiSerialize*(x: bool): string =
  if x: "true" else: "false"

proc ffiSerialize*(x: float): string =
  $(%* x)

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

proc ffiDeserialize*[T](s: cstring, _: typedesc[ptr T]): Result[ptr T, string] =
  try:
    let address = cast[ptr T](uint(parseJson($s).getBiggestInt()))
    ok(address)
  except Exception as e:
    err(e.msg)

macro ffiType*(body: untyped): untyped =
  ## Statement macro applied to a type declaration block.
  ## Generates ffiSerialize and ffiDeserialize overloads for each type,
  ## and registers the type in ffiTypeRegistry for binding generation.
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

  # Collect field metadata for the codegen registry
  let typeNameStr = $typeName
  var fieldMetas: seq[FFIFieldMeta] = @[]
  # typeDef layout: TypDef[name, genericParams, objectTy]
  # objectTy layout: ObjectTy[empty, empty, recList]
  let objTy = typeDef[2]
  if objTy.kind == nnkObjectTy and objTy.len >= 3:
    let recList = objTy[2]
    if recList.kind == nnkRecList:
      for identDef in recList:
        if identDef.kind == nnkIdentDefs:
          # identDef: [name1, ..., type, default]
          let fieldType = identDef[^2]
          var fieldTypeName: string
          if fieldType.kind == nnkIdent:
            fieldTypeName = $fieldType
          elif fieldType.kind == nnkPtrTy:
            fieldTypeName = "ptr " & $fieldType[0]
          else:
            fieldTypeName = fieldType.repr
          for i in 0 ..< identDef.len - 2:
            let fname = $identDef[i]
            fieldMetas.add(FFIFieldMeta(name: fname, typeName: fieldTypeName))

  ffiTypeRegistry.add(FFITypeMeta(name: typeNameStr, fields: fieldMetas))

  let serializeProc = quote do:
    proc ffiSerialize*(x: `typeName`): string =
      $(%* x)

  let deserializeProc = quote do:
    proc ffiDeserialize*(s: cstring, _: typedesc[`typeName`]): Result[`typeName`, string] =
      try:
        ok(parseJson($s).to(`typeName`))
      except Exception as e:
        err(e.msg)

  result = newStmtList(body, serializeProc, deserializeProc)
