# oj architecture

`oj` is a 1:1 port of httpie to Odin. This document is the contract for the
tasks that build on the scaffold: layout, module boundaries, the HTTP/TLS
backend choice, and the memory ownership rules. Change it deliberately or not at
all; do not let code drift away from it silently.

Written by t_89f5bafa (scaffold), against Odin `dev-2026-09` (nightly a2fb372)
on Ubuntu 24.04 with libcurl 8.5.0. Revised by t_6bb80c81 against HEAD `c20e75e`:
the full §1 inventory, §2's import graph and allocation rule, §4's
`temp_allocator` rule, §5's golden replay, §6, and the new §8.

## 1. Repository layout

```
src/main.odin          process entry point: reads the allocator once, parses argv,
                       builds the session Context, exits with the run's exit code
src/cli/               the parsed command line and the argv parser
  options.odin         Options (the parsed command line), its defaults, destroy proc
  parse.odin           the argv parser: option table, config/env defaults
  items.odin           the request-item mini-language (name=value, name:=json,
                       name==query, name:header, name@upload, bracket paths)
  usage.odin           the usage/error block the parser's failures print
  python_digits.odin   the CPython predicates rich's $COLUMNS gate runs
  python_digits_generated.odin  their tables (generated)
  help_text_generated.odin      the recorded --help/--manual bytes (generated)
src/session/           the order of an invocation (meta flags -> request -> send
                       -> render -> exit code)
  context.odin         Context: that order, and the exit-code mapping
  jar.odin             the session cookie jar (Set-Cookie replies -> Cookie header)
  store.odin           session-file persistence (httpie's JSON session format)
src/http/              the exchange: Request/Response types, URL splitter, dispose
                       helpers, the transport (`send`) and the libcurl binding
  types.odin           Method/Scheme/Header/Data_Item/Request/Response/Error
  url.odin             the URL splitter and the default-scheme heuristic
  host.odin            the URL host: lowercase, escape-folding, IDNA, refusal rules
  request.odin         request_create and the builders (target, URL, Host, auth
                       header); request_prepare fills the derived headers
  owned.odin           allocator-explicit Buffer/slice helpers (see §4)
  body.odin            the body encodings: JSON, form, multipart, raw
  auth.odin            the Authorization header for basic/bearer
  digest.odin          the client-side Digest handshake (RFC 2617)
  md5.odin             MD5 (RFC 1321), for that handshake
  netrc.odin           credentials from the user's netrc file
  proxy.odin           --proxy + environment/no_proxy resolution
  header_validity.odin requests' check_header_validity
  skippable.odin       urllib3's SKIPPABLE_HEADERS / SKIP_HEADER sentinel
  python_str.odin      the reference's *str* layer (surrogateescape) in bytes
  detect.odin          detect_encoding: the printed body's charset guess
  detect_cd.odin       the coherence detector half of that guess
  detect_md.odin       the mess-detector half of that guess
  charset.odin         smart_decode/smart_encode: the printed text's codecs
  backend.odin         the `send`/`send_to` seam (the transport choice)
  curl_transport.odin  the exchange itself: options, callbacks, the redirect loop
  libcurl.odin         the only file that touches C
  charset_generated.odin, detect_generated.odin, idna_generated.odin,
  unicode_printable_generated.odin  the generated tables the files above read
src/output/            renderers writing to an io.Writer (see the allocation rule
                       in §2)
  print.odin           the version line, errors, the request/response blocks
  render.odin          the parity renderer: httpie's output contract, byte for byte
  colorize.odin        byte-exact emulation of httpie's Pygments colouring
  styles_generated.odin  the Pygments style table (generated)
src/rich/              rich 15.0.0's own text rules the port needs: the emoji
                       pass (`:code:` -> the table's value) and the cell widths a
                       wrap measures, with the generated tables beside them
  emoji.odin           the emoji pass
  emoji_generated.odin its table (generated)
src/format/            body classification (Content-Type -> Kind) and the
                       pretty-printing parameters the renderer will consume
  content_type.odin    Kind, kind_for_content_type and the Indent enum
  json.odin            the JSON value model, parser and serializer
  xml.odin             XML pretty printing (httpie's XMLFormatter)
tests/                 Odin `core:testing` suite (behaviour + ownership)
docs/                  this file, RATING.md, security-findings.md
```

