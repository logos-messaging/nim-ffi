## The poll model from the host's side, in Nim.
##
## For a Nim host of a `-d:ffiPollMode` library: a program that loaded one,
## or a library shipped inside a larger Nim image -- a Logos module, say --
## that calls its own exports from the thread the image's host dispatches
## on. The Nim twin of `host/nim_ffi_host.hpp`: it owns no thread. A call
## submits a request and pumps the context on the calling thread until that
## reply, handing whatever arrives meanwhile -- events, the library's own
## questions -- to the handlers, so a reverse call the library needs answered
## before it can reply is served from inside the wait.
##
## One host per context, used from one thread at a time; `reverseReply` alone
## may be called from any thread. Payloads are bytes as the library produced
## them: a reply's CBOR value or its UTF-8 error text, an event's body, a
## reverse call's CBOR arguments. The exports are bound by their C names, so a
## host depends on the ABI and not on how the library was built.

import std/[macros, sets, tables]
import results
import ./ffi_msg, ./ret_codes
import cbor_serialization
import ./cbor_serial

export ret_codes

type
  Ctx* = pointer ## The library's context token.
  CtorFn* = proc(req: ptr byte, len: csize_t, ctxOut: ptr pointer, idOut: ptr uint64): cint {.cdecl, gcsafe, raises: [].}
    ## `<lib>_<ctor>`: hands the context out at once; its reply says whether it came up.
  MethodFn* = proc(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.cdecl, gcsafe, raises: [].}
    ## Any `{.ffi.}` export: the request is a CBOR map keyed by its parameter names.
  DestroyFn* = proc(ctx: pointer): cint {.cdecl, gcsafe, raises: [].}
  PollFn* = proc(ctx: pointer, timeoutMs: int32, msg: ptr ptr NimFfiMsg): cint {.cdecl, gcsafe, raises: [].}
  ReverseReplyFn* = proc(
    ctx: pointer, callId: uint64, retCode: cint, payload: ptr byte, len: csize_t
  ): cint {.cdecl, gcsafe, raises: [].}

  Library* = object
    ## The fixed exports of one library, by their C names.
    create*: CtorFn
    destroy*: DestroyFn
    poll*: PollFn
    reverseReply*: ReverseReplyFn ## nil for a library that asks nothing back

  Reply* = object
    ret*: cint
    payload*: seq[byte] ## RET_OK: the reply's CBOR value
    error*: string ## otherwise the library's text

  EventHandler* = proc(nameId: uint64, payload: seq[byte]) {.gcsafe, raises: [].}
    ## `nameId` is `nameId(wireName)` of the event's name.
  ReverseHandler* = proc(callId, nameId: uint64, args: seq[byte]) {.gcsafe, raises: [].}
    ## Answer with `reverseReply`, from this thread or another.

  Host* = ref object
    lib: Library
    ctx: Ctx
    onEvent*: EventHandler
    onReverseCall*: ReverseHandler
    timeoutMs*: int ## what a call waits for its reply when it names no deadline
    settled: Table[uint64, Reply] # replies read before their caller asked
    unwaited: HashSet[uint64] # submitted with no one waiting: their replies are dropped
    closed: bool

const
  SliceMs = 50'i32 # one poll; the deadline is checked between slices
  HostDefault* = -1 ## for `timeoutMs`: the host's own

# --- binding exports by their C names ------------------------------------------
# A library's exports are `exportc` procs that keep the Nim name of the proc
# they wrap, so from Nim the name is ambiguous and the C-shaped overload has to
# be picked by type. These spell the shape once; a caller names the symbol.
# The linker resolves it, whether the library is a loaded image or this one.

template importCtor*(name: static string): CtorFn =
  block:
    proc bound(req: ptr byte, len: csize_t, ctxOut: ptr pointer, idOut: ptr uint64): cint
      {.importc: name, cdecl, gcsafe, raises: [].}
    CtorFn(bound)

