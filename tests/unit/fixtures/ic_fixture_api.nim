import ffi
import ./ic_fixture_decl

type IcReply {.ffi.} = object
  text*: string

const IC_LIMIT {.ffiConst.} = 7

proc icfixture_create(): Future[Result[IcFixture, string]] {.ffiCtor.} =
  return ok(IcFixture())

proc icfixture_destroy(lib: IcFixture) {.ffiDtor.} =
  discard

proc icfixture_reply(
    lib: IcFixture, text: string
): Future[Result[IcReply, string]] {.ffi.} =
  return ok(IcReply(text: text))

proc icfixture_on_reply(reply: IcReply) {.ffiEvent: "on_reply".}

proc icfixture_open(lib: IcFixture): Future[Result[IcSession, string]] {.ffi.} =
  return ok(IcSession(id: 1))
