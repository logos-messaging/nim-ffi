import ffi

type IcFixture* = object

declareLibrary("icfixture", IcFixture)

type IcSession* {.ffiHandle.} = ref object
  id*: int
