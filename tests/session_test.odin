package tests

import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import "src:cli"
import "src:http"
import "src:output"
import "src:session"

@(test)
test_session_offline_renders_the_request_head :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	out: strings.Builder
	strings.builder_init(&out, allocator)
	err_out: strings.Builder
	strings.builder_init(&err_out, allocator)

	options, err := parse_cli_plain([]string{"htthor", "--offline", "GET", "localhost:8000/hello"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

	ctx := session.context_create(options, strings.to_writer(&out), strings.to_writer(&err_out))
	exit_code := session.run(&ctx)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	rendered := strings.to_string(out)
	// The rendered head is the reference's, CRLF and all (`--offline -p H` on a
	// pipe: request line, auto headers, `Host`, blank line).
	testing.expectf(t, strings.has_prefix(rendered, "GET /hello HTTP/1.1\r\n"), "rendered: %q", rendered)
	testing.expectf(t, strings.contains(rendered, "Host: localhost:8000"), "rendered: %q", rendered)
	testing.expectf(t, strings.has_suffix(rendered, "\r\n\r\n"), "rendered: %q", rendered)
	testing.expect_value(t, strings.to_string(err_out), "")

	session.context_destroy(&ctx)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	expect_no_leaks(t, &track)
}

@(test)
test_session_version_and_help_need_no_url :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	for flag in ([]string{"--version", "--help"}) {
		out: strings.Builder
		strings.builder_init(&out, allocator)
		err_out: strings.Builder
		strings.builder_init(&err_out, allocator)

		options, err := parse_cli_plain([]string{"htthor", flag}, allocator)
		testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

		ctx := session.context_create(options, strings.to_writer(&out), strings.to_writer(&err_out))
		exit_code := session.run(&ctx)
		testing.expectf(t, exit_code == 0, "%s must exit 0, got %d", flag, exit_code)
		testing.expectf(t, len(strings.to_string(out)) > 0, "%s must print something", flag)

		session.context_destroy(&ctx)
		strings.builder_destroy(&out)
		strings.builder_destroy(&err_out)
	}
	expect_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// The download progress message
// ---------------------------------------------------------------------------

// `-d -o FILE` prints two of httpie's own messages on stderr, and rich wraps
// both to the terminal width: `Downloading to <path>` moves the path to its own
// line when the two do not fit, and folds a path longer than a whole line. The
// three shapes are the ones the reference produces under COLUMNS=80/200 (the
// report on card t_429defab, reproduced from tests/parity's fixture).
@(test)
test_download_message_wraps_at_the_console_width :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// `Downloading to ` is 15 cells, so a 63-cell path is 78 and fits, a
	// 68-cell path is 83 and moves down, and a 153-cell path is folded.
	short := strings.repeat("s", 63, allocator)
	medium := strings.repeat("m", 68, allocator)
	long := strings.repeat("l", 153, allocator)

	fitting := fmt.aprintf("Downloading to %s", short, allocator = context.temp_allocator)
	wrapped := fmt.aprintf("Downloading to %s", medium, allocator = context.temp_allocator)
	folded := fmt.aprintf("Downloading to %s", long, allocator = context.temp_allocator)

	expect_console_line(
		t,
		"fits",
		fitting,
		80,
		fmt.aprintf("Downloading to %s\n", short, allocator = context.temp_allocator),
	)
	expect_console_line(
		t,
		"moves the path down",
		wrapped,
		80,
		fmt.aprintf("Downloading to \n%s\n", medium, allocator = context.temp_allocator),
	)
	expect_console_line(
		t,
		"folds a long path",
		folded,
		80,
		fmt.aprintf(
			"Downloading to \n%s\n%s\n",
			long[:80],
			long[80:],
			allocator = context.temp_allocator,
		),
	)
	// COLUMNS=200 holds the whole line, so nothing moves.
	expect_console_line(
		t,
		"wide console",
		folded,
		200,
		fmt.aprintf("%s\n", folded, allocator = context.temp_allocator),
	)
	// `$COLUMNS=0` is a console zero cells wide, and `Console.render` draws
	// nothing at all below one cell: neither line reaches stderr, and neither
	// does the newline this printer ends them with (`console_silent`,
	// docs/PARITY.md §4.2, t_e0f7b7b3 — measured with `-d -o` against the
	// parity fixture's `/download`).
	expect_console_line(t, "zero width", wrapped, 0, "")

	delete(short, allocator)
	delete(medium, allocator)
	delete(long, allocator)
	expect_no_leaks(t, &track)
}

