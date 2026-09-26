# host/ — the poll model from the host's side

`nim_ffi.h` is the C declaration of what a `-d:ffiPollMode` library hands a
host: `NimFfiMsg`, the `NIMFFI_MSG_*` kinds, the `NIMFFI_RET_*` codes and
`nimffi_name_id()`. It is kept in step with `ffi/ffi_msg.nim` and
`ffi/ret_codes.nim`.

`nim_ffi_host.hpp` is a header-only C++17 host for one context: bind the
library's five fixed exports into a `nim_ffi::Library`, then `create`, `call`,
`submit`, `reverseReply` and `drain`. It owns no thread; watch `fd()` from
your own event loop and call `drain()` when it is readable. Payloads are
bytes — decode them with the codec you already have.

```cpp
nim_ffi::Host host({my_create, my_destroy, my_poll, my_poll_fd, my_reverse_reply});
host.onReverseCall([&](uint64_t call, uint64_t name, const uint8_t* args, size_t len) {
  /* answer, from any thread: */ host.reverseReply(call, NIMFFI_RET_OK, cbor_bytes);
});
host.create(cbor_of({{"configJson", "{}"}}), 5s);
auto r = host.call(my_send, cbor_of({{"messageJson", msg}}), 30s);   // pumps meanwhile
```

`ffi/poll_host.nim` is the same host in Nim, for a Nim program that loaded a
poll-mode library or a library shipped inside a larger Nim image (a Logos
module, say) that calls its own exports from its host's thread. Bind the
exports by their C names into a `Library`, then `create`, `call`, `submit`,
`reverseReply`, `drain`; requests are `encode`d objects whose fields are the
export's parameter names, replies `decode` into the declared type.

```nim
import ffi/poll_host
proc myCreate(req: ptr byte, len: csize_t, ctxOut: ptr pointer, idOut: ptr uint64): cint {.importc: "my_create", cdecl.}
# ... my_destroy, my_poll, my_reverse_reply, my_send likewise
let host = newHost(Library(create: myCreate, destroy: myDestroy, poll: myPoll, reverseReply: myReverseReply),
                   onEvent = proc(nameId: uint64, payload: seq[byte]) {.gcsafe, raises: [].} = discard)
discard host.create(encode(CreateReq(configJson: "{}")), 5_000)
let r = host.call(mySend, encode(SendReq(messageJson: msg)), 30_000)   # pumps meanwhile
```
