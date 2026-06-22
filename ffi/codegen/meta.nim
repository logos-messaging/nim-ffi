## Compile-time metadata types for FFI binding generation.
## Populated by the {.ffiCtor.} and {.ffi.} macros and consumed by codegen.

import std/strutils

type
  ABIFormat* {.pure.} = enum
    ## Wire format for an FFI payload. `Cbor` is wired end-to-end; `C` (flat
    ## C-struct) is recognized but gated by the macros until its codegen lands.
    Cbor = "cbor"
    C = "c"

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
    abiFormat*: ABIFormat # wire format for this interaction (default Cbor)

  FFIFieldMeta* = object
    name*: string # e.g. "delayMs"
    typeName*: string # e.g. "int"

  FFITypeMeta* = object
    name*: string
    fields*: seq[FFIFieldMeta]
    abiFormat*: ABIFormat # wire format for this type (default Cbor)

  FFIEventMeta* = object
    ## Library-initiated event from `{.ffiEvent: "wire_name".}`. `wireName` is
    ## the verbatim CBOR `eventType` string the foreign side dispatches on.
    wireName*: string
    nimProcName*: string
    libName*: string
    payloadTypeName*: string
    abiFormat*: ABIFormat # wire format for this event (default Cbor)

# Compile-time registries populated by the macros
var ffiProcRegistry* {.compileTime.}: seq[FFIProcMeta]
var ffiTypeRegistry* {.compileTime.}: seq[FFITypeMeta]
var ffiEventRegistry* {.compileTime.}: seq[FFIEventMeta]
var currentLibName* {.compileTime.}: string

# Set by `declareLibrary`; the FFI annotations require it (name/type/default ABI).
var libraryDeclared* {.compileTime.}: bool = false

# Library-wide default ABI, inherited by each annotation unless it overrides.
var currentDefaultABIFormat* {.compileTime.}: ABIFormat = ABIFormat.Cbor

proc abiCodegenImplemented*(fmt: ABIFormat): bool =
  ## Whether `fmt` has a working end-to-end proc-dispatch path. Only `Cbor` does
  ## today; this is the single seam a future PR flips when `c` dispatch lands.
  fmt == ABIFormat.Cbor

proc parseABIFormatName*(name: string): tuple[ok: bool, fmt: ABIFormat] =
  ## Bare format name (`"c"`/`"cbor"`, case-insensitive) → `ABIFormat`;
  ## `ok` is false otherwise.
  case name.strip().toLowerAscii()
  of "cbor":
    (true, ABIFormat.Cbor)
  of "c":
    (true, ABIFormat.C)
  else:
    (false, ABIFormat.Cbor)

proc parseAbiSpec*(spec: string): tuple[ok: bool, fmt: ABIFormat, err: string] =
  ## Parse an `"abi = <format>"` override (whitespace/case tolerant). On bad
  ## grammar or format, returns `ok = false` with a human-readable `err`.
  let parts = spec.split('=')
  if parts.len != 2 or parts[0].strip().toLowerAscii() != "abi":
    return (
      false,
      ABIFormat.Cbor,
      "invalid ABI override '" & spec & "'; expected `abi = c` or `abi = cbor`",
    )
  let (ok, fmt) = parseABIFormatName(parts[1])
  if not ok:
    return (
      false,
      ABIFormat.Cbor,
      "unknown ABI format '" & parts[1].strip() & "'; valid values are `c` and `cbor`",
    )
  (true, fmt, "")

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
