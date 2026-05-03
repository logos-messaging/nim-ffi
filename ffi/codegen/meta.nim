## Compile-time metadata types for FFI binding generation.
## Populated by the {.ffiCtor.} and {.ffi.} macros and consumed by codegen.

type
  FFIParamMeta* = object
    name*: string       # Nim param name, e.g. "req"
    typeName*: string   # Nim type name, e.g. "EchoRequest"
    isPtr*: bool        # true if the type is `ptr T`

  FFIProcKind* = enum
    ffiCtorKind
    ffiFfiKind

  FFIProcMeta* = object
    procName*: string       # e.g. "nimtimer_echo"
    libName*: string        # library name, e.g. "nimtimer"
    kind*: FFIProcKind
    libTypeName*: string    # e.g. "NimTimer"
    extraParams*: seq[FFIParamMeta]   # all params except the lib param
    returnTypeName*: string  # e.g. "EchoResponse", "string", "pointer"
    returnIsPtr*: bool       # true if return type is ptr T
    isAsync*: bool

  FFIFieldMeta* = object
    name*: string       # e.g. "delayMs"
    typeName*: string   # e.g. "int"

  FFITypeMeta* = object
    name*: string
    fields*: seq[FFIFieldMeta]

# Compile-time registries populated by the macros
var ffiProcRegistry* {.compileTime.}: seq[FFIProcMeta]
var ffiTypeRegistry* {.compileTime.}: seq[FFITypeMeta]
var currentLibName* {.compileTime.}: string

# Target language for binding generation; override with -d:ffiTargetLang=cpp
const ffiTargetLang* {.strdefine.} = "rust"
