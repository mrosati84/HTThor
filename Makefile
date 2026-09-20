# oj — an httpie port in Odin. See docs/ARCHITECTURE.md for the module
# boundaries, the HTTP/TLS backend choice and the memory ownership rules.
#
# Per-machine toolchain paths live in local.mk (git-ignored) so this file stays
# portable:
#
#   ODIN := /path/to/odin
#
# `make build` compiles the CLI, `make check` type-checks src and tests without
# codegen, and `make test` runs the Odin unit suite in tests/.

ODIN       ?= odin
BUILD_DIR  ?= build
BIN        ?= $(BUILD_DIR)/oj

COLLECTION ?= -collection:src=src
ODIN_FLAGS ?= -o:speed -vet -warnings-as-errors
# `odin check` takes no optimisation level.
ODIN_CHECK_FLAGS ?= -vet -warnings-as-errors
# libcurl is the transport (docs/ARCHITECTURE.md, "HTTP/TLS backend").
CURL_LIBS  ?= -lcurl
LINK_FLAGS ?= $(if $(strip $(CURL_LIBS)),-extra-linker-flags:"$(CURL_LIBS)")

SOURCES      := $(shell find src -name '*.odin')
TEST_SOURCES := $(shell find tests -name '*.odin')

-include local.mk

.PHONY: all build test test-unit check clean check-deps

all: build

build: check-deps $(BIN)

$(BIN): $(SOURCES)
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(COLLECTION) $(ODIN_FLAGS) $(LINK_FLAGS) -out:$(BIN)

# make test = the Odin unit suite in tests/. The behavioural tests and their
# mem.Tracking_Allocator assertions are the whole gate.
test: test-unit

test-unit: $(TEST_SOURCES) $(SOURCES)
	$(ODIN) test tests $(COLLECTION) $(ODIN_FLAGS) $(LINK_FLAGS)

# `check` is the fast gate: parse, type check and vet both packages, no codegen
# and no linker.
check: check-deps
	$(ODIN) check src $(COLLECTION) $(ODIN_CHECK_FLAGS)
	# tests/ is a @(test) package: it has no entry point of its own.
	$(ODIN) check tests $(COLLECTION) $(ODIN_CHECK_FLAGS) -no-entry-point

check-deps:
	@command -v $(ODIN) >/dev/null 2>&1 || { \
	  echo "error: odin not found in PATH; set ODIN=/path/to/odin (README.md)"; exit 1; }

clean:
	rm -rf $(BUILD_DIR)