@(private)
expect_console_line :: proc(
	t: ^testing.T,
	name: string,
	text: string,
	width: int,
	want: string,
) {
	out: strings.Builder
	strings.builder_init(&out, context.temp_allocator)
	console := output.Console {
		writer = strings.to_writer(&out),
		width  = width,
	}
	if err := output.write_console_line(console, text); err != .None {
		testing.expectf(t, false, "%s: write failed: %v", name, err)
		return
	}
	got := strings.to_string(out)
	testing.expectf(
		t,
		got == want,
		"%s: wrapped to\n%q\nwant\n%q",
		name,
		got,
		want,
	)
}

// httpie prints every `http: error:` and `http: warning:` line through its own
// rich console (`env.log_error`, httpie/context.py:170-182), which is why a
// zero-width `$COLUMNS` takes the whole family with it: the console renders
// nothing, so neither the message nor the blank line in front of it nor the
// newlines behind it reach stderr (`console_silent`, docs/PARITY.md §4.2,
// t_e0f7b7b3). The line is never *wrapped* — the reference prints it with
// `soft_wrap=True` — so the width matters only at zero.
@(test)
test_log_line_is_dropped_by_a_zero_width_console :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	message := "InvalidURL: Failed to parse: 'a\U0001F171c' is not a valid host or port"

	out: strings.Builder
	strings.builder_init(&out, context.temp_allocator)
	wide := output.Console {
		writer = strings.to_writer(&out),
		width  = 80,
	}
	if err := output.write_log_error(wide, "http", message); err != .None {
		testing.expectf(t, false, "write failed: %v", err)
		return
	}
	got := strings.to_string(out)
	want := strings.concatenate({"\nhttp: error: ", message, "\n\n\n"}, context.temp_allocator)
	testing.expectf(t, got == want, "the 80-cell line is not the reference's:\n  got  %q\n  want %q", got, want)

	out2: strings.Builder
	strings.builder_init(&out2, context.temp_allocator)
	narrow := output.Console {
		writer = strings.to_writer(&out2),
		width  = 0,
	}
	if err := output.write_log_error(narrow, "http", message); err != .None {
		testing.expectf(t, false, "write failed: %v", err)
		return
	}
	zero := strings.to_string(out2)
	testing.expectf(t, zero == "", "a zero-width console printed %q", zero)
	testing.expectf(
		t,
		output.console_silent(narrow) && !output.console_silent(wide),
		"console_silent did not reject the zero width alone",
	)
}

// A missing URL is argparse's required-arguments failure, so it never reaches
// the session: the reference (`http` with no arguments) prints the usage block
// plus "the following arguments are required: URL" on stderr and exits 1.
@(test)
test_session_missing_url_is_a_usage_error :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	options, err := parse_cli_plain([]string{"htthor"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
	testing.expectf(
		t,
		strings.contains(err.message, "the following arguments are required: URL"),
		"unexpected message: %s",
		err.message,
	)
	testing.expect_value(t, options.url, "")

	cli.parse_error_destroy(&err)
	expect_no_leaks(t, &track)
}

@(test)
test_session_invalid_url_is_a_usage_error :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	out: strings.Builder
	strings.builder_init(&out, allocator)
	err_out: strings.Builder
	strings.builder_init(&err_out, allocator)

	options, err := parse_cli_plain([]string{"htthor", "ftp://example.com/"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

	ctx := session.context_create(options, strings.to_writer(&out), strings.to_writer(&err_out))
	exit_code := session.run(&ctx)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Error))

	session.context_destroy(&ctx)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	expect_no_leaks(t, &track)
}

// A `:=`/`:=@` data item never reaches a **multipart** body. The reference
// builds that body from `args.multipart_data`, and only the separators of
// `SEPARATORS_GROUP_MULTIPART` (`=`, `=@`, `@`) are ever put into it
// (httpie/cli/requestitems.py:112-113), so a raw-JSON item — accepted by the
// CLI, and part of `args.data` — contributes no part at all. The JSON body and
// the urlencoded form body *are* built from `args.data`, which keeps it, so the
// rule is a property of the multipart road alone (docs/PARITY.md §1.2).
//
// The table is that road's three separators plus the two roads that must not
// move: a multipart body keeps its `=` part beside a dropped `:=`, a `--form`
// without a file field still urlencodes the item, and the default JSON body
// still serialises it.
@(test)
test_session_multipart_body_takes_multipart_data_only :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	head := [?]string{
		"htthor", "--offline", "--ignore-stdin", "--pretty=none", "-p", "B",
		"--boundary=B",
	}
	tail := [?]string{"POST", "http://example.org/x"}

	Case :: struct {
		flags: []string,
		items: []string,
		body:  string,
	}
	part_a := "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n"
	terminator := "--B--\r\n"
	cases := []Case {
		// The multipart road: `=` reaches it, `:=` and `:=@` do not.
		{[]string{"--multipart"}, []string{"a=1"}, part_a},
		{[]string{"--multipart"}, []string{"a:=1"}, terminator},
		{[]string{"--multipart"}, []string{"a:=\"x\""}, terminator},
		{[]string{"--multipart"}, []string{"a=1", "b:=2"}, part_a},
		// The two roads built from `args.data`: the item stays.
		{[]string{"-f"}, []string{"a:=1"}, "a=1"},
		{nil, []string{"a:=1"}, "{\"a\": 1}"},
	}

	for entry in cases {
		// A stack argv: nothing to free, and it outlives the run below.
		argv: [16]string
		count := 0
		for arg in head {
			argv[count] = arg
			count += 1
		}
		for flag in entry.flags {
			argv[count] = flag
			count += 1
		}
		for arg in tail {
			argv[count] = arg
			count += 1
		}
		for item in entry.items {
			argv[count] = item
			count += 1
		}

		out: strings.Builder
		strings.builder_init(&out, allocator)
		err_out: strings.Builder
		strings.builder_init(&err_out, allocator)

		options, err := parse_cli_plain(argv[:count], allocator)
		testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

		ctx := session.context_create(options, strings.to_writer(&out), strings.to_writer(&err_out))
		exit_code := session.run(&ctx)
		testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))
		testing.expectf(
			t,
			strings.to_string(out) == entry.body,
			"items %v: body %q, want %q (stderr %q)",
			entry.items,
			strings.to_string(out),
			entry.body,
			strings.to_string(err_out),
		)

		session.context_destroy(&ctx)
		strings.builder_destroy(&out)
		strings.builder_destroy(&err_out)
	}
	expect_no_leaks(t, &track)
}

