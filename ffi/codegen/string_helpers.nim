## Identifier-casing helpers shared by the codegen modules and the FFI macro.
## All three operate on `Rune` via `std/unicode` so non-ASCII identifiers
## (rare in FFI symbols but possible in field names) round-trip correctly.

import std/[strutils, unicode]

proc toLower*(s: string): string =
  ## Unicode-aware lowercase for an entire string. Wraps `std/unicode`'s
  ## per-Rune `toLower` so callers don't have to iterate manually.
  var buf = ""
  for r in runes(s):
    buf.add($r.toLower())
  return buf

proc camelToSnakeCase*(s: string): string =
  ## Converts camelCase to snake_case. Inserts `_` before each uppercase rune
  ## that's not the first character and lowercases everything.
  ## e.g. "delayMs" → "delay_ms", "timerName" → "timer_name"
  var snake = ""
  var first = true
  for r in runes(s):
    if r.isUpper() and not first:
      snake.add('_')
    snake.add($r.toLower())
    first = false
  return snake

proc capitalizeFirstLetter*(s: string): string =
  ## Returns `s` with its first rune uppercased; the rest is left unchanged.
  ## e.g. "abc" → "Abc", "" → "", "Abc" → "Abc"
  if s.len == 0:
    return s
  var runesSeq = toRunes(s)
  runesSeq[0] = runesSeq[0].toUpper()
  return $runesSeq

proc snakeToPascalCase*(s: string): string =
  ## Converts snake_case identifiers to PascalCase: split on `_`, uppercase
  ## the first rune of each part, concatenate.
  ## e.g. "testlib_create" → "TestlibCreate", "hello_world" → "HelloWorld"
  let parts = s.split('_')
  var pascal = ""
  for p in parts:
    pascal.add capitalizeFirstLetter(p)
  return pascal
