# nim-ffi benchmarks: CBOR vs raw C

Two harnesses that compare the two FFI wire formats nim-ffi supports:

- `ffiMode=cbor` — self-describing CBOR bytes on every boundary crossing.
- `ffiMode=raw`  — flat C structs travel by shared-memory pointer; no
                   encode/decode pass.

## What's measured

### Microbench — `bench_codec.nim` (Nim, in-process)
Isolates **codec cost only**: just the encode/decode (cbor) or
pack/unpack (cwire) functions, with no FFI thread hop, no chronos
work, no callback dispatch. Useful as an upper bound on how much
faster `ffiMode=raw` can ever be for the codec layer.

```
nimble bench_codec
```

### E2E bench — `cpp_cbor/` + `c_raw/` (compiled binaries)
Measures the **full round-trip** through the FFI thread and chronos
event loop for each operation:

- `version_sync`    — sync body, no `await` (no FFI thread hop).
- `echo_0ms`        — async body with `sleepAsync(0)`.
- `complex_small`   — sync body, container-heavy payload.
- `schedule_3objs`  — async body with `sleepAsync(1.ms)` + 3 object params.
- `bytes_echo_<N>`  — sync echo of a `seq[byte]` of size N, swept across
                      sizes drawn from real consumers' wire payloads:
                      100 B (RPC envelopes), 1 KiB (typical chat),
                      10 KiB (fat pubsub message), 64 KiB (codex
                      Block.data default), 150 KiB
                      (`DefaultMaxWakuMessageSize`).

```
nimble bench_e2e            # build & run both, print comparison
tests/bench/run_bench.sh    # same thing, with iter-count overrides
```

The output is CSV (`op,mode,ns_per_op,iters`) plus a side-by-side
ratio table. The raw CSV is saved to `bench-results.csv` for
downstream tooling.

## Reading the numbers

Two contradicting trends show up across the size sweep, and they
matter for picking a mode:

- **Structured small objects** (strings, options, nested {.ffi.}
  types): raw is 7–12× faster than CBOR at the codec layer, 1.5–2×
  faster end-to-end. CBOR's per-field tagging overhead dominates.

- **Byte-blob payloads** (`seq[byte]`): codec-only is a near tie
  above ~1 KiB — both paths converge to memory bandwidth. But the
  **e2e gap widens with size** (1.5× at 100 B, ~3× at 64+ KiB)
  because the foreign-side CBOR encoder pays a growable-buffer cost
  the raw side doesn't.

What this means in practice for the consumers I checked:

| Consumer            | Typical payload | Likely cbor/raw gap |
| ------------------- | --------------- | ------------------- |
| logos-delivery      | 1–10 KiB        | ~1.7–2.5×           |
| nim-libp2p (pubsub) | 1–10 KiB        | ~1.7–2.5×           |
| logos-storage (codex block) | 64 KiB  | ~3×                 |

Worth it for the storage block path; marginal for sub-KiB control
traffic. The cost is structural rigidity — `ffiMode=raw` cannot cross
process boundaries.

## Reference: status-app ↔ status-go today

A useful baseline for picking a mode: how does status-app *currently*
talk to its Go-side messaging stack? The pattern is informative because
status-app is the largest Nim consumer of an embedded Go networking
stack, and any nim-ffi migration would replace this layer.

