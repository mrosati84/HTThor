# oj (htthor) — Evidence-Based Quality Rating

## Scope and method

This report assesses the Odin port of `httpie`, `oj`, at observed commit
`f13d8f3` ("working version"), on the machine toolchain `odin dev-2026-09:a2fb372b7`
(`odin version`) with the *machine* libcurl `8.22.0` (`curl --version` →
`libcurl/8.22.0 OpenSSL/3.6.4 ... Release-Date: 2026-09-02`). The tree is a
single-commit repository. Everything below is graded from reproducible evidence:
each non-obvious claim is backed by a shell command plus its observed result, or by
a `path:line` citation. A prior worker produced `/tmp/opencode/oj-evidence.md`
(261 lines); it was used as the primary source, and at least six of its claims were
independently re-run or re-read here. Three of its numeric claims did not survive
those spot-checks and are corrected in this report (see **Caveats**). The
assessment covers seven dimensions — functional correctness, tests, architecture,
memory safety, security, documentation, and build/packaging — and does not modify
`src/` or `tests/`.

## Rating scale and weighting

Scores use a **0–10 scale at one decimal place**, where 0 is non-functional or
unsafe and 10 is exemplary with no material caveats. Each of the seven dimensions
is scored independently, then combined with **equal weights (1/7 each)**:

```
overall = round_to_1dp( (D1 + D2 + D3 + D4 + D5 + D6 + D7) / 7 )
```

Equal weighting is chosen because the requirements give no basis for ranking the
dimensions, and a port can pass its gates while still carrying contract drift; an
unweighted mean is the most defensible, least hand-tuned rule. No dimension score
is adjusted after the fact to hit a target overall. Scores reflect the whole
tree, with generated files counted by provenance rather than by line-by-line
review (see **Caveats**).

## Overall rating

### Overall: **7.5 / 10**

`oj` is a large (64,112 source LOC), disciplined, genuinely working port: all
three gates pass cleanly, 167 tests including real-wire HTTP engine tests all
succeed, and the memory-ownership engineering is well above average. It is not a
10 because it ships a security-adjacent correctness bug in redirect credential
handling, violates its own hard allocator contract in 21 places, and documents
several artifacts that do not exist — including `docs/PARITY.md`, cited as the
source of truth but absent from the tree. It is far from a bad port: the
deficiencies are mostly contract/provenance drift and one localized behavioral
divergence, sitting on top of a strong, leak-asserted core.

## Gates and reproducibility

All three gates were re-run from the repository root on the machine described
above. Each exited `0`:

| Command | Exit code | Key observed output |
| --- | --- | --- |
| `make check` | `0` | two `odin check` invocations (src, then tests) with no warnings |
| `make build` | `0` | produced `build/oj` (size is output-path/metadata dependent; exit 0 is the gate) |
| `make test-unit` | `0` | `Finished 167 tests in 1.016558388s. All tests were successful.` |

`make check` runs, verbatim (`Makefile:48-51`):

```sh
/usr/bin/odin check src -collection:src=src -vet -warnings-as-errors
/usr/bin/odin check tests -collection:src=src -vet -warnings-as-errors -no-entry-point
```

`make test-unit` (`Makefile:43-44`) printed both required summary lines:

```
colorize goldens: 421 cases, 0 mismatches
Finished 167 tests in 1.016558388s. All tests were successful.
```

**How a reader reproduces this:** on a machine with the `dev-2026-09` Odin
toolchain and libcurl development files, from the repo root run
`make check; echo EXIT=$?`, `make build; echo EXIT=$?`, and
`make test-unit; echo EXIT=$?`. Each must print `EXIT=0`; `make test-unit` must
print the two lines above. `make check-deps` (`Makefile:53-55`) fails early with a
clear message if `odin` is not on `PATH`.

## Dimension scores

