## C++ binding generator for the nim-ffi framework.
## Generates a header-only C++ binding and CMakeLists.txt. Requests/responses
## travel as CBOR (encoded with vendored TinyCBOR on the C++ side, matching
## the Nim-side cbor_serial codec on the wire — both ends speak RFC 8949).

import std/[os, strutils]
import ./meta, ./string_helpers

## Wire-format C++ type used for any Nim `ptr T` / `pointer`. Fixed 64-bit so
## the CBOR payload size is stable regardless of host architecture.
const CppPtrType* = "uint64_t"

## Static template blocks live as real C++ / CMake files under templates/cpp/
## and are slurped into the binary at compile time. Edits to those files are
## reflected in the generated bindings without touching this codegen.
const
  HeaderPreludeTpl = staticRead("templates/cpp/header_prelude.hpp.tpl")
  ResultTpl = staticRead("templates/cpp/result.hpp.tpl")
  CborHelpersTpl = staticRead("templates/cpp/cbor_helpers.hpp.tpl")
  SyncCallHelperTpl = staticRead("templates/cpp/sync_call_helper.hpp.tpl")
  ContextRuleOf5Tpl = staticRead("templates/cpp/context_rule_of_5.hpp.tpl")
  CMakeListsTpl = staticRead("templates/cpp/CMakeLists.txt.tpl")

proc genericInnerType(typeName, prefix: string): string =
  if typeName.startsWith(prefix) and typeName.endsWith("]"):
    let start = prefix.len
    let lastIndex = typeName.len - 2
    return typeName[start .. lastIndex]
  return ""

proc nimTypeToCpp*(typeName: string): string =
  let trimmed = typeName.strip()
  if trimmed.startsWith("ptr "):
    return CppPtrType
  else:
    let seqInner = genericInnerType(trimmed, "seq[")
    if seqInner.len > 0:
      return "std::vector<" & nimTypeToCpp(seqInner) & ">"
    let optionInner = genericInnerType(trimmed, "Option[")
    if optionInner.len > 0:
      return "std::optional<" & nimTypeToCpp(optionInner) & ">"
    let maybeInner = genericInnerType(trimmed, "Maybe[")
    if maybeInner.len > 0:
      return "std::optional<" & nimTypeToCpp(maybeInner) & ">"
  case trimmed
  of "string", "cstring": "std::string"
  of "int", "int64": "int64_t"
  of "int32": "int32_t"
  of "bool": "bool"
  of "float": "float"
  of "float64": "double"
  of "pointer": CppPtrType
  else: trimmed

proc stripLibPrefixCpp(procName, libName: string): string =
  let prefix = libName & "_"
  if procName.startsWith(prefix):
    return procName[prefix.len .. ^1]
  return procName

proc reqStructName(p: FFIProcMeta): string =
  let camel = snakeToPascalCase(p.procName)
  if p.kind == FFIKind.CTOR:
    camel & "CtorReq"
  else:
    camel & "Req"

proc emitStructCborCodec(
    lines: var seq[string], structName: string, fields: seq[(string, string)]
) =
  ## Appends per-struct TinyCBOR encode_cbor + decode_cbor free functions for
  ## `structName`. `fields` is a sequence of (field-name, ignored C++ type)
  ## pairs — the type is unused at the codec layer because the generic
  ## encode_cbor / decode_cbor overloads in cbor_helpers.hpp.tpl dispatch on
  ## the struct member's type. We emit a CBOR map with text-string keys to
  ## match the wire format produced by Nim's cbor_serialization.
  let n = fields.len
  # ── encode ────────────────────────────────────────────────────────────────
  if n == 0:
    lines.add(
      "inline CborError encode_cbor(CborEncoder& e, const $1&) {" % [structName]
    )
  else:
    lines.add(
      "inline CborError encode_cbor(CborEncoder& e, const $1& v) {" % [structName]
    )
  lines.add("    CborEncoder m;")
  lines.add("    CborError err = cbor_encoder_create_map(&e, &m, $1);" % [$n])
  lines.add("    if (err) return err;")
  for (name, _) in fields:
    lines.add(
      "    err = cbor_encode_text_stringz(&m, \"$1\"); if (err) return err;" % [name]
    )
    lines.add(
      "    err = encode_cbor(m, v.$1);              if (err) return err;" % [name]
    )
  lines.add("    return cbor_encoder_close_container(&e, &m);")
  lines.add("}")
  # ── decode ────────────────────────────────────────────────────────────────
  if n == 0:
    lines.add("inline CborError decode_cbor(CborValue& it, $1&) {" % [structName])
    lines.add("    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;")
    lines.add("    return cbor_value_advance(&it);")
    lines.add("}")
    return
  lines.add("inline CborError decode_cbor(CborValue& it, $1& v) {" % [structName])
  lines.add("    if (!cbor_value_is_map(&it)) return CborErrorImproperValue;")
  lines.add("    CborValue field;")
  lines.add("    CborError err;")
  for (name, _) in fields:
    lines.add(
      "    err = cbor_value_map_find_value(&it, \"$1\", &field); if (err) return err;" %
        [name]
    )
    lines.add("    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;")
    lines.add("    err = decode_cbor(field, v.$1); if (err) return err;" % [name])
  lines.add("    return cbor_value_advance(&it);")
  lines.add("}")

