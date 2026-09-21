# HTThor — Comprehensive Rating

**Reviewed revision:** `730a497e9e20054b00de2f1c21a54d0c9f567960` ("rebrand oj -> htthor"), tree
`/home/matteo/Projects/htthor`, reviewed 2026-09-21. All three chapters below review that same
commit, and every citation in this document is relative to the repository root at that revision.
The chapters were produced and verified independently (code quality, project sanity & fidelity,
security); this assembly merges them without adding findings.

**Reference:** HTTPie 3.2.4 — the version HTThor targets and the version the documentation site
serves (so this review carries no upstream version drift).

**Rating scale (identical in all three chapters):** 0–10 with one decimal. 9.0–10 A, 8.0–8.9 B+,
7.0–7.9 B, 6.0–6.9 C, 5.0–5.9 D, below 5.0 F.

## Overall Rating: 7.1/10 (B)

**Verdict:** a genuine, working, well-tested HTTPie port with real engineering discipline, held
below a shipping grade by broken provenance, a missing licence, and help text that advertises four
flags the binary ignores — with no Critical or High security defect anywhere in the review.

**Justification.** The score is carried by three things and capped by three others. Carried: the
port *works and is verified* — `make check`, `make build` and `make test` pass on the reviewed
commit (176 tests, 421/421 colour goldens), both README examples are byte-identical to real output,
a live TLS request and an end-to-end download with `--continue` resume were exercised, and the
option table reproduces every `add_argument` in upstream `httpie/cli/definition.py`@3.2.4; the
*engineering discipline is real* — allocator threading is asserted by tests rather than documented,
errors are values (zero `panic(`/`assert(` in `src/`), and TLS verification is on by default and
fail-closed, measured against a self-signed listener; and *most security-relevant defaults hold* —
header injection is refused twice, redirect credential handling matches `requests`, and downloads
take no filename from the server. Capped: the artifact cannot be maintained as it stands — the
eight generated tables (31,882 lines, ~50% of `src/`) name generators that are absent from the
tree, 250+ in-code citations point at a `docs/` tree deleted in `9aa787b`, there is no `LICENSE`
on a BSD-3-Clause derivative, and four flags in the port's own `--help` (`--stream`, `--ssl`,
`--history-print`, `--debug`/`--traceback`) are parsed and then silently ignored. Security
contributes no Critical or High finding — it is weighted heaviest precisely so that it *would*
dominate if it had — and its three Medium findings (terminal escape-sequence injection, unbounded
reply buffering with `--download` never streaming, and a `--ssl` no-op that leaves no TLS-version
floor) are real but bounded. The result sits at the bottom of the B band: a good implementation
that cannot yet be regenerated, attributed, or trusted to do what its help text promises.

**Weighting used:** security 40%, project sanity & fidelity 30%, code quality 30% — security is
deliberately the heaviest single lens, and a Critical finding there would have capped the overall
score outright. Chapters' own scores feed in unchanged.

| Lens | Weight | Chapter rating | Weighted |
| --- | --- | --- | --- |
| Chapter 1 — Code Quality | 30% | 7.5/10 (B) | 2.25 |
| Chapter 2 — Project Sanity & Fidelity | 30% | 6.6/10 (C) | 1.98 |
| Chapter 3 — Security | 40% | 7.3/10 (B) | 2.92 |
| **Weighted mean** | 100% | — | **7.15** |
| **Overall (after judgement adjustment, see below)** | | | **7.1/10 (B)** |

**From the weighted mean to the number.** The arithmetic gives 7.15; the reported overall is 7.1,
a −0.1 judgement adjustment, for one stated reason: security returned no Critical or High finding
(chapter 3's own verdict: "issues found — no Critical or High"), so the 40% security weight acts
here as a stabiliser rather than the cap it was designed to be. The High-severity findings that do
exist sit in the 30% project-sanity bucket — a missing licence on a derivative work and the
deletion of the port's only specification — and their consequences (legal exposure, and the loss of
the document every "why is it this way" comment defers to) are binary rather than proportional to a
30% weight. Carrying that as a rounding-level deduction, instead of a larger arbitrary one, keeps
the overall at the bottom of the B band rather than mid-B, and keeps the number recomputable from
the table above. Had chapter 3 found a Critical, the overall would have been capped well below this.

## Top Findings

Deduplicated across the three chapters and ranked by severity and impact. Where chapters rate the
same defect differently, both ratings are shown and the disagreement is explained in *Assembly
notes* at the end of this document. No finding here is new: each is a chapter finding, cited to the
chapter that owns it.

1. **High — No `LICENSE`/`COPYING` on a BSD-3-Clause derivative.** *ch2 finding 1 (High); ch1 F10
   (Low) — rated differently, see Assembly notes.* `README.md:150` admits the gap; the sources
   derive from HTTPie, whose licence is BSD-3-Clause (`https://github.com/httpie/cli/blob/master/LICENSE`),
   and `grep -ri "copyright\|BSD"` over `src/` finds no attribution.
   *Fix:* add the upstream BSD-3-Clause text plus an attribution line in the README.

