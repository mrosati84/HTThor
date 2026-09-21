# Chapter 2 — Project Sanity & Fidelity — Rating: 6.6/10 (C)

**Project:** HTThor — an Odin port of HTTPie, `/home/matteo/Projects/htthor`
**Commit reviewed:** `730a497e9e20054b00de2f1c21a54d0c9f567960` ("rebrand oj -> htthor"), 24 commits, one author
**Date reviewed:** 2026-09-21 · **Environment:** Arch Linux, `odin version dev-2026-09:a2fb372b7`; `make build`, `make check`, `make test` run from a clean checkout
**Reference:** HTTPie **3.2.4** — the version HTThor targets and the version the docs site serves ("HTTPie 3.2.4 (latest) docs", dated 2024-11-01), so there is no version drift in this review.

Scope: project sanity only; code style and security depth belong to chapters 1 and 3.

## Sub-scores

| Sub-score | Score | Basis |
| --- | --- | --- |
| Claim accuracy | 8.5/10 | Self-reported limitations verified true; both README examples byte-identical; four accepted no-op flags undisclosed |
| HTTPie feature fidelity | 7.0/10 | Option table matches upstream `definition.py`@3.2.4 completely; 4 flags parsed-and-ignored; no password prompt; no auth plugins |
| Project hygiene | 4.5/10 | No LICENSE on a BSD-3-Clause derivative; 167 refs to a deleted `docs/PARITY.md`; no CI |
| Build / installability | 8.5/10 | All three documented targets pass; requirements accurate; no CI, so cross-machine reproducibility unverified |
| Maturity | 4.5/10 | 24 commits over ~2 days, no tags, no CHANGELOG, `--version` prints upstream's number, 0 issues |

**Rating = flat mean (33.0 / 5) = 6.6 → C.** Claim accuracy and buildability carry the score; hygiene and maturity drag it down, and the missing licence is a blocker rather than a cosmetic defect.

## Feature matrix

Each row is checked against HTTPie 3.2.4 docs **and** HTThor source. "ran" = executed here.

