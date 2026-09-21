# Security findings inventory — `docs/RATING.md` (oj / htthor)

Task: `t_e458fe1e` — "Analyze docs/RATING.md and enumerate all security concerns".
Deliverable produced by the security-reviewer profile. The report below is a **factual
inventory**, not a remediation plan (that is the downstream task's job).

---

## 1. What was reviewed, by whom, and how

`docs/RATING.md` (408 lines, 22,876 bytes, commit `0f3cf5d`) is an **evidence-based quality
rating written by an "independent judge"** (its own words: *"This report assesses the Odin port
of `httpie`, `oj` … Everything below is graded from reproducible evidence"*, and it explicitly
modifies neither `src/` nor `tests/`). It uses:

* a **0–10 scale, one decimal place**, "where 0 is non-functional or unsafe and 10 is exemplary";
* **seven dimensions with equal 1/7 weights** — dimension 5 is *"Security posture (TLS, auth,
  C interop) — 7.5"*;
* its own severity language for findings: **`MAJOR` / `MINOR`** (no CVSS-style
  critical/high/medium/low). Where the judge did not assign a severity, this report supplies one
  and says so.

**Method used here.** Read the judge's claims; opened every cited `path:line`; re-ran the
judge's own counting commands on this tree; **executed the real `should_strip_authorization`**
with a temporary Odin test file (added, run, deleted — see §7); built the real binary
(`make build`, exit 0) and drove it against loopback HTTP/TLS probe servers, comparing the
**bytes each hop sent** with the reference stack (installed `requests` 2.33.0 and the
`httpie` 3.2.4 sdist).

**Environment of this run** (differs from the judge's in three ways, which matters for a few
environment-specific claims):

| | this worktree | `docs/RATING.md` |
| --- | --- | --- |
| Odin | `dev-2026-09-nightly:a2fb372` | `dev-2026-09:a2fb372b7` |
| libcurl | **8.5.0** (OpenSSL 3.0.13) | **8.22.0** (OpenSSL 3.6.4) |
| `requests` | **2.33.0** | **2.34.2** |
| tree | `/home/matteo/htthor/.worktrees/t_e458fe1e` | `/home/matteo/Projects/htthor` |

Gates re-run here: `make check` → exit 0 (zero warnings, both packages); `make test-unit` →
exit 0, `colorize goldens: 421 cases, 0 mismatches`, `Finished 167 tests … All tests were
successful.` The judge's reproduction script `/tmp/opencode/redirect_auth_check.py` **does not
exist on this machine** (`/tmp/opencode` is absent), so its exact script could not be re-run;
its seven cases were re-derived from the judge's own table and from the code, and re-checked
against `requests`.

---

## 2. Verdict

**Issues found — no critical finding, one high finding the judge missed.**

* Every security claim in `docs/RATING.md` reproduces (**6 CONFIRMED**, **0 NOT REPRODUCIBLE**;
  the judge's numbers, where they are numbers, are exact).
* The judge's severity framing is honest but *conservative in one place*: RATING.md's `MAJOR`
  F1 is rated **medium** here, because its fail-open direction (credentials kept across an
  `http:8080 → https:8080` scheme change) is real but low-impact, while its fail-closed
  direction costs authenticated redirects.
* **The highest real risk in this codebase is not in `docs/RATING.md` at all**:
  `Cookie`/credential headers are never stripped on redirect (`SEC-ADD-01`, **high**), so a
  session cookie — *including one marked `Secure`* — is forwarded to whatever host a server
  names in `Location`, where the reference (`requests`) drops it. RATING.md's F1 covers only
  `Authorization`.
* A second new finding: `--ciphers` is advertised in `oj --help`, accepted, parsed and
  **silently ignored** (`SEC-ADD-02`, **medium**); the reference httpie 3.2.4 applies it.

Status legend: **CONFIRMED** = reproduced here on this tree; **PARTIAL** = reproduced with a
caveat (environment or line numbers); **NOT REPRODUCIBLE** = could not be reproduced here.

---

## 3. Security statements in `docs/RATING.md` (every one appears exactly once)

*The status column records this review's own findings, taken at the commit named
in §1. The five remediations planned in §9 (`SF-001`…`SF-005`) landed afterwards
and are independently verified in §V — so an entry marked `CONFIRMED` below means
"reproduced at review time", not "present in the current tree".*

| ID | concern | source quote (verbatim from `docs/RATING.md`) | severity | affected files | status | evidence notes |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-01 | Redirect credential handling (`should_strip_authorization`) diverges from the reference; restated in the overall rating and in dimension 5 | "ships a security-adjacent correctness bug in redirect credential handling" (Overall); "a real, localized behavioral divergence in `should_strip_authorization` (`src/http/curl_transport.odin:1177-1195`)" (D1); "The logic normalizes absent ports to 80/443 *before* comparing them (`:1186-1187`), which makes the documented http→https exception (`:1175-1176`, `:1194`) unreachable for default ports and also keeps credentials across a scheme change on a non-standard same port" (F1); "it strips auth on legitimate upgrades and forwards it across a scheme change on a non-standard port" (D5) | judge `MAJOR`; this review: **medium** (fail-open direction low-impact, fail-closed direction breaks authenticated redirects) | `src/http/curl_transport.odin:1177-1195`, called at `:1698`; skip at `:987-989` | **CONFIRMED** | The real proc was executed with a temporary `@(test)` in `src/http` (`odin test src/http …`) and returned `strip=true` for `http://h/a → https://h/b` and `strip=false` for `http://h:8080/a → https://h:8080/b` — identical to the judge's `odin` column. Independent harness vs `requests` 2.33.0 `should_strip_auth`: `7 cases, 3 divergence(s)` (exit 1). On the wire: `oj --follow --verify=no --auth user:pass` sent `Authorization: Basic dXNlcjpwYXNz` on hop 2 to `https://127.0.0.1:19003/secure` (probe log `[TLS]` hop + header), while `requests` refused/stripped it. `grep -rn 'should_strip\|strip_auth' tests` → no matches (exit 1), so no test covers it. |
| SEC-02 | TLS verification on by default and mapped to libcurl, with `--verify=<path>` bound to the CA bundle | "TLS verification defaults **on**: `Request.verify = true` (`src/http/request.odin:58,181`), the CLI default is `"yes"` (`src/cli/parse.odin:678,1907`), and the engine maps that to `CURLOPT_SSL_VERIFYPEER = req.verify?1:0` (`src/http/curl_transport.odin:1357`) and `CURLOPT_SSL_VERIFYHOST = req.verify?2:0` (`:1362`), with `--verify=<path>` → `CURLOPT_CAINFO` (`:1374`)" (D5); "Secure defaults. TLS peer/host verification is on by default …" (Good) | none — control present (judge scores it as a positive) | `src/http/request.odin:58,181`; `src/cli/parse.odin:678,1907`; `src/http/curl_transport.odin:1357,1362,1374` | **CONFIRMED** | All four cited lines read and match verbatim (`req.verify = true` twice; `set_owned(&ns.verify, "yes", allocator)`; the two `setopt_long` calls and `setopt_string(handle, CURLOPT_CAINFO, ca_c)`). Empirically: `oj GET https://127.0.0.1:19701/secure` (self-signed) → `oj: error: TLS handshake failed …`, exit 1; the same request with `--verify=no` → `ok`, exit 0. |
| SEC-03 | Digest auth is hand-rolled MD5, checked against the RFC 1321 vectors | "Digest auth is hand-rolled MD5 validated against the RFC 1321 vectors (`tests/digest_test.odin:22-78`, e.g. `"" → d41d8cd98f00b204e9800998ecf8427e`)" (D5) | none — control present (protocol-mandated MD5; see SEC-ADD-04 for the algorithm-range caveat) | `tests/digest_test.odin:21-40`; `src/http/md5.odin`; `src/http/digest.odin:244-292` | **CONFIRMED** | The test proc `test_md5_matches_the_rfc1321_vectors` sits at `tests/digest_test.odin:21` and carries all seven RFC 1321 Appendix A.5 vectors, starting `{"", "d41d8cd98f00b204e9800998ecf8427e"}`; it passes in the 167-test run. `md5_hex_join` is used to build HA1/HA2/response at `src/http/digest.odin:266-291`. |
| SEC-04 | `CURLOPT_VERBOSE` is declared but never set, so no libcurl debug channel can echo credentials | "`CURLOPT_VERBOSE` is declared but never set in `src`, so libcurl cannot dump credentials" (D5); "`CURLOPT_VERBOSE` is never set, so no debug channel can leak credentials" (Good) | none — control present | `src/http/libcurl.odin:89` (declaration only); `tests/libcurl_test.odin:40` (constant check only) | **CONFIRMED** | `grep -rn 'CURLOPT_VERBOSE' src tests` returns exactly two hits: the constant declaration and the constant-name test. There is no `setopt_long(handle, CURLOPT_VERBOSE, …)` anywhere in `src/`, so libcurl's `*_write` debug stream (which prints request headers, including `Authorization`) is never enabled. |
| SEC-05 | Two used libcurl option constants are not re-checked by the test that is supposed to catch typos | "`tests/libcurl_test.odin` checks the constants via that API, but omits `CURLOPT_READDATA` (`src/http/libcurl.odin:113`) and `CURLOPT_READFUNCTION` (`:125`), both used by the engine (`src/http/curl_transport.odin:819,822`)" (F6); "docked … for the two unchecked libcurl option constants in F6" (D5) | judge `MINOR`; this review: **hardening** (missing guard, not a live defect) | `src/http/libcurl.odin:113,125`; `src/http/curl_transport.odin:819,822`; `tests/libcurl_test.odin:34-66` | **CONFIRMED** | Line numbers exact: `CURLOPT_READDATA :: CURLoption(10009)` at `:113`, `CURLOPT_READFUNCTION :: CURLoption(20012)` at `:125`; both are used (`setopt_read_callback(handle, CURLOPT_READFUNCTION, read_callback)` at `:819`, `setopt_ptr(handle, CURLOPT_READDATA, transfer)` at `:822`). `grep -rn 'READDATA\|READFUNCTION' tests/` → no matches (exit 1). The two ABI numbers are in fact correct, so today this is a coverage gap, not a bug. |
| SEC-06 | The C surface is a hand-declared, thin binding: one `foreign import`, no C headers, and option numbers validated at run time | "Only `src/http/libcurl.odin` contains a `foreign import` (`:22`); no C headers are a build dependency and no `cstring` escapes the package, with libcurl constants validated via `curl_easy_option_by_name` in `tests/libcurl_test.odin`" (Good) | none — control present | `src/http/libcurl.odin:22`; `tests/libcurl_test.odin:13,34-66` | **CONFIRMED** | `grep -rn 'foreign import' src/` → two hits, both in `src/http/libcurl.odin` (the doc comment and the single declaration at `:22`). No C header is included anywhere (`build` links `-lcurl` via `-extra-linker-flags`, `Makefile:21-22`). `cstring` appears outside `src/http` only as the substring inside the word "docstring" in a comment (`src/output/styles_generated.odin:6`) — zero real uses. |

---

## 4. Additional security findings (not mentioned by the judge)

| ID | concern | source | severity | affected files | status | evidence notes |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-ADD-01 | **`Cookie` (and any other non-Authorization credential header) is never stripped on a redirect.** The hop loop removes only `Authorization`, and the per-hop `Cookie` recomputation the reference performs (`resolve_redirects`: `headers.pop("Cookie", None)` then `prepare_cookies` against the jar) has no counterpart — the header list built for the first URL is replayed verbatim on every hop | additional — my own finding (no counterpart in `docs/RATING.md`; F1 knows only about `Authorization`) | **high** | `src/http/curl_transport.odin:977-993` (skip list has no `Cookie`); `src/session/jar.odin:119-176` (jar header applied once, only if absent); `src/session/context.odin:1002` (single `session_apply_cookies` call); reference: `requests/sessions.py:235-243` | **CONFIRMED** | On the wire, cross-host (`127.0.0.1` → `127.0.0.2`), `oj --follow --auth alice:s3cr3t GET … 'Cookie:sess=TOPSECRET'` sent hop 2 `host='127.0.0.2:19901' auth=None cookie='sess=TOPSECRET'` while `requests` sent `auth=None cookie=None` — same request, same servers. Session-jar variant: an `httpie` session file with a cookie scoped `domain: 127.0.0.1` produced hop 2 `cookie='sess=JARSECRET'` at `host='127.0.0.2:19601'`; `requests` with the same cookie in its jar sent no cookie. `Secure` variant: a `secure: true` session cookie was sent over TLS on hop 1 **and in cleartext** on the hop-2 downgrade to `http://127.0.0.2:19802/landing` (`oj exit 0`, probe log `[PLAIN] … cookie='sess=SECUREJARSECRET'`); `requests` sent `cookie=None` there. |
| SEC-ADD-02 | **`--ciphers` is documented, accepted, parsed, and silently ignored.** No `CURLOPT_SSL_CIPHER_LIST` exists anywhere in `src/`, so the cipher constraint a user believes they set is not applied | additional — my own finding | **medium** (documented security control with no effect, fail-silent) | `src/cli/parse.odin:347` (option table), `:641,707,1497,1912` (namespace field, never forwarded); `src/cli/help_text_generated.odin:378,801`; no use in `src/http/*` | **CONFIRMED** | `oj --ciphers=NOT-A-REAL-CIPHER … → ok, exit 0`; libcurl would return `CURLE_SSL_CIPHER` (59) for an invalid cipher list if the option were set. `oj --ciphers=ECDHE-RSA-AES256-SHA384 … → ok, exit 0` even though the probe server does not offer that suite, i.e. the handshake was not constrained. `grep -rn 'CIPHER' src/http/curl_transport.odin src/http/libcurl.odin` finds only the error-code constant `CURLE_SSL_CIPHER :: CURLcode(59)`; grep for the parsed field outside `src/cli` finds nothing. Reference: httpie 3.2.4 does apply it (`client.py:70 ciphers=args.ciphers` → `httpie/ssl_.py` `HTTPieHTTPSAdapter(... ciphers=ciphers)`). |
| SEC-ADD-03 | Session files are written **0644** and contain **plaintext credentials** (`"raw_auth": "alice:s3cr3t"`) | additional (adjacent: RATING.md does not mention session storage) | **hardening** — not exploitable as written, because every parent directory is 0700 | `src/session/store.odin:39-44` (`SESSION_FILE_MODE` = user+group+other read), `:794-812` (`session_save`, `SESSION_DIR_MODE` 0700 for dirs) | **CONFIRMED** | Created `xdg_run1/httpie/sessions/127.0.0.1_19311/probe.json` with mode `644`, contents `"auth": {"raw_auth": "alice:s3cr3t", …}`; the three directories above it are all `700`. The reference behaves identically: httpie 3.2.4 `config.py:110-128` uses `Path.write_text` (0666 & umask → 0644) with `mkdir(mode=0o700)` — so this is inherited, and the 0700 directory is the actual containment. Worth tightening (`0o600`) as defence in depth; not a divergence. |
| SEC-ADD-04 | Digest auth supports only `MD5`/`MD5-SESS`; a `SHA-256` challenge aborts the request | additional (adjacent to SEC-03) | **low** (fails closed; availability/compat, not exposure) | `src/http/digest.odin:244-253` (`if !equal_fold(algorithm, "MD5") && !equal_fold(algorithm, "MD5-SESS") { return "", false }`) | **CONFIRMED** (code read) | RATING.md credits the MD5 vectors but does not note the algorithm range. MD5 is what RFC 2617's `MD5`/`MD5-sess` mandate, so the *use* of MD5 is protocol-correct; the gap is that a server offering only `SHA-256` (RFC 7616) cannot be authenticated, where `requests` supports it. No path was found by which this leaks credentials. |
| SEC-ADD-05 | The port never pins a minimum TLS version (`CURLOPT_SSLVERSION` is never set); urllib3/requests pins `TLSv1_2` | additional | **hardening** (platform default is modern; no exploit path found here) | no `CURLOPT_SSLVERSION` anywhere in `src/`; `src/cli/parse.odin:640,706` holds an unused `ssl_version` field | **CONFIRMED** (code read + wire check) | `grep -rn 'SSLVERSION' src/` → no matches; the wire probe recorded the negotiated protocol as `TLS/TLSv1.3`, so on this machine (OpenSSL 3.0.13 defaults) the effective floor is fine. `--ssl-version` is *not* accepted by this build (`oj: error: unrecognized arguments: --ssl-version=SSLv3`, exit 1), so nothing is silently ignored there — unlike `--ciphers`. |

---

## 5. Non-security statements from `docs/RATING.md` (recorded for completeness)

*As in §3, the status column is this review's at the commit named in §1; the later
fixes are in §V.*

RATING.md's other findings (F2–F5, F7–F9, dimension 6, the stale libcurl pin and the memory-ownership
positives) are **contract/documentation/memory-safety** concerns, not security vulnerabilities.
They are listed here so that no statement in the source document is unaccounted for.

