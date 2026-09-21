// H4 (docs/rating/HTThor-remediation-backlog.md): `--stream`/`-S` is the
// reference's `ProcessingOptions.stream`, and what the reference does with it is
// set `is_stream` for the message (output/writer.py:162-171) — the value the
// stream class is picked by (writer.py:172-192). These tests pin the two
// consequences of that choice this port can observe:
//
//   - the line-oriented `PrettyStream` yields no line for a body the message
//     does not have, so an empty body never reaches its formatter or its
//     encoder, where `BufferedPrettyStream` yields a body of its own outside the
//     read loop (output/streams.py:198-226, :238-250) — a charset name the
//     registry has no codec for is what that shows, because the buffered stream's
//     `smart_encode` is where the reference's `LookupError` is raised;
//   - every line `PrettyStream` yields ends in a line feed (streams.py:216, and
//     models.py:67-68 is where a *response*'s line comes by one), so a streamed
//     body whose last line carries no line break of its own gains one.
//
// The first test drives the flag from argv through the session, which is the
// defect the row records: `opts.stream` was parsed, stored and read by nothing.
package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:cli"
import "src:http"
import "src:output"
import "src:session"

// STREAM_REPLY_NO_LF answers with a `text/plain` body that has no line break of
// its own (12 bytes); STREAM_REPLY_LF is the same body with one (14).
STREAM_REPLY_NO_LF :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 12\r\nConnection: close\r\n\r\nno line feed"
STREAM_REPLY_LF :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 14\r\nConnection: close\r\n\r\nhas line feed\n"

// STREAM_REPLY_EMPTY_BAD_CHARSET answers with no body and a charset name no
// registry has a codec for. The name is only ever *used* by an encoder, so
// whether the run ends in httpie's `LookupError` is decided by which stream the
// empty body goes to.
STREAM_REPLY_EMPTY_BAD_CHARSET :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=bogus\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

// ---------------------------------------------------------------------------
// The flag, through the CLI
// ---------------------------------------------------------------------------

@(test)
test_the_stream_flag_reaches_the_renderer :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	// Without the flag a prettify group picks `BufferedPrettyStream`, which
	// writes the body as it stands: no line feed is added.
	buffered := stream_run_reply(
		t,
		backing,
		allocator,
		STREAM_REPLY_NO_LF,
		[]string{"htthor", "--print=b", "--pretty=format"},
	)
	testing.expect_value(t, buffered.exit_code, int(cli.Exit_Code.Ok))
	testing.expect_value(t, buffered.stdout, "no line feed")

	// `-S` is `is_stream`, which picks `PrettyStream`: this reply is yielded by
	// line, so its last line ends in an LF even though the body does not
	// (models.py:67-68).
	streamed := stream_run_reply(
		t,
		backing,
		allocator,
		STREAM_REPLY_NO_LF,
		[]string{"htthor", "--print=b", "--pretty=format", "-S"},
	)
	testing.expect_value(t, streamed.exit_code, int(cli.Exit_Code.Ok))
	testing.expect_value(t, streamed.stdout, "no line feed\n")

	// A body whose last line already ends in a line break gains nothing — the
	// line feed is the one `iter_lines` appends, not an extra one.
	terminated := stream_run_reply(
		t,
		backing,
		allocator,
		STREAM_REPLY_LF,
		[]string{"htthor", "--print=b", "--pretty=format", "--stream"},
	)
	testing.expect_value(t, terminated.stdout, "has line feed\n")

	// With no prettify group the reply is `RawStream`'s, which is the wire's
	// bytes and nothing else: the flag changes no byte there. (That is the
	// stream the port already had, and it is `--stream`'s other half in
	// writer.py:172-180 — the read size, which the transport's own buffering
	// answers for, not the renderer.)
	raw := stream_run_reply(
		t,
		backing,
		allocator,
		STREAM_REPLY_NO_LF,
		[]string{"htthor", "--print=b", "--pretty=none", "--stream"},
	)
	testing.expect_value(t, raw.stdout, "no line feed")

	stream_run_destroy(&buffered, allocator)
	stream_run_destroy(&streamed, allocator)
	stream_run_destroy(&terminated, allocator)
	stream_run_destroy(&raw, allocator)
	expect_no_leaks(t, &track)
}

