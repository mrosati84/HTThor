// The command-line parser: argv in, Options out.
//
// The grammar is httpie 3.2.4's, which is argparse's with a good deal of extra
// processing on top. The parser is written as that same two-stage pipeline, so
// every stage can be checked against the reference source:
//
//  1. the scan (CPython argparse's `_parse_known_args`): each arg string is
//     classified as an option, an ordinary argument or a bare `--`; the
//     ordinary ones are matched against the positional specs ([METHOD] URL
//     [REQUEST_ITEM ...]) by backtracking over their nargs patterns; options
//     take their value from the same arg string (`-pvalue`, `--print=value`) or
//     from the following arg strings. Unambiguous long-option abbreviations and
//     short-option clustering (`-vv`, `-phb`) fall out of argparse's
//     `_get_option_tuples`.
//  2. httpie's own processing (httpie/cli/argparser.py:151-620), in the
//     reference's order: `--no-OPTION` resets, the download/continue rules, the
//     print-set rules, `--pretty`, `--format-options`, the method guess, the
//     request items and the body-source checks.
//
// Failures reproduce argparse's wording ("argument --timeout: invalid float
// value: 'abc'") in `Parse_Error.message`, ready for usage_error_text
// (src/cli/usage.odin). The exit code is Exit_Code.Error = 1, not argparse's 2
// (see the note in options.odin).
//
// The config file is part of stage one: `default_options` from
// `$HTTPIE_CONFIG_DIR/config.json` (or the httpie config directory) are
// *prepended* to argv (httpie/core.py:48-49), so a command-line option wins by
// coming later, and the repeated-option rules above then apply to the combined
// list.
//
// Deliberate deviations, all outside the captured scenarios:
//   * `http://host item` style URL qualification stays in src/http/url.odin, so
//     Options.url is the argument as written rather than the qualified URL.
//   * Options.method is src:http's enum, which has no room for a method outside
//     the nine standard verbs; an unknown method keeps the default verb.
//   * `--auth` is stored, not resolved: netrc lookup and the "prompt for the
//     password" path (httpie/cli/argparser.py:278-350) belong to the session.
//   * Environment.colors is derived from $TERM instead of asking terminfo.
package cli

import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "src:format"
import "src:http"

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

Parse_Error_Kind :: enum {
	None,
	Usage,
	// Exception is the one failure the reference raises *outside* its own error
	// handling: `--raw`'s body is encoded while the arguments are parsed
	// (argparser.py:183 -> :397 `data.encode()`), so a body byte the argv decode
	// turned into a lone surrogate ends the run with an uncaught
	// `UnicodeEncodeError` — rc 1, nothing on stdout, nothing sent, and no
	// `usage:` block (docs/PARITY.md §3.6). `message` is the exception's own
	// text, the line the reference's traceback ends with; main.odin prints it as
	// the `http: error:` line the reference would have printed had the handler
	// caught it, and §8.20 records the traceback's frames as not reproduced.
	Exception,
}

// Parse_Error is what main.odin hands to usage_error_text. `message` is the
// bare, unwrapped text that goes after the `error:` line's four-space indent:
// "argument --timeout: invalid float value: 'abc'", "the following arguments
// are required: URL", "cannot combine --compress and --chunked". It is an owned
// copy; parse_error_destroy releases it through the remembered allocator.
//
// `width` is the console width that block is wrapped to (rich's Console.size:
// `$COLUMNS` when it holds digits, else 80) — decided here, while the
// run's environment is in hand, because the block is rendered by main.odin after
// this struct has left the parser and the partial Options it was built from have
// been released. It is `console_width(env)`; a width of zero is not a fallback
// but a console that renders nothing (`console_silent`), and
// Parse_Error_Kind.Exception never
// reaches the block, so for that kind it is only what the same env said.
Parse_Error :: struct {
	allocator: mem.Allocator,
	kind:      Parse_Error_Kind,
	message:   string,
	width:     int,
}

// parse_error_destroy releases the message and zeroes the error. Calling it on
// a zero error, or twice, is safe.
parse_error_destroy :: proc(err: ^Parse_Error) {
	if err == nil {
		return
	}
	delete(err.message, err.allocator)
	err^ = {}
}

// usage_error wraps an already-rendered message (argparse's `ArgumentError`
// string, or a bare sentence from httpie's own checks). `width` is the console
// width the usage block is wrapped to (Parse_Error.width).
@(private)
usage_error :: proc(allocator: mem.Allocator, message: string, width: int) -> Parse_Error {
	return Parse_Error {
		allocator = allocator,
		kind = .Usage,
		message = message,
		width = width,
	}
}

// exception_error wraps the text of an exception the reference never catches
// (Parse_Error_Kind.Exception). The message is already rendered — it is
// CPython's `UnicodeEncodeError: …` line, which http.str_encode_error_message
// builds — and is not a usage block: main.odin writes it through the `error:`
// log line instead (src/output/render.odin's write_log_error).
@(private)
exception_error :: proc(allocator: mem.Allocator, message: string) -> Parse_Error {
	return Parse_Error {
		allocator = allocator,
		kind = .Exception,
		message = message,
	}
}

// argument_message is argparse's `ArgumentError(action, body)` text: "argument
// <name>: <body>", where <name> is '/'.join(action.option_strings).
@(private)
argument_message :: proc(allocator: mem.Allocator, action_name, body: string) -> string {
	return strings.concatenate({"argument ", action_name, ": ", body}, allocator)
}

// ---------------------------------------------------------------------------
// httpie's constants (httpie/cli/constants.py)
// ---------------------------------------------------------------------------

// BASE_OUTPUT_OPTIONS is what `-v` prints; OUTPUT_OPTIONS adds the response
// metadata block, so `-vv` prints everything. Joining a frozenset in Python
// gives an arbitrary order, but the print set is a set: the order is invisible.
BASE_OUTPUT_OPTIONS :: "BHbh"
OUTPUT_OPTIONS :: "BHbhm"

// The tty-sensitive default print sets.
OUTPUT_OPTIONS_DEFAULT :: "hb" // stdout is a terminal
OUTPUT_OPTIONS_DEFAULT_STDOUT_REDIRECTED :: "b"
OUTPUT_OPTIONS_DEFAULT_OFFLINE :: "HB" // --offline ignores stdout

// `--sorted`/`--unsorted` are sugar for these --format-options groups;
// `--no-sorted`/`--no-unsorted` append the inverted one
// (httpie/cli/definition.py:318-346). They accumulate, so the last one wins.
SORTED_FORMAT_OPTIONS_STRING :: "headers.sort:true,json.sort_keys:true"
UNSORTED_FORMAT_OPTIONS_STRING :: "headers.sort:false,json.sort_keys:false"

// DATA_SEPARATORS is SEPARATOR_GROUP_DATA_ITEMS: the items that count as request
// data when the method is guessed and when the body-source rules run.
DATA_SEPARATORS :: bit_set[Sep] {
	.Data_String,
	.Data_Embed_File,
	.Data_Raw_JSON,
	.Data_Raw_JSON_File,
}

// The messages httpie's own checks raise verbatim.
MESSAGE_COMPRESS_CHUNKED :: "cannot combine --compress and --chunked"
MESSAGE_COMPRESS_MULTIPART :: "cannot combine --compress and --multipart"
MESSAGE_CONTINUE_WITHOUT_DOWNLOAD :: "--continue only works with --download"
MESSAGE_CONTINUE_WITHOUT_OUTPUT :: "--continue requires --output to be specified"
MESSAGE_SESSION_NAME :: "Session name contains invalid characters."

// ---------------------------------------------------------------------------
// The option table (httpie/cli/definition.py, in add_argument order)
// ---------------------------------------------------------------------------

// Option_Action mirrors the argparse Action classes httpie uses.
@(private)
Option_Action :: enum {
	Store, // one argument, converted and stored
	Store_Const, // no argument; stores a constant
	Store_True, // no argument; stores true
	Count, // no argument; increments (repeatable)
	Append, // one argument, appended to a list
	Append_Const, // no argument; appends a constant (--sorted and friends)
	Help, // --help
	Manual, // --manual
	Version, // --version
}

// Option_Type is the argparse `type=` callable.
@(private)
Option_Type :: enum {
	Str, // no type: the value is used as it stands
	Int, // int
	Float, // float
	Charset, // response_charset_type
	Mime, // response_mime_type
	Session_Name, // SessionNameValidator
	Readable_File, // readable_file_arg
	Output_File, // argparse.FileType('ab')
	Ssl_Credentials, // SSLCredentials
}

// Option_Nargs is argparse's nargs; `One` is Python's None (exactly one).
@(private)
Option_Nargs :: enum {
	One,
	Zero,
}

// Option_Const is the `const=` of the no-argument actions.
@(private)
Option_Const :: enum {
	None,
	Request_JSON,
	Request_Form,
	Request_Multipart,
	Print_Headers, // 'h': response headers
	Print_Body, // 'b': response body
	Print_Meta, // 'm': response metadata
	Format_Sorted,
	Format_Unsorted,
}

// Dest is the `dest=` of the reference's add_argument call, spelled as a type
// so the compiler checks it.
@(private)
Dest :: enum {
	Request_Type,
	Boundary,
	Raw,
	Compress,
	Prettify,
	Style,
	Format_Options,
	Response_Charset,
	Response_Mime,
	Output_Options,
	Output_Options_History,
	Output_File,
	Download,
	Download_Resume,
	Quiet,
	Verbose,
	All,
	Stream,
	Session,
	Session_Read_Only,
	Auth,
	Auth_Type,
	Ignore_Netrc,
	Offline,
	Proxy,
	Follow,
	Max_Redirects,
	Max_Headers,
	Timeout,
	Check_Status,
	Path_As_Is,
	Chunked,
	Verify,
	Ssl_Version,
	Ciphers,
	Cert,
	Cert_Key,
	Cert_Key_Pass,
	Ignore_Stdin,
	Help,
	Manual,
	Version,
	Traceback,
	Default_Scheme,
	Debug,
}

// Option_Spec is one add_argument call. `names` is in the reference's order
// (long form first): it is what argparse reports as the action's name, and the
// order the table is searched in for abbreviations and clusters.
@(private)
Option_Spec :: struct {
	names:    []string,
	dest:     Dest,
	action:   Option_Action,
	arg_type: Option_Type,
	nargs:    Option_Nargs,
	choices:  []string, // for the choice error; empty when the type carries them
	const:    Option_Const,
}

