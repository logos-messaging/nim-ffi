## Unit tests for `{.ffiConst.}`: the per-backend rendering of a synthetic const
## registry, plus an end-to-end generation run over a fixture so the macro's own
## registration path is covered.

import std/[os, strutils]
import unittest2
import ./fixture_gen
import ffi/codegen/[meta, c, cpp, rust]

proc constMeta(name, typeName, value: string): FFIConstMeta =
  FFIConstMeta(name: name, typeName: typeName, value: value)

let consts = @[
  constMeta("maxPeers", "int", "42"),
  constMeta("DefaultTimeoutMs", "uint32", "3000"),
  constMeta("Ratio", "float64", "1.5"),
  constMeta("DebugEnabled", "bool", "false"),
  constMeta("Greeting", "string", "he\"llo\n"),
]

let ctor = FFIProcMeta(
  procName: "constlib_create",
  libName: "constlib",
  kind: FFIKind.CTOR,
  libTypeName: "ConstLib",
  returnTypeName: "ConstLib",
)

suite "constants in the C header":
  setup:
    let header = generateCLibHeader(@[ctor], @[], "constlib", @[], consts)

  test "scalars become typed static consts under an UPPER_SNAKE name":
    check "static const int64_t MAX_PEERS = 42;" in header
    check "static const uint32_t DEFAULT_TIMEOUT_MS = 3000;" in header
    check "static const double RATIO = 1.5;" in header
    check "static const bool DEBUG_ENABLED = false;" in header

  test "strings become const char* with escapes applied":
    check "static const char* const GREETING = \"he\\\"llo\\n\";" in header

  test "no constants means no constants section":
    let bare = generateCLibHeader(@[ctor], @[], "constlib")
    check "Generated constants" notin bare

suite "constants in the abi = c header":
  test "the CBOR-free header carries the same declarations":
    let cabiCtor = FFIProcMeta(
      procName: "constlib_create",
      libName: "constlib",
      kind: FFIKind.CTOR,
      libTypeName: "ConstLib",
      returnTypeName: "ConstLib",
      abiFormat: ABIFormat.C,
    )
    let header = generateCAbiLibHeader(@[cabiCtor], @[], "constlib", @[], consts)
    check "static const int64_t MAX_PEERS = 42;" in header
    check "static const char* const GREETING = \"he\\\"llo\\n\";" in header

suite "constants in the C++ header":
  setup:
    let header = generateCppHeader(@[ctor], @[], "constlib", @[], consts)

  test "constexpr, not static const":
    check "constexpr int64_t MAX_PEERS = 42;" in header
    check "constexpr bool DEBUG_ENABLED = false;" in header

  test "a string const is a const char*, not std::string":
    check "constexpr const char* GREETING = \"he\\\"llo\\n\";" in header

suite "constants in the Rust crate":
  setup:
    let typesRs = generateTypesRs(@[], @[ctor], consts)

  test "pub const with the mapped Rust type":
    check "pub const MAX_PEERS: i64 = 42;" in typesRs
    check "pub const DEFAULT_TIMEOUT_MS: u32 = 3000;" in typesRs
    check "pub const RATIO: f64 = 1.5;" in typesRs

  test "a string const is a &str, without the redundant 'static":
    check "pub const GREETING: &str = \"he\\\"llo\\n\";" in typesRs

suite "{.ffiConst.} end-to-end generation":
  test "the C header carries every annotated const, computed values included":
    let (outDir, _, code) = genFixtureBindings("consts_fixture", "c")
    require code == 0
    let header = readFile(outDir / "constlib.h")
    check "static const int64_t MAX_PEERS = 42;" in header
    # `3 * 1000` is evaluated before it reaches the registry.
    check "static const uint32_t DEFAULT_TIMEOUT_MS = 3000;" in header
    check "static const double RATIO = 1.5;" in header
    check "static const bool DEBUG_ENABLED = false;" in header
    check "static const char* const GREETING = \"he\\\"llo\\n\";" in header
    check "static const int64_t HTTP_PORT = 8080;" in header

  test "the Rust crate carries them too":
    let (outDir, _, code) = genFixtureBindings("consts_fixture", "rust")
    require code == 0
    let typesRs = readFile(outDir / "src" / "types.rs")
    check "pub const MAX_PEERS: i64 = 42;" in typesRs
    check "pub const DEFAULT_TIMEOUT_MS: u32 = 3000;" in typesRs
    check "pub const RATIO: f64 = 1.5;" in typesRs
    check "pub const DEBUG_ENABLED: bool = false;" in typesRs
    check "pub const GREETING: &str = \"he\\\"llo\\n\";" in typesRs
    check "pub const HTTP_PORT: i64 = 8080;" in typesRs