proc cppBracedInit(structName: string, fieldNames: seq[string]): string =
  ## Produces a C++ braced-init expression for a per-proc Req struct.
  ## Used to construct the request value before CBOR-encoding it for the wire,
  ## as in `const auto req = TimerEchoReq{message, count};` in the generated
  ## header. The field order must match the struct's declaration order, which
  ## in turn mirrors the user's Nim FFI signature.
  ##
  ## Examples:
  ##   cppBracedInit("TimerEchoReq", @["message", "count"])
  ##     → "TimerEchoReq{message, count}"
  ##   cppBracedInit("TimerVersionReq", @[])
  ##     → "TimerVersionReq{}"
  ##   cppBracedInit("TimerCreateCtorReq", @["config"])
  ##     → "TimerCreateCtorReq{config}"
  ##
  ## Empty `fieldNames` collapses cleanly because `join` on an empty seq
  ## returns "", so the result is the well-formed empty-init `Name{}`.
  return structName & "{" & fieldNames.join(", ") & "}"

proc emitEventDispatcher(
    lines: var seq[string], ctxTypeName, libName: string, events: seq[FFIEventMeta]
) =
  ## Public listener-registration API in the generated context class:
  ##
  ## - `addOn<X>Listener(std::function<void(const T&)>) -> ListenerHandle`
  ##   per declared `{.ffiEvent.}`. Internally registers under the wire
  ##   event name; the per-listener trampoline decodes the CBOR
  ##   envelope's `payload` field as `T` and invokes the user handler.
  ## - `addEventListener(std::function<void(int, const std::string&)>) ->
  ##   ListenerHandle` registers a catch-all wildcard listener
  ##   (event_name == "") that receives every event as raw envelope
  ##   bytes plus the FFI return code.
  ## - `removeEventListener(ListenerHandle) -> bool` drops a listener by
  ##   handle. After it returns true, no further callbacks for that id
  ##   are in flight on the FFI side (the Nim-side registry lock plus
  ##   snapshot copy guarantees this).
  ##
  ## Ownership: each listener's callable is held by a
  ## `std::unique_ptr<ListenerBase>` in `listeners_`, keyed by id; the
  ## raw pointer is handed to the dylib as `user_data`. The map entry
  ## (and therefore the callable) survives at a stable heap address
  ## until `removeEventListener` removes it.
  if events.len == 0:
    return
  lines.add("    // ── Event listener API ──────────────────────────────────")
  lines.add("    struct ListenerHandle { std::uint64_t id = 0; };")
  lines.add("")
  # Per-event typed registration helpers.
  for ev in events:
    let methodName =
      "addOn" & capitalizeFirstLetter(ev.nimProcName).substr(2) & "Listener"
    lines.add(
      "    ListenerHandle $1(std::function<void(const $2&)> handler) {" %
        [methodName, ev.payloadTypeName]
    )
    lines.add(
      "        auto owned = std::make_unique<TypedListener<$1>>(std::move(handler));" %
        [ev.payloadTypeName]
    )
    lines.add("        auto* raw = owned.get();")
    lines.add(
      "        const auto id = $1_add_event_listener(" % [libName]
    )
    lines.add(
      "            ptr_, \"$1\", &$2::typedTrampoline<$3>, raw);" %
        [ev.wireName, ctxTypeName, ev.payloadTypeName]
    )
    lines.add("        if (id == 0) return ListenerHandle{0};")
    lines.add("        listeners_.emplace(id, std::move(owned));")
    lines.add("        return ListenerHandle{id};")
    lines.add("    }")
    lines.add("")
  # Generic wildcard registration.
  #
  # The handler receives the FFI return code, the wire `eventType` string
  # extracted from the CBOR envelope (empty if the envelope is malformed
  # or `ret != 0`), and a `std::span` view over the raw envelope bytes —
  # the buffer is owned by the dylib and stays valid for the duration of
  # the synchronous callback only. Pair with `decodeEventPayload<T>` to
  # lift the payload into a typed value without hand-rolling CBOR parsing.
  lines.add(
    "    ListenerHandle addEventListener(std::function<void(int, const std::string&, std::span<const std::uint8_t>)> handler) {"
  )
  lines.add(
    "        auto owned = std::make_unique<WildcardListener>(std::move(handler));"
  )
  lines.add("        auto* raw = owned.get();")
  lines.add("        const auto id = $1_add_event_listener(" % [libName])
  lines.add(
    "            ptr_, \"\", &$1::wildcardTrampoline, raw);" % [ctxTypeName]
  )
  lines.add("        if (id == 0) return ListenerHandle{0};")
  lines.add("        listeners_.emplace(id, std::move(owned));")
  lines.add("        return ListenerHandle{id};")
  lines.add("    }")
  lines.add("")
  # Remove by handle.
  lines.add("    bool removeEventListener(ListenerHandle handle) {")
  lines.add("        if (handle.id == 0) return false;")
  lines.add(
    "        const auto rc = $1_remove_event_listener(ptr_, handle.id);" % [libName]
  )
  lines.add("        listeners_.erase(handle.id);")
  lines.add("        return rc == 0;")
  lines.add("    }")
  lines.add("")