// OPTION_SPECS is httpie/cli/definition.py's argument table in add_argument
// order. The order is what argparse's insertion-ordered option dictionary gives
// us: it decides the order of the ambiguous-option report and the order the
// abbreviation search visits candidates, and nothing else.
@(private)
OPTION_SPECS := [?]Option_Spec{
	// Predefined content types
	{names = []string{"--json", "-j"}, dest = .Request_Type, action = .Store_Const, nargs = .Zero, const = .Request_JSON},
	{names = []string{"--form", "-f"}, dest = .Request_Type, action = .Store_Const, nargs = .Zero, const = .Request_Form},
	{names = []string{"--multipart"}, dest = .Request_Type, action = .Store_Const, nargs = .Zero, const = .Request_Multipart},
	{names = []string{"--boundary"}, dest = .Boundary, action = .Store, nargs = .One, arg_type = .Str},
	{names = []string{"--raw"}, dest = .Raw, action = .Store, nargs = .One, arg_type = .Str},
	{names = []string{"--compress", "-x"}, dest = .Compress, action = .Count, nargs = .Zero},
	// Content processing
	{names = []string{"--pretty"}, dest = .Prettify, action = .Store, nargs = .One, arg_type = .Str, choices = PRETTY_CHOICES[:]},
	{names = []string{"--style", "-s"}, dest = .Style, action = .Store, nargs = .One, arg_type = .Str},
	{names = []string{"--no-unsorted"}, dest = .Format_Options, action = .Append_Const, nargs = .Zero, const = .Format_Sorted},
	{names = []string{"--no-sorted"}, dest = .Format_Options, action = .Append_Const, nargs = .Zero, const = .Format_Unsorted},
	{names = []string{"--unsorted"}, dest = .Format_Options, action = .Append_Const, nargs = .Zero, const = .Format_Unsorted},
	{names = []string{"--sorted"}, dest = .Format_Options, action = .Append_Const, nargs = .Zero, const = .Format_Sorted},
	{names = []string{"--response-charset"}, dest = .Response_Charset, action = .Store, nargs = .One, arg_type = .Charset},
	{names = []string{"--response-mime"}, dest = .Response_Mime, action = .Store, nargs = .One, arg_type = .Mime},
	{names = []string{"--format-options"}, dest = .Format_Options, action = .Append, nargs = .One, arg_type = .Str},
	// Output options
	{names = []string{"--print", "-p"}, dest = .Output_Options, action = .Store, nargs = .One, arg_type = .Str},
	{names = []string{"--headers", "-h"}, dest = .Output_Options, action = .Store_Const, nargs = .Zero, const = .Print_Headers},
	{names = []string{"--meta", "-m"}, dest = .Output_Options, action = .Store_Const, nargs = .Zero, const = .Print_Meta},
	{names = []string{"--body", "-b"}, dest = .Output_Options, action = .Store_Const, nargs = .Zero, const = .Print_Body},
	{names = []string{"--verbose", "-v"}, dest = .Verbose, action = .Count, nargs = .Zero},
	{names = []string{"--all"}, dest = .All, action = .Store_True, nargs = .Zero},
	{names = []string{"--history-print", "-P"}, dest = .Output_Options_History, action = .Store, nargs = .One, arg_type = .Str},
	{names = []string{"--stream", "-S"}, dest = .Stream, action = .Store_True, nargs = .Zero},
	{names = []string{"--output", "-o"}, dest = .Output_File, action = .Store, nargs = .One, arg_type = .Output_File},
	{names = []string{"--download", "-d"}, dest = .Download, action = .Store_True, nargs = .Zero},
	{names = []string{"--continue", "-c"}, dest = .Download_Resume, action = .Store_True, nargs = .Zero},
	{names = []string{"--quiet", "-q"}, dest = .Quiet, action = .Count, nargs = .Zero},
	// Sessions
	{names = []string{"--session"}, dest = .Session, action = .Store, nargs = .One, arg_type = .Session_Name},
	{names = []string{"--session-read-only"}, dest = .Session_Read_Only, action = .Store, nargs = .One, arg_type = .Session_Name},
	// Authentication
	{names = []string{"--auth", "-a"}, dest = .Auth, action = .Store, nargs = .One, arg_type = .Str},
	{names = []string{"--auth-type", "-A"}, dest = .Auth_Type, action = .Store, nargs = .One, arg_type = .Str, choices = AUTH_TYPE_CHOICES_SORTED[:]},
	{names = []string{"--ignore-netrc"}, dest = .Ignore_Netrc, action = .Store_True, nargs = .Zero},
	// Network
	{names = []string{"--offline"}, dest = .Offline, action = .Store_True, nargs = .Zero},
	{names = []string{"--proxy"}, dest = .Proxy, action = .Append, nargs = .One, arg_type = .Str},
	{names = []string{"--follow", "-F"}, dest = .Follow, action = .Store_True, nargs = .Zero},
	{names = []string{"--max-redirects"}, dest = .Max_Redirects, action = .Store, nargs = .One, arg_type = .Int},
	{names = []string{"--max-headers"}, dest = .Max_Headers, action = .Store, nargs = .One, arg_type = .Int},
	{names = []string{"--timeout"}, dest = .Timeout, action = .Store, nargs = .One, arg_type = .Float},
	{names = []string{"--check-status"}, dest = .Check_Status, action = .Store_True, nargs = .Zero},
	{names = []string{"--path-as-is"}, dest = .Path_As_Is, action = .Store_True, nargs = .Zero},
	{names = []string{"--chunked"}, dest = .Chunked, action = .Store_True, nargs = .Zero},
	{names = []string{"--verify"}, dest = .Verify, action = .Store, nargs = .One, arg_type = .Str},
	// SSL
	{names = []string{"--ssl"}, dest = .Ssl_Version, action = .Store, nargs = .One, arg_type = .Str, choices = SSL_VERSION_CHOICES[:]},
	{names = []string{"--ciphers"}, dest = .Ciphers, action = .Store, nargs = .One, arg_type = .Str},
	{names = []string{"--cert"}, dest = .Cert, action = .Store, nargs = .One, arg_type = .Readable_File},
	{names = []string{"--cert-key"}, dest = .Cert_Key, action = .Store, nargs = .One, arg_type = .Readable_File},
	{names = []string{"--cert-key-pass"}, dest = .Cert_Key_Pass, action = .Store, nargs = .One, arg_type = .Ssl_Credentials},
	{names = []string{"--ignore-stdin", "-I"}, dest = .Ignore_Stdin, action = .Store_True, nargs = .Zero},
	// Troubleshooting
	{names = []string{"--help"}, dest = .Help, action = .Help, nargs = .Zero},
	{names = []string{"--manual"}, dest = .Manual, action = .Manual, nargs = .Zero},
	{names = []string{"--version"}, dest = .Version, action = .Version, nargs = .Zero},
	{names = []string{"--traceback"}, dest = .Traceback, action = .Store_True, nargs = .Zero},
	{names = []string{"--default-scheme"}, dest = .Default_Scheme, action = .Store, nargs = .One, arg_type = .Str},
	{names = []string{"--debug"}, dest = .Debug, action = .Store_True, nargs = .Zero},
}

@(private)
N_OPTION_SPECS :: len(OPTION_SPECS)

// The session options sit in one mutually exclusive group
// (httpie/cli/definition.py:587); nothing else in the spec does.
@(private)
SESSION_ACTION :: 28
@(private)
SESSION_READ_ONLY_ACTION :: 29

@(private)
option_action_name :: proc(spec: Option_Spec, allocator: mem.Allocator) -> string {
	return strings.join(spec.names, "/", allocator)
}

// find_option is argparse's `_option_string_actions[arg_string]` lookup, walked
// in insertion order, which is what makes abbreviation and cluster resolution
// deterministic.
@(private)
find_option :: proc(name: string) -> (index: int, found: bool) {
	for spec, i in OPTION_SPECS {
		for candidate in spec.names {
			if candidate == name {
				return i, true
			}
		}
	}
	return -1, false
}

// ---------------------------------------------------------------------------
// argparse's classification of one arg string
// ---------------------------------------------------------------------------

@(private)
Arg_Kind :: enum u8 {
	Ordinary, // 'A'
	Option, // 'O'
	Dash, // '-', a bare `--`
}

@(private)
Option_Hit :: struct {
	present:      bool,
	action:       int, // -1 when the option is unknown (argparse's action=None)
	name:         string,
	sep:          string, // "=" for --flag=value, "" for a short cluster
	explicit:     string,
	has_explicit: bool,
}

// UNKNOWN_REPORTED marks a hit whose `explicit` field holds a complete message
// (the ambiguous-option error aborts the parse immediately).
@(private)
UNKNOWN_REPORTED :: -2

// parse_optional is argparse's `_parse_optional`: whether an arg string is an
// option, and how its value is attached.
@(private)
parse_optional :: proc(arg: string, allocator: mem.Allocator) -> (hit: Option_Hit, is_option: bool) {
	// "if it's an empty string, it was meant to be a positional"
	if arg == "" {
		return {}, false
	}
	// "if it doesn't start with a prefix, it was meant to be positional"
	if arg[0] != '-' {
		return {}, false
	}
	// a known option string
	if index, found := find_option(arg); found {
		return Option_Hit{present = true, action = index, name = arg}, true
	}
	// "if it's just a single character, it was meant to be positional": that is
	// '-' itself, which argparse treats as an ordinary argument.
	if len(arg) == 1 {
		return {}, false
	}
	// `--flag=value` where `--flag` is known
	if eq := strings.index_byte(arg, '='); eq >= 0 {
		if index, found := find_option(arg[:eq]); found {
			return Option_Hit {
				present = true,
				action = index,
				name = arg[:eq],
				sep = "=",
				explicit = arg[eq + 1:],
				has_explicit = true,
			}, true
		}
	}
	// unambiguous prefixes and short-option clusters
	tuples := get_option_tuples(arg, allocator)
	defer delete(tuples, allocator)
	switch len(tuples) {
	case 1:
		return tuples[0], true
	case 2 ..= 1000:
		// ambiguous: this is `self.error(...)`, so the message has no argument
		// name and the usage line gets no whitelist entry
		matches := strings.join(
			names_of_hits(tuples, context.temp_allocator),
			", ",
			allocator,
		)
		message := strings.concatenate(
			{"ambiguous option: ", arg, " could match ", matches},
			allocator,
		)
		return Option_Hit{present = true, action = UNKNOWN_REPORTED, explicit = message}, true
	}
	// a negative number is a positional (httpie defines no numeric options)
	if is_negative_number(arg) {
		return {}, false
	}
	// "if it contains a space, it was meant to be a positional"
	if strings.contains(arg, " ") {
		return {}, false
	}
	// an unknown option is still carried through as an option hit
	return Option_Hit{present = true, action = -1, name = arg}, true
}

@(private)
names_of_hits :: proc(hits: []Option_Hit, allocator: mem.Allocator) -> []string {
	names := make([]string, len(hits), allocator)
	for hit, i in hits {
		names[i] = hit.name
	}
	return names
}

// get_option_tuples is argparse's `_get_option_tuples`: every option string the
// arg string could be. Two prefix characters mean an abbreviation; one means a
// short option, possibly with its argument glued on (`-phb`).
@(private)
get_option_tuples :: proc(arg: string, allocator: mem.Allocator) -> []Option_Hit {
	result := make([dynamic]Option_Hit, 0, 4, allocator)
	if len(arg) < 2 || arg[0] != '-' {
		return result[:]
	}
	if arg[1] == '-' {
		prefix := arg
		sep := ""
		explicit := ""
		has_explicit := false
		if eq := strings.index_byte(arg, '='); eq >= 0 {
			prefix = arg[:eq]
			sep = "="
			explicit = arg[eq + 1:]
			has_explicit = true
		}
		for spec, i in OPTION_SPECS {
			for candidate in spec.names {
				if strings.has_prefix(candidate, prefix) {
					append(
						&result,
						Option_Hit {
							present = true,
							action = i,
							name = candidate,
							sep = sep,
							explicit = explicit,
							has_explicit = has_explicit,
						},
					)
				}
			}
		}
	} else {
		short_prefix := arg[:2]
		short_explicit := arg[2:]
		for spec, i in OPTION_SPECS {
			for candidate in spec.names {
				if candidate == short_prefix {
					append(
						&result,
						Option_Hit {
							present = true,
							action = i,
							name = candidate,
							sep = "",
							explicit = short_explicit,
							has_explicit = true,
						},
					)
				} else if strings.has_prefix(candidate, arg) {
					append(&result, Option_Hit{present = true, action = i, name = candidate})
				}
			}
		}
	}
	return result[:]
}

// is_negative_number is argparse's `_negative_number_matcher`.
@(private)
is_negative_number :: proc(arg: string) -> bool {
	if len(arg) < 2 || arg[0] != '-' {
		return false
	}
	return arg[1] >= '0' && arg[1] <= '9'
}

// ---------------------------------------------------------------------------
// The namespace (argparse's Namespace plus the flags httpie derives from it)
// ---------------------------------------------------------------------------

@(private)
Req_Type :: enum {
	Unset, // Python's None: JSON is the default
	Json,
	Form,
	Multipart,
}

@(private)
Namespace :: struct {
	allocator: mem.Allocator,

	// positionals
	method:             string,
	method_seen:        bool, // false means None: absent, or given without a value
	url:                string,
	url_seen:           bool, // the URL positional was matched (required by argparse)
	request_items:      [dynamic]string,
	request_items_seen: bool,

	// request
	request_type: Req_Type,
	boundary:     string,
	raw:          string,
	raw_set:      bool,
	compress:     int,
	chunked:      bool,
	ignore_stdin: bool,

	// output
	prettify:                   string, // "" is STDOUT_TTY_ONLY
	style:                      string,
	format_options:             [dynamic]string,
	output_options:             string,
	output_options_set:         bool,
	output_options_history:     string,
	output_options_history_set: bool,
	output_file:                string,
	output_file_set:            bool,
	response_charset:           string,
	response_mime:              string,
	verbose:                    int,
	quiet:                      int,
	all:                        bool,
	stream:                     bool,
	download:                   bool,
	download_resume:            bool,
	check_status:               bool,

	// sessions
	session:                string,
	session_seen:           bool,
	session_read_only:      string,
	session_read_only_seen: bool,

	// auth
	auth:           string,
	auth_seen:      bool,
	auth_type:      string,
	auth_type_seen: bool,
	ignore_netrc:   bool,

	// transport
	offline:            bool,
	proxy:              [dynamic]string,
	follow:             bool,
	max_redirects:      int,
	max_headers:        int,
	timeout:            f64,
	timeout_set:        bool,
	path_as_is:         bool,
	verify:             string,
	ssl_version:        string,
	ciphers:            string,
	cert:               string,
	cert_key:           string,
	cert_key_pass:      string,
	default_scheme:     string,
	default_scheme_set: bool,

	// modes
	help:      bool,
	manual:    bool,
	version:   bool,
	// The left-most of the three argparse actions that print and exit: argparse
	// fires them while it scans argv, so the first one matched wins
	// (docs/PARITY.md §8 notes the one case this port still gets differently).
	meta_action: Meta_Action,
	traceback: bool,
	debug:     bool,

	// argparse bookkeeping
	extras: [dynamic]string,
	seen:   [N_OPTION_SPECS]bool,
}

@(private)
namespace_create :: proc(allocator: mem.Allocator) -> Namespace {
	ns := Namespace {
		allocator = allocator,
		request_items = make([dynamic]string, allocator),
		format_options = make([dynamic]string, allocator),
		proxy = make([dynamic]string, allocator),
		extras = make([dynamic]string, allocator),
		// argparse's numeric defaults, straight from the spec
		max_redirects = 30,
	}
	// The string defaults are owned copies: namespace_destroy frees every string
	// field, so a literal here would be freed as well.
	set_owned(&ns.style, "auto", allocator)
	set_owned(&ns.verify, "yes", allocator)
	set_owned(&ns.default_scheme, "http", allocator)
	return ns
}

@(private)
namespace_destroy :: proc(ns: ^Namespace) {
	if ns == nil {
		return
	}
	a := ns.allocator
	for field in ([]string {
		ns.method,
		ns.url,
		ns.boundary,
		ns.raw,
		ns.prettify,
		ns.style,
		ns.output_options,
		ns.output_options_history,
		ns.output_file,
		ns.response_charset,
		ns.response_mime,
		ns.session,
		ns.session_read_only,
		ns.auth,
		ns.auth_type,
		ns.verify,
		ns.ssl_version,
		ns.ciphers,
		ns.cert,
		ns.cert_key,
		ns.cert_key_pass,
		ns.default_scheme,
	}) {
		delete(field, a)
	}
	for item in ns.request_items {
		delete(item, a)
	}
	for option in ns.format_options {
		delete(option, a)
	}
	for entry in ns.proxy {
		delete(entry, a)
	}
	for extra in ns.extras {
		delete(extra, a)
	}
	delete(ns.request_items)
	delete(ns.format_options)
	delete(ns.proxy)
	delete(ns.extras)
	ns^ = {}
}