## 2. Module boundaries

Dependencies point one way only (this is the import graph the code has today,
one line per package):

```
main    -> { cli, output, session }
session -> { cli, format, http, output }
cli     -> { format, http, rich }
output  -> { format, http, rich }
format  -> {}
http    -> {}
rich    -> {}
```

Rules that hold the boundary in place:

- **`http` imports neither `cli` nor `output`.** The transport must be usable
  without a command line; that is also what makes it testable with a plain
  struct. The session copies the parsed options down onto the Request, because
  the session is the only layer that knows both vocabularies.
- **`output` writes to an `io.Writer` it is handed and owns no memory.** No
  direct `os.stdout`/`os.stderr`, no formatting state kept between calls; that is
  what lets the tests render into a `strings.Builder` and compare bytes. It is
  not literally allocation-free: ten `make(` sites allocate scratch buffers, and
  the rule is that they pass an allocator explicitly — seven do
  (`colorize.odin:217,227,236,253,271`, `render.odin:283,457`) and three still
  fall back on the implicit `context.allocator` (`colorize.odin:917,919,947`).
  The three are known debt; new code must not add a fourth (see §8).
- **`format` owns classification, not formatting.** `Kind` and
  `kind_for_content_type` decide *what* a body is; the pretty printer that
  consumes the decision is the renderer (`output/render.odin`), with the JSON/XML
  value models in `format/json.odin` and `format/xml.odin`. `Indent` lives here
  too because the CLI collects it (`--format-options json.indent=N`).
- **The CLI is a parse, not a policy.** `cli.parse_args` returns Options or a
  usage error; it never prints and never exits, and the only filesystem reads it
  performs are the ones parsing requires: the config file (`config_read`
  → `config.json`, `parse.odin:2261`, called from `parse_args_with` `:3179`),
  argparse's own readability probes (`file_is_readable` `:1745`, opening at
  `:1746`; `file_is_openable_for_append` `:1755`, opening at `:1756`; both called
  from the option validation at `:1300`/`:1306`), and the item files
  (`cli/items.odin:861`). Wording of errors belongs to `output` (and to
  docs/PARITY.md).
- **Only `main` exits.** `session.run` returns an exit code (`cli.Exit_Code`);
  `main` destroys the Context and calls `os.exit` with it. Nothing else calls
  `os.exit`, and no `defer` in `main` is relied upon (defers do not run across
  `os.exit`).
- **Only `src/http/libcurl.odin` talks to C.** Everything above it uses Odin
  types with explicit lengths.
- **`src/http/backend.odin` is the transport seam.** `send(req, res) -> Error`
  (plus `send_to(req, res, sink)` for a download) is the whole surface the
  session needs; swapping the backend means replacing what sits behind those
  procs, plus the `Backend` value.

## 3. HTTP/TLS backend: libcurl, and why

The requirement is httpie parity: HTTPS with verification, proxies, redirects
with per-method rewriting, Basic/Digest/Bearer auth, chunked and
gzip/deflate/br decoding, client certificates, timeouts. That set decides the
backend; everything below was considered.

**`core:net` alone (rejected for anything but plain HTTP).** The Odin standard
library ships TCP/UDP sockets, DNS and an event loop — and no TLS. It also has
no HTTP/1.1 framing, no proxy CONNECT, no digest auth, no content decoding and
no redirect policy. Using it means hand-writing the protocol *and* vendoring a
TLS stack (BearSSL/mbedTLS bindings), i.e. owning a security-sensitive surface
that libcurl has had audited for decades, plus the system CA-bundle handling
that goes with it. That is a project of its own, not a scaffold.

**The Odin distribution's own `vendor:curl` (rejected, concretely).** It exists,
but its Linux foreign import is pinned to mbedTLS:

```odin
// vendor/curl/curl.odin (dev-2026-09)
} else {
	@(export)
	foreign import lib {
		"system:curl",
		"system:mbedtls",
		"system:mbedx509",
		"system:mbedcrypto",
		"system:z",
	}
}
```

