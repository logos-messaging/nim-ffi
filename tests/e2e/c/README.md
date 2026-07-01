# C end-to-end test

Builds the generated C bindings for the timer example (`examples/timer/c_bindings`)
and drives them against the real Nim dylib, asserting on every response. Run it
with:

```sh
nimble test_c_e2e
```

which regenerates the bindings, configures CMake, builds, and runs the test via
`ctest`. The test program (`test_timer_e2e.c`) exercises the constructor, the
sync and async methods, nested `seq`/`Option` payloads, multi-parameter
requests, the error channel, and the typed event listener.

`test_timer_e2e.c` is hand-written (it is the consumer of the bindings, not a
generated artifact). The bindings under `examples/timer/c_bindings` are
generated and must not be edited by hand.