// set_owned replaces an owned string field, releasing the previous value.
@(private)
set_owned :: proc(field: ^string, value: string, allocator: mem.Allocator) -> bool {
	clone, err := strings.clone(value, allocator)
	if err != .None {
		return false
	}
	delete(field^, allocator)
	field^ = clone
	return true
}

// append_owned appends a copy of `value` to a dynamic string list.
@(private)
append_owned :: proc(list: ^[dynamic]string, value: string, allocator: mem.Allocator) -> bool {
	clone, err := strings.clone(value, allocator)
	if err != .None {
		return false
	}
	append(list, clone)
	return true
}

// ---------------------------------------------------------------------------
// The scan (argparse's _parse_known_args)
// ---------------------------------------------------------------------------

@(private)
Parser :: struct {
	allocator:   mem.Allocator,
	env:         Env_Info,
	ns:          ^Namespace,
	arg_strings: []string,
	pattern:     []Arg_Kind,
	hits:        []Option_Hit,
	// exception says the message `process` returned is an exception the
	// reference never catches rather than a usage error: parse_args_with wraps
	// it with exception_error instead of usage_error (Parse_Error_Kind).
	exception: bool,
	// config_item/config_item_type are the `default_options` element that is not
	// a string, if the config file had one: `_guess_method` is where the
	// reference first meets it (Config_Read.item).
	config_item:      Config_Item,
	config_item_type: string,
}

@(private)
Pos_Kind :: enum {
	Method,
	URL,
	Request_Items,
}

@(private)
POSITIONALS := [?]Pos_Kind{.Method, .URL, .Request_Items}

// skip_dashes is the `-*` at the start of argparse's nargs patterns: the bare
// `--` entries a positional may step over.
@(private)
skip_dashes :: proc(pattern: []Arg_Kind, from: int) -> int {
	i := from
	for i < len(pattern) && pattern[i] == .Dash {
		i += 1
	}
	return i
}

// match_group enumerates the positions one positional's nargs pattern can end
// at, in the order Python's regex engine backtracks through them (greedy
// quantifiers first, each `-*` starting from its longest run).
@(private)
match_group :: proc(kind: Pos_Kind, pattern: []Arg_Kind, from: int, ends: ^[dynamic]int) {
	lead_max := skip_dashes(pattern, from) - from
	lead := lead_max
	for {
		base := from + lead
		switch kind {
		case .Method: // (-*A?-*)
			for step in 0 ..= 1 {
				take := 1 - step
				if take == 1 && !(base < len(pattern) && pattern[base] == .Ordinary) {
					continue
				}
				after := base + take
				trail_max := skip_dashes(pattern, after) - after
				for trail := trail_max; trail >= 0; trail -= 1 {
					append(ends, after + trail)
				}
			}
		case .URL: // (-*A-*)
			if base < len(pattern) && pattern[base] == .Ordinary {
				after := base + 1
				trail_max := skip_dashes(pattern, after) - after
				for trail := trail_max; trail >= 0; trail -= 1 {
					append(ends, after + trail)
				}
			}
		case .Request_Items: // (-*[A-]*)
			after := base
			for after < len(pattern) && pattern[after] != .Option {
				after += 1
			}
			append(ends, after)
		}
		if lead == 0 {
			break
		}
		lead -= 1
	}
}

// match_positionals is `_match_arguments_partial`: the longest prefix of the
// remaining positionals that can match wins, and each group's length counts the
// `--` entries it stepped over (`_get_values` then drops the first one).
@(private)
match_positionals :: proc(
	remaining: []Pos_Kind,
	pattern: []Arg_Kind,
	from: int,
	counts: ^[3]int,
	at: int,
) -> bool {
	if at == len(remaining) {
		return true
	}
	ends := make([dynamic]int, 0, 8, context.temp_allocator)
	defer delete(ends)
	match_group(remaining[at], pattern, from, &ends)
	for end in ends {
		if match_positionals(remaining, pattern, end, counts, at + 1) {
			counts[at] = end - from
			return true
		}
	}
	return false
}

// match_nargs is `_match_argument`: how many arg strings an option consumes.
// argparse strips '-' out of an option's pattern, so a bare `--` is never
// consumed by one.
@(private)
match_nargs :: proc(nargs: Option_Nargs, pattern: []Arg_Kind, from: int) -> (count: int, ok: bool) {
	switch nargs {
	case .Zero:
		return 0, true
	case .One:
		if from < len(pattern) && pattern[from] == .Ordinary {
			return 1, true
		}
		return 0, false
	}
	return 0, false
}

// match_explicit is `_match_argument(action, 'A')`: the check against the
// literal one-argument pattern, used when the value came glued to the option.
@(private)
match_explicit :: proc(nargs: Option_Nargs) -> (count: int, ok: bool) {
	switch nargs {
	case .Zero:
		return 0, true
	case .One:
		return 1, true
	}
	return 0, false
}

@(private)
nargs_error_message :: proc(nargs: Option_Nargs) -> string {
	#partial switch nargs {
	case .Zero:
		return "expected 0 argument(s)"
	}
	return "expected one argument"
}

// without_first_double_dash is the `arg_strings.remove('--')` at the top of
// `_get_values`: positional arguments only, and only the first one.
@(private)
without_first_double_dash :: proc(
	args: []string,
	allocator: mem.Allocator,
) -> (out: []string, allocated: bool) {
	for arg, i in args {
		if arg == "--" {
			rest := make([]string, len(args) - 1, allocator)
			copy(rest[:i], args[:i])
			copy(rest[i:], args[i + 1:])
			return rest, true
		}
	}
	return args, false
}

