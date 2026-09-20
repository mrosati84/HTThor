// Package output renders everything the user sees: the version line, the usage
// text, errors, and the request/response blocks.
//
// The scaffold prints the shapes the skeleton can actually produce (a request
// head for --offline, a response head and raw body). The parity renderer —
// --print masks, pretty JSON, ANSI styles, downloads — is t_9a017f57's; it
// replaces these procs without changing the package boundary: everything here
// writes to an io.Writer it is handed, and allocates nothing.
package output

import "core:fmt"
import "core:io"

import "src:http"

// VERSION is the reference release this port must match byte for byte: the
// `--version` action prints the bare version string and nothing else
// (argparse's `action='version'`, httpie/cli/definition.py:923).
VERSION :: "3.2.4"

print_version :: proc(w: io.Writer) {
	fmt.wprintfln(w, "%s", VERSION)
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

// print_request_head renders the request line and headers for --offline: the
// request that would go on the wire, without sending it. Serialising the query
// string and the body is the engine's job (t_3d62ca31); this renders the target
// the scaffold already parsed.
//
// The `Host` line is the authority the URL spells — the request's host plus
// `:<port>` whenever the URL spelled a port whose value is not zero, an explicit
// scheme default included (`http.host_header_value`, docs/PARITY.md §3.6).
print_request_head :: proc(w: io.Writer, req: ^http.Request) {
	fmt.wprintfln(w, "%s %s HTTP/1.1", http.method_to_string(req.method), req.path)

	if req.port != 0 {
		fmt.wprintfln(w, "Host: %s:%d", req.host, req.port)
	} else {
		fmt.wprintfln(w, "Host: %s", req.host)
	}
	for header in req.headers {
		fmt.wprintfln(w, "%s: %s", header.name, header.value)
	}
	io.write_string(w, "\n")
}

// print_response writes the status line, the headers and the body verbatim.
// Pretty printing and --print masks replace this in t_9a017f57.
print_response :: proc(w: io.Writer, res: ^http.Response) {
	version := res.http_version != "" ? res.http_version : "HTTP/1.1"
	fmt.wprintfln(w, "%s %d %s", version, res.status, res.reason)
	for header in res.headers {
		fmt.wprintfln(w, "%s: %s", header.name, header.value)
	}
	io.write_string(w, "\n")
	print_body(w, res)
}

// print_body writes the response bytes as received; it does not interpret them.
print_body :: proc(w: io.Writer, res: ^http.Response) -> (int, io.Error) {
	if len(res.body) == 0 {
		return 0, .None
	}
	written, write_err := io.write(w, res.body)
	if write_err != .None {
		return written, write_err
	}
	if res.body[len(res.body) - 1] != '\n' {
		n, newline_err := io.write_string(w, "\n")
		return written + n, newline_err
	}
	return written, .None
}
