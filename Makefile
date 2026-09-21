# HTThor — an httpie port in Odin. See README.md, "Architecture", for the module
# boundaries, the HTTP/TLS backend choice and the memory ownership rules, and
# docs/PROVENANCE.md for the port's provenance trail.
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
BIN        ?= $(BUILD_DIR)/htthor

COLLECTION ?= -collection:src=src
ODIN_FLAGS ?= -o:speed -vet -warnings-as-errors
# `odin check` takes no optimisation level.
ODIN_CHECK_FLAGS ?= -vet -warnings-as-errors
# libcurl is the transport (README.md, "Transport").
CURL_LIBS  ?= -lcurl
LINK_FLAGS ?= $(if $(strip $(CURL_LIBS)),-extra-linker-flags:"$(CURL_LIBS)")

# The revision the binary reports after its own release (`--version`, backlog M9):
# git's description of the tree being built, or `unknown` outside a checkout. odin
# takes the bare word as the string constant, so no quoting is needed (and a git
# description never contains a space). Override with `make PORT_REVISION=...`.
PORT_REVISION ?= $(shell git describe --always --dirty 2>/dev/null || echo unknown)
PORT_FLAGS    ?= -define:PORT_REVISION=$(PORT_REVISION)
# The revision is compared on every build and only rewritten when it changes, so
# the binary relinks exactly when the value it would report changes — in either
# direction. `FORCE` is the standard phony prerequisite for "run this recipe".
REVISION_STAMP ?= $(BUILD_DIR)/revision

SOURCES      := $(shell find src -name '*.odin')
TEST_SOURCES := $(shell find tests -name '*.odin')

-include local.mk

.PHONY: all build test test-unit check clean check-deps FORCE

all: build

build: check-deps $(BIN)

$(BIN): $(SOURCES) $(REVISION_STAMP)
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(COLLECTION) $(ODIN_FLAGS) $(PORT_FLAGS) $(LINK_FLAGS) -out:$(BIN)

$(REVISION_STAMP): FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '%s\n' '$(PORT_REVISION)' | cmp -s - $@ 2>/dev/null || printf '%s\n' '$(PORT_REVISION)' > $@

FORCE:

# make test = the Odin unit suite in tests/. The behavioural tests and their
# mem.Tracking_Allocator assertions are the whole gate.
test: test-unit

test-unit: $(TEST_SOURCES) $(SOURCES)
	$(ODIN) test tests $(COLLECTION) $(ODIN_FLAGS) $(PORT_FLAGS) $(LINK_FLAGS)

# `check` is the fast gate: parse, type check and vet both packages, no codegen
# and no linker.
check: check-deps
	$(ODIN) check src $(COLLECTION) $(ODIN_CHECK_FLAGS) $(PORT_FLAGS)
	# tests/ is a @(test) package: it has no entry point of its own.
	$(ODIN) check tests $(COLLECTION) $(ODIN_CHECK_FLAGS) $(PORT_FLAGS) -no-entry-point

check-deps:
	@command -v $(ODIN) >/dev/null 2>&1 || { \
	  echo "error: odin not found in PATH; set ODIN=/path/to/odin (README.md)"; exit 1; }

clean:
	rm -rf $(BUILD_DIR)