proc emitEventTrampoline(
    lines: var seq[string], events: seq[FFIEventMeta]
) =
  ## Private listener machinery for the public API emitted by
  ## `emitEventDispatcher`:
  ##
  ## - `ListenerBase` is a polymorphic base so the context's
  ##   `listeners_` map can own typed and wildcard listeners under a
  ##   single value type.
  ## - `TypedListener<T>` holds the user's `std::function<void(const T&)>`
  ##   and is the target of `typedTrampoline<T>`, which CBOR-decodes the
  ##   envelope's `payload` field as `T` and invokes the handler.
  ## - `WildcardListener` holds a `std::function<void(int, const
  ##   std::string&, std::span<const std::uint8_t>)>` and is the target
  ##   of `wildcardTrampoline`, which forwards the FFI return code plus
  ##   a span view over the raw payload bytes (no copy — the dylib owns
  ##   the buffer for the duration of the synchronous callback).
  if events.len == 0:
    return
  lines.add("    struct ListenerBase {")
  lines.add("        virtual ~ListenerBase() = default;")
  lines.add("    };")
  lines.add("")
  lines.add("    template <class T>")
  lines.add("    struct TypedListener : ListenerBase {")
  lines.add("        std::function<void(const T&)> fn;")
  lines.add("        explicit TypedListener(std::function<void(const T&)> f) : fn(std::move(f)) {}")
  lines.add("    };")
  lines.add("")
  lines.add("    struct WildcardListener : ListenerBase {")
  lines.add(
    "        std::function<void(int, const std::string&, std::span<const std::uint8_t>)> fn;"
  )
  lines.add(
    "        explicit WildcardListener(std::function<void(int, const std::string&, std::span<const std::uint8_t>)> f) : fn(std::move(f)) {}"
  )
  lines.add("    };")
  lines.add("")
  # Typed trampoline — one instantiation per payload type, all sharing a body.
  lines.add("    template <class T>")
  lines.add("    static void typedTrampoline(int ret, const char* msg, std::size_t len, void* ud) {")
  lines.add("        if (!ud || ret != 0 || !msg || len == 0) return;")
  lines.add("        auto* listener = static_cast<TypedListener<T>*>(ud);")
  lines.add("        if (!listener->fn) return;")
  lines.add("        CborParser parser; CborValue it;")
  lines.add(
    "        if (cbor_parser_init(reinterpret_cast<const std::uint8_t*>(msg), len, 0, &parser, &it) != CborNoError) return;"
  )
  lines.add("        if (!cbor_value_is_map(&it)) return;")
  lines.add("        CborValue payloadField;")
  lines.add(
    "        if (cbor_value_map_find_value(&it, \"payload\", &payloadField) != CborNoError) return;"
  )
  lines.add("        T payload{};")
  lines.add(
    "        if (decode_cbor(payloadField, payload) != CborNoError) return;"
  )
  lines.add("        listener->fn(payload);")
  lines.add("    }")
  lines.add("")
  # Wildcard trampoline — extracts `eventType` from the CBOR envelope so
  # the user can match on the event name without hand-parsing. Falls back
  # to an empty `eventId` if the envelope is missing, malformed, or the
  # FFI return code signals an error (in which case the bytes are an
  # error string, not a CBOR envelope).
  lines.add(
    "    static void wildcardTrampoline(int ret, const char* msg, std::size_t len, void* ud) {"
  )
  lines.add("        if (!ud) return;")
  lines.add("        auto* listener = static_cast<WildcardListener*>(ud);")
  lines.add("        if (!listener->fn) return;")
  # The buffer pointed to by `msg` is owned by the dylib and stays valid
  # for the duration of this synchronous call — safe to hand to the user
  # as a span view rather than copying.
  lines.add("        std::span<const std::uint8_t> envelope{};")
  lines.add("        if (msg && len > 0) {")
  lines.add(
    "            envelope = std::span<const std::uint8_t>(reinterpret_cast<const std::uint8_t*>(msg), len);"
  )
  lines.add("        }")
  lines.add("        std::string eventId;")
  lines.add("        if (ret == 0 && !envelope.empty()) {")
  lines.add("            CborParser parser; CborValue it;")
  lines.add(
    "            if (cbor_parser_init(envelope.data(), envelope.size(), 0, &parser, &it) == CborNoError"
  )
  lines.add("                && cbor_value_is_map(&it)) {")
  lines.add("                CborValue evtField;")
  lines.add(
    "                if (cbor_value_map_find_value(&it, \"eventType\", &evtField) == CborNoError"
  )
  lines.add("                    && cbor_value_is_text_string(&evtField)) {")
  lines.add("                    (void)decode_cbor(evtField, eventId);")
  lines.add("                }")
  lines.add("            }")
  lines.add("        }")
  lines.add("        listener->fn(ret, eventId, envelope);")
  lines.add("    }")
  lines.add("")

