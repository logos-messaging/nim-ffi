## Logos deterministic CBOR (dCBOR) — encoder, strict decoder, canonicaliser.
##
## Used only under `-d:ffiDeterministicCbor`. Off, nothing here is reachable and
## the wire format is unchanged for every existing consumer.
##
## This is the single home of the profile. It arrived from the logos-mod-coms
## interop PoC, which now imports it from here rather than keeping its own copy,
## and it is still cross-checked there against independent Python and Rust
## encoders over the same 40 vectors.
##
## LOGOS-MODULE-INTERFACE 4.5 requires an implementation to REJECT incoming
## bytes that break the profile, which is why `decode` validates rather than
## repairs. `canonicalise` is the one place that accepts mis-ordered input: it
## exists to fix what `cbor_serialization` produces on the way out, never to
## launder what a peer sent in.
##
## Hand-rolled rather than layered on a general CBOR library: the determinism
## rules below are the whole point, and a general encoder gives no guarantee
## about any of them. It is small enough that owning it is cheaper than
## constraining someone else's.
##
## Profile, per LOGOS-MODULE-INTERFACE 4.4:
##   1. map keys sorted bytewise over each key's COMPLETE encoding
##   2. shortest-form head argument everywhere
##   3. no indefinite-length items
##   4. no duplicate map keys
##   5. no floats
## Also: no tags; tstr is UTF-8 and must not contain U+0000.

import std/[algorithm, strutils, unicode]

type
  DcborError* = object of CatchableError

  NodeKind* = enum
    nkUint, nkNint, nkBytes, nkText, nkArray, nkMap, nkBool

  Node* = ref object
    case kind*: NodeKind
    of nkUint: u*: uint64        ## major 0, argument = u
    of nkNint: n*: uint64        ## major 1, argument = n, value = -1 - n
    of nkBytes: b*: seq[byte]
    of nkText: t*: string
    of nkArray: items*: seq[Node]
    of nkMap: pairs*: seq[(Node, Node)]
    of nkBool: yes*: bool

# ---------------------------------------------------------------- constructors

func du*(v: uint64): Node = Node(kind: nkUint, u: v)

func di*(v: int64): Node =
  ## Routes to major 0 or 1. Written to survive int64.low, where the obvious
  ## `-1 - v` overflows.
  let node =
    if v >= 0: Node(kind: nkUint, u: uint64(v))
    else: Node(kind: nkNint, n: uint64(-(v + 1)))
  return node

func dt*(v: string): Node = Node(kind: nkText, t: v)
func db*(v: seq[byte]): Node = Node(kind: nkBytes, b: v)
func dbool*(v: bool): Node = Node(kind: nkBool, yes: v)
func darr*(v: varargs[Node]): Node = Node(kind: nkArray, items: @v)
func dmap*(v: varargs[(Node, Node)]): Node = Node(kind: nkMap, pairs: @v)

# --------------------------------------------------------------------- encoder