// A console rich cannot build is the *other* way a log line disappears, and it
// is not the same disappearance: `Console.__init__` raises before the console
// exists, so the reference dies there (`console_crash`, docs/PARITY.md §3.1,
// §8.20, t_14a26d57). The port writes the exception's own line in its usual
// shape — the interpreter's message, not the run's — and the caller ends the
// run with status 1, so both `write_log_error` and `write_log_warning` are the
// same four bytes short of a message.
@(test)
test_log_line_becomes_the_conversion_line_when_rich_cannot_build_the_console :: proc(
	t: ^testing.T,
) {
	defer free_all(context.temp_allocator)

	columns := "\u00b2" // SUPERSCRIPT TWO: `isdigit()` yes, `int()` no
	want := "\nhttp: error: ValueError: invalid literal for int() with base 10: '\u00b2'\n\n\n"

	levels := []string{"error", "warning"}
	for level in levels {
		out: strings.Builder
		strings.builder_init(&out, context.temp_allocator)
		console := output.Console {
			writer = strings.to_writer(&out),
			width  = cli.RICH_WIDTH,
			crash  = columns,
		}
		err := level == "error" \
			? output.write_log_error(console, "http", "InvalidURL: this is never printed") \
			: output.write_log_warning(console, "http", "this is never printed either")
		if err != .None {
			testing.expectf(t, false, "%s: write failed: %v", level, err)
			continue
		}
		got := strings.to_string(out)
		testing.expectf(
			t,
			got == want,
			"%s: the crash line is not the reference's:\n  got  %q\n  want %q",
			level,
			got,
			want,
		)
	}

	// The console the port reads out of the run's environment is the one the
	// writers take, value and all: `console_crash` is what the line quotes.
	env := cli.env_info_from_strings([]string{"COLUMNS=1\u00b2"}, false, false, false, context.temp_allocator)
	out: strings.Builder
	strings.builder_init(&out, context.temp_allocator)
	console := output.Console {
		writer = strings.to_writer(&out),
		width  = cli.console_width(env),
		crash  = cli.console_crash(env),
	}
	if err := output.write_log_error(console, "http", "unused"); err != .None {
		testing.expectf(t, false, "write failed: %v", err)
		return
	}
	got := strings.to_string(out)
	want = "\nhttp: error: ValueError: invalid literal for int() with base 10: '1\u00b2'\n\n\n"
	testing.expectf(t, got == want, "COLUMNS='1²':\n  got  %q\n  want %q", got, want)
}

// A session with no URL and no meta flag must not allocate a request; the
// writers are only handed io.Writer values, which is what keeps the session
// testable without a terminal.
@(test)
test_session_writers_are_io_writers :: proc(t: ^testing.T) {
	out: strings.Builder
	strings.builder_init(&out)
	defer strings.builder_destroy(&out)

	writer: io.Writer = strings.to_writer(&out)
	io.write_string(writer, "rendered")
	testing.expect_value(t, strings.to_string(out), "rendered")
}

