# Build the IPC (CBOR-over-socket) timer example.
#
#   make            # build the Nim dylib, the server, and the client
#   make demo       # run a full same-machine round-trip over a unix socket
#   make clean
#
# The server links libmy_timer; the client does not (it only needs the CBOR
# encoder/decoder in my_timer_cbor.h). The Nim library is compiled from the
# repository root so its vendored Nimble dependencies resolve.

# Generated my_timer.h / my_timer_cbor.h live in ../c_bindings.
REPO_ROOT := $(abspath ../../..)
NIM_SRC   := $(REPO_ROOT)/examples/timer/timer.nim
HDR_DIR   := ../c_bindings

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LIBNAME := libmy_timer.dylib
  RPATH   := -Wl,-rpath,.
else
  LIBNAME := libmy_timer.so
  RPATH   := -Wl,-rpath,'$$ORIGIN'
endif

CC      ?= cc
# proto.h is a shared static-inline header; each TU uses a subset of it, so
# unused-function warnings are expected and silenced.
CFLAGS  ?= -std=c11 -Wall -Wextra -Wno-unused-function -O2 -I. -I$(HDR_DIR)
NIMFLAGS := --mm:orc -d:chronicles_log_level=WARN --app:lib --noMain \
            --nimMainPrefix:libmy_timer
SOCK     := /tmp/my_timer.sock

.PHONY: all demo clean

all: server client

$(LIBNAME):
	cd $(REPO_ROOT) && nim c $(NIMFLAGS) -o:$(CURDIR)/$(LIBNAME) $(NIM_SRC)

server: server.c proto.h $(HDR_DIR)/my_timer_cbor.h $(LIBNAME)
	$(CC) $(CFLAGS) server.c -L. -lmy_timer -lpthread $(RPATH) -o server

client: client.c proto.h $(HDR_DIR)/my_timer_cbor.h
	$(CC) $(CFLAGS) client.c -o client

# Same-machine demo: start the server on a unix socket, run the client, stop.
demo: all
	@./server --unix $(SOCK) & echo $$! > .srv.pid; \
	sleep 1; \
	./client --unix $(SOCK); \
	kill `cat .srv.pid` 2>/dev/null; rm -f .srv.pid $(SOCK)

clean:
	rm -f server client $(LIBNAME) .srv.pid $(SOCK)
