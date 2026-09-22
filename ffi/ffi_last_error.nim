## Text of the last request the calling thread had refused. An export returns a
## code; `<lib>_last_error()` gives the words. A fixed thread-local buffer, so
## there is no ownership to hand over and nothing for the host to free.

const LastErrorCapacity = 256

var lastErrorBuf {.threadvar.}: array[LastErrorCapacity, char]

proc setLastError*(msg: string) {.raises: [], gcsafe.} =
  let n = min(msg.len, LastErrorCapacity - 1)
  if n > 0:
    copyMem(addr lastErrorBuf[0], unsafeAddr msg[0], n)
  lastErrorBuf[n] = '\0'

proc lastError*(): cstring {.raises: [], gcsafe.} =
  ## Never nil; empty when this thread had no refusal.
  return cast[cstring](addr lastErrorBuf[0])
