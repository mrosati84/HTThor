# Chapter 3 — Security — Rating: 7.3/10 (B)

Reviewed commit: `730a497e9e20054b00de2f1c21a54d0c9f567960` ("rebrand oj -> htthor"), tree
`/home/matteo/Projects/htthor`, 2026-09-21. Static review of `src/` (64,315 lines of Odin) plus
execution of `build/htthor` against two loopback listeners written for this review
(`127.0.0.1:18999`, `:19001`); no third-party service was contacted. "Reference" = HTTPie 3.2.4's
stack: `requests` 2.33.0, CPython 3.14 `urllib`. Gates: `make test` green (176 tests, 421/421 goldens).

Verdict: **issues found — no Critical or High.** Secure defaults hold where it matters: TLS
verification is on and fail-closed, redirect credential stripping matches `requests`, request-side
CRLF injection is refused twice, and memory safety is structurally enforced. The deductions: a silent
no-op in a TLS control, escape sequences passed to the user's terminal, an unbounded reply buffer,
and two divergences from the reference's own hardening.

## Sub-scores

| Dimension | Score | Basis |
| --- | --- | --- |
| Transport security (TLS) | 7.5 | Verified by default, fail-closed; `--verify=<pem>`/`--ciphers` applied. Docked for F-01. |
| Credential handling | 7.5 | Per-hop Authorization rebuild, cross-origin strip, 0600 sessions. Docked for F-06. |
| Input parsing | 9.0 | Two-layer header-injection refusal; IDNA2008; `urlsplit` CR/LF/TAB deletion. |
| Output & file safety | 6.0 | Download naming server-independent (clean); response bytes unfiltered (F-02). |
| Memory safety & build hardening | 6.5 | No `#no_bounds_check`/`assert` in `src/`; unbounded reply buffer (F-03). |

Mean = 7.3 → **B**. No Critical finding, so the 5.0 cap does not apply.

## Checked and clean

* **TLS default on, fails closed.** `verify_enabled` (`src/session/context.odin:942`, `:1222-1230`) →
  `CURLOPT_SSL_VERIFYPEER 1` / `CURLOPT_SSL_VERIFYHOST 2`
  (`src/http/curl_transport.odin:1409-1416`). Measured: self-signed listener →
  `htthor: error: TLS handshake failed …`, exit 1; `--verify=no` → 200; `--verify=<pem>` → 200, still
  verifying. No path disables the hostname check alone. `--ciphers` is applied (`:1434-1441`); a bogus
  list fails the handshake (measured).
* **No credential-echoing debug channel.** `CURLOPT_VERBOSE`/`USERPWD`/`HTTPAUTH` are declared and
  never set (`src/http/libcurl.odin:89`, `:112`); Basic/Bearer are built in `src/http/auth.odin:20-43`,
  Digest in `src/http/digest.odin`. No log file is written.
* **Redirect handling matches the reference.** `should_strip_authorization`
  (`curl_transport.odin:1220-1247`) reproduces `requests/sessions.py:128-158` (the http→https
  standard-port exception runs before port normalisation); the hop loop drops `Authorization`
  (`:992-996`) and re-derives `Cookie` per hop (`:997-1004`, `:1092-1118`), whose policy enforces
  secure/expiry/domain/path (`src/session/jar.odin:229-294`). Tests: `tests/http_test.odin:1497`,
  `tests/http_engine_test.odin:2444`, `tests/session_store_test.odin:436`. Chains are bounded
  (`--max-redirects` default 30, `src/cli/parse.odin:673`); non-http(s) targets are refused before
  connecting (`curl_transport.odin:1702-1704`).
* **Header injection refused twice**: prepare-time (`src/http/header_validity.odin:77-100`) and
  wire-time (`:189-281`). The Digest answer built from server-controlled `realm`/`nonce`/`opaque`
  passes the same wire check (`curl_transport.odin:1051-1075`), so a CRLF challenge errors rather than
  splitting a header; `urlsplit`'s TAB/CR/LF deletion is implemented (`src/http/url.odin:1296-1298`).
* **Sessions**: `0600` files in `0700` directories, re-`chmod`ed on save
  (`src/session/store.odin:49-50`, `:800-827`). JSON escaping is CPython-compatible (`:959-1012`), so
  server-controlled cookie names/values cannot forge `raw_auth` or other keys.
