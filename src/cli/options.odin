package cli

import "core:mem"
import "core:os"
import "core:strings"

import "src:http"

// Exit_Code mirrors httpie's exit codes (docs/PARITY.md §5, httpie/status.py).
//
// NOTE ON USAGE ERRORS. argparse's own `parser.error()` calls `exit(2)`, but
// httpie catches that SystemExit in `raw_main` and maps it to
// `ExitStatus.ERROR` = 1 (docs/PARITY.md §2 note 5, verified by every `err-*`
// capture: `err-invalid-item.rc` contains `1`). The task body for t_9a017f57
// asks for 2; docs/PARITY.md is the specification this port is measured
// against and the parity harness (t_225e2dc3) diffs exit codes against the
// reference, so the reference value wins here.
Exit_Code :: enum int {
	Ok                 = 0,
	Error              = 1, // usage errors, transport errors, unhandled failures
	Timeout            = 2, // requests.Timeout
	Http_3xx           = 3, // --check-status / --download, no --follow
	Http_4xx           = 4,
	Http_5xx           = 5,
	Too_Many_Redirects = 6,
	Plugin_Error       = 7, // defined by httpie 3.2.4 but never raised
	Ctrl_C             = 130,
}

// Usage_Error is the code main exits with after a parse failure. It is spelled
// as the reference's code on purpose; see the note on Exit_Code.
USAGE_EXIT_CODE :: Exit_Code.Error

Body_Kind :: enum {
	JSON, // --json / default: data items become one JSON object
	Form, // --form: application/x-www-form-urlencoded
	Multipart, // --multipart, or --form with a file field
	Raw, // --raw / bare @file / stdin
}

// ---------------------------------------------------------------------------
// The process environment
// ---------------------------------------------------------------------------

// Env_Var is one `NAME=VALUE` pair of the environment the parser reads. `name`
// never contains '='; an entry without one is kept with an empty value, the way
// Python's os.environ reports it.
Env_Var :: struct {
	name:  string,
	value: string,
}

// Env_Info is everything about the process the parser needs beyond argv: the
// tty-ness of the three standard streams and the environment itself.
//
// httpie reads these from its `Environment` object (httpie/context.py): the
// tty flags decide the default `--print` set and `--pretty`, and the variables
// configure the proxy, the config directory and the terminal's colour count.
//
// Ownership: `vars` and the strings inside it belong to whoever built the
// Env_Info; parse_args_with clones what it keeps (Options.env) and frees it in
// options_destroy, so callers may hand it borrowed strings.
Env_Info :: struct {
	stdin_is_tty:  bool,
	stdout_is_tty: bool,
	stderr_is_tty: bool,
	vars:          []Env_Var,
}

// env_get is os.environ.get(name); the second result is false when the
// variable is not set (as opposed to set to the empty string).
env_get :: proc(env: Env_Info, name: string) -> (string, bool) {
	for v in env.vars {
		if v.name == name {
			return v.value, true
		}
	}
	return "", false
}

// env_info_clone copies `env` so the copy can outlive the caller's strings.
env_info_clone :: proc(env: Env_Info, allocator: mem.Allocator) -> Env_Info {
	cloned := Env_Info {
		stdin_is_tty  = env.stdin_is_tty,
		stdout_is_tty = env.stdout_is_tty,
		stderr_is_tty = env.stderr_is_tty,
	}
	if len(env.vars) > 0 {
		cloned.vars = make([]Env_Var, len(env.vars), allocator)
		for v, i in env.vars {
			cloned.vars[i] = Env_Var {
				name  = strings.clone(v.name, allocator) or_else "",
				value = strings.clone(v.value, allocator) or_else "",
			}
		}
	}
	return cloned
}

// env_info_destroy releases an Env_Info built by env_info_clone or
// env_info_from_process and zeroes it.
env_info_destroy :: proc(env: ^Env_Info, allocator: mem.Allocator) {
	if env == nil {
		return
	}
	for v in env.vars {
		delete(v.name, allocator)
		delete(v.value, allocator)
	}
	delete(env.vars, allocator)
	env^ = {}
}