| ID | RATING.md item | source quote (abridged, verbatim) | severity | affected files | status | evidence notes |
| --- | --- | --- | --- | --- | --- | --- |
| DOC-01 | F2 — documented source of truth `docs/PARITY.md` does not exist | "`docs/PARITY.md` is absent … yet it is named **223 times**" | judge `MAJOR` (documentation) | `docs/`, `docs/ARCHITECTURE.md:395-397` | **CONFIRMED** | Exact count reproduced: `grep -ro 'PARITY\.md' src tests docs/ARCHITECTURE.md README.md Makefile \| wc -l` → **223**; `docs/` contains only `ARCHITECTURE.md` and `RATING.md`. `ARCHITECTURE.md:395-396`: "Behaviour that the tests cannot decide comes from `docs/PARITY.md`, not from preference". |
| DOC-02 | F3 — documented CI workflow is absent | "`ARCHITECTURE.md:304-311` describes `.github/workflows/ci.yml` … There is no `.github/` directory" | judge `MAJOR` (documentation) | `docs/ARCHITECTURE.md:306`; missing `.github/` | **CONFIRMED** | `ls -d .github` → "No such file or directory"; `ARCHITECTURE.md:306` does describe `.github/workflows/ci.yml` running on Ubuntu. Reproducibility rests on local `make`, as the judge says. |
| DOC-03 | F4 — 21 `context.temp_allocator` uses violate the hard allocator rule | "There are 21 non-comment code uses in 7 files" | judge `MAJOR` (contract) | `src/cli/parse.odin`, `src/session/jar.odin`, `src/http/detect.odin`, `src/http/charset.odin`, `src/output/render.odin`, `src/session/context.odin`, `src/session/store.odin`; rule at `docs/ARCHITECTURE.md:182-186` | **CONFIRMED** | Count reproduced exactly: 21 non-comment hits (`grep -rn 'context\.temp_allocator' src --include='*.odin'` minus comment lines). The rule text at `ARCHITECTURE.md:182-186` matches the quote ("No file under `src/` reads `context.allocator` or `context.temp_allocator`"). Memory-safety-adjacent; no leak or UAF was observed (suite green). |
| DOC-04 | F5 — `src/output` allocates, contradicting the "allocates nothing" rule; three sites bypass the tracking allocator | "10 explicit `make(` call sites … of which **three pass no allocator**" | judge `MAJOR` (contract; memory-safety-adjacent) | `src/output/colorize.odin:917,919,947` (the three); `docs/ARCHITECTURE.md:58-60` (rule) | **CONFIRMED** | `grep -rn -E '(^\|[^_a-zA-Z])make\(' src/output --include='*.odin' \| wc -l` → **10** (judge's number exact); `new(` → 0. The three unallocated sites are exactly the cited lines. No leak was observed in exercised paths. |
| DOC-05 | F7 — provenance artifacts cited by source and tests are missing | "`tests/golden_test.odin` and its `capture_argv` helper; neither exists … `docs/REVIEW.md` (absent) … `tests/parity/server.py` … `build/probe_*.py`/`.c`" | judge `MINOR` (documentation) | `tests/`, `docs/`, `build/` | **CONFIRMED** | `tests/golden_test.odin` and `docs/REVIEW.md` do not exist (`ls -d` → no such file); `tests/parity` absent while referenced 11 times (`tests/parity/server.py` 5 times); `build/probe_*` referenced 62 times across `src tests docs/ARCHITECTURE.md`; `build/` holds only `oj`. Golden replay does live in `tests/colorize_test.odin` over `tests/golden/`, as the judge notes. |
| DOC-06 | F8 — README purity claim contradicts a present capture sandbox | "`README.md:5` says the tree is 'pure Odin — no Python, no reference-parity harness', but `.capture-sandbox/` is present with 15 files" | judge `MINOR` (documentation) | `README.md:5`; `.gitignore:13-15`; missing `.capture-sandbox/` | **PARTIAL** | `README.md:5` does carry that sentence and `.gitignore` does ignore `/.capture-sandbox/` (line 15) with a comment calling it "left behind by the removed parity harness". But the directory itself is **absent in a fresh worktree** (`ls -d .capture-sandbox` → no such file): git-ignored leftovers are not part of a checkout, so the judge measured a working copy, not the tree. The 15-file count is not reproducible here. |
| DOC-07 | F9 — "two libcurl callbacks" vs three in the code | "`ARCHITECTURE.md:261` says '`curl_transport.odin`'s two libcurl callbacks', but there are three `proc \"c\"` callbacks" | judge `MINOR` (documentation) | `docs/ARCHITECTURE.md:260`; `src/http/curl_transport.odin:529,557,576` | **CONFIRMED** (one-line citation offset) | The sentence is at `ARCHITECTURE.md:260`, not `:261`, and the substance is right: `write_callback` (`:529`), `read_callback` (`:557`), `header_callback` (`:576`) — three `proc "c"` callbacks (a fourth hit at `:524` is a comment). |
| DOC-08 | stale libcurl pin (`ARCHITECTURE.md:9` says 8.5.0 while the machine runs 8.22.0) | "the pinned libcurl is stale: `ARCHITECTURE.md:9` says 'libcurl 8.5.0' while the machine runs 8.22.0" | judge `MINOR` (build/packaging) | `docs/ARCHITECTURE.md:9`; `tests/http_engine_test.odin:362-368` | **PARTIAL** (environment-dependent) | On *this* machine `curl --version` reports `libcurl/8.5.0`, i.e. the pin at `ARCHITECTURE.md:9` is accurate here and the judge's mismatch is specific to its host. The workaround the judge cites does exist and does name 8.22.0 behaviour: `tests/http_engine_test.odin:362-368` removes the `Connection` line because "libcurl writes a caller-supplied `Connection` header last … (measured against libcurl 8.22.0)". |
| MEM-01 | Memory-ownership dimension (9.0): ownership executed by the tests | "108 `mem.Tracking_Allocator` occurrences and 109 leak assertions (80 `expect_no_leaks` + 29 `engine_no_leaks`) run under every suite invocation and all pass" | judge score 9.0 (memory safety, not security) | `tests/*.odin`, `tests/helpers.odin:54` | **CONFIRMED** | Counts reproduced exactly on this tree: `mem.Tracking_Allocator` → 108, `expect_no_leaks(` → 80, `engine_no_leaks(` → 29 (109 leak assertions); `make test-unit` exit 0, 167 tests. |
| MEM-02 | Double-destroy-safe resource API | "`*_destroy` procs accept zero values and zero their argument (e.g. `src/http/request.odin:1266-1326`, `src/cli/options.odin:450-485`)" | judge: listed under "genuinely good" (memory safety) | `src/http/request.odin:1266-1326`; `src/cli/options.odin:450-485` | **CONFIRMED** | Both procs end by zeroing their argument (`req^ = {}`; `opts^ = {}`) after freeing through their stored allocator, and `request.odin:1320-1325` documents the borrowed `proxy/cert/...` exception. |

---

## 6. Detail on the two findings that matter most

### SEC-ADD-01 — cookies follow redirects to any host (high)

* **Attacker and precondition.** The attacker is whoever controls a response the user reaches
  with `oj --follow` (the redirecting origin itself, or anyone able to inject a `Location`
  header — e.g. a MitM on the plaintext first hop). The user must have opted into redirect
  following and be carrying a cookie, which happens whenever a session is in play
  (`--session`), a `Cookie:` item is passed (httpie documents exactly that form,
  `help_text_generated.odin:58`), or a jar cookie was collected earlier.
* **Steps.** (1) Start a server that answers `302 Location: http://<attacker-or-other-host>/`.
  (2) Run `oj --follow --session=probe GET http://origin/` where the session holds a cookie for
  `origin`. (3) Read the second hop's request on the other host.
* **Impact.** The cookie — a session token, an `Authorization`-equivalent for many APIs, or a
  `Secure`-flagged cookie — is delivered to an origin the reference would refuse to send it to.
  In the `https → http` variant the `Secure` cookie crosses the wire **in cleartext**, so a
  network observer can lift it. `Authorization` in the same request *is* correctly stripped,
  which makes the leak easy to miss in review.
* **Root cause.** `apply_hop`'s header loop (`src/http/curl_transport.odin:977-993`) skips only
  `Authorization`; `session_apply_cookies` (`src/session/jar.odin:119-176`, called once at
  `src/session/context.odin:1002`) refuses to touch a `Cookie` header that already exists and is
  never re-run for a later hop, and the jar's `cookie_applies` domain/`Secure` policy therefore
  never sees the redirect target. The reference does the opposite on every hop
  (`requests/sessions.py:235-243`: `headers.pop("Cookie", None)` followed by
  `prepare_cookies` against the merged jar).
* **Reproduction.** §7, tests `H` and `D`/`G`.
* **Fix direction.** In the hop loop, treat `Cookie` like `Authorization`: drop the header
  whenever a hop changes origin/port/scheme and re-derive it from the session jar for the new
  URL (which also restores the `Secure`-flag rule). Verification test: extend
  `tests/http_engine_test.odin` with a two-listener case asserting the second hop carries no
  cookie (and no `Authorization`) for a different host/port, plus a `secure=true` downgrade case.

### SEC-01 — `should_strip_authorization` divergence (medium, judge `MAJOR`)

* **Attacker and precondition.** No attacker is required for the fail-closed direction (the
  user simply loses the `Authorization` header on an ordinary `http → https` upgrade, so an
  authenticated redirect silently 401s). The fail-open direction,
  `http://h:P/a → https://h:P/b` with a non-default `P`, needs a redirect to a same-host,
  same-port scheme change; the reference strips credentials there and `oj` keeps them, so
  credentials are sent to an endpoint the reference treats as a different origin.
* **Reproduction.** §7, tests `C` (wire) and the executed-proc probe.
* **Fix direction.** Reproduce `requests`' `should_strip_auth` ordering: evaluate the
  `http`(port 80/None) → `https`(port 443/None) exception **before** normalising ports, then
  fall back to `changed_port or changed_scheme` on raw ports. Verification test: port the seven
  cases of the judge's table into `tests/` (they are the same seven exercised here), with the
  `requests` column as the golden.

---

## 7. Reproduction

All commands run from the repository root of this worktree, on the toolchain in §1.

### 7.1 The judge's own counts (re-run, exact matches)

```sh
grep -ro 'PARITY\.md' src tests docs/ARCHITECTURE.md README.md Makefile | wc -l   # 223
grep -rn 'context\.temp_allocator' src --include='*.odin' | grep -v ':[0-9]*:[[:space:]]*//' | wc -l  # 21
grep -rn -E '(^|[^_a-zA-Z])make\(' src/output --include='*.odin' | wc -l          # 10
grep -ro '@(test)' tests | wc -l                                                  # 167
grep -ro 'mem\.Tracking_Allocator' tests | wc -l                                  # 108
grep -rn 'READDATA\|READFUNCTION' tests/                                          # no matches (exit 1)
find src -name '*_generated.odin' | wc -l                                         # 8
make check; echo EXIT=$?            # EXIT=0, zero warnings
make test-unit | tail -3            # 421 goldens 0 mismatches; 167 tests all successful
```

### 7.2 Executing the real `should_strip_authorization` (SEC-01)

Temporary file `src/http/zz_probe_redirect_test.odin` (deleted again — the tree is clean apart
from this report), then:

```sh
odin test src/http -collection:src=src -vet -warnings-as-errors -extra-linker-flags:"-lcurl"
# PROBE http://h/a               https://h/b              strip=true
# PROBE http://h:80/a            https://h:443/b          strip=true
# PROBE http://h/a               http://h/b               strip=false
# PROBE http://h:8080/a          https://h:8080/b         strip=false
# PROBE http://h/a               https://h:8443/b         strip=true
# PROBE http://h/a               http://h:8080/b          strip=true
# PROBE http://h/a               https://other/b          strip=true
```

### 7.3 Wire tests (SEC-01, SEC-ADD-01)

Two ~90-line loopback probe servers were used: one plain-HTTP sink / redirector, one
dual-protocol listener that sniffs the first byte so a single port can serve `http://` and
`https://` (self-signed cert, needed for the same-non-default-port scheme change without root),
plus a `tls-redirect` mode for the `https → http` downgrade. Driver snippets:

```sh
# H) cross-host redirect carrying both --auth and a cookie
python3 probe_server.py 19901 sink      log.jsonl http://x/            127.0.0.2
python3 probe_server.py 19902 redirect  log.jsonl http://127.0.0.2:19901/landing
build/oj --follow --auth alice:s3cr3t GET http://127.0.0.1:19902/start 'Cookie:sess=TOPSECRET'

# oj       hop1 auth='Basic YWxpY2U6czNjcjN0' cookie='sess=TOPSECRET'
#          hop2 host='127.0.0.2:19901' auth=None cookie='sess=TOPSECRET'   <-- cookie leaked
# requests hop2 host='127.0.0.2:19901' auth=None cookie=None

# C) F1 case 4: http://127.0.0.1:P -> https://127.0.0.1:P (one port, TLS sniffing)
python3 probe_server.py 19003 dual  log_c.jsonl https://127.0.0.1:19003/secure
build/oj --follow --verify=no --auth user:pass GET http://127.0.0.1:19003/start
# [PLAIN] hop1 Authorization=Basic dXNlcjpwYXNz
# [TLS]   hop2 Authorization=Basic dXNlcjpwYXNz   <-- oj keeps across the scheme change

# G) Secure session cookie over an https -> http downgrade
python3 probe_server.py 19801 tls-redirect log_g.jsonl http://127.0.0.2:19802/landing
XDG_CONFIG_HOME=<scratch> build/oj --follow --verify=no --session=probe GET https://127.0.0.1:19801/start
# [TLS]   hop1 cookie='sess=SECUREJARSECRET'
# [PLAIN] hop2 cookie='sess=SECUREJARSECRET'   <-- Secure cookie in cleartext on another host
```

### 7.4 The reference side

```sh
python3 -c "import requests; ..."   # via a file, not -c, in this environment
# requests 2.33.0 should_strip_auth: 7 cases, 3 divergences vs the executed Odin proc
python3 -m pip download httpie==3.2.4 --no-deps --no-binary :all:   # sdist for --ciphers / config.py
```

### 7.5 Tree state

Only `docs/security-findings.md` (this report) was added; the temporary probe test file was
deleted, `src/` and `tests/` are unmodified, and `make check` / `make test-unit` still pass.

---

## 8. Coverage, assumptions and open questions

* **Examined:** `docs/RATING.md` in full; every `path:line` it cites for security claims;
  `src/http/curl_transport.odin` (hop loop, header list, redirect chain, TLS options, auth),
  `src/http/libcurl.odin`, `src/http/request.odin`, `src/http/digest.odin`,
  `src/http/netrc.odin`, `src/session/jar.odin`, `src/session/store.odin`,
  `src/cli/parse.odin`, `src/cli/usage.odin`, `tests/libcurl_test.odin`,
  `tests/digest_test.odin`, `tests/http_engine_test.odin`, `docs/ARCHITECTURE.md`, `Makefile`,
  `README.md`, `.gitignore`, `tests/fixtures/sessions/*.json`, and the httpie 3.2.4 /
  requests 2.33.0 sources for the comparison points.
* **Not examined (named, not hidden):** the 8 `*_generated.odin` files (31,882 lines) were not
  read line by line — only compiled and counted (same caveat the judge states); the
  `src/http/url.odin` + `idna_generated.odin` parsing machinery was not audited for
  parser-differential attacks beyond the origin comparisons used by redirects;
  `src/http/proxy.odin` (proxy credentials and per-hop proxy rebuilds) was not reviewed;
  netrc file-permission enforcement was not tested (the reference does not enforce it either);
  the golden colour corpus was not inspected for embedded sensitive data; no remote/real
  network testing was performed — all wire evidence is loopback.
* **Assumptions.** The judge's evidence bundle (`/tmp/opencode/oj-evidence.md`) and its Python
  scripts are not in this tree and not on this machine, so the judge's *exact* script could not
  be re-run; SEC-01 was re-derived from the code and re-measured against `requests`.
  `docs/RATING.md` uses `MAJOR`/`MINOR` rather than the severity vocabulary requested for this
  report, so the judge's labels are quoted and this review's own severities are stated
  separately for each row.
* **Open questions for the owner.** (1) Is `--follow` + session cookies a configuration the
  project intends to support for cross-origin redirects at all, or should cookies be dropped
  whenever the origin changes (the reference's behaviour)? (2) Should `--ciphers` be
  implemented (`CURLOPT_SSL_CIPHER_LIST`) or rejected explicitly, so the failure is loud?
  (3) Should the session file be tightened to `0600` even though the reference writes `0644`
  under a `0700` directory? Each is a decision, not a defect class.

---

## Remediation Plan

Task: `t_0c45de6d` — *"Produce prioritized remediation plan for confirmed findings"*.
Input: this report's §3 (judge findings) and §4 (additional findings).

Everything below was re-checked against the tree in `/home/matteo/htthor/.worktrees/t_0c45de6d`
before it was written: the reference behaviour each fix restores was **measured here**, not
copied from the inventory. Where a spec names a line, that line is the one this worktree's
`HEAD` (`0f3cf5d`) has.

### 9.1 What this plan adds to §7 (evidence re-taken for the plan)

| check | how it was taken | result |
| --- | --- | --- |
| `should_strip_authorization` divergence (**SEC-01**) | `requests` 2.33.0 `should_strip_auth` read at `…/venv/lib/python3.11/site-packages/requests/sessions.py:128-158` and compared case by case with `src/http/curl_transport.odin:1177-1195` | 3 of 9 pinned cases diverge, **in both directions** (table in SF-002) |
| the cookie leak (**SEC-ADD-01**) | `make build` (21 s, exit 0) then the built `build/oj` driven against loopback redirect/sink servers, cross-checked with `requests` in the same run | **leak reproduced independently**: `oj` hop 2 to `127.0.0.2:58867` carried `Cookie: sess=TOPSECRET`; `requests` carried none. Same-origin hop 2: `oj` kept the cookie, `Authorization` correctly kept |
| the reference rule the fix must match | 5-case probe of `requests` (session-jar cookie vs `Cookie:` header item; cross-host, same host/other port, path mismatch) | `requests` **pops `Cookie` on every followed hop** and re-derives it from the merged jar (`sessions.py:235-243`): cross-host → none; same host, other port → **sent**; path mismatch → none; header item → never re-sent on any hop |
| `CURLOPT_SSL_CIPHER_LIST` ABI number (**SEC-ADD-02**) | `curl_easy_option_by_name("SSL_CIPHER_LIST")` through `ctypes` against this host's libcurl 8.5.0 / OpenSSL 3.0.13 | id **10083** (string option) — `CURLOPT_SSL_CIPHER_LIST :: CURLoption(10083)` |
| can the suite prove a TLS-dependent fix? | `core/crypto` of the pinned toolchain (`~/.local/toolchain/odin-linux-amd64-nightly+2026-09-01`) has **no `tls` package**; the Odin suite is loopback-plain-HTTP only | **no**: SF-003's TLS half is a scripted probe run by QA, not an in-suite test (stated in SF-003, not hidden) |
| `os.chmod` for SF-004 | `core/os/file.odin:415,425` (`chmod :: change_mode`) | present |

Gates re-run before writing this plan: `make check` exit 0; `make test-unit` exit 0 (167
tests, `421 goldens 0 mismatches`). Nothing in the tree was modified by this planning task
except this document; the probe scripts live outside the repo
(`~/.hermes/profiles/security-reviewer/cache/scratch/probe_*.py`).

### 9.2 Findings with no remediation item

* **NOT REPRODUCIBLE: none.** §2/§7 record zero, so nothing is discarded on that ground.
* **PARTIAL — `DOC-06` (capture sandbox present) and `DOC-08` (libcurl pin stale).** Both are
  environment-specific and, more importantly, **non-security**: `.capture-sandbox/` is a
  git-ignored leftover and is absent from a fresh worktree by construction, and the libcurl
  "mismatch" is the judge's host (`curl --version` here reports 8.5.0, which is exactly what
  `ARCHITECTURE.md:9` pins). **Parked with no work item and no follow-up ticket**: there is
  nothing in this tree to change.
* **`SEC-02`, `SEC-03`, `SEC-04`, `SEC-06`** are *positive* controls (verified present). No
  change. `SEC-04` is a control that must stay: **nothing may ever set `CURLOPT_VERBOSE`**, and
  no fix below touches it.
* **`DOC-01`–`DOC-05`, `DOC-07`, `MEM-01`, `MEM-02`** are documentation / contract /
  memory-safety statements, not vulnerabilities. Out of scope (§9.6), not "parked pending
  reproduction".

### 9.3 The ranked work list

Ranking key: `severity × exploitability × effort` — a fix ranks up when it closes a credential
leak an attacker can steer, and down when it closes a divergence, a defence-in-depth gap, or
needs a subsystem that does not exist yet.

| rank | item | finding | severity | exploitability | effort | verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | **SF-001** | SEC-ADD-01 | high | user runs `--follow` with any cookie; attacker controls a `Location` header | M (4 source files, ~120 lines) | **MUST-FIX** |
| 2 | **SF-002** | SEC-01 | medium | needs a redirect across an origin; one direction sends credentials the reference refuses to send | S (one proc + tests) | **MUST-FIX** |
| 3 | SF-003 | SEC-ADD-02 | medium | none directly — the user's cipher constraint is silently not applied | S (~20 lines + a TLS probe) | SHOULD-FIX |
| 4 | SF-004 | SEC-ADD-03 | hardening | none as written (0700 parents contain it) | XS (1 constant + `chmod` + 1 test expectation) | SHOULD-FIX |
| 5 | SF-005 | SEC-05 | hardening | none — the two ABI numbers are correct today | XS (2 lines) | SHOULD-FIX |
| — | SF-D1 | SEC-ADD-04 | low | none (fails closed) | L (a new hash implementation) | DEFER |
| — | SF-D2 | SEC-ADD-05 | hardening | none (platform default negotiates TLS 1.3) | S | DEFER |
| — | SF-D3 | new (found while planning) | none — parity gap, not a leak | — | M | DEFER |

Implement the items **in the order given**: SF-001's refactor of `session_apply_cookies` is the
surface SF-003/SF-004 touch, and SF-002 is independent of both.

---

### SF-001 — `Cookie` must not follow a redirect; re-derive it per hop from the jar

**Finding / evidence.** SEC-ADD-01 (high). `apply_hop`'s header filter skips only
`Authorization` (`src/http/curl_transport.odin:987-991`); the `Cookie` header — built **once for
the first URL** from the jar (`src/session/context.odin:1002` →
`src/session/jar.odin:119-176`) or from a `Cookie:` item — is replayed on every hop.

*Attacker and precondition.* Whoever controls a response the user reaches with `--follow` (the
redirecting origin, or a MitM on a plaintext first hop) and the user carries a cookie
(`--session` jar, or a `Cookie:` item — the form `--help` documents).
*Steps (reproduced here).* A 302 from `127.0.0.1:P` whose `Location` names `127.0.0.2:Q`, then
read the second hop's request. `oj` sent `Cookie: sess=TOPSECRET` to `127.0.0.2`; `requests`
sent none. On an `https → http` downgrade the same path puts a `Secure` cookie on the wire in
cleartext (§7.3 case G).
*Impact.* A bearer-equivalent credential is disclosed to an origin the reference refuses to
send it to; the `Authorization` header in the same request *is* stripped, which hides the leak
in review.

**Reference rule (measured, §9.1).** On **every** followed hop `requests` does
`headers.pop("Cookie", None)` and then re-derives the header from the merged jar for the new
URL (`requests/sessions.py:235-243`); the value is a host / path / `Secure` policy result. A
`Cookie:` header item is therefore never re-sent on any hop; a jar cookie is re-sent when
(same host) and (path prefix matches) and (not `Secure`-on-plain-http).

**Fix — files and functions, in order.**

1. `src/http/types.odin`, in the transport-policy block (`:357-382`, next to `ca_bundle`):
   add the hook type and field. The zero value means "no jar in this run".

   ```odin
   // Cookie_Hook is the session's jar applied to one hop: requests pops `Cookie`
   // on every followed redirect and re-derives it for the new URL from the merged
   // jar (sessions.py:235-243), and only the jar knows the domain / path / Secure
   // policy that decides what the new URL gets. `value` is nil when the run has no
   // session; the transport then drops the header instead of rebuilding it.
   Cookie_Hook :: struct {
       context: rawptr,
       // value returns the `Cookie` header value for `url`, owned by `allocator`
       // (the caller deletes it); "" means "this URL gets no cookie".
       value:   proc(context: rawptr, url: string, allocator: mem.Allocator) -> string,
   }
   ```

   and on `Request` (near `ca_bundle`, `:382`): `cookie_hook: Cookie_Hook,` — **borrowed**
   (a `rawptr` plus a proc value, like the other borrowed policy fields at `:373-382`);
   `request_destroy` must not release it, and zeroing the struct is enough.

2. `src/http/curl_transport.odin`:
   * `Hop` (`:663-688`): add
     `// redirect_target is true for every hop the chain followed into: the request's own Cookie header was derived for the first URL only and must be re-derived for this one (requests' resolve_redirects, sessions.py:235-243).`
     `redirect_target: bool,`
   * where the next hop is installed (`:1696-1701`, beside
     `hop.keep_authorization = ...`): add `hop.redirect_target = true`.
   * in `apply_hop`'s header loop, immediately **after** the `Authorization` rule
     (`:987-991`, before the `if skip { continue }` at `:992`):

     ```odin
     // requests pops `Cookie` on every followed redirect and re-derives it from
     // the merged jar for the new URL (sessions.py:235-243). The header this
     // request carries was built for the *first* URL only, so it is never
     // replayed onto a hop the chain followed into; the re-derived value is
     // appended after the loop, where this hop's URL is known.
     if hop.redirect_target && strings.equal_fold(header.name, "Cookie") {
         skip = true
     }
     ```

   * immediately **after** the header loop closes (`:1078`, before the digest
     `Authorization` append at `:1082-1099`), append the re-derived line — that position is
     what `requests` produces (`pop` then `prepare_cookies` puts `Cookie` last, and the auth
     hook's `Authorization` is added after it):

     ```odin
     if hop.redirect_target && req.cookie_hook.value != nil {
         value := req.cookie_hook.value(req.cookie_hook.context, hop.url, req.allocator)
         defer if value != "" { delete(value, req.allocator) }
         if value != "" {
             line, line_err := strings.concatenate({"Cookie: ", value}, req.allocator)
             if line_err != .None {
                 return .Out_Of_Memory
             }
             entry, entry_ok := c_strings_add(c_strings, line)
             delete(line, req.allocator)
             if !entry_ok {
                 return .Out_Of_Memory
             }
             slist^ = curl_slist_append(slist^, entry)
             if slist^ == nil {
                 return .Out_Of_Memory
             }
         }
     }
     ```

     (`strings`/`c_strings_add`/`curl_slist_append` are the ones the loop above already uses,
     `:962-974`.)

3. `src/session/jar.odin` — factor the policy out of `session_apply_cookies`
   (`:119-176`) into an exported proc, and add the hook:

   ```odin
   // session_cookie_value is the `Cookie` value the jar produces for a request to
   // `host`/`request_path` over `secure`, or "" when it has none. Owned by the
   // caller. session_apply_cookies is its first caller; a followed hop re-derives
   // through it (requests' resolve_redirects, sessions.py:235-243).
   session_cookie_value :: proc(
       session: ^Session,
       host: string,
       request_path: string,
       secure: bool,
       allocator: mem.Allocator,
   ) -> string
   ```

   — the body is `session_apply_cookies:123-175` minus the `request_header_get` guard and the
   `request_add_header` call, taking `host`/`request_path`/`secure`/`allocator` as parameters
   instead of reading them off the request.

   `session_apply_cookies` keeps its signature and behaviour (first request):
   guard `session == nil || len(session.cookies) == 0` → guard "the request already carries a
   `Cookie`" → `value := session_cookie_value(session, request.host, path, request.scheme == .HTTPS, request.allocator)`
   → return on `""` → `defer delete(value, request.allocator)` → `request_add_header`.

   ```odin
   // session_cookie_hook installs the jar on the request the transport will send,
   // so a followed hop can re-derive its `Cookie` header (http.Cookie_Hook).
   session_cookie_hook :: proc(session: ^Session, request: ^http.Request) {
       if session == nil {
           return
       }
       request.cookie_hook = http.Cookie_Hook {
           context = session,
           value   = session_cookie_value_for,
       }
   }

   // session_cookie_value_for is http.Cookie_Hook.value: the transport hands it a
   // followed hop's prepared URL. The split is the one `collect_response_cookies`
   // (`:43-50`) uses for the same purpose, so the host the jar matches against is
   // the host its cookies were stored for.
   @(private)
   session_cookie_value_for :: proc(context: rawptr, url: string, allocator: mem.Allocator) -> string {
       session := cast(^Session) context
       target, split_err := http.url_split(url, nil)
       if split_err != .None {
           return ""
       }
       request_path := target.path
       if request_path == "" {
           request_path = "/"
       }
       return session_cookie_value(session, target.host, request_path, target.scheme == .HTTPS, allocator)
   }
   ```

4. `src/session/context.odin:1002` — after `session_apply_cookies(session, request)` add
   `session_cookie_hook(session, request)`. (`session` is nil unless `--session` /
   `--session-read-only` was given, `:135-136`; `session_cookie_hook` is the nil check.)

5. `src/session/context.odin` — the **rendered** hop head must show what the wire sends.
   `write_hop_request` (`:418-476`) renders every followed hop from
   `first_request.headers` (`:460`), which still carries the first URL's `Cookie`. Apply the
   same rule there: skip any `Cookie` header while building `headers`, and append the jar's
   value for `hop.url` via the same `session_cookie_value` (host/path/scheme come from the
   `target` the function already splits at `:453`; the `refused` branch at `:445-450` has no
   adapter and is never sent, so drop there and append nothing). This needs the session
   pointer threaded in: add a `session: ^Session` parameter to `write_hop_request` and to
   `write_hop_messages` (`:333`) and pass `has_session ? &session : nil` at both call sites
   (`:227`, `:289`) — exactly the expression `build_request` is called with at `:150`.

**Risk of the change.**
* With **no** `--session`, hop-N cookies are now dropped entirely. That matches the reference
  for `Cookie:` items (measured: `requests` sends none on hop 2, even same-origin), and it is
  the fail-closed direction; SF-D3 notes the one case where the reference would still send one.
* `Secure` cookies now obey `cookie_applies` on every hop, so a plain-http hop drops them even
  on the same host — which is exactly the §7.3 case G leak.
* Same-host jar cookies keep travelling (measured case B: `requests` sends them across a port
  change), so ordinary session flows are not broken.
* The rendering change touches only followed hops; **no existing test renders a hop with a
  `Cookie` header** (checked: `grep -rn 'Cookie' tests/` matches only the first-request jar
  test and a `Set-Cookie` fixture), so only the new tests below pin it.

**Verification.**
* `tests/http_engine_test.odin` — new `test_engine_rebuilds_the_cookie_header_on_a_redirect`.
  The sink must live on another **host**, not another port (a port change keeps cookies, by
  design): refactor `engine_server_start` (`:53-87`) into
  `engine_server_start_on(backing: mem.Allocator, address: net.Address) -> (server: ^Engine_Server, ok: bool)`
  and keep `engine_server_start` as a one-line wrapper binding `net.IP4_Address{127,0,0,1}`.
  Cases, all asserting on the bytes the sink captured (`server.requests`, raw):
  1. request carries `Cookie: item=1` (a header, no hook) and a 302 to
     `http://127.0.0.2:<sink>/landing` → hop 2 has **no** `Cookie:` line;
  2. a `Cookie_Hook` stub (`value = <file-level test proc>` returning `"sess=JARSECRET"` for
     the target URL) and the same cross-host 302 → hop 2 has no `Cookie:` line;
  3. the same stub and a 302 to `http://127.0.0.1:<other listener>/landing` (same host, other
     port) → hop 2 **has** `Cookie: sess=JARSECRET`;
  4. the stub returning `""` (a path the jar's policy rejects) → hop 2 has no `Cookie:` line;
  5. the first hop still carries the request's own `Cookie` header unchanged.
  *Proof the test bites:* cases 1, 2 and 4 fail on the pre-fix code, where hop 2 replays the
  first URL's header.
* `tests/session_store_test.odin` — keep `test_session_cookie_jar_replays_a_set_cookie`
  (`:266-334`) green unchanged: it is the regression guard for the
  `session_apply_cookies` refactor (first request still gets `BODY=deterministic-cookie`).
  Add `test_session_cookie_value_respects_domain_path_and_secure`, calling the new exported
  `session.session_cookie_value` directly with: the stored cookie's host / another host /
  a path outside the cookie's path / `secure = false` for a `Secure` cookie → `""`; and the
  matching combination → the cookie text.
* The end-to-end wire check for the ticket: the two-listener probe of §7.3 case H re-run by QA
  must show hop 2 with `cookie=None` for `oj` (it shows `sess=TOPSECRET` today).

---

### SF-002 — `should_strip_authorization` must reproduce `requests`' ordering

**Finding / evidence.** SEC-01 (judge `MAJOR`, re-rated **medium** here; §6). `url_parts`
normalises absent ports to 80/443 **before** the comparison, so the documented `http → https`
exception is unreachable and the same-scheme/non-standard-port case fail-opens. Divergences,
pinned case by case against `requests` 2.33.0 (`sessions.py:128-158`):

| old → new | `requests` | `oj` today (`:1177-1195`) | after SF-002 |
| --- | --- | --- | --- |
| `http://h/a` → `https://h/b` | keep | strip | keep |
| `http://h:80/a` → `https://h:443/b` | keep | strip | keep |
| `http://h/a` → `http://h/b` | keep | keep | keep |
| `http://h:443/a` → `https://h:443/b` | strip | strip | strip |
| `https://h:80/a` → `https://h/b` | strip | strip | strip |
| `http://h:8080/a` → `https://h:8080/b` | strip | **keep** | strip |
| `http://h/a` → `https://h:8443/b` | strip | strip | strip |
| `http://h/a` → `http://h:8080/b` | strip | strip | strip |
| `http://h/a` → `https://other/b` | strip | strip | strip |

*Attacker and precondition.* For the fail-open rows (6): a redirect to the same host and port
with the scheme changed — credentials are sent to an endpoint `requests` treats as a different
origin. For the fail-closed rows (1, 2): no attacker; an ordinary `http → https` upgrade loses
the header and the authenticated redirect silently 401s (this is the judge's F1 symptom).

**Fix.** Rewrite `should_strip_authorization` in `src/http/curl_transport.odin:1173-1195`,
keeping the `url_parts` helper (`:1140-1171`) untouched. Port `requests`' order literally:
host first, then the standard-port `http → https` exception **before** any port normalisation,
then the scheme's default-port rule, then `changed_port or changed_scheme`.

```odin
should_strip_authorization :: proc(old_url: string, new_url: string) -> bool {
    if strings.equal_fold(old_url, new_url) {
        return false
    }
    old := url_parts(old_url)
    new := url_parts(new_url)
    if !strings.equal_fold(old.host, new.host) {
        return true
    }
    // The reference's one exception, evaluated *before* any default-port
    // normalisation: http (80 or absent) -> https (443 or absent) keeps them
    // (sessions.py:138-144).
    if strings.equal_fold(old.scheme, "http") && (old.port == 0 || old.port == 80) &&
       strings.equal_fold(new.scheme, "https") && (new.port == 0 || new.port == 443) {
        return false
    }
    changed_port := old.port != new.port
    changed_scheme := !strings.equal_fold(old.scheme, new.scheme)
    // A same-scheme hop that only spells the default port differently is the same
    // origin (sessions.py:146-155, `default_port`).
    default_port := strings.equal_fold(old.scheme, "https") ? 443 : 80
    if !changed_scheme &&
       (old.port == 0 || old.port == default_port) &&
       (new.port == 0 || new.port == default_port) {
        return false
    }
    return changed_port || changed_scheme
}
```

`url_parts` reports an absent port as `0`, which is the `None` of `urlparse(...).port`; the two
schemes this is ever called with are `http`/`https` (a URL without an HTTP adapter is refused
at `:1637-1639`, before the next hop is installed), which is why the reference's
`DEFAULT_PORTS.get(scheme, None)` collapses to the ternary above.

**Risk.** This changes which credential the wire carries on redirects in both directions; it is
the reference's behaviour, so goldens are unaffected (no test covers the proc today —
`grep -rn 'should_strip\|strip_auth' tests` is empty). No other caller exists.

**Verification.**
* `tests/http_test.odin` — new `test_should_strip_authorization_matches_requests`: the nine
  rows above as a table, `requests`' column as the expected value. (The proc is exported, so the
  test calls `http.should_strip_authorization` directly.) Rows 1, 2, 4, 5 and 6 are red on the
  pre-fix code.
* `tests/http_engine_test.odin` — new
  `test_engine_keeps_and_strips_authorization_across_a_redirect`, two listeners, both plain
  HTTP: (a) hop 1 `http://127.0.0.1:A/start` answers `302 Location: /next` →
  `http://127.0.0.1:A/next` must carry `Authorization`; (b) `302 Location:
  http://127.0.0.1:B/landing` (same host, other port) must not. Part (b) is the wire-level proof
  that credentials do not cross an origin.

---

### SF-003 — apply `--ciphers` (`CURLOPT_SSL_CIPHER_LIST`)

**Finding / evidence.** SEC-ADD-02 (medium). `--ciphers` is in the option table
(`src/cli/parse.odin:347`), stored (`:641`, `:1497`, `:1912`), advertised in `oj --help`
(`src/cli/help_text_generated.odin:378-383`, `:801-806`) and **never applied**: no
`CURLOPT_SSL_CIPHER_LIST` exists anywhere in `src/http`. `oj --ciphers=NOT-A-REAL-CIPHER …`
exits 0, where libcurl would answer `CURLE_SSL_CIPHER` (59) — the constant is already declared
for the error path (`src/http/curl_transport.odin:629-631`). Reference httpie 3.2.4 applies it
(`client.py:70` → `httpie/ssl_.py` `HTTPieSslAdapter(..., ciphers=...)`).

**Fix.**
1. `src/http/libcurl.odin` — beside `CURLOPT_CAINFO` (`:120`):
   `CURLOPT_SSL_CIPHER_LIST :: CURLoption(10083)` with a comment recording the provenance
   (`CURLOPTTYPE_STRINGPOINT + 83`, verified with `curl_easy_option_by_name` on libcurl 8.5.0,
   the same run-time check `tests/libcurl_test.odin` makes).
2. `src/http/types.odin` — `ciphers: string,` in the borrowed group at `:373-382` (with
   `cert`/`cert_key`/`cert_key_pass`/`ca_bundle`; **borrowed from `cli.Options`**, never freed
   here).
3. `src/session/context.odin` — next to `request.ca_bundle = verify_ca_bundle(options.verify)`
   (`:936`): `request.ciphers = options.ciphers`.
4. `src/http/curl_transport.odin` — in the TLS block, after the `CURLOPT_CAINFO` block
   (`:1369-1377`), mirroring its shape:

   ```odin
   // `--ciphers` is OpenSSL's cipher-list grammar and libcurl hands it to OpenSSL
   // verbatim: a list the library cannot use fails the handshake with
   // CURLE_SSL_CIPHER (mapped to .TLS_Failure above), which is the loud failure
   // the help text promises.
   if req.ciphers != "" {
       ciphers_c, ciphers_ok := c_strings_add(&c_strings, req.ciphers)
       if !ciphers_ok {
           return .Out_Of_Memory
       }
       if code := setopt_string(handle, CURLOPT_SSL_CIPHER_LIST, ciphers_c); code != CURLE_OK {
           return map_curl_error(code)
       }
   }
   ```

   (Use the same `c_strings` expression the `CAINFO` block at `:1370` uses — that block is
   inside the same function, so copy its spelling exactly.)

**Risk.** Behaviour change for anyone who already passes `--ciphers`: a bogus or unusable list
now **fails the run** instead of being ignored (see §9.7). Runs without `--ciphers` are
untouched. `OPENSSL`-grammar strings that only the system's provider rejects will now fail
loudly — which is the point of a documented control.

**Verification.**
* `tests/libcurl_test.odin` — add `check_option(t, "SSL_CIPHER_LIST", http.CURLOPT_SSL_CIPHER_LIST)`
  to `test_option_constants_match_libcurl` (`:32-72`), beside `CAINFO` (`:61`). This is the
  in-suite half: it fails if the ABI number is wrong.
* **Scripted half, run by QA, not committed** (the suite has no TLS capability — §9.1 — and
  `build/` is git-ignored while the tree is deliberately free of a parity harness). With a
  local TLS listener on a self-signed cert:
  ```sh
  # pre-fix: exit 0 (the option is ignored). post-fix: non-zero (CURLE_SSL_CIPHER → TLS failure)
  build/oj --verify=no --ciphers=NOT-A-REAL-CIPHER GET https://127.0.0.1:<TLS_PORT>/
  # control: the same request with no --ciphers must still succeed
  build/oj --verify=no GET https://127.0.0.1:<TLS_PORT>/
  ```
  Record both exit codes and the error line in the Verification section.

---

### SF-004 — session files are written `0600` (and existing files are chmod'd)

**Finding / evidence.** SEC-ADD-03 (hardening). `SESSION_FILE_MODE`
(`src/session/store.odin:43-44`) is user+group+other read, and the file contains
`"raw_auth": "alice:s3cr3t"`. Containment today is the 0700 directory
(`SESSION_DIR_MODE`, `:43`), which is why this is hardening and not a vulnerability; the
reference does the same (`httpie/config.py:110-128`, `Path.write_text` under
`mkdir(mode=0o700)`), and `tests/session_store_test.odin:127-134` pins the 0644 on purpose.

**Fix.**
1. `src/session/store.odin:39-44` — set
   `SESSION_FILE_MODE :: os.Permissions{.Read_User, .Write_User}` and replace the comment:
   the file holds a plaintext credential, 0600 is a deliberate divergence from the reference's
   0644 (which the 0700 directory is what actually contains), and the divergence is recorded
   here so nobody "restores parity" by accident.
2. `src/session/store.odin` — in `session_save` (`:794-812`), after a successful
   `os.write_entire_file_from_bytes`, add
   `_ = os.chmod(session.path, SESSION_FILE_MODE)` with a comment: the mode argument only
   applies when the file is created, so a session written by an older build (or by httpie)
   keeps 0644 until the next save; the chmod failure is not fatal (best-effort hardening, the
   data is already written).
3. `tests/session_store_test.odin` — update the expectation at `:127-134` to
   `{.Read_User, .Write_User}` / `want 0600`, and the doc comment at `:38-39` and `:101-102`
   ("the same 0700 directory / 0644 file modes" → "0700 directory / 0600 file"), plus the
   `@(test)` comment above `test_session_cap1_file_matches_the_reference_capture` (`:36-39`).

**Risk.** A deliberate, user-invisible divergence from the reference's file mode; no content
change, so a session file still round-trips between `oj` and `httpie`. Pre-existing files are
tightened on their next write.

**Verification.**
* `test_session_cap1_file_matches_the_reference_capture` (`:40-138`) must pass with the new
  expectation (it is the test that pins the mode).
* New `test_session_save_tightens_an_existing_0644_file`: pre-create the session path with
  `.Read_User, .Write_User, .Read_Group, .Read_Other`, run the same offline `--session` write,
  then `os.stat` and expect `{.Read_User, .Write_User}`. Red before the `os.chmod` line and
  green after it (the first half of the item alone does not satisfy this test).

---

### SF-005 — the option-table guard must cover the two constants it omits

**Finding / evidence.** SEC-05 (judge `MINOR`, hardening here): `CURLOPT_READDATA`
(`src/http/libcurl.odin:113`) and `CURLOPT_READFUNCTION` (`:125`) are used by the engine
(`src/http/curl_transport.odin:819,822`) but are absent from
`test_option_constants_match_libcurl` (`tests/libcurl_test.odin:34-66`). The numbers are
correct today; the guard is what the constant table relies on instead of C headers.

**Fix.** Add to `tests/libcurl_test.odin:32-66`:
`check_option(t, "READDATA", http.CURLOPT_READDATA)` next to `WRITEDATA` (`:55`) and
`check_option(t, "READFUNCTION", http.CURLOPT_READFUNCTION)` next to `WRITEFUNCTION` (`:65`).

**Risk.** None (test-only). Cheap insurance, and it must land with SF-003 so the new constant
joins the table in the same PR.

**Verification.** The test itself; to prove it bites, temporarily set
`CURLOPT_READFUNCTION :: CURLoption(20011)` and watch it fail.

---

### 9.4 DEFER — follow-up tickets (do not implement in this PR)

**SF-D1 — Digest auth: support the SHA-256 challenge (SEC-ADD-04, low).**
`digest_authorization` (`src/http/digest.odin:244-253`) accepts only `MD5`/`MD5-SESS`, so a
server offering only `SHA-256` (RFC 7616) cannot be authenticated; the failure is fail-closed
and `MD5` is what RFC 2617 mandates, which is why it is not in this PR. Ticket: *"digest auth:
implement `SHA-256`/`SHA-256-sess` (RFC 7616) in `src/http/digest.odin`, replacing the
`md5_hex_join` call sites at `:266-291` with an algorithm-selected hash; add RFC 7616 §3.9.1
vectors to `tests/digest_test.odin` (the RFC 1321 table at `:21-40` stays as the MD5 case);
`requests` supports the algorithm, so this is also a parity item."* Effort L, and it must not
touch the MD5 path while doing it.

**SF-D2 — pin a minimum TLS version (SEC-ADD-05, hardening).**
`CURLOPT_SSLVERSION` is never set; urllib3/requests pin `TLSv1_2`. No exploit path was found
(negotiated TLS 1.3 here), and a pin **removes** connectivity to TLS 1.0/1.1-only servers — a
user-visible break that deserves its own change and its own release note. Ticket: *"set
`CURLOPT_SSLVERSION = CURL_SSLVERSION_TLSv1_2` (6) in the TLS block of
`src/http/curl_transport.odin` to match urllib3's `ssl_minimum_version = TLSv1_2`; verification
needs a TLS probe that caps at TLSv1.1 (the Odin suite has no TLS listener — see the
Remediation Plan §9.1)."* Note `src/cli/parse.odin:640,706` already carries an unused
`ssl_version` field: decide in that ticket whether `--ssl-version` becomes a real option or the
dead field is removed.

**SF-D3 — a `Set-Cookie` from a redirecting hop is not applied to the following hop (found
while planning; parity gap, not a leak).**
`requests` runs `extract_cookies_to_jar` per hop inside the redirect loop, so a cookie set by
the redirecting response travels on the next hop. `oj` collects the whole chain's `Set-Cookie`
*after* the exchange (`session_collect_cookies`, `src/session/jar.odin:22-34`), so the jar the
SF-001 hook reads does not yet contain it. The result is fail-closed (a cookie the reference
would send is not sent), never a disclosure. Ticket: *"apply each hop's `Set-Cookie` to the
session jar before the next hop is sent — the chain's cookies must be visible to the hop loop
(probably by folding `collect_response_cookies` (`jar.odin:37-57`) into a per-hop call the
transport can make through the same session hook SF-001 added); golden: a
`Set-Cookie`-plus-302 exchange must reach hop 2 with the cookie on it."*

### 9.5 Findings deliberately left unfixed (with reasons)

| finding | why no code change |
| --- | --- |
| SEC-02 (TLS verify default on) | control verified present and mapped to libcurl; nothing to fix |
| SEC-03 (digest MD5 vs RFC 1321) | protocol-correct; the algorithm-range caveat is SF-D1 |
| SEC-04 (`CURLOPT_VERBOSE` never set) | the secure state *is* the current state; SF-005's guard keeps the constants honest and nothing may introduce a verbose channel |
| SEC-06 (thin C binding, run-time-validated constants) | design verified; SF-005 closes the only coverage gap it had |
| RESTRICTED COVERAGE from §8: the 8 `*_generated.odin` files, `src/http/url.odin` + `idna_generated.odin` parser-differential review, `src/http/proxy.odin` (proxy credentials), netrc permission enforcement | not examined in §1 either; **not claimed here**. These stay open as review coverage, not as findings. If the PR's reviewer wants one of them in this cycle, it needs its own analysis task before it can be specified. |

### 9.6 In-Scope / Out-of-Scope for this PR

**In scope (implement, test, verify):**
* SF-001 `Cookie` redirect rule — `src/http/types.odin`, `src/http/curl_transport.odin`,
  `src/session/jar.odin`, `src/session/context.odin`; tests in `tests/http_engine_test.odin`,
  `tests/session_store_test.odin`.
* SF-002 `should_strip_authorization` — `src/http/curl_transport.odin`; tests in
  `tests/http_test.odin`, `tests/http_engine_test.odin`.
* SF-003 `--ciphers` applied — `src/http/libcurl.odin`, `src/http/types.odin`,
  `src/http/curl_transport.odin`, `src/session/context.odin`; `tests/libcurl_test.odin` plus the
  QA TLS probe.
* SF-004 session file `0600` — `src/session/store.odin`; `tests/session_store_test.odin`.
* SF-005 option-table guard — `tests/libcurl_test.odin`.
* `docs/security-findings.md`: this plan, the `## Verification` section the QA task appends, and
  the `## Implementation Notes` section the coder task appends. Nothing else in `docs/`.

**Out of scope (do not touch in this PR):**
* Everything in §9.5 and §9.4 (SF-D1/D2/D3) — follow-up tickets, not this branch.
* `DOC-01`–`DOC-08`: documentation and provenance (missing `docs/PARITY.md`, missing
  `.github/workflows/ci.yml`, the allocator-rule violations in `src/cli`, `src/session`,
  `src/http`, `src/output`, the three unallocated `make(` sites, missing
  `tests/golden_test.odin`/`docs/REVIEW.md`/`build/probe_*`). None of them is a vulnerability,
  and several would re-introduce files the project removed on purpose. They need a
  documentation/contract decision from the owner, not a security commit.
* `MEM-01`/`MEM-02`: memory-ownership positives — keep them working, change nothing.
* Any refactor, formatting, rename or dependency bump not named above; in particular **do not**
  "fix" the `context.temp_allocator` uses (RATING.md F4) or the `make(` sites (F5) — they are
  another card's subject and would bury this diff.
* `--ssl-version` (SF-D2) and any new CLI surface.

### 9.7 Breaking changes, migrations, and decisions for the human reviewer

1. **SF-001 changes what a redirect sends** (deliberate, parity-driven): a `Cookie:` item no
   longer follows *any* redirect; jar cookies follow the reference's domain/path/`Secure`
   policy per hop, so a cross-host redirect stops carrying the session cookie and an
   `https → http` downgrade stops carrying a `Secure` one. Any user depending on the old
   behaviour sees the cookie stop — that is the vulnerability being closed, so it must be
   called out in the PR body.
2. **SF-002 changes `Authorization` on redirects in both directions**: `http → https` on
   standard ports now *keeps* it (previously stripped, breaking authenticated upgrades), and
   the same-host/non-standard-port scheme change now *strips* it (previously kept). No
   migration.
3. **SF-003 makes `--ciphers` real**: an invalid or unusable cipher list now fails the run
   (`CURLE_SSL_CIPHER` → a TLS failure message) where it used to be ignored. Anyone who passes
   `--ciphers` in a script should re-check that the list is accepted. This is the only fix here
   that can turn a green script red.
4. **SF-004 is a deliberate divergence from `httpie`'s file mode** (0644 → 0600), and
   `tests/session_store_test.odin` pins the mode, so the *test* changes too. If the maintainer
   prefers strict reference parity over defence in depth, SF-004 is the one item to drop — it
   is the only one whose value depends on threat model rather than on a leak: say so in review,
   don't silently revert a fix.
5. **No migrations elsewhere**: nothing changes the session-file *contents*, the CLI surface,
   the exit codes of existing successful runs, or any golden.
6. **Doc/contract decisions this plan cannot make for the owner**: whether `docs/PARITY.md`
   gets restored (the inventory's §8 open questions) and whether the session file mode should
   stay reference-identical (item 4). Both are recorded, neither blocks the PR.

### 9.8 How the whole PR is proven (summary for the coder and QA tasks)

| item | in-suite test (name) | must fail before the fix | scripted/other evidence |
| --- | --- | --- | --- |
| SF-001 | `test_engine_rebuilds_the_cookie_header_on_a_redirect` (engine), `test_session_cookie_value_respects_domain_path_and_secure` (session store) | yes (cases 1, 2, 4) | the two-listener cross-host probe (hop 2 `cookie=None`) |
| SF-002 | `test_should_strip_authorization_matches_requests` (http), `test_engine_keeps_and_strips_authorization_across_a_redirect` (engine) | yes (5 of 9 rows, part (b)) | — |
| SF-003 | `test_option_constants_match_libcurl` (constant id) | no (new coverage) | TLS probe: `--ciphers=NOT-A-REAL-CIPHER` must go from exit 0 to a TLS failure; the no-`--ciphers` control must still succeed |
| SF-004 | `test_session_cap1_file_matches_the_reference_capture` (mode), `test_session_save_tightens_an_existing_0644_file` | second test: yes | — |
| SF-005 | `test_option_constants_match_libcurl` | no (new coverage) | temporary wrong number to prove it bites |

Full gates for the branch: `make check` exit 0 (zero warnings, both packages), `make test-unit`
exit 0 with the 167 existing tests plus the new ones, `421 goldens 0 mismatches` unchanged.
Every count in this plan (167 tests, 421 goldens) is this worktree's, re-measured today.

## Implementation Notes

Branch `fix/security-rating-findings`, base `0f3cf5d`; this document was recovered from
`wt/t_0c45de6d` (`8ade88c`) as the card's comment describes. Every in-scope item is
implemented, in the plan's order, in a commit of its own.

Gates on the final commit: `make check` exit 0 (zero warnings, `src` and `tests`), `make
test-unit` exit 0 — **173 tests** (167 existing + 6 new) and `421 goldens 0 mismatches`,
unchanged.

| finding | commit | test that covers it | red before the fix |
| --- | --- | --- | --- |
| SF-001 | `37e9b65` (fix), `c0b8f84` (rendered hop) | `test_engine_rebuilds_the_cookie_header_on_a_redirect`, `test_session_cookie_value_respects_domain_path_and_secure`, `test_session_renders_no_cookie_on_a_cross_host_hop` | yes — 5 assertions fail with the hop's `Cookie` strip disabled; the scripted two-listener probe below separates pre-fix from post-fix |
| SF-002 | `5452a6b` | `test_should_strip_authorization_matches_requests`, `test_engine_keeps_and_strips_authorization_across_a_redirect` | yes — the table is red on 4 of its 9 rows against the old predicate (measured, see item 2 below) |
| SF-003 | `2566128` | `test_option_constants_match_libcurl` (id `10083`) | not in suite (new coverage); the TLS probe goes from exit 0 to a TLS failure |
| SF-004 | `d003340` | `test_session_save_tightens_an_existing_0644_file`, plus the deliberately updated mode expectation in `test_session_cap1_file_matches_the_reference_capture` | yes — the tightening test fails with the constant alone (chmod disabled locally) |
| SF-005 | `32bc45a` | `test_option_constants_match_libcurl` | not in suite (new coverage); a locally wrong number fails the table |

Pre-fix measurements, taken on this branch with each fix neutralised in turn (so the new
tests are the only variable):

* SF-001, the strip disabled in the hop loop: `a cross-host hop must not carry the first
  URL's Cookie`, `the jar refused this host: no Cookie line may go out`, `a same-host hop
  must carry the jar's Cookie, got "item=1"`, `the jar's path rule rejected the hop: no
  Cookie line may go out`, `the cross-host hop must not carry the jar's Cookie`.
* SF-002, the old body restored: `http://h/a -> https://h/b: got strip=true, want false`,
  `http://h:80/a -> https://h:443/b: got strip=true, want false`,
  `http://h:443/a -> https://h:443/b: got strip=false, want true`,
  `http://h:8080/a -> https://h:8080/b: got strip=false, want true`.
* SF-004, `os.chmod` commented out: `a 0644 session file must be tightened on save, mode is
  Permissions{Read_Other, Read_Group, Write_User, Read_User}`.
* SF-005, `CURLOPT_READFUNCTION` set to `20011`: `READFUNCTION: libcurl says 20012,
  src/http/libcurl.odin says 20011`.

### Deviations, and what §9 got wrong

1. **SF-003 needed CLI plumbing its file list omits.** `cli.Options` had no `ciphers` field
   and `cli.parse` dropped the finished namespace's value, so `CURLOPT_SSL_CIPHER_LIST` had
   nothing to apply: `--ciphers` is documented and parsed but never reached the transport.
   The fix therefore also adds `Options.ciphers` (`src/cli/options.odin`), its clone in
   `parse.odin` and its free in `options_destroy`. Without that the item is unreachable
   from the CLI.
2. **SF-002: 4 of 9 rows are red, not 5, and the engine test's part (b) does not
   discriminate.** Same host, different port, same scheme is stripped by the old code as
   well, so `test_engine_keeps_and_strips_authorization_across_a_redirect` proves the wire
   behaviour but is green either way; so is part (a) (a same-origin hop is kept by both).
   Every discriminating row changes the scheme `http -> https`, which this suite cannot
   perform (the pinned toolchain has no TLS), so `test_should_strip_authorization_matches_requests`
   carries the discrimination and the engine test pins the bytes.
3. **SF-001 got a third test.** `write_hop_request` is a changed code path that nothing
   covered: no case in the suite ran a live exchange through `session.run` with `--follow`,
   so the printed hop head could have drifted from the wire unnoticed. The new
   `test_session_renders_no_cookie_on_a_cross_host_hop` seeds the reference's cookie file,
   follows a cross-host `302`, and asserts the jar's `Cookie` line is printed exactly once —
   on the first request — while the listeners' bytes agree.
4. **SF-005 also carries the `SSL_CIPHER_LIST` row** SF-003 introduced: one table, both
   constants guarded.
5. **The plan's §9.7 items are all real, and item 3 has a second edge worth a PR note:** a
   TLS 1.3 *ciphersuite* name (`--ciphers=TLS_AES_128_GCM_SHA256`) now fails loudly, because
   OpenSSL's `SSL_CTX_set_cipher_list` — which is what `CURLOPT_SSL_CIPHER_LIST` feeds —
   speaks the TLS 1.2-and-below grammar (TLS 1.3 suites need `set_ciphersuites`). httpie
   inherits exactly the same limitation through urllib3's `set_ciphers`, so this is the
   reference's behaviour, not a new divergence; a valid TLS 1.2 list
   (`--ciphers=ECDHE+AESGCM`) is unaffected.

### Evidence commands for the QA card (`t_b1daab68`)

The in-suite tests are in the table above; the two items with no committable test are these,
and both are reproducible with any local listener:

* **SF-003 (TLS).** A self-signed cert (`openssl req -x509 -newkey rsa:2048 -keyout key.pem
  -out cert.pem -days 1 -nodes -subj "/CN=127.0.0.1"`) and any TLS listener on
  `127.0.0.1:<PORT>` (`openssl s_server -accept <PORT> -cert cert.pem -key key.pem -www
  -quiet`, or a short python `ssl` server) are enough — the assertion is on the client's
  exit code:
  * `build/oj --verify=no GET https://127.0.0.1:<PORT>/` → exit 0 (the control).
  * `build/oj --verify=no --ciphers=NOT-A-REAL-CIPHER GET https://127.0.0.1:<PORT>/` →
    pre-fix exit 0 with the body printed (the option was ignored); post-fix exit 1 with a
    TLS failure on stderr.
* **SF-001 (cross-host cookie).** Two plain-HTTP listeners: an origin on `127.0.0.1:P1` that
  answers every request with `302` and `Location: http://127.0.0.2:P2/landing`, and a sink on
  `127.0.0.2:P2` that records the headers it receives. Put a session file at
  `$HTTPIE_CONFIG_DIR/sessions/127.0.0.1_<P1>/probe.json` holding one host-only cookie for
  `127.0.0.1` (the shape of `tests/fixtures/sessions/cap-cookie.json`) and run
  `build/oj --session=probe --follow -p Hh GET http://127.0.0.1:<P1>/start`. Pre-fix the sink
  recorded `Cookie: sess=TOPSECRET`; post-fix it records none and the printed hop 2 head has
  no `Cookie` line, while hop 1 carries it.

### Commit list

`843c96c` docs · `37e9b65` SF-001 · `5452a6b` SF-002 · `2566128` SF-003 · `d003340` SF-004 ·
`32bc45a` SF-005 · `c0b8f84` SF-001's rendered hop · plus this notes commit. 13 files
touched, all of them named by the plan (`docs/security-findings.md`, the four SF-001 sources,
`curl_transport.odin` for SF-002/SF-003, `libcurl.odin`/`types.odin`/`context.odin` for
SF-003, `store.odin` for SF-004, and the four test files) — no unrelated file changed.

---

## Verification

Task: `t_b1daab68` — *"Verify fixes and check for security regressions"*. Independent
verification of the five in-scope items on branch `fix/security-rating-findings`
(**base `0f3cf5d`, head `570a405`**, `origin/fix/security-rating-findings == 570a405`).
Nothing in this section was taken from the coder's `## Implementation Notes`: every claim
below was re-measured here, on this host, with the commands shown. Where the measurement is
a scripted probe rather than an in-suite test, the probe is quoted so it can be re-created —
the scripts live outside the tree (`~/.hermes/profiles/qa/cache/scratch/verify/`), as §9
requires for the parity-harness-free tree.

**Verdict: READY FOR PR.** All five in-scope findings PASS; no regression was introduced;
every in-suite test that carries a fix was measured red on the pre-fix code; the two items
without an in-suite test (SF-003's TLS behaviour, SF-001's cross-host wire path) were
measured on real binaries against the reference (`requests` 2.33.0) run against the same
loopback servers. The two coverage limits are named in V.11, not hidden.

### V.1 Environment

| | value |
| --- | --- |
| tree | `/home/matteo/htthor/.worktrees/t_b1daab68` (worktree, branch `qa/t_b1daab68-verify` = `570a405`) |
| base tree / pre-fix binary | `0f3cf5d`, built in a throwaway worktree under the QA scratch dir |
| Odin | `dev-2026-09-nightly:a2fb372` (toolchain `odin-linux-amd64-nightly+2026-09-01`) |
| libcurl / OpenSSL | 8.5.0 / OpenSSL 3.0.13 |
| reference | `requests` 2.33.0 (`should_strip_auth`, `resolve_redirects`, `Session.cookies`) |
| binaries | pre-fix `sha256 ba6aa3a53f31…`, post-fix `sha256 24c5e43101d1…` (both `make build`, exit 0) |

### V.2 Per-finding results (the §9.8 table, measured)

| finding | in-suite test | fails pre-fix (measured here) | scripted / wire evidence | verdict |
| --- | --- | --- | --- | --- |
| SF-001 | `test_engine_rebuilds_the_cookie_header_on_a_redirect`, `test_session_renders_no_cookie_on_a_cross_host_hop`, `test_session_cookie_value_respects_domain_path_and_secure` | **yes** — 2 tests, 5 assertions, with `hop.redirect_target` forced false on the branch | two-listener wire probe (V.3): cross-host, cross-host jar, `Secure` downgrade, same-origin item, `127.0.0.1`→`127.0.0.10`; reference agrees on every case | **PASS** |
| SF-002 | `test_should_strip_authorization_matches_requests`, `test_engine_keeps_and_strips_authorization_across_a_redirect` | **yes** — 4 of 9 rows red with the pre-fix body restored (confirms the plan's 5-row claim was wrong, as the coder's item 2 says) | 9-row probe vs `requests` (9/9) + a 1024-pair URL matrix (0 mismatches post-fix, 54 pre-fix) + wire: same-host/same-port scheme change | **PASS** |
| SF-003 | `test_option_constants_match_libcurl` (id `10083`) | n/a in suite (new coverage; constant-guard bit proven in V.7) | TLS probe on `127.0.0.1:19200`, self-signed: bogus `--ciphers` **exit 0 pre-fix → exit 1 post-fix**; no-`--ciphers` control exit 0 both; valid TLS 1.2 list exit 0; TLS 1.3 suite name exit 1 (documented) | **PASS** |
| SF-004 | `test_session_save_tightens_an_existing_0644_file` (+ the deliberately updated mode expectation) | **yes** — fails with `os.chmod` commented out | CLI probe: fresh file 0644→0600, pre-existing 0644→0600, directories 0700 unchanged, contents unchanged | **PASS** |
| SF-005 | `test_option_constants_match_libcurl` | n/a in suite (new coverage; guard proven in V.7) | wrong `CURLOPT_READFUNCTION` makes the guard fail with libcurl's own number, and (with a colliding value) aborts the whole suite — the constant is load-bearing | **PASS** |

Items marked **NOT REPRODUCIBLE** and fixed anyway: **none** — §9.2 records zero, so there was
nothing of that kind to re-test. Out-of-scope findings (`SF-D1`–`SF-D3`, `DOC-*`, `SEC-02`/
`SEC-03`/`SEC-04`/`SEC-06`, `MEM-*`) were checked only for *absence of change* (V.10).

### V.3 SF-001 — `Cookie` must not follow a redirect (high)

Two plain-HTTP loopback listeners, an origin on `127.0.0.1:P1` answering `302` with
`Location:` on another host, and a sink that logs the raw request head it receives. Six
cases, each run against the pre-fix binary, the post-fix binary, and (for A/B/D/E) the
reference:

| case | pre-fix hop 2 | post-fix hop 2 | `requests` 2.33.0 |
| --- | --- | --- | --- |
| A `Cookie:` item, `127.0.0.1` → `127.0.0.2` | `Cookie: sess=TOPSECRET` (**leak**) | none | none |
| B session-jar cookie, same redirect | `Cookie: sess=TOPSECRET` (**leak**) | none | none |
| C `Secure` jar cookie, `https://127.0.0.1:P` → `http://127.0.0.1:P` (one dual-protocol port) | sent **in cleartext** on hop 2 (**leak**) | none | not run (same rule) |
| D control — jar cookie, same host / **other port** | `Cookie: sess=TOPSECRET` | `Cookie: sess=TOPSECRET` (**not over-stripped**) | sent |
| E `Cookie:` item, same-origin `302 /start → /landing` | sent | none | none |
| F hostile — cookie for `127.0.0.1`, `302` to `127.0.0.10` | `Cookie: sess=TOPSECRET` (**leak**) | none | — |

Commands (post-fix binary; the session file is the `cap-cookie.json` shape, written under
`$HTTPIE_CONFIG_DIR/sessions/127.0.0.1_<P1>/probe.json`):

```sh
# A
build/oj --follow --all -p Hh GET http://127.0.0.1:19102/start 'Cookie:sess=TOPSECRET'
# B / F / D: 302 to 127.0.0.2:19101 / 127.0.0.10:19101 / 127.0.0.1:19501
build/oj --follow --all -p Hh --session=probe GET http://127.0.0.1:19102/start
# C: dual listener (peeks the first byte, 0x16 => TLS) on 127.0.0.1:19105
build/oj --follow --all --verify=no -p Hh --session=probe GET https://127.0.0.1:19105/start
```

The printed head agrees with the wire in every case: post-fix stdout carries exactly **one**
`Cookie:` line (hop 1) for A/B/C/E/F and **two** for D, where the jar legitimately supplies
one for each hop; pre-fix it carried two everywhere. Pre-fix evidence is the same probe run
against a binary built from `0f3cf5d`.

*Proof the in-suite tests bite.* On the branch with `hop.redirect_target` forced to `false`
(the single line the fix turns on, `curl_transport.odin:1764`), and nothing else changed:

```sh
odin test tests -collection:src=src -o:speed -vet -warnings-as-errors \
  -extra-linker-flags:"-lcurl" \
  -define:ODIN_TEST_NAMES=tests.test_engine_rebuilds_the_cookie_header_on_a_redirect,tests.test_session_renders_no_cookie_on_a_cross_host_hop,tests.test_session_cookie_value_respects_domain_path_and_secure
# Finished 3 tests ... 2 tests failed.
#   a cross-host hop must not carry the first URL's Cookie
#   the cross-host hop must not carry the jar's Cookie
#   the jar refused this host: no Cookie line may go out
#   a same-host hop must carry the jar's Cookie, got "item=1"
#   the jar's path rule rejected the hop: no Cookie line may go out
```

### V.4 SF-002 — `should_strip_authorization` matches `requests` (medium)

Three independent measurements, none of them the branch's own test:

1. **The nine pinned rows**, by executing the real proc through a probe package that lives
   outside the repo and is built against either `src` tree (`-collection:src=<tree>/src`):
   pre-fix **4 rows diverge** (`http://h/a→https://h/b`, `http://h:80/a→https://h:443/b`,
   `http://h:443/a→https://h:443/b`, `http://h:8080/a→https://h:8080/b`), post-fix **9/9
   match** `requests.Session().should_strip_auth`.
2. **A 32×32 URL matrix** (hosts `h`, `H`, `h2`, `127.0.0.1` × the two schemes × ports
   absent / `:80` / `:443` / `:8080` × path `/a` = 32 URLs, 1024 ordered pairs): pre-fix **54 mismatches** with
   the reference, post-fix **0**.
3. **Wire**, one dual-protocol port so a same-host/same-port scheme change is reachable
   without root: `--auth user:pass`, `http://127.0.0.1:P/start` → `302 https://127.0.0.1:P/secure`
   → pre-fix hop 2 carried `Authorization: Basic dXNlcjpwYXNz` (**fail-open**), post-fix
   carries none, and `requests` on the same server carries none. Control: a plain same-origin
   `302 /start → /next` keeps `Authorization` on hop 2 (no over-stripping).

*Proof the in-suite test bites:* with the pre-fix body restored verbatim on the branch, the
table fails on exactly the four rows above (`got strip=true, want false` ×2,
`got strip=false, want true` ×2) and the engine test passes either way — which is the
coder's documented inaccuracy #2, independently confirmed.

### V.5 SF-003 — `--ciphers` is applied (medium)

Independent of the suite (which cannot speak TLS): a local TLS listener on
`127.0.0.1:19200` with a self-signed cert, and the client's exit code — exactly the scripted
half §SF-003 prescribes:

| command | pre-fix | post-fix |
| --- | --- | --- |
| `build/oj --verify=no GET https://127.0.0.1:19200/` (control) | exit 0, body `ok` | exit 0, body `ok` |
| `build/oj --verify=no --ciphers=NOT-A-REAL-CIPHER GET …` | **exit 0, body `ok`** (option ignored) | **exit 1**, `oj: error: TLS handshake failed …` |
| `build/oj --verify=no --ciphers=ECDHE+AESGCM GET …` | exit 0 | exit 0 (a usable TLS 1.2 list still connects) |
| `build/oj --verify=no --ciphers=TLS_AES_128_GCM_SHA256 GET …` | exit 0 | exit 1 (documented: `SSL_CTX_set_cipher_list` grammar, same as urllib3 `set_ciphers`) |
| `build/oj GET https://127.0.0.1:19200/` (verify default) | exit 1 TLS failure | exit 1 TLS failure (SEC-02 control intact) |

The listener's own log shows the bogus-cipher run aborting inside the handshake
(`UNEXPECTED_EOF_WHILE_READING`) and the control completing on `TLSv1.3`. Regression checks:
a bogus list on a **plain-http** URL still exits 0 with the body, and an empty `--ciphers=`
on a TLS URL exits 0 — the option only constrains TLS cipher selection.

### V.6 SF-004 — session file `0600` (hardening)

CLI runs against a loopback sink with `--session=probe` (`$HTTPIE_CONFIG_DIR` in a scratch
dir); modes read with `os.stat`:

| | pre-fix | post-fix |
| --- | --- | --- |
| fresh file | `0644` | **`0600`** |
| pre-existing `0644` file, saved again | `0644` (unchanged) | **`0600`** (tightened) |
| directories `sessions/…` | `0700` | `0700` (unchanged) |
| file written with `--auth alice:s3cr3t` | `0644`, contains the plaintext credential | `0600`, contents otherwise unchanged |

*Proof the tightening test bites:* with the `os.chmod` line commented out, only
`test_session_save_tightens_an_existing_0644_file` fails
(`a 0644 session file must be tightened on save, mode is Permissions{Read_Other, Read_Group, Write_User, Read_User}`);
`test_session_cap1_file_matches_the_reference_capture` still passes, because creation is
covered by the constant and the *tightening* of an existing file is covered by the chmod —
i.e. both halves of SF-004 are load-bearing.

The only pre-existing test assertion the branch changes is the mode expectation itself
(`0644` → `0600`, §9.7 item 4). That is the item's purpose; it is recorded here as a
deliberate divergence, not a weakened test.

### V.7 SF-005 — the two unguarded constants are guarded (hardening)

With `CURLOPT_READFUNCTION` set to `20013` on the branch:

```
[ERROR] [libcurl_test.odin:18:check_option()] READFUNCTION: libcurl says 20012, src/http/libcurl.odin says 20013
Finished 173 tests ... 5 tests failed.
```

(the guard fails first; four engine tests that upload a chunked body fail too, because the
wrong number breaks the read callback — the constant is load-bearing, not decorative). With
the value set to `20011` — the neighbouring `WRITEFUNCTION` number — the suite aborts with a
glibc stdio error, one more sign the number reaches libcurl. SF-003's `SSL_CIPHER_LIST` row
is in the same table and is exercised by V.5.

### V.8 Why the card's step 2 ("checkout the base commit and run the new test") is done by neutralisation

Running the branch's `tests/` against the base `src/` **does not compile**, so it cannot
produce red/green evidence for the new tests:

```sh
git checkout 0f3cf5d -- src/            # in a scratch worktree that has the branch's tests/
make test-unit
# tests/libcurl_test.odin(63:37) Error: 'CURLOPT_SSL_CIPHER_LIST' is not declared by 'http'
# tests/session_store_test.odin(587:12) Error: 'session_cookie_value' is not declared by 'session'
# tests/http_engine_test.odin(2300:8) Error: 'Cookie_Hook' is not declared by 'http'
# … 'Request' has no field 'cookie_hook' …
```

The new tests are written against the new API, which is the point. The equivalent red
evidence was therefore taken the other way round — the branch with exactly one fix
neutralised (V.3/V.4/V.6/V.7) — which keeps every other variable out of the measurement and
is what the coder's "measured red with its fix neutralised" claims reproduce here.

### V.9 Gates and tooling on the branch (`570a405`)

```sh
make check      # exit 0 — `odin check src` and `odin check tests`, -vet -warnings-as-errors, zero warnings
make build      # exit 0
make test-unit  # exit 0 — "colorize goldens: 421 cases, 0 mismatches"
                #           "Finished 173 tests in 1.022078326s. All tests were successful."
```

* **Test inventory:** `grep -ro '@(test)' tests | wc -l` → **173** on the branch vs **167** at
  `0f3cf5d`; six tests added, **none removed**:
  `test_engine_rebuilds_the_cookie_header_on_a_redirect`,
  `test_session_cookie_value_respects_domain_path_and_secure`,
  `test_session_renders_no_cookie_on_a_cross_host_hop`,
  `test_should_strip_authorization_matches_requests`,
  `test_engine_keeps_and_strips_authorization_across_a_redirect`,
  `test_session_save_tightens_an_existing_0644_file`.
* **Dependency audit:** there is no dependency manifest to audit (no `requirements.txt`,
  `Cargo.toml`, `go.mod`, `package.json`, `pyproject.toml`, `Gemfile`, `vcpkg.json`,
  `conanfile.txt`). The branch changes no build file and adds no dependency: `ldd build/oj`
  lists only the system libraries it already used (`libcurl.so.4` 8.5.0-2ubuntu10.13,
  `libssl`/`libcrypto` 3.0.13, `libnghttp2`, `libidn2`, `libpsl`, `libssh`, `librtmp`,
  `libzstd`, `libbrotlidec`, `libz`, `libm`, `libc`).
* **Static analysis:** `make check` (Odin `-vet -warnings-as-errors`) is the project's SAST
  gate and is green with zero warnings on `src` and `tests`. No other linter/SAST tool is
  configured in the tree (`grep -rniE 'lint|sast|audit|scan|valgrind' README.md Makefile
  docs/ARCHITECTURE.md` → one prose hit).
* **Secret scan:** `git diff 0f3cf5d..570a405 | grep -E '^\+.*(BEGIN .*PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-)'`
  → no hits. The only credential-shaped strings the branch adds are sample values in prose
  and tests (`alice:s3cr3t`, `TOPSECRET`, `SECUREJARSECRET`), none of them real.
* **Memory-safety spot check (extra, not required by the plan):** `valgrind` on the SF-001
  path (followed redirect with a session jar), symbol-bearing debug builds of both trees:
  **no invalid reads/writes and no use-after-free in either binary**; both report the same
  two contexts, both inside the Odin runtime's heap allocator
  (`runtime::conditional_mem_zero` ← `heap_allocator_proc` ← `strings::write_string` ←
  `cli::pure_path_join`), with 168 errors pre-fix vs 170 post-fix. That is a known benign
  pattern of the runtime's own allocator bookkeeping, present identically before and after
  the change; it is recorded as a coverage note (V.11), not as a fix-blocking finding.

### V.10 Diff review for regressions

Reviewed `git diff 0f3cf5d..570a405` (13 files: `docs/security-findings.md` added, 8 `src`
files, 4 test files — exactly the §9.6 in-scope list; no build file, no golden, no
`tests/fixtures`):

| check | result |
| --- | --- |
| new `eval`/`exec`/shell-out | none — `grep -rnE '\beval\b|os.process|/bin/sh|system\(' src` → no hits (Odin has no `eval`) |
| `CURLOPT_VERBOSE` introduced | no — still only the constant (`libcurl.odin:89`) and its constant-table row; nothing in `src` sets it (SEC-04 preserved) |
| TLS verification weakened | no — `CURLOPT_SSL_VERIFYPEER (req.verify?1:0)` / `VERIFYHOST (req.verify?2:0)` / `CAINFO` lines are untouched by the diff, and the self-signed probe is still refused without `--verify=no` |
| `Secure`-cookie handling dropped | no — `cookie_applies` is untouched; the fix routes *more* traffic through it (V.3 case C) |
| validation removed / checks weakened | no — the only deleted test lines are the deliberate `0644`→`0600` expectation, a test-helper refactor (`engine_server_start_on`), and comments; no test proc removed (167→173) |
| secrets committed | no (V.9) |
| debug logging of sensitive data | no new `fmt.print*` of cookie/auth values in `src`; the rendered hop head now *drops* the `Cookie` line the wire no longer carries (V.3) |
| ownership/aliasing | the new `Request.cookie_hook` is borrowed (zero value = no session) and released by nobody, as documented in `types.odin`; the re-derived string is freed by the caller path in both `apply_hop` and `write_hop_request`; `Options.ciphers` is borrowed from `cli.Options` and freed in `options_destroy` |

### V.11 Coverage limits (stated, not hidden)

* **No in-suite TLS capability.** The pinned toolchain's `core/crypto` has no `tls` package
  (§9.1), so SF-003's behavioural half and the `https` rows of SF-002 can only be measured by
  the scripted probes above; `build/` is git-ignored, so no TLS test is committable. This is
  the same limitation the plan records — it is a limit of the branch, not of this
  verification.
* **Probe scripts live outside the tree** (QA scratch dir), by the same §9 rule that keeps the
  tree free of a parity harness. Everything needed to rebuild them is in V.3–V.5 (listener
  roles, exact commands, expected exit codes); the pre-fix comparison binary is a plain
  `make build` of `0f3cf5d`.
* **Not re-verified here (unchanged by the branch, out of scope):** `SF-D1`–`SF-D3` (still
  deferred), `DOC-01`–`DOC-08`, the 8 `*_generated.odin` files, `src/http/url.odin` /
  `idna_generated.odin` parser-differential review, `src/http/proxy.odin`, netrc permission
  enforcement — the same list §8 and §9.5 leave open. The branch touches none of them.
* **Valgrind noise** (V.9) is confined to the Odin runtime allocator on both sides; no
  allocation *leak* assertion in the suite regressed — the branch runs **116** leak
  assertions (`85` `expect_no_leaks` + `31` `engine_no_leaks`; the base has 109) and all of
  them pass inside the 173-test run.

### V.12 Final verdict

**READY FOR PR.** Every in-scope finding (`SF-001`–`SF-005`) has an explicit PASS backed by a
reproducible command or probe; every in-suite test that carries a fix was measured red on the
pre-fix code; the full suite and the project's static gate are green on the pushed SHA; the
diff introduces no new `eval`/`exec`, no disabled TLS check, no re-enabled credential replay,
no secret, and no weakened test. Nothing was fixed by QA — the branch is unchanged by this
verification except this section.

READY FOR PR
