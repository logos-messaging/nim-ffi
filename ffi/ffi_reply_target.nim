## Where a C export's answer goes. A callback host gets its refusal through the
## callback; a polling host gets the code back and the words from `lastError()`.
## One shape for both, so the generated exports do not fork on the mode.

import ./ffi_types, ./ffi_last_error, ./ret_codes

when defined(ffiPollMode):
  type ReplyTarget* = object
    reqId*: ptr uint64 ## Receives the id of the reply; nil when the host passed none.

  template replyTarget*(reqId, callback, userData: untyped): ReplyTarget =
    ## `callback` and `userData` are untyped: a poll-mode export has neither.
    ReplyTarget(reqId: reqId)

  proc missing*(t: ReplyTarget): bool =
    return false

  proc refuse*(t: ReplyTarget, msg: string) =
    ## Refuses the call before a request exists: no id, and the text says why.
    if not t.reqId.isNil():
      t.reqId[] = 0
    setLastError(msg)

  proc reject*(t: ReplyTarget, code: cint, msg: string): cint =
    t.refuse(msg)
    return code

else:
  type ReplyTarget* = object
    callback*: FFICallBack
    userData*: pointer

  template replyTarget*(reqId, callback, userData: untyped): ReplyTarget =
    ## `reqId` is untyped: a callback export has no id to hand back.
    ReplyTarget(callback: callback, userData: userData)

  proc missing*(t: ReplyTarget): bool =
    return t.callback.isNil()

  proc refuse*(t: ReplyTarget, msg: string) =
    ## Refuses the call before a request exists, through the callback.
    t.callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), t.userData)

  proc reject*(t: ReplyTarget, code: cint, msg: string): cint =
    t.refuse(msg)
    return RET_ERR