// env_info_from_process reads the live process: the tty-ness of stdin, stdout
// and stderr (`posix.isatty`) and every environment variable.
//
// This is the one place that touches process-global state; parse_args calls it
// and everything else goes through parse_args_with, which is why the parser is
// testable without a terminal.
env_info_from_process :: proc(allocator: mem.Allocator) -> Env_Info {
	env := Env_Info {
		stdin_is_tty  = os.is_tty(os.stdin),
		stdout_is_tty = os.is_tty(os.stdout),
		stderr_is_tty = os.is_tty(os.stderr),
	}
	raw, err := os.environ(allocator)
	if err != nil {
		return env
	}
	defer {
		for entry in raw {
			delete(entry, allocator)
		}
		delete(raw, allocator)
	}
	if len(raw) > 0 {
		env.vars = make([]Env_Var, len(raw), allocator)
		for entry, i in raw {
			if split := strings.index_byte(entry, '='); split >= 0 {
				env.vars[i] = Env_Var {
					name  = strings.clone(entry[:split], allocator) or_else "",
					value = strings.clone(entry[split + 1:], allocator) or_else "",
				}
			} else {
				env.vars[i] = Env_Var{name = strings.clone(entry, allocator) or_else ""}
			}
		}
	}
	return env
}

// env_info_from_strings builds an Env_Info from `NAME=VALUE` strings, for tests
// and for callers that already have the environment in that form. Ownership of
// the result is the caller's (env_info_destroy).
env_info_from_strings :: proc(
	entries: []string,
	stdin_is_tty, stdout_is_tty, stderr_is_tty: bool,
	allocator: mem.Allocator,
) -> Env_Info {
	env := Env_Info {
		stdin_is_tty  = stdin_is_tty,
		stdout_is_tty = stdout_is_tty,
		stderr_is_tty = stderr_is_tty,
	}
	if len(entries) > 0 {
		env.vars = make([]Env_Var, len(entries), allocator)
		for entry, i in entries {
			if split := strings.index_byte(entry, '='); split >= 0 {
				env.vars[i] = Env_Var {
					name  = strings.clone(entry[:split], allocator) or_else "",
					value = strings.clone(entry[split + 1:], allocator) or_else "",
				}
			} else {
				env.vars[i] = Env_Var{name = strings.clone(entry, allocator) or_else ""}
			}
		}
	}
	return env
}

// DEFAULT_COLORS is what httpie reports when curses cannot say how many colours
// the terminal has (httpie/context.py: `colors` starts at 256 and a failed
// `setupterm` leaves it there).
DEFAULT_COLORS :: 256

// colors_from_env mirrors Environment.colors: the number of colours the
// terminal supports, as curses' `tigetnum('colors')` would report it.
//
// The real implementation asks terminfo. This is the same question answered
// from $TERM, which is what terminfo looks up first: the `-256color`, `direct`
// and `truecolor` families report 256, the classic eight-colour terminal
// descriptions report 8, and anything terminfo does not know keeps httpie's
// default. Nothing here consults NO_COLOR: in httpie that forces the *style*,
// never the colour count.
colors_from_env :: proc(env: Env_Info) -> int {
	term, found := env_get(env, "TERM")
	if !found || term == "" {
		// No TERM at all: curses fails and the 256 default stands.
		return DEFAULT_COLORS
	}
	if strings.contains(term, "256") ||
	   strings.contains(term, "direct") ||
	   strings.contains(term, "truecolor") {
		return 256
	}
	for family in EIGHT_COLOR_TERMS {
		if strings.has_prefix(term, family) {
			return 8
		}
	}
	return DEFAULT_COLORS
}

// EIGHT_COLOR_TERMS are the terminal descriptions whose terminfo entry reports
// eight colours.
@(private)
EIGHT_COLOR_TERMS := [?]string{
	"xterm",
	"screen",
	"tmux",
	"linux",
	"vt100",
	"vt220",
	"rxvt",
	"ansi",
	"cygwin",
	"cons",
	"dtterm",
	"st",
}

// program_name_of is os.path.basename(argv[0]): the name the binary was invoked
// as, which selects the default URL scheme and appears in the usage text. The
// returned string is a view into argv; nothing is allocated.
program_name_of :: proc(argv: []string) -> string {
	if len(argv) == 0 || argv[0] == "" {
		return "oj"
	}
	name := argv[0]
	if slash := strings.last_index_byte(name, '/'); slash >= 0 {
		name = name[slash + 1:]
	}
	return name == "" ? "oj" : name
}

Auth_Type :: enum {
	Basic,
	Digest,
	Bearer,
}