* **Downloads take no name from the server**: only `--output` (`src/session/context.odin:1813-1841`);
  `Content-Disposition` appears only on multipart uploads (`src/http/body.odin:397-409`) → no
  traversal or overwrite via a header. `--continue` truncates unless the reply is 206
  (`context.odin:1899-1909`).
* **netrc** reads only `$NETRC`/`~/.netrc`/`~/_netrc` (`src/http/netrc.odin:69-95`), per-host with
  `default` fallback; **IDN** hosts are IDNA2008/punycode-normalised (`src/http/host.odin:684-732`)
  before libcurl sees them.
* **Memory/FFI**: no `#no_bounds_check`, no `intrinsics`, no `assert(`/`panic(` in `src/`; the
  `transmute`s are `string → []u8` reinterprets (e.g. `src/http/auth.odin:76`); the variadic
  `curl_easy_setopt` is wrapped in typed helpers (`src/http/libcurl.odin:174-200`) with run-time
  option-number validation; the build keeps vet/bounds/asserts (`Makefile:17`, `:43-44`). Digest
  answers only MD5/MD5-SESS (`digest.odin:250-252`) and never carries an answer across a redirect
  (`curl_transport.odin:1546-1550`); its cnonce uses Odin's ChaCha8 `getrandom` generator
  (`digest.odin:384-392`). Proxy resolution mirrors `requests` (`src/http/proxy.odin:92-117`) — except
  F-04.

## Findings

| ID | Severity | Location | Summary |
| --- | --- | --- | --- |
| F-01 | **Medium** | `src/cli/parse.odin:346`, `:640`; `src/cli/options.odin:359-371` | `--ssl` accepted and ignored; no `CURLOPT_SSLVERSION`, so no TLS-version floor. |
| F-02 | **Medium** | `src/output/render.odin:1580`; `src/session/context.odin:1974` | Server bytes reach the terminal unfiltered (OSC/CSI); inherited from the reference. |
| F-03 | **Medium** | `src/session/context.odin:215`, `:1968`; `src/http/backend.odin:25`; `src/http/curl_transport.odin:538-551` | Reply buffered whole with no cap; `--download` does not stream; short writes ignored. |
| F-04 | **Low** | `src/http/proxy.odin:109-113`, `:189-194` | Uppercase `HTTP_PROXY` honoured without the reference's CGI guard (httpoxy). |
| F-05 | **Low** | `README.md:154`; `src/cli/help_text_generated.odin:368` | `--help` advertises `REQUESTS_CA_BUNDLE`, never read. |
| F-06 | **Low** | `src/session/store.odin:800-827`; `src/http/auth.odin:45-47` | `raw_auth` plaintext, tightened only on save; secrets argv-only; no prompt. |

### F-01 — `--ssl` is accepted and has no effect

`--ssl` is in the option table (`src/cli/parse.odin:346`) with a validated choice list
(`src/cli/usage.odin:264`, `:299`) and a namespace field (`parse.odin:640`), but the transport-facing
`Options` (`src/cli/options.odin:359-371`) has no `ssl_version` and nothing under `src/http/` reads
one. *Attacker and precondition:* none needed; the flag is user-invoked against downgrade attempts.
*Impact:* the TLS floor is whatever the local libcurl/OpenSSL defaults to. *Exploitation sketch:* a
network attacker able to force a version downgrade gets no resistance from the flag the user set.
*Not a measurement artefact:* against a TLS1.2+-only listener `--ssl=tls1` returned `tls-ok` (exit 0)
while the applied control `--ciphers=NOT-A-REAL-CIPHER` failed the handshake (exit 1).
*Remediation:* map the choices onto `CURLOPT_SSLVERSION` as minimum versions, or reject the flag;
guard the new constant as `CURLOPT_SSL_CIPHER_LIST` is guarded.

### F-02 — Terminal escape-sequence injection

Nothing filters control bytes between socket and terminal: `write_raw_bytes`
(`src/output/render.odin:1580`) writes the body verbatim (`src/session/context.odin:1974`) and the
rendered head prints header values as received. *Evidence:* a loopback listener answered
`X-Injected: \x1b[2J\x1b]0;PWNED\x07cleared` with a body containing `\x1b]52;c;ZGF0YQ==\x07`, and the
built binary printed both byte-for-byte. *Attacker and precondition:* whoever controls the response —
a hostile origin, an injected `Location` hop, a MitM on a plaintext first hop; the default print path
suffices. *Impact:* screen clearing, cursor movement and forged output, and OSC 52 clipboard
read/write where the terminal allows it; with `-v`/`--all` an injected *header* line joins the same
stream and can impersonate the tool. *Remediation:* sanitise C0/ESC bytes by default on a tty (visible
rendering) with a `--raw`-style opt-out; at minimum drop OSC/CSI in headers. Reference behaviour, but
it should be a documented decision, not an inherited default.