Ubuntu's libcurl is OpenSSL-backed (`libcurl/8.5.0 OpenSSL/3.0.13 ...`) and the
machine has no mbedTLS development libraries, so that link line does not resolve
here (and would not in CI either, without pulling a second TLS stack in). It
also exposes curl's entire API surface, which is far more than this project
wants to depend on.

**Chosen: a hand-declared thin `foreign import` over the system libcurl**
(`src/http/libcurl.odin`), linked with `-lcurl`. It declares exactly the symbols
the engine needs — `curl_global_init/cleanup`, `curl_version`, `curl_easy_init/
cleanup/reset/setopt/getinfo/perform/strerror`, `curl_easy_option_by_name`,
`curl_easy_escape/unescape`, `curl_slist_append/free_all`, `curl_free` — and the
`CURLOPT_*`, `CURLINFO_*`, `CURLE_*`, `CURLAUTH_*` constants for the options the
engine sets. Because the declarations are manual, curl's headers are *not* a
build dependency: only `libcurl.so` is.

Two things keep the hardcoded constants honest:

- their provenance is written down in the file: curl 8.5.0
  (`curl/curl.h`, `curl/options.h`, where an option's number is its tick type
  plus its index in the `CURLOPT` list);
- `tests/libcurl_test.odin` asks libcurl itself, via
  `curl_easy_option_by_name`, which number belongs to each option name, and
  fails if the constant disagrees. A typo cannot survive `make test`.

Consequences to keep in mind (they are the engine's problem, not the scaffold's,
but they come from this choice):

- HTTPS verification, CA bundle discovery, HTTP/2 and brotli/zstd decoding are
  the *system* libcurl's features. `--verify`, `--proxy`, `--timeout`,
  `--follow`, `--max-redirects`, `--cert`, `--auth` map 1:1 onto curl options.
- curl's error strings are not httpie's. The engine translates libcurl codes
  into `http.Error` and uses the wording captured in docs/PARITY.md.
- `curl_global_init` must run once before any easy handle and
  `curl_global_cleanup` at the end; the engine owns that, the tests show both.
- libcurl decides *both* halves of an exchange from one request kind: the option
  that makes it send a body and the one that makes it read a reply body are the
  same decision, and the only switch for "this reply has no body"
  (`CURLOPT_NOBODY`) suppresses the request body with it. A HEAD that carries
  bytes (items, or a `--chunked` upload whose only byte is the terminating
  chunk) therefore cannot be asked of libcurl as one transfer: the engine sends
  it like any other hop and the header callback cuts the transfer at the end of
  the reply head, which is also what the reference's own transport does with a
  HEAD (`src/http/curl_transport.odin`'s `Transfer.head_reply_only`;
  docs/PARITY.md §4.1).
- **Digest auth is not libcurl's here.** requests' Digest is a client-side hook
  (`HTTPDigestAuth.handle_401`: read the challenge, throw its body away, build
  the answer, send the same prepared request again), so the port's copy of the
  handshake lives in the port — `src/http/digest.odin` and its own RFC 1321 MD5
  — and the hop loop sends the request twice, the first time bare. libcurl is
  not asked for it: with a `--chunked` upload it deadlocks against any server
  that reads the body before answering (libcurl writes the framing head and
  waits for the challenge while the server waits for the terminating chunk),
  and a HEAD that carries bytes never completes its retry, because the reply to
  a HEAD has no body to read and `CURLOPT_NOBODY` — the only switch for that —
  takes the request body with it (the consequence above).
  That road was measured against a server that answers at the head before the
  body is written.

**Link model / "single binary".** The build produces one executable, `build/oj`,
dynamically linked against `libcurl.so.4` and libc. A fully static link needs a
static libcurl *and* its dependency chain (libssl, libcrypto, zlib, brotli, zstd,
nghttp2, psl, idn2, …), which this environment cannot install without root; the
Makefile's `CURL_LIBS` / `LINK_FLAGS` variables are where that switch goes for a
build environment that has them.

**When to revisit:** if httpie parity ever drops TLS/decoding requirements, a
`core:net` backend becomes viable behind the same `send` seam. That is the point
of `backend.odin`.