// Pretty is httpie's --pretty. Auto is the tty-sensitive default: `all` on a
// terminal, `none` otherwise (docs/PARITY.md §4.2).
Pretty :: enum {
	Auto,
	All,
	Colors,
	Format,
	None,
}

Print_Kind :: enum {
	Request_Headers, // H
	Request_Body, // B
	Response_Headers, // h
	Response_Body, // b
	Response_Meta, // m
}

Print_Set :: bit_set[Print_Kind]

// Format_Options is the resolved --format-options state. httpie starts from
// DEFAULT_FORMAT_OPTIONS and applies every section.key:value on top, left to
// right (docs/PARITY.md §4.2).
Format_Options :: struct {
	headers_sort:   bool,
	json_format:    bool,
	json_indent:    int, // json.dumps(indent=…); the reference type is int, default 4
	json_sort_keys: bool,
	xml_format:     bool,
	xml_indent:     int,
}

format_options_default :: proc() -> Format_Options {
	return {
		headers_sort   = true,
		json_format    = true,
		json_indent    = 4,
		json_sort_keys = true,
		xml_format     = true,
		xml_indent     = 2,
	}
}

// Meta_Action identifies which of argparse's three "print something and exit"
// actions fired, and which one came *first* on the command line. argparse runs
// those actions while it scans argv, so the left-most one wins and the rest of
// argv is never parsed: `http --help --version` prints the help, while
// `http --version --help` prints the version. (This port still parses the whole
// command line, so `http --help --style=nope` reports the bad choice where the
// reference prints the help — an open item in docs/PARITY.md §8.)
Meta_Action :: enum {
	None,
	Help,
	Manual,
	Version,
}

// Options is the parsed command line: the single input the session runs on.
//
// Every string and slice it owns comes from `allocator` and is released by
// options_destroy, which needs no extra argument because the struct remembers
// its allocator. Options has no useful zero value: build it with
// options_default (or through parse_args) so that the allocator and the httpie
// defaults are in place.
Options :: struct {
	allocator:    mem.Allocator,
	program_name: string,

	// The process as the parser saw it: the tty state of the three standard
	// streams and the environment. `session/` and `output/` read it for the
	// proxy variables, the config directory and the colour count.
	env:    Env_Info,
	colors: int, // 0, 8 or 256, as terminfo would report it (--style aside)

	// --default-scheme default for this program name (`https` vs `http`).
	script_scheme: http.Scheme,

	// target
	method:       http.Method,
	method_given: bool,
	// method_raw is the verb as it goes on the wire and into the request line
	// (requests uppercases it: httpie passes `args.method.lower()` but
	// PreparedRequest.prepare_method turns it back into upper case). It is what
	// makes a verb outside the nine standard ones — PROPFIND, for instance —
	// possible at all, since http.Method has no room for it.
	method_raw: string,
	url:        string,
	items:        [dynamic]string, // raw request items, in command-line order
	item_set:     Item_Set, // parsed form of `items`

	// body
	body_kind: Body_Kind,
	// json_given is httpie's `args.json`: true only when --json/-j was asked
	// for. Body_Kind cannot carry it, because Body_Kind.JSON is also the
	// default when no request type was given at all — and the two differ in
	// the headers: only an explicit --json adds the JSON Content-Type to a
	// request that has no body (client.py:263-278).
	json_given: bool,
	raw_body:  string,
	boundary:  string,
	compress:  int, // --compress is a counter: -xx forces compression
	chunked:   bool,

	// transport
	default_scheme: Maybe(http.Scheme), // --default-scheme; nil: httpie's heuristic
	timeout_s:      f64,
	timeout_given:  bool,
	follow:         bool,
	max_redirects:  int,
	verify:         string, // "" = the httpie default ("yes"); else no/false/yes/true/<path>
	// ciphers is `--ciphers`: OpenSSL's cipher-list grammar (or a TLS 1.3
	// ciphersuite list). It is owned here and handed to the transport, which
	// applies it with CURLOPT_SSL_CIPHER_LIST.
	ciphers:        string,
	proxy:          [dynamic]string, // --proxy, repeatable
	cert:           string,
	cert_key:       string,
	cert_key_pass:  string,
	path_as_is:     bool,
	max_headers:    int,

	// auth
	auth:         string,
	auth_type:    Auth_Type,
	ignore_netrc: bool,

	// output
	print:               Print_Set,
	print_given:         bool,
	print_history:       Print_Set,
	print_history_given: bool,
	verbose:             int, // -v is a counter: -vv adds the metadata block
	quiet:               int, // -q is a counter
	all:                 bool,
	pretty:              Pretty,
	pretty_given:        bool,
	style:               string, // --style; "" means auto
	style_given:         bool,
	format_options:      Format_Options,
	response_charset:    string,
	response_mime:       string,
	stream:              bool, // --stream/-S
	output_file:         string,
	download:            bool,
	download_resume:     bool,
	check_status:        bool,

	// modes
	offline:       bool,
	ignore_stdin:  bool,
	stdin_is_tty:  bool,

	// The argparse actions that print something and exit. The booleans are what
	// the session checks; meta_action is the *left-most* of them in argv order,
	// which is the one argparse would have fired: its actions run while the
	// command line is scanned, so the first one matched ends the process
	// (cli/utils.py's Manual, argparse's own Help/Version).
	show_help:     bool,
	show_manual:   bool,
	show_version:  bool,
	meta_action:   Meta_Action,
	show_debug:    bool,
	show_traceback: bool,

	// sessions
	session:           string,
	session_read_only: string,
}

