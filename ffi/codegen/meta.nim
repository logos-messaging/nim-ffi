## Compile-time metadata types for FFI binding generation, populated by the
## {.ffiCtor.}/{.ffi.} macros and consumed by codegen.

import std/[json, macrocache, macros, options, strutils]
import ../ffi_msg

type
  FFIParamMeta* = object
    name*: string
    typeName*: string
    isPtr*: bool
    isHandle*: bool # {.ffiHandle.} type, wire form uint64

  FFIKind* {.pure.} = enum
    FFI
    CTOR
    DTOR
    STATIC ## `{.ffiStatic.}`: context-independent, its wrapper takes no `ctx`

  FFIProcMeta* = object
    procName*: string
    libName*: string
    kind*: FFIKind
    libTypeName*: string
    doc*: string
    extraParams*: seq[FFIParamMeta] # all params except the lib param
    returnTypeName*: string
    returnIsPtr*: bool
    returnIsHandle*: bool

  FFIFieldMeta* = object
    name*: string
    typeName*: string

  FFIEnumValueMeta* = object
    ## One `{.ffi.}` enum value. `wire` is what `$value` yields — the symbol name,
    ## or the associated string if the enum declares one — which is exactly what
    ## cbor_serialization puts on the wire.
    name*: string
    wire*: string
    ord*: int

  FFITypeMeta* = object
    name*: string
    fields*: seq[FFIFieldMeta]
    enumValues*: seq[FFIEnumValueMeta] ## non-empty iff the type is an enum

  FFIConstMeta* = object
    ## A `{.ffiConst.}` value. `value` is the compile-time-evaluated result of
    ## `$theConst`, re-rendered as a literal by each backend.
    name*: string
    typeName*: string
    value*: string

  FFIEventMeta* = object
    ## Library-initiated event from `{.ffiEvent: "wire_name".}`; `wireName` is
    ## the verbatim CBOR `eventType` the foreign side dispatches on.
    wireName*: string
    nimProcName*: string
    libName*: string
    payloadTypeName*: string
    doc*: string

  FFIReverseMeta* = object ## Host-implemented interface from `{.ffiReverse.}`.
    wireName*: string ## the registry key and the `<lib>_set_<wire>_impl` suffix
    nimProcName*: string ## the Nim stub the library awaits
    libName*: string ## prefix of the generated exports
    params*: seq[FFIParamMeta] ## the call's arguments, in declaration order
    argsTypeName*: string ## synthesized args object, single param type, or ""
    replyTypeName*: string ## "" when the proc returns Future[Result[void, string]]
    timeoutMs*: int ## 0 = library default (ReverseCallTimeoutMs)
    doc*: string ## the proc's doc comment, copied into the bindings

  FFIReverseEventMeta* = object ## Host-emitted event from `{.ffiReverseEvent.}`.
    wireName*: string ## the `<lib>_emit_<wire>` suffix
    nimProcName*: string ## the Nim handler that runs on the FFI thread
    libName*: string ## prefix of the generated exports
    reqTypeName*: string ## the Req object whose CBOR shape the host encodes
    params*: seq[FFIParamMeta] ## the event's fields, in declaration order
    doc*: string ## the proc's doc comment, copied into the bindings

# macrocache, not `{.compileTime.}` vars: `--ic:on` compiles each module in its own process.
const
  procCache = CacheSeq"ffi.procs"
  typeCache = CacheSeq"ffi.types"
  eventCache = CacheSeq"ffi.events"
  constCache = CacheSeq"ffi.consts"
  reverseCache = CacheSeq"ffi.reverses"
  reverseEventCache = CacheSeq"ffi.reverseEvents"
  handleTypeCache = CacheSeq"ffi.handleTypes"
  libNameCache = CacheSeq"ffi.libName"
  nameIdCache = CacheSeq"ffi.nameIds"
  libTypeCache = CacheSeq"ffi.libType"
  genBindingsCache = CacheCounter"ffi.genBindings"

proc cacheAdd[T](cache: CacheSeq, item: T) {.compileTime.} =
  cache.add(newLit($(%item)))

proc addFFIProc*(meta: FFIProcMeta) {.compileTime.} =
  procCache.cacheAdd(meta)

proc addFFIType*(meta: FFITypeMeta) {.compileTime.} =
  typeCache.cacheAdd(meta)

proc addFFIEvent*(meta: FFIEventMeta) {.compileTime.} =
  eventCache.cacheAdd(meta)

proc addFFIConst*(meta: FFIConstMeta) {.compileTime.} =
  constCache.cacheAdd(meta)

proc addFFIReverse*(meta: FFIReverseMeta) {.compileTime.} =
  reverseCache.cacheAdd(meta)

proc addFFIReverseEvent*(meta: FFIReverseEventMeta) {.compileTime.} =
  reverseEventCache.cacheAdd(meta)

proc setCurrentLibName*(name: string) {.compileTime.} =
  libNameCache.add(newLit(name))

proc setCurrentLibType*(name: string) {.compileTime.} =
  libTypeCache.add(newLit(name))

proc addFFIHandleTypeName*(name: string) {.compileTime.} =
  handleTypeCache.add(newLit(name))

proc isFFIHandleTypeName*(name: string): bool {.compileTime.} =
  for node in handleTypeCache:
    if node.strVal == name:
      return true
  return false

