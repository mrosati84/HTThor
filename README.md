# HTThor — HTTPie 3.2.4, ported to Odin

`HTThor` is a 1:1 port of the [HTTPie](https://httpie.io) command-line HTTP client, reference release **3.2.4**, to the [Odin](https://odin-lang.org) programming language. It is a single, dynamically linked executable: the argv parser and request-item mini-language, the request/response model, the HTTP exchange, and the terminal renderer (Pygments-compatible colouring, JSON/XML pretty-printing) are all implemented in Odin. There is no Python runtime and no dependency on the reference implementation at run time.

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
make build   # compile -> build/htthor
make check   # type-check src and tests, no codegen
make test    # run the Odin unit suite in tests/
```

`make build` compiles with `-o:speed -vet -warnings-as-errors`. `make check` is the fast gate: it parse- and type-checks `src` and `tests` without code generation. `make test` runs the Odin unit suite under `tests/`.

| target | what it does |
| --- | --- |
| `all` | default target; builds the binary (same as `build`) |
| `build` | compiles `build/htthor` with `-o:speed -vet -warnings-as-errors`, linking `-lcurl` |
| `check` | type-checks `src` and `tests` with `-vet -warnings-as-errors`, no codegen |
| `check-deps` | checks that the `ODIN` executable is available |
| `clean` | removes the `build/` directory |
| `test` | runs the Odin unit suite in `tests/` |
| `test-unit` | runs the Odin unit suite in `tests/` (`test` is an alias) |

A successful `make test` currently reports `Finished 188 tests ... All tests were successful.` and `colorize goldens: 421 cases, 0 mismatches`.

`tests/` is an Odin `@(test)` package. It also contains `tests/libcurl_test.odin`, which re-checks every libcurl option number against `curl_easy_option_by_name` at run time, and golden fixtures under `tests/golden/`.

## Usage and quick start

Build once, then invoke `build/htthor`. The first examples are offline and need no server. `--version` prints the reference version on its first line and this port's release and build revision on the second (see *Status and limitations*):

```sh
./build/htthor --version
```

```text
3.2.4
htthor 0.1.0 (aa04782-dirty)
```

The first line is HTTPie 3.2.4, the release the port matches; the second is this port's own release and the git revision the binary was built from (`make PORT_REVISION=... build` overrides it, and a build with no define stops at the release).

`--offline` builds and prints the request without sending it. The two flags below keep the example reproducible in scripts and terminals:

- `--ignore-stdin` stops `HTThor` from reading a request body from redirected stdin, so the command neither blocks on an open pipe nor changes its output when stdin is not a terminal. Scripting should pass it.
- `--pretty=none` disables terminal colouring, so the printed block is plain text and identical in a pipe and a terminal.

```sh
./build/htthor --offline --ignore-stdin --pretty=none GET localhost:8000/hello
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
./build/htthor --offline --ignore-stdin --pretty=none POST localhost:8000/hello name=world
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
./build/htthor --ignore-stdin --print=hb GET https://example.com
```

`--print=hb` selects the response headers and body. Without `--print`, the default follows HTTPie: `hb` when stdout is a terminal, and body only when stdout is redirected to a file or a pipe. `./build/htthor --help` lists the full option set, including the request-item separators (`=` JSON/form field, `:=` typed JSON, `==` query parameter, `:` header, `@` file upload, `=@` embedded file content, `:=@` embedded raw JSON), the body-encoding flags (`--json`, `--form`, `--multipart`, `--raw`, `--boundary`), and the authentication, session, proxy, output and SSL options.

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

- The port targets HTTPie **3.2.4**; `./build/htthor --version` prints `3.2.4` on its
  first line. The second line names this port's own release and the revision the
  binary was built from (`CHANGELOG.md`, *Versions*); the Makefile passes
  `git describe --always --dirty`, so `make PORT_REVISION=... build` overrides it.
- Reply bytes are sanitised on their way to a terminal: the C0 controls (except tab,
  LF, and the CR of a CRLF pair), DEL, the C1 controls and bytes that are not valid
  UTF-8 become U+FFFD before the renderer and the colouriser see them, so a server
  cannot emit a CSI/OSC sequence through a body or a header value. This is a
  deliberate divergence — HTTPie prints the server's bytes as they arrive.
  `HTTHOR_ALLOW_TERMINAL_ESCAPES=1` (any value but an empty string or `0`) restores
  the raw bytes. A non-terminal destination — a pipe, `-o FILE`, a download target —
  is never rewritten.
- `--auth user` with no password prompts in HTTPie. The port has no terminal layer,
  so the password comes from `$HTTHOR_AUTH_PASSWORD` instead, and a run that has none
  exits with an error rather than sending `user:` with an empty password. `-A bearer`
  is unaffected (its value is passed through unparsed upstream too), and
  `--cert-key-pass` / `--auth user:pass` stay on the command line exactly as upstream
  has them.
- A session file that is group- or world-readable when a run starts is reported and
  `chmod 0600`ed. HTTPie never checks; the file holds `raw_auth` in plaintext. Under
  `--session-read-only` it is reported and left alone.
- A reply body that nothing streams (no `--download` to a file) is buffered with a
  512 MiB cap, and a larger body is refused with an error instead of taking the
  machine down. HTTPie buffers without a limit.
- `--history-print/-P`, `--debug` and `--traceback` are accepted and recorded but read
  by nothing: the port prints no intermediary-hop view and has no Python traceback to
  print. The recorded `--help`/`--manual` text advertises them and cannot be edited
  (the bytes are pinned by `tests/cli_help_test.odin`), so the gap is disclosed here
  rather than left silent.
- `--stream/-S` picks the stream HTTPie picks for it, but it does not stream *while the
  reply arrives*. A prettified reply goes to the line-oriented `PrettyStream` instead of
  `BufferedPrettyStream`, which is observable in two places: an empty body is never
  handed to its encoder (a charset name no codec resolves is therefore not reported under
  `--stream`, where the buffered stream ends the run with HTTPie's `LookupError`), and a
  streamed body's last line ends in a line feed whether or not the body's own does. What
  is missing is the `tail -f` behaviour the recorded `--help` text advertises: HTTPie
  reads the reply one byte at a time, this port's transport hands the renderer a complete
  body (the sink that does reach bytes as they arrive is `--download`'s, and the 512 MiB
  cap above is the same fact seen from the other side). The recorded help text is not
  edited for it, for the reason the bullet above gives.
- `LICENSE` carries the upstream HTTPie BSD 3-Clause text, including its copyright
  notice and disclaimer (see *Licence and provenance* below).
- There is no CI configuration (`.github/` is absent).
- The tree contains no Python: the eight `*_generated.odin` tables name generators that
  are not checked in, so refreshing them means re-creating the generator first
  (`docs/PROVENANCE.md` records each table's hash and source pins).
- `docs/PROVENANCE.md` is the provenance trail: it accounts for the removed `docs/` tree,
  the capture corpus and the probe/generator scripts the sources cite, and indexes the
  `docs/PARITY.md` section citations those comments carry.
- The build depends on the system libcurl shared library.
- `--help` and `--manual` print recorded HTTPie 3.2.4 text. That text still advertises the `REQUESTS_CA_BUNDLE` environment variable, but the port does not read it: the only CA-bundle input is `--verify <path>`.
- The recorded help describes session files at `[HTTPIE_CONFIG_DIR]/<HOST>/<SESSION_NAME>.json`, whereas the implementation stores named sessions at `$HTTPIE_CONFIG_DIR/sessions/<host>_<port>/<name>.json`.

## Licence and provenance

`HTThor` is a derivative work of [HTTPie](https://httpie.io) 3.2.4, which is
Copyright © 2012-2022 Jakub Roztocil and contributors and is distributed under the
BSD 3-Clause licence. `LICENSE` at the repository root carries that licence text with
the upstream copyright notice and disclaimer retained verbatim, which conditions 1
and 2 of it require of a derivative work; the port is distributed under the same
licence. `HTThor` is not affiliated with, or endorsed by, the HTTPie project.

`docs/PROVENANCE.md` is the rest of the provenance trail: which upstream release and
files the port was written against, what happened to the port's own specification
(`docs/PARITY.md`), capture corpus and generator/probe scripts the sources cite, and
an index of the `docs/PARITY.md` section citations the source comments carry.

