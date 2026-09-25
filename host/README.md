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