# Templates: a proc call with constant args folds when the macro compiles, before any annotation runs.
template cacheLoad(cache: CacheSeq, T: typedesc): untyped =
  var loaded: seq[T]
  for node in macrocache.items(cache):
    loaded.add(parseJson(node.strVal).to(T))
  loaded

template cacheLast(cache: CacheSeq): string =
  if cache.len == 0:
    ""
  else:
    cache[cache.len - 1].strVal

template ffiProcRegistry*(): seq[FFIProcMeta] =
  procCache.cacheLoad(FFIProcMeta)

template ffiTypeRegistry*(): seq[FFITypeMeta] =
  typeCache.cacheLoad(FFITypeMeta)

template ffiEventRegistry*(): seq[FFIEventMeta] =
  eventCache.cacheLoad(FFIEventMeta)

template ffiConstRegistry*(): seq[FFIConstMeta] =
  constCache.cacheLoad(FFIConstMeta)

template ffiReverseRegistry*(): seq[FFIReverseMeta] =
  reverseCache.cacheLoad(FFIReverseMeta)

template ffiReverseEventRegistry*(): seq[FFIReverseEventMeta] =
  reverseEventCache.cacheLoad(FFIReverseEventMeta)

template currentLibName*(): string =
  libNameCache.cacheLast()

template currentLibType*(): string =
  libTypeCache.cacheLast()

type FFINameIdClaim* = object
  ## One wire name of a library and the `nameId` a polled message carries for it.
  id*: uint64
  wireName*: string
  kind*: string
    ## "event" or "reverse call": each is matched within its own message kind.
  libName*: string

func clashingName*(claims: openArray[FFINameIdClaim], claim: FFINameIdClaim): string =
  ## The other name already holding `claim.id` in the same library and kind; "" if none.
  for c in claims:
    if c.id == claim.id and c.kind == claim.kind and c.libName == claim.libName and
        c.wireName != claim.wireName:
      return c.wireName
  return ""

proc addNameIdClaim*(claim: FFINameIdClaim) {.compileTime.} =
  nameIdCache.add(
    newLit(claim.kind & "\n" & claim.libName & "\n" & claim.wireName & "\n" & $claim.id)
  )

proc claimNameId*(wireName, kind: string) {.compileTime.} =
  ## A polled message names its event or reverse call by `nameId` alone, so two
  ## names sharing one id would reach the host as the same thing. Stop the build.
  var held: seq[FFINameIdClaim]
  for node in nameIdCache:
    let parts = node.strVal.split('\n')
    held.add(
      FFINameIdClaim(
        id: parseBiggestUInt(parts[3]).uint64,
        wireName: parts[2],
        kind: parts[0],
        libName: parts[1],
      )
    )
  let claim = FFINameIdClaim(
    id: nameId(wireName), wireName: wireName, kind: kind, libName: currentLibName()
  )
  let other = held.clashingName(claim)
  if other.len > 0:
    error(
      "the " & kind & " names \"" & wireName & "\" and \"" & other &
        "\" hash to the same name id (" & nameIdLiteral(wireName) &
        "); rename one of them"
    )
  addNameIdClaim(claim)

template libraryDeclared*(): bool =
  libTypeCache.len > 0

template markGenBindingsEmitted*() =
  genBindingsCache.inc()

template genBindingsEmitted*(): bool =
  genBindingsCache.value > 0

func isEnum*(t: FFITypeMeta): bool =
  return t.enumValues.len > 0

func isStatic*(p: FFIProcMeta): bool =
  p.kind == FFIKind.STATIC

type ClassifiedProcs* = object
  ctors*: seq[FFIProcMeta]
  methods*: seq[FFIProcMeta]
  statics*: seq[FFIProcMeta]
  dtor*: Option[FFIProcMeta]

func classifyProcs*(procs: seq[FFIProcMeta]): ClassifiedProcs =
  ## Splits the registry into constructors, methods, statics and the first destructor.
  var c: ClassifiedProcs
  for p in procs:
    case p.kind
    of FFIKind.CTOR:
      c.ctors.add(p)
    of FFIKind.FFI:
      c.methods.add(p)
    of FFIKind.STATIC:
      c.statics.add(p)
    of FFIKind.DTOR:
      if c.dtor.isNone():
        c.dtor = some(p)
  c

func dtorProcName*(c: ClassifiedProcs): string =
  ## The destructor's proc name, or "" when the library has no destructor.
  if c.dtor.isSome():
    c.dtor.get().procName
  else:
    ""

func replyProcs*(c: ClassifiedProcs): seq[FFIProcMeta] =
  ## Procs that reply with a decoded value: methods and statics.
  c.methods & c.statics

proc ridesAsPtr*(ep: FFIParamMeta): bool =
  ## True if the param crosses the wire as an opaque uint64 (raw ptr or handle).
  ep.isPtr or ep.isHandle

proc returnRidesAsPtr*(p: FFIProcMeta): bool =
  ## True if the return crosses the wire as an opaque uint64 (raw ptr or handle).
  p.returnIsPtr or p.returnIsHandle

# Target language(s), override with -d:targetLang=cpp; comma-separated list allowed.
const targetLang* {.strdefine.} = "rust"

# Output dir override (-d:ffiOutputDir); empty derives `<lang>_bindings/` by src.
const ffiOutputDir* {.strdefine.} = ""

# Nim src path override relative to outputDir (-d:ffiSrcPath); empty derives it.
const ffiSrcPath* {.strdefine.} = ""