| # | Dimension | Score |
| --- | --- | --- |
| 1 | Functional scope & correctness | 7.5 |
| 2 | Test-suite quality | 8.5 |
| 3 | Architecture & module boundaries | 7.5 |
| 4 | Memory / resource ownership safety | 9.0 |
| 5 | Security posture (TLS, auth, C interop) | 7.5 |
| 6 | Documentation integrity | 5.0 |
| 7 | Build & packaging | 7.5 |
| | **Overall (equal-weight mean)** | **7.5** |

### 1. Functional scope & correctness — 7.5

The port is broad and functional: it implements the CLI parser, request/response
model, libcurl transport, and renderer, totalling 64,112 lines across 45 `src`
`.odin` files and 10,979 lines across 15 `tests` files (`find ... | wc -l`). The
full suite passes (`make test-unit` → `EXIT=0`, 167 tests) and the colorize golden
replay reports `421 cases, 0 mismatches`, so the reference-derived rendering is
correct on a large corpus. The score is held below 9 by a real, localized
behavioral divergence in `should_strip_authorization`
(`src/http/curl_transport.odin:1177-1195`): the reference `requests` library and
the Odin logic disagree on 3 of 7 redirect cases (`python3
/tmp/opencode/redirect_auth_check.py` → `7 cases, 3 divergence(s)`), including a
wrong result on the ordinary `http://h/a -> https://h/b` upgrade. The core is
correct on everything the suite exercises; the defect sits in an untested corner
(see Finding F1).

### 2. Test-suite quality — 8.5

There are 167 `@(test)` procs (`rg -o '@\(test\)' tests | wc -l` → `167`), and the
engine tests are behavioural rather than snapshot: `tests/http_engine_test.odin`
starts a real one-thread loopback server (`engine_server_start` binds
`127.0.0.1:0` via `net.listen_tcp`, `tests/http_engine_test.odin:53-87`), records
raw request bytes, and asserts on the wire. Ownership is actively executed, not
just declared: 108 `mem.Tracking_Allocator` occurrences, 80 `expect_no_leaks(`
call sites (`tests/helpers.odin:54`), and 29 `engine_no_leaks(` call sites give
**109 leak assertions** across the suite. The suite loses points for three real
gaps: no test covers `should_strip_authorization` (`rg -n 'should_strip|strip_auth'
tests` returns no matches at all, exit `1`; the similarly named
`should_strip_sig_or_bom` lives only in `src/http/detect.odin:272`); `tests/charset_test.odin`
and `tests/colorize_test.odin` use no tracking allocator at all
(`rg -c 'Tracking_Allocator|expect_no_leaks'` on both exits `1`); and
`tests/libcurl_test.odin` omits `CURLOPT_READDATA`/`CURLOPT_READFUNCTION` (F6).

### 3. Architecture & module boundaries — 7.5

The intended dependency direction largely holds. `src/http` imports neither
`src:cli` nor `src:output` (`rg -n 'src:cli|src:output' src/http -g '*.odin'` →
empty), the transport has a single seam (`src/http/backend.odin:24 send` →
`:32 send_to` → `:35 transport_send`, with `transport_send` defined at
`curl_transport.odin:1206`), and `src/main.odin:18` is the one permitted
`context.allocator` read. However, the documented hard rule is broken in the
small: `docs/ARCHITECTURE.md:182-186` says no file under `src/` reads
`context.temp_allocator`, yet there are **21 non-comment code hits in 7 files**
(`rg -n 'context\.temp_allocator' src -g '*.odin' | rg -v '^\S+:\d+:\s*//'` →
`21`). The DAG in `ARCHITECTURE.md:47-50` also omits a real edge,
`cli -> rich` (`src/cli/usage.odin:33`). These are contract violations with
mostly localized impact, but they mean the stated boundary invariant is not true.

### 4. Memory / resource ownership safety — 9.0