## 4. Memory ownership

The hard rule: **`context.allocator` is read exactly once**, in `main`
(`src/main.odin:18`), and is then passed explicitly down every layer. No other
file under `src/` reads it — not for a temporary string, not "just this once".
Library code that needs memory takes a `mem.Allocator` parameter.

`context.temp_allocator` falls under the same rule, **and the tree does not
satisfy it yet**: 21 non-comment uses remain in 7 files — `cli/parse.odin` 9,
`session/jar.odin` 4, `http/detect.odin` 3, `http/charset.odin` 2, and one each in
`output/render.odin`, `session/context.odin`, `session/store.odin`. They are
scratch-string sites (the suite's leak assertions still pass), but they are
exactly the implicit-allocation model this section forbids. They are recorded as
debt in §8: new code must take an allocator parameter, not add a 22nd use.

Follow-on rules:

1. **Owning structs remember their allocator, so destroy takes only a pointer.**
   `cli.Options`/`options_destroy`, `cli.Parse_Error`/`parse_error_destroy`,
   `http.Request`/`request_destroy`, `http.Response`/`response_destroy`. The
   allocator that created the struct is the allocator that frees it.
2. **Who allocates what:**

   | buffer | allocated by | freed by |
   | --- | --- | --- |
   | `Options` and every string/slice in it (`program_name`, `url`, `items`, `proxy`, `cert`, `cert_key`, `cert_key_pass`, `verify`, `auth`, `style`, `output_file`, `raw_body`) | `cli.options_default` / `cli.parse_args`, from the allocator `main` passed | `cli.options_destroy`, called by `session.context_destroy` (the `Context` takes ownership in `context_create`) |
   | the request's transport-policy strings — `Request.proxy`, `.cert`, `.cert_key`, `.cert_key_pass`, `.ca_bundle` | nothing: the session **aliases** the `Options` strings into the `Request` (`session/context.odin`, where the two meet) | `cli.options_destroy`, never `http.request_destroy`. Two owners free twice: that double free is what made every `--cert` run — and every `--proxy` entry the session did not select — crash or leak until it was closed |
   | the usage-error `message` | `cli.usage_error`, same allocator | `cli.parse_error_destroy`, called by `main` |
   | `Request` and its `host`, `path`, `userinfo`, `headers`, `query`, `body` | `http.request_create` (and, later, the engine's builder), from `Options.allocator` | `http.request_destroy`, via `defer` in `session.run` |
   | `Response` and its `reason`, `http_version`, `url`, `headers`, `body` | `http.send`, from `req.allocator` | `http.response_destroy`, via `defer` in `session.run` |
   | renderer output | nothing: `output` writes into the caller's `io.Writer` | — |

3. **Nothing borrowed survives the value it came from.** Every string a struct
   keeps for its own use is a copy taken from its allocator; argv and caller
   buffers are read-only inputs. The one deliberate exception is the
   transport-policy set in the table above (`Request.proxy`, `.cert`,
   `.cert_key`, `.cert_key_pass`, `.ca_bundle`), and it is safe for a reason
   that is part of the rule rather than an accident: those strings are only ever
   read while the `Options` that own them are alive. `session.run` destroys the
   `Request` in a `defer` before it returns, and `main` destroys the `Options`
   through `context_destroy` only after `run` has returned — nothing reads a
   string after it is freed, and the single owner frees each one exactly once.
   (Borrowing is also what keeps this cheap: the alternative is a clone per
   string for a value that is only ever passed to the transport.)
   This is also why the tests build their fixtures with the allocator instead of
   using slice/string literals: a literal is static data and freeing it is a bad
   free, which `mem.Tracking_Allocator` reports as such.
4. **Zero values are destroyable.** `request_destroy`, `response_destroy`,
   `options_destroy`, `parse_error_destroy` accept a zero value and zero their
   argument after freeing, so double destroys are no-ops and `defer` is always
   safe — including on the paths where nothing was allocated yet.
5. **Every error path frees what it built.** `usage_error` destroys the partial
   `Options` before returning; `request_create` destroys the partial `Request`
   before returning `Out_Of_Memory`; `main` destroys the `Parse_Error` before
   exiting. There is no "the process is about to die anyway" reasoning in
   library code — the tests run their allocating paths on a
   `mem.Tracking_Allocator` and assert a zero balance (§5 names the three files
   that do not).
6. **Allocation failure is not swallowed.** Allocation sites use the two-value
   form (`strings.clone(s, allocator)`) and map a failure to
   `Error.Out_Of_Memory`, which the session turns into an error message. The one
   place where a failure has no better answer than "no name"
   (`options_default`'s `program_name`) leaves the field empty rather than
   pretending.
7. **C interop keeps its lengths.** Everything crossing into libcurl is a
   `cstring` (NUL-terminated, outliving the call), and everything coming back is
   copied at the boundary using the length the API reported — `curl_easy_getinfo`
   fills a caller-owned value, `curl_slist` entries are copied out with their
   length. Only `curl_version`/`curl_easy_strerror` return static strings that
   libcurl owns; they must not be freed and must be copied if kept. No `cstring`
   escapes `src/http/libcurl.odin`.

8. **`defer` runs when its *block* ends, not its function.** A `defer` inside an
   `if`/`for` body fires as that body ends, so
   `if len(contents) > 0 { defer delete(contents, a) }` frees the bytes while the
   code below still uses them (this was a real use-after-free in the multipart
   encoder and in the basic-auth builder). Keep a `defer` at the scope that owns
   the value, and give the resource a named variable when the block is conditional:

   ```odin
   clone: string
   defer delete(clone, allocator)   // function scope, frees "" harmlessly
   if condition {
       clone = strings.concatenate({...}, allocator) or_return
   }
   ```

9. **C callbacks set the runtime context themselves.** A `proc "c"` has no Odin
   context, so `curl_transport.odin`'s three libcurl callbacks start with
   `context = runtime.default_context()` (`write_callback` `:529`, `read_callback`
   `:557`, `header_callback` `:576`). That is the idiom, not a loophole:
   nothing below them reads an allocator out of it — every buffer carries its own
   (`Buffer`) and every allocation takes the allocator as an argument.

## 5. Build, tests and memory checks

`make build` compiles `src` with `-o:speed -vet -warnings-as-errors`: **zero
warnings is enforced by the build**, not asserted in a document. `-vet` also
catches unused imports/variables, shadowing and `using`, so the scaffold stays
tidy as tasks land.

`make check` is the same gate without codegen (`odin check src` plus
`odin check tests -no-entry-point`, since `tests/` is a `@(test)` package): use
it while iterating. This Odin release ships no `odin fmt` (only
`odin strip-semicolon`), so formatting is a convention rather than a target:
tabs for indentation, trailing commas in multi-line literals, braces attached.

`make test` runs the Odin unit suite in `tests/`: `odin test tests
-collection:src=src -vet -warnings-as-errors`. The suite covers the URL splitter
and scheme heuristic, the parser (both `--flag value` and `--flag=value`, `--`
terminator, usage errors), the request/response dispose helpers, the session's
exit codes and rendered bytes, the session store and cookie jar, the Content-Type
classifier, and the libcurl constants. Every test that builds an owning struct
runs on a `mem.Tracking_Allocator` and finishes with `expect_no_leaks`, so the
ownership rules above are *executed*, not just documented: a leak shows up as a
non-zero balance when the allocator is checked, and the test fails. Tests that
copy a fixture into an owning struct use the allocator, which is what makes a
"forgot to clone" mistake visible. Three files run no tracking allocator, so
their allocations are not balance-checked (§8): `tests/charset_test.odin` and
`tests/colorize_test.odin`, which do allocate (`charset_test.odin:205,233-234`,
`colorize_test.odin:30,31,48` use `context.temp_allocator`), and
`tests/libcurl_test.odin`, which also has none but allocates nothing at all.

The colorize golden replay lives in `tests/colorize_test.odin`: it walks
`tests/golden/colorize/` against `manifest.tsv` case by case (it must be run from
the repository root) and prints
`colorize goldens: <cases> cases, <mismatches> mismatches`.

`tests/http_engine_test.odin` is the engine's part of the suite: it starts a
one-thread HTTP server on 127.0.0.1:0 inside the test, records the raw bytes of
every request it receives, and answers with a canned reply — so the assertions
are about the **wire** (the JSON/form/multipart/raw bodies, the Authorization
header, the request line of each hop of a redirect chain) and about what the
engine gives back (status, headers, decoded chunked/gzip bodies, typed errors
for a refused connection, a failed lookup and a timeout), not about the engine's
own idea of what it sent. It builds on its own (`odin test
tests/http_engine_test.odin -file -collection:src=src` — `-file` needs the
collection flag too), which is why its helpers are file-local.

`local.mk` (git-ignored, `-include`d by the Makefile) holds per-machine toolchain
paths; `make check-deps` reports a missing `odin` as an error.

## 6. CI

**There is no CI configuration in this tree.** `.github/` does not exist, so no
workflow file is checked in and nothing runs on a push; earlier revisions of this
document described a `.github/workflows/ci.yml` that was never landed. The gate
is what a developer runs locally, on Ubuntu with `clang` and libcurl's
development files (`libcurl4-openssl-dev`) installed: `make build` and
`make test` — the same two commands a reviewer would run. A green run therefore
means: zero warnings, and all Odin tests pass (including the ownership
assertions). If a workflow is ever added it must run exactly those two commands,
or this section has to be rewritten with it (see §8).

## 7. Who fills what in (and what must not change)

| task | owns | must keep |
| --- | --- | --- |
| t_9a017f57 (CLI + renderer) | the body of `cli.parse.odin` (item grammar, config files, env defaults), `output/`, `format/` | the `Options`/`Parse_Error` shapes and their destroy procs; `output` keeps taking an `io.Writer` and keeps its allocators explicit (§2) |
| t_3d62ca31 (engine) | `http.send`, the rest of `request_create` (query, headers, body encodings, auth), `libcurl.odin` additions | the `Request`/`Response` fields and destroy procs; the allocator rules in §4; no C outside `libcurl.odin` |
| t_2ad8c0b2 (review) | the review output — `docs/REVIEW.md` was never landed; reviews now live in `docs/RATING.md` and `docs/security-findings.md` | findings reference `file:line` and this document's rules; blockers are left for the owning task |

The engine's seam, as landed (t_3d62ca31):

- **The session fills the model; the engine derives the wire.** `Request.headers`
  carries what the caller wants — including, in httpie's order, `User-Agent`,
  `Accept-Encoding` and `Connection`, and `Host` via `request_host_header`.
  `request_prepare` then adds what is derived from the body
  (`Content-Length`, `Content-Type`, `Accept`) and the preemptive
  `Authorization`, each only when the caller has not supplied one
  (case-insensitively). `build_request` also *strips every merged value once*
  (`http.request_strip_header_values`: httpie's `finalize_headers`,
  docs/PARITY.md §3.1) — that happens before the session records the headers and
  before the renderer and the transport read the list, so the three agree.
- **The transport owns one header on the wire, and the decoding.** `Host` is skipped when the
  model's headers are turned into libcurl's list, because libcurl derives it (a caller-supplied
  `Host` is an entry like any other, and libcurl sends it as it stands). Every other line is
  written from that list, so it keeps httpie's position: `Content-Length`, `Content-Type` and
  `Transfer-Encoding` are dropped only on a hop that followed a 301/302/303 — `requests`'
  `resolve_redirects` purge, docs/PARITY.md §8.18(g) — a chunked upload's framing is written only
  when the hop really is such an upload, and `Accept-Encoding` travels as the caller's entry
  while `CURLOPT_ACCEPT_ENCODING` stays set to the announced value: the option is what decodes
  the reply, and libcurl leaves a header of its own out once the name is in
  `CURLOPT_HTTPHEADER`, which is what keeps the caller's line — and its position — intact. An
  *empty* value is written as libcurl's `Name;` form, because libcurl reads `Name: ` (nothing
  after the colon) as its own removal syntax and would drop the line `requests` sends.
- **The redirect chain is the engine's loop, not `CURLOPT_FOLLOWLOCATION`.** A
  custom request method survives libcurl's own redirect handling unchanged, so
  only a loop of our own applies httpie's rules to the bytes that go out
  (303 → GET, 301/302 POST → GET, 307/308 keep the method and the body; a hop that followed
  anything else loses the body and the three headers that describe it — `requests`' purge, see
  the bullet above). *Which* 3xx is a redirect at all is `requests`' `is_redirect` —
  `http.is_redirect_hop`, one of `REDIRECT_STATI`'s five statuses (301/302/303/307/308) *and* a
  `Location` — so a `300`/`304`/`305` that carries one is the response, body and all
  (docs/PARITY.md §8 item 19), and a status of the five without the header is the response too,
  because `resolve_redirects`' `while url:` ends on the empty target. Hops
  land in `Response.history` (intermediate only — `--all` prints those plus the
  final response), credentials do not follow a redirect to another origin, and
  the depth limit surfaces as `Error.Too_Many_Redirects`. A chain that *dies*
  mid-follow publishes the hops it made on `Request.follow_history` instead — a
  failed `send` leaves the reply zeroed (the engine's contract) and the request
  is what the caller frees, so `request_destroy` releases those entries exactly
  like `response_destroy` does `Response.history`'s.
- **`--follow` is the caller's flag.** Without it a 3xx is an ordinary response:
  status, headers and body are returned as they arrived.
- **Argv stays bytes; the reference's `str` layer is modelled on top of it.**
  CPython decodes argv with `surrogateescape`, so a byte that is not valid UTF-8
  is a lone surrogate to httpie, and every re-encode of one raises
  `UnicodeEncodeError` — except in the URL, which percent-encodes it.
  `http/python_str.odin` owns that layer (`str_utf8_seq_len`,
  `str_encode_failure`, `str_encode_failure_lone`, `Request.encode_error`), and the four
  places that can fail call into it: `build_request`, `request_prepare`/the body encoders, the
  rendered head, and the CLI's own parse step — where `--raw`'s value is encoded, because the
  reference encodes it there (httpie's `parse_args`, outside its error handling: the one
  failure of the family that prints no `usage:` block, `cli.Parse_Error_Kind.Exception`).
  The transport adds the ascii rule CPython's `putheader` applies
  to a header *name*. A `:=` value can also hold a character argv never carried — a lone
  surrogate the item's own JSON text spelled — and that one has no byte at all, so it travels
  out of band (`format.Surrogate_String`, `http.Lone_Surrogate`) and the same encoder check
  reads it from the marks beside the string. docs/PARITY.md §3.4/§3.6 have the surfaces and the
  message shape.

`src/session/` owns session-file handling (`--session`, cookies:
`session/store.odin`, `session/jar.odin`); it stays the only layer that knows the
order of an invocation. The session JSON follows httpie's own file
(`httpie/sessions.py`, `httpie/config.py`); the spec that used to be cited here,
`docs/PARITY.md` §6.3, is absent from this tree (§8).

Rules for every task that touches this tree:

1. `make build && make test` must pass before you claim the work is done; both
   are cheap, and the suite's tracking-allocator assertions are what catch
   ownership mistakes.
2. New allocation sites take the allocator as a parameter and use the two-value
   `strings.clone`/`make`/`new` form, freeing on both the success and the error
   path — or add a test that proves otherwise to this document first.
3. New owning types follow the `..._destroy(ptr)` pattern (allocator stored in
   the struct) and accept a zero value.
4. Behaviour that the tests cannot decide comes from the reference `httpie` 3.2.4
   — its source, or captures of its bytes — not from preference. The document
   that used to record those decisions, `docs/PARITY.md`, is **not present in
   this tree** (§8); read the citations to it in `src/` and `tests/` as pointers
   to the reference implementation until it is restored.

## 8. Known deviations and open items

Everything above describes the tree at commit `c20e75e`. The items below are the
places where the tree and its documentation were known to disagree at that
commit. They are deliberately **flagged, not silently "fixed"**: each one needs
either a code change or a human decision, and rewriting this document to hide it
would only move the inaccuracy around (task t_6bb80c81).

**Artifacts cited by the tree but absent from it.**

- `docs/PARITY.md` — the reference-behaviour spec, cited across the tree (11
  times in this file). §2, §3, §7 and §8 cite it, most with a section number;
  today those citations point at the reference `httpie` 3.2.4 sources.
- `docs/REVIEW.md`, `tests/golden_test.odin` + `capture_argv` — see §5 and §7.
- `tests/parity/` and `tests/parity/server.py`.
- `build/probe_*.py` / `build/probe_*.c` (wire and digest measurements) and the
  `build/gen_*.py` table generators named by the generated files' own headers.
- `docs/parity-captures/` (the help/error captures), `docs/COLORIZE.md`,
  `tools/ref-capture/*`, `tools/gen-help-text.py`.
- the repository has no `LICENSE` or `COPYING` file, so nothing in the tree
  states the terms this port may be used or redistributed under.
- `.gitignore:12-15` still ignores `/.capture-sandbox/`, described there as
  scratch left behind by the removed parity harness; the directory itself is not
  in any checkout. The rule is harmless, and it is left in place rather than
  removed, because deleting it would change what a future run of that harness
  would track.

**Contracts the code does not meet yet.** 21 `context.temp_allocator` uses (§4);
three allocator-less `make(` sites in `src/output` (§2); the three test files that
run no tracking allocator — `tests/charset_test.odin` and
`tests/colorize_test.odin` (which allocate), plus `tests/libcurl_test.odin`
(which allocates nothing) (§5).

**Code-vs-help-text disagreements — no documentation edit can fix them.** The
`--help`/`--manual` bytes in `src/cli/help_text_generated.odin` are *recorded
reference captures* of httpie's own output, not this port's prose, so they are
not edited to agree with the port:

- `REQUESTS_CA_BUNDLE` is advertised by `--help` but read by no code; the only
  CA-bundle input is `--verify <path>` → `CURLOPT_CAINFO`
  (`src/http/curl_transport.odin:1426`). A parity decision, not a doc fix.
- the help text's session path (`[HTTPIE_CONFIG_DIR]/<HOST>/<SESSION_NAME>.json`,
  `--help` line 264) differs from the implemented one
  (`$HTTPIE_CONFIG_DIR/sessions/<host>_<port>/<name>.json`,
  `src/session/store.odin:199-203` and the build at `:245-252`).
- the help promises "for every `--OPTION` there is also a `--no-OPTION`", but the
  blanket form fails on every option except `--no-sorted`/`--no-unsorted`:
  `apply_no_options` passes the bare name to `reset_option`
  (`src/cli/parse.odin:1785`), which compares it against names carrying the `--`
  prefix (`:1800-1815`). **This is a code bug, not a doc bug**, and needs a code
  fix.
- `--history-print`/`-P`, `--no-sorted` and `--no-unsorted` are accepted by the
  parser but appear in neither help text.

**Point-in-time documents.** `docs/RATING.md` grades commit `f13d8f3`, 11 commits
before this one, and is deliberately left exactly as graded: its verdicts are its
own, and what changed since (F1 and F6 fixed, F8 no longer reproducible) is
recorded in `docs/security-findings.md` §V and here, not by rewriting the report.
Read its counts and `file:line` citations as of `f13d8f3`; at `c20e75e` the suite
has 173 `@(test)` procs (not 167), `src` is 64,310 lines (not 64,112), the leak
assertions number 116 (not 109), and `docs/PARITY.md` is cited 224 times under
that report's own counting command (`grep -ro 'PARITY\.md' src tests
docs/ARCHITECTURE.md README.md Makefile`; 223 at `f13d8f3` — this revision adds
one citation), or 229 across the same set plus `docs/security-findings.md`'s
five. One of its caveats does not reproduce here: this machine's libcurl is
8.5.0, which is what §3 pins, so the "stale pin" complaint is a property of the
machine the report was measured on.

**Line-number citations.** This document was revised in 2026-09 (the full §1
inventory, §2's real import graph, §4's restatement of the `temp_allocator` rule,
§6's correction, this section), so `docs/ARCHITECTURE.md:<line>` citations
recorded elsewhere — `docs/RATING.md`, `docs/security-findings.md` §5 — use the
pre-revision numbering. Locate a passage by its section number or its quoted
words; the section numbering is stable.
