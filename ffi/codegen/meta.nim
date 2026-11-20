## Compile-time metadata types for FFI binding generation, populated by the
## {.ffiCtor.}/{.ffi.} macros and consumed by codegen.

import std/[json, macrocache, macros, options, sequtils]

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

template libraryDeclared*(): bool =
  libTypeCache.len > 0

template markGenBindingsEmitted*() =
  genBindingsCache.inc()

template genBindingsEmitted*(): bool =
  genBindingsCache.value > 0

func builtinTypes*(): seq[FFITypeMeta] =
  ## Payload types of the liveness events the runtime emits on every library.
  func f(name, typeName: string): FFIFieldMeta =
    FFIFieldMeta(name: name, typeName: typeName)

  @[
    FFITypeMeta(
      name: "NotRespondingReason",
      enumValues: @[
        FFIEnumValueMeta(name: "heartbeat", wire: "heartbeat", ord: 0),
        FFIEnumValueMeta(name: "queueFull", wire: "queueFull", ord: 1),
      ],
    ),
    FFITypeMeta(
      name: "NotRespondingEvent", fields: @[f("reason", "NotRespondingReason")]
    ),
    FFITypeMeta(name: "RespondingEvent", fields: @[f("reason", "NotRespondingReason")]),
    FFITypeMeta(
      name: "ReverseWorkerBlockedEvent",
      fields: @[
        f("worker", "int"),
        f("callId", "uint64"),
        f("procName", "string"),
        f("elapsedMs", "int64"),
      ],
    ),
    FFITypeMeta(name: "ReverseWorkerRecoveredEvent", fields: @[f("worker", "int")]),
  ]

func builtinEvents*(libName: string): seq[FFIEventMeta] =
  ## `not_responding`, `responding` and the reverse-worker events, typed like declared ones.
  func ev(wire, procName, payload, doc: string): FFIEventMeta =
    FFIEventMeta(
      wireName: wire,
      nimProcName: procName,
      libName: libName,
      payloadTypeName: payload,
      doc: doc,
    )

  @[
    ev(
      "not_responding", "notResponding", "NotRespondingEvent",
      "The library stopped responding: its FFI thread stalled or the event queue overflowed.",
    ),
    ev(
      "responding", "responding", "RespondingEvent",
      "The library responds again after `not_responding`.",
    ),
    ev(
      "reverse_worker_blocked", "reverseWorkerBlocked", "ReverseWorkerBlockedEvent",
      "A reverse worker has been inside one implementation past the call timeout.",
    ),
    ev(
      "reverse_worker_recovered", "reverseWorkerRecovered",
      "ReverseWorkerRecoveredEvent", "A blocked reverse worker returned.",
    ),
  ]

func withBuiltinTypes*(types: seq[FFITypeMeta]): seq[FFITypeMeta] =
  ## `types` plus the builtin event types that it does not declare itself.
  let declared = types.mapIt(it.name)
  return types & builtinTypes().filterIt(it.name notin declared)

func withBuiltinEvents*(libName: string, events: seq[FFIEventMeta]): seq[FFIEventMeta] =
  ## `events` plus the builtin events that it does not declare itself.
  let declared = events.mapIt(it.wireName)
  return events & builtinEvents(libName).filterIt(it.wireName notin declared)

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