proc generateCppHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
): string =
  var lines: seq[string] = @[]

  lines.add(HeaderPreludeTpl)
  if events.len > 0:
    # Only pulled in when the library declares `{.ffiEvent.}` procs —
    # `<unordered_map>` backs the `listeners_` map, `<span>` is the
    # zero-copy view type handed to wildcard callbacks.
    lines.add("#include <unordered_map>")
    lines.add("#include <span>")

  # Result<T> is the exception-free return channel used by every generated
  # entry point. It must precede the CBOR helpers and sync-call helper below,
  # which now hand their failures back as Result rather than throwing.
  lines.add(ResultTpl)

  # CBOR primitive / container helpers must precede the per-struct codecs
  # below, because each emitted `encode_cbor`/`decode_cbor(T)` calls the
  # generic overloads for the struct's fields (std::string, std::vector,
  # std::optional, primitives). The struct codecs are non-template `inline`
  # functions, so name lookup happens at parse time — the overloads must be
  # in scope before the struct codecs are parsed.
  lines.add(CborHelpersTpl)

  # ── Types ──────────────────────────────────────────────────────────────────
  if types.len > 0:
    lines.add("// ============================================================")
    lines.add("// User-declared FFI types")
    lines.add("// ============================================================")
    lines.add("")
    for t in types:
      lines.add("struct $1 {" % [t.name])
      for f in t.fields:
        lines.add("    $1 $2;" % [nimTypeToCpp(f.typeName), f.name])
      lines.add("};")
      var fields: seq[(string, string)] = @[]
      for f in t.fields:
        fields.add((f.name, nimTypeToCpp(f.typeName)))
      emitStructCborCodec(lines, t.name, fields)
      lines.add("")

  # ── Per-proc Req structs (CBOR transport units) ───────────────────────────
  lines.add("// ============================================================")
  lines.add("// Per-proc request envelopes (CBOR encoded on the wire)")
  lines.add("// ============================================================")
  lines.add("")
  for p in procs:
    if p.kind == FFIKind.DTOR:
      continue
    let reqName = reqStructName(p)
    lines.add("struct $1 {" % [reqName])
    for ep in p.extraParams:
      let cppType =
        if ep.isPtr:
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      lines.add("    $1 $2;" % [cppType, ep.name])
    lines.add("};")
    var fields: seq[(string, string)] = @[]
    for ep in p.extraParams:
      let cppType =
        if ep.isPtr:
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      fields.add((ep.name, cppType))
    emitStructCborCodec(lines, reqName, fields)
    lines.add("")

  # ── C FFI declarations ─────────────────────────────────────────────────────
  lines.add("// ============================================================")
  lines.add("// C FFI declarations")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("extern \"C\" {")
  lines.add(
    "typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);"
  )
  lines.add("")
  for p in procs:
    case p.kind
    of FFIKind.FFI:
      # The C++ wrapper speaks CBOR, so it targets the `<name>_cbor` exports; the
      # bare `<name>` symbol is the native (typed-args) entry point.
      lines.add(
        "int $1_cbor(void* ctx, FFICallback callback, void* user_data, const uint8_t* req_cbor, size_t req_cbor_len);" %
          [p.procName]
      )
    of FFIKind.CTOR:
      lines.add(
        "void* $1_cbor(const uint8_t* req_cbor, size_t req_cbor_len, FFICallback callback, void* user_data);" %
          [p.procName]
      )
    of FFIKind.DTOR:
      # The destructor takes no request payload, so it has no `_cbor` variant.
      lines.add("int $1(void* ctx);" % [p.procName])
  # `declareLibrary` always exports the listener-registration ABI. Declare
  # it here so the typed event-handler wiring below can call into it.
  lines.add(
    "uint64_t $1_add_event_listener(void* ctx, const char* event_name, FFICallback callback, void* user_data);" %
      [libName]
  )
  lines.add(
    "int $1_remove_event_listener(void* ctx, uint64_t listener_id);" % [libName]
  )
  lines.add("} // extern \"C\"")
  lines.add("")

  lines.add(SyncCallHelperTpl)

  # ── Event-payload decoder helper ──────────────────────────────────────────
  # Lets wildcard-listener bodies lift the `payload` field out of a CBOR
  # envelope into any registered event type with a single call, e.g.
  #     EchoEvent evt;
  #     if (decodeEventPayload(envelope, evt)) { ... }
  # Relies on the per-struct `decode_cbor` codec emitted above.
  if events.len > 0:
    lines.add("template <class T>")
    lines.add(
      "inline bool decodeEventPayload(std::span<const std::uint8_t> envelope, T& out) {"
    )
    lines.add("    if (envelope.empty()) return false;")
    lines.add("    CborParser parser; CborValue it;")
    lines.add(
      "    if (cbor_parser_init(envelope.data(), envelope.size(), 0, &parser, &it) != CborNoError)"
    )
    lines.add("        return false;")
    lines.add("    if (!cbor_value_is_map(&it)) return false;")
    lines.add("    CborValue payloadField;")
    lines.add(
      "    if (cbor_value_map_find_value(&it, \"payload\", &payloadField) != CborNoError)"
    )
    lines.add("        return false;")
    lines.add("    return decode_cbor(payloadField, out) == CborNoError;")
    lines.add("}")
    lines.add("")

  # ── High-level C++ context class ──────────────────────────────────────────
  var ctors: seq[FFIProcMeta] = @[]
  var methods: seq[FFIProcMeta] = @[]
  for p in procs:
    case p.kind
    of FFIKind.CTOR:
      ctors.add(p)
    of FFIKind.FFI:
      methods.add(p)
    of FFIKind.DTOR:
      discard

  let libTypeName =
    if ctors.len > 0:
      ctors[0].libTypeName
    else:
      capitalizeFirstLetter(libName)

  let ctxTypeName = libTypeName & "Ctx"

  lines.add("// ============================================================")
  lines.add("// High-level C++ context class")
  lines.add("// ============================================================")
  lines.add("")
  lines.add("class $1 {" % [ctxTypeName])
  lines.add("public:")

  # ── Constructors ────────────────────────────────────────────────────────
  for ctor in ctors:
    let reqName = reqStructName(ctor)
    var ctorParams: seq[string] = @[]
    var epNames: seq[string] = @[]
    for ep in ctor.extraParams:
      let cppType =
        if ep.isPtr:
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      ctorParams.add("const $1& $2" % [cppType, ep.name])
      epNames.add(ep.name)
    let timeoutParam = "std::chrono::milliseconds timeout = std::chrono::seconds{30}"
    let ctorParamsWithTimeout =
      if ctorParams.len > 0:
        ctorParams.join(", ") & ", " & timeoutParam
      else:
        timeoutParam

    let reqInit = cppBracedInit(reqName, epNames)

    # Same `ffi_*_` underscore convention as instance methods so that a ctor
    # parameter cannot collide with the local Req envelope name.
    #
    # The ctor's C symbol returns `void*` (the ctx pointer) synchronously, but
    # `ffi_call_` expects an int-returning lambda — and we want the callback
    # path anyway since it carries the CBOR-encoded ctx address. Discard the
    # synchronous return and yield 0 from the lambda; the address comes back
    # through the callback's CBOR text-string payload.
    # `create` returns std::unique_ptr<Ctx> rather than a Ctx by value: the
    # context owns library threads, so we forbid copy/move on the class
    # itself (see ContextRuleOf5Tpl) and hand out ownership through a
    # smart pointer that callers can move, store in containers, etc.
    let createRet = "Result<std::unique_ptr<$1>>" % [ctxTypeName]
    lines.add(
      "    static $1 create($2) {" % [createRet, ctorParamsWithTimeout]
    )
    lines.add("        const auto ffi_req_ = $1;" % [reqInit])
    lines.add("        auto ffi_enc_ = encodeCborFFI(ffi_req_);")
    lines.add("        if (ffi_enc_.isErr()) return $1::err(ffi_enc_.error());" % [createRet])
    lines.add("        const auto& ffi_req_bytes_ = ffi_enc_.value();")
    lines.add("        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {")
    lines.add(
      "            (void)$1_cbor(ffi_req_bytes_.data(), ffi_req_bytes_.size(), cb, ud);" %
        [ctor.procName]
    )
    lines.add("            return 0;")
    lines.add("        }, timeout);")
    lines.add("        if (ffi_raw_.isErr()) return $1::err(ffi_raw_.error());" % [createRet])
    lines.add("        auto ffi_addr_ = decodeCborFFI<std::string>(ffi_raw_.value());")
    lines.add("        if (ffi_addr_.isErr()) return $1::err(ffi_addr_.error());" % [createRet])
    lines.add("        const auto& addr_str = ffi_addr_.value();")
    # Parse the ctx address without exceptions: std::stoull would throw on a
    # non-numeric payload, so use std::from_chars and surface the failure as
    # an err() Result instead.
    lines.add("        std::uint64_t addr = 0;")
    lines.add("        const char* addr_begin = addr_str.data();")
    lines.add("        const char* addr_end = addr_begin + addr_str.size();")
    lines.add("        const auto fc_ = std::from_chars(addr_begin, addr_end, addr);")
    lines.add("        if (fc_.ec != std::errc() || fc_.ptr != addr_end) {")
    lines.add(
      "            return $1::err(\"FFI create returned non-numeric address: \" + addr_str);" %
        [createRet]
    )
    lines.add("        }")
    # Use `new` directly (not std::make_unique) so the ctor can stay private.
    lines.add(
      "        return $1::ok(std::unique_ptr<$2>(new $2(reinterpret_cast<void*>(static_cast<uintptr_t>(addr)), timeout)));" %
        [createRet, ctxTypeName]
    )
    lines.add("    }")
    lines.add("")

    let captureList =
      if epNames.len > 0:
        epNames.join(", ") & ", timeout"
      else:
        "timeout"
    let callList =
      if epNames.len > 0:
        epNames.join(", ") & ", timeout"
      else:
        "timeout"
    lines.add(
      "    static std::future<Result<std::unique_ptr<$1>>> createAsync($2) {" %
        [ctxTypeName, ctorParamsWithTimeout]
    )
    lines.add(
      "        return std::async(std::launch::async, [$1]() { return create($2); });" %
        [captureList, callList]
    )
    lines.add("    }")
    lines.add("")

  # ── Rule of 5 ──────────────────────────────────────────────────────────
  lines.add(
    ContextRuleOf5Tpl.multiReplace(("{{CTX}}", ctxTypeName), ("{{LIB}}", libName))
  )

  # ── Typed event handlers (public section) ───────────────────────────────
  emitEventDispatcher(lines, ctxTypeName, libName, events)

  # ── Instance methods ────────────────────────────────────────────────────
  for m in methods:
    let methodName = stripLibPrefixCpp(m.procName, libName)
    let retCppType =
      if m.returnIsPtr:
        CppPtrType
      else:
        nimTypeToCpp(m.returnTypeName)
    let reqName = reqStructName(m)

    var methParams: seq[string] = @[]
    var methParamNames: seq[string] = @[]
    for ep in m.extraParams:
      let cppType =
        if ep.isPtr:
          CppPtrType
        else:
          nimTypeToCpp(ep.typeName)
      methParams.add("const $1& $2" % [cppType, ep.name])
      methParamNames.add(ep.name)
    let methParamsStr = methParams.join(", ")
    let methParamNamesStr = methParamNames.join(", ")

    let reqInit = cppBracedInit(reqName, methParamNames)

    let methRet = "Result<$1>" % [retCppType]
    # Use a single-underscore-suffixed local for the Req envelope so it can't
    # shadow a method parameter whose name happens to be `req` (or similar).
    lines.add("    $1 $2($3) const {" % [methRet, methodName, methParamsStr])
    lines.add("        const auto ffi_req_ = $1;" % [reqInit])
    lines.add("        auto ffi_enc_ = encodeCborFFI(ffi_req_);")
    lines.add("        if (ffi_enc_.isErr()) return $1::err(ffi_enc_.error());" % [methRet])
    lines.add("        const auto& ffi_req_bytes_ = ffi_enc_.value();")
    lines.add("        auto ffi_raw_ = ffi_call_([&](FFICallback cb, void* ud) {")
    lines.add(
      "            return $1_cbor(ptr_, cb, ud, ffi_req_bytes_.data(), ffi_req_bytes_.size());" %
        [m.procName]
    )
    lines.add("        }, timeout_);")
    lines.add("        if (ffi_raw_.isErr()) return $1::err(ffi_raw_.error());" % [methRet])
    lines.add("        return decodeCborFFI<$1>(ffi_raw_.value());" % [retCppType])
    lines.add("    }")
    lines.add("")
    # The async wrapper calls the sync method via `this->methodName(...)` so
    # a method param that happens to share the method's name doesn't shadow
    # the call target (e.g. `schedule(job, retry, schedule)` would otherwise
    # parse as invoking the `schedule` parameter).
    if methParamsStr.len > 0:
      lines.add(
        "    std::future<$1> $2Async($3) const {" %
          [methRet, methodName, methParamsStr]
      )
      lines.add(
        "        return std::async(std::launch::async, [this, $1]() { return this->$2($3); });" %
          [methParamNamesStr, methodName, methParamNamesStr]
      )
      lines.add("    }")
    else:
      lines.add("    std::future<$1> $2Async() const {" % [methRet, methodName])
      lines.add(
        "        return std::async(std::launch::async, [this]() { return this->$1(); });" %
          [methodName]
      )
      lines.add("    }")
    lines.add("")

  lines.add("private:")
  # Listener machinery (`ListenerBase`, `TypedListener<T>`,
  # `WildcardListener`, plus the static trampolines) must appear before
  # the `listeners_` data member declaration — C++ requires the value
  # type of a member to be complete at point of declaration. The public
  # add*/remove methods above also reference these types, but member
  # function bodies see the full class scope regardless of declaration
  # order, so emitting here is sufficient for both.
  emitEventTrampoline(lines, events)
  lines.add("    void* ptr_;")
  lines.add("    std::chrono::milliseconds timeout_;")
  if events.len > 0:
    # One owning entry per live listener, keyed by id. Destroyed after
    # the destructor body runs `<lib>_destroy(ptr_)`, by which point the
    # FFI side has joined its threads so no callback is mid-flight.
    lines.add(
      "    std::unordered_map<std::uint64_t, std::unique_ptr<ListenerBase>> listeners_;"
    )
  lines.add(
    "    explicit $1(void* p, std::chrono::milliseconds t) : ptr_(p), timeout_(t) {}" %
      [ctxTypeName]
  )
  lines.add("};")
  lines.add("")

  return lines.join("\n")

proc generateCppCMakeLists*(libName: string, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  return CMakeListsTpl.multiReplace(("{{LIB}}", libName), ("{{SRC}}", src))

proc generateCppBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
) =
  createDir(outputDir)
  writeFile(
    outputDir / (libName & ".hpp"),
    generateCppHeader(procs, types, libName, events),
  )
  writeFile(outputDir / "CMakeLists.txt", generateCppCMakeLists(libName, nimSrcRelPath))