This is the strongest dimension. `src/http/owned.odin` makes ownership explicit:
`Buffer` stores its allocator (`:54-57`), `buffer_make` uses it (`:59-64`),
`buffer_owned` transfers bytes and nils the slot (`:119-126`), and
`buffer_destroy` frees through the dynamic array's own allocator (`:128-131`).
Destroy procs accept a zero value and zero their argument, making double-destroy
safe (e.g. `http.request_destroy` at `src/http/request.odin:1266-1326` ends with
`req^ = {}`; `cli.options_destroy` at `src/cli/options.odin:450-485`). The
tracking allocators actually assert this: 108 `mem.Tracking_Allocator`
occurrences and 109 leak assertions, all green under `make test-unit`. The
borrowing exception for `Request.proxy/.cert/...` is deliberate and documented
(`request.odin:1320-1324` vs `options.odin:462-465`). The one blemish is that
three `make` calls inside `src/output` omit an allocator and thus bypass the
tracker (F5); no leak or use-after-free was observed in exercised paths.

### 5. Security posture (TLS, auth, C interop) — 7.5

TLS verification defaults **on**: `Request.verify = true`
(`src/http/request.odin:58,181`), the CLI default is `"yes"`
(`src/cli/parse.odin:678,1907`), and the engine maps that to
`CURLOPT_SSL_VERIFYPEER = req.verify?1:0` (`src/http/curl_transport.odin:1357`)
and `CURLOPT_SSL_VERIFYHOST = req.verify?2:0` (`:1362`), with `--verify=<path>`
→ `CURLOPT_CAINFO` (`:1374`). Digest auth is hand-rolled MD5 validated against
the RFC 1321 vectors (`tests/digest_test.odin:22-78`, e.g. `"" →
d41d8cd98f00b204e9800998ecf8427e`), and `CURLOPT_VERBOSE` is declared but never
set in `src`, so libcurl cannot dump credentials. The dimension is docked for the
redirect credential divergence in F1, which is security-adjacent (it strips auth
on legitimate upgrades and forwards it across a scheme change on a non-standard
port), and for the two unchecked libcurl option constants in F6.

### 6. Documentation integrity — 5.0

`docs/ARCHITECTURE.md` is detailed and unusually self-aware, but the tree
systematically references artifacts that do not exist. `docs/PARITY.md` is absent
(`[ -e docs/PARITY.md ]` → no) yet is named **223 times**
(`rg -o 'PARITY.md' . -g '!docs/RATING.md' | wc -l` → `223`; 10 within
`ARCHITECTURE.md`; this report is excluded to avoid self-reference), and
`ARCHITECTURE.md:395-397` makes it the authority for undecidable behaviour.
`.github/workflows/ci.yml` is described at `ARCHITECTURE.md:304-311` but there is
no `.github/` tree at all (`ls -la .github` → no such directory). `docs/REVIEW.md`
(`ARCHITECTURE.md:319`), `tests/golden_test.odin` + `capture_argv`
(`ARCHITECTURE.md:288-290`), `tests/parity/server.py`, and the `build/probe_*`
provenance scripts are likewise cited and missing. `README.md:5` claims "no
Python, no reference-parity harness" while `.capture-sandbox/` (15 files) is
present and git-ignored. The number is not lower because the architecture prose,
the Makefile contract, and the README build instructions are accurate.

### 7. Build & packaging — 7.5

The build is clean and portable. `Makefile:29-58` defines `all build test
test-unit check check-deps clean`; `build` links `-lcurl` via
`-extra-linker-flags` (`Makefile:21-22`), and `make build` produced
`build/oj` (2,549,296 bytes on the observed artifact; the exact size is
output-path/metadata dependent, so the gate that matters is `EXIT=0`). The
`-vet -warnings-as-errors` flags
(`Makefile:17,19`) make the zero-warning property a hard gate, and
`check-deps` gives a helpful failure when `odin` is missing. Per-machine paths
live in git-ignored `local.mk` (`git check-ignore -v local.mk` →
`.gitignore:3:local.mk`; `Makefile:27 -include local.mk`). It loses points because
the documented CI workflow does not exist (F3) and because the pinned libcurl is
stale: `ARCHITECTURE.md:9` says "libcurl 8.5.0" while the machine runs 8.22.0,
which the engine tests explicitly work around at
`tests/http_engine_test.odin:362-368`.

## Findings and weaknesses

