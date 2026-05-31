// Shared wire protocol for the timer IPC example (client <-> server).
//
// The library lives in the *server* process; the `ctx` it returns is a pointer
// into the server's address space and never crosses the wire. A client sends a
// method name + a CBOR request payload; the server routes it to the matching
// `<name>_cbor` entry point on its own context and ships the CBOR response back.
//
// All framing uses network byte order so the same client/server work whether
// they are two processes on one machine (AF_UNIX) or two machines (AF_INET).
//
// Request frame:   [u32 method_len][method][u32 payload_len][cbor payload]
// Response frame:  [ i32 ret      ][u32 resp_len][cbor/raw response]
#ifndef TIMER_IPC_PROTO_H
#define TIMER_IPC_PROTO_H

#include "my_timer_cbor.h" // FfiCbor encoder + ffi_decode_text (pure C, no lib)

#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// --- reliable read/write (handle short reads/writes) ------------------------
static int io_write_all(int fd, const void *buf, size_t n) {
  const uint8_t *p = (const uint8_t *)buf;
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w <= 0) return -1;
    p += (size_t)w;
    n -= (size_t)w;
  }
  return 0;
}
static int io_read_all(int fd, void *buf, size_t n) {
  uint8_t *p = (uint8_t *)buf;
  while (n) {
    ssize_t r = read(fd, p, n);
    if (r <= 0) return -1; // 0 = peer closed
    p += (size_t)r;
    n -= (size_t)r;
  }
  return 0;
}

static int io_write_u32(int fd, uint32_t v) {
  uint32_t be = htonl(v);
  return io_write_all(fd, &be, 4);
}
static int io_read_u32(int fd, uint32_t *out) {
  uint32_t be;
  if (io_read_all(fd, &be, 4) != 0) return -1;
  *out = ntohl(be);
  return 0;
}

// --- request frame ----------------------------------------------------------
static int proto_send_request(int fd, const char *method, const uint8_t *payload,
                              uint32_t payload_len) {
  uint32_t mlen = (uint32_t)strlen(method);
  if (io_write_u32(fd, mlen) != 0) return -1;
  if (io_write_all(fd, method, mlen) != 0) return -1;
  if (io_write_u32(fd, payload_len) != 0) return -1;
  if (payload_len && io_write_all(fd, payload, payload_len) != 0) return -1;
  return 0;
}

// Reads a request frame. `method` is filled (NUL-terminated, <= method_cap-1).
// `*payload` is malloc'd (caller frees) or NULL when empty.
static int proto_recv_request(int fd, char *method, size_t method_cap,
                              uint8_t **payload, uint32_t *payload_len) {
  uint32_t mlen;
  if (io_read_u32(fd, &mlen) != 0) return -1;
  if (mlen >= method_cap) return -1;
  if (io_read_all(fd, method, mlen) != 0) return -1;
  method[mlen] = '\0';
  if (io_read_u32(fd, payload_len) != 0) return -1;
  *payload = NULL;
  if (*payload_len) {
    *payload = (uint8_t *)malloc(*payload_len);
    if (!*payload || io_read_all(fd, *payload, *payload_len) != 0) {
      free(*payload);
      return -1;
    }
  }
  return 0;
}

// --- response frame ---------------------------------------------------------
static int proto_send_response(int fd, int32_t ret, const uint8_t *resp,
                               uint32_t resp_len) {
  if (io_write_u32(fd, (uint32_t)ret) != 0) return -1;
  if (io_write_u32(fd, resp_len) != 0) return -1;
  if (resp_len && io_write_all(fd, resp, resp_len) != 0) return -1;
  return 0;
}
static int proto_recv_response(int fd, int32_t *ret, uint8_t **resp,
                               uint32_t *resp_len) {
  uint32_t r;
  if (io_read_u32(fd, &r) != 0) return -1;
  *ret = (int32_t)r;
  if (io_read_u32(fd, resp_len) != 0) return -1;
  *resp = NULL;
  if (*resp_len) {
    *resp = (uint8_t *)malloc(*resp_len);
    if (!*resp || io_read_all(fd, *resp, *resp_len) != 0) {
      free(*resp);
      return -1;
    }
  }
  return 0;
}