// The `-d -o FILE` path end to end: the session hands the open file to the
// transport (`send_to`), which writes the body into it as it arrives, and the
// reference's two progress messages land on stderr. The engine tests call the
// transport directly, so this is the only test that covers the CLI's own
// download wiring — the path that used to buffer the whole body and then write
// it in one call (backlog M3).
@(test)
test_download_streams_the_body_into_the_output_file :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the engine server must start")
	engine_queue_reply(
		server,
		"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 14\r\nConnection: close\r\n\r\nhello download",
	)

	scratch := engine_scratch_dir(t)
	download_path := fmt.aprintf("%s/htthor_session_download.txt", scratch, allocator = allocator)
	os.remove(download_path)
	url := engine_url(server, "/download", allocator)

	out: strings.Builder
	strings.builder_init(&out, allocator)
	err_out: strings.Builder
	strings.builder_init(&err_out, allocator)

	options, err := parse_cli_plain(
		[]string{"htthor", "--download", "--output", download_path, url},
		allocator,
	)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

	ctx := session.context_create(options, strings.to_writer(&out), strings.to_writer(&err_out))
	exit_code := session.run(&ctx)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	// The body is the file's, and only the messages went to the streams: with
	// --download httpie moves everything that is not the body to stderr
	// (cli/argparser.py:242-245).
	contents, read_err := os.read_entire_file_from_path(download_path, allocator)
	testing.expect(t, read_err == nil, "the download must be readable")
	testing.expect_value(t, string(contents), "hello download")
	testing.expect_value(t, strings.to_string(out), "")
	stderr_text := strings.to_string(err_out)
	testing.expectf(
		t,
		strings.contains(stderr_text, "Downloading to "),
		"the progress line must reach stderr, got %q",
		stderr_text,
	)

	session.context_destroy(&ctx)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	delete(contents, allocator)
	delete(url, allocator)
	os.remove(download_path)
	delete(download_path, allocator)
	engine_server_destroy(server)
	expect_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// build_request, phase by phase
// ---------------------------------------------------------------------------

// These cases go one step further than the run: they call `session.build_request`
// on the request the options describe, so a phase can be asserted where the whole
// run only shows it through a rendered head or a written file. Nothing the file
// already covers is repeated: the request head end to end is
// `test_session_offline_renders_the_request_head`, the multipart road and the
// `:=` item it drops are `test_session_multipart_body_takes_multipart_data_only`,
// the missing-password refusal is
// `test_a_missing_password_without_the_environment_stops_the_run`
// (tests/auth_password_test.odin), the session file's bytes and the cookie jar are
// `session_store_test.odin`'s captures, and the body bytes these phases hand the
// engine are the engine tests' (tests/http_engine_test.odin).
@(private)
build_request_from :: proc(
	t: ^testing.T,
	argv: []string,
	allocator: mem.Allocator,
	out: ^strings.Builder,
	err_out: ^strings.Builder,
	request: ^http.Request,
) -> (
	ctx: session.Context,
	ok: bool,
) {
	options, err := parse_cli_plain(argv, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	if err.kind != .None {
		cli.parse_error_destroy(&err)
		return ctx, false
	}
	built := session.context_create(options, strings.to_writer(out), strings.to_writer(err_out))
	ok = session.build_request(&built, request, nil)
	return built, ok
}

// session_seeded opens the captured `cap1.json` session — the headers `Accept`
// and `X-Session-Header: keepme`, bound to 127.0.0.1:8765 — as `name`, and makes
// the context whose options describe `argv`: the two things `session.run` has in
// hand when it builds the request (context.odin:135-150).
@(private)
session_seeded :: proc(
	t: ^testing.T,
	sandbox: string,
	name: string,
	argv: []string,
	allocator: mem.Allocator,
	out: ^strings.Builder,
	err_out: ^strings.Builder,
) -> (
	instance: session.Session,
	ctx: session.Context,
	ok: bool,
) {
	// `name` is the session's name as the CLI takes it (`--session=merge`, so the
	// file the CLI resolves is `merge.json`); session_seed writes the file name
	// it is handed without adding the extension (session_store_test.odin).
	file_name := fmt.aprintf("%s.json", name, allocator = allocator)
	session_seed(t, sandbox, "cap1.json", file_name)
	delete(file_name, allocator)
	options, parse_err := session_options(t, argv, sandbox, allocator)
	testing.expect_value(t, parse_err.kind, cli.Parse_Error_Kind.None)
	if parse_err.kind != .None {
		cli.parse_error_destroy(&parse_err)
		return instance, ctx, false
	}
	log := output.Console {
		writer = strings.to_writer(err_out),
		width  = cli.RICH_WIDTH,
	}
	opened: bool
	instance, opened = session.session_open(&options, log, allocator)
	if !opened {
		// session_open reports the failure itself; the options are still the
		// caller's then.
		cli.options_destroy(&options)
		return instance, ctx, false
	}
	return instance, session.context_create(options, strings.to_writer(out), strings.to_writer(err_out)), true
}

// header_index_of is the slot of the first header with that name, or -1.
@(private)
header_index_of :: proc(request: ^http.Request, name: string) -> int {
	for header, index in request.headers {
		if strings.equal_fold(header.name, name) {
			return index
		}
	}
	return -1
}

// header_count_of is how many entries carry that name: a merge replaces a name's
// value in its slot, so the answer is one and not two.
@(private)
header_count_of :: proc(request: ^http.Request, name: string) -> int {
	count := 0
	for header in request.headers {
		if strings.equal_fold(header.name, name) {
			count += 1
		}
	}
	return count
}

// The session's base headers are merged first (`base_headers`, client.py:48-63):
// they are the request dict's first entries, ahead of the item headers, and a
// name the session carries is not duplicated by the merge.
@(test)
test_build_request_merges_the_session_headers_before_the_items :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "build-merge", allocator)
	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	argv := []string{
		"htthor", "--session=merge", "--offline", "-p", "h", "--pretty=none",
		"http://127.0.0.1:8765/echo", "X-Item-Only:1",
	}
	instance, ctx, opened := session_seeded(
		t,
		sandbox,
		"merge",
		argv,
		allocator,
		&out,
		&err_out,
	)
	testing.expectf(
		t,
		opened,
		"the session could not be opened: %s",
		strings.to_string(err_out),
	)
	if opened {
		request: http.Request
		built := session.build_request(&ctx, &request, &instance)
		testing.expect(t, built, "the request must be built")

		session_header := header_index_of(&request, "X-Session-Header")
		item_header := header_index_of(&request, "X-Item-Only")
		testing.expectf(
			t,
			session_header >= 0,
			"the session's X-Session-Header is missing from %v",
			request.headers,
		)
		testing.expectf(t, item_header >= 0, "the item header is missing from %v", request.headers)
		if session_header >= 0 && item_header >= 0 {
			testing.expect_value(t, request.headers[session_header].value, "keepme")
			testing.expect_value(t, request.headers[item_header].value, "1")
			// The session's headers are the first entries of the dict, so they
			// are ahead of the item headers in the ordered list as well.
			testing.expectf(
				t,
				session_header < item_header,
				"the session's header must precede the item header: %v",
				request.headers,
			)
		}
		// Both the session's names survive the merge once: its `Accept` is the
		// one httpie's own `Accept` would have been merged behind (the two hold
		// the same value), and X-Session-Header is the item-less name.
		testing.expect_value(t, header_count_of(&request, "Accept"), 1)
		testing.expect_value(t, header_count_of(&request, "X-Session-Header"), 1)

		http.request_destroy(&request)
		session.session_destroy(&instance)
	}
	session.context_destroy(&ctx)
	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}