2. **High — 250+ in-code citations point at a `docs/` tree that no longer exists.** *ch1 F2 (High);
   ch2 finding 2 (High) — the two chapters count the citations differently, see Assembly notes.*
   `docs/PARITY.md` and `docs/ARCHITECTURE.md` are cited throughout, `docs/` was removed in
   `9aa787b`, and the trail still leads there: `Makefile:1`, `src/cli/options.odin:9-17`,
   `src/http/backend.odin:7`, `src/http/owned.odin:4`, `.gitignore:12-14`.
   *Fix:* restore `docs/PARITY.md` and `docs/ARCHITECTURE.md`, or replace the citations with a
   checked-in `docs/PROVENANCE.md`; at minimum repair `Makefile:1`.

3. **High — The eight generated tables cannot be regenerated.** *ch1 F1 (High).* The files name
   their generators — `build/gen_*.py`, `tools/gen-help-text.py`, `tools/ref-capture/gen_styles.py`
   (`src/http/detect_generated.odin:1-2`, `src/http/charset_generated.odin:1`,
   `src/http/idna_generated.odin:1`, `src/http/unicode_printable_generated.odin:1`,
   `src/rich/emoji_generated.odin:1`, `src/cli/python_digits_generated.odin:1`,
   `src/cli/help_text_generated.odin:1-2`, `src/output/styles_generated.odin:9`) — but no `*.py`
   exists in the tree, and two headers bake in `/home/matteo/htthor/.venv-ref/bin/python`
   (`src/http/charset_generated.odin:14`, `src/http/detect_generated.odin:12`).
   *Fix:* check the generators back in under `tools/`, pin the reference versions in the headers,
   and drop the absolute interpreter path.

4. **High — Flags the port's own `--help` advertises do nothing.** *ch2 findings 3 (High) and 5
   (Medium).* `--stream/-S` is parsed (`src/cli/parse.odin:322`, `:1441`), stored
   (`src/cli/options.odin:393`) and never read, yet the help text promises `tail -f`-style
   line-streaming; `--history-print/-P` (`src/cli/options.odin:381-382`) and `--debug`/`--traceback`
   (`src/cli/options.odin:413-414`) have no reader outside the parser either.
   *Fix:* implement the flags — `--stream` first, since buffering changes behaviour — or reject
   them and remove them from the help text.

5. **Medium — `--ssl` is validated and then discarded; no TLS-version floor.** *ch2 finding 4
   (Medium); ch3 F-01 (Medium).* The value is range-checked (`src/cli/parse.odin:346`, `:1493`,
   `:640`; `src/cli/usage.odin:264`, `:299`) but never reaches `Options`
   (`src/cli/options.odin:359-371`) and no `CURLOPT_SSLVERSION` exists
   (`src/http/curl_transport.odin:1409-1416`); measured: `--ssl=tls1` against a TLS1.2+-only
   listener succeeded, while the applied control `--ciphers=NOT-A-REAL-CIPHER` failed the handshake.
   *Fix:* map the choices onto `CURLOPT_SSLVERSION` as minimum versions, or reject the flag.

6. **Medium — Response bytes reach the terminal unfiltered (escape-sequence injection).** *ch3 F-02
   (Medium).* `write_raw_bytes` (`src/output/render.odin:1580`) writes the body verbatim
   (`src/session/context.odin:1974`) and header values are printed as received; OSC 52 and CSI
   sequences from a loopback server were reproduced byte-for-byte by the built binary.
   *Fix:* sanitise C0/ESC bytes by default on a tty (with an opt-out), at minimum dropping OSC/CSI
   in headers — a deliberate divergence from HTTPie rather than an inherited hazard.

7. **Medium — Reply bodies are buffered whole with no cap, and `--download` never streams.** *ch3
   F-03 (Medium).* `write_callback` buffers into `transfer.body` when `sink == nil`
   (`src/http/curl_transport.odin:538-551`), the session calls `http.send` with no sink
   (`src/session/context.odin:215`, `src/http/backend.odin:25`), the streaming path is reachable
   only from tests, and `download_response` writes the whole body at once ignoring a short write
   (`src/session/context.odin:1968`) — while two header comments claim the opposite
   (`src/http/curl_transport.odin:7`, `:10-11`).
   *Fix:* thread the open file through `send_to` on the download path, cap the buffer, check
   `written == len(body)`, fix the comments, and cover the CLI path in a test.

8. **Medium — No password prompt for `-a user`, and credentials are argv-only once more.** *ch2
   finding 6 (Medium); ch3 F-06 (Low) — rated differently, see Assembly notes.*
   `src/http/auth.odin:45-47` sends `user:` rather than prompting where HTTPie prompts;
   `--auth user:pass` and `--cert-key-pass` stay in `/proc/<pid>/cmdline` and shell history, and
   `raw_auth` is plaintext on disk with `chmod 0600` applied only on save
   (`src/session/store.odin:800-827`).
   *Fix:* prompt, or read the password from stdin/env; `chmod` session files on load too.

9. **Medium — 199 `or_else ""`/`or_else nil` sites turn out-of-memory into a valid empty value.**
   *ch1 F4 (Medium).* `src/cli/items.odin:442`, `:477-480`, `:512-513` and ~190 more, plus
   `src/session/jar.odin:265`, `:425`, discard `mem.Allocator_Error`; `""` is a legitimate HTTP
   value, so a failed clone yields a wrong request instead of a reported failure.
   *Fix:* one `clone_or_oom` helper returning `(string, bool)` in the house style of
   `src/http/owned.odin:26-38`, and propagate where the caller can report.

