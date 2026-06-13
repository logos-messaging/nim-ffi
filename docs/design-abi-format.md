# Design: ABI format selection (`raw` vs `cbor`)

Status: **direction decided, open for refinement.** How a library author tells the
compiler which wire format a boundary-crossing proc uses. Applies to the whole
pragma family (`{.ffi.}`, `{.ffiHost.}`, `{.ffiCtor.}`, `{.ffiDtor.}`).

## The two formats

- **`raw`** — native, zero-serialization C-POD ABI. Same-process; the request/
  result is a C struct passed/cast directly under the deep-copy +
  callback-lifetime ownership rule. The common path.
- **`cbor`** — CBOR-encoded buffer. For IPC / generic / cross-language callers
  where serialization is required anyway.

## Decision

**A1 — per-proc pragma argument** (chosen). The format is an argument on the
pragma, read by the macro at compile time:

```nim
proc echo(req: EchoReq): Future[Result[EchoResp, string]] {.ffi: raw.}
proc echo(req: EchoReq): Future[Result[EchoResp, string]] {.ffi: cbor.}

proc fetchProfile(id: string): Future[Result[Profile, string]] {.ffiHost: cbor.}
```

Matches the existing `{.ffiEvent: "wire_name".}` precedent (pragmas already take
args in this codebase). Local, granular, lets one library mix both formats.

**C2 — library-wide default** (chosen, layered on top). Set the default once at
`declareLibrary`; a per-proc pragma arg overrides it:

```nim
declareLibrary("my_app", MyApp, defaultAbiFormat = raw)
# every {.ffi.}/{.ffiHost.}/… is `raw` unless it says otherwise
```

So the common case stays terse, with per-proc control when needed.

**Rejected:**
- **Global compile flag** (`-d:ffiFormat=…`) — discarded. All-or-nothing,
  action-at-a-distance, can't mix formats in one library. `defaultAbiFormat`
  replaces its only virtue (a single default) without the downsides.
- Distinct pragma names (`{.ffiCbor.}`, `{.ffiHostCbor.}`) — combinatorial
  explosion across the pragma family.
- Format on the data type (`type T {.ffi: cbor.}`) — misattributes a transport
  property to the data; breaks when one type is used by both a raw and a cbor
  proc.

## Sketch

```nim
type AbiFormat* = enum
  raw    # native zero-serialization C-POD (same-process)
  cbor   # CBOR buffer (IPC / generic)

# two overloads, like ffiEvent: no-arg form defaults to the library default
macro ffi*(prc: untyped): untyped = ...                       # uses defaultAbiFormat
macro ffi*(fmt: static[AbiFormat], prc: untyped): untyped = ...  # explicit override
```

## Open questions (for further discussion)

- **Enum name / spelling.** `AbiFormat` with values `raw` / `cbor`? (`raw` over
  `native` per current preference.)
- **Resolution order.** proc pragma arg → `defaultAbiFormat` → built-in fallback
  (`raw`?). Confirm the fallback when `declareLibrary` sets no default.
- **Symbol emission.** Today `{.ffi.}` emits BOTH `<name>` and `<name>_cbor`. Does
  a per-proc format mean we emit only the chosen symbol, or keep emitting both
  and let the format arg pick the *primary*? (Leaning: emit only the chosen one;
  `<name>_cbor` suffix stays only when both are explicitly wanted.)
- **Codegen impact.** Each generator (c/go/cpp/rust/swift/kotlin) must honour the
  per-proc format when emitting wrappers + registration symbols.
- **Future A3.** Whether to later expose an orthogonal `{.ffi, wire: cbor.}`
  transport pragma that composes across the family (deferred; A1+C2 first).
