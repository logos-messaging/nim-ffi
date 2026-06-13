## Compile-time metadata types for FFI binding generation.
## Populated by the {.ffiCtor.} and {.ffi.} macros and consumed by codegen.

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

  FFIFieldMeta* = object
    name*: string # e.g. "delayMs"
    typeName*: string # e.g. "int"

  FFITypeMeta* = object
    name*: string
    fields*: seq[FFIFieldMeta]

  FFIEventMeta* = object
    ## Library-initiated event declared with `{.ffiEvent: "wire_name".}`.
    ## `wireName` is the literal string the foreign side dispatches on
    ## (it appears in the CBOR `eventType` field, verbatim — no case
    ## conversion). `payloadTypeName` is the Nim type of the single
    ## payload parameter.
    wireName*: string
    nimProcName*: string
    libName*: string
    payloadTypeName*: string

  FFIHostMeta* = object
    ## Host-provided function declared with `{.ffiHost.}` — the host implements
    ## it and a `{.ffi.}` handler awaits it. `wireName` is the snake_case name
    ## the host registers under. First slice: one `string` arg, `string` return;
    ## `argName`/`argTypeName`/`returnTypeName` carry the shape so generators can
    ## emit a typed wrapper.
    wireName*: string
    nimProcName*: string
    libName*: string
    argName*: string
    argTypeName*: string
    returnTypeName*: string

# Compile-time registries populated by the macros
var ffiProcRegistry* {.compileTime.}: seq[FFIProcMeta]
var ffiTypeRegistry* {.compileTime.}: seq[FFITypeMeta]
var ffiEventRegistry* {.compileTime.}: seq[FFIEventMeta]
var ffiHostRegistry* {.compileTime.}: seq[FFIHostMeta]
var currentLibName* {.compileTime.}: string

# Target language for binding generation; override with -d:targetLang=cpp
const targetLang* {.strdefine.} = "rust"

# Output directory for generated bindings; set with -d:ffiOutputDir=path/to/dir
const ffiOutputDir* {.strdefine.} = ""

# Nim source path (relative to outputDir) embedded in generated build files;
# set with -d:ffiSrcPath=../relative/path.nim
const ffiSrcPath* {.strdefine.} = ""