10. **Medium — 183 lines of dead code that `-vet` cannot see.** *ch1 F6 (Medium).* Superseded or
    unreferenced procs in `src/cli/usage.odin:290-315`, `:511-531`, `src/cli/options.odin:495-503`,
    `src/output/print.odin:47-59`, `:63-71`, `:74-87`, `src/http/detect_md.odin:61-63`,
    `:639-658` and `src/session/jar.odin:586-655`, plus three unused libcurl bindings
    (`src/http/libcurl.odin:165`, `:166`, `:171`).
    *Fix:* delete them, or annotate the pending ones; `-vet` checks variables and imports, not procs,
    so this stays green.

Also material, below the cut of ten: no release identity (ch2 finding 7 — no tags, no CHANGELOG,
`--version` prints upstream's `3.2.4`) and no CI (ch2 finding 8; ch1 F10), three implicit-allocator
call sites (ch1 F3 — `src/output/colorize.odin:917`, `:919`, `:947`), five procs over 300 lines
(ch1 F5), duplicated helpers across leaf packages (ch1 F8), the unreachable scaffold help branch
(ch1 F7), dead `httpie cli sessions upgrade` advice (ch2 finding 9), `HTTP_PROXY` honoured without
the reference's httpoxy guard (ch3 F-04, Low), and the advertised-but-unread `REQUESTS_CA_BUNDLE`
(ch3 F-05, Low).

## Chapter 1 — Code Quality: 7.5/10 (B)

Reviewed revision: `730a497e9e20054b00de2f1c21a54d0c9f567960` ("rebrand oj -> htthor"),
2026-09-21. Working tree clean at review time; all paths below are relative to the
repository root at that commit. Where I ran something, I say so; where a judgement is
stylistic, I mark it so.

### Sub-scores

| Sub-score | Value | Anchor |
| --- | --- | --- |
| Idioms | 7.5 | 361/364 allocation sites thread an explicit allocator; 199 silent `or_else ""` |
| Structure | 7.0 | acyclic package graph, but 8 god-files, 10 procs >200 lines, 50% generated lines |
| Readability | 7.5 | 29% comment lines, zero TODOs, but 253 citations to deleted docs and 183 dead lines |
| Test coverage | 8.0 | 176 tests / 11,696 lines pass; `main` and the built binary untested |
| Build hygiene | 7.5 | `-vet -warnings-as-errors` everywhere, 2.6 s check gate; no CI, no formatter, no table regeneration |

Mean of the five sub-scores is 37.5/5 = **7.5** → grade **B**. The score is capped by
structure and by two provenance findings, not by correctness.

### What is sound

I built and ran the tree rather than reading it: `make check` (src + tests, `-vet
-warnings-as-errors`) is clean in 2.6 s, and `make test` reports `Finished 176 tests
... All tests were successful.` plus `colorize goldens: 421 cases, 0 mismatches` in 44 s.

- **Allocator discipline is real, and enforced.** `context.allocator` is read once, at
  `src/main.odin:18`, exactly as `README.md:141` claims. Of 364 allocation sites in
  `src/` (200 `strings.clone`, 66 `fmt.aprintf`, 98 `make(`), all but three pass an
  explicit allocator; there is no `new(`, no `free(`, and `src/http/owned.odin:1-8`
  documents why `append` on a bare slice is banned. `tests/helpers.odin:54-69` asserts a
  zero balance and a clean `bad_free_array` at the end of every allocating test, so the
  rule is a test, not a comment.
- **Failure is explicit.** Zero `panic(`/`assert(`/`unimplemented` in `src/`; errors are
  returned as enums (`src/http/types.odin:496`, `error_message` at `:537`) or as
  `(value, bool)`. `or_return` appears 40 times, `defer` 255 times. `os.exit` occurs in
  `src/main.odin` only (`:71`, `:93`, `:121`, `:128`, `:170`, `:178`, `:187`), and
  `foreign import` only at `src/http/libcurl.odin:22`.
- **Concerns are separated.** The import headers confirm the graph the README draws:
  `main` → `cli, output, session`; `session` → `cli, format, http, output`; `cli` and
  `output` → `format, http, rich`; `format`, `http`, `rich` import nothing from `src`.
  The exchange (`src/http/`) cannot see the CLI or the renderer.
- **Comments carry the specification.** Non-generated `src/` is 29% comment lines
  (8,937/30,607) and `tests/` 19%; the comments name the reference file and line being
  ported and state ownership contracts (`src/format/xml.odin:45-48`). Two headers argue
  their stdlib rejection up front: `src/format/json.odin:3-21` (Python `json.dumps`
  bytes) and `src/http/md5.odin:1-15` (bypassing libcurl for non-rewindable uploads).
- **The test suite is not decorative.** 176 `@(test)` procs; goldens for 421 colour cases
  with 26 inputs; `tests/libcurl_test.odin` re-checks every libcurl option number against
  `curl_easy_option_by_name` at run time; `tests/http_engine_test.odin` asserts on bytes a
  loopback listener actually saw.

### Findings

**F1 — High — the generated tables cannot be regenerated, and their provenance is a
stranger's home directory.** `src/http/detect_generated.odin:1-2` names
`build/gen_detect_tables.py`; `src/http/idna_generated.odin:1`, `src/http/charset_generated.odin:1`,
`src/rich/emoji_generated.odin:1`, `src/cli/python_digits_generated.odin:1` and
`src/http/unicode_printable_generated.odin:1` do the same; `src/output/styles_generated.odin:9`
names `tools/ref-capture/gen_styles.py` and `src/cli/help_text_generated.odin:1-2` names
`tools/gen-help-text.py`. Neither `build/*.py`, nor `tools/`, nor `tests/parity/` exists in
the tree (`ls` fails; `find . -name '*.py'` returns nothing). Those eight files are 31,882
lines — 50% of `src/` (64,316) — and several headers bake in
`/home/matteo/htthor/.venv-ref/bin/python` (`src/http/charset_generated.odin:14`,
`src/http/detect_generated.odin:12`). Porting
or refreshing the Unicode/CPython/pygments data now means hand-editing hex tables. *Fix:*
check the generators back in under `tools/`, pin the reference versions in the headers, and
drop the absolute interpreter path.

**F2 — High — 253 citations point at documents that are not in the repository.**
`docs/PARITY.md` is cited 211 times, `docs/ARCHITECTURE.md` 22, with `docs/COLORIZE.md`,
`docs/security-findings.md`, `docs/cli/*`, `docs/parity-captures/*`, `build/gen_*.py` and
`tests/parity/*` making up the rest; `.gitignore:12-14` acknowledges "the removed parity
harness". `docs/` does not exist. The Makefile opens by sending the reader there
(`Makefile:1`), as do `src/http/backend.odin:7` and `src/http/owned.odin:4`. Every
"why is it this way" claim in this codebase is therefore unverifiable by a new maintainer,
and the byte-level goldens the port targets have no recorded home. *Fix:* restore `docs/`
or replace the citations with a checked-in `docs/PROVENANCE.md`; at minimum repair
`Makefile:1`.

**F3 — Medium — three allocation sites bypass the documented allocator rule.**
`src/output/colorize.odin:917`, `:919` and `:947` call `make(...)` with no allocator, so
`json_tokens` (`:916`) allocates from `context.allocator`; the matching `defer delete`
calls at `:918`, `:920`, `:948` do the same. `README.md:141` and `src/main.odin:10-13`
state the opposite, and every other call site in `src/` complies. The proc has no
allocator parameter to thread. *Fix:* add one — its callers `lex_json`
(`src/output/colorize.odin:251`) and `:1538` already receive `allocator`.

**F4 — Medium — 199 `or_else ""` sites turn out-of-memory into an empty value.**
`src/cli/items.odin:442`, `:477-480`, `:512-513` and 190 more
(`or_else nil` at `src/session/jar.odin:425`, `or_else ""` at `:265`) discard
`mem.Allocator_Error`. `""` is a legitimate HTTP value, so a failed clone yields a wrong
request rather than a reported failure, and `http.Error.Out_Of_Memory`
(`src/http/types.odin:547`) stays unreachable from these paths. The house style already
exists: `src/http/owned.odin:26-38` returns `bool` and lets the caller fail. *Fix:* one
`clone_or_oom` helper returning `(string, bool)`, or propagate where the caller can report.

**F5 — Medium — five procs carry entire state machines.** `detect_matches`
(`src/http/detect.odin:130-669`, 540 lines), `transport_send`
(`src/http/curl_transport.odin:1258-1771`, 514), `apply_hop` (`:723-1180`, 458),
`build_request` (`src/session/context.odin:599-1053`, 455) and `apply_action`
(`src/cli/parse.odin:1228-1534`, 307). Across 872 procs the median is 13 lines and 10 exceed
200 — the tail is concentrated in exactly the files a newcomer must touch (transport,
request building, charset detection). Stylistic judgement, but the one-to-one porting rule
and readability are in tension here. *Fix:* extract the hop/redirect bookkeeping and the
candidate loop's phases into named helpers with their own tests.

**F6 — Medium — 183 lines of dead code, invisible to `-vet`.** `print_set_default`
(`src/cli/options.odin:495-503`), `auth_type_is_valid` / `ssl_version_is_valid` /
`pretty_is_valid` / `usage_block_text` (`src/cli/usage.odin:290-315`, `:511-531`),
`detect_char_range` / `detect_rune_slice` (`src/http/detect_md.odin:61-63`, `:639-658`),
`print_request_head` / `print_response` / `print_body` (`src/output/print.odin:47-59`,
`:63-71`, `:74-87`) and `session_store_request_cookies` (`src/session/jar.odin:586-655`)
have no reference in `src/` or `tests/`. Three C bindings are equally unused
(`src/http/libcurl.odin:165`, `:166`, `:171`). The print trio is superseded by
`src/output/render.odin`. `-vet` checks unused variables and imports, not procs, so this
stays green. *Fix:* delete them; the 70-line session helper in particular deserves a
"wired up in <task>" note if it is pending rather than abandoned.

**F7 — Low — the scaffold survives in a live branch and in user-facing text.**
`src/session/context.odin:124-129` prints `output.print_help`, whose body
(`src/output/print.odin:28-30`) tells the user "The scaffold implements argument parsing…"
and cites task ids `t_9a017f57`/`t_3d62ca31`. I could not reach it: `./build/htthor
--version --help` prints `3.2.4` and `--help --version` prints the recorded help, because
`src/main.odin:152-181` owns `.Help`/`.Manual` and `run` checks `show_version` first
(`:120-123`). So it is a trap, not a live bug. *Fix:* delete the branch or route it to
`cli.HELP_TEXT`.

**F8 — Low — duplication forced by the leaf-package rule.** `write_codepoint_escape` /
`write_u16_escape` exist twice (`src/format/json.odin:1451`, `:1463` versus
`src/http/body.odin:557`, `:567`), as do `expand_user_path`
(`src/cli/items.odin:780`, `src/session/store.odin:378`), `is_alpha`/`is_digit`
(`src/http/url.odin:612`, `:616`; `src/output/colorize.odin:825`, `:830`),
`console_silent` (`src/cli/usage.odin:193`, `src/output/render.odin:1443`) and `parts_any`
(`src/output/render.odin:125`, `src/session/context.odin:586`). Since `format` and `http`
must not import each other, the fix is a new leaf package, not a wider import.

**F9 — Low (question) — a hand-rolled UTF-8 decoder beside the stdlib one.**
`src/http/body.odin:583` defines `decode_utf8` while the same package imports
`core:unicode/utf8` elsewhere (`src/http/url.odin:7`, `src/http/host.odin:7`). The
file does not justify it the way the JSON and MD5 headers do. *Question:* is
`RUNE_ERROR`/`surrogatepass` behaviour the reason, or is this an un-updated copy?

**F10 — Low — no licence, no CI, no format gate.** `README.md:150` confirms the missing
`LICENSE`; `.github/` is absent; `odin fmt` is not a command in the pinned toolchain
(`dev-2026-09:a2fb372b7`) and no OLS/`odinfmt` config is tracked. *Fix:* add the upstream
BSD-3-Clause licence text, and a CI job running `make check && make test`.

**F11 — Nit — `Makefile:35` builds `$(BIN)` from `$(SOURCES)` only, so edits to
`Makefile`/`local.mk` (flags, `ODIN` path) do not trigger a rebuild.**

### Recommendations, by impact

1. Restore `docs/PARITY.md` and `docs/ARCHITECTURE.md` (or replace all 253 citations) —
   F2; without it the port has no auditable specification.
2. Check the eight table generators back in, pin versions, remove the machine-local path —
   F1.
3. Fix the three implicit-allocator calls and give `json_tokens` an allocator parameter —
   F3.
4. Delete the 183 dead lines and the scaffold branch; they mislead about what ships —
   F6, F7.
5. Extract the four >400-line procs into named phases — F5.
6. Adopt one OOM policy for `or_else` on allocation — F4.
7. Add `LICENSE`, CI, and a shared leaf package for the duplicated helpers — F10, F8.

Verification note: `make check` and `make test` were run against the revision above on
2026-09-21; the binary probed for F7 was built from the same tree. Everything else above is
a reading of the cited lines. F5 and F9 are judgements, marked as such.

## Chapter 2 — Project Sanity & Fidelity: 6.6/10 (C)

**Project:** HTThor — an Odin port of HTTPie, `/home/matteo/Projects/htthor`
**Commit reviewed:** `730a497e9e20054b00de2f1c21a54d0c9f567960` ("rebrand oj -> htthor"), 24 commits, one author
**Date reviewed:** 2026-09-21 · **Environment:** Arch Linux, `odin version dev-2026-09:a2fb372b7`; `make build`, `make check`, `make test` run from a clean checkout
**Reference:** HTTPie **3.2.4** — the version HTThor targets and the version the docs site serves ("HTTPie 3.2.4 (latest) docs", dated 2024-11-01), so there is no version drift in this review.

Scope: project sanity only; code style and security depth belong to chapters 1 and 3.

### Sub-scores

| Sub-score | Score | Basis |
| --- | --- | --- |
| Claim accuracy | 8.5/10 | Self-reported limitations verified true; both README examples byte-identical; four accepted no-op flags undisclosed |
| HTTPie feature fidelity | 7.0/10 | Option table matches upstream `definition.py`@3.2.4 completely; 4 flags parsed-and-ignored; no password prompt; no auth plugins |
| Project hygiene | 4.5/10 | No LICENSE on a BSD-3-Clause derivative; 167 refs to a deleted `docs/PARITY.md`; no CI |
| Build / installability | 8.5/10 | All three documented targets pass; requirements accurate; no CI, so cross-machine reproducibility unverified |
| Maturity | 4.5/10 | 24 commits over ~2 days, no tags, no CHANGELOG, `--version` prints upstream's number, 0 issues |

**Rating = flat mean (33.0 / 5) = 6.6 → C.** Claim accuracy and buildability carry the score; hygiene and maturity drag it down, and the missing licence is a blocker rather than a cosmetic defect.

### Feature matrix

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

### What is sound

- **The option table is a real, complete port.** `OPTION_SPECS` (`src/cli/parse.odin:296-358`) reproduces every `add_argument` in upstream `httpie/cli/definition.py`@3.2.4, including the suppressed `--no-unsorted`/`--no-sorted` aliases and `-P`. No upstream flag is missing; none is invented.
- **The documented build works.** `make check` 2.3 s, `make build` links `-lcurl`, `make test` → `Finished 176 tests ... All tests were successful` and `colorize goldens: 421 cases, 0 mismatches` — exactly README:47. Both README examples are byte-identical to real output (md5 matched, CRLF included).
- **The binary does real work.** A live TLS request to `https://example.com` returned a full header block; download and resume were exercised end-to-end against local servers.
- **Dependency footprint is small and honest.** Exactly one `foreign import` in the tree (`src/http/libcurl.odin:22`), no vendored libraries, no Python; `ldd` shows `libcurl.so.4` and its own transitive deps.
- **The README is candid and I could not falsify it.** Its limitations (README:147-155) self-report the missing LICENSE, the missing CI, the unread `REQUESTS_CA_BUNDLE` (confirmed: it appears only in the recorded help text, `src/cli/help_text_generated.odin:368,791`) and the session-path divergence. That last claim is right in an interesting way: upstream 3.2.4 `sessions.py` writes `sessions/<host>_<port>/<name>.json`, so HTThor follows the *code* while the recorded help repeats upstream's own stale docstring.

### Findings (severity-ranked)

1. **HIGH — No licence on a derivative work.** No `LICENSE`/`COPYING` exists (README:150 admits it; GitHub reports `licenseInfo: null`), yet the sources derive from HTTPie, whose LICENSE is BSD-3-Clause (`https://github.com/httpie/cli/blob/master/LICENSE`, "Copyright © 2012-2022 Jakub Roztocil") — conditions 1–2 require retaining the notice and disclaimer. `grep -ri "copyright\|BSD"` over `src/` finds no attribution.
2. **HIGH — The specification the port is measured against has been deleted.** `src/` holds **167 references to `docs/PARITY.md` across 30 files** and **19 to `docs/ARCHITECTURE.md`**; `docs/` does not exist (removed in `9aa787b`). The Makefile's first line still points readers at `docs/ARCHITECTURE.md`, and error-wording/exit-code decisions cite PARITY.md as their authority (`src/cli/options.odin:9-17`).
3. **HIGH — `--stream/-S` is a no-op that `--help` advertises.** Parsed (`src/cli/parse.odin:322,1441`), stored (`src/cli/options.odin:393`), never read by any package (tree-wide field audit). The help text it reproduces promises "Always stream the response body by line, i.e., behave like `tail -f`" — the documented feature does not exist.
4. **MEDIUM — `--ssl` is validated and discarded.** `src/cli/parse.odin:346,1493` accepts and range-checks the value; `Options` has no `ssl_version` field and no `CURLOPT_SSLVERSION` appears in `src/http/curl_transport.odin`. The flag cannot change the negotiated protocol version.
5. **MEDIUM — Three more accepted-and-ignored flags, undisclosed.** `--history-print/-P`, `--debug` and `--traceback` have no reader outside the parser (`src/cli/options.odin:381-382,413-414`). With findings 3–4, four flags in the port's own `--help` do nothing; only the CA-bundle gap is disclosed in README's limitations.
6. **MEDIUM — No interactive password prompt.** `--auth user` is documented as prompting (`httpie.io/docs/cli/authentication`); HTThor silently sends `user:` (`src/http/auth.odin:46-47`, verified: Basic header emitted, no prompt). The justifying comment points at the deleted `docs/ARCHITECTURE.md`.
7. **MEDIUM — No release identity.** No tags, no CHANGELOG, one author, 24 commits over two days. `--version` prints `3.2.4` — the *upstream* number — so a binary cannot be identified as any HTThor revision.
8. **LOW — No CI.** No `.github/` (README:151), so the passing suite is unverified on any machine but this one.
9. **LOW — Dead advice and scratch files.** Legacy-session warnings tell users to run `httpie cli sessions upgrade[-all]` (`src/session/store.odin:523-567`), but no subcommand dispatch exists: `htthor cli sessions list` is parsed as a request item and exits 1. Untracked `tmp/`, `.capture-sandbox/` and `.opencode/node_modules/` sit in the working directory (all git-ignored).

### Recommendations (by impact)

1. Add a `LICENSE` (BSD-3-Clause plus the upstream copyright notice) and an attribution line in the README — the only finding with legal consequence.
2. Restore `docs/PARITY.md` and `docs/ARCHITECTURE.md`, or rewrite the 186 references to point at what replaced them. The code's provenance trail is currently broken.
3. Implement the dead flags or remove them and say so. `--stream` first: buffering a long-lived response is a real behavioural difference, and silently ignoring a documented flag is worse than rejecting it.
4. Extend README's "Status and limitations" with the `--ssl`, `--history-print`, `--debug`/`--traceback` and password-prompt gaps. The README's honesty is its strongest asset; these omissions undercut it.
5. Add CI running `make check`, `make build` and `make test` on a pinned Odin version, and tag a first release whose `--version` also prints the HTThor revision.

### Open questions

- Whether the recorded `--help`/`--manual` bytes equal a real HTTPie 3.2.4's output is **unverified**: no `httpie`/`http` binary or Python package is installed here, and upstream's help varies with installed Pygments styles. README:5 is therefore *reported, plausible, not independently diffed*.
- Proxy, redirect and cookie behaviour is **unverified at the wire level**: I confirmed the code paths and the unit tests that pin them, but never ran a reference HTTPie side by side.
- `--auth-type` with a third-party plugin cannot be exercised at all — HTThor has no plugin system — so that row is marked unverified rather than failed.

## Chapter 3 — Security: 7.3/10 (B)

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

### Sub-scores

| Dimension | Score | Basis |
| --- | --- | --- |
| Transport security (TLS) | 7.5 | Verified by default, fail-closed; `--verify=<pem>`/`--ciphers` applied. Docked for F-01. |
| Credential handling | 7.5 | Per-hop Authorization rebuild, cross-origin strip, 0600 sessions. Docked for F-06. |
| Input parsing | 9.0 | Two-layer header-injection refusal; IDNA2008; `urlsplit` CR/LF/TAB deletion. |
| Output & file safety | 6.0 | Download naming server-independent (clean); response bytes unfiltered (F-02). |
| Memory safety & build hardening | 6.5 | No `#no_bounds_check`/`assert` in `src/`; unbounded reply buffer (F-03). |

Mean = 7.3 → **B**. No Critical finding, so the 5.0 cap does not apply.

### Checked and clean

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

### Findings

| ID | Severity | Location | Summary |
| --- | --- | --- | --- |
| F-01 | **Medium** | `src/cli/parse.odin:346`, `:640`; `src/cli/options.odin:359-371` | `--ssl` accepted and ignored; no `CURLOPT_SSLVERSION`, so no TLS-version floor. |
| F-02 | **Medium** | `src/output/render.odin:1580`; `src/session/context.odin:1974` | Server bytes reach the terminal unfiltered (OSC/CSI); inherited from the reference. |
| F-03 | **Medium** | `src/session/context.odin:215`, `:1968`; `src/http/backend.odin:25`; `src/http/curl_transport.odin:538-551` | Reply buffered whole with no cap; `--download` does not stream; short writes ignored. |
| F-04 | **Low** | `src/http/proxy.odin:109-113`, `:189-194` | Uppercase `HTTP_PROXY` honoured without the reference's CGI guard (httpoxy). |
| F-05 | **Low** | `README.md:154`; `src/cli/help_text_generated.odin:368` | `--help` advertises `REQUESTS_CA_BUNDLE`, never read. |
| F-06 | **Low** | `src/session/store.odin:800-827`; `src/http/auth.odin:45-47` | `raw_auth` plaintext, tightened only on save; secrets argv-only; no prompt. |

#### F-01 — `--ssl` is accepted and has no effect

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

#### F-02 — Terminal escape-sequence injection

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

#### F-03 — Unbounded reply buffering; `--download` does not stream

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

#### F-04 — `HTTP_PROXY` honoured without the CGI guard

`proxy_for` reads lowercase then uppercase for both schemes (`src/http/proxy.odin:109-113`,
`:189-194`), where the reference's `urllib` drops the non-lowercase `http_proxy` when `REQUEST_METHOD`
is set (`/usr/lib/python3.14/urllib/request.py:1893-1898`). *Attacker and precondition:* a CGI/web-server
caller that exports `HTTP_PROXY` from the client's `Proxy:` header, then runs this tool. *Impact:* all
plaintext traffic — URLs, query strings, cookies, host Authorization headers — goes to an
attacker-chosen proxy. *Remediation:* implement the `REQUEST_METHOD` guard.

#### F-05 — Advertised CA-bundle variable is not honoured

`--help` still says to "set the `REQUESTS_CA_BUNDLE` environment variable instead"
(`src/cli/help_text_generated.odin:368`); the divergence is documented (`README.md:154`) and only
`--verify <path>` is read. *Impact (fail-open relative to intent):* a user pinning a strict or private
bundle silently gets the system store. *Remediation:* read `REQUESTS_CA_BUNDLE`/`CURL_CA_BUNDLE` as
the reference does, or delete the sentence.

#### F-06 — Secrets in argv, plaintext session credentials, no prompt

`--auth user:pass` and `--cert-key-pass` are argv-only (`/proc/<pid>/cmdline`, shell history); with
`--auth` carrying no colon the port sends an empty password rather than prompting
(`src/http/auth.odin:45-47`); `raw_auth` is plaintext on disk and `chmod 0600` runs only on save
(`src/session/store.odin:800-827`), so a pre-existing `0644` file read by a `--session-read-only` run
is never fixed or warned about. *Impact:* local credential exposure and a silent empty-password
attempt. *Remediation:* prompt or read from stdin/env when no password is given; `chmod` on load too.

### Recommendations (by severity)

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

## Assembly Notes — how this document was built, and where the chapters disagree

**Consistency checks performed on the three chapter files before merging**

- **Same revision.** All three chapters state `730a497e9e20054b00de2f1c21a54d0c9f567960`
  ("rebrand oj -> htthor") as the reviewed revision and dated the review 2026-09-21. Verified
  against the repository: `git rev-parse HEAD` returns the same SHA on a tree whose only untracked
  path is `docs/`.
- **Same scale.** All three use the 0–10 one-decimal scale with grades 9.0–10 A, 8.0–8.9 B+,
  7.0–7.9 B, 6.0–6.9 C, 5.0–5.9 D, below 5.0 F, and each rating is justified from its sub-scores
  (chapter 1 from a five-way mean of 37.5/5, chapter 2 from a five-way mean of 33.0/5, chapter 3
  from a five-way mean; chapter 3 states that no Critical finding was found, so its own 5.0 cap on
  a Critical does not apply — its rating stands at 7.3).
- **Rating lines.** No line-1 rating line was malformed, so no formatting repair was needed in this
  assembly. Each chapter's line-1 rating is carried into its section heading here
  (`## Chapter 1 — Code Quality: 7.5/10 (B)`, `## Chapter 2 — Project Sanity & Fidelity: 6.6/10 (C)`,
  `## Chapter 3 — Security: 7.3/10 (B)`).
- **Edits applied to chapter bodies:** heading levels shifted by one so each chapter's sections nest
  under its `##` heading; the duplicated line-1 title removed (the rating now lives in the section
  heading); one heading added for consistency — chapter 1's sub-score table had no heading while
  chapters 2 and 3 both had one, so `### Sub-scores` was inserted above it. No prose, no number, no
  severity and no citation was altered. Every `path:line` citation in the chapters is reproduced
  verbatim.
- **No new findings.** Everything in *Top Findings* traces to a numbered finding in a chapter;
  where two chapters cover one defect the entries are merged and both attributions are shown.

**Where the chapters disagree, both sides are kept**

1. **Severity of the missing licence.** Chapter 1 files it as **F10, Low**, grouped with "no CI, no
   formatter config". Chapter 2 files it as its **finding 1, High**, on the grounds that HTTPie is
   BSD-3-Clause and conditions 1–2 of that licence require retaining the notice and disclaimer on a
   derivative work. Same defect, different severity. This document carries it at **High** in *Top
   Findings* because chapter 2's basis is legal rather than stylistic, and reports the disagreement
   here instead of silently editing chapter 1's Low. Chapter 1's F10 text is unchanged in its
   chapter above.
2. **How many citations point at the deleted `docs/` tree.** Chapter 1 counts **253** dangling
   citations total — **211** to `docs/PARITY.md` and **22** to `docs/ARCHITECTURE.md`, by counting
   *occurrences of the path string* with `git grep -ohE 'docs/…'` over tracked `src/*`, `tests/*`,
   `Makefile` and `README.md`. Chapter 2 counts **167** references to `docs/PARITY.md` and **19** to
   `docs/ARCHITECTURE.md` across **30 files**, i.e. a different denominator (the chapter 1 worker
   recorded this distinction in a comment on task `t_4d5a4971`). The chapters agree completely on
   the defect — `docs/` was removed in `9aa787b`, the Makefile and several sources still point at
   it — and differ only on the count. This document therefore quotes the defect as **"250+ in-code
   citations"** (chapter 1's occurrence-based count) and cites chapter 2's per-file breakdown for
   the file-level view, rather than picking one chapter's number and dropping the other's.
3. **Severity of the missing password prompt / credential handling.** Chapter 2 rates it **finding
   6, Medium** (a fidelity gap: HTTPie prompts, HTThor sends `user:`). Chapter 3 bundles it with
   argv-only secrets and session-file permissions as **F-06, Low** (an exposure, not an
   exploitable defect). Both are quoted in *Top Findings* entry 8.
4. **Rated once, described twice, and not a conflict:** `--ssl` (ch2 finding 4, Medium; ch3 F-01,
   Medium) is presented as one merged finding; `--stream` (ch2 finding 3, High — a fidelity defect)
   and the unbounded reply buffer (ch3 F-03, Medium — the memory consequence) are the same code
   path seen from two lenses but have different fixes, so they stay separate in *Top Findings*
   (entries 4 and 7) as the chapters wrote them.
5. **Assembly observation, not a code finding:** chapter 1's F5 prose says "five procs carry entire
   state machines" and then lists five (`detect_matches` 540, `transport_send` 514, `apply_hop` 458,
   `build_request` 455, `apply_action` 307); the four sizes above 400 are the ones the chapter's
   own summary counted as "4 procs >400 lines". The body is reproduced verbatim as written; the
   contradiction is internal to chapter 1 and has no bearing on any other chapter or on the overall
   rating.

**Coverage limits inherited from the chapters** (unchanged, and worth reading before acting on the
numbers): chapter 3 did not audit `src/format/json.odin` + `xml.odin` (2,850 lines) line by line,
and treated libcurl/OpenSSL internals and the generated tables as trusted; chapter 2 could not
diff the recorded `--help`/`--manual` bytes against a live HTTPie 3.2.4 (no `httpie` installed) and
could not exercise the `--auth-type` plugin row (HTThor has no plugin system); proxy, redirect and
cookie parity were verified against code paths and unit tests, not against a reference HTTPie side
by side.