// An item header that repeats a session header takes the session's slot: requests
// merges the item dict over the session's headers (sessions.py:461-476), so the
// value is replaced where the session put the name and the name keeps the
// spelling the session file wrote (`replace_session_header`).
@(test)
test_build_request_item_header_overrides_the_session_header_in_place :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "build-override", allocator)
	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// The item's spelling is lower-case on purpose: the session's is the one the
	// request must carry, because the value is what is replaced.
	argv := []string{
		"htthor", "--session=override", "--offline", "-p", "h", "--pretty=none",
		"http://127.0.0.1:8765/echo", "x-session-header:changed",
	}
	instance, ctx, opened := session_seeded(
		t,
		sandbox,
		"override",
		argv,
		allocator,
		&out,
		&err_out,
	)
	testing.expectf(
		t,
		opened,
		"the session could not be opened: %s",
		strings.to_string(err_out),
	)
	if opened {
		request: http.Request
		built := session.build_request(&ctx, &request, &instance)
		testing.expect(t, built, "the request must be built")

		index := header_index_of(&request, "X-Session-Header")
		testing.expectf(t, index >= 0, "the name left the request: %v", request.headers)
		if index >= 0 {
			testing.expect_value(t, request.headers[index].name, "X-Session-Header")
			testing.expect_value(t, request.headers[index].value, "changed")
		}
		testing.expect_value(t, header_count_of(&request, "X-Session-Header"), 1)

		http.request_destroy(&request)
		session.session_destroy(&instance)
	}
	session.context_destroy(&ctx)
	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// `--auth user:pass` is `args.auth` (client.py:372): the credentials reach the
