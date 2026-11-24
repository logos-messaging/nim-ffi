## Payloads of the liveness events every library emits; codegen types them in each binding.
## Both reasons can be active at once; a host tracks the state per `reason`, and is healthy only when no reason is active.

type
  NotRespondingReason* {.pure.} = enum
    heartbeat ## the FFI thread stopped advancing its heartbeat
    queueFull ## event-queue overflow went on past `EventOverflowSustainMs`

  NotRespondingEvent* = object
    reason*: NotRespondingReason

  RespondingEvent* = object
    reason*: NotRespondingReason ## the reason of the `not_responding` it ends

const
  NotRespondingEventName* = "not_responding"
  RespondingEventName* = "responding"