// httpie's defaults. Anything that turns out to differ is a docs/PARITY.md
// question, not a preference: change it there first, then here.
DEFAULT_MAX_REDIRECTS :: 30

// options_default builds the option set httpie starts from, given the program
// name the binary was invoked as (the name selects the default URL scheme and
// appears in the usage text).
options_default :: proc(allocator: mem.Allocator, program_name: string) -> Options {
	opts := Options {
		allocator      = allocator,
		script_scheme  = .HTTP,
		method         = .GET,
		body_kind      = .JSON,
		max_redirects  = DEFAULT_MAX_REDIRECTS,
		auth_type      = .Basic,
		pretty         = .Auto,
		colors         = DEFAULT_COLORS,
		format_options = format_options_default(),
		items          = make([dynamic]string, allocator),
		proxy          = make([dynamic]string, allocator),
		item_set       = item_set_create(allocator),
	}
	name := strings.clone(program_name, allocator) or_else ""
	opts.program_name = name
	// `https` (and `oj-https`) defaults to https://, `http` to http://.
	if strings.has_suffix(program_name, "https") {
		opts.script_scheme = .HTTPS
	}
	return opts
}

// options_destroy releases everything the Options owns and zeroes it. Calling
// it on the result of a failed parse is safe; calling it twice is safe.
options_destroy :: proc(opts: ^Options) {
	if opts == nil {
		return
	}
	for item in opts.items {
		delete(item, opts.allocator)
	}
	delete(opts.items)
	// Each --proxy entry is its own clone (parse.odin's append_owned), so the
	// array is not enough: freeing only the array leaked every entry the
	// session did not select (39 bytes with two --proxy flags). The Request
	// borrows the selected entry; Options owns all of them (ARCHITECTURE §4).
	for entry in opts.proxy {
		delete(entry, opts.allocator)
	}
	delete(opts.proxy)
	item_set_destroy(&opts.item_set)
	delete(opts.program_name, opts.allocator)
	delete(opts.method_raw, opts.allocator)
	delete(opts.url, opts.allocator)
	delete(opts.raw_body, opts.allocator)
	delete(opts.boundary, opts.allocator)
	delete(opts.verify, opts.allocator)
	delete(opts.ciphers, opts.allocator)
	delete(opts.cert, opts.allocator)
	delete(opts.cert_key, opts.allocator)
	delete(opts.cert_key_pass, opts.allocator)
	delete(opts.auth, opts.allocator)
	delete(opts.style, opts.allocator)
	delete(opts.response_charset, opts.allocator)
	delete(opts.response_mime, opts.allocator)
	delete(opts.output_file, opts.allocator)
	delete(opts.session, opts.allocator)
	delete(opts.session_read_only, opts.allocator)
	env_info_destroy(&opts.env, opts.allocator)
	opts^ = {}
}

// print_set_default is httpie's tty-sensitive --print default
// (docs/PARITY.md §4.1): `b` when stdout is not a tty, `hb` on a terminal,
// `HB` in --offline mode regardless of the tty.
print_set_default :: proc(stdout_is_tty: bool, offline: bool) -> Print_Set {
	if offline {
		return {.Request_Headers, .Request_Body}
	}
	if stdout_is_tty {
		return {.Response_Headers, .Response_Body}
	}
	return {.Response_Body}
}
