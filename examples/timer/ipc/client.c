// Timer IPC client. Does NOT link the library — it only builds CBOR requests
// (with the FfiCbor encoder from my_timer_cbor.h) and parses CBOR responses.
// The actual timer runs in the server process, reached over a socket.
//
//   ./client --unix /tmp/my_timer.sock        # same machine
//   ./client --tcp  192.168.1.20 9099         # separate machine
#include "proto.h"

#include <netinet/in.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>

static int connect_unix(const char *path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}
static int connect_tcp(const char *host, uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
    close(fd);
    return -1;
  }
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

// Send one request frame, read one response frame. Returns ret code (or -1 on
// transport error); response bytes (malloc'd, caller frees) via out params.
static int call(int fd, const char *method, FfiCbor req, uint8_t **resp,
                uint32_t *resp_len) {
  if (proto_send_request(fd, method, req.buf, (uint32_t)req.len) != 0) return -1;
  int32_t ret = -1;
  if (proto_recv_response(fd, &ret, resp, resp_len) != 0) return -1;
  return ret;
}

int main(int argc, char **argv) {
  int fd = -1;
  if (argc == 3 && strcmp(argv[1], "--unix") == 0) {
    fd = connect_unix(argv[2]);
  } else if (argc == 4 && strcmp(argv[1], "--tcp") == 0) {
    fd = connect_tcp(argv[2], (uint16_t)atoi(argv[3]));
  } else {
    fprintf(stderr, "usage: %s --unix <path> | --tcp <host> <port>\n", argv[0]);
    return 2;
  }
  if (fd < 0) {
    perror("connect");
    return 1;
  }
  printf("[client] connected\n");

  uint8_t *resp = NULL;
  uint32_t rlen = 0;

  // 1) version — empty request, response is a CBOR text string.
  {
    FfiCbor req = req_version();
    int ret = call(fd, "version", req, &resp, &rlen);
    ffi_cbor_free(&req);
    if (ret == RET_OK) {
      char *s = ffi_decode_text(resp, rlen);
      printf("[client] version    = %s\n", s ? s : "<decode failed>");
      free(s);
    } else {
      printf("[client] version failed (ret=%d)\n", ret);
    }
    free(resp);
    resp = NULL;
  }

  // 2) echo — nested request, response is an EchoResponse map.
  {
    FfiCbor req = req_echo("hello over the wire", 5);
    int ret = call(fd, "echo", req, &resp, &rlen);
    ffi_cbor_free(&req);
    if (ret == RET_OK) {
      char echoed[256] = {0}, timer_name[256] = {0};
      cbor_map_get_text(resp, rlen, "echoed", echoed, sizeof(echoed));
      cbor_map_get_text(resp, rlen, "timerName", timer_name, sizeof(timer_name));
      printf("[client] echo.echoed= %s\n", echoed);
      printf("[client] echo.timer = %s\n", timer_name);
    } else {
      printf("[client] echo failed (ret=%d)\n", ret);
    }
    free(resp);
    resp = NULL;
  }

  close(fd);
  printf("[client] done\n");
  return 0;
}
