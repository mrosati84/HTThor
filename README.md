# oj — HTTPie 3.2.4, ported to Odin

`oj` is a 1:1 port of the [HTTPie](https://httpie.io) command-line HTTP client, reference release **3.2.4**, to the [Odin](https://odin-lang.org) programming language. It is a single, dynamically linked executable: the argv parser and request-item mini-language, the request/response model, the HTTP exchange, and the terminal renderer (Pygments-compatible colouring, JSON/XML pretty-printing) are all implemented in Odin. There is no Python runtime and no dependency on the reference implementation at run time.

The reference release's observable behaviour — CLI grammar, error wording, exit codes, request and response rendering — is the specification the port targets. For example, `--help`, `--manual` and `--version` print the recorded HTTPie 3.2.4 output.

Features include:

- Rendering the request without sending it (`--offline`).
- JSON, form, multipart and raw request bodies; request items for fields, query parameters, headers and file uploads.
- Basic, bearer and client-side Digest authentication; netrc credentials; proxies; redirects; timeouts; downloads; persistent sessions and cookies.
- Colour output matching HTTPie's Pygments styles, with JSON/XML formatting.

## Requirements

- An Odin toolchain, tested with `dev-2026-09:a2fb372b7`.
- `clang` (Odin's linker).
- The system libcurl development files: the build links with `-lcurl` (for example the `libcurl4-openssl-dev` package on Debian and Ubuntu). Curl's headers are not a build dependency — `src/http/libcurl.odin` declares the C symbols by hand.
- `make`.

The Makefile uses `odin` from `PATH` by default. A per-machine path belongs in the git-ignored `local.mk`, which the Makefile includes when present:

```make
ODIN := /usr/bin/odin
```

## Build and test

```sh
make build   # compile -> build/oj
make check   # type-check src and tests, no codegen
make test    # run the Odin unit suite in tests/
```

`make build` compiles with `-o:speed -vet -warnings-as-errors`. `make check` is the fast gate: it parse- and type-checks `src` and `tests` without code generation. `make test` runs the Odin unit suite under `tests/`.

| target | what it does |
| --- | --- |
| `all` | default target; builds the binary (same as `build`) |
| `build` | compiles `build/oj` with `-o:speed -vet -warnings-as-errors`, linking `-lcurl` |
| `check` | type-checks `src` and `tests` with `-vet -warnings-as-errors`, no codegen |
| `check-deps` | checks that the `ODIN` executable is available |
| `clean` | removes the `build/` directory |
| `test` | runs the Odin unit suite in `tests/` |
| `test-unit` | runs the Odin unit suite in `tests/` (`test` is an alias) |

A successful `make test` currently reports `Finished 176 tests ... All tests were successful.` and `colorize goldens: 421 cases, 0 mismatches`.

`tests/` is an Odin `@(test)` package. It also contains `tests/libcurl_test.odin`, which re-checks every libcurl option number against `curl_easy_option_by_name` at run time, and golden fixtures under `tests/golden/`.

## Usage and quick start

Build once, then invoke `build/oj`. The first examples are offline and need no server. `--version` prints the reference version:

```sh
./build/oj --version
```

```text
3.2.4
```

`--offline` builds and prints the request without sending it. The two flags below keep the example reproducible in scripts and terminals:

- `--ignore-stdin` stops `oj` from reading a request body from redirected stdin, so the command neither blocks on an open pipe nor changes its output when stdin is not a terminal. Scripting should pass it.
- `--pretty=none` disables terminal colouring, so the printed block is plain text and identical in a pipe and a terminal.

```sh
./build/oj --offline --ignore-stdin --pretty=none GET localhost:8000/hello
```

```text
GET /hello HTTP/1.1
Accept-Encoding: gzip, deflate
Accept: */*
Connection: keep-alive
User-Agent: HTTPie/3.2.4
Host: localhost:8000

```

The rendered block uses CRLF line endings (HTTP message framing); the line breaks above stand in for them, and the blank line after the headers ends the header block.

Request items (`name=value`, `Name:value`, `name==query`, and so on) build the body and the headers:

```sh
./build/oj --offline --ignore-stdin --pretty=none POST localhost:8000/hello name=world
```

```text
POST /hello HTTP/1.1
Accept-Encoding: gzip, deflate
Connection: keep-alive
Content-Length: 17
User-Agent: HTTPie/3.2.4
Accept: application/json, */*;q=0.5
Content-Type: application/json
Host: localhost:8000

{"name": "world"}
```

A real request (requires network access):

```sh
./build/oj --ignore-stdin --print=hb GET https://example.com
```

`--print=hb` selects the response headers and body. Without `--print`, the default follows HTTPie: `hb` when stdout is a terminal, and body only when stdout is redirected to a file or a pipe. `./build/oj --help` lists the full option set, including the request-item separators (`=` JSON/form field, `:=` typed JSON, `==` query parameter, `:` header, `@` file upload, `=@` embedded file content, `:=@` embedded raw JSON), the body-encoding flags (`--json`, `--form`, `--multipart`, `--raw`, `--boundary`), and the authentication, session, proxy, output and SSL options.

## Architecture

The Odin sources live under `src/`, split into packages by responsibility. `src/main.odin` is the entry point; the `-collection:src=src` flag makes the packages importable as `src:<package>`.

| package | responsibility |
| --- | --- |
| `src/main.odin` | process entry point: reads `context.allocator` once, parses argv, builds the session `Context`, and is the only place that calls `os.exit` |
| `src/cli/` | the argv parser and the parsed `Options`; the request-item mini-language; usage and error text; the recorded help and manual bytes |
| `src/session/` | the order of one invocation (meta flags, then request, send, render, exit code); cookie jar and session-file persistence |
| `src/http/` | the HTTP exchange: `Request`/`Response` types, URL splitter, body encodings, auth/digest, proxy/netrc, charset detection, the `send`/`send_to` transport seam, and the libcurl binding |
| `src/output/` | renderers writing to an `io.Writer`: the version line, errors, request and response blocks, byte-exact Pygments-style colouring |
| `src/format/` | body classification (Content-Type to `Kind`) and the JSON/XML pretty-printing models and parameters |
| `src/rich/` | the parts of rich's text rules the port needs (the emoji pass and its generated tables) |

The package import graph is acyclic:

```text
main    -> cli, output, session
session -> cli, format, http, output
cli     -> format, http, rich
output  -> format, http, rich
format  -> (no src imports)
http    -> (no src imports)
rich    -> (no src imports)
```

Boundaries and ownership:

- `src/http` imports neither `src/cli` nor `src/output`: the exchange knows nothing about the command line or the renderer.
- `src/http/libcurl.odin` is the only file that uses `foreign import` (C interop); it binds `system:curl`.
- The runtime default allocator, `context.allocator`, is read exactly once, in `src/main.odin`, and passed down explicitly. `context.temp_allocator` is used only as short-lived scratch.
- `src/output/` writes to an `io.Writer` it is handed and owns no memory.
- `src/main.odin` is the only place that calls `os.exit`.

Transport. The HTTP exchange is performed by libcurl through a hand-written, thin `foreign import` wrapper (`src/http/libcurl.odin`, linked with `-lcurl`), giving a single dynamically linked binary. libcurl was chosen over Odin's `core:net` (no TLS) and the Odin distribution's `vendor:curl` (its Linux link line pins mbedTLS, which does not match the OpenSSL-backed libcurl that distributions ship). `src/http/backend.odin` exposes the `send`/`send_to` transport seam; only the libcurl backend is compiled in. Digest authentication is implemented in the port (`src/http/digest.odin` and its MD5), not delegated to libcurl.

## Status and limitations

- The port targets HTTPie **3.2.4**; `./build/oj --version` prints `3.2.4`.
- There is no `LICENSE` or `COPYING` file in this repository.
- There is no CI configuration (`.github/` is absent).
- The tree contains no Python.
- The build depends on the system libcurl shared library.
- `--help` and `--manual` print recorded HTTPie 3.2.4 text. That text still advertises the `REQUESTS_CA_BUNDLE` environment variable, but the port does not read it: the only CA-bundle input is `--verify <path>`.
- The recorded help describes session files at `[HTTPIE_CONFIG_DIR]/<HOST>/<SESSION_NAME>.json`, whereas the implementation stores named sessions at `$HTTPIE_CONFIG_DIR/sessions/<host>_<port>/<name>.json`.