| Feature | HTTPie 3.2.4 | HTThor | Evidence |
| --- | --- | --- | --- |
| Request items `key=value`, `key:=raw`, `key==query`, `Header:value`, `@file`, `=@`, `:=@` | all documented | all implemented | docs `httpie.io/docs/cli/request-items`; `src/cli/items.odin`; ran offline probe → `{"n": "2", "raw": [1, 2], "b": true}` |
| Methods incl. custom verbs | any verb | any verb | `src/cli/options.odin:337`; ran `PROPFIND` |
| `--json`/`--form`/`--multipart`/`--boundary`/`--raw` | documented | implemented | `src/cli/parse.odin:298-303`; ran `--form`→`n=2`, `--raw hello`→`hello` |
| `--auth/-a`, `--auth-type/-A` basic/digest/bearer | documented | implemented | docs `httpie.io/docs/cli/authentication`; `src/http/auth.odin:30-41`, `src/http/digest.odin`; ran all three offline |
| Password prompt for `-a username` | prompts | **absent** — sends `username:` | same page; `src/http/auth.odin:46-47`; ran: Basic header emitted, no prompt |
| `.netrc`, `--ignore-netrc` | documented | implemented | `src/http/netrc.odin`; `src/cli/parse.odin:333` |
| Cookies, `--session`, `--session-read-only` | documented | implemented | docs `httpie.io/docs/cli/sessions`; `src/session/jar.odin`, `src/session/store.odin:201-270`; ran: file written at `$HTTPIE_CONFIG_DIR/sessions/127.0.0.1_8732/s1.json` |
| `-d`, `-o`, `--continue -c` resume | documented | implemented | docs `httpie.io/docs/cli/download-mode`; `src/session/context.odin:1817-1871` (Range), `:1899` (206); ran: full download byte-exact, truncated file + `-c` against a Range server → `206`, byte-exact |
| `--follow/-F`, `--max-redirects`, `--all` | documented | implemented | docs `httpie.io/docs/cli/http-redirects`; `src/http/curl_transport.odin:1254,1655`; `tests/http_engine_test.odin:1156,1216,2191` |
| `--proxy` + `$ALL_PROXY`/`$HTTP_PROXY`/`no_proxy` | documented | implemented | docs `httpie.io/docs/cli/proxies`; `src/http/proxy.odin:1-18`; `tests/http_engine_test.odin:1666` |
| `-p/-h/-b/-m/-v/-q/--meta` | documented | implemented | docs `httpie.io/docs/cli/output-options`; `src/cli/parse.odin:315-326`; ran `-q` → 0 bytes |
| Formatting, colourising (`--pretty`, `--style`, `--format-options`) | documented | implemented | docs `httpie.io/docs/cli/terminal-output`; `src/output/colorize.odin`, `src/cli/options.odin:284-293`; ran `--pretty=colors --style=native` → ANSI; 421 goldens, 0 mismatches |
| `--offline` | documented | implemented | docs `httpie.io/docs/cli/offline-mode`; `src/session/context.odin:189`; ran |
| `--verbose` | documented | implemented | `src/cli/parse.odin:2812-2825`; ran |
| `--chunked`, `--compress`, `--max-headers`, `--path-as-is`, `--timeout`, `--verify`, `--ciphers`, `--cert*` | documented | implemented | `src/session/context.odin:941,943,945`; `src/http/curl_transport.odin:1404` (path-as-is), `1379` (timeout), `1409-1426` (verify), `1439` (ciphers), `1448/1457/1468` (cert) |
| **Streaming `--stream/-S`** | line-streams the body; "Disabling buffering" | **accepted, ignored** | docs `httpie.io/docs/cli/streamed-responses`; parsed `src/cli/parse.odin:322,1441`, stored `src/cli/options.odin:393`, never read (tree-wide audit) |
| **`--ssl`** | sets protocol version | **accepted, ignored** | `definition.py`@3.2.4; `src/cli/parse.odin:346,1493` — validated, never copied to `Options` (no such field); no `CURLOPT_SSLVERSION` anywhere |
| **`--history-print/-P`** | hidden but functional | **accepted, ignored** | `definition.py`@3.2.4:496-502; `src/cli/options.odin:381-382`, `src/cli/parse.odin:2998-3000` — no reader |
| **`--debug`, `--traceback`** | diagnostics / tracebacks | **accepted, ignored** | `definition.py`@3.2.4:928-949; `src/cli/options.odin:413-414` — no reader outside the parser |
| Auth plugins as `--auth-type` | supported | **unverified** — basic/bearer/digest only | docs authentication ("any auth plugins you have installed"); `src/cli/parse.odin:332` |

## What is sound

- **The option table is a real, complete port.** `OPTION_SPECS` (`src/cli/parse.odin:296-358`) reproduces every `add_argument` in upstream `httpie/cli/definition.py`@3.2.4, including the suppressed `--no-unsorted`/`--no-sorted` aliases and `-P`. No upstream flag is missing; none is invented.
- **The documented build works.** `make check` 2.3 s, `make build` links `-lcurl`, `make test` → `Finished 176 tests ... All tests were successful` and `colorize goldens: 421 cases, 0 mismatches` — exactly README:47. Both README examples are byte-identical to real output (md5 matched, CRLF included).
- **The binary does real work.** A live TLS request to `https://example.com` returned a full header block; download and resume were exercised end-to-end against local servers.
- **Dependency footprint is small and honest.** Exactly one `foreign import` in the tree (`src/http/libcurl.odin:22`), no vendored libraries, no Python; `ldd` shows `libcurl.so.4` and its own transitive deps.
- **The README is candid and I could not falsify it.** Its limitations (README:147-155) self-report the missing LICENSE, the missing CI, the unread `REQUESTS_CA_BUNDLE` (confirmed: it appears only in the recorded help text, `src/cli/help_text_generated.odin:368,791`) and the session-path divergence. That last claim is right in an interesting way: upstream 3.2.4 `sessions.py` writes `sessions/<host>_<port>/<name>.json`, so HTThor follows the *code* while the recorded help repeats upstream's own stale docstring.

## Findings (severity-ranked)

