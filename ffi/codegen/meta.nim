## Compile-time metadata types for FFI binding generation.
## Populated by the {.ffiCtor.} and {.ffi.} macros and consumed by codegen.

type
  FFIParamMeta* = object
    name*: string # Nim param name, e.g. "req"
    typeName*: string # Nim type name, e.g. "EchoRequest"
    isPtr*: bool # true if the type is `ptr T`
    isHandle*: bool # true if the type is an {.ffiHandle.} type (wire form uint64)

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
    returnIsHandle*: bool # true if return type is an {.ffiHandle.} type

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

# Compile-time registries populated by the macros
var ffiProcRegistry* {.compileTime.}: seq[FFIProcMeta]
var ffiTypeRegistry* {.compileTime.}: seq[FFITypeMeta]
var ffiEventRegistry* {.compileTime.}: seq[FFIEventMeta]
var currentLibName* {.compileTime.}: string

# Lib type name (set by declareLibrary) so handle-receiver procs resolve the pool.
var currentLibType* {.compileTime.}: string

# Names of types marked `{.ffiHandle.}` (wire form uint64).
var ffiHandleTypeNames* {.compileTime.}: seq[string]

proc isFFIHandleTypeName*(name: string): bool {.compileTime.} =
  name in ffiHandleTypeNames

proc ridesAsPtr*(ep: FFIParamMeta): bool =
  ## True if the param crosses the wire as an opaque uint64 — a raw `ptr` or an
  ## `{.ffiHandle.}` id. Both share the codegen pointer type.
  ep.isPtr or ep.isHandle

proc returnRidesAsPtr*(p: FFIProcMeta): bool =
  ## True if the return crosses the wire as an opaque uint64 (raw `ptr` or handle).
  p.returnIsPtr or p.returnIsHandle

# Target language for binding generation; override with -d:targetLang=cpp
const targetLang* {.strdefine.} = "rust"

# Output directory for generated bindings; set with -d:ffiOutputDir=path/to/dir
const ffiOutputDir* {.strdefine.} = ""

# Nim source path (relative to outputDir) embedded in generated build files;
# set with -d:ffiSrcPath=../relative/path.nim
const ffiSrcPath* {.strdefine.} = ""