// The empty body is the reply the two streams disagree about on every run: the
// line-oriented one sees no line at all and asks nothing, where the buffered one
// processes the body it does not have — and an encoder the registry cannot
// resolve is the reference's `LookupError`, which ends the run.
@(test)
test_a_streamed_empty_body_asks_no_encoder :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	buffered := stream_run_reply(
		t,
		backing,
		allocator,
		STREAM_REPLY_EMPTY_BAD_CHARSET,
		[]string{"htthor", "--print=b", "--pretty=format"},
	)
	testing.expect_value(t, buffered.exit_code, int(cli.Exit_Code.Error))
	testing.expect_value(t, buffered.stdout, "")
	testing.expectf(
		t,
		strings.contains(buffered.stderr, "LookupError: unknown encoding: bogus"),
		"the buffered stream's encoder must report the name: %q",
		buffered.stderr,
	)

	streamed := stream_run_reply(
		t,
		backing,
		allocator,
		STREAM_REPLY_EMPTY_BAD_CHARSET,
		[]string{"htthor", "--print=b", "--pretty=format", "-S"},
	)
	testing.expect_value(t, streamed.exit_code, int(cli.Exit_Code.Ok))
	testing.expect_value(t, streamed.stdout, "")
	testing.expect_value(t, streamed.stderr, "")

	stream_run_destroy(&buffered, allocator)
	stream_run_destroy(&streamed, allocator)
	expect_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// The two streams, at the renderer
// ---------------------------------------------------------------------------

// `text/event-stream` is `is_stream` without the flag (writer.py:164-171): the
// same line-oriented stream a `--stream` run of any content type gets, which is
// why the two agree on what they write.
@(test)
test_an_event_stream_is_the_line_oriented_stream_without_the_flag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	prettified := stream_render_reply(
		t,
		allocator,
		"text/event-stream",
		"data: no line break",
		false,
		true,
		false,
	)
	testing.expect_value(t, prettified, "data: no line break\n")

	// The same reply, streamed by the flag rather than by its Content-Type:
	// one byte for byte equal body.
	flagged := stream_render_reply(
		t,
		allocator,
		"text/event-stream",
		"data: no line break",
		true,
		true,
		false,
	)
	testing.expect_value(t, flagged, prettified)

	// No prettify group: the encode/colour stream is not asked for, so the
	// body is `RawStream`'s — the wire's bytes, with no line feed added even
	// though the message *is* streamed.
	raw := stream_render_reply(t, allocator, "text/event-stream", "data: no line break", true, false, false)
	testing.expect_value(t, raw, "data: no line break")

	// The `colors` group alone (a pipe with `--pretty=colors`) is the other
	// prettified stream, and the line feed is the stream's, not the format
	// group's: under the flag the coloured body ends in one too.
	buffered_colors := stream_render_reply(t, allocator, "text/plain", "plain body", false, false, true)
	streamed_colors := stream_render_reply(t, allocator, "text/plain", "plain body", true, false, true)
	testing.expect_value(t, streamed_colors, strings.concatenate({buffered_colors, "\n"}, context.temp_allocator))
}

// A request is the message the choice does not change: `HTTPRequest.iter_lines`
// yields its whole body as one line with no line feed (models.py:136-137), so it
// reads the same in either stream — and the port asks for the buffered one
// (`write_request` passes false), which is what this pins.
@(test)
test_a_request_body_never_gains_a_line_feed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	style, found := output.style_lookup(output.DEFAULT_STYLE_NAME)
	testing.expect(t, found, "the default style must resolve")
	config := output.Write_Config {
		allocator     = allocator,
		style         = style,
		variant       = .Pygments_Http,
		pretty_format = true,
		stream        = true,
	}
	request := http.Request {
		allocator         = allocator,
		body              = transmute([]u8)string("no line feed"),
		body_content_type = "text/plain",
	}
	rendered := strings.builder_make(allocator)
	defer strings.builder_destroy(&rendered)
	if err := output.write_request(
		strings.to_writer(&rendered),
		&request,
		output.Parts{body = true},
		output.Request_Head_Defaults{},
		&config,
	); err != .None {
		testing.expectf(t, false, "write_request failed: %v", err)
	}
	testing.expect_value(t, strings.to_string(rendered), "no line feed")
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Stream_Run is what one CLI run left behind: the two streams it wrote to, and
// its exit code. Both strings are owned by the caller's allocator.
@(private)
Stream_Run :: struct {
	stdout:    string,
	stderr:    string,
	exit_code: int,
}

