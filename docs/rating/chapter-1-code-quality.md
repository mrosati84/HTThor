# Chapter 1 — Code Quality — Rating: 7.5/10 (B)

Reviewed revision: `730a497e9e20054b00de2f1c21a54d0c9f567960` ("rebrand oj -> htthor"),
2026-09-21. Working tree clean at review time; all paths below are relative to the
repository root at that commit. Where I ran something, I say so; where a judgement is
stylistic, I mark it so.

| Sub-score | Value | Anchor |
| --- | --- | --- |
| Idioms | 7.5 | 361/364 allocation sites thread an explicit allocator; 199 silent `or_else ""` |
| Structure | 7.0 | acyclic package graph, but 8 god-files, 10 procs >200 lines, 50% generated lines |
| Readability | 7.5 | 29% comment lines, zero TODOs, but 253 citations to deleted docs and 183 dead lines |
| Test coverage | 8.0 | 176 tests / 11,696 lines pass; `main` and the built binary untested |
| Build hygiene | 7.5 | `-vet -warnings-as-errors` everywhere, 2.6 s check gate; no CI, no formatter, no table regeneration |

Mean of the five sub-scores is 37.5/5 = **7.5** → grade **B**. The score is capped by
structure and by two provenance findings, not by correctness.

## What is sound

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

## Findings

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

## Recommendations, by impact

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