1. **HIGH — No licence on a derivative work.** No `LICENSE`/`COPYING` exists (README:150 admits it; GitHub reports `licenseInfo: null`), yet the sources derive from HTTPie, whose LICENSE is BSD-3-Clause (`https://github.com/httpie/cli/blob/master/LICENSE`, "Copyright © 2012-2022 Jakub Roztocil") — conditions 1–2 require retaining the notice and disclaimer. `grep -ri "copyright\|BSD"` over `src/` finds no attribution.
2. **HIGH — The specification the port is measured against has been deleted.** `src/` holds **167 references to `docs/PARITY.md` across 30 files** and **19 to `docs/ARCHITECTURE.md`**; `docs/` does not exist (removed in `9aa787b`). The Makefile's first line still points readers at `docs/ARCHITECTURE.md`, and error-wording/exit-code decisions cite PARITY.md as their authority (`src/cli/options.odin:9-17`).
3. **HIGH — `--stream/-S` is a no-op that `--help` advertises.** Parsed (`src/cli/parse.odin:322,1441`), stored (`src/cli/options.odin:393`), never read by any package (tree-wide field audit). The help text it reproduces promises "Always stream the response body by line, i.e., behave like `tail -f`" — the documented feature does not exist.
4. **MEDIUM — `--ssl` is validated and discarded.** `src/cli/parse.odin:346,1493` accepts and range-checks the value; `Options` has no `ssl_version` field and no `CURLOPT_SSLVERSION` appears in `src/http/curl_transport.odin`. The flag cannot change the negotiated protocol version.
5. **MEDIUM — Three more accepted-and-ignored flags, undisclosed.** `--history-print/-P`, `--debug` and `--traceback` have no reader outside the parser (`src/cli/options.odin:381-382,413-414`). With findings 3–4, four flags in the port's own `--help` do nothing; only the CA-bundle gap is disclosed in README's limitations.
6. **MEDIUM — No interactive password prompt.** `--auth user` is documented as prompting (`httpie.io/docs/cli/authentication`); HTThor silently sends `user:` (`src/http/auth.odin:46-47`, verified: Basic header emitted, no prompt). The justifying comment points at the deleted `docs/ARCHITECTURE.md`.
7. **MEDIUM — No release identity.** No tags, no CHANGELOG, one author, 24 commits over two days. `--version` prints `3.2.4` — the *upstream* number — so a binary cannot be identified as any HTThor revision.
8. **LOW — No CI.** No `.github/` (README:151), so the passing suite is unverified on any machine but this one.
9. **LOW — Dead advice and scratch files.** Legacy-session warnings tell users to run `httpie cli sessions upgrade[-all]` (`src/session/store.odin:523-567`), but no subcommand dispatch exists: `htthor cli sessions list` is parsed as a request item and exits 1. Untracked `tmp/`, `.capture-sandbox/` and `.opencode/node_modules/` sit in the working directory (all git-ignored).

## Recommendations (by impact)

1. Add a `LICENSE` (BSD-3-Clause plus the upstream copyright notice) and an attribution line in the README — the only finding with legal consequence.
2. Restore `docs/PARITY.md` and `docs/ARCHITECTURE.md`, or rewrite the 186 references to point at what replaced them. The code's provenance trail is currently broken.
3. Implement the dead flags or remove them and say so. `--stream` first: buffering a long-lived response is a real behavioural difference, and silently ignoring a documented flag is worse than rejecting it.
4. Extend README's "Status and limitations" with the `--ssl`, `--history-print`, `--debug`/`--traceback` and password-prompt gaps. The README's honesty is its strongest asset; these omissions undercut it.
5. Add CI running `make check`, `make build` and `make test` on a pinned Odin version, and tag a first release whose `--version` also prints the HTThor revision.

## Open questions

- Whether the recorded `--help`/`--manual` bytes equal a real HTTPie 3.2.4's output is **unverified**: no `httpie`/`http` binary or Python package is installed here, and upstream's help varies with installed Pygments styles. README:5 is therefore *reported, plausible, not independently diffed*.
- Proxy, redirect and cookie behaviour is **unverified at the wire level**: I confirmed the code paths and the unit tests that pin them, but never ran a reference HTTPie side by side.
- `--auth-type` with a third-party plugin cannot be exercised at all — HTThor has no plugin system — so that row is marked unverified rather than failed.