// request as requests' own `prepare_auth` pair — the auth fields, and the
// `Authorization` header `request_prepare` derives from them (models.py:452-499).
// The `-A digest` value is the scheme, which is the one thing that differs.
@(test)
test_build_request_auth_fills_the_credentials_and_the_header :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	basic_argv := []string{
		"htthor", "--auth", "user:pass", "--offline", "-p", "h", "--pretty=none",
		"http://example.org/x",
	}
	request: http.Request
	ctx, built := build_request_from(t, basic_argv, allocator, &out, &err_out, &request)
	testing.expectf(
		t,
		built,
		"the request must be built (stderr %q)",
		strings.to_string(err_out),
	)
	testing.expect_value(t, request.auth, "user:pass")
	testing.expect_value(t, request.auth_type, http.Auth_Type.Basic)
	// `Basic dXNlcjpwYXNz` is base64("user:pass"), which is the value the
	// reference's plugin assigns (plugins/builtin.py:33).
	authorization, has_authorization := http.request_header_get(&request, "Authorization")
	testing.expect(t, has_authorization, "the credentials must be preemptive")
	testing.expect_value(t, authorization, "Basic dXNlcjpwYXNz")
	http.request_destroy(&request)
	session.context_destroy(&ctx)

	digest_argv := []string{
		"htthor", "--auth", "user:pass", "-A", "digest", "--offline",
		"http://example.org/x",
	}
	request_digest: http.Request
	digest_ctx, digest_built := build_request_from(
		t,
		digest_argv,
		allocator,
		&out,
		&err_out,
		&request_digest,
	)
	testing.expectf(
		t,
		digest_built,
		"the digest request must be built (stderr %q)",
		strings.to_string(err_out),
	)
	testing.expect_value(t, request_digest.auth, "user:pass")
	testing.expect_value(t, request_digest.auth_type, http.Auth_Type.Digest)
	http.request_destroy(&request_digest)
	session.context_destroy(&digest_ctx)

	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	expect_no_leaks(t, &track)
}

// Which body a request carries decides the encoding *and* the Content-Type the
// request goes out with: the JSON request type serialises the items
// (client.py:311-319), `--form` urlencodes them, `--raw` hands the bytes over
// (argparser.py:182-185) and a multipart body takes its Content-Type from the
// CLI's own item (client.py:353-358). The engine tests send these bytes; this is
// what the session decides before any of them.
@(test)
test_build_request_body_kinds_decide_the_content_type :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// The multipart part the `--boundary=B` run produces, as
	// test_session_multipart_body_takes_multipart_data_only renders it.
	part_a := "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n"

	Case :: struct {
		name:         string,
		flags:        []string,
		items:        []string,
		body:         string,
		content_type: string,
		kind:         http.Body_Kind,
	}
	cases := []Case {
		{
			name         = "json",
			items        = []string{"a=1"},
			body         = `{"a": "1"}`,
			content_type = http.JSON_CONTENT_TYPE,
			kind         = .JSON,
		},
		{
			name         = "form",
			flags        = []string{"-f"},
			items        = []string{"a=1"},
			body         = "a=1",
			content_type = http.FORM_CONTENT_TYPE,
			kind         = .Form,
		},
		{
			name         = "raw",
			flags        = []string{"--raw", "hello"},
			body         = "hello",
			content_type = http.JSON_CONTENT_TYPE,
			kind         = .Raw,
		},
		{
			name         = "multipart",
			flags        = []string{"--multipart", "--boundary=B"},
			items        = []string{"Content-Type:application/x-custom", "a=1"},
			body         = part_a,
			content_type = "application/x-custom; boundary=B",
			kind         = .Multipart,
		},
	}

	for entry in cases {
		// A stack argv: nothing to free, and it outlives the run below. The
		// method's positional must be followed by the URL, so the flags come
		// first.
		argv: [10]string
		count := 0
		argv[count] = "htthor"
		count += 1
		for flag in entry.flags {
			argv[count] = flag
			count += 1
		}
		argv[count] = "POST"
		count += 1
		argv[count] = "http://example.org/x"
		count += 1
		for item in entry.items {
			argv[count] = item
			count += 1
		}

		session_out, session_err: strings.Builder
		strings.builder_init(&session_out, allocator)
		strings.builder_init(&session_err, allocator)

		request: http.Request
		ctx, built := build_request_from(
			t,
			argv[:count],
			allocator,
			&session_out,
			&session_err,
			&request,
		)
		testing.expectf(
			t,
			built,
			"%s: the request must be built (stderr %q)",
			entry.name,
			strings.to_string(session_err),
		)
		testing.expect_value(t, request.body_kind, entry.kind)
		testing.expectf(
			t,
			string(request.body) == entry.body,
			"%s: body %q, want %q",
			entry.name,
			string(request.body),
			entry.body,
		)
		content_type, has_content_type := http.request_header_get(&request, "Content-Type")
		testing.expectf(
			t,
			has_content_type && content_type == entry.content_type,
			"%s: Content-Type %q (present %v), want %q",
			entry.name,
			content_type,
			has_content_type,
			entry.content_type,
		)

		http.request_destroy(&request)
		session.context_destroy(&ctx)
		strings.builder_destroy(&session_out)
		strings.builder_destroy(&session_err)
	}

	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	expect_no_leaks(t, &track)
}

