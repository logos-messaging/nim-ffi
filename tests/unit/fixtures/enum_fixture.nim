## Compile fixture for `{.ffi.}` enum binding generation (see
## tests/unit/test_ffi_enum.nim): a plain enum, one with associated strings and
## one with explicit ordinals, used as a field and as a param/return type.

import ffi, chronos

type EnumLib = object
  calls: int

declareLibrary("enumlib", EnumLib)

type
  Color {.ffi.} = enum
    cRed
    cGreen
    cBlue

  Level {.ffi.} = enum
    lLow = "low"
    lHigh = "high"

  Status {.ffi.} = enum
    stIdle = 2
    stBusy = 7

type PaintRequest {.ffi.} = object
  color: Color
  level: Level

type PaintResponse {.ffi.} = object
  status: Status
  applied: Color

proc enumlib_create*(): Future[Result[EnumLib, string]] {.ffiCtor.} =
  return ok(EnumLib(calls: 0))

proc enumlib_paint*(
    lib: EnumLib, req: PaintRequest
): Future[Result[PaintResponse, string]] {.ffi.} =
  return ok(PaintResponse(status: stBusy, applied: req.color))

proc enumlib_pick*(lib: EnumLib, level: Level): Future[Result[Color, string]] {.ffi.} =
  return ok(if level == lHigh: cBlue else: cRed)

proc enumlib_destroy*(lib: EnumLib) {.ffiDtor.} =
  discard

genBindings()
