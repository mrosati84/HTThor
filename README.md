# oj — httpie, ported to Odin

`oj` is a port of the [httpie](https://httpie.io) CLI to Odin: the argument
parser, the request/response model, the libcurl transport and the output
renderer. This tree is pure Odin — no Python, no reference-parity harness.

Documentation:

| file | what it is |
| --- | --- |
| `docs/ARCHITECTURE.md` | module boundaries, the HTTP/TLS backend choice and its rationale, memory ownership rules, build/test/CI. **Read this before writing code.** |

## Build and test

Requirements: an Odin toolchain (tested with `dev-2026-09`), `clang` (Odin's
linker), and libcurl's development files (`libcurl4-openssl-dev` on Debian and
Ubuntu; any libcurl that ships `libcurl.so` will do, since
`src/http/libcurl.odin` declares the symbols it needs instead of parsing curl's
headers).

```sh
make build    # -> build/oj, -o:speed, zero warnings (-vet -warnings-as-errors)
make check    # parse + type check + vet src and tests, no codegen
make test     # Odin unit test suite in tests/
make clean
```

`make test` runs only the Odin unit test suite in `tests/`; `make test-unit`
runs that same suite.

`make` reads per-machine toolchain paths from `local.mk` (git-ignored):

```make
ODIN := /path/to/odin
```

## Try it

```sh
./build/oj --version
./build/oj --help
./build/oj --offline GET localhost:8000/hello    # renders the request, sends nothing
./build/oj GET http://localhost:8000/hello       # a real request
```
