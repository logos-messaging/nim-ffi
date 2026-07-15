## Unicode-aware identifier-casing helpers shared by codegen and the FFI macro.

import std/[strutils, unicode]

proc toLower*(s: string): string =
  ## Unicode-aware lowercase for an entire string.
  var buf = ""
  for r in runes(s):
    buf.add($r.toLower())
  return buf

proc camelToSnakeCase*(s: string): string =
  ## camelCase → snake_case, e.g. "delayMs" → "delay_ms".
  var snake = ""
  var first = true
  for r in runes(s):
    if r.isUpper() and not first:
      snake.add('_')
    snake.add($r.toLower())
    first = false
  return snake

func capitalizeFirstLetter*(s: string): string =
  ## Returns `s` with its first rune uppercased, rest unchanged.
  if s.len == 0:
    return s
  var runesSeq = toRunes(s)
  runesSeq[0] = runesSeq[0].toUpper()
  return $runesSeq

proc snakeToPascalCase*(s: string): string =
  ## snake_case → PascalCase, e.g. "hello_world" → "HelloWorld".
  let parts = s.split('_')
  var pascal = ""
  for p in parts:
    pascal.add capitalizeFirstLetter(p)
  return pascal
