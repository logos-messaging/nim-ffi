import ffi

type NoDecl = object

proc nodecl_ping(lib: NoDecl): Future[Result[string, string]] {.ffi.} =
  return ok("pong")