// The `name==value` items are `args.params` (client.py:373) and they are added in
// command-line order, beside the URL's own query — which is what the target
// renders. The one URL kind requests never prepared takes none of them:
// `prepare_url` returns before it encodes `_encode_params` (models.py:498-505,
// :550).
@(test)
test_build_request_query_items_keep_the_url_query_and_the_item_order :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	argv := []string{
		"htthor", "GET", "http://example.org/x?a=0", "a==1", "b==2",
	}
	request: http.Request
	ctx, built := build_request_from(t, argv, allocator, &out, &err_out, &request)
	testing.expectf(
		t,
		built,
		"the request must be built (stderr %q)",
		strings.to_string(err_out),
	)
	testing.expect_value(t, request.query_raw, "a=0")
	testing.expect_value(t, len(request.query), 2)
	if len(request.query) == 2 {
		testing.expect_value(t, request.query[0].name, "a")
		testing.expect_value(t, request.query[0].value, "1")
		testing.expect_value(t, request.query[1].name, "b")
		testing.expect_value(t, request.query[1].value, "2")
	}
	http.request_destroy(&request)
	session.context_destroy(&ctx)

	// A URL requests never prepared keeps its own query and takes no item.
	unprepared_argv := []string{
		"htthor", "GET", "file:///etc/hostname", "a==1",
	}
	request_unprepared: http.Request
	unprepared_ctx, unprepared_built := build_request_from(
		t,
		unprepared_argv,
		allocator,
		&out,
		&err_out,
		&request_unprepared,
	)
	testing.expectf(
		t,
		unprepared_built,
		"the unprepared request must be built (stderr %q)",
		strings.to_string(err_out),
	)
	testing.expect_value(t, request_unprepared.url_kind, http.Url_Kind.Unprepared)
	testing.expect_value(t, len(request_unprepared.query), 0)
	http.request_destroy(&request_unprepared)
	session.context_destroy(&unprepared_ctx)

	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	expect_no_leaks(t, &track)
}

// httpie's own session-level headers reach the request — libcurl cannot know
// them (`make_default_headers`, client.py:263-278) — and an item that *unsets* a
// name keeps the default away: the reference's `None` pair removed the name from
// the dict the defaults were merged into. The item that sets a value is the
// value that goes out, not the default (add_default_header).
@(test)
test_build_request_defaults_yield_to_an_item_and_an_unset :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	argv := []string{
		"htthor", "GET", "http://example.org/x", "User-Agent:", "Accept-Encoding:custom",
	}
	request: http.Request
	ctx, built := build_request_from(t, argv, allocator, &out, &err_out, &request)
	testing.expectf(
		t,
		built,
		"the request must be built (stderr %q)",
		strings.to_string(err_out),
	)
	// The unset becomes urllib3's SKIP_HEADER sentinel rather than no entry at
	// all: the name stays in urllib3's own list so the `User-Agent` *it* would
	// add is suppressed, and the line is dropped at the wire (`client.py:190-209`
	// in `skippable.odin`). The port keeps the name in `unset_headers` for the
	// same reason.
	user_agent, has_user_agent := http.request_header_get(&request, "User-Agent")
	testing.expect(t, has_user_agent)
	testing.expect_value(t, user_agent, http.SKIP_HEADER)
	testing.expect(t, http.request_header_unset(&request, "User-Agent"))
	// The item that sets a value is the value that goes out, not the default.
	accept_encoding, has_accept_encoding := http.request_header_get(&request, "Accept-Encoding")
	testing.expect(t, has_accept_encoding)
	testing.expect_value(t, accept_encoding, "custom")
	connection, has_connection := http.request_header_get(&request, "Connection")
	testing.expect(t, has_connection)
	testing.expect_value(t, connection, "keep-alive")
	http.request_destroy(&request)
	session.context_destroy(&ctx)

	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	expect_no_leaks(t, &track)
}

