## The message `<lib>_poll` hands to the host, and the numeric names it carries.
## Single source of the C and Rust declarations, like `ret_codes`.

import std/strutils

type NimFfiMsg* {.bycopy.} = object
  ## `poll` hands out a pointer to it. Owned by the library and valid until the
  ## next poll on the same context.
  structSize*: uint32 ## `sizeof(NimFfiMsg)` of the library; fields are only appended.
  kind*: uint32
  seqNum*: uint64 ## Production order within the context.
  id*: uint64 ## Reply, Stale: the request id. Otherwise 0.
  nameId*: uint64 ## Event: `nameId` of its wire name. Otherwise 0.
  durationMs*: uint64
    ## Stale: how long the request has been in flight. ReverseCall: how long the
    ## host has left to answer it. Otherwise 0.
  retCode*: int32 ## Reply, Closed: RET_OK or RET_ERR. Otherwise 0.
  flags*: uint32 ## Reserved for per-message bits; zero today.
  payload*: pointer
    ## The bare CBOR value; the UTF-8 error text of a RET_ERR. Never nil, even when `len` is 0.
  len*: csize_t

type MsgKind* = object
  name*: string
  value*: uint32
  doc*: string

const
  MsgReply* = 1'u32
  MsgEvent* = 2'u32
  MsgStale* = 3'u32
  MsgReverseCall* = 4'u32
  MsgNotRespondingHeartbeat* = 5'u32
  MsgResponding* = 6'u32
  MsgClosed* = 7'u32
  MsgNotRespondingQueueFull* = 8'u32

const MsgKinds* = [
  MsgKind(
    name: "REPLY",
    value: MsgReply,
    doc: "id is the request; ret_code OK: payload is its CBOR, ERR: UTF-8 text",
  ),
  MsgKind(
    name: "STALE",
    value: MsgStale,
    doc:
      "request id is still running; duration_ms is the ms in flight, and its REPLY still comes",
  ),
  MsgKind(name: "EVENT", value: MsgEvent, doc: "name_id names it; payload is its CBOR"),
  MsgKind(
    name: "REVERSE_CALL",
    value: MsgReverseCall,
    doc: "the library asks: answer id with <lib>_reverse_reply within duration_ms",
  ),
  MsgKind(
    name: "NOT_RESPONDING_HEARTBEAT",
    value: MsgNotRespondingHeartbeat,
    doc: "the FFI thread's heartbeat stalled",
  ),
  MsgKind(
    name: "NOT_RESPONDING_QUEUE_FULL",
    value: MsgNotRespondingQueueFull,
    doc:
      "the event queue overflowed; requests are refused until the context is recycled",
  ),
  MsgKind(
    name: "RESPONDING", value: MsgResponding, doc: "the FFI thread's heartbeat resumed"
  ),
  MsgKind(
    name: "CLOSED", value: MsgClosed, doc: "the context is gone; every later poll fails"
  ),
]

func nameId*(wireName: string): uint64 =
  ## FNV-1a 64 of the wire name: what a message carries instead of the string.
  var h = 0xcbf29ce484222325'u64
  for c in wireName:
    h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  return h

func nameIdLiteral*(wireName: string): string =
  return "0x" & toHex(nameId(wireName)).toLowerAscii()

func cMsgDecl*(): string =
  # Guarded: a C and a C++ binding can meet in one translation unit, in any order.
  var lines = @[
    "#ifndef NIMFFI_MSG_DECLARED", "#define NIMFFI_MSG_DECLARED", "typedef struct {",
    "  uint32_t struct_size;   /* sizeof(NimFfiMsg) of the library; fields are only appended */",
    "  uint32_t kind;          /* NIMFFI_MSG_* */",
    "  uint64_t seq_num;       /* production order within the context */",
    "  uint64_t id;            /* REPLY, STALE: the request id. Otherwise 0 */",
    "  uint64_t name_id;       /* EVENT: which one. Otherwise 0 */",
    "  uint64_t duration_ms;   /* STALE: ms in flight; REVERSE_CALL: ms left to answer */",
    "  int32_t  ret_code;", "  uint32_t flags;          /* reserved; zero today */",
    "  const uint8_t* payload; /* bare CBOR value; never NULL */", "  size_t   len;",
    "} NimFfiMsg;", "",
  ]
  for k in MsgKinds:
    lines.add("#define NIMFFI_MSG_" & k.name & " " & $k.value & "  /* " & k.doc & " */")
  lines.add("")
  lines.add("#endif /* NIMFFI_MSG_DECLARED */")
  return lines.join("\n")

func rustMsgDecl*(): string =
  var lines = @[
    "#[repr(C)]", "pub struct NimFfiMsg {", "    pub struct_size: u32,",
    "    pub kind: u32,", "    pub seq_num: u64,", "    pub id: u64,",
    "    pub name_id: u64,", "    pub duration_ms: u64,", "    pub ret_code: i32,",
    "    pub flags: u32,", "    pub payload: *const u8,", "    pub len: usize,", "}", "",
  ]
  for k in MsgKinds:
    lines.add("pub const NIMFFI_MSG_" & k.name & ": u32 = " & $k.value & ";")
  return lines.join("\n")