**Stack:** status-app (Nim/QML) → [nim-status-go](https://github.com/status-im/nim-status-go) (thin Nim wrapper)
→ status-go (compiled to `libstatus.{dylib,so,a}`) → status-go embeds
go-waku, the chat protocol, the wallet, etc. internally.

### Calls into status-go (request path)

- **Boundary type is `cstring`**, both directions. Every wrapped proc
  in [nim-status-go/status_go/impl.nim](https://github.com/status-im/nim-status-go/blob/master/status_go/impl.nim)
  imports a Go-side function whose params and return value are
  `cstring`-encoded JSON. The same `(jsonIn) -> jsonOut` shape regardless
  of method.

- **96 directly-exported mobile API functions** at the status-go side
  ([status-go/mobile/status.go](https://github.com/status-im/status-go/blob/develop/mobile/status.go)) —
  `InitializeApplication`, `Login`, `SendTransaction`, `CallRPC`,
  `CallPrivateRPC`, etc. These are the entry points the Nim wrapper
  binds directly with `importc`.

- **276+ wakuext methods** ride through one of those 96 — specifically
  `CallPrivateRPC(inputJSON)` ([status-go/services/ext/api.go](https://github.com/status-im/status-go/blob/develop/services/ext/api.go)).
  All Waku-adjacent functionality (chats, contacts, communities,
  messages, mailservers, syncing) is dispatched JSON-RPC style:
  status-app builds a `{"jsonrpc":"2.0","method":"wakuext_…","params":…}`
  envelope, passes it as one cstring, parses the cstring response.

So the active call surface is **one JSON-RPC fan-out point with
hundreds of virtual method names**, not hundreds of typed C-ABI
entry points.

### Parameter payload sizes (qualitative — not instrumented)

Untyped and method-dependent. Buckets I'd expect from reading the API:

- **Small (~100 B – 1 KiB):** the majority — `Chat(chatID)`,
  `LeaveGroupChat`, `MuteChat`, lookups, status updates. JSON-RPC
  envelope overhead is a meaningful fraction of these.
- **Medium (~1 – 10 KiB):** `SendChatMessage` (encrypted content +
  metadata), `CreateOneToOneChat` (request struct), most
  community/group ops.
- **Large (10 KiB – several MiB):** paged history — `ChatMessages`,
  `RequestAllHistoricMessages`, mailserver sync responses. These can
  return arrays of dozens-to-thousands of messages in one call.

### Events from status-go (notification path)

- **One callback slot.** Nim registers a single
  `SignalCallback = proc(signal: cstring): void {.cdecl.}` via
  `status_go.setSignalEventCallback`.

- **63+ distinct event types** share that slot. Listed across
  [status-go/signal/events_*.go](https://github.com/status-im/status-go/blob/develop/signal/) —
  `message.delivered`, `community.found`, `node.started`, `wakuv2.peerstats`,
  `wallet.event`, `sign-request.queued`, etc.

- **Wire format is a JSON envelope** ([signal/signals.go](https://github.com/status-im/status-go/blob/develop/signal/signals.go)):

  ```go
  type Envelope struct {
      Type      string      `json:"type"`       // e.g. "message.delivered"
      Event     interface{} `json:"event"`      // type-specific body
      Timestamp int64       `json:"timestamp"`
  }
  ```

  Nim receives the cstring, parses to JSON, dispatches on `.type`,
  then decodes `.event` into the type-specific struct. The discriminator
  is in-band; the framework provides no codegen for the per-type decode
  — each consumer hand-rolls it.

### How this maps to a nim-ffi migration

- The current status-app wire shape is **closest in spirit to
  `ffiMode=cbor`** — self-describing strings, single multiplexed entry
  point, tagged envelope events — just using JSON instead of CBOR. A
  cbor-mode nim-ffi version would be a wire-format upgrade (smaller +
  faster encode/decode) without a structural rearchitecture.

- `ffiMode=raw` would force a different shape: 276 typed C-ABI entry
  points instead of one JSON-RPC dispatcher, abi-hash symbol versioning
  forcing client rebuilds on every wakuext signature change. The
  process-boundary restriction is a non-issue today (status-go is
  in-process), but the API churn cost is large.

- The **paged-history call** is the only one where the raw-mode perf
  delta would visibly help. Everything else either fits the
  "structured small object" regime (1.5–2× e2e gap, in-process saves
  a few µs per call) or the "large byte-blob" regime (~3× e2e gap,
  but absolute time is already dominated by encryption / I/O).

- For events specifically: the existing pattern (tagged envelope, one
  callback, in-band discriminator) is *exactly* the "single tagged
  envelope, consumer dispatches" shape we discussed for the planned
  typed-FFI-events follow-up. JSON today, would become CBOR-bytes (in
  `cbor` mode) or a struct pointer (in `raw` mode) under nim-ffi —
  in either case still one callback slot.
