# Build + run the GENERATED native C++ example.
#
#   make run     # build the Nim dylib + the C++ driver against the generated hpp
#   make clean
#
# Regenerate the bindings with `nimble genbindings_cpp_native` (from the repo
# root). The Nim library is compiled from the repo root so its vendored Nimble
# dependencies resolve.

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

CXX      ?= c++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -O2 -I.
NIMFLAGS := --mm:orc -d:chronicles_log_level=WARN --app:lib --noMain \
            --nimMainPrefix:libmy_timer

.PHONY: all run clean

all: example

$(LIBNAME):
	cd $(REPO_ROOT) && nim c $(NIMFLAGS) -o:$(CURDIR)/$(LIBNAME) $(NIM_SRC)

example: main.cpp my_timer.hpp my_timer.h $(LIBNAME)
	$(CXX) $(CXXFLAGS) main.cpp -L. -lmy_timer $(RPATH) -o example

run: example
	./example

clean:
	rm -f example $(LIBNAME)
