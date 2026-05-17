## Compile-time metadata types for FFI binding generation.
## Populated by the {.ffiCtor.} and {.ffi.} macros and consumed by codegen.

import std/strutils

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
    abiHash*: string
      # 7-char SHA-1 prefix of canonical signature; empty for dtors
      # ───────────────────────────────────────────────────────────────────
      # Content-addressable symbol versioning. When set, the exported C
      # symbol is named `<procName>_v<abiHash>` instead of just `<procName>`.
      # Computed by `abiHashFor()` from the proc's canonical signature
      # (param names + types, recursively for {.ffi.} types). Any layout
      # change to the proc's request type, response type, or nested types
      # produces a different hash → different symbol name → old consumers
      # get a loud `undefined symbol` at load time instead of silent UB
      # from a mismatched struct layout. Only populated for `ffiMode=raw`
      # procs (where the silent-UB risk lives); empty for `ffiMode=cbor` and
      # for dtors (whose signature is structurally invariant).

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

# ---------------------------------------------------------------------------
# Target selection — the framework offers a 2-knob matrix:
#
#   ffiMode   = raw | cbor    (default: cbor)
#               └─ How the data crosses the FFI boundary:
#                  `raw`  = **in-memory communication, no encode/decode**.
#                            Flat C structs travel by pointer through shared
#                            memory; consumer and library link into the same
#                            address space. Zero-copy-friendly, lowest cost
#                            per call. Cannot cross process boundaries.
#                  `cbor`  = **inter-process communication, CBOR on the wire**.
#                            Payloads are encoded as self-describing CBOR
#                            bytes that survive any byte-oriented transport
#                            (Unix socket, TCP, pipe, file). The right choice
#                            when the consumer may live in a different
#                            process or on a different host.
#
#   ffiLang   = cpp  | rust   (default: cpp)
#               └─ Consumer-side wrapper language to generate alongside the
#                  ABI. The .h emitted on `ffiMode=raw` is
#                  `extern "C"`-safe so both pure-C and C++ consumers can
#                  use it.
#
# Legal cells today:
#
#   ┌───────────┬───────────────┬───────────────┐
#   │ ffiMode \ │     cpp       │      rust     │
#   │   ffiLang │               │               │
#   ├───────────┼───────────────┼───────────────┤
#   │   cbor    │  ✅ ready     │  ✅ ready     │
#   │   raw    │  ✅ ready (h) │  🚧 todo      │
#   └───────────┴───────────────┴───────────────┘
# ---------------------------------------------------------------------------

const ffiMode* {.strdefine.} = "cbor" ## "raw" | "cbor"
const ffiLang* {.strdefine.} = "cpp" ## "cpp" | "rust"

# Output directory for generated bindings; set with -d:ffiOutputDir=path/to/dir
const ffiOutputDir* {.strdefine.} = ""

# Nim source path (relative to outputDir) embedded in generated build files;
# set with -d:ffiNimSrcRelPath=../relative/path.nim
const ffiNimSrcRelPath* {.strdefine.} = ""

proc effectiveMode*(): string {.compileTime.} =
  ## Returns the active ABI mode (always lowercased). Defaults to `cbor`.
  return ffiMode.toLowerAscii()

proc effectiveLang*(): string {.compileTime.} =
  ## Returns the active consumer-side wrapper language (always lowercased).
  ## Defaults to `cpp`.
  return ffiLang.toLowerAscii()

# ---------------------------------------------------------------------------
# Package version — single source of truth: ffi.nimble.
#
# Nimble auto-injects `-d:NimblePkgVersion=X.Y.Z` when building the package
# via `nimble`, which is the idiomatic way to surface the version. That
# strdefine is *not* injected when codegen runs through `exec "nim c …"`
# from a nimble task (as `nimble genbindings_c` does), so we fall back to
# parsing the nimble file directly — also at compile time, also a single
# source of truth.
# ---------------------------------------------------------------------------

const NimblePkgVersion* {.strdefine.} = ""

proc parseNimbleVersion(): string {.compileTime.} =
  const nimbleContent = staticRead("../../ffi.nimble")
  for line in nimbleContent.splitLines():
    let s = line.strip()
    if s.startsWith("version"):
      let eq = s.find('=')
      if eq >= 0:
        let rest = s[eq + 1 ..^ 1].strip()
        if rest.len >= 2 and rest[0] == '"' and rest[^1] == '"':
          return rest[1 ..^ 2]
  return "unknown"

const NimFFIVersion* =
  when NimblePkgVersion.len > 0:
    NimblePkgVersion
  else:
    parseNimbleVersion()