### F-03 — Unbounded reply buffering; `--download` does not stream

`write_callback` buffers into `transfer.body` when `sink == nil`
(`src/http/curl_transport.odin:538-551`) with no cap, and the session only calls `http.send`
(`src/session/context.odin:215`), which passes no sink (`src/http/backend.odin:25`). The streaming
path exists but is reachable only from tests (`tests/http_engine_test.odin:1339`);
`download_response` then writes all of `response.body` at once (`context.odin:1968`), ignoring a short
write, and two header comments claim the opposite (`curl_transport.odin:7`, `:10-11`). *Attacker and
precondition:* any server returning a large or endless body (`--max-headers` defaults to no limit,
`curl_transport.odin:328-330`). *Impact:* memory exhaustion/OOM-kill of the client and silent
truncation of a download. *Remediation:* thread the open file through `send_to` on the download path,
cap the buffer, check `written == len(body)`, fix the comments, cover the CLI path in a test.

### F-04 — `HTTP_PROXY` honoured without the CGI guard

`proxy_for` reads lowercase then uppercase for both schemes (`src/http/proxy.odin:109-113`,
`:189-194`), where the reference's `urllib` drops the non-lowercase `http_proxy` when `REQUEST_METHOD`
is set (`/usr/lib/python3.14/urllib/request.py:1893-1898`). *Attacker and precondition:* a CGI/web-server
caller that exports `HTTP_PROXY` from the client's `Proxy:` header, then runs this tool. *Impact:* all
plaintext traffic — URLs, query strings, cookies, host Authorization headers — goes to an
attacker-chosen proxy. *Remediation:* implement the `REQUEST_METHOD` guard.

### F-05 — Advertised CA-bundle variable is not honoured

`--help` still says to "set the `REQUESTS_CA_BUNDLE` environment variable instead"
(`src/cli/help_text_generated.odin:368`); the divergence is documented (`README.md:154`) and only
`--verify <path>` is read. *Impact (fail-open relative to intent):* a user pinning a strict or private
bundle silently gets the system store. *Remediation:* read `REQUESTS_CA_BUNDLE`/`CURL_CA_BUNDLE` as
the reference does, or delete the sentence.

### F-06 — Secrets in argv, plaintext session credentials, no prompt

`--auth user:pass` and `--cert-key-pass` are argv-only (`/proc/<pid>/cmdline`, shell history); with
`--auth` carrying no colon the port sends an empty password rather than prompting
(`src/http/auth.odin:45-47`); `raw_auth` is plaintext on disk and `chmod 0600` runs only on save
(`src/session/store.odin:800-827`), so a pre-existing `0644` file read by a `--session-read-only` run
is never fixed or warned about. *Impact:* local credential exposure and a silent empty-password
attempt. *Remediation:* prompt or read from stdin/env when no password is given; `chmod` on load too.

## Recommendations (by severity)

1. **F-02** — sanitise response bytes for the terminal by default; make this a deliberate divergence
   from HTTPie rather than preserving the hazard.
2. **F-03** — stream `--download` to its file via `send_to`, cap buffered bodies, honour short writes,
   fix `curl_transport.odin:7` and `:10-11`.
3. **F-01** — apply `--ssl` through `CURLOPT_SSLVERSION` (or refuse it) and add it to the
   option-constant guard.
4. **F-04** — add the `REQUEST_METHOD` guard for `HTTP_PROXY`.
5. **F-05** — honour or stop advertising `REQUESTS_CA_BUNDLE`.
6. **F-06** — `chmod` sessions on load; add a password source that is not argv.
7. **Hardening** — run the suite with `-sanitize:address` where supported; record hashes for the
   in-tree `*_generated.odin` tables (their `build/gen_*.py` generators are absent); pin the system
   libcurl version.

**Not examined:** `src/format/json.odin` + `xml.odin` (2,850 lines) were not audited line-by-line for
memory-safety defects even though they consume server bytes (the absence of `#no_bounds_check` and
`assert` in `src/` bounds the failure mode to a controlled abort, but this is the largest unaudited
surface). libcurl/OpenSSL internals and the generated tables were taken as trusted, not verified.