// scan walks argv the way `_parse_known_args` does and returns "" or an owned
// usage message.
@(private)
scan :: proc(p: ^Parser) -> string {
	arg_strings := p.arg_strings
	ns := p.ns
	allocator := p.allocator

	p.pattern = make([]Arg_Kind, len(arg_strings), allocator)
	p.hits = make([]Option_Hit, len(arg_strings), allocator)
	option_indices := make([dynamic]int, allocator)
	defer delete(option_indices)

	dash := false
	for arg, i in arg_strings {
		if arg == "--" && !dash {
			// "all args after -- are non-options" (_parse_known_args)
			p.pattern[i] = .Dash
			dash = true
			continue
		}
		kind := Arg_Kind.Ordinary
		if !dash && strings.has_prefix(arg, "-") && arg != "-" {
			hit, is_option := parse_optional(arg, allocator)
			if is_option {
				if hit.action == UNKNOWN_REPORTED {
					// the ambiguous-option error ends the parse here
					return hit.explicit
				}
				p.hits[i] = hit
				append(&option_indices, i)
				kind = .Option
			}
		}
		p.pattern[i] = kind
	}

	max_option_index := -1
	if len(option_indices) > 0 {
		max_option_index = option_indices[len(option_indices) - 1]
	}

	taken_positionals := 0
	start_index := 0
	for start_index <= max_option_index {
		next_option := -1
		for index in option_indices {
			if index >= start_index {
				next_option = index
				break
			}
		}
		// consume the positionals that precede the next option
		if start_index != next_option {
			end, message := consume_positionals(p, start_index, &taken_positionals)
			if message != "" {
				return message
			}
			if end > start_index {
				start_index = end
				continue
			}
			start_index = end
		}
		// arg strings no positional could take are extras
		if !(start_index < len(p.hits) && p.hits[start_index].present) {
			for index := start_index; index < next_option; index += 1 {
				if !append_owned(&ns.extras, arg_strings[index], allocator) {
					return strings.clone("not enough memory", allocator) or_else ""
				}
			}
			start_index = next_option
		}
		stop, message := consume_optional(p, start_index)
		if message != "" {
			return message
		}
		// A print-and-exit action ends the walk where argparse meets it: the
		// help, manual and version actions call `parser.exit()` from
		// `take_action`, so no argument after it is even looked at — not the
		// extras check that closes the walk below, and not the option values
		// that would be converted after it (measured: `http --help
		// --pretty=bogus` prints the help, rc 0, while `http --pretty=bogus
		// --help` still reports the option error, because that argument comes
		// first). parse_args_with writes the text.
		if ns.meta_action != .None {
			return ""
		}
		start_index = stop
	}

	end, message := consume_positionals(p, start_index, &taken_positionals)
	if message != "" {
		return message
	}
	for index := end; index < len(arg_strings); index += 1 {
		if !append_owned(&ns.extras, arg_strings[index], allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	}

	// the required-actions check argparse runs before it returns. `--help`,
	// `--manual` and `--version` are argparse actions that fire while argv is
	// being scanned, so they have already exited (successfully) by the time
	// anything could complain that the URL is missing.
	if !ns.url_seen && !ns.help && !ns.manual && !ns.version {
		return strings.clone("the following arguments are required: URL", allocator) or_else ""
	}
	return ""
}

// consume_positionals is argparse's closure of the same name.
@(private)
consume_positionals :: proc(
	p: ^Parser,
	start_index: int,
	taken: ^int,
) -> (end_index: int, message: string) {
	remaining := POSITIONALS[taken^:]
	for count := len(remaining); count >= 1; count -= 1 {
		counts: [3]int
		if !match_positionals(remaining[:count], p.pattern, start_index, &counts, 0) {
			continue
		}
		index := start_index
		for kind, i in remaining[:count] {
			arg_count := counts[i]
			args := p.arg_strings[index:index + arg_count]
			index += arg_count
			if msg := apply_positional(p, kind, args); msg != "" {
				return index, msg
			}
		}
		taken^ += count
		return index, ""
	}
	return start_index, ""
}

// consume_optional is argparse's closure of the same name, including the
// short-option clustering loop that turns `-phb` into `-p hb` and `-vv` into
// two `-v`s.
@(private)
consume_optional :: proc(p: ^Parser, start_index: int) -> (stop: int, message: string) {
	ns := p.ns
	allocator := p.allocator
	hit := p.hits[start_index]

	pending_actions := make([dynamic]int, 0, 2, allocator)
	defer delete(pending_actions)
	pending_names := make([dynamic]string, 0, 2, allocator)
	defer delete(pending_names)
	// The clustering loop below rewrites `option_string` to a glued clone built
	// from the name's leading dash and the tail's next letter (`-vv` -> the name
	// `-v` with the tail `v`). From there on the rewritten name is only borrowed
	// — it is what `option_string[1] != '-'` inspects and what `pending_names`
	// hands to apply_action, which ignores it — so the clones are collected here
	// and released on the way out instead of leaking one block per cluster step.
	// The loop's `not found` branch is the exception: it hands its clone to
	// `ns.extras`, which owns it from then on.
	owned_names := make([dynamic]string, 0, 2, allocator)
	defer {
		for name in owned_names {
			delete(name, allocator)
		}
		delete(owned_names)
	}
	pending_args := make([dynamic][]string, 0, 2, allocator)
	// The explicit-argument lists are made with `make` below and belong to this
	// proc; the borrowed ones (arg_strings[start:stop], `[]string{}`) must not
	// be freed, so they are tracked separately from `pending_args` itself.
	owned_args := make([dynamic][]string, 0, 2, allocator)
	defer {
		for args in owned_args {
			delete(args, allocator)
		}
		delete(owned_args)
		delete(pending_args)
	}

	action := hit.action
	option_string := hit.name
	sep := hit.sep
	explicit := hit.explicit
	has_explicit := hit.has_explicit

	stop = start_index + 1
	for {
		if action < 0 {
			// `if action is None: extras.append(arg_strings[start_index])`
			if !append_owned(&ns.extras, p.arg_strings[start_index], allocator) {
				return stop, strings.clone("not enough memory", allocator) or_else ""
			}
			return stop, ""
		}
		spec := OPTION_SPECS[action]
		if has_explicit {
			arg_count, _ := match_explicit(spec.nargs)
			// A single-dash option that takes no argument can have more
			// clustered options glued after it.
			if arg_count == 0 && option_string[1] != '-' && explicit != "" {
				if sep != "" || explicit[0] == '-' {
					repr := python_repr(explicit, allocator)
					defer delete(repr, allocator)
					body := strings.concatenate(
						{"ignored explicit argument ", repr},
						allocator,
					)
					defer delete(body, allocator)
					name := option_action_name(spec, allocator)
					defer delete(name, allocator)
					return stop, argument_message(allocator, name, body)
				}
				append(&pending_actions, action)
				append(&pending_names, option_string)
				append(&pending_args, []string{})
				next_name := strings.concatenate({option_string[:1], explicit[:1]}, allocator)
				rest := explicit[1:]
				if index, found := find_option(next_name); found {
					action = index
					option_string = next_name
					append(&owned_names, next_name)
					if rest == "" {
						sep = ""
						explicit = ""
						has_explicit = false
					} else if rest[0] == '=' {
						sep = "="
						explicit = rest[1:]
						has_explicit = true
					} else {
						sep = ""
						explicit = rest
						has_explicit = true
					}
					continue
				}
				// not an option after all: the tail is an extra argument
				if !append_owned(&ns.extras, next_name, allocator) {
					return stop, strings.clone("not enough memory", allocator) or_else ""
				}
				break
			} else if arg_count == 1 {
				explicit_args := make([]string, 1, allocator)
				explicit_args[0] = explicit
				append(&owned_args, explicit_args)
				append(&pending_actions, action)
				append(&pending_names, option_string)
				append(&pending_args, explicit_args)
				break
			} else {
				repr := python_repr(explicit, allocator)
				defer delete(repr, allocator)
				body := strings.concatenate(
					{"ignored explicit argument ", repr},
					allocator,
				)
				defer delete(body, allocator)
				name := option_action_name(spec, allocator)
				defer delete(name, allocator)
				return stop, argument_message(allocator, name, body)
			}
		} else {
			arg_count, matched := match_nargs(spec.nargs, p.pattern, start_index + 1)
			if !matched {
				name := option_action_name(spec, allocator)
				defer delete(name, allocator)
				return stop, argument_message(allocator, name, nargs_error_message(spec.nargs))
			}
			stop = start_index + 1 + arg_count
			append(&pending_actions, action)
			append(&pending_names, option_string)
			append(&pending_args, p.arg_strings[start_index + 1:stop])
			break
		}
	}

	for pending_action, i in pending_actions {
		if msg := apply_action(p, pending_action, pending_args[i], pending_names[i]); msg != "" {
			return stop, msg
		}
	}
	return stop, ""
}

// record_meta_action remembers the first of argparse's print-and-exit actions
// in command-line order. argparse installs `--help`, `--manual` and `--version`
// as actions, so the scan stops at the first one it meets (`http --help
// --version` prints the help and never looks at `--version`); this port scans
// the whole command line and picks the winner here instead.
@(private)
record_meta_action :: proc(ns: ^Namespace, action: Meta_Action) {
	if ns.meta_action == .None {
		ns.meta_action = action
	}
}

// apply_action is argparse's `take_action` for an option: convert the value,
// check the mutually exclusive group, then store.
@(private)
apply_action :: proc(p: ^Parser, action: int, args: []string, option_string: string) -> string {
	spec := OPTION_SPECS[action]
	allocator := p.allocator
	ns := p.ns
	_ = option_string

	name := option_action_name(spec, allocator)
	defer delete(name, allocator)

	value := ""
	if spec.nargs != .Zero {
		value = args[len(args) - 1] // the matcher guarantees at least one
		switch spec.arg_type {
		case .Int:
			if _, ok := parse_python_int(value); !ok {
				repr := python_repr(value, allocator)
				defer delete(repr, allocator)
				body := strings.concatenate(
					{"invalid int value: ", repr},
					allocator,
				)
				defer delete(body, allocator)
				return argument_message(allocator, name, body)
			}
		case .Float:
			if _, ok := parse_python_float(value); !ok {
				repr := python_repr(value, allocator)
				defer delete(repr, allocator)
				body := strings.concatenate(
					{"invalid float value: ", repr},
					allocator,
				)
				defer delete(body, allocator)
				return argument_message(allocator, name, body)
			}
		case .Charset:
			// `response_charset_type` is `''.encode(encoding)` with the LookupError
			// inverted (cli/argtypes.py:262-268). A name with no *text* codec
			// behind it is the ArgumentTypeError that raises; a name whose codec
			// resolves and then refuses to encode an empty string (only
			// `undefined`) is not a LookupError at all, so argparse reports its
			// own ValueError instead — same option, different message.
			// src/http/charset.odin holds the registry, generated from CPython's.
			class := http.charset_class(value)
			if class != .Text {
				repr := python_repr(value, allocator)
				defer delete(repr, allocator)
				body := class == .Raising \
					? strings.concatenate({"invalid response_charset_type value: ", repr}, allocator) \
					: strings.concatenate({repr, " is not a supported encoding"}, allocator)
				defer delete(body, allocator)
				return argument_message(allocator, name, body)
			}
		case .Mime:
			if count_byte(value, '/') != 1 {
				repr := python_repr(value, allocator)
				defer delete(repr, allocator)
				body := strings.concatenate(
					// httpie's typographic apostrophe, byte for byte
					{repr, " doesn\u2019t look like a mime type; use type/subtype"},
					allocator,
				)
				defer delete(body, allocator)
				return argument_message(allocator, name, body)
			}
		case .Session_Name:
			if !session_name_is_valid(value) {
				// ArgumentError(None, …) in the reference: no argument name, so
				// no "argument …:" prefix either
				return strings.clone(MESSAGE_SESSION_NAME, allocator) or_else ""
			}
		case .Readable_File:
			if !file_is_readable(value) {
				body := strings.concatenate({value, ": No such file or directory"}, allocator)
				defer delete(body, allocator)
				return argument_message(allocator, name, body)
			}
		case .Output_File:
			if !file_is_openable_for_append(value) {
				quoted := python_repr(value, allocator)
				defer delete(quoted, allocator)
				body := strings.concatenate(
					{"can't open ", quoted, ": [Errno 2] No such file or directory: ", quoted},
					allocator,
				)
				defer delete(body, allocator)
				return argument_message(allocator, name, body)
			}
		case .Ssl_Credentials, .Str:
		// stored as the raw string
		}
		if len(spec.choices) > 0 && !choice_is_valid(spec.choices, value) {
			choices_text := choices_repr(spec.choices, allocator)
			defer delete(choices_text, allocator)
			return invalid_choice_message(name, value, choices_text, allocator)
		}
		// --style and --auth-type are LazyChoices: the action's own list.
		if spec.dest == .Style && !style_is_valid(value) {
			choices_text := style_choices_repr(allocator)
			defer delete(choices_text, allocator)
			return invalid_choice_message(name, value, choices_text, allocator)
		}
	}

	// the mutually exclusive group around the session options
	if action == SESSION_ACTION && ns.seen[SESSION_READ_ONLY_ACTION] {
		return strings.concatenate(
			{
				"argument ",
				name,
				": not allowed with argument ",
				OPTION_SPECS[SESSION_READ_ONLY_ACTION].names[0],
			},
			allocator,
		)
	}
	if action == SESSION_READ_ONLY_ACTION && ns.seen[SESSION_ACTION] {
		return strings.concatenate(
			{
				"argument ",
				name,
				": not allowed with argument ",
				OPTION_SPECS[SESSION_ACTION].names[0],
			},
			allocator,
		)
	}
	ns.seen[action] = true

	switch spec.dest {
	case .Request_Type:
		#partial switch spec.const {
		case .Request_JSON:
			ns.request_type = .Json
		case .Request_Form:
			ns.request_type = .Form
		case .Request_Multipart:
			ns.request_type = .Multipart
		case:
		}
	case .Boundary:
		if !set_owned(&ns.boundary, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Raw:
		if !set_owned(&ns.raw, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.raw_set = true
	case .Compress:
		ns.compress += 1
	case .Prettify:
		if !set_owned(&ns.prettify, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Style:
		if !set_owned(&ns.style, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Format_Options:
		if spec.action == .Append_Const {
			options :=
				spec.const == .Format_Sorted ? SORTED_FORMAT_OPTIONS_STRING : UNSORTED_FORMAT_OPTIONS_STRING
			if !append_owned(&ns.format_options, options, allocator) {
				return strings.clone("not enough memory", allocator) or_else ""
			}
		} else if !append_owned(&ns.format_options, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Response_Charset:
		if !set_owned(&ns.response_charset, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Response_Mime:
		if !set_owned(&ns.response_mime, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Output_Options:
		letters := value
		#partial switch spec.const {
		case .Print_Headers:
			letters = "h"
		case .Print_Body:
			letters = "b"
		case .Print_Meta:
			letters = "m"
		case:
		}
		if !set_owned(&ns.output_options, letters, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.output_options_set = true
	case .Output_Options_History:
		if !set_owned(&ns.output_options_history, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.output_options_history_set = true
	case .Output_File:
		if !set_owned(&ns.output_file, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.output_file_set = true
	case .Download:
		ns.download = true
	case .Download_Resume:
		ns.download_resume = true
	case .Quiet:
		ns.quiet += 1
	case .Verbose:
		ns.verbose += 1
	case .All:
		ns.all = true
	case .Stream:
		ns.stream = true
	case .Session:
		if !set_owned(&ns.session, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.session_seen = true
	case .Session_Read_Only:
		if !set_owned(&ns.session_read_only, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.session_read_only_seen = true
	case .Auth:
		if !set_owned(&ns.auth, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.auth_seen = true
	case .Auth_Type:
		if !set_owned(&ns.auth_type, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.auth_type_seen = true
	case .Ignore_Netrc:
		ns.ignore_netrc = true
	case .Offline:
		ns.offline = true
	case .Proxy:
		if !append_owned(&ns.proxy, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Follow:
		ns.follow = true
	case .Max_Redirects:
		number, _ := parse_python_int(value)
		ns.max_redirects = int(number)
	case .Max_Headers:
		number, _ := parse_python_int(value)
		ns.max_headers = int(number)
	case .Timeout:
		number, _ := parse_python_float(value)
		ns.timeout = number
		ns.timeout_set = true
	case .Check_Status:
		ns.check_status = true
	case .Path_As_Is:
		ns.path_as_is = true
	case .Chunked:
		ns.chunked = true
	case .Verify:
		if !set_owned(&ns.verify, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Ssl_Version:
		if !set_owned(&ns.ssl_version, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Ciphers:
		if !set_owned(&ns.ciphers, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Cert:
		if !set_owned(&ns.cert, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Cert_Key:
		if !set_owned(&ns.cert_key, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Cert_Key_Pass:
		if !set_owned(&ns.cert_key_pass, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Ignore_Stdin:
		ns.ignore_stdin = true
	case .Help:
		ns.help = true
		record_meta_action(ns, .Help)
	case .Manual:
		ns.manual = true
		record_meta_action(ns, .Manual)
	case .Version:
		ns.version = true
		record_meta_action(ns, .Version)
	case .Traceback:
		ns.traceback = true
	case .Default_Scheme:
		if !set_owned(&ns.default_scheme, value, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		ns.default_scheme_set = true
	case .Debug:
		ns.debug = true
	}
	return ""
}

// apply_positional is argparse's `take_action` for the positionals. The
// REQUEST_ITEM grammar check happens here, which is why a bad item is reported
// as "argument REQUEST_ITEM: …" while an item httpie's own item parser rejects
// later is not.
@(private)
apply_positional :: proc(p: ^Parser, kind: Pos_Kind, raw_args: []string) -> string {
	ns := p.ns
	allocator := p.allocator
	args, allocated := without_first_double_dash(raw_args, allocator)
	defer if allocated {
		delete(args, allocator)
	}

	switch kind {
	case .Method:
		delete(ns.method, allocator)
		ns.method = ""
		ns.method_seen = false
		if len(args) == 1 {
			if !set_owned(&ns.method, args[0], allocator) {
				return strings.clone("not enough memory", allocator) or_else ""
			}
			ns.method_seen = true
		}
	case .URL:
		delete(ns.url, allocator)
		ns.url = ""
		ns.url_seen = false
		if len(args) == 1 {
			if !set_owned(&ns.url, args[0], allocator) {
				return strings.clone("not enough memory", allocator) or_else ""
			}
			ns.url_seen = true
		}
	case .Request_Items:
		for arg in args {
			// KeyValueArgType.__call__: the separator has to be there
			parsed, item_message := parse_item_arg(arg, allocator)
			if item_message != "" {
				defer delete(item_message, allocator)
				return strings.concatenate(
					{"argument REQUEST_ITEM: ", item_message},
					allocator,
				)
			}
			// The parse was only a validity check: the namespace keeps the
			// argument as typed and re-parses it later.
			item_parse_destroy(&parsed, allocator)
			if !append_owned(&ns.request_items, arg, allocator) {
				return strings.clone("not enough memory", allocator) or_else ""
			}
		}
		ns.request_items_seen = true
	}
	return ""
}

// ---------------------------------------------------------------------------
// Value conversion (Python's int()/float()/str.count(), httpie's argtypes.py)
// ---------------------------------------------------------------------------

// parse_python_int is `int(value)`: optional surrounding whitespace, an
// optional sign, decimal digits with single '_' separators between them.
@(private)
parse_python_int :: proc(value: string) -> (result: i64, ok: bool) {
	text := strings.trim_space(value)
	if text == "" {
		return 0, false
	}
	negative := false
	if text[0] == '+' || text[0] == '-' {
		negative = text[0] == '-'
		text = text[1:]
	}
	if text == "" {
		return 0, false
	}
	digits := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&digits)
	seen_digit := false
	previous_underscore := false
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '0' ..= '9':
			strings.write_byte(&digits, c)
			seen_digit = true
			previous_underscore = false
		case '_':
			if !seen_digit || previous_underscore || i == len(text) - 1 {
				return 0, false
			}
			previous_underscore = true
		case:
			return 0, false
		}
	}
	number, parsed := strconv.parse_i64(strings.to_string(digits))
	if !parsed {
		return 0, false
	}
	return negative ? -number : number, true
}

// parse_python_float is `float(value)`.
@(private)
parse_python_float :: proc(value: string) -> (result: f64, ok: bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "" {
		return 0, false
	}
	// Python's float() accepts underscores between digits; strip them into a
	// stack buffer, since Odin's parser does not accept them.
	text := trimmed
	if strings.contains(trimmed, "_") {
		buffer: [64]u8
		if len(trimmed) <= len(buffer) {
			kept := 0
			for i in 0 ..< len(trimmed) {
				if trimmed[i] != '_' {
					buffer[kept] = trimmed[i]
					kept += 1
				}
			}
			text = string(buffer[:kept])
		}
	}
	// The word forms cannot be produced by the numeric parser.
	if strings.equal_fold(text, "inf") || strings.equal_fold(text, "+inf") ||
	   strings.equal_fold(text, "infinity") || strings.equal_fold(text, "+infinity") {
		one, zero := f64(1), f64(0)
		return one / zero, true
	}
	if strings.equal_fold(text, "-inf") || strings.equal_fold(text, "-infinity") {
		one, zero := f64(1), f64(0)
		return -one / zero, true
	}
	if strings.equal_fold(text, "nan") || strings.equal_fold(text, "+nan") {
		zero := f64(0)
		return zero / zero, true
	}
	if strings.equal_fold(text, "-nan") {
		zero := f64(0)
		return -(zero / zero), true
	}
	number, parsed := strconv.parse_f64(text)
	return number, parsed
}

// isnumeric is Python's str.isnumeric for the ASCII digits httpie's format
// options use.
@(private)
isnumeric :: proc(text: string) -> bool {
	if text == "" {
		return false
	}
	for c in text {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// count_byte is Python's str.count for a one-byte needle.
@(private)
count_byte :: proc(text: string, c: u8) -> int {
	count := 0
	for i in 0 ..< len(text) {
		if text[i] == c {
			count += 1
		}
	}
	return count
}

// session_name_is_valid is SessionNameValidator: a path (anything containing
// the platform's path separator) is accepted verbatim, a plain name has to
// match `^[a-zA-Z0-9_.-]+$`.
@(private)
session_name_is_valid :: proc(value: string) -> bool {
	if strings.contains(value, "/") {
		return true
	}
	if value == "" {
		return false
	}
	for c in value {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.', '-':
		case:
			return false
		}
	}
	return true
}

// choice_is_valid is argparse's `_check_value` membership test.
@(private)
choice_is_valid :: proc(choices: []string, value: string) -> bool {
	for choice in choices {
		if choice == value {
			return true
		}
	}
	return false
}

@(private)
file_is_readable :: proc(path: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return false
	}
	delete(data, context.temp_allocator)
	return true
}

@(private)
file_is_openable_for_append :: proc(path: string) -> bool {
	handle, err := os.open(path, os.O_RDWR | os.O_CREATE)
	if err != nil {
		return false
	}
	os.close(handle)
	return true
}

// ---------------------------------------------------------------------------
// httpie's post-processing (httpie/cli/argparser.py:151-620)
// ---------------------------------------------------------------------------

// apply_no_options is `_apply_no_options`: every `--no-OPTION` that argparse
// could not resolve as an option resets that option's dest to its default. It
// runs after the scan, so it also undoes values that came from the config file.
// It returns the "unrecognized arguments" message when some extra was neither a
// known option nor a resolvable `--no-` form.
@(private)
apply_no_options :: proc(p: ^Parser) -> string {
	ns := p.ns
	allocator := p.allocator

	invalid := make([dynamic]string, allocator)
	defer delete(invalid)
	for option in ns.extras {
		if !strings.has_prefix(option, "--no-") {
			append(&invalid, option)
			continue
		}
		// `--no-option` => `--option`: the inverted name is spelled the way the
		// option table spells its names, `--OPTION` and not `OPTION`.
		inverted := strings.concatenate({"--", option[5:]}, allocator)
		defer delete(inverted, allocator)
		if !reset_option(p, inverted) {
			append(&invalid, option)
		}
	}
	if len(invalid) == 0 {
		return ""
	}
	joined := strings.join(invalid[:], " ", allocator)
	defer delete(joined, allocator)
	return strings.concatenate({"unrecognized arguments: ", joined}, allocator)
}

// reset_option is the `--no-OPTION` -> `--OPTION` lookup: `name` is the
// inverted option string (`--OPTION`, the form the caller builds), which has to
// be a real option string, and its dest goes back to the argparse default.
@(private)
reset_option :: proc(p: ^Parser, name: string) -> bool {
	ns := p.ns
	allocator := p.allocator
	for spec in OPTION_SPECS {
		found := false
		for candidate in spec.names {
			if candidate == name {
				found = true
				break
			}
		}
		if !found {
			continue
		}
		switch spec.dest {
		case .Request_Type:
			ns.request_type = .Unset
		case .Boundary:
			delete(ns.boundary, allocator)
			ns.boundary = ""
		case .Raw:
			delete(ns.raw, allocator)
			ns.raw = ""
			ns.raw_set = false
		case .Compress:
			ns.compress = 0
		case .Prettify:
			delete(ns.prettify, allocator)
			ns.prettify = ""
		case .Style:
			set_owned(&ns.style, "auto", allocator)
		case .Format_Options:
			for option in ns.format_options {
				delete(option, allocator)
			}
			clear(&ns.format_options)
		case .Response_Charset:
			delete(ns.response_charset, allocator)
			ns.response_charset = ""
		case .Response_Mime:
			delete(ns.response_mime, allocator)
			ns.response_mime = ""
		case .Output_Options:
			delete(ns.output_options, allocator)
			ns.output_options = ""
			ns.output_options_set = false
		case .Output_Options_History:
			delete(ns.output_options_history, allocator)
			ns.output_options_history = ""
			ns.output_options_history_set = false
		case .Output_File:
			delete(ns.output_file, allocator)
			ns.output_file = ""
			ns.output_file_set = false
		case .Download:
			ns.download = false
		case .Download_Resume:
			ns.download_resume = false
		case .Quiet:
			ns.quiet = 0
		case .Verbose:
			ns.verbose = 0
		case .All:
			ns.all = false
		case .Stream:
			ns.stream = false
		case .Session:
			delete(ns.session, allocator)
			ns.session = ""
			ns.session_seen = false
		case .Session_Read_Only:
			delete(ns.session_read_only, allocator)
			ns.session_read_only = ""
			ns.session_read_only_seen = false
		case .Auth:
			delete(ns.auth, allocator)
			ns.auth = ""
			ns.auth_seen = false
		case .Auth_Type:
			delete(ns.auth_type, allocator)
			ns.auth_type = ""
			ns.auth_type_seen = false
		case .Ignore_Netrc:
			ns.ignore_netrc = false
		case .Offline:
			ns.offline = false
		case .Proxy:
			for entry in ns.proxy {
				delete(entry, allocator)
			}
			clear(&ns.proxy)
		case .Follow:
			ns.follow = false
		case .Max_Redirects:
			ns.max_redirects = 30
		case .Max_Headers:
			ns.max_headers = 0
		case .Timeout:
			ns.timeout = 0
			ns.timeout_set = false
		case .Check_Status:
			ns.check_status = false
		case .Path_As_Is:
			ns.path_as_is = false
		case .Chunked:
			ns.chunked = false
		case .Verify:
			set_owned(&ns.verify, "yes", allocator)
		case .Ssl_Version:
			delete(ns.ssl_version, allocator)
			ns.ssl_version = ""
		case .Ciphers:
			delete(ns.ciphers, allocator)
			ns.ciphers = ""
		case .Cert:
			delete(ns.cert, allocator)
			ns.cert = ""
		case .Cert_Key:
			delete(ns.cert_key, allocator)
			ns.cert_key = ""
		case .Cert_Key_Pass:
			delete(ns.cert_key_pass, allocator)
			ns.cert_key_pass = ""
		case .Ignore_Stdin:
			ns.ignore_stdin = false
		case .Traceback:
			ns.traceback = false
		case .Default_Scheme:
			set_owned(&ns.default_scheme, "http", allocator)
			ns.default_scheme_set = false
		case .Debug:
			ns.debug = false
		case .Help, .Manual, .Version:
		// no value to reset
		}
		return true
	}
	return false
}

// apply_format_options_group is httpie/cli/argtypes.py's parse_format_options:
// one `section.key:value[,section.key:value]` group folded onto `state`. The
// value's type has to match the current one, and the option is lower-cased
// first, which is why an upper-case value still parses.
@(private)
apply_format_options_group :: proc(
	state: Format_Options,
	group: string,
	allocator: mem.Allocator,
) -> (out: Format_Options, message: string) {
	out = state
	remaining := group
	for option in strings.split_iterator(&remaining, ",") {
		lowered := strings.to_lower(option, context.temp_allocator)
		// `path, value = option.lower().split(':')` raises unless there is
		// exactly one separator; `section, key = path.split('.')` then raises
		// unless the path holds exactly one dot.
		colon := strings.index_byte(lowered, ':')
		if colon < 0 || strings.index_byte(lowered[colon + 1:], ':') >= 0 {
			return out, repr_message(allocator, "invalid option ", option, "")
		}
		path := lowered[:colon]
		value := lowered[colon + 1:]
		dot := strings.index_byte(path, '.')
		if dot < 0 || strings.index_byte(path[dot + 1:], '.') >= 0 {
			return out, repr_message(allocator, "invalid option ", option, "")
		}
		section := path[:dot]
		key := path[dot + 1:]

		// the parsed value's type
		value_kind: Format_Value_Kind
		switch {
		case value == "true", value == "false":
			value_kind = .Bool
		case isnumeric(value):
			value_kind = .Int
		case:
			value_kind = .Str
		}

		// `defaults[section][key]`: a missing path is a KeyError, reported as
		// `invalid key <path>` with the lower-cased path.
		expected: Format_Value_Kind
		switch section {
		case "headers":
			if key != "sort" {
				return out, repr_message(allocator, "invalid key ", path, "")
			}
			expected = .Bool
		case "json":
			switch key {
			case "format", "sort_keys":
				expected = .Bool
			case "indent":
				expected = .Int
			case:
				return out, repr_message(allocator, "invalid key ", path, "")
			}
		case "xml":
			switch key {
			case "format":
				expected = .Bool
			case "indent":
				expected = .Int
			case:
				return out, repr_message(allocator, "invalid key ", path, "")
			}
		case:
			return out, repr_message(allocator, "invalid key ", path, "")
		}

		if expected != value_kind {
			return out, format_message(
				allocator,
				"invalid value ",
				python_repr(value, allocator),
				" in ",
				python_repr(option, allocator),
				" (expected ",
				format_value_kind_name(expected),
				" got ",
				format_value_kind_name(value_kind),
				")",
			)
		}

		parsed_int := 0
		bool_value := false
		switch value_kind {
		case .Bool:
			bool_value = value == "true"
		case .Int:
			if parsed, ok := strconv.parse_int(value, 10); ok {
				parsed_int = int(parsed)
			}
		case .Str:
		}

		switch section {
		case "headers":
			out.headers_sort = bool_value
		case "json":
			switch key {
			case "format":
				out.json_format = bool_value
			case "indent":
				out.json_indent = parsed_int
			case "sort_keys":
				out.json_sort_keys = bool_value
			case:
			}
		case "xml":
			switch key {
			case "format":
				out.xml_format = bool_value
			case "indent":
				out.xml_indent = parsed_int
			case:
			}
		case:
		}
	}
	return out, ""
}

@(private)
Format_Value_Kind :: enum {
	Bool,
	Int,
	Str,
}

@(private)
format_value_kind_name :: proc(kind: Format_Value_Kind) -> string {
	switch kind {
	case .Bool:
		return "bool"
	case .Int:
		return "int"
	case .Str:
		return "str"
	}
	return "str"
}

// format_message joins already-formatted message pieces.
@(private)
format_message :: proc(allocator: mem.Allocator, parts: ..string) -> string {
	joined, err := strings.join(parts, "", allocator)
	if err != .None {
		return ""
	}
	return joined
}

// repr_message is format_message for the error paths that embed `repr(value)`:
// the temporary is built and released here, so no caller leaks it.
repr_message :: proc(allocator: mem.Allocator, prefix, value, tail: string) -> string {
	repr := python_repr(value, allocator)
	defer delete(repr, allocator)
	return format_message(allocator, prefix, repr, tail)
}

// ---------------------------------------------------------------------------
// The config file (httpie/config.py + httpie/core.py:48-49)
// ---------------------------------------------------------------------------

// config_dir is `get_default_config_dir`: $HTTPIE_CONFIG_DIR, else the legacy
// ~/.httpie when it exists, else ($XDG_CONFIG_HOME or ~/.config)/httpie.
@(private)
config_dir :: proc(env: Env_Info, allocator: mem.Allocator) -> (string, bool) {
	if value, found := env_get(env, "HTTPIE_CONFIG_DIR"); found && value != "" {
		return strings.clone(value, allocator) or_else "", true
	}
	home, has_home := env_get(env, "HOME")
	if !has_home || home == "" {
		return "", false
	}
	legacy := strings.concatenate({home, "/.httpie"}, allocator)
	if ok := dir_exists(legacy); ok {
		return legacy, true
	}
	delete(legacy, allocator)
	if xdg, found := env_get(env, "XDG_CONFIG_HOME"); found && xdg != "" {
		return strings.concatenate({xdg, "/httpie"}, allocator), true
	}
	return strings.concatenate({home, "/.config/httpie"}, allocator), true
}

@(private)
dir_exists :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err == nil {
		return info.type == .Directory
	}
	return false
}

// The config file is read the way `Environment.config` reads it, and so are the
// two steps that follow it *outside* that property's `except ConfigFileError`:
// `BaseConfigDict.load`'s `self.update(data)` (config.py:103-108) and `raw_main`'s
// `args = env.config.default_options + args` (core.py:48-49). A value neither can
// use ends the reference with an **unhandled Python traceback** — rc 1, nothing
// on stdout, nothing sent, and no `http: warning:` line — where a malformed file
// is only the warning `read_raw_config` raises. Config_Read carries three
// separate answers because the reference reaches them at three moments:
//
//   * `fatal` — a value `BaseConfigDict.load` itself chokes on, i.e. before
//     argparse is called at all (core.py:46-49): the *root* is a scalar, or a
//     `default_options` that is not a list meets `+ args`. Nothing precedes it,
//     not even `--help`/`--version`.
//   * `item_fatal` — a `default_options` element that is not a string and that
//     argparse's `_parse_optional` refuses *by type* (a scalar is not
//     subscriptable, a mapping has no key `0`, an array's first element is fed to
//     `in self.prefix_chars`). That is argparse's own walk, so the options before
//     the element are processed first and the `unrecognized arguments` check
//     comes after it.
//   * `item` + `item_type` — an element argparse *does* use as an argument
//     string (`Config_Item`): the port puts CONFIG_ITEM_PLACEHOLDER in its place
//     and lets its own scan, which is a model of argparse's, decide what the
//     element does to the command line and what it leaves over.
//
// Measured, not assumed (`build/probe_config_value_shapes.py` for every shape and
// the reference's traceback tail, the value-shape cases of
// `build/probe_config_warning.py` for the printed block): docs/PARITY.md §6.1,
// §8.18(f). The reference's *stderr* for these shapes is a CPython traceback
// whose frames name its own interpreter paths, so no scenario pins it — the
// port prints the exception's own line through the `http: error:` writer, the
// decision §8.20 records for the one other road that dies outside httpie's own
// error handling (the `--raw` body's `UnicodeEncodeError`); what a scenario does
// pin is the observable contract: rc 1, nothing on stdout and nothing sent.

// CONFIG_ITEM_PLACEHOLDER stands in the argument list for a `default_options`
// element that argparse uses as an argument string. It starts with no `-`, so
// the scan classifies it as an ordinary argument — which is what argparse's
// `_parse_optional` answers for such an element (`if not arg_string: return
// None` / `if not arg_string[0] in self.prefix_chars: return None`) — and the
// port's positional matcher, a model of argparse's, then places it exactly where
// argparse places the element and reports the same leftovers. It never reaches a
// rendered request: the run is refused before `process` either by a message the
// scan produced or by the item rule in parse_args_with.
CONFIG_ITEM_PLACEHOLDER :: "httpie-config-default-option"

// Config_Item is what a `default_options` element that is not a string is, for
// the two shapes whose reference answer is *not* one exception line.
//
//	None  — every element is a string.
//	Null  — an element is JSON `null`. It is falsy, so `_parse_optional` answers
//	        "ordinary" at its first check; `_get_values` then hands the null on as
//	        the value, and `_guess_method`'s `if self.args.method is None` reads it
//	        as "no method given" — the `assert not self.args.request_items` on
//	        that branch is the one thing left of it.
//	Other — an element is `{}`, or an array whose first element is a string other
//	        than `''` and `'-'`: the values `_parse_optional` passes over. (Its
//	        `prefix_chars` is `-` alone, so `'x' in '-'` is false for every string
//	        long enough to be a real option.) An element that is not one of those
//	        two shapes is refused by type in the same function — see
//	        config_item_fatal.
Config_Item :: enum {
	None,
	Null,
	Other,
}

// Config_Read is what the config file contributed: the option words, with one
// placeholder per item, plus the malformed-file warning and the refusals above.
// `warning` is the caller's to print and release; the rest is owned here and
// released by config_read_destroy.
Config_Read :: struct {
	options:    [dynamic]string,
	warning:    string,
	fatal:      string,
	item_fatal: string,
	item:       Config_Item,
	item_type:  string, // "list" or "dict": the type name in the item's message
}

// config_read_destroy releases everything config_read allocated except the
// warning, which parse_args_with hands to its caller. `fatal` and `item_fatal`
// are transferred the same way on the paths that use them: the caller clears the
// field before returning the message.
@(private)
config_read_destroy :: proc(read: ^Config_Read, allocator: mem.Allocator) {
	for option in read.options {
		delete(option, allocator)
	}
	delete(read.options)
	delete(read.fatal, allocator)
	delete(read.item_fatal, allocator)
	read^ = {}
}

// config_read reads `config.json` for the config directory and walks the value
// the way the reference does.
//
// The reader is `Environment.config` (httpie/context.py:143-149): a file that is
// *not there* is not read at all (`Config.is_new()` is `not Path.exists()`), and
// `read_raw_config` (httpie/config.py:60-78) raises the `ConfigFileError` that
// becomes `warning` for a read that failed, a byte order mark, a decoder
// refusal or the codec refusal of the `open(encoding='utf-8')`.
@(private)
config_read :: proc(env: Env_Info, allocator: mem.Allocator) -> Config_Read {
	read: Config_Read
	directory, has_dir := config_dir(env, allocator)
	if !has_dir {
		return read
	}
	defer delete(directory, allocator)

	// `CONFIG_FILE = Path(directory) / 'config.json'` (config.py:56) is a
	// PurePath join, so the path the run reads — and above all the path the two
	// wordings below print — is the normalised one.
	path := pure_path_join(directory, "config.json", allocator)
	defer delete(path, allocator)

	// There is no separate existence test: `core:os`'s own `stat` *opens* the
	// path — it fails with EACCES for a file the reader would have reported — so
	// the read is the one probe, and the failures `Path.exists()` swallows
	// (ENOENT, ENOTDIR, EBADF, ELOOP) come back from `config_read_failure` as
	// "no file".
	text, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		// `read_raw_config`'s OSError branch. Its `FileNotFoundError` half is
		// the silent one: a file that is not there was never loaded.
		if errno, strerror, ok := config_read_failure(path, read_err); ok {
			// `python_repr` is what Python's `OSError.__str__` spells the
			// filename with (`: %R`), owned here and released again.
			path_repr := python_repr(path, allocator)
			defer delete(path_repr, allocator)
			read.warning = fmt.aprintf(
				"cannot read config file: [Errno %d] %s: %s",
				errno,
				strerror,
				path_repr,
				allocator = allocator,
			)
		}
		return read
	}
	defer delete(text, allocator)

	// `open(encoding='utf-8')` decodes the bytes before `json.load` ever sees
	// them, and its refusal is the same `ValueError` channel — `read_raw_config`
	// wraps the *message* only, so the codec's own text is what the warning
	// carries.
	if decode_err := http.str_utf8_decode_failure(string(text)); decode_err.failed {
		detail := http.str_utf8_decode_error_text(&decode_err, allocator)
		defer delete(detail, allocator)
		read.warning = config_invalid_message(detail, path, allocator)
		return read
	}

	root, json_err := format.parse_json(string(text), allocator)
	if json_err.message != "" {
		read.warning = config_invalid_message(json_err.message, path, allocator)
		format.json_error_destroy(&json_err)
		return read
	}
	defer format.value_destroy(&root, allocator)

	config_document(root, &read, allocator)
	return read
}

// config_document is `BaseConfigDict.load`'s `if data is not None:
// self.update(data)` followed by the `default_options` read that `raw_main`
// concatenates. `dict.update` takes a mapping or a sequence of pairs and leaves
// any other value with CPython's own error; a value it *accepts* that is not a
// mapping of one key is discarded the way `dict(...)` discards it, which is why
// a root array is walked for the `default_options` pair it may carry.
@(private)
config_document :: proc(root: format.Value, read: ^Config_Read, allocator: mem.Allocator) {
	switch value in root {
	case format.Object:
		// `object_get` reads the live dict, so a repeated key is the last one,
		// as it is for `json.load` and for `dict.update`.
		object := value
		if member, found := format.object_get(&object, "default_options"); found {
			config_default_options_value(member^, read, allocator)
		}
	case format.Null:
		// `if data is not None`: a JSON null updates nothing at all.
	case []format.Value:
		config_update_sequence(value, read, allocator)
	case string, format.Surrogate_String:
		// `dict.update(str)`: the characters are the items, and one character is
		// never a pair. The empty string is the one shape with no items.
		text, _ := format.string_parts(root)
		if text != "" {
			read.fatal = strings.clone(
				"ValueError: dictionary update sequence element #0 has length 1; 2 is required",
				allocator,
			) or_else ""
		}
	case bool, i64, f64:
		read.fatal = fmt.aprintf(
			"TypeError: '%s' object is not iterable",
			config_value_type_name(root),
			allocator = allocator,
		)
	}
}

// config_update_sequence is `dict.update(array)`: every element must be a
// two-element sequence, and only a `default_options` pair can matter — its value
// is what `raw_main` then uses. The element that fails is the one CPython names
// (`#%d`), with `has length %d; 2 is required` for a sequence that is not two
// long (a string counts *characters*), `cannot convert … to a sequence` for an
// element that is no sequence at all, and `unhashable type` for a pair whose key
// could not be a dict key.
@(private)
config_update_sequence :: proc(items: []format.Value, read: ^Config_Read, allocator: mem.Allocator) {
	for item, index in items {
		length, is_sequence := config_sequence_length(item)
		if !is_sequence {
			read.fatal = fmt.aprintf(
				"TypeError: cannot convert dictionary update sequence element #%d to a sequence",
				index,
				allocator = allocator,
			)
			return
		}
		if length != 2 {
			read.fatal = fmt.aprintf(
				"ValueError: dictionary update sequence element #%d has length %d; 2 is required",
				index,
				length,
				allocator = allocator,
			)
			return
		}
		key, value := config_pair(item)
		if !config_key_is_hashable(key) {
			read.fatal = fmt.aprintf(
				"TypeError: unhashable type: '%s'",
				config_value_type_name(key),
				allocator = allocator,
			)
			return
		}
		if key_text, is_string := config_string_text(key); is_string && key_text == "default_options" {
			config_default_options_value(value, read, allocator)
		}
	}
}

// config_default_options_value is `raw_main`'s
// `if use_default_options and env.config.default_options: args =
// env.config.default_options + args`. The `+` is Python's, so a truthy value
// that is not a *list* is a TypeError before anything is parsed, and a list's
// elements are what argparse then uses as argument strings.
@(private)
config_default_options_value :: proc(value: format.Value, read: ^Config_Read, allocator: mem.Allocator) {
	switch item in value {
	case format.Null:
		// Falsy: the concatenation is skipped.
	case bool:
		if item {
			read.fatal = config_concat_error("bool", allocator)
		}
	case i64:
		if item != 0 {
			read.fatal = config_concat_error("int", allocator)
		}
	case f64:
		if item != 0 {
			read.fatal = config_concat_error("float", allocator)
		}
	case string, format.Surrogate_String:
		text, _ := format.string_parts(value)
		if text != "" {
			read.fatal = strings.clone(
				"TypeError: can only concatenate str (not \"list\") to str",
				allocator,
			) or_else ""
		}
	case format.Object:
		if len(item.members) > 0 {
			read.fatal = config_concat_error("dict", allocator)
		}
	case []format.Value:
		config_default_options_list(item, read, allocator)
	}
}

// config_default_options_list walks the list's elements in order: a string is
// the usable element and the common one, everything else is either a value
// argparse refuses by type (config_item_fatal) or one it uses as an argument
// string, which becomes a placeholder. The two kinds keep their order, because
// the list is prepended to argv as it stands. `read.item` and `read.item_type`
// describe the *first* such element: it is the command line's first ordinary
// word whenever the list's own elements come first, which is what the reference
// then reads as the method (or, when more than one positional word is needed,
// the URL).
@(private)
config_default_options_list :: proc(items: []format.Value, read: ^Config_Read, allocator: mem.Allocator) {
	for item in items {
		if text, is_string := config_string_text(item); is_string {
			// A `default_options` string that carries an out-of-band surrogate
			// is an option like any other: its own bytes are what the reader had
			// before that representation existed.
			if !append_owned(&read.options, text, allocator) {
				return
			}
			continue
		}
		if message := config_item_fatal(item, allocator); message != "" {
			// The first refusal wins: it is the one argparse reaches, and the
			// walk stops there.
			if read.item_fatal == "" {
				read.item_fatal = message
			} else {
				delete(message, allocator)
			}
			continue
		}
		if read.item == .None {
			read.item = .Other
			if _, is_null := item.(format.Null); is_null {
				read.item = .Null
			}
			read.item_type = config_value_type_name(item)
		}
		if !append_owned(&read.options, CONFIG_ITEM_PLACEHOLDER, allocator) {
			return
		}
	}
}

// config_item_fatal is the refusal `_parse_optional` raises for an element by
// its *type*, before the positional machinery can see it (argparse.py:2246-2252):
// a scalar has no `[0]`, a mapping has no key `0` (an empty one is falsy and
// passes the first check instead), and an array's first element is fed to
// `in self.prefix_chars` — which answers for a string, raises for anything else,
// and makes the array itself a dict key (`unhashable type`) when that string is
// `''` or `'-'`. `""` means the element is not refused here.
@(private)
config_item_fatal :: proc(item: format.Value, allocator: mem.Allocator) -> string {
	switch value in item {
	case format.Null:
		return ""
	case bool, i64, f64:
		return fmt.aprintf(
			"TypeError: '%s' object is not subscriptable",
			config_value_type_name(item),
			allocator = allocator,
		)
	case format.Object:
		if len(value.members) == 0 {
			return ""
		}
		return strings.clone("KeyError: 0", allocator) or_else ""
	case []format.Value:
		if len(value) == 0 {
			return ""
		}
		first, is_string := config_string_text(value[0])
		if !is_string {
			// CPython's own wording, with no quotes around the type name:
			// `'in <string>' requires string as left operand, not int`.
			return fmt.aprintf(
				"TypeError: 'in <string>' requires string as left operand, not %s",
				config_value_type_name(value[0]),
				allocator = allocator,
			)
		}
		if first == "" || first == "-" {
			return strings.clone("TypeError: unhashable type: 'list'", allocator) or_else ""
		}
		return ""
	case string, format.Surrogate_String:
		return ""
	}
	return ""
}

// config_sequence_length is Python's `len()` of a value used as a sequence: a
// string counts characters, an array its elements and a mapping its keys. `ok`
// is false for a value that is no sequence at all.
@(private)
config_sequence_length :: proc(item: format.Value) -> (length: int, ok: bool) {
	#partial switch value in item {
	case string, format.Surrogate_String:
		text, _ := format.string_parts(item)
		return utf8.rune_count_in_string(text), true
	case []format.Value:
		return len(value), true
	case format.Object:
		return len(value.members), true
	case:
		return 0, false
	}
	return 0, false
}

// config_pair is `dict(sequence)`'s key and value for an element of length two:
// the pair itself for an array, the element's two *items* for anything else —
// the two characters of a string, the two keys of a mapping, because
// `PyDict_MergeFromSeq2` takes each item's first two elements and a mapping's
// items are its keys.
@(private)
config_pair :: proc(item: format.Value) -> (key: format.Value, value: format.Value) {
	#partial switch element in item {
	case []format.Value:
		return element[0], element[1]
	case string, format.Surrogate_String:
		text, _ := format.string_parts(item)
		_, size := utf8.decode_rune_in_string(text)
		key = text[:size]
		if size < len(text) {
			value = text[size:]
		}
		return
	case format.Object:
		return element.members[0].key, element.members[1].key
	}
	return "", ""
}

// config_key_is_hashable is whether the pair's key could be a dict key. Every
// JSON scalar is; an array or an object is not.
@(private)
config_key_is_hashable :: proc(key: format.Value) -> bool {
	#partial switch value in key {
	case []format.Value, format.Object:
		return false
	}
	return true
}

// config_string_text answers the byte image of a JSON string value, with `ok`
// false for a value that is not a string at all.
@(private)
config_string_text :: proc(item: format.Value) -> (text: string, ok: bool) {
	if !format.value_is_string(item) {
		return "", false
	}
	text, _ = format.string_parts(item)
	return text, true
}

// config_concat_error is the `+` of `args = env.config.default_options + args`
// when the left operand is not a list.
@(private)
config_concat_error :: proc(type_name: string, allocator: mem.Allocator) -> string {
	return fmt.aprintf(
		"TypeError: unsupported operand type(s) for +: '%s' and 'list'",
		type_name,
		allocator = allocator,
	)
}

// config_value_type_name is the name CPython's messages use for a JSON value's
// type: `type(value).__name__`.
@(private)
config_value_type_name :: proc(item: format.Value) -> string {
	#partial switch value in item {
	case format.Null:
		return "NoneType"
	case bool:
		return "bool"
	case i64:
		return "int"
	case f64:
		return "float"
	case string, format.Surrogate_String:
		return "str"
	case []format.Value:
		return "list"
	case format.Object:
		return "dict"
	}
	return "object"
}

// pure_path_join is `Path(directory) / name` (config.py:56): a PurePath join, so
// the path the run reads and the path the warnings print are the *normalised*
// one. pathlib drops empty components — a trailing separator, a doubled one — and
// `.` components, keeps `..` exactly as it is, and follows the POSIX rule that
// exactly two leading separators are significant (`//a/b` stays, `///a` is `/a`).
// The port concatenated the directory bytes as it was given, so a
// `$HTTPIE_CONFIG_DIR` ending in `/` printed `…//config.json`.
@(private)
pure_path_join :: proc(directory, name: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	rest := directory
	if strings.has_prefix(directory, "/") {
		if strings.has_prefix(directory, "//") && len(directory) > 2 && directory[2] != '/' {
			strings.write_string(&builder, "//")
		} else {
			strings.write_byte(&builder, '/')
		}
		for len(rest) > 0 && rest[0] == '/' {
			rest = rest[1:]
		}
	}
	wrote_part := false
	for part in strings.split_iterator(&rest, "/") {
		if part == "" || part == "." {
			continue
		}
		if wrote_part {
			strings.write_byte(&builder, '/')
		}
		strings.write_string(&builder, part)
		wrote_part = true
	}
	if wrote_part {
		strings.write_byte(&builder, '/')
	}
	strings.write_string(&builder, name)
	return strings.to_string(builder)
}

// config_item_refusal is what the reference does with a `default_options`
// element that is not a string *after* argparse has placed it (Config_Item). The
// element is CONFIG_ITEM_PLACEHOLDER in the argument list, so the namespace says
// where the scan put it:
//
//   * the method slot — `_guess_method`'s `re.match('^[a-zA-Z]+$', method)`
//     refuses a `.Other` element (`TypeError: expected string or bytes-like
//     object, got 'list'`); a `.Null` element is `method is None`, whose
//     `assert not self.args.request_items` is a refusal and whose other outcome
//     is "no method given at all" — the reference sends the request, and the
//     port clears the slot so that its own `_guess_method` reads it the same way
//     (`POST` with data, `GET` without).
//   * the URL slot — `_process_url`'s first line, `url.startswith('://')`,
//     measured for both element kinds: `AttributeError: 'NoneType' object has no
//     attribute 'startswith'` and the `'dict'` one.
//
// `refused` is false only for the `.Null` element that is no method at all.
@(private)
config_item_refusal :: proc(
	p: ^Parser,
) -> (
	message: string,
	refused: bool,
) {
	ns := p.ns
	allocator := p.allocator
	if ns.method_seen && ns.method == CONFIG_ITEM_PLACEHOLDER {
		switch p.config_item {
		case .None:
		case .Null:
			if len(ns.request_items) > 0 {
				return strings.clone("AssertionError", allocator) or_else "", true
			}
			delete(ns.method, allocator)
			ns.method = ""
			ns.method_seen = false
			return "", false
		case .Other:
			return fmt.aprintf(
				"TypeError: expected string or bytes-like object, got '%s'",
				p.config_item_type,
				allocator = allocator,
			), true
		}
	}
	if ns.url == CONFIG_ITEM_PLACEHOLDER {
		return fmt.aprintf(
			"AttributeError: '%s' object has no attribute 'startswith'",
			p.config_item_type,
			allocator = allocator,
		), true
	}
	// A second element with no slot left of its own: the reference parses it as
	// a request item, which is `_parse_items`' own refusal.
	return fmt.aprintf(
		"TypeError: expected string or bytes-like object, got '%s'",
		p.config_item_type,
		allocator = allocator,
	), true
}

// config_invalid_message is `read_raw_config`'s first wording:
// `ConfigFileError(f'invalid config file: {e} [{path}]')`. The path is
// interpolated as it is spelled (not repr'd), and `e` is the `ValueError`'s own
// message — the decoder's or the codec's, whichever failed.
@(private)
config_invalid_message :: proc(detail, path: string, allocator: mem.Allocator) -> string {
	return format_message(allocator, "invalid config file: ", detail, " [", path, "]")
}

// config_read_failure is Python's `(errno, strerror)` for a read that failed,
// i.e. the two halves of `OSError.__str__`'s `[Errno N] <text>: '<path>'`. The
// text is glibc's, which is what CPython prints; `core:os` knows the same errnos
// but spells two of them its own way (`permission denied`), so the pair is
// spelled here. `ok` is false for a failure that is not one of the shapes the
// reference's reader reports.
@(private)
config_read_failure :: proc(path: string, read_err: os.Error) -> (errno: int, strerror: string, ok: bool) {
	// A directory opened as a file: `read()` is what fails, with EISDIR.
	if os.is_dir(path) {
		return 21, "Is a directory", true
	}
	// `core:os` carries glibc's `strerror(3)` text for the errnos it knows, but
	// names two conditions its own way (`permission denied` for EACCES), so
	// those are spelled out here.
	#partial switch e in read_err {
	case io.Error:
		#partial switch e {
		case .Permission_Denied:
			return 13, "Permission denied", true
		}
	case os.Platform_Error:
		// ENOENT, ENOTDIR and ELOOP are the errnos `Path.exists()` swallows
		// (`pathlib._IGNORED_ERRNOS`, plus EBADF): the reference answers False,
		// `Config.is_new` short-circuits and nothing is read or warned about. A
		// path whose parent is a file, or a symlink loop, is one of those.
		code := int(e)
		if code != 0 && code != 2 && code != 20 && code != 40 {
			return code, os.error_string(read_err), true
		}
	}
	// Everything else — `General_Error.Not_Exist` above all — is the "no file"
	// answer.
	return 0, "", false
}

// ---------------------------------------------------------------------------
// The post-processing pipeline
// ---------------------------------------------------------------------------

// process runs httpie's own stages over the scanned namespace and fills `opts`.
// It returns "" or an owned usage message.
@(private)
process :: proc(p: ^Parser, opts: ^Options) -> string {
	env := p.env
	ns := p.ns
	allocator := p.allocator

	// parse_args (httpie/cli/argparser.py:154-172)
	if ns.debug {
		ns.traceback = true
	}
	has_stdin_data := !env.stdin_is_tty && !ns.ignore_stdin
	has_input_data := has_stdin_data || ns.raw_set

	if message := apply_no_options(p); message != "" {
		return message
	}

	// _process_request_type
	is_json := ns.request_type == .Unset || ns.request_type == .Json
	form_like := ns.request_type == .Form || ns.request_type == .Multipart
	multipart := ns.request_type == .Multipart

	// _process_download_options
	if ns.offline {
		ns.download = false
		ns.download_resume = false
	} else {
		if !ns.download && ns.download_resume {
			return strings.clone(MESSAGE_CONTINUE_WITHOUT_DOWNLOAD, allocator) or_else ""
		}
		if ns.download_resume && !(ns.download && ns.output_file_set) {
			return strings.clone(MESSAGE_CONTINUE_WITHOUT_OUTPUT, allocator) or_else ""
		}
	}

	// _setup_standard_streams: with --download httpie redirects stdout to
	// stderr and the response body to stdout or --output; that is the output
	// layer's business, and Options carries what it needs.

	// _process_output_options
	if ns.verbose > 0 {
		ns.all = true
	}
	output_options := ns.output_options
	if !ns.output_options_set {
		switch {
		case ns.verbose >= 2:
			output_options = OUTPUT_OPTIONS
		case ns.verbose == 1:
			output_options = BASE_OUTPUT_OPTIONS
		case ns.offline:
			output_options = OUTPUT_OPTIONS_DEFAULT_OFFLINE
		case !env.stdout_is_tty:
			output_options = OUTPUT_OPTIONS_DEFAULT_STDOUT_REDIRECTED
		case:
			output_options = OUTPUT_OPTIONS_DEFAULT
		}
	}
	history_options := output_options
	if ns.output_options_history_set {
		history_options = ns.output_options_history
	}
	if unknown := unknown_output_options(output_options); unknown != "" {
		return strings.concatenate({"Unknown output options: --print=", unknown}, allocator)
	}
	if unknown := unknown_output_options(history_options); unknown != "" {
		return strings.concatenate({"Unknown output options: --history-print=", unknown}, allocator)
	}
	if ns.download {
		// The response body is downloaded through a different routine, so it
		// leaves the print set (httpie/cli/argparser.py:539-543).
		output_options = without_body_option(output_options)
	}

	// _process_pretty_options
	pretty := Pretty.Auto
	switch ns.prettify {
	case "":
		// PRETTY_STDOUT_TTY_ONLY
		pretty = env.stdout_is_tty ? .All : .None
	case "all":
		pretty = .All
	case "colors":
		pretty = .Colors
	case "format":
		pretty = .Format
	case "none":
		pretty = .None
	case:
	}

	// _process_format_options
	format_options := format_options_default()
	{
		remaining := ns.format_options[:]
		for group in remaining {
			out, message := apply_format_options_group(format_options, group, allocator)
			if message != "" {
				return message
			}
			format_options = out
		}
	}

	// The `default_options` element that is not a string is met here, exactly
	// where the reference meets it: `_guess_method` runs after
	// `_apply_no_options` — so an unrecognized-arguments report above comes
	// first — and before `_parse_items`/`_process_url`, which is what the
	// namespace the scan filled already answers for (Config_Read.item). A
	// print-and-exit action is not reached at all: argparse acts on `--help`
	// while it walks the command line and never gets to `_guess_method`
	// (measured — with such an element in `default_options`, `http --help`
	// prints the help, rc 0, and sends nothing).
	if p.config_item != .None && ns.meta_action == .None {
		if message, refused := config_item_refusal(p); refused {
			p.exception = true
			return message
		}
	}

	// _guess_method
	method_text := ns.method
	method_given := ns.method_seen && is_letters_only(ns.method)
	if !ns.method_seen {
		// invoked as `http URL`: no method at all
		method_text = has_input_data ? "POST" : "GET"
	} else if !is_letters_only(ns.method) {
		// invoked as `http URL item+': the URL sits in `method` and the first
		// item in `url`, so the item moves and the URL takes its place
		parsed_url, item_message := parse_item_arg(ns.url, allocator)
		defer item_parse_destroy(&parsed_url, allocator)
		if item_message != "" {
			return item_message
		}
		if !move_url_to_first_item(p) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		has_data := has_input_data
		if !has_data {
			for item in ns.request_items {
				parsed, message := parse_item_arg(item, allocator)
				if message != "" {
					delete(message, allocator)
					continue
				}
				is_data := parsed.sep in DATA_SEPARATORS
				item_parse_destroy(&parsed, allocator)
				if is_data {
					has_data = true
					break
				}
			}
		}
		method_text = has_data ? "POST" : "GET"
	}

	// _parse_items
	for item in ns.request_items {
		message := item_set_add(&opts.item_set, item, is_json, form_like, env, allocator)
		if message != "" {
			return message
		}
		if !append_owned(&opts.items, item, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	}
	// item_set_validate covers everything `_body_from_input`/`_body_from_file`
	// check afterwards: at most one of stdin, --raw, a bare @file and key=value
	// data may be present, and file fields need --form.
	if message := item_set_validate(&opts.item_set, form_like, ns.raw_set, has_stdin_data);
	   message != "" {
		return message
	}

	// `--raw`'s body is encoded while the reference parses the arguments:
	// argparser.py:182-183 calls `_body_from_input`, whose `data.encode()` is
	// line 397 — the strict utf-8 codec, on the string the argv decode made, so
	// a body byte that is not valid UTF-8 is a lone surrogate by then and the
	// encode raises (docs/PARITY.md §3.6). That is why the refusal is checked
	// *here*: after the one-data-source check above, which `_body_from_input`
	// runs first (`_ensure_one_data_source`, its line 396 — `--raw=<bad> a=1` is
	// the mixing usage error and not this exception), and before the --compress
	// checks below, which the reference reaches only because the exception
	// *ends* the parse (argparser.py:187-192). The stdin and the bare-`@file`
	// roads read bytes (`_body_from_file`, argparser.py:381-389) and take no
	// such step. The message is the exception's own line; `p.exception` is what
	// keeps it out of the `usage:` block.
	if ns.raw_set {
		failure := http.str_encode_failure(ns.raw, .Utf8)
		if failure.failed {
			p.exception = true
			return http.str_encode_error_message(&failure, allocator)
		}
	}

	// the compress checks come last
	if ns.compress > 0 {
		if ns.chunked {
			return strings.clone(MESSAGE_COMPRESS_CHUNKED, allocator) or_else ""
		}
		if multipart {
			return strings.clone(MESSAGE_COMPRESS_MULTIPART, allocator) or_else ""
		}
	}

	// ---- fill the Options -------------------------------------------------

	opts.pretty = pretty
	opts.format_options = format_options
	opts.body_kind = body_kind_from(ns, &opts.item_set)
	opts.json_given = ns.request_type == .Json
	opts.raw_body = strings.clone(ns.raw, allocator) or_else ""
	opts.boundary = strings.clone(ns.boundary, allocator) or_else ""
	opts.compress = ns.compress
	opts.chunked = ns.chunked
	opts.ignore_stdin = ns.ignore_stdin
	opts.stdin_is_tty = env.stdin_is_tty
	opts.verbose = ns.verbose
	opts.quiet = ns.quiet
	opts.all = ns.all
	opts.stream = ns.stream
	opts.download = ns.download
	opts.download_resume = ns.download_resume
	opts.check_status = ns.check_status
	opts.output_file = strings.clone(ns.output_file, allocator) or_else ""
	opts.print = print_set_from_string(output_options)
	opts.print_history = print_set_from_string(history_options)
	opts.print_given = ns.output_options_set || ns.verbose > 0
	opts.print_history_given = ns.output_options_history_set
	opts.style = strings.clone(ns.style, allocator) or_else ""
	opts.style_given = ns.style != "auto"
	opts.response_charset = strings.clone(ns.response_charset, allocator) or_else ""
	opts.response_mime = strings.clone(ns.response_mime, allocator) or_else ""
	opts.session = strings.clone(ns.session, allocator) or_else ""
	opts.session_read_only = strings.clone(ns.session_read_only, allocator) or_else ""
	opts.auth = strings.clone(ns.auth, allocator) or_else ""
	opts.auth_type = auth_type_from_string(ns.auth_type)
	opts.ignore_netrc = ns.ignore_netrc
	opts.offline = ns.offline
	opts.follow = ns.follow
	opts.max_redirects = ns.max_redirects
	opts.max_headers = ns.max_headers
	opts.timeout_s = ns.timeout
	opts.timeout_given = ns.timeout_set
	opts.path_as_is = ns.path_as_is
	opts.verify = strings.clone(ns.verify, allocator) or_else ""
	opts.ciphers = strings.clone(ns.ciphers, allocator) or_else ""
	opts.cert = strings.clone(ns.cert, allocator) or_else ""
	opts.cert_key = strings.clone(ns.cert_key, allocator) or_else ""
	opts.cert_key_pass = strings.clone(ns.cert_key_pass, allocator) or_else ""
	opts.show_help = ns.help
	opts.show_manual = ns.manual
	opts.show_version = ns.version
	opts.meta_action = ns.meta_action
	opts.show_traceback = ns.traceback
	opts.show_debug = ns.debug
	opts.url = strings.clone(ns.url, allocator) or_else ""
	for entry in ns.proxy {
		if !append_owned(&opts.proxy, entry, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	}
	// The scheme a schemeless URL gets (cli/argparser.py:206-224): the
	// `--default-scheme` value, whose own default is `http` — or `https` when
	// the program was invoked through the `https` console script.
	if scheme, ok := http.scheme_from_string(ns.default_scheme); ok {
		opts.default_scheme = scheme
	}
	if !ns.default_scheme_set && opts.program_name == "https" {
		opts.default_scheme = http.Scheme.HTTPS
	}
	opts.method_given = method_given
	if method, ok := http.method_from_string(method_text); ok {
		opts.method = method
	}
	// requests' PreparedRequest.prepare_method uppercases whatever method it
	// was given, and httpie hands it `args.method.lower()`; the request line and
	// the wire therefore carry the upper-cased verb.
	opts.method_raw = strings.to_upper(method_text, allocator) or_else ""
	return ""
}

// body_kind_from is the request type after httpie's own resolution: what the
// session needs to build the body. `--raw` and a bare `@file` win outright;
// --form/--multipart pick the form encoding, with a file field promoting
// --form to multipart; and a request with no items at all takes its body from
// stdin (or has none).
@(private)
body_kind_from :: proc(ns: ^Namespace, item_set: ^Item_Set) -> Body_Kind {
	if ns.raw_set || item_set.body_file_given {
		return .Raw
	}
	#partial switch ns.request_type {
	case .Form:
		return item_set.any_file_field ? .Multipart : .Form
	case .Multipart:
		return .Multipart
	case:
	}
	if !ns.request_items_seen {
		return .Raw
	}
	return .JSON
}

// move_url_to_first_item is the `request_items.insert(0, …)` of _guess_method:
// the string in the URL slot becomes the first request item, and the string in
// the method slot becomes the URL. Both owned strings move, nothing is copied.
@(private)
move_url_to_first_item :: proc(p: ^Parser) -> bool {
	ns := p.ns
	url_text := ns.url
	method_text := ns.method
	ns.method = "" // ownership moves to ns.url
	ns.url = method_text
	inject_at(&ns.request_items, 0, url_text)
	ns.request_items_seen = true
	return true
}

@(private)
is_letters_only :: proc(text: string) -> bool {
	if text == "" {
		return false
	}
	for c in text {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z':
		case:
			return false
		}
	}
	return true
}

@(private)
unknown_output_options :: proc(value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&builder)
	for i in 0 ..< len(value) {
		c := value[i]
		switch c {
		case 'H', 'B', 'h', 'b', 'm':
			continue
		case:
			if strings.index_byte(strings.to_string(builder), c) < 0 {
				strings.write_byte(&builder, c)
			}
		}
	}
	return strings.to_string(builder)
}

@(private)
without_body_option :: proc(value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&builder)
	for i in 0 ..< len(value) {
		if value[i] != 'b' {
			strings.write_byte(&builder, value[i])
		}
	}
	return strings.to_string(builder)
}

@(private)
print_set_from_string :: proc(value: string) -> Print_Set {
	set: Print_Set
	for c in value {
		switch c {
		case 'h':
			set += {.Response_Headers}
		case 'b':
			set += {.Response_Body}
		case 'H':
			set += {.Request_Headers}
		case 'B':
			set += {.Request_Body}
		case 'm':
			set += {.Response_Meta}
		case:
		}
	}
	return set
}

@(private)
auth_type_from_string :: proc(value: string) -> Auth_Type {
	switch value {
	case "digest":
		return .Digest
	case "bearer":
		return .Bearer
	case:
		return .Basic
	}
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

// parse_args_with is the parser: everything it reads about the process comes
// from `env`, so a test can drive it with a recorded tty state and environment.
// Ownership of `argv` and `env` stays with the caller.
//
// The third result is the config file's warning — `http: warning: invalid config
// file: …`, already worded, "" when there is nothing to report — and it is the
// caller's to print (main.odin does, before anything else the run writes) and to
// release. It is returned even on the error paths, because the reference reads
// `env.config` before it parses anything: a malformed `config.json` prints its
// warning ahead of the usage block a bad command line produces.
parse_args_with :: proc(env: Env_Info, argv: []string, allocator: mem.Allocator) -> (Options, Parse_Error, string) {
	program_name := program_name_of(argv)
	opts := options_default(allocator, program_name)
	opts.env = env_info_clone(env, allocator)
	opts.colors = colors_from_env(env)
	// The width main.odin wraps the usage block to. It is decided once, here,
	// because the error paths below release the partial Options — and with them
	// the cloned env — before the block is rendered (Parse_Error.width).
	usage_width := console_width(env)

	// The config file is read first, before the `len(argv) <= 1` check below:
	// the reference's `env.config` is touched at the top of `raw_main`
	// (core.py:46-49), so its warning precedes argparse's own missing-URL error
	// as well as every other message.
	config := config_read(env, allocator)
	defer config_read_destroy(&config, allocator)

	// A value `BaseConfigDict.load` itself refuses — a root that is not an
	// object, or a `default_options` that is not a list against the `+ args` of
	// core.py:48-49: the reference dies inside `env.config`, i.e. before the
	// `--debug` block, before argparse and before anything is printed
	// (Config_Read.fatal).
	if config.fatal != "" {
		message := config.fatal
		config.fatal = ""
		options_destroy(&opts)
		return {}, exception_error(allocator, message), config.warning
	}

	// A `default_options` element argparse's `_parse_optional` refuses by *type*
	// is refused while argparse walks the command line (argparse.py:2246-2252),
	// i.e. at the element's own place — and the elements stand first, so nothing
	// else is reached: not the missing-URL error below, not an option error
	// further along, and not the `unrecognized arguments` report that closes the
	// walk either (Config_Read.item_fatal).
	if config.item_fatal != "" {
		message := config.item_fatal
		config.item_fatal = ""
		options_destroy(&opts)
		return {}, exception_error(allocator, message), config.warning
	}

	if len(argv) <= 1 {
		// No arguments at all: argparse still reports the missing URL.
		message := strings.clone("the following arguments are required: URL", allocator) or_else ""
		options_destroy(&opts)
		return {}, usage_error(allocator, message, usage_width), config.warning
	}

	p := Parser {
		allocator        = allocator,
		env              = env,
		ns               = nil,
		arg_strings      = {},
		config_item      = config.item,
		config_item_type = config.item_type,
	}
	ns := namespace_create(allocator)
	p.ns = &ns

	// config default options come first, argv[1:] after them; an element of
	// `default_options` that is not a string stands in the list as
	// CONFIG_ITEM_PLACEHOLDER.
	full_args := make([dynamic]string, 0, len(config.options) + len(argv), allocator)
	defer delete(full_args)
	for option in config.options {
		append(&full_args, option)
	}
	for arg in argv[1:] {
		append(&full_args, arg)
	}
	p.arg_strings = full_args[:]

	defer {
		delete(p.pattern, allocator)
		delete(p.hits, allocator)
		namespace_destroy(&ns)
	}

	if len(p.arg_strings) > 0 {
		if message := scan(&p); message != "" {
			options_destroy(&opts)
			return {}, usage_error(allocator, message, usage_width), config.warning
		}
	}

	// A print-and-exit action ends the run where argparse meets it: the help,
	// manual and version actions call `parser.exit()` from `take_action` while
	// the command line is still being walked, so nothing after that argument is
	// ever reached — none of the steps `process` models and none of the errors
	// they report. Measured: `http --help --continue` prints the help, rc 0,
	// although `--continue` alone is an error; `http --pretty=bogus --help`
	// still reports the option error, because that argument comes first — the
	// scan above walks argv in order and has already returned its message.
	// main.odin writes the text (the session's own `--version` writer), so the
	// parse stops here.
	if ns.meta_action != .None {
		opts.meta_action = ns.meta_action
		opts.show_help = ns.help
		opts.show_manual = ns.manual
		opts.show_version = ns.version
		return opts, {}, config.warning
	}

	if message := process(&p, &opts); message != "" {
		options_destroy(&opts)
		// The one message `process` can return as an exception rather than a
		// usage error is the `--raw` body's `UnicodeEncodeError`: the reference
		// never catches that one, so it prints no usage block either.
		if p.exception {
			return {}, exception_error(allocator, message), config.warning
		}
		return {}, usage_error(allocator, message, usage_width), config.warning
	}
	return opts, {}, config.warning
}

// parse_args reads the live process and parses `argv`, whose first element is
// the program name, as in C. This is what main.odin calls.
parse_args :: proc(argv: []string, allocator: mem.Allocator) -> (Options, Parse_Error, string) {
	env := env_info_from_process(allocator)
	defer env_info_destroy(&env, allocator)
	return parse_args_with(env, argv, allocator)
}