# ---------------------------------------------------------------------------
# ABI hash — content-addressable symbol versioning.
#
# The hash is derived from a canonical string representation of the proc's
# signature so that:
#
#   - Whitespace, comments, field reordering inside the *source* never
#     affect the hash (canonical form is order-stable on field declaration
#     order, type-stable on the resolved type names).
#   - Adding, removing, renaming, or changing the type of any field
#     (transitively through nested {.ffi.} types) *does* change the hash.
#   - The hash is stable across platforms and Nim versions (uses SHA-1 of
#     a deterministic UTF-8 string, not Nim's built-in `hash()` which is
#     not stable).
#
# Output is the first 7 hex chars of SHA-1, matching Git's short-hash
# convention.
# ---------------------------------------------------------------------------

const AbiHashPrefixLen* = 7

proc canonicalTypeName*(typeName: string, depth: int = 0): string {.compileTime.} =
  ## Canonical, recursively-expanded representation of a type for ABI
  ## hashing. Primitives map to themselves; `seq[T]` / `Option[T]` /
  ## `Maybe[T]` expand to `seq[<canonical T>]` etc.; nested {.ffi.} object
  ## types expand to `TypeName{field1:type1;field2:type2;...}` so the
  ## transitive shape is part of the hash. `Maybe` aliases to `Option` so
  ## the two read identically.
  if depth > 16:
    return "<recursive>"
  let t = typeName.strip()
  case t
  of "string", "cstring", "int", "int8", "int16", "int32", "int64", "uint", "uint8",
      "uint16", "uint32", "uint64", "bool", "float", "float32", "float64", "pointer",
      "void":
    return t
  else:
    discard
  if t.startsWith("seq[") and t.endsWith("]"):
    return "seq[" & canonicalTypeName(t[4 ..^ 2], depth + 1) & "]"
  if t.startsWith("Option[") and t.endsWith("]"):
    return "Option[" & canonicalTypeName(t[7 ..^ 2], depth + 1) & "]"
  if t.startsWith("Maybe[") and t.endsWith("]"):
    return "Option[" & canonicalTypeName(t[6 ..^ 2], depth + 1) & "]"
  if t.startsWith("ptr "):
    return "ptr" # all raw ptrs treated identically (opaque)
  # Look up a user-declared {.ffi.} type and expand its fields.
  for tm in ffiTypeRegistry:
    if tm.name == t:
      var fs = ""
      for i in 0 ..< tm.fields.len:
        if i > 0:
          fs &= ";"
        fs &=
          tm.fields[i].name & ":" & canonicalTypeName(tm.fields[i].typeName, depth + 1)
      return t & "{" & fs & "}"
  # Unknown type — pass through as-is. Reaching here usually means the
  # type wasn't tagged with {.ffi.} but is still referenced; that's a
  # user error elsewhere. Don't error, just include the name.
  return t

proc fnv1a64(s: string): uint64 {.compileTime.} =
  ## FNV-1a 64-bit hash. Pure Nim, evaluable in the compile-time VM
  ## (Nim 2.2's `std/sha1` reaches an `importc` intrinsic that the VM
  ## can't execute). Good enough as a fingerprint for distinguishing
  ## struct shapes — not a cryptographic primitive, but we're not
  ## defending against an adversary, just detecting drift.
  const Offset = 0xcbf29ce484222325'u64
  const Prime = 0x100000001b3'u64
  var h = Offset
  for c in s:
    h = h xor uint64(byte(c))
    h = h * Prime
  return h

proc toHexLower(value: uint64, width: int): string {.compileTime.} =
  ## Compile-time-safe hex formatter; pad to `width` chars, lowercase.
  const digits = "0123456789abcdef"
  var v = value
  var buf = newString(width)
  for i in countdown(width - 1, 0):
    buf[i] = digits[int(v and 0xf'u64)]
    v = v shr 4
  return buf

proc abiHashFor*(
    procName: string, extraParams: seq[FFIParamMeta], returnTypeName: string
): string {.compileTime.} =
  ## FNV-1a fingerprint of the proc's canonical signature. Returns a
  ## lowercase hex string of length `AbiHashPrefixLen`. Stable across
  ## platforms and Nim versions (the algorithm is a few lines of pure
  ## Nim) and deterministic for the same canonical form.
  var s = procName & "("
  for i in 0 ..< extraParams.len:
    if i > 0:
      s &= ","
    let pty =
      if extraParams[i].isPtr:
        "ptr"
      else:
        extraParams[i].typeName
    s &= extraParams[i].name & ":" & canonicalTypeName(pty)
  s &= "):" & canonicalTypeName(returnTypeName)
  return toHexLower(fnv1a64(s), AbiHashPrefixLen)
