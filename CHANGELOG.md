# Changelog

All notable changes to this port are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the port's own
releases are numbered with [Semantic Versioning](https://semver.org/).

Two version numbers are in play and they are not the same number:

- **HTTPie 3.2.4** — the upstream release this port matches byte for byte. It is what
  `--version` prints on its first line (argparse's `action='version'`), and what
  `tests/cli_help_test.odin` pins for `--help`/`--manual`.
- **HTThor 0.1.0** — this port's own release, printed on the second line of `--version`
  together with the git revision the binary was built from. Quote it, and the revision,
  in a bug report.

## [0.1.0] - 2026-09-21

First release. `HTThor` ports HTTPie 3.2.4 to Odin: the argparse-compatible command
line and request-item grammar, the request model, the libcurl transport, and the
byte-exact renderer (`--print` masks, pretty JSON/XML, Pygments-style colouring).

### Fixed — review remediation

The first review pass's findings are closed; the row-by-row record, including the
items deliberately deferred and why, is `docs/rating/HTThor-remediation-backlog.md`.
The user-visible fixes:

- `--ssl` now sets a TLS-version floor (`CURLOPT_SSLVERSION`) instead of being parsed
  and discarded.
- Reply bytes printed to a terminal are sanitised: a server can no longer clear the
  screen, move the cursor or write the clipboard through a body or a header value.
  `HTTHOR_ALLOW_TERMINAL_ESCAPES=1` prints the reference's raw bytes instead.
- `--download` streams the body into the file instead of buffering it whole, and a
  short write is reported instead of silently truncating the file.
- `--auth user` with no password takes it from `$HTTHOR_AUTH_PASSWORD` and stops the
  run when there is none, rather than sending `user:` with an empty password.
- A session file another tool wrote is reported and tightened to `0600` when it was
  readable by other users; `--session-read-only` reports it without touching it.
- A reply body that nothing streams is capped: a huge or endless body is refused with
  an error instead of taking the machine down.
- `--version` names the port's release and the revision it was built from.
- `--stream`/`-S` selects the stream HTTPie picks for it instead of being parsed and read
  by nothing: a prettified reply is processed by the line-oriented `PrettyStream` rather
  than `BufferedPrettyStream`, so an empty body is never handed to its encoder — a charset
  no codec resolves no longer ends the run under `--stream`, where the buffered stream
  still reports HTTPie's `LookupError` — and a streamed body's last line ends in a line
  feed. The reply itself still arrives whole (the transport buffers it), so the `tail -f`
  behaviour the recorded `--help` text advertises is not reproduced; `README.md`, *Status
  and limitations*, says so.