@(private)
stream_run_destroy :: proc(run: ^Stream_Run, allocator: mem.Allocator) {
	delete(run.stdout, allocator)
	delete(run.stderr, allocator)
	run^ = {}
}

// stream_run_reply runs one CLI invocation against a one-reply loopback server
// and returns what it wrote. `backing` is where the server's own allocations
// come from (they are not the run's); `allocator` owns the result.
@(private)
stream_run_reply :: proc(
	t: ^testing.T,
	backing: mem.Allocator,
	allocator: mem.Allocator,
	reply: string,
	argv: []string,
) -> Stream_Run {
	server, started := engine_server_start(backing)
	testing.expect(t, started, "the engine server must start")
	engine_queue_reply(server, reply)
	url := engine_url(server, "/stream", allocator)

	out: strings.Builder
	strings.builder_init(&out, allocator)
	err_out: strings.Builder
	strings.builder_init(&err_out, allocator)

	full := make([]string, len(argv) + 1, context.temp_allocator)
	copy(full, argv)
	full[len(argv)] = url

	options, err := parse_cli_plain(full, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	ctx := session.context_create(options, strings.to_writer(&out), strings.to_writer(&err_out))
	exit_code := session.run(&ctx)

	run := Stream_Run {
		stdout    = stream_must_clone(t, strings.to_string(out), allocator),
		stderr    = stream_must_clone(t, strings.to_string(err_out), allocator),
		exit_code = exit_code,
	}

	session.context_destroy(&ctx)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	delete(url, allocator)
	engine_server_destroy(server)
	return run
}

// stream_render_reply renders one reply's body with the stream flag and the
// prettify groups a case asks for, and returns what the writer got.
// `stdout_is_tty` is false: a terminal puts the message in the encode/colour
// stream on its own, which would hide which stream the flag picked.
@(private)
stream_render_reply :: proc(
	t: ^testing.T,
	allocator: mem.Allocator,
	content_type: string,
	body: string,
	stream: bool,
	pretty_format: bool,
	pretty_colors: bool,
) -> string {
	style, found := output.style_lookup(output.DEFAULT_STYLE_NAME)
	testing.expect(t, found, "the default style must resolve")
	config := output.Write_Config {
		allocator     = allocator,
		style         = style,
		variant       = .Pygments_Http,
		pretty_format = pretty_format,
		pretty_colors = pretty_colors,
		stream        = stream,
	}

	response := http.Response {
		allocator    = allocator,
		status       = 200,
		reason       = stream_must_clone(t, "OK", allocator),
		http_version = stream_must_clone(t, "HTTP/1.1", allocator),
	}
	response.headers = make([]http.Header, 1, allocator)
	response.headers[0] = {
		name  = stream_must_clone(t, "Content-Type", allocator),
		value = stream_must_clone(t, content_type, allocator),
	}
	response.body = make([]u8, len(body), allocator)
	copy(response.body, body)

	rendered := strings.builder_make(allocator)
	if err := output.write_response(
		strings.to_writer(&rendered),
		&response,
		output.Parts{body = true},
		0,
		&config,
	); err != .None {
		testing.expectf(t, false, "write_response failed: %v", err)
	}
	text, clone_err := strings.clone(strings.to_string(rendered), allocator)
	testing.expect_value(t, clone_err, mem.Allocator_Error.None)
	strings.builder_destroy(&rendered)
	http.response_destroy(&response)
	return text
}

// stream_must_clone is the two-value clone with the error checked.
@(private)
stream_must_clone :: proc(t: ^testing.T, s: string, allocator: mem.Allocator) -> string {
	clone, err := strings.clone(s, allocator)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	return clone
}
