# C end-to-end test

Builds the generated C bindings for the timer example (`examples/timer/c_bindings`)
and drives them against the real Nim dylib, asserting on every response. Run it
with:

```sh
nimble test_c_e2e
```

which regenerates the bindings, configures CMake, builds, and runs the test via
`ctest`. The test program (`test_timer_e2e.c`) exercises the constructor, both
shapes of every request (the asynchronous one, answered inside
`my_timer_ctx_pump_once`, and the `_sync` one), nested `seq`/`Option` payloads,
multi-parameter requests, the error channel, a `_sync` timeout, several requests
in flight, a refused submit, the static requests, the raw exports with the typed
decoders, and the events, taken out with the pump or after a wait on the
`my_timer_ctx_poll_fd` handle. The binding starts no thread and neither does the
test: nothing is waited on but the pump. `test_echo_e2e.c` compiles and runs the
second generated header.

`test_timer_e2e.c` is hand-written (it is the consumer of the bindings, not a
generated artifact). The bindings under `examples/timer/c_bindings` are
generated and must not be edited by hand.