template importMethod*(name: static string): MethodFn =
  block:
    proc bound(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint
      {.importc: name, cdecl, gcsafe, raises: [].}
    MethodFn(bound)

template importDestroy*(name: static string): DestroyFn =
  block:
    proc bound(ctx: pointer): cint {.importc: name, cdecl, gcsafe, raises: [].}
    DestroyFn(bound)

template importPoll*(name: static string): PollFn =
  block:
    proc bound(ctx: pointer, timeoutMs: int32, msg: ptr ptr NimFfiMsg): cint
      {.importc: name, cdecl, gcsafe, raises: [].}
    PollFn(bound)

template importReverseReply*(name: static string): ReverseReplyFn =
  block:
    proc bound(ctx: pointer, callId: uint64, retCode: cint, payload: ptr byte, len: csize_t): cint
      {.importc: name, cdecl, gcsafe, raises: [].}
    ReverseReplyFn(bound)

template importLibrary*(prefix: static string, ctor: static string): Library =
  ## The fixed exports of the library declared as `declareLibrary(prefix, ...)`,
  ## plus its `{.ffiCtor.}`, which has a name of its own.
  Library(
    create: importCtor(ctor),
    destroy: importDestroy(prefix & "_destroy"),
    poll: importPoll(prefix & "_poll"),
    reverseReply: importReverseReply(prefix & "_reverse_reply"),
  )

proc newHost*(
    lib: Library,
    onEvent: EventHandler = nil,
    onReverseCall: ReverseHandler = nil,
    timeoutMs = 30_000,
): Host =
  return Host(lib: lib, onEvent: onEvent, onReverseCall: onReverseCall, timeoutMs: timeoutMs)

proc deadline(host: Host, timeoutMs: int): int =
  return if timeoutMs == HostDefault: host.timeoutMs else: timeoutMs

macro request*(fields: untyped): seq[byte] =
  ## The request of a `{.ffi.}` export, from `{"param": value, ...}`: a CBOR
  ## map keyed by the export's parameter names, the values whatever
  ## cbor_serialization writes. `request({})` is a no-parameter export's.
  if fields.kind notin {nnkTableConstr, nnkCurly}:
    error("request takes {\"param\": value, ...}", fields)
  let typ = genSym(nskType, "Request")
  var fieldDefs = newNimNode(nnkRecList)
  var ctor = newTree(nnkObjConstr, typ)
  for f in fields:
    if f.kind != nnkExprColonExpr or f[0].kind != nnkStrLit:
      error("request takes {\"param\": value, ...}", f)
    let name = ident(f[0].strVal)
    fieldDefs.add(newIdentDefs(name, newCall(ident("typeof"), f[1])))
    ctor.add(newTree(nnkExprColonExpr, name, f[1]))
  let typeDef = newTree(
    nnkTypeSection,
    newTree(
      nnkTypeDef, typ, newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), fieldDefs),
    ),
  )
  return quote do:
    block:
      `typeDef`
      cborEncode(`ctor`)

proc ctx*(host: Host): Ctx =
  return host.ctx

proc bytesOf(m: ptr NimFfiMsg): seq[byte] =
  var bytes = newSeq[byte](int(m.len))
  if m.len > 0:
    copyMem(addr bytes[0], m.payload, int(m.len))
  return bytes

proc decodeReply(m: ptr NimFfiMsg): Reply =
  var r = Reply(ret: m.retCode.cint)
  if m.retCode == RET_OK:
    r.payload = bytesOf(m)
  elif m.len > 0:
    r.error = newString(int(m.len))
    copyMem(addr r.error[0], m.payload, int(m.len))
  return r

proc reverseReply*(
    host: Host, callId: uint64, ret: cint, payload: openArray[byte]
): cint {.gcsafe, raises: [].} =
  ## Answers a reverse call. `payload` is the reply's CBOR value on RET_OK, the
  ## error text otherwise.
  if host.lib.reverseReply.isNil or host.ctx.isNil:
    return RET_ERR
  return host.lib.reverseReply(
    host.ctx, callId, ret, if payload.len > 0: unsafeAddr payload[0] else: nil,
    csize_t(payload.len),
  )

proc reverseReply*(
    host: Host, callId: uint64, ret: cint, text: string
): cint {.gcsafe, raises: [].} =
  return host.reverseReply(callId, ret, text.toOpenArrayByte(0, text.len - 1))

proc dispatch(host: Host, m: ptr NimFfiMsg) =
  case m.kind
  of MsgReply:
    if m.id in host.unwaited:
      host.unwaited.excl(m.id)
    else:
      host.settled[m.id] = decodeReply(m)
  of MsgEvent:
    if not host.onEvent.isNil:
      host.onEvent(m.nameId, bytesOf(m))
  of MsgReverseCall:
    if not host.onReverseCall.isNil:
      host.onReverseCall(m.id, m.nameId, bytesOf(m))
    else:
      discard host.reverseReply(m.id, RET_ERR, "no handler for reverse calls")
  of MsgClosed:
    host.closed = true
  else:
    discard # STALE_WARN and the liveness ticks: the deadline decides

