// Timer IPC server: links libmy_timer, owns the FFI context, and serves method
// calls over a socket using the CBOR ABI. One context is created at startup and
// shared by every client connection (the library is internally thread-safe and
// serializes work on its own FFI thread).
//
//   ./server --unix /tmp/my_timer.sock        # same machine (AF_UNIX)
//   ./server --tcp  0.0.0.0 9099              # separate machines (AF_INET)
#include "proto.h"

#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>

// --- blocking response capture for the async CBOR entry points --------------
typedef struct {
  int ret;
  uint8_t *bytes;
  size_t len;
  int done;
  pthread_mutex_t mu;
  pthread_cond_t cv;
} Resp;

static void resp_init(Resp *r) {
  memset(r, 0, sizeof(*r));
  pthread_mutex_init(&r->mu, NULL);
  pthread_cond_init(&r->cv, NULL);
}
static void resp_reset(Resp *r) {
  free(r->bytes);
  r->bytes = NULL;
  r->len = 0;
  r->ret = 0;
  r->done = 0;
}
static void on_result(int ret, const char *msg, size_t len, void *ud) {
  Resp *r = (Resp *)ud;
  pthread_mutex_lock(&r->mu);
  r->ret = ret;
  r->bytes = (uint8_t *)malloc(len ? len : 1);
  if (msg && len) memcpy(r->bytes, msg, len);
  r->len = len;
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}
static void resp_wait(Resp *r) {
  pthread_mutex_lock(&r->mu);
  while (!r->done) pthread_cond_wait(&r->cv, &r->mu);
  pthread_mutex_unlock(&r->mu);
}

// --- socket setup -----------------------------------------------------------
static int make_unix_listener(const char *path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  unlink(path);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}
static int make_tcp_listener(const char *host, uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
    close(fd);
    return -1;
  }
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

// --- dispatch one method on the shared context ------------------------------
static int dispatch(void *ctx, const char *method, const uint8_t *payload,
                    uint32_t plen, Resp *r) {
  resp_reset(r);
  if (strcmp(method, "version") == 0)
    return my_timer_version_cbor(ctx, on_result, r, payload, plen);
  if (strcmp(method, "echo") == 0)
    return my_timer_echo_cbor(ctx, on_result, r, payload, plen);
  if (strcmp(method, "complex") == 0)
    return my_timer_complex_cbor(ctx, on_result, r, payload, plen);
  if (strcmp(method, "schedule") == 0)
    return my_timer_schedule_cbor(ctx, on_result, r, payload, plen);
  return -1; // unknown method
}

static void serve_conn(int conn, void *ctx, Resp *r) {
  for (;;) {
    char method[64];
    uint8_t *payload = NULL;
    uint32_t plen = 0;
    if (proto_recv_request(conn, method, sizeof(method), &payload, &plen) != 0)
      break; // peer closed
    int rc = dispatch(ctx, method, payload, plen, r);
    free(payload);
    if (rc == RET_OK)
      resp_wait(r);
    int32_t ret = (rc == RET_OK) ? r->ret : RET_ERR;
    const uint8_t *body = (rc == RET_OK) ? r->bytes : (const uint8_t *)method;
    uint32_t blen = (rc == RET_OK) ? (uint32_t)r->len : 0;
    printf("[server] %-9s -> ret=%d (%u bytes)\n", method, ret, blen);
    if (proto_send_response(conn, ret, body, blen) != 0) break;
  }
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0); // flush server logs line-by-line
  int listener = -1;
  if (argc == 3 && strcmp(argv[1], "--unix") == 0) {
    listener = make_unix_listener(argv[2]);
    printf("[server] listening on unix:%s\n", argv[2]);
  } else if (argc == 4 && strcmp(argv[1], "--tcp") == 0) {
    listener = make_tcp_listener(argv[2], (uint16_t)atoi(argv[3]));
    printf("[server] listening on tcp:%s:%s\n", argv[2], argv[3]);
  } else {
    fprintf(stderr, "usage: %s --unix <path> | --tcp <host> <port>\n", argv[0]);
    return 2;
  }
  if (listener < 0) {
    perror("listen");
    return 1;
  }

  // Create the library context once, up front, with a fixed config.
  Resp r;
  resp_init(&r);
  FfiCbor cfg = ffi_cbor_new();
  ffi_cbor_map(&cfg, 1);
  ffi_cbor_text(&cfg, "config");
  ffi_cbor_map(&cfg, 1);
  ffi_cbor_kv_text(&cfg, "name", "ipc-server");
  void *ctx = my_timer_create_cbor(cfg.buf, cfg.len, on_result, &r);
  ffi_cbor_free(&cfg);
  resp_wait(&r);
  if (!ctx) {
    fprintf(stderr, "[server] create failed\n");
    return 1;
  }
  printf("[server] timer context ready\n");

  for (;;) {
    int conn = accept(listener, NULL, NULL);
    if (conn < 0) break;
    printf("[server] client connected\n");
    serve_conn(conn, ctx, &r);
    close(conn);
    printf("[server] client disconnected\n");
  }

  my_timer_destroy(ctx);
  close(listener);
  return 0;
}
