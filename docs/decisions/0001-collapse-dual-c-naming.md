# 0001 — Collapse the dual C naming layers (deferred to a future major)

- Status: Accepted, deferred (not scheduled)
- Scope: `-d:targetLang=c` header generator (`ffi/codegen/c.nim`)
- Affected consumers: cbind (primary), any downstream linking the generated `<lib>.h`

## Context

The generated C header exposes every method under **two** names for the same
call:

1. **Raw C ABI exports** — the actual symbols the Nim dylib exports, e.g.
   `my_timer_create`, `my_timer_echo`, `my_timer_destroy`,
   `my_timer_add_event_listener`. They take an opaque CBOR buffer
   (`const uint8_t* req_cbor, size_t req_cbor_len`) plus an `FFICallback`, and do
   no marshaling. Declared in the `extern "C"` block of the header.
2. **`_ctx_` convenience wrappers** — `static inline` functions in the same
   header, e.g. `my_timer_ctx_create`, `my_timer_ctx_echo`,
   `my_timer_ctx_destroy`, `my_timer_ctx_add_on_echo_fired_listener`. They take
   typed structs, own and reclaim the CBOR buffers and reply/error strings, and
   manage the `MyTimerCtx` handle plus its listener registry. This is the API a
   human is meant to call.

Two problems follow from shipping both as public surface:

- **Redundancy.** Every method appears twice in the header; the raw name is a
  footgun (call it directly and you own the marshaling and the wire contract by
  hand), yet it sits at the same visibility as the wrapper meant for use.
- **The POSIX collision landmine.** The raw layer's names are
  `<libname>_<method>`. The `<libname>` prefix is the *only* guard against
  colliding with libc/POSIX symbols — nothing in the generator enforces a safe
  prefix. A library named `timer` would export `timer_create`, which collides
  with POSIX `<time.h>`'s `int timer_create(clockid_t, ...)` that `<pthread.h>`
  transitively drags in on Linux. Today this is dodged only by user naming
  discipline, documented in a single place: `examples/timer/timer.nim:6-9`
  (the example type is deliberately `MyTimer`, not `Timer`).

## Decision

Keep both layers for now. Breaking the generated output *is* acceptable, so when
the next breaking major is cut, collapse the public surface to the `_ctx_` layer
(or a configurable symbol prefix). This is recorded, not scheduled — no code
change lands with this document.

Nuance for whoever implements it: the raw symbols cannot simply be deleted from
the header. The `static inline` wrappers call them directly, so their
declarations must remain visible for the header to compile and link. "Expose
only the `_ctx_` layer" therefore means one of:

- **Demote, don't delete.** Move the raw `extern "C"` declarations into a
  clearly-internal section (or a separate `<lib>_internal.h`) marked "do not call
  directly — use the `<lib>_ctx_*` API". The wrappers still link; the advertised
  surface is just the typed layer. Cheapest change; does *not* fix the POSIX
  collision, since the raw symbols keep their bare `<libname>_<method>` names.
- **Configurable prefix (preferred fix for the collision).** Give the raw dylib
  symbols a fixed, namespaced prefix (e.g. `nimffi_<lib>_<method>`) so they can
  never shadow a libc/POSIX name, and reserve the clean `<lib>_ctx_*` names for
  the public API. This kills the landmine at its root rather than relying on the
  user picking a non-colliding library name. Requires a matching prefix change
  wherever the dylib symbols are declared/exported and in every downstream that
  links them.

## Migration notes (cbind)

cbind links the generated header directly and is the consumer that a collapse
breaks. Before cutting the major:

- Audit whether cbind calls any raw `<lib>_*` symbol directly or goes exclusively
  through the `<lib>_ctx_*` wrappers. Only the former needs source changes.
- If the configurable-prefix route is chosen, cbind's symbol references (and any
  `dlsym`/link-time lookups) must move to the new prefix in lockstep with the
  generator bump.
- Ship the generator change and the cbind change as a coordinated pair, and note
  the renamed/removed symbols in the CHANGELOG's breaking-changes section.

## Consequences

- No behavior change today; this is a forward-looking commitment.
- The generator keeps emitting both layers until the major, so existing
  integrations are untouched.
- The POSIX-collision rationale is centralized here; the README warns briefly
  and `ffi/codegen/c.nim` points back to this record at both emission sites, so
  the deferred plan is discoverable from the code without re-explaining it there.
