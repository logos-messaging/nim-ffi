## Must compile: declareLibrary accepts the `ABIFormat` enum for defaultABIFormat,
## so `defaultABIFormat = ABIFormat.C` resolves the enum overload rather than the
## `static[string]` one.

import ffi, chronos
import ffi/codegen/meta

type EnumLib = object
  n: int

# Stub the importc NimMain declareLibrary emits (plain-exe link).
{.emit: "void libenumabiNimMain(void) {}".}

declareLibrary("enumabi", EnumLib, defaultABIFormat = ABIFormat.C)

static:
  doAssert currentDefaultABIFormat == ABIFormat.C

type EnumCfg {.ffi.} = object
  n: int

proc enumabi_create*(c: EnumCfg): Future[Result[EnumLib, string]] {.ffiCtor.} =
  return ok(EnumLib(n: c.n))

proc enumabi_destroy*(lib: EnumLib) {.ffiDtor.} =
  discard

genBindings()