### F1 — MAJOR: `should_strip_authorization` diverges from `requests` on redirects

`src/http/curl_transport.odin:1177-1195` implements the reference
`should_strip_auth`, called at `:1698`, and `:987-989` skips the `Authorization`
header when `!hop.keep_authorization`. The logic normalizes absent ports to
80/443 *before* comparing them (`:1186-1187`), which makes the documented
http→https exception (`:1175-1176`, `:1194`) unreachable for default ports and
also keeps credentials across a scheme change on a non-standard same port.

Reproduction recorded by the prior worker, re-run here:

```sh
python3 /tmp/opencode/redirect_auth_check.py
```

Observed (exit `1`), comparing `requests` 2.34.2 `should_strip_auth` with a
faithful transcription of the Odin logic (column values are `should_strip_auth`
returns; `True` = strip credentials):

```
old                        new                        requests  odin   match
http://h/a                 https://h/b                False     True   DIVERGE
http://h:80/a              https://h:443/b            False     True   DIVERGE
http://h/a                 http://h/b                 False     False  OK
http://h:8080/a            https://h:8080/b           True      False  DIVERGE
http://h/a                 https://h:8443/b           True      True   OK
http://h/a                 http://h:8080/b            True      True   OK
http://h/a                 https://other/b            True      True   OK

7 cases, 3 divergence(s)
```

Impact: (a) on the standard `http://h/a -> https://h/b` upgrade, `requests` keeps
`Authorization` (`False`) while `oj` strips it (`True`), so authenticated
redirects silently lose credentials; (b) on `http://h:8080/a -> https://h:8080/b`,
`requests` strips (`True`) while `oj` keeps (`False`), forwarding credentials
across a scheme change where the reference would not. No test covers this
function (see dimension 2), which is why the defect survives `make test-unit`.
*(Correction: the evidence bundle's prose stated the first two case values
inverted; the actual script output above is authoritative.)*

### F2 — MAJOR: the documented source of truth `docs/PARITY.md` does not exist

`docs/` contains only `ARCHITECTURE.md`; `docs/PARITY.md` is absent, yet it is
referenced 223 times across the tree, including 10 times in `ARCHITECTURE.md`.
`ARCHITECTURE.md:395-397` states that behaviour the tests cannot decide "comes
from `docs/PARITY.md`, not from preference", so the authority the codebase points
to is missing. Proof: `rg -o 'PARITY.md' . -g '!docs/RATING.md' | wc -l` → `223`;
`[ -e docs/PARITY.md ]` → no.

### F3 — MAJOR: the documented CI workflow is absent

`ARCHITECTURE.md:304-311` describes `.github/workflows/ci.yml` running
`make build` and `make test` on Ubuntu, and claims "a green CI run therefore
means: zero warnings, and all Odin tests pass". There is no `.github/` directory
(`ls -la .github` → no such file or directory), so the described gate does not
exist; reproducibility rests entirely on a developer running Make locally.

### F4 — MAJOR: 21 `context.temp_allocator` uses violate the hard allocator rule

