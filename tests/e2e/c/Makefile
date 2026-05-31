# Build + run the native/CBOR concurrency stress test for the timer example.
#
#   make stress                 # plain build + run
#   make stress SAN=address     # AddressSanitizer
#   make stress SAN=thread      # ThreadSanitizer
#   make clean
#
# Drives the real exported ABI of the timer example library, so it links the
# same dylib the C/Go consumers do. The library is built from the repo root so
# its vendored Nimble dependencies resolve.

REPO_ROOT := $(abspath ../../..)
NIM_SRC   := $(REPO_ROOT)/examples/timer/timer.nim
HDR_DIR   := $(REPO_ROOT)/examples/timer/c_bindings

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LIBNAME := libmy_timer.dylib
  RPATH   := -Wl,-rpath,.
else
  LIBNAME := libmy_timer.so
  RPATH   := -Wl,-rpath,'$$ORIGIN'
endif

CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -O1 -g -I$(HDR_DIR)
NIMFLAGS := --mm:orc -d:chronicles_log_level=WARN --app:lib --noMain \
            --nimMainPrefix:libmy_timer

# Optional sanitizer: SAN=address | thread | undefined
ifneq ($(SAN),)
  SANFLAGS  := -fsanitize=$(SAN) -fno-omit-frame-pointer
  CFLAGS    += $(SANFLAGS)
  LDSAN     := $(SANFLAGS)
  NIMFLAGS  += -d:useMalloc --passC:-fsanitize=$(SAN) --passL:-fsanitize=$(SAN)
endif

.PHONY: stress clean

$(LIBNAME):
	cd $(REPO_ROOT) && nim c $(NIMFLAGS) -o:$(CURDIR)/$(LIBNAME) $(NIM_SRC)

stress: stress.c $(HDR_DIR)/my_timer.h $(LIBNAME)
	$(CC) $(CFLAGS) stress.c -L. -lmy_timer -lpthread $(RPATH) $(LDSAN) -o stress
	./stress

clean:
	rm -f stress $(LIBNAME)
