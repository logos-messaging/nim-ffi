## Compile-time metadata types for FFI binding generation.
## Populated by the {.ffiCtor.} and {.ffi.} macros and consumed by codegen.

import std/strutils

type
  FFIParamMeta* = object
    name*: string # Nim param name, e.g. "req"
    typeName*: string # Nim type name, e.g. "EchoRequest"
    isPtr*: bool # true if the type is `ptr T`

  FFIKind* {.pure.} = enum
    FFI
    CTOR
    DTOR

  FFIProcMeta* = object
    procName*: string # e.g. "timer_echo"
    libName*: string # library name, e.g. "timer"
    kind*: FFIKind
    libTypeName*: string # e.g. "Timer"
    extraParams*: seq[FFIParamMeta] # all params except the lib param
    returnTypeName*: string # e.g. "EchoResponse", "string", "pointer"
    returnIsPtr*: bool # true if return type is ptr T
    isAsync*: bool

  FFIFieldMeta* = object
    name*: string # e.g. "delayMs"
    typeName*: string # e.g. "int"

  FFITypeMeta* = object
    name*: string
    fields*: seq[FFIFieldMeta]

# Compile-time registries populated by the macros
var ffiProcRegistry* {.compileTime.}: seq[FFIProcMeta]
var ffiTypeRegistry* {.compileTime.}: seq[FFITypeMeta]
var currentLibName* {.compileTime.}: string

# Target language for binding generation; override with -d:targetLang=cpp
const targetLang* {.strdefine.} = "rust"

# Output directory for generated bindings; set with -d:ffiOutputDir=path/to/dir
const ffiOutputDir* {.strdefine.} = ""

# Nim source path (relative to outputDir) embedded in generated build files;
# set with -d:ffiNimSrcRelPath=../relative/path.nim
const ffiNimSrcRelPath* {.strdefine.} = ""

# ---------------------------------------------------------------------------
# Name conversion helpers shared by codegen and the ffi macro
# ---------------------------------------------------------------------------

proc toSnakeCase*(s: string): string =
  var snake = ""
  for i, c in s:
    if c.isUpperAscii() and i > 0:
      snake.add('_')
    snake.add(c.toLowerAscii())
  return snake

proc toPascalCase*(s: string): string =
  ## Returns `s` with the first character uppercased.
  if s.len == 0:
    return s
  var pascal = s
  pascal[0] = s[0].toUpperAscii()
  return pascal

proc toCamelCase*(s: string): string =
  ## Converts snake_case or mixed identifiers to PascalCase for type names.
  ## e.g. "testlib_create" -> "TestlibCreate"
  let parts = s.split('_')
  var camel = ""
  for p in parts:
    camel.add toPascalCase(p)
  return camel
