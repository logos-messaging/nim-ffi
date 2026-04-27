import unittest2
import ../ffi/alloc

suite "alloc(cstring)":
  test "nil input returns empty cstring":
    let s: cstring = nil
    let res = alloc(s)
    check res != nil
    check res[0] == '\0'
    deallocShared(res)

  test "copies content":
    let res = alloc("hello world".cstring)
    check $res == "hello world"
    deallocShared(res)

  test "empty cstring":
    let res = alloc("".cstring)
    check len(res) == 0
    deallocShared(res)

suite "alloc(string)":
  test "copies content":
    let res = alloc("test string")
    check $res == "test string"
    deallocShared(res)

  test "empty string":
    let res = alloc("")
    check len(res) == 0
    deallocShared(res)

  test "string with special characters":
    let res = alloc("abc\0xyz")
    check res[0] == 'a'
    deallocShared(res)

suite "allocSharedSeq / deallocSharedSeq / toSeq":
  test "roundtrip int seq":
    let original = @[1, 2, 3, 4, 5]
    var shared = allocSharedSeq(original)
    check shared.len == 5
    let back = toSeq(shared)
    check back == original
    deallocSharedSeq(shared)
    check shared.len == 0

  test "empty seq":
    let original: seq[int] = @[]
    var shared = allocSharedSeq(original)
    check shared.len == 0
    check shared.data == nil
    let back = toSeq(shared)
    check back.len == 0
    deallocSharedSeq(shared)

  test "preserves element values by index":
    let original = @[10, 20, 30]
    var shared = allocSharedSeq(original)
    check shared.data[0] == 10
    check shared.data[1] == 20
    check shared.data[2] == 30
    deallocSharedSeq(shared)

  test "works with byte seq":
    let original = @[byte(0xFF), byte(0x00), byte(0xAB)]
    var shared = allocSharedSeq(original)
    check shared.len == 3
    let back = toSeq(shared)
    check back == original
    deallocSharedSeq(shared)