proc drain*(host: Host) =
  ## Reads everything already queued, without waiting. For a host with an
  ## event loop of its own, when `<lib>_poll_fd` is readable.
  if host.ctx.isNil:
    return
  while not host.closed:
    var m: ptr NimFfiMsg = nil
    if host.lib.poll(host.ctx, 0'i32, addr m) != RET_OK or m.isNil:
      return
    host.dispatch(m)

proc waitFor*(host: Host, id: uint64, timeoutMs = HostDefault): Reply =
  ## Pumps the context on the calling thread until reply `id`, or the deadline.
  let timeoutMs = host.deadline(timeoutMs)
  var left = timeoutMs
  while true:
    if host.settled.hasKey(id):
      let r = host.settled[id]
      host.settled.del(id)
      return r
    if host.closed:
      return Reply(ret: RET_ERR, error: "the context is closed")
    if left <= 0:
      return Reply(ret: RET_TIMEOUT, error: "no reply within " & $timeoutMs & " ms")
    var m: ptr NimFfiMsg = nil
    let slice = min(left, int(SliceMs))
    let rc = host.lib.poll(host.ctx, int32(slice), addr m)
    if rc == RET_OK and not m.isNil:
      host.dispatch(m)
    elif rc == RET_TIMEOUT:
      left -= slice
    elif rc != RET_OK:
      return Reply(ret: rc, error: "poll rc=" & $rc)

proc create*(host: Host, req: openArray[byte], timeoutMs = HostDefault): Result[void, string] =
  ## Runs the constructor and waits for its reply: the host holds the context
  ## from here on. On failure the context is destroyed again.
  if not host.ctx.isNil:
    return err("the host already holds a context")
  var ctx: pointer = nil
  var id: uint64 = 0
  let rc = host.lib.create(
    if req.len > 0: unsafeAddr req[0] else: nil, csize_t(req.len), addr ctx, addr id
  )
  if rc != RET_OK or ctx.isNil:
    return err("constructor not accepted, rc=" & $rc)
  host.ctx = ctx
  host.closed = false
  let ready = host.waitFor(id, timeoutMs)
  if ready.ret != RET_OK:
    discard host.lib.destroy(ctx)
    host.ctx = nil
    return err(if ready.error.len > 0: ready.error else: "rc=" & $ready.ret)
  return ok()

proc destroy*(host: Host) =
  if not host.ctx.isNil:
    discard host.lib.destroy(host.ctx)
    host.ctx = nil
  host.settled.clear()
  host.unwaited.clear()

proc submit*(host: Host, m: MethodFn, req: openArray[byte]): Result[void, string] =
  ## Submits without waiting: the reply, when it comes, is dropped. For a call
  ## whose outcome the library reports as an event.
  if host.ctx.isNil:
    return err("no context")
  var id: uint64 = 0
  let rc = m(host.ctx, if req.len > 0: unsafeAddr req[0] else: nil, csize_t(req.len), addr id)
  if rc != RET_OK:
    return err("not accepted, rc=" & $rc)
  host.unwaited.incl(id)
  return ok()

proc call*(host: Host, m: MethodFn, req: openArray[byte], timeoutMs = HostDefault): Reply =
  ## Submits and pumps until the reply.
  if host.ctx.isNil:
    return Reply(ret: RET_ERR, error: "no context")
  var id: uint64 = 0
  let rc = m(host.ctx, if req.len > 0: unsafeAddr req[0] else: nil, csize_t(req.len), addr id)
  if rc != RET_OK:
    return Reply(ret: rc, error: "not accepted, rc=" & $rc)
  return host.waitFor(id, timeoutMs)

template submit*(host: Host, name: static string, req: openArray[byte]): Result[void, string] =
  ## `submit` of the export named `name`.
  submit(host, importMethod(name), req)

template call*(host: Host, name: static string, req: openArray[byte], timeoutMs = HostDefault): Reply =
  ## `call` of the export named `name`.
  call(host, importMethod(name), req, timeoutMs)

proc encode*[T](req: T): seq[byte] =
  ## A request: a CBOR map keyed by the export's parameter names, i.e. the
  ## fields of `req`. An object with no fields is the empty request.
  return cborEncode(req)

proc failure(r: Reply): string =
  return if r.error.len > 0: r.error else: "rc=" & $r.ret

proc outcome*(r: Reply): Result[void, string] =
  ## Whether the call succeeded, for a reply whose value means nothing to the caller.
  return if r.ret == RET_OK: ok() else: err(r.failure)

proc decode*(r: Reply, T: typedesc): Result[T, string] =
  ## The value of a RET_OK reply.
  if r.ret != RET_OK:
    return err(r.failure)
  return cborDecode(r.payload, T)
