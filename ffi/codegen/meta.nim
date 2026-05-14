## Compile-time metadata types for FFI binding generation.
## Populated by the {.ffiCtor.} and {.ffi.} macros and consumed by codegen.

import std/[strutils, unicode]

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

proc camelToSnakeCase*(s: string): string =
  ## Converts camelCase to snake_case. Inserts `_` before each uppercase rune
  ## that's not the first character and lowercases everything.
  ## e.g. "delayMs" → "delay_ms", "timerName" → "timer_name"
  var snake = ""
  var first = true
  for r in runes(s):
    if r.isUpper() and not first:
      snake.add('_')
    snake.add($r.toLower())
    first = false
  return snake

proc capitalizeFirstLetter*(s: string): string =
  ## Returns `s` with its first rune uppercased; the rest is left unchanged.
  ## e.g. "abc" → "Abc", "" → "", "Abc" → "Abc"
  if s.len == 0:
    return s
  var runesSeq = toRunes(s)
  runesSeq[0] = runesSeq[0].toUpper()
  return $runesSeq

proc snakeToPascalCase*(s: string): string =
  ## Converts snake_case identifiers to PascalCase: split on `_`, uppercase
  ## the first rune of each part, concatenate.
  ## e.g. "testlib_create" → "TestlibCreate", "hello_world" → "HelloWorld"
  let parts = s.split('_')
  var pascal = ""
  for p in parts:
    pascal.add capitalizeFirstLetter(p)
  return pascal