proc head(dst: var seq[byte], major: byte, arg: uint64) {.gcsafe, raises: [].} =
  ## Rule 2 lives here, and nowhere else.
  let m = major shl 5
  if arg < 24'u64:
    dst.add(m or byte(arg))
  elif arg <= 0xFF'u64:
    dst.add(m or 24'u8); dst.add(byte(arg))
  elif arg <= 0xFFFF'u64:
    dst.add(m or 25'u8)
    for s in countdown(1, 0): dst.add(byte((arg shr (8 * s)) and 0xFF))
  elif arg <= 0xFFFF_FFFF'u64:
    dst.add(m or 26'u8)
    for s in countdown(3, 0): dst.add(byte((arg shr (8 * s)) and 0xFF))
  else:
    dst.add(m or 27'u8)
    for s in countdown(7, 0): dst.add(byte((arg shr (8 * s)) and 0xFF))

func cmpBytes(a, b: seq[byte]): int =
  ## Bytewise lexicographic; a proper prefix sorts first. Spelled out because
  ## this ordering IS rule 1, and borrowing a generic `cmp` would leave it
  ## implicit.
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    if a[i] != b[i]:
      return (if a[i] < b[i]: -1 else: 1)
  return cmp(a.len, b.len)

proc encodeTo(dst: var seq[byte], n: Node) {.gcsafe, raises: [DcborError].}

proc encode*(n: Node): seq[byte] {.gcsafe, raises: [DcborError].} =
  var buf: seq[byte] = @[]
  encodeTo(buf, n)
  return buf

proc encodeTo(dst: var seq[byte], n: Node) {.gcsafe, raises: [DcborError].} =
  case n.kind
  of nkUint: dst.head(0, n.u)
  of nkNint: dst.head(1, n.n)
  of nkBytes:
    dst.head(2, uint64(n.b.len))
    dst.add(n.b)
  of nkText:
    if n.t.contains('\0'):
      raise newException(DcborError, "tstr must not contain U+0000")
    dst.head(3, uint64(n.t.len))
    for c in n.t: dst.add(byte(c))
  of nkArray:
    dst.head(4, uint64(n.items.len))
    for it in n.items: dst.encodeTo(it)
  of nkMap:
    # Encode every key first: the sort is over encoded bytes, not over the
    # logical key, which is what makes mixed-type keys well-ordered.
    var enc: seq[(seq[byte], seq[byte])] = @[]
    for (k, v) in n.pairs:
      enc.add((encode(k), encode(v)))
    # The comparator is annotated because `sort` inherits its effects: an
    # unannotated closure here makes `encode` look like it raises bare
    # `Exception`, which no `except CatchableError` can catch -- and every
    # caller then has to widen its handler for a call that cannot actually fail.
    enc.sort(proc (a, b: (seq[byte], seq[byte])): int {.nimcall, raises: [].} =
      cmpBytes(a[0], b[0]))
    for i in 1 ..< enc.len:
      if enc[i - 1][0] == enc[i][0]:
        raise newException(DcborError, "duplicate map key")
    dst.head(5, uint64(enc.len))
    for (k, v) in enc:
      dst.add(k); dst.add(v)
  of nkBool:
    dst.add(if n.yes: 0xF5'u8 else: 0xF4'u8)

proc toHex*(bytes: seq[byte]): string {.gcsafe, raises: [].} =
  var s = newStringOfCap(bytes.len * 2)
  for b in bytes: s.add(b.toHex(2).toLowerAscii)
  return s

# --------------------------------------------------------------------- decoder
#
# Strict by design: the decoder is where non-deterministic input is caught, so
# it re-checks every rule the encoder enforces rather than trusting the sender.
# An encoder-only implementation happily accepts bytes it would never produce,
# which is exactly how two peers drift apart.

type Cursor = object
  requireOrder: bool
  b: seq[byte]
  i: int

proc fail(msg: string) {.noreturn, gcsafe, raises: [DcborError].} =
  raise newException(DcborError, msg)

proc readHead(c: var Cursor): tuple[major: byte, arg: uint64, ai: byte] {.gcsafe, raises: [DcborError].} =
  if c.i >= c.b.len: fail("truncated head")
  let ib = c.b[c.i]
  let major = ib shr 5
  let ai = ib and 0x1F
  inc c.i
  if ai < 24:
    return (major, uint64(ai), ai)
  if ai == 24:
    if c.i >= c.b.len: fail("truncated 1-byte argument")
    let arg = uint64(c.b[c.i]); inc c.i
    if arg < 24'u64: fail("non-shortest head")
    return (major, arg, ai)
  if ai in {25'u8, 26'u8, 27'u8}:
    let n = (if ai == 25: 2 elif ai == 26: 4 else: 8)
    if c.i + n > c.b.len: fail("truncated argument")
    var arg: uint64 = 0
    for k in 0 ..< n:
      arg = (arg shl 8) or uint64(c.b[c.i + k])
    c.i += n
    let limit: uint64 = (if ai == 25: 0xFF'u64
                         elif ai == 26: 0xFFFF'u64
                         else: 0xFFFF_FFFF'u64)
    if arg <= limit: fail("non-shortest head")
    return (major, arg, ai)
  if ai == 31: fail("indefinite length is forbidden")
  fail("reserved additional info " & $ai)

proc decodeAt(c: var Cursor): Node {.gcsafe, raises: [DcborError].} =
  # `ai` travels alongside the argument because major 7 is classified by the
  # additional-info bits, not by value: 0xf9 3c00 is a float whose argument
  # happens to be 15360.
  let (major, arg, ai) = c.readHead()
  case major
  of 0: return du(arg)
  of 1: return Node(kind: nkNint, n: arg)
  of 2:
    if c.i + int(arg) > c.b.len: fail("truncated bstr")
    let v = c.b[c.i ..< c.i + int(arg)]
    c.i += int(arg)
    return db(v)
  of 3:
    if c.i + int(arg) > c.b.len: fail("truncated tstr")
    var s = newStringOfCap(int(arg))
    for k in 0 ..< int(arg):
      let ch = c.b[c.i + k]
      if ch == 0: fail("tstr must not contain U+0000")
      s.add(char(ch))
    c.i += int(arg)
    if validateUtf8(s) != -1: fail("tstr is not valid UTF-8")
    return dt(s)
  of 4:
    var items: seq[Node] = @[]
    for _ in 0 ..< int(arg): items.add(c.decodeAt())
    return Node(kind: nkArray, items: items)
  of 5:
    var pairs: seq[(Node, Node)] = @[]
    var prev: seq[byte] = @[]
    for idx in 0 ..< int(arg):
      let kStart = c.i
      let k = c.decodeAt()
      let kBytes = c.b[kStart ..< c.i]
      if idx > 0:
        let ord = cmpBytes(kBytes, prev)
        if ord == 0: fail("duplicate map key")
        # Out-of-order keys are a rejection on the way in (4.5) and a thing to
        # fix on the way out; `requireOrder` is what tells the two apart.
        if ord < 0 and c.requireOrder: fail("map keys out of canonical order")
      prev = kBytes
      pairs.add((k, c.decodeAt()))
    return Node(kind: nkMap, pairs: pairs)
  of 7:
    if ai == 20: return dbool(false)
    if ai == 21: return dbool(true)
    if ai in {25'u8, 26'u8, 27'u8}:
      fail("floats are not part of Logos module schemas")
    fail("unsupported simple value (ai=" & $ai & ")")
  else:
    fail("tags are forbidden (major " & $major & ")")

proc decode*(bytes: seq[byte]): Node {.gcsafe, raises: [DcborError].} =
  ## Decode one complete dCBOR item. Trailing bytes are an error.
  var c = Cursor(b: bytes, i: 0, requireOrder: true)
  let n = c.decodeAt()
  if c.i != bytes.len:
    fail($(bytes.len - c.i) & " trailing byte(s)")
  return n

# -------------------------------------------------------------- typed access
#
# What generated codecs use to read a decoded map. Every mismatch raises rather
# than returning a zero value: a field that is the wrong type is a contract
# violation, and silently substituting a default is how one is hidden.

proc field*(n: Node, key: string): Node {.gcsafe, raises: [DcborError].} =
  ## The value for `key`, or nil when absent. Absence is legal for `?` fields
  ## and is the caller's business to interpret.
  if n.kind != nkMap: fail("expected a map")
  for (k, v) in n.pairs:
    if k.kind == nkText and k.t == key:
      return v
  return nil

proc asText*(n: Node): string {.gcsafe, raises: [DcborError].} =
  if n == nil or n.kind != nkText: fail("expected tstr")
  return n.t

proc asBytes*(n: Node): seq[byte] {.gcsafe, raises: [DcborError].} =
  if n == nil or n.kind != nkBytes: fail("expected bstr")
  return n.b

proc asBool*(n: Node): bool {.gcsafe, raises: [DcborError].} =
  if n == nil or n.kind != nkBool: fail("expected bool")
  return n.yes

proc asUint*(n: Node): uint64 {.gcsafe, raises: [DcborError].} =
  if n == nil or n.kind != nkUint: fail("expected uint")
  return n.u

proc asInt*(n: Node): int64 {.gcsafe, raises: [DcborError].} =
  if n == nil: fail("expected int")
  case n.kind
  of nkUint:
    if n.u > uint64(high(int64)): fail("int out of range")
    return int64(n.u)
  of nkNint:
    if n.n > uint64(high(int64)): fail("int out of range")
    return -1'i64 - int64(n.n)
  else: fail("expected int")

proc items*(n: Node): seq[Node] {.gcsafe, raises: [DcborError].} =
  if n == nil or n.kind != nkArray: fail("expected array")
  return n.items

proc require*(n: Node, key: string): Node {.gcsafe, raises: [DcborError].} =
  let v = n.field(key)
  if v == nil: fail("missing required field '" & key & "'")
  return v

func dmapOf*(v: seq[(Node, Node)]): Node = Node(kind: nkMap, pairs: v)
func darrOf*(v: seq[Node]): Node = Node(kind: nkArray, items: v)


# --------------------------------------------------------------- conformance

proc validate*(bytes: seq[byte]): bool {.gcsafe, raises: [].} =
  ## Section 4.5: does `bytes` satisfy the profile? The decoder enforces every
  ## rule as it reads, so a clean decode is the whole answer.
  if bytes.len == 0: return true
  try:
    discard decode(bytes)
    return true
  except DcborError:
    return false

proc canonicalise*(bytes: seq[byte]): seq[byte] {.gcsafe, raises: [DcborError].} =
  ## Re-emit `bytes` in canonical form, accepting mis-ordered map keys on the
  ## way in. Everything else the profile forbids -- floats, tags, indefinite
  ## lengths, non-shortest heads, duplicate keys -- still fails, because none of
  ## them can be canonicalised into a profile that has no such value.
  if bytes.len == 0: return @[]
  var c = Cursor(b: bytes, i: 0, requireOrder: false)
  let n = c.decodeAt()
  if c.i != bytes.len:
    fail($(bytes.len - c.i) & " trailing byte(s)")
  return encode(n)
