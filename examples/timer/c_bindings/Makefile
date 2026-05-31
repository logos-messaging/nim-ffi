# Build the native (same-process) C example for the timer library.
#
#   make run     # build the Nim dylib + the C driver, then run it
#   make clean
#
# The Nim library is compiled from the repository root so its vendored Nimble
# dependencies resolve, exactly like the CMake-based C++ example does.

REPO_ROOT := $(abspath ../../..)
NIM_SRC   := $(REPO_ROOT)/examples/timer/timer.nim

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LIBNAME := libmy_timer.dylib
  RPATH   := -Wl,-rpath,.
else
  LIBNAME := libmy_timer.so
  RPATH   := -Wl,-rpath,'$$ORIGIN'
endif

CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -O2
NIMFLAGS := --mm:orc -d:chronicles_log_level=WARN --app:lib --noMain \
            --nimMainPrefix:libmy_timer

.PHONY: all run clean

all: example

$(LIBNAME):
	cd $(REPO_ROOT) && nim c $(NIMFLAGS) -o:$(CURDIR)/$(LIBNAME) $(NIM_SRC)

example: example.c my_timer.h $(LIBNAME)
	$(CC) $(CFLAGS) -I. example.c -L. -lmy_timer $(RPATH) -o example

run: example
	./example

clean:
	rm -f example $(LIBNAME)