// The three doors a build fails at, each one printing httpie's runtime error and
// answering false: the URL's host rule before anything is prepared, requests'
// header rule after the merge, and the nested-JSON body the CLI's grammar left
// broken. Two things run() depends on are asserted with them: what reaches the
// message stream (the run's `error:`) and that a failure leaves the request in a
// state `request_destroy` can take, filled part-way or not at all
// (context.odin:150-158). The printed line is the reference's `HTTPError`
// leaving `client.main` and reaching the run's stderr with a failing exit status
// (core.py:138-141, `handle_generic_error`); the JSON door's text is the port's
// own `cli.type_error` (items.odin, interpret.py:14-20).
//
// The body door is the nested-JSON *type* error, not the `Expecting ']'` syntax
// error: `cli.parse_nested_path` returns the partial token list it built without
// releasing it on that path — a leak of the CLI's, not of the build — which this
// test's tracker would report as its own.
@(test)
test_build_request_failure_doors_print_the_runtime_error :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	Case :: struct {
		name:    string,
		argv:    []string,
		message: string,
		// filled is whether the failing step leaves headers on the request: the
		// host rule refuses before the URL is assigned, the other two after the
		// merge.
		filled: bool,
	}
	cases := []Case {
		{
			name    = "the URL's host rule",
			argv    = []string{"htthor", "GET", "http://[zzz]/x"},
			message = "InvalidURL: Failed to parse: '[zzz]' is not a valid host or port",
			filled  = false,
		},
		{
			name    = "requests' header rule",
			argv    = []string{"htthor", "GET", "http://example.org/x", "X-Note:a\nb"},
			message = "InvalidHeader: Invalid leading whitespace, reserved character(s), or return character(s) in header value: b'a\\nb'",
			filled  = true,
		},
		{
			name    = "the JSON body",
			argv    = []string{"htthor", "POST", "http://example.org/x", "X-Item-Only:1", "a=1", "a[b]=2"},
			message = "HTTPie Type Error: Cannot perform 'key' based access on 'a'",
			filled  = true,
		},
	}

	for entry in cases {
		out, err_out: strings.Builder
		strings.builder_init(&out, allocator)
		strings.builder_init(&err_out, allocator)

		request: http.Request
		ctx, built := build_request_from(t, entry.argv, allocator, &out, &err_out, &request)
		testing.expectf(t, !built, "%s: the build must fail", entry.name)
		message := strings.to_string(err_out)
		testing.expectf(
			t,
			strings.contains(message, entry.message),
			"%s: stderr %q, want it to carry %q",
			entry.name,
			message,
			entry.message,
		)
		testing.expectf(
			t,
			strings.to_string(out) == "",
			"%s: nothing may reach stdout, got %q",
			entry.name,
			strings.to_string(out),
		)
		testing.expectf(
			t,
			(len(request.headers) > 0) == entry.filled,
			"%s: the request holds %d headers, filled %v",
			entry.name,
			len(request.headers),
			entry.filled,
		)

		// What the run does with a failed build; a partly built request is what
		// makes this the site that has to release it (context.odin:150-158).
		http.request_destroy(&request)
		session.context_destroy(&ctx)
		strings.builder_destroy(&out)
		strings.builder_destroy(&err_out)
	}
	expect_no_leaks(t, &track)
}

// The `auto_json` switch decides requests' own `Accept` — the pair
// `make_default_headers` turns on (`client.py:263-278`; the value is
// `JSON_ACCEPT`, http/body.odin) — and the transport policy the send carries is
// copied down here rather than by the engine (`client.py:281-312`,
// `client.py:361`): the CLI's numbers and switches have to land on the request
// the build answers with. Both sides of the switch are asserted, because
// `auto_json = args.data and not args.form` is what makes `--json` and a
// non-form body the two ways in.
@(test)
test_build_request_auto_json_switch_and_transport_policy :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// --json asks for the pair; the transport flags are httpie's own spellings
	// (cli/parse.odin's table).
	argv := []string{
		"htthor", "--json", "--timeout=5", "--verify=no", "--max-redirects=3",
		"--max-headers=7", "--chunked", "POST", "http://example.org/x", "a=1",
	}
	request: http.Request
	ctx, built := build_request_from(t, argv, allocator, &out, &err_out, &request)
	testing.expectf(
		t,
		built,
		"the request must be built (stderr %q)",
		strings.to_string(err_out),
	)
	testing.expect(t, request.json_accept)
	// The Accept is added by requests' prepared-request step from that flag:
	// without it the request keeps requests' own `*/*` (http/request.odin).
	accept, has_accept := http.request_header_get(&request, "Accept")
	testing.expect(t, has_accept)
	testing.expect_value(t, accept, http.JSON_ACCEPT)

	testing.expect_value(t, request.timeout_s, 5)
	testing.expect(t, !request.follow_redirects)
	testing.expect_value(t, request.max_redirects, 3)
	testing.expect_value(t, request.max_headers, 7)
	testing.expect(t, !request.verify)
	testing.expect(t, request.chunked)
	testing.expect(t, !request.offline)

	http.request_destroy(&request)
	session.context_destroy(&ctx)

	// The other side: no --json and no body, so the pair stays off.
	plain_argv := []string{"htthor", "GET", "http://example.org/x"}
	plain: http.Request
	plain_ctx, plain_built := build_request_from(t, plain_argv, allocator, &out, &err_out, &plain)
	testing.expectf(
		t,
		plain_built,
		"the plain request must be built (stderr %q)",
		strings.to_string(err_out),
	)
	testing.expect(t, !plain.json_accept)
	plain_accept, plain_has_accept := http.request_header_get(&plain, "Accept")
	testing.expect(t, plain_has_accept)
	testing.expect_value(t, plain_accept, http.NON_JSON_ACCEPT)
	http.request_destroy(&plain)
	session.context_destroy(&plain_ctx)

	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	expect_no_leaks(t, &track)
}
