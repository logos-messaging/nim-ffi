import ffi
import ./ic_fixture_decl

proc icfixture_late(lib: IcFixture): Future[Result[string, string]] {.ffi.} =
  return ok("late")
