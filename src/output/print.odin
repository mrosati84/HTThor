// Package output renders everything the user sees: the version line, the usage
// text, errors, and the request/response blocks.
//
// The parity renderer — --print masks, pretty JSON, ANSI styles, downloads —
// lives in render.odin and owns every request/response shape it prints. What
// remains here is the scaffold's own printing: the version string, the usage
// line `print_help` falls back to, and the one-line errors. The package
// boundary is unchanged — everything here writes to an io.Writer it is handed,
// and allocates nothing.
package output

import "core:fmt"
import "core:io"

// VERSION is the reference release this port must match byte for byte: the
// `--version` action prints the bare version string and nothing else
// (argparse's `action='version'`, httpie/cli/definition.py:923).
VERSION :: "3.2.4"

// PORT_VERSION is this port's own release: the one CHANGELOG.md names and a bug
// report should quote. The reference's line above is printed first and verbatim;
// this is a deliberate second line, because a binary that prints only `3.2.4`
// cannot be told apart from the upstream release it ports (backlog M9, README
// "Status and limitations").
PORT_VERSION :: "0.1.0"

// PORT_REVISION is the tree the binary was built from, handed in by the Makefile
// (`-define:PORT_REVISION=...`). It is empty for a build that did not name one —
// a plain `odin build src`, the test binary — and the line then stops at the
// release. `git describe --always --dirty` is what the Makefile passes, so a
// build from a modified tree says so.
PORT_REVISION :: #config(PORT_REVISION, "")

// print_version writes the reference's version line, then the port's own
// identity: `--version` is the one action a bug report quotes, and the revision
// it came from has to be nameable (backlog M9).
print_version :: proc(w: io.Writer) {
	fmt.wprintfln(w, "%s", VERSION)
	if PORT_REVISION == "" {
		fmt.wprintfln(w, "htthor %s", PORT_VERSION)
		return
	}
	fmt.wprintfln(w, "htthor %s (%s)", PORT_VERSION, PORT_REVISION)
}

print_help :: proc(w: io.Writer, program_name: string) {
	fmt.wprintfln(w, "usage: %s [METHOD] URL [ITEM ...]", program_name)
	fmt.wprintfln(w, "")
	fmt.wprintfln(w, "The scaffold implements argument parsing, the request model and the")
	fmt.wprintfln(w, "transport wrapper. The renderer, the request-item grammar and the")
	fmt.wprintfln(w, "engine land in t_9a017f57 and t_3d62ca31; see docs/ARCHITECTURE.md.")
}

// print_error writes a usage or transport error. httpie prefixes the program
// name; docs/PARITY.md pins the exact wording and stream.
print_error :: proc(w: io.Writer, program_name: string, message: string) {
	fmt.wprintfln(w, "%s: error: %s", program_name, message)
}
