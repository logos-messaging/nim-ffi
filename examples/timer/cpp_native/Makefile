# Build the native (same-process) C++ example for the timer library.
#
#   make run     # build the Nim dylib + the C++ driver, then run it
#   make clean
#
# Links the library directly and uses the native ABI (../c_bindings/my_timer.h)
# — no CBOR, no tinycbor. The Nim library is compiled from the repo root so its
# vendored Nimble dependencies resolve.

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

CXX     ?= c++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -O2 -I$(HDR_DIR)
NIMFLAGS := --mm:orc -d:chronicles_log_level=WARN --app:lib --noMain \
            --nimMainPrefix:libmy_timer

.PHONY: all run clean

all: example

$(LIBNAME):
	cd $(REPO_ROOT) && nim c $(NIMFLAGS) -o:$(CURDIR)/$(LIBNAME) $(NIM_SRC)

example: main.cpp $(HDR_DIR)/my_timer.h $(LIBNAME)
	$(CXX) $(CXXFLAGS) main.cpp -L. -lmy_timer $(RPATH) -o example

run: example
	./example

clean:
	rm -f example $(LIBNAME)
