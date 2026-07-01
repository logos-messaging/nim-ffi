## Compile-time metadata types for FFI binding generation.
## Populated by the {.ffiCtor.} and {.ffi.} macros and consumed by codegen.

import std/strutils

type
  ABIFormat* {.pure.} = enum
    ## Wire format for an FFI payload. Only `Cbor` is wired end-to-end; `C`
    ## (flat C-struct) has a type codec but no proc-dispatch path yet.
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
    scalarFastPath*: bool
      ## True for an `abi = c` proc whose whole signature is scalar (see
      ## `isScalarOnly`): it dispatches through the CBOR-free scalar fast path
      ## and is skipped by the foreign-binding generators (no dispatch codegen
      ## yet — the request rides inline POD args, no `_CWire`, no CBOR).

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

# Set by `genBindings()`. Any FFI annotation expanded after it registers into the
# codegen registries too late to be emitted, so the annotation macros check this
# and fail loudly instead of silently dropping the proc/type from the bindings.
var genBindingsEmitted* {.compileTime.}: bool = false

# Library-wide default ABI, inherited by each annotation unless it overrides.
var currentDefaultABIFormat* {.compileTime.}: ABIFormat = ABIFormat.Cbor

proc abiCodegenImplemented*(fmt: ABIFormat): bool =
  ## Whether `fmt` has a working proc-dispatch path. Only `Cbor` does today; the
  ## seam a future PR flips once the `c` dispatch path is wired.
  fmt == ABIFormat.Cbor

proc overrideKey*(override: string): string =
  ## Lowercased key of a `key = value` pragma override (the text before `=`),
  ## used to route it to its parser. `"timeout = 30000"` → `"timeout"`.
  override.split('=')[0].strip().toLowerAscii()

proc parseTimeoutSpec*(override: string): tuple[ok: bool, ms: int, err: string] =
  ## Parse a `"timeout = <milliseconds>"` override (whitespace/case tolerant).
  ## The value must be a positive integer number of milliseconds. On bad
  ## grammar or value, returns `ok = false` with a human-readable `err`.
  let parts = override.split('=')
  if parts.len != 2 or overrideKey(override) != "timeout":
    return (
      false,
      0,
      "invalid timeout override: '" & override & "'; expected `timeout = <ms>`",
    )
  let raw = parts[1].strip()
  let ms =
    try:
      parseInt(raw)
    except ValueError:
      return (
        false,
        0,
        "invalid timeout value: '" & raw &
          "'; expected a positive integer of milliseconds",
      )
  if ms <= 0:
    return (false, 0, "timeout must be a positive number of milliseconds, got: " & raw)
  (true, ms, "")

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

proc parseAbiSpec*(override: string): tuple[ok: bool, fmt: ABIFormat, err: string] =
  ## Parse an `"abi = <format>"` override (whitespace/case tolerant). On bad
  ## grammar or format, returns `ok = false` with a human-readable `err`.
  let parts = override.split('=')
  if parts.len != 2:
    return (
      false,
      ABIFormat.Cbor,
      "invalid ABI override: '" & override & "'; expected `abi = c` or `abi = cbor`",
    )
  if parts[0].strip().toLowerAscii() != "abi":
    return (
      false,
      ABIFormat.Cbor,
      "invalid ABI override: '" & override & "'; expected `abi = c` or `abi = cbor`",
    )
  let (ok, fmt) = parseABIFormatName(parts[1])
  if not ok:
    return (
      false,
      ABIFormat.Cbor,
      "unknown ABI format: '" & parts[1].strip() & "'; valid values are `c` and `cbor`",
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