// --- CBOR request builders (use the FfiCbor encoder from my_timer_cbor.h) ----
// version: empty map. request map keys: (none)
static FfiCbor req_version(void) {
  FfiCbor c = ffi_cbor_new();
  ffi_cbor_map(&c, 0);
  return c;
}
// echo: { "req": { "message": <str>, "delayMs": <int> } }
static FfiCbor req_echo(const char *message, int64_t delay_ms) {
  FfiCbor c = ffi_cbor_new();
  ffi_cbor_map(&c, 1);
  ffi_cbor_text(&c, "req");
  ffi_cbor_map(&c, 2);
  ffi_cbor_kv_text(&c, "message", message);
  ffi_cbor_kv_int(&c, "delayMs", delay_ms);
  return c;
}

// --- minimal CBOR response reader -------------------------------------------
// Enough to walk the definite-length maps the library emits (text/int/bool/
// nested). `cbor_item_len` returns the byte length of one item at `p`, 0 on err.
static size_t cbor_item_len(const uint8_t *p, size_t len) {
  if (len < 1) return 0;
  uint8_t major = p[0] >> 5, info = p[0] & 0x1f;
  size_t head = 1;
  uint64_t arg = info;
  if (info == 24) { if (len < 2) return 0; arg = p[1]; head = 2; }
  else if (info == 25) { if (len < 3) return 0; arg = ((uint64_t)p[1] << 8) | p[2]; head = 3; }
  else if (info == 26) { if (len < 5) return 0; arg = ((uint64_t)p[1] << 24) | ((uint64_t)p[2] << 16) | ((uint64_t)p[3] << 8) | p[4]; head = 5; }
  else if (info == 27) { if (len < 9) return 0; arg = 0; for (int i = 1; i <= 8; i++) arg = (arg << 8) | p[i]; head = 9; }
  else if (info >= 28) return 0;
  switch (major) {
  case 0: case 1: case 7: return head;          // uint / negint / simple+float
  case 2: case 3: return head + (size_t)arg;     // bytes / text
  case 4: {                                      // array: arg items
    size_t off = head;
    for (uint64_t i = 0; i < arg; i++) {
      size_t n = cbor_item_len(p + off, len - off);
      if (!n) return 0;
      off += n;
    }
    return off;
  }
  case 5: {                                      // map: 2*arg items
    size_t off = head;
    for (uint64_t i = 0; i < arg * 2; i++) {
      size_t n = cbor_item_len(p + off, len - off);
      if (!n) return 0;
      off += n;
    }
    return off;
  }
  default: return 0;
  }
}

// Find text value for `key` in a top-level definite-length map. Copies into
// `out` (NUL-terminated). Returns 1 on success, 0 if not found / not text.
static int cbor_map_get_text(const uint8_t *p, size_t len, const char *key,
                             char *out, size_t out_cap) {
  if (len < 1 || (p[0] >> 5) != 5) return 0;
  uint8_t info = p[0] & 0x1f;
  if (info >= 24) return 0; // only small maps in this example
  uint64_t pairs = info;
  size_t off = 1, klen = strlen(key);
  for (uint64_t i = 0; i < pairs; i++) {
    const uint8_t *k = p + off;
    if (off >= len || (k[0] >> 5) != 3) return 0;
    uint8_t kinfo = k[0] & 0x1f;
    if (kinfo >= 24) return 0;
    size_t kn = 1 + kinfo, vlen_off = off + kn;
    const uint8_t *v = p + vlen_off;
    int match = (kinfo == klen) && memcmp(k + 1, key, klen) == 0;
    if (match && (v[0] >> 5) == 3) {
      uint8_t vinfo = v[0] & 0x1f;
      if (vinfo >= 24) return 0;
      size_t vn = vinfo;
      size_t cp = vn < out_cap - 1 ? vn : out_cap - 1;
      memcpy(out, v + 1, cp);
      out[cp] = '\0';
      return 1;
    }
    size_t vfull = cbor_item_len(v, len - vlen_off);
    if (!vfull) return 0;
    off = vlen_off + vfull;
  }
  return 0;
}

#endif // TIMER_IPC_PROTO_H
