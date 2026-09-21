package tests

import "core:fmt"
import "core:io"
import "core:mem"
import "core:strings"
import "core:testing"

import "src:cli"
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