`ARCHITECTURE.md:182-186` is explicit: "No file under `src/` reads
`context.allocator` or `context.temp_allocator`". There are 21 non-comment code
uses in 7 files — `src/cli/parse.odin:461,859,1613,1746,1750,1953,2132,3103,3121`
(9), `src/session/jar.odin:218,255,378,401` (4),
`src/http/detect.odin:364,379,870` (3), `src/http/charset.odin:158,176` (2), and
one each at `src/output/render.odin:1214`, `src/session/context.odin:2039`,
`src/session/store.odin:415`. Proof: `rg -n 'context\.temp_allocator' src -g
'*.odin' | rg -v '^\S+:\d+:\s*//' | wc -l` → `21`. Impact is localized (the
suite's leak assertions still pass), but it defeats the "allocator read exactly
once" invariant and the explicit-allocator-parameter model the code claims.

### F5 — MAJOR: `src/output` allocates, contradicting the "allocates nothing" rule

`ARCHITECTURE.md:58-60` requires `output` to "write to an `io.Writer` it is
handed and allocate nothing". `src/output` instead contains 10 explicit `make(`
call sites (`rg -n '\bmake\(' src/output -g '*.odin' | wc -l` → `10`; `new(` → 0),
of which **three pass no allocator** and therefore read `context.allocator`
implicitly: `src/output/colorize.odin:917` (`make([dynamic]int, ...)`),
`:919` (`make([dynamic]rune, ...)`), and `:947` (`make([dynamic]JSON_Queued, ...)`).
These bypass both the architecture contract and any test's tracking allocator.
Proof: the `make(` listing above; compare `:217,227,236,253,271` and
`src/output/render.odin:283,457`, which do pass an explicit allocator.
*(Correction: the evidence bundle said "18 allocation sites"; the reproducible
`make`/`new` count is 10, of which 3 lack an allocator.)*

### F6 — MINOR: two used libcurl option constants are never validated

`src/http/libcurl.odin:15-17` claims every option number is re-checked against
`curl_easy_option_by_name` at run time "so a typo cannot survive `make test`".
`tests/libcurl_test.odin` checks the constants via that API, but omits
`CURLOPT_READDATA` (`src/http/libcurl.odin:113`) and `CURLOPT_READFUNCTION`
(`:125`), both used by the engine (`src/http/curl_transport.odin:819,822`).
Proof: `rg -n 'READDATA|READFUNCTION' tests/libcurl_test.odin` → no matches
(exit 1). A wrong value for either would not fail the suite.

### F7 — MINOR: provenance artifacts cited by source and tests are missing

`ARCHITECTURE.md:288-290` documents `tests/golden_test.odin` and its
`capture_argv` helper; neither exists (golden replay actually lives in
`tests/colorize_test.odin` over `tests/golden/`). `ARCHITECTURE.md:319` names
`docs/REVIEW.md` (absent). Paths under `tests/parity/` are referenced 11 times
(`rg -o 'tests/parity' . -g '!docs/RATING.md' | wc -l` → `11`), of which the
specific file `tests/parity/server.py` appears 5 times
(`rg -o 'tests/parity/server\.py' . -g '!docs/RATING.md' | wc -l` → `5`), and the
`build/probe_*.py`/`.c` scripts are cited 50+ times as the provenance for digest,
dot-segment, and wire measurements, but neither path exists (`build/` holds only
`oj`). The tree cannot reproduce its own reference captures.

### F8 — MINOR: README purity claim contradicts a present sandbox

`README.md:5` says the tree is "pure Odin — no Python, no reference-parity
harness", but `.capture-sandbox/` is present with 15 files
(`find .capture-sandbox -type f | wc -l` → `15`) and is git-ignored
(`git check-ignore -v .capture-sandbox` → `.gitignore:15:/.capture-sandbox/`),
a leftover of the removed harness.

### F9 — MINOR: internal doc inconsistency on C callback count

`ARCHITECTURE.md:261` says "`curl_transport.odin`'s two libcurl callbacks", but
there are three `proc "c"` callbacks: `write_callback`
(`src/http/curl_transport.odin:529`), `read_callback` (`:557`), and
`header_callback` (`:576`). A documentation-only defect, but it is another case
where the contract prose and the code disagree.

## What is genuinely good

- **Zero-warning gate is real.** `make check` type-checks and vets both packages
  with `-vet -warnings-as-errors` and exits `0` (`Makefile:48-51`).
- **Ownership is executed, not asserted on paper.** 108 `mem.Tracking_Allocator`
  occurrences and 109 leak assertions (80 `expect_no_leaks` + 29
  `engine_no_leaks`) run under every suite invocation and all pass.
- **Real-wire HTTP engine tests.** `tests/http_engine_test.odin:53-87` starts a
  loopback server on `127.0.0.1:0` and asserts on raw request bytes, exercising
  bodies, auth, redirects, chunked/gzip, and refused/lookup/timeout paths.
- **Large verified corpus.** `make test-unit` reports
  `colorize goldens: 421 cases, 0 mismatches` against
  `tests/golden/colorize/manifest.tsv` (whose header records `cases 421`).
- **Hand-declared thin C binding.** Only `src/http/libcurl.odin` contains a
  `foreign import` (`:22`); no C headers are a build dependency and no `cstring`
  escapes the package, with libcurl constants validated via
  `curl_easy_option_by_name` in `tests/libcurl_test.odin`.
- **Secure defaults.** TLS peer/host verification is on by default
  (`src/http/request.odin:58,181`; `curl_transport.odin:1357,1362`) and
  `CURLOPT_VERBOSE` is never set, so no debug channel can leak credentials.
- **Double-destroy-safe resource API.** `*_destroy` procs accept zero values and
  zero their argument (e.g. `src/http/request.odin:1266-1326`,
  `src/cli/options.odin:450-485`).

## Caveats and confidence

- **Generated files are scored by provenance, not line review.** 8
  `*_generated.odin` files total 31,882 lines of the 64,112 `src` lines
  (`find src -name '*_generated.odin' | wc -l` → `8`), the largest being
  `src/http/idna_generated.odin` (8,971). They were not read line-by-line; they
  are credited only because they compile cleanly and their consuming tests pass.
- **Machine libcurl differs from the documented pin.** The machine runs libcurl
  `8.22.0`, while `docs/ARCHITECTURE.md:9` claims `8.5.0`. The suite passes
  anyway because it explicitly works around 8.22's `Connection`-header-last
  ordering (`tests/http_engine_test.odin:362-368`); the pin is stale but not
  currently breaking.
- **Single-commit history.** The repository is one commit, `f13d8f3`; there is no
  history to evaluate incremental quality, review discipline, or whether the
  drift accumulated gradually. Confidence in the current snapshot is high.
- **Three evidence-bundle corrections were made here.** `docs/PARITY.md`
  references are `223`, not `221`; `src/output` has `10` explicit `make`/`new`
  sites (3 without an allocator), not `18` "allocation sites"; and the redirect
  checker's first two case values were reported inverted in the bundle prose
  (the script output shown in F1 is authoritative). All other spot-checked
  bundle claims reproduced exactly.
- **Environment fragility.** The engine's one documented brittleness is
  libcurl-version-dependent header ordering, handled explicitly, so the suite is
  not silently green on a different libcurl.

## How to reproduce this assessment

Run from `/home/matteo/Projects/htthor` on the described toolchain:

```sh
odin version                                    # dev-2026-09:a2fb372b7
curl --version | head -2                        # libcurl/8.22.0
make check; echo CHECK_EXIT=$?                  # -> 0
make build; echo BUILD_EXIT=$?                  # -> 0; ls -la build/oj
make test-unit; echo TESTUNIT_EXIT=$?           # -> 0; 167 tests, 421 goldens
rg -o '@\(test\)' tests | wc -l                  # -> 167
rg -n 'context\.temp_allocator' src -g '*.odin' \
  | rg -v '^\S+:\d+:\s*//' | wc -l               # -> 21
rg -n '\bmake\(' src/output -g '*.odin'          # -> 10 sites, 3 without allocator
rg -o 'PARITY.md' . -g '!docs/RATING.md' | wc -l  # -> 223 (report excluded)
[ -e docs/PARITY.md ] && echo PRESENT || echo ABSENT   # -> ABSENT
ls -la .github 2>/dev/null || echo "no .github"  # -> no .github
rg -n 'READDATA|READFUNCTION' tests/libcurl_test.odin  # -> no matches (exit 1)
python3 /tmp/opencode/redirect_auth_check.py     # -> 3 divergence(s), exit 1
find src -name '*.odin' -print0 | xargs -0 cat | wc -l   # -> 64112
```

The redirect reproduction requires Python `requests` (observed: 2.34.2) and the
script at `/tmp/opencode/redirect_auth_check.py`, which transcribes the Odin
logic at `src/http/curl_transport.odin:1177-1195` and exits non-zero on any
divergence.
