// Package session is the one place that knows the order of an invocation:
// handle the meta flags, turn the options into a request, hand the request to
// the transport, render what comes back, compute the exit code.
//
// It owns the parsed Options for the duration of the run and nothing else:
// everything it allocates comes from Context.allocator, which is the allocator
// main read once from the runtime (docs/ARCHITECTURE.md, "Memory ownership").
package session

import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "src:cli"
import "src:format"
import "src:http"
import "src:output"

// Context is one invocation: the parsed options, the output streams and the
// allocator every layer below shares.
//
// `stdout` is the real standard output; `out` is where the *messages* go. The
// two differ when the reference redirects them (cli/argparser.py:230-267):
// with --download every message moves to stderr and the body goes to the
// download target; with -o FILE and no --download the messages go to the file.
Context :: struct {
	allocator: mem.Allocator,
	options:   cli.Options, // owned: context_destroy releases it
	stdout:    io.Writer,
	stderr:    io.Writer,
	out:       io.Writer, // where messages are written
	log:       output.Console, // the console errors and warnings are printed through
	// warnings_silenced is `-qq` on a tty: httpie drops warnings of that level
	// on the floor (context.py:39-43, 169-172), errors never.
	warnings_silenced: bool,
	output:    ^os.File, // the open -o FILE, nil when stdout/stderr are used
	devnull:   ^os.File, // the open /dev/null behind --quiet, nil otherwise
	download_resumed_from: i64, // bytes already on disk when resuming a download
}

// context_create takes ownership of `options`; the caller must not use them (or
// destroy them) afterwards.
context_create :: proc(options: cli.Options, stdout: io.Writer, stderr: io.Writer) -> Context {
	ctx := Context {
		allocator = options.allocator,
		options   = options,
		stdout    = stdout,
		stderr    = stderr,
		out       = stdout,
	}

	if options.download {
		// "With `--download`, we write everything that would normally go to
		// stdout to stderr instead." (cli/argparser.py:242-245)
		ctx.out = stderr
	} else if options.output_file != "" {
		if handle, open_err := os.open(options.output_file, os.O_WRONLY | os.O_CREATE | os.O_TRUNC); open_err == nil {
			ctx.output = handle
			ctx.out = os.to_writer(handle)
		}
	}

	// The log stream is the *original* stderr: --download and -o move the
	// messages, never the errors (context.py:100-103,169-172). It is a rich
	// console there too — `log_error` builds one over this stream
	// (context.py:170-182) — so it carries the run's console width, which is
	// what a zero-width `$COLUMNS` needs to drop every line (`$COLUMNS=0`:
	// docs/PARITY.md §4.2, t_e0f7b7b3), and the value rich's `int()` refuses,
	// which is the console the reference dies building — at the first message
	// that goes through it and not before, because `log_error` builds its
	// console lazily (`console_crash`; §3.1, t_14a26d57).
	ctx.log = output.Console {
		writer = stderr,
		width  = cli.console_width(options.env),
		crash  = cli.console_crash(options.env),
	}

	if options.quiet > 0 {
		// "Do not print to stdout or stderr, except for errors and warnings
		// when provided once." (cli/argparser.py:262-267). stdout is still
		// redirected to -o, which is why the output file wins here.
		if handle, open_err := os.open("/dev/null", os.O_WRONLY); open_err == nil {
			ctx.devnull = handle
			if !(options.output_file != "" && !options.download) {
				ctx.out = os.to_writer(handle)
			}
			ctx.warnings_silenced = options.env.stdout_is_tty && options.quiet >= 2
		}
	}
	return ctx
}

// context_destroy releases what the Context owns and zeroes it, so destroying
// twice is safe.
context_destroy :: proc(ctx: ^Context) {
	if ctx == nil {
		return
	}
	if ctx.output != nil {
		os.close(ctx.output)
		ctx.output = nil
	}
	if ctx.devnull != nil {
		os.close(ctx.devnull)
		ctx.devnull = nil
	}
	cli.options_destroy(&ctx.options)
	ctx^ = {}
}

// run executes one invocation and returns the process exit code.
run :: proc(ctx: ^Context) -> int {
	options := &ctx.options
	allocator := ctx.allocator

	if options.show_version {
		output.print_version(ctx.out)
		return int(cli.Exit_Code.Ok)
	}
	if options.show_help || options.show_manual {
		// `--manual` falls back to the help text whenever the man pages are not
		// installed (cli/argparser.py:561-575); the port has no man pages, so
		// that fallback is the only path.
		output.print_help(ctx.out, options.program_name)
		return int(cli.Exit_Code.Ok)
	}

	// httpie loads the session before it builds the request and writes it back
	// after the exchange (client.py:48-58, 136-140). The flags themselves are
	// the CLI's: this is only the persistence they ask for.
	session: Session
	has_session := options.session != "" || options.session_read_only != ""
	if has_session {
		ok: bool
		session, ok = session_open(options, ctx.log, allocator)
		if !ok {
			return int(cli.Exit_Code.Error)
		}
	}
	defer if has_session {
		session_destroy(&session)
	}

	// The request the invocation describes, before anything is sent.
	request: http.Request
	if !build_request(ctx, &request, has_session ? &session : nil) {
		// The failing step may have filled the request part-way — the headers,
		// the query items, the body — and the run ends there, so this is the
		// site that has to release what it built. A `request_create` that
		// failed leaves the value untouched (and zero): destroying a zero
		// Request is a no-op (request_destroy).
		http.request_destroy(&request)
		return int(cli.Exit_Code.Error)
	}
	// The Request owns all of its buffers; this is the only free site.
	defer http.request_destroy(&request)

	config, config_ok := write_config(ctx)
	if !config_ok {
		return int(cli.Exit_Code.Error)
	}

	parts_request, parts_response := print_parts(options)

	// httpie prints the request before sending it (core.py:186-232).
	defaults := request_head_defaults(ctx, &request)
	defer delete(defaults.host, allocator)
	if parts_request.head || parts_request.body {
		output.write_request(ctx.out, &request, parts_request, defaults, &config)
		// The reference encodes the rendered head as one string (models.py:160,
		// output/streams.py:53), so a header name that is not valid UTF-8 raises
		// while the message is written: the request is built, the transport is
		// never asked to send, and nothing of the head reaches stdout. A charset
		// the registry has no text codec for is looked up first, in the same
		// call (`encode(output_encoding)`), so it is what the run reports when
		// both are wrong.
		if charset_failure(ctx, &config) {
			return int(cli.Exit_Code.Error)
		}
		if encode_failure(ctx, &request) {
			return int(cli.Exit_Code.Error)
		}
	}

	if options.offline {
		// --offline renders the request that would go on the wire and stops;
		// the session file is still written, because httpie's generator reaches
		// its tail without a reply having been produced (client.py:136-140).
		if has_session && !session_finish(&session, nil) {
			return int(cli.Exit_Code.Error)
		}
		return int(cli.Exit_Code.Ok)
	}

	// --download changes what the request asks for before it goes out: no
	// compression, and a Range header when resuming (downloads.py:38-84).
	download_target: ^os.File
	if options.download {
		file, prepare_err := prepare_download(ctx, &request)
		if prepare_err != .None {
			return transport_failure(ctx, &request, prepare_err)
		}
		download_target = file
	}
	defer if download_target != nil {
		os.close(download_target)
	}

	started := time.now()
	response: http.Response
	send_err := http.send(&request, &response)
	elapsed_s := time.duration_seconds(time.since(started))
	if send_err != .None {
		// A chain that died mid-follow has already printed the request of every
		// hop it made: httpie prints a hop's request before it sends it
		// (client.py:105, `yield prepared_request`), so those messages are on
		// stdout even though the exchange never finished. The transport
		// publishes them on the request for the failure path (a failed `send`
		// leaves the reply zeroed); without them only the first hop's request
		// would be shown (docs/PARITY.md §3.6).
		if len(request.follow_history) > 0 {
			prev_with_body := parts_request.body
			if !write_hop_messages(
				ctx,
				&request,
				has_session ? &session : nil,
				request.follow_history,
				parts_request,
				parts_response,
				defaults,
				elapsed_s,
				&config,
				&prev_with_body,
			) {
				return int(cli.Exit_Code.Error)
			}
		}
		return transport_failure(ctx, &request, send_err)
	}
	// A zero Response is valid input, so this defer is safe on every path.
	defer http.response_destroy(&response)

	// The reply's own head still goes out through the normal writer, before the
	// progress line: to stderr when the body is heading for a file, so the two
	// do not clobber each other. `exit_code` is decided first because httpie
	// logs the warning for a failed reply before writing the message, and
	// because it decides whether the transfer even starts (core.py:214-232,
	// 246-250).
	//
	// That warning is a console print, so when the run's `$COLUMNS` is a value
	// rich's `int()` refuses the reference dies inside it and never writes the
	// reply: nothing else of the run happens, and the port ends here with the
	// same status (`console_fatal`; docs/PARITY.md §3.1, §8.20).
	exit_code, columns_fatal := status_exit_code(ctx, &response)
	if columns_fatal {
		return int(cli.Exit_Code.Error)
	}
	if options.download {
		head_parts := parts_response
		head_parts.body = false // the body is the file's
		if head_parts.head || head_parts.meta {
			writer := ctx.out
			if download_target != nil {
				writer = ctx.stderr
			}
			output.write_response(writer, &response, head_parts, elapsed_s, &config)
			if charset_failure(ctx, &config) {
				return int(cli.Exit_Code.Error)
			}
		}
		if exit_code == int(cli.Exit_Code.Ok) {
			if code := download_response(ctx, &response, &config, download_target, elapsed_s); code != int(cli.Exit_Code.Ok) {
				if has_session && !session_finish(&session, &response) {
					return int(cli.Exit_Code.Error)
				}
				return code
			}
		}
	} else {
		// The hops that led here: each one's response when --all asked for it,
		// then the next hop's request. httpie writes every message of the
		// exchange as its client produces it (client.py:104-127), which is why
		// a followed redirect shows both requests and, with --all, the
		// intermediate replies too.
		prev_with_body := parts_request.body
		if !write_hop_messages(
			ctx,
			&request,
			has_session ? &session : nil,
			response.history,
			parts_request,
			parts_response,
			defaults,
			elapsed_s,
			&config,
			&prev_with_body,
		) {
			return int(cli.Exit_Code.Error)
		}
		// Between two printed messages httpie separates with a blank line when
		// the earlier one printed a body (core.py:216-219).
		separate_before(ctx, parts_any(parts_response), prev_with_body)
		output.write_response(ctx.out, &response, parts_response, elapsed_s, &config)
		if charset_failure(ctx, &config) {
			return int(cli.Exit_Code.Error)
		}
	}

	// The tail of httpie's client (client.py:136-140): the cookies the exchange
	// collected are in the jar by now, and the file is written back unless
	// --session-read-only asked for a read that must not change it.
	if has_session && !session_finish(&session, &response) {
		return int(cli.Exit_Code.Error)
	}

	return exit_code
}

// ---------------------------------------------------------------------------
// The message sequence of a followed exchange
// ---------------------------------------------------------------------------

// write_hop_messages writes the tail of the exchange: for every hop after the
// first, the reply that led to it (only with --all) followed by its request.
// The first hop's request was already written before the send; the final reply
// is the caller's, written after this. `prev_with_body` carries httpie's
// separator state in and out (core.py:214-232). `session` is the loaded session
// (nil when the run has none), which every followed hop's `Cookie` header is
// re-derived from: the request's own copy was built for the first URL only,
// exactly as the transport re-derives the one it sends (http.Cookie_Hook).
// False when a message stopped the run — a charset the registry has no text
// codec for — which the caller reports after the fact, since the reference's
// raise unwinds out of the message loop.
@(private)
write_hop_messages :: proc(
	ctx: ^Context,
	first_request: ^http.Request,
	session: ^Session,
	history: []http.Exchange,
	parts_request: output.Parts,
	parts_response: output.Parts,
	base_defaults: output.Request_Head_Defaults,
	elapsed_s: f64,
	config: ^output.Write_Config,
	prev_with_body: ^bool,
) -> bool {
	options := &ctx.options
	// requests' purge is *sticky*, and this flag is that fact: `resolve_redirects`
	// copies the prepared request once per hop (`prepared_request = req.copy()`,
	// sessions.py:206) and pops `Content-Length`, `Content-Type` and
	// `Transfer-Encoding`, clearing the body, on the copy whose reply was not a
	// 307/308 (:247-258) — and the copy is what the *next* hop renders. A purge
	// is therefore never undone: a 307/308 that follows it keeps only what the
	// purge left, which is nothing. The transport carries the same fact for the
	// wire (`Hop.purge_body_headers`, src/http/curl_transport.odin), which is
	// why only the rendered head can disagree (t_073ea885).
	purged := false
	for i in 1 ..< len(history) {
		// The reply that led to hop `i`: the render's input for --all, and what
		// decides the purge below either way.
		led_to_it := history[i - 1]
		if !http.redirect_keeps_body(led_to_it.status) {
			purged = true
		}
		if options.all {
			any := parts_any(parts_response)
			separate_before(ctx, any, prev_with_body^)
			if any {
				// A historical reply borrows the exchange's strings: it is
				// rendered, never destroyed. Its body is not kept by the
				// transport (only the final reply's is).
				reply := http.Response {
					status       = led_to_it.status,
					reason       = led_to_it.reason,
					http_version = led_to_it.http_version,
					headers      = led_to_it.headers,
				}
				output.write_response(ctx.out, &reply, parts_response, elapsed_s, config)
				if charset_failure(ctx, config) {
					return false
				}
			}
			prev_with_body^ = parts_response.body
		}
		write_hop_request(ctx, first_request, session, history[i], purged, parts_request, base_defaults, config, prev_with_body)
		if charset_failure(ctx, config) {
			return false
		}
	}
	return true
}

// write_hop_request writes one followed hop's request message. The verb and the
// target come from the hop the transport sent; the headers are the request's
// own, because that is what requests re-sends — as the purge left them:
// `resolve_redirects` pops `Content-Length`, `Content-Type` and
// `Transfer-Encoding` and clears the body on every followed redirect that is
// not a 307/308 (sessions.py:249-258), and it does so on the request the next
// hop copies forward, so the pop is *sticky* — `purged` is true once any reply
// in the chain was not a 307/308, and a 307/308 that follows such a hop renders
// without the three names too (there is nothing left for it to keep;
// `write_hop_messages` accumulates the flag). A hop whose request never had a
// body has nothing to lose either way: the purge is about the *redirect*, not
// about a request that was body-less from the start.
//
// One body the hop keeps does *not* render: a `--chunked` upload's. That body
// is a *stream* in the reference
// (`ChunkedUploadStream(stream=iter([body]))`, uploads.py:221-224) and httpie
// prints a request body only through the callback that stream calls while the
// *send* reads it (core.py:185-200; the message itself is written head-only
// when its body is not `str`/`bytes`, :225-226), so a hop whose prepared
// request still points at that stream (sessions.py:206's `req.copy()`) prints
// the head requests kept and no body: the first send spent the iterator. The
// transport sends nothing for that hop either (Hop.body_spent,
// src/http/curl_transport.odin), which is what
// `redirect-keep-all-get-chunked-{307,308}-live` pins (t_43183eec). Only the
// *bytes* are gone: `Transfer-Encoding: chunked` and `Content-Type` are in the
// head the hop prints, exactly as the reference's is — unless a purge already
// took them, which is the sticky case above (`redirect-purge-sticky-*`).
@(private)
write_hop_request :: proc(
	ctx: ^Context,
	first_request: ^http.Request,
	session: ^Session,
	hop: http.Exchange,
	purged: bool,
	parts: output.Parts,
	base_defaults: output.Request_Head_Defaults,
	config: ^output.Write_Config,
	prev_with_body: ^bool,
) {
	allocator := ctx.allocator
	// Two splits, one per kind of hop. A hop requests could send is the one the
	// port speaks, and `url_split` (httpie's argv rule) is what reads its host,
	// port and target. A hop requests has **no adapter** for is the other kind:
	// nothing is sent with it, and the only thing that spelled it is
	// `urlsplit` of the URL requests held — no `prepare_url` ever ran over it —
	// so `http.url_refused_target` is its rule (models.py:137-151).
	refused := !http.url_has_http_adapter(hop.url)
	target: http.Target
	refused_target: http.Refused_Target
	// That split deletes the three bytes `urlsplit` deletes before it parses
	// anything — tab, CR and LF (`http.url_location_parse`) — so it may need a
	// copy of the URL, and this is the buffer for it: the fields read out of
	// `refused_target` borrow it, so it lives until the hop is rendered, and it
	// stays empty (and unallocated) for a URL without one of them.
	refused_scratch := http.buffer_make(allocator)
	defer http.buffer_destroy(&refused_scratch)
	if refused {
		refused_ok: bool
		refused_target, refused_ok = http.url_refused_target(hop.url, &refused_scratch)
		if !refused_ok {
			return
		}
	} else {
		split_err: http.Error
		target, split_err = http.url_split(hop.url, nil)
		if split_err != .None {
			return
		}
	}

	keep_body := !purged
	// The hop's head is the request's own headers minus the two things the
	// reference takes off a followed redirect: the purged body headers, and
	// `Cookie` — requests pops that one on *every* followed hop and then
	// re-derives it from the jar for the new URL (sessions.py:235-243). The
	// re-derived line is appended below, where the hop's target is known.
	// The filtered list has to outlive the block that builds it: the renderer
	// reads it below.
	filtered := make([dynamic]http.Header, 0, len(first_request.headers) + 1, allocator)
	for header in first_request.headers {
		if strings.equal_fold(header.name, "Cookie") {
			continue
		}
		if !keep_body &&
		   (strings.equal_fold(header.name, "Content-Length") ||
			   strings.equal_fold(header.name, "Content-Type") ||
			   strings.equal_fold(header.name, "Transfer-Encoding")) {
			continue
		}
		append(&filtered, header)
	}
	defer delete(filtered)

	// The `Cookie` this hop is sent with, re-derived from the jar for *its* URL
	// — requests' `prepare_cookies`, after `resolve_redirects` popped the first
	// URL's header. A refused target is never sent and gets no line: the branch
	// above returned the target no mounted adapter can carry.
	if !refused && session != nil {
		request_path := target.path
		if request_path == "" {
			request_path = "/"
		}
		value := session_cookie_value(session, target.host, request_path, target.scheme == .HTTPS, allocator)
		defer if value != "" {
			delete(value, allocator)
		}
		if value != "" {
			append(&filtered, http.Header{name = "Cookie", value = value})
		}
	}
	// The list the renderer reads: the filtered headers, with the re-derived
	// `Cookie` last — the position requests' own dict assignment gives it.
	headers := filtered[:]

	hop_request := first_request^
	hop_request.method = hop.method
	// The verb as sent: the hop's own spelling, which for a rewritten hop is
	// the enum's (the transport followed requests' rebuild_method).
	hop_request.method_raw = ""
	hop_request.scheme = target.scheme
	// The refused hop's Host is the netloc as `urlsplit` read it, userinfo and
	// all removed by the rule, and it keeps a port requests never parsed: it is
	// the string httpie prints (`url.netloc.split('@')[-1]`, models.py:150-151),
	// read here with no host rule over it (`url_refused_target`), which is why
	// it comes through `host` with no port beside it.
	hop_request.host = refused ? refused_target.host : target.host
	hop_request.port = refused ? 0 : target.port
	hop_request.path = refused ? refused_target.path : target.path
	hop_request.query_raw = refused ? refused_target.query : target.query
	hop_request.query = nil
	// The hop's target is the URL requests resolved, as it stands: the path and
	// the query the history prints are the prepared spelling, not the
	// re-encoded one the wire carries (docs/PARITY.md §3.6).
	hop_request.target_verbatim = true
	hop_request.headers = headers
	// A body the hop keeps but does not carry: see the note above. The headers
	// above are untouched, so the hop still prints `Transfer-Encoding: chunked`
	// and `Content-Type`; only the bytes are gone.
	if !keep_body || first_request.chunked {
		hop_request.body = nil
		hop_request.body_source = .None
	}

	defaults := hop_head_defaults(ctx, &hop_request, base_defaults)
	if refused {
		// httpie's model appends `Host` to a request that carries none whatever
		// the netloc is, so a refused target with no authority at all prints the
		// line empty (`file:///etc/hostname` → `Host: `, models.py:150-151); a
		// prepared HTTP URL always has a host, which is why only this hop asks
		// for the line.
		defaults.host_always = true
	}
	defer delete(defaults.host, allocator)

	separate_before(ctx, parts_any(parts), prev_with_body^)
	output.write_request(ctx.out, &hop_request, parts, defaults, config)
	prev_with_body^ = parts.body
}

// hop_head_defaults is request_head_defaults for a followed hop: the automatic
// headers are the ones the session already resolved, but Host follows the hop —
// the hop's own authority, which is what requests' second `prepare_url` spelled
// into the hop URL (see `http.host_header_value`; an explicit default port is
// kept there too, in the header as in the URL).
@(private)
hop_head_defaults :: proc(
	ctx: ^Context,
	hop: ^http.Request,
	base: output.Request_Head_Defaults,
) -> output.Request_Head_Defaults {
	defaults := base
	host, host_err := http.request_host_header(hop, ctx.allocator)
	defaults.host = host_err == .None ? host : ""
	return defaults
}

// separate_before writes httpie's blank line between two messages: the earlier
// one printed a body and this one prints anything (core.py:216-219). On a
// terminal httpie only separates a streamed upload, which the port does not
// print per message.
@(private)
separate_before :: proc(ctx: ^Context, any: bool, prev_with_body: bool) {
	if prev_with_body && any && !ctx.options.env.stdout_is_tty {
		io.write_string(ctx.out, output.MESSAGE_SEPARATOR)
	}
}

// parts_any reports whether a print set asks for anything at all.
@(private)
parts_any :: proc(parts: output.Parts) -> bool {
	return parts.head || parts.body || parts.meta
}

// ---------------------------------------------------------------------------
// Options to a request
// ---------------------------------------------------------------------------

// build_request fills `request` from the parsed options. `session` is the
// loaded session when the run asked for one (nil otherwise): its headers are
// the request's base headers and the request headers are what the session
// records back (client.py:48-81). On failure it prints httpie's runtime error
// and returns false.
build_request :: proc(ctx: ^Context, request: ^http.Request, session: ^Session) -> bool {
	options := &ctx.options
	allocator := ctx.allocator

	host_error: http.Host_Error
	req, create_err := http.request_create(
		allocator,
		options.method,
		options.url,
		options.default_scheme,
		options.path_as_is,
		&host_error,
	)
	if create_err != .None {
		// The host rule raises urllib3's own `LocationParseError` (wrapped by
		// requests as an `InvalidURL`) before anything else about the request
		// is prepared, and its message is the reference's — not the port's
		// short `http.error_message` wording (docs/PARITY.md §3.6).
		if host_error.kind != .None {
			message := http.host_error_message(&host_error, allocator)
			defer delete(message, allocator)
			// The quoted label of an `.Invalid_Name` is the rule's own copy
			// (`host_error_destroy`), so it is released here, after the render.
			defer http.host_error_destroy(&host_error, allocator)
			output.write_log_error(ctx.log, options.program_name, message)
			return false
		}
		output.write_log_error(ctx.log, options.program_name, http.error_message(create_err))
		return false
	}
	request^ = req

	// The session's own headers come first (client.py:48-63): they override
	// httpie's defaults and are overridden by the item headers below. They are
	// the first entries of the request dict there too, and an item that repeats
	// a name replaces its value in that slot.
	if session != nil {
		if !session_merge_headers(session, request) {
			return request_failure(ctx, .Out_Of_Memory)
		}
	}

	// Query items (`name==value`) and headers (`name:value`) come straight from
	// the item grammar. The query items are the exception for a URL requests
	// never prepared: `prepare_url` encodes them into the URL it is about to
	// prepare (`_encode_params`, models.py:550) and returns *before* that for
	// the short-circuited URL, so they are simply not there — the rendered
	// target keeps the URL's own query and nothing else (docs/PARITY.md §3.6).
	if request.url_kind != .Unprepared {
		for param in options.item_set.params {
			if err := http.request_add_query(request, param.name, param.value); err != .None {
				return request_failure(ctx, err)
			}
		}
	}
	// The item headers are httpie's `args.headers`, and every rule of that dict
	// lives in the fold the grammar builds for them (cli/items.odin's
	// header_fold): a repeated name accumulates its values, an item that unsets
	// a name replaces every value it has, and a name set again after an unset
	// moves to the end of the dict.
	//
	// An *unset* (`Name:` with an empty value, `Header_Item.unset`) is not an
	// empty-valued header: the reference turns it into a `None`
	// (requestitems.py:process_header_arg answers `arg.value or None`), which
	// drops every value of the name, and `finalize_headers` then drops the pair
	// itself (client.py:190-209) — so the name leaves the request, taking a
	// repeated item, a session header and one of httpie's defaults with it. The
	// one exception is urllib3's three skippable names, whose `None` becomes the
	// SKIP_HEADER sentinel instead: the name stays in the dict so the header
	// urllib3 would add on its own is suppressed, and both the rendered head and
	// the wire leave the line out (src/http/skippable.odin). `Name;` is the
	// empty-valued header and stays one — the two spellings are not the same
	// thing (docs/PARITY.md §3.1).
	fold := cli.header_fold(&options.item_set, allocator)
	defer cli.header_fold_destroy(&fold)
	for entry in fold.entries {
		if entry.unset {
			// `self[key] = None` drops every value of the name and keeps the
			// name's slot: `insert_at` is that slot for the three names whose
			// absence has to be announced to urllib3.
			first, _ := http.request_remove_headers(request, entry.name)
			if http.is_skippable_header(entry.name) {
				insert_at := len(request.headers)
				if first >= 0 {
					insert_at = first
				}
				if strings.equal_fold(entry.name, "User-Agent") {
					// Its slot is the one `make_default_headers` gave it
					// (client.py:263-278), ahead of the session's headers —
					// and the port adds its own defaults last, so the slote
					// the reference assigns into is the front of the list.
					insert_at = 0
				}
				// The assignment's spelling is the item's; the value is the
				// sentinel urllib3 drops.
				if err := http.request_insert_header(request, insert_at, entry.name, http.SKIP_HEADER); err != .None {
					return request_failure(ctx, err)
				}
			}
			if err := http.request_unset_header(request, entry.name); err != .None {
				return request_failure(ctx, err)
			}
			continue
		}
		// A name the session already carries keeps its slot — requests merges
		// the item dict in place over the session's headers (sessions.py:461-476)
		// — so the first value replaces the stored one and the rest are
		// appended, in command-line order.
		start := 0
		if replace_session_header(request, entry.name, entry.values[0].value) {
			start = 1
		}
		for value in entry.values[start:] {
			if err := http.request_add_header(request, value.name, value.value); err != .None {
				return request_failure(ctx, err)
			}
		}
	}
	// (File fields are added with the data items below: a multipart body is
	// serialised in command-line order and the two are interleaved there.)

	// The merged values lose their surrounding whitespace here, exactly once:
	// the reference strips every value of the request dict it hands to requests
	// (`finalize_headers`, client.py:192-209), right after its own defaults, the
	// session's headers and the items have been merged. Running it at the same
	// point is what makes the head, the wire and the session file agree — the
	// session records the headers further down (client.py:75 reads the finalized
	// ones), and both the renderer and the transport read this same list after
	// output.order_request_headers has rewritten it.
	if strip_err := http.request_strip_header_values(request); strip_err != .None {
		return request_error(ctx, request, strip_err)
	}

	// requests prepares the URL for every invocation, before the body and the
	// auth, and that is where the query items are encoded (models.py:550,
	// `_encode_params`): a byte the argv decode turned into a lone surrogate
	// raises there, whether or not anything is printed. The check has to be here
	// rather than in request_target, which an invocation printing neither part
	// of the request (`-p b`) never calls.
	if query_err := http.request_check_query_items(request); query_err != .None {
		return request_error(ctx, request, query_err)
	}

	// ...and the string requests' `requote_uri` is handed right after them, for
	// the one URL kind whose preparation re-encodes the *whole* URL with
	// `errors='strict'`: a character utf-8 has no encoding for (the lone
	// surrogate of an argv byte that is not valid UTF-8) raises
	// `UnicodeEncodeError` inside CPython's `quote`, with the character's
	// position counted in that string — the request is never rendered and no
	// adapter is looked up (docs/PARITY.md §3.6, §8 item 21).
	if url_err := http.request_check_other_scheme_url(request); url_err != .None {
		return request_error(ctx, request, url_err)
	}

	// requests validates every header it prepares (models.py:440,
	// `prepare_headers` → `check_header_validity`) *after* the URL and *before*
	// the cookies, the body and the auth, and the refusal ends the run — no
	// head is rendered, nothing is sent. The check runs there, on the finalized
	// values (the strip above has already rewritten them), so the rule the
	// reference applies is the one the port applies, and it applies it to the
	// same pair the reference's merged dict holds under each name
	// (src/http/header_validity.odin).
	if invalid_text, invalid_part, invalid := http.request_invalid_header(request); invalid {
		message := http.invalid_header_message(invalid_text, invalid_part, allocator)
		defer delete(message, allocator)
		output.write_log_error(ctx.log, options.program_name, message)
		return false
	}

	// The Content-Type item is also the raw material of a multipart body's
	// Content-Type: client.py:353-358 builds that value from `args.headers` —
	// the CLI's own items, *not* the session's base headers — so the encoder
	// gets this one and not the merged header. The first item wins, because
	// `args.headers.get` reads the first value of a repeated name.
	for header in options.item_set.headers {
		if strings.equal_fold(header.name, "Content-Type") {
			if err := http.request_set_content_type_item(request, header.value); err != .None {
				return request_failure(ctx, err)
			}
			break
		}
	}

	// The body. The item grammar already decided which of the mutually
	// exclusive sources is in play (docs/PARITY.md section 1.2).
	// The request type picks how the engine encodes the items.
	//
	// A piped stdin is the one source the CLI cannot resolve: it is not an
	// item, and httpie reads it only here, after the item grammar has run and
	// only when nothing else supplied the body (argparser.py:735-741).
	stdin_body := !options.stdin_is_tty && !options.ignore_stdin &&
	              !options.item_set.has_data && !options.item_set.body_file_given &&
	              options.body_kind != .Raw && options.body_kind != .Multipart
	request.body_kind = body_kind_of(options.body_kind)
	switch {
	case options.item_set.body_file_given:
		// A bare `@file`: the whole body, typed by the file's extension when the
		// extension has one. There is no fallback type: when the guess says
		// nothing the header item is simply not added
		// (`if content_type: self.args.headers['Content-Type'] = content_type`,
		// argparser.py:485-488), so the request type's own default — the same
		// one `--raw` gets — is what the request carries (docs/PARITY.md §3.1).
		guessed := cli.item_set_body_file_content_type(&options.item_set, allocator)
		defer if guessed != "" {
			delete(guessed, allocator)
		}
		content_type := guessed
		if content_type == "" {
			content_type = raw_content_type(options)
		}
		if err := http.request_set_raw_body(request, options.item_set.body_file_contents, content_type); err != .None {
			return request_failure(ctx, err)
		}
	case stdin_body:
		// The bytes as they arrive, with the content type the request type
		// implies — the same treatment `--raw` gets.
		input := read_stdin(allocator)
		defer delete(input, allocator)
		if err := http.request_set_raw_body(request, input, raw_content_type(options)); err != .None {
			return request_failure(ctx, err)
		}
	case options.body_kind == .Raw:
		// --raw: the bytes as given, with the content type the request type
		// implies.
		raw := options.raw_body
		content_type := raw_content_type(options)
		if err := http.request_set_raw_body(request, transmute([]u8)raw, content_type); err != .None {
			return request_failure(ctx, err)
		}
	case options.item_set.has_data && options.body_kind == .JSON:
		// The CLI already applied the nested-JSON (bracket) grammar; here the
		// tree is only serialised, exactly as json.dumps prints it — with the
		// module *defaults*, which is what json_dict_to_request_body calls
		// (client.py:311-319): `ensure_ascii=True`, so every character outside
		// `' '..'~'` is escaped and the Content-Length follows the escapes
		// (docs/PARITY.md §3.4). The response formatter's dump is the one that
		// passes ensure_ascii=False.
		root, message := cli.item_set_json_data(&options.item_set, allocator)
		if message != "" {
			// httpie's core.py:81-85: a nested-JSON syntax/type error is written
			// to stderr as the bare message plus one newline, then exit 1.
			output.write_raw_bytes(ctx.stderr, transmute([]u8)message)
			output.write_raw_bytes(ctx.stderr, []u8{'\n'})
			delete(message, allocator)
			return false
		}
		defer format.value_destroy(&root, allocator)
		text := format.dump_to_string(&root, format.body_dump_options(), allocator)
		defer delete(text, allocator)
		if err := http.request_set_raw_body(request, transmute([]u8)text, http.JSON_CONTENT_TYPE); err != .None {
			return request_failure(ctx, err)
		}
	case options.item_set.has_data:
		// Data items and file fields, interleaved in command-line order: a
		// multipart body serialises them in that order (httpie builds
		// `args.multipart_data` as a dict, and Python's dicts keep insertion
		// order).
		//
		// A multipart body is built from `args.multipart_data` — not from
		// `args.data` — and only the separators of SEPARATORS_GROUP_MULTIPART
		// (`=`, `=@`, `@`) are ever put into that dict (requestitems.py:112-113).
		// A `:=`/`:=@` item is still accepted by the CLI and still lands in
		// `args.data`, but it contributes no part at all: `--multipart a:=1`
		// sends the closing line alone (docs/PARITY.md §1.2). The JSON body and
		// the urlencoded form body are built from `args.data`, so the same item
		// *does* reach those two roads (a `--form` with no file field is the
		// urlencoded one); this branch is the only one that drops it.
		multipart := options.body_kind == .Multipart
		files := options.item_set.files
		items := make([]http.Data_Item, len(options.item_set.data) + len(files), allocator)
		out := 0
		defer {
			for item in items[:out] {
				delete(item.name, allocator)
				delete(item.value, allocator)
				delete(item.lone, allocator)
			}
			delete(items, allocator)
		}
		file_index := 0
		for &item, i in options.item_set.data {
			for file_index < len(files) && files[file_index].after_data == i {
				items[out] = file_data_item(files[file_index], allocator)
				out += 1
				file_index += 1
			}
			if multipart && !(item.sep in cli.MULTIPART_SEPARATORS) {
				// Not part of multipart_data: the item is skipped *after* the
				// file fields that sat before it, so the parts that remain
				// keep their relative order (the file's `after_data` counts
				// command-line data items, this one included).
				continue
			}
			items[out] = http.Data_Item {
				kind  = data_item_kind(item.sep),
				name  = strings.clone(item.key, allocator) or_else "",
				value = data_item_value(&item, allocator),
				lone  = data_item_lone(&item, allocator),
			}
			out += 1
		}
		for file_index < len(files) {
			items[out] = file_data_item(files[file_index], allocator)
			out += 1
			file_index += 1
		}
		if err := http.request_add_items(request, items[:out]); err != .None {
			return request_failure(ctx, err)
		}
	case options.body_kind == .Multipart:
		// `--multipart` without a single data item still sends a body: httpie
		// hands MultipartEncoder an empty field dict and it emits the closing
		// `--boundary--\r\n` line alone (38 bytes for a 32-char boundary),
		// which is what fixes the Content-Length and the boundary. A file
		// field with no data items is the other shape this case covers.
		files := options.item_set.files
		items := make([]http.Data_Item, len(files), allocator)
		defer {
			for item in items {
				delete(item.name, allocator)
				delete(item.value, allocator)
			}
			delete(items, allocator)
		}
		for file, i in files {
			items[i] = file_data_item(file, allocator)
		}
		if err := http.request_add_items(request, items); err != .None {
			return request_failure(ctx, err)
		}
	}

	if options.boundary != "" {
		delete(request.boundary, allocator)
		request.boundary = strings.clone(options.boundary, allocator) or_else ""
	}

	// Transport policy: http deliberately does not import cli, so the session is
	// where the two meet (docs/ARCHITECTURE.md).
	request.timeout_s = int(options.timeout_s)
	request.follow_redirects = options.follow || options.download
	request.max_redirects = options.max_redirects
	request.max_headers = options.max_headers
	request.verify = verify_enabled(options.verify)
	request.chunked = options.chunked
	request.offline = options.offline
	request.compress = int(options.compress)
	if options.method_raw != "" {
		if err := http.request_set_method_raw(request, options.method_raw); err != .None {
			return request_failure(ctx, err)
		}
	}

	// client.py:263-278, `auto_json = args.data and not args.form`: either --json
	// was asked for or the request carries a body that is not form-encoded. That
	// is what switches the Accept/Content-Type pair on; without it httpie leaves
	// requests' session default `Accept: */*` in place.
	request.json_accept = options.json_given ||
	                      (request.body_source != .None && !form_like_body(options.body_kind))
	// `--proxy` entries are `PROTOCOL:PROXY_URL`; requests turns them into a
	// mapping and picks the one for the request's scheme (client.py:302,
	// select_proxy). The Request borrows the entry (and cert/cert_key/
	// cert_key_pass below) — cli.Options keeps ownership of every one of them
	// and options_destroy frees them (docs/ARCHITECTURE.md §4).
	if index := http.proxy_entry_index(request, options.proxy[:]); index >= 0 {
		request.proxy = options.proxy[index]
	}
	request.cert = options.cert
	request.cert_key = options.cert_key
	request.cert_key_pass = options.cert_key_pass
	request.ca_bundle = verify_ca_bundle(options.verify)
	request.ciphers = options.ciphers
	if options.auth != "" {
		if err := http.request_set_auth(request, options.auth, auth_type_of(options.auth_type)); err != .None {
			return request_failure(ctx, err)
		}
	} else {
		// No --auth: requests resolves the credentials from the user's netrc
		// file itself (sessions.py:530-539), and --ignore-netrc is exactly what
		// defeats that (argparser.py:352-355). The session's own credentials
		// are the last resort, and only when neither supplied any
		// (client.py:82-85).
		applied := false
		if !options.ignore_netrc {
			if credentials, found := http.netrc_credentials(request.host, allocator); found {
				defer delete(credentials, allocator)
				if err := http.request_set_auth(request, credentials, .Basic); err != .None {
					return request_failure(ctx, err)
				}
				applied = true
			}
		}
		if !applied && session != nil && session_has_auth(session) {
			credentials, auth_type, has_credentials := session_auth_credentials(session, allocator)
			if has_credentials {
				defer delete(credentials, allocator)
				if err := http.request_set_auth(request, credentials, auth_type); err != .None {
					return request_failure(ctx, err)
				}
			}
		}
	}

	// httpie recomputes the session's stored headers here — from the request
	// headers it has just merged (client.py:75, sessions.py:200-256) — and
	// stores the credentials the command line gave it (client.py:77-81).
	if session != nil {
		if !session_record_headers(session, options, request) {
			return request_failure(ctx, .Out_Of_Memory)
		}
		if !session_record_auth(session, options) {
			return request_failure(ctx, .Out_Of_Memory)
		}
	}

	if err := http.request_prepare(request); err != .None {
		return request_error(ctx, request, err)
	}

	// httpie's session-level defaults belong on the wire as well as in the
	// printed head; libcurl cannot know them (it would send a User-Agent of its
	// own). The header list is then rewritten into the reference's order, which
	// is what both the transport and the renderer read.
	defaults := request_head_defaults(ctx, request)
	defer delete(defaults.host, allocator)
	if err := add_default_header(request, "Accept-Encoding", http.ACCEPT_ENCODING); err != .None {
		return request_failure(ctx, err)
	}
	if err := add_default_header(request, "Connection", "keep-alive"); err != .None {
		return request_failure(ctx, err)
	}
	if err := add_default_header(request, "User-Agent", http.USER_AGENT); err != .None {
		return request_failure(ctx, err)
	}
	// The jar's cookies are requests' own step (client.py:76: the request
	// session's jar *is* the httpie session's), so the header joins after
	// httpie's defaults and before the head is ordered.
	session_apply_cookies(session, request)
	// The same jar re-derives that header for every followed hop: a redirect
	// must not replay the first URL's cookie (http.Cookie_Hook, SF-001).
	session_cookie_hook(session, request)
	// The order comes from the headers' provenance, not their names: the
	// session is the only layer that knows which of them httpie's request dict
	// carried (see request_own_names and output.order_request_headers).
	own, own_ok := request_own_names(ctx, session, request, &fold)
	if !own_ok {
		return request_failure(ctx, .Out_Of_Memory)
	}
	defer delete(own, allocator)
	if !output.order_request_headers(request, own, allocator) {
		output.write_log_error(ctx.log, options.program_name, "not enough memory")
		return false
	}
	return true
}

// replace_session_header gives an item header the value of the session header
// it repeats, keeping the session header's place in the list: requests merges
// the item dict over the session's headers and httpie documents the same
// priority for the stored ones (sessions.py:461-476, :236-248), so the name
// stays where the session put it and takes the item's value.
//
// The request's header list holds the session's headers as its first entries
// and no other occurrence before the item headers, so the first entry of that
// name is the session's. It is searched over the whole list rather than over a
// prefix because an unset can insert a skippable name's sentinel at the front
// (see the merge in build_request).
@(private)
replace_session_header :: proc(
	request: ^http.Request,
	name: string,
	value: string,
) -> bool {
	for index in 0 ..< len(request.headers) {
		if !strings.equal_fold(request.headers[index].name, name) {
			continue
		}
		replacement := strings.clone(value, request.allocator) or_else ""
		delete(request.headers[index].value, request.allocator)
		request.headers[index].value = replacement
		return true
	}
	return false
}

// add_default_header adds one of httpie's session-level headers unless the user
// already asked for that name — or unset it, which removed the name from the
// dict `make_default_headers` builds, so the default does not come back
// (`Name:` of `User-Agent`, `Accept-Encoding` or `Connection`).
@(private)
add_default_header :: proc(req: ^http.Request, name: string, value: string) -> http.Error {
	if _, found := http.request_header_get(req, name); found {
		return .None
	}
	if http.request_header_unset(req, name) {
		return .None
	}
	return http.request_add_header(req, name, value)
}

// read_stdin drains a piped stdin into memory: httpie reads the whole stream
// there too (`env.stdin.read()`, argparser.py:739-741), because the body must
// be complete before the request is prepared.
@(private)
read_stdin :: proc(allocator: mem.Allocator) -> []u8 {
	buffer := make([dynamic]u8, 0, 4096, allocator)
	chunk: [16 * 1024]u8
	for {
		n, err := os.read(os.stdin, chunk[:])
		if n > 0 {
			append(&buffer, ..chunk[:n])
		}
		// EOF arrives as an error (or as a short read); either way the stream
		// is done and whatever was read is the body.
		if err != nil || n <= 0 {
			break
		}
	}
	if len(buffer) == 0 {
		delete(buffer)
		return nil
	}
	return buffer[:]
}

// file_data_item is a file field as the engine wants it, with its strings owned
// so the array it lands in can be freed uniformly.
@(private)
file_data_item :: proc(file: cli.File_Item, allocator: mem.Allocator) -> http.Data_Item {
	return http.Data_Item {
		kind     = .File,
		name     = strings.clone(file.name, allocator) or_else "",
		value    = strings.clone(file.path, allocator) or_else "",
		filename = file.filename,
		mime     = file.mime,
	}
}

// body_kind_of maps the CLI's request type onto the engine's encoder choice.
@(private)
body_kind_of :: proc(kind: cli.Body_Kind) -> http.Body_Kind {
	#partial switch kind {
	case .Form:
		return .Form
	case .Multipart:
		return .Multipart
	case .Raw:
		return .Raw
	}
	return .JSON
}

// form_like_body mirrors httpie's `args.form`, which covers --form and
// --multipart. Those are the request types that keep requests' default
// `Accept: */*` even when they carry data.
@(private)
form_like_body :: proc(kind: cli.Body_Kind) -> bool {
	return kind == .Form || kind == .Multipart
}

// data_item_kind maps the CLI's separator to the engine's encoding.
@(private)
data_item_kind :: proc(sep: cli.Sep) -> http.Data_Item_Kind {
	#partial switch sep {
	case .Data_Raw_JSON, .Data_Raw_JSON_File:
		return .Raw_JSON
	case .File_Upload:
		return .File
	}
	return .String
}

// data_item_value is the item's value as the engine wants it: the plain string
// for a `=` item, and the JSON text for a `:=` item (which the CLI parsed).
//
// A `:=` string that carries an out-of-band lone surrogate is a `str` to the
// reference, so what the engine gets is its own bytes with the placeholder U+FFFD
// standing in for the character — today's bytes, unchanged — and the characters
// themselves travel beside them through data_item_lone.
@(private)
data_item_value :: proc(item: ^cli.Data_Item, allocator: mem.Allocator) -> string {
	#partial switch v in item.value {
	case string:
		return strings.clone(v, allocator) or_else ""
	case format.Surrogate_String:
		return strings.clone(v.text, allocator) or_else ""
	}
	return format.dump_to_string(&item.value, format.default_dump_options(), allocator)
}

// data_item_lone translates the out-of-band surrogates of a `:=` item's value
// into the terms the form encoder checks: format.Surrogate_Mark (which points
// at the placeholder in the string's bytes) and http.Lone_Surrogate are the same
// pair, and this is where they meet, because `http` does not import `format`.
// The result is owned by the caller.
@(private)
data_item_lone :: proc(item: ^cli.Data_Item, allocator: mem.Allocator) -> []http.Lone_Surrogate {
	#partial switch v in item.value {
	case format.Surrogate_String:
		if len(v.marks) == 0 {
			return nil
		}
		lone := make([]http.Lone_Surrogate, len(v.marks), allocator)
		for mark, i in v.marks {
			lone[i] = {offset = mark.offset, code = rune(mark.code)}
		}
		return lone
	}
	return nil
}

@(private)
raw_content_type :: proc(options: ^cli.Options) -> string {
	#partial switch options.body_kind {
	case .Form:
		return http.FORM_CONTENT_TYPE
	case .Multipart:
		return http.MULTIPART_CONTENT_TYPE
	}
	return http.JSON_CONTENT_TYPE
}

@(private)
verify_enabled :: proc(verify: string) -> bool {
	switch {
	case verify == "", strings.equal_fold(verify, "yes"), strings.equal_fold(verify, "true"):
		return true
	case strings.equal_fold(verify, "no"), strings.equal_fold(verify, "false"):
		return false
	}
	return true // a CA bundle path
}

// verify_ca_bundle is the other half of --verify: `no`/`false` disables
// verification, `yes`/`true`/absent keeps the system store, and anything else
// is a CA bundle path (argparser.py's --verify action stores the string as
// given; requests passes a truthy `verify` straight to urllib3, which loads it
// as a CA file). Returns "" when the system store is what should be used.
@(private)
verify_ca_bundle :: proc(verify: string) -> string {
	switch {
	case verify == "":
		return ""
	case strings.equal_fold(verify, "yes"), strings.equal_fold(verify, "true"):
		return ""
	case strings.equal_fold(verify, "no"), strings.equal_fold(verify, "false"):
		return ""
	}
	return verify
}

@(private)
auth_type_of :: proc(auth_type: cli.Auth_Type) -> http.Auth_Type {
	#partial switch auth_type {
	case .Digest:
		return .Digest
	case .Bearer:
		return .Bearer
	}
	return .Basic
}

// ---------------------------------------------------------------------------
// Print sets and the render configuration
// ---------------------------------------------------------------------------

// print_parts splits httpie's --print set into what the request message prints
// and what the response message prints.
@(private)
print_parts :: proc(options: ^cli.Options) -> (request: output.Parts, response: output.Parts) {
	request = {
		head = .Request_Headers in options.print,
		body = .Request_Body in options.print,
	}
	response = {
		head = .Response_Headers in options.print,
		body = .Response_Body in options.print,
		meta = .Response_Meta in options.print,
	}
	return
}

// write_config resolves --pretty, --style and --format-options into the
// renderer's configuration.
@(private)
write_config :: proc(ctx: ^Context) -> (config: output.Write_Config, ok: bool) {
	options := &ctx.options
	allocator := ctx.allocator

	config.allocator = allocator
	config.pretty_format = options.pretty == .All || options.pretty == .Format
	config.pretty_colors = (options.pretty == .All || options.pretty == .Colors) && options.colors != 0
	config.stdout_is_tty = options.env.stdout_is_tty
	// `explicit_json` is httpie's `args.json`, which is true whenever the
	// request type is JSON (cli/argparser.py:198) and false only for --form and
	// --multipart.
	config.explicit_json = options.body_kind != .Form && options.body_kind != .Multipart

	style, variant, found := output.resolve_style(options.style, options.colors)
	if !found {
		// argparse rejects an unknown --style before this point; a missing entry
		// here would mean the generated style table is out of step.
		output.print_error(ctx.out, options.program_name, "unknown style")
		return config, false
	}
	config.style = style
	config.variant = variant

	config.headers_sort = options.format_options.headers_sort
	config.json_format = options.format_options.json_format
	config.json_sort_keys = options.format_options.json_sort_keys
	switch options.format_options.json_indent {
	case 0:
		config.json_indent = .None
	case 2:
		config.json_indent = .Two
	case 4:
		config.json_indent = .Four
	case:
		config.json_indent = .Four
	}
	config.xml_format = options.format_options.xml_format
	config.xml_indent = options.format_options.xml_indent
	config.response_mime = options.response_mime
	config.response_charset = options.response_charset
	return config, true
}

// request_head_defaults is what httpie's session contributes to a request that
// does not carry the header itself (see output.build_request_head): the `Host`
// the URL implies. It is appended even when it is empty for the one request
// shape that can spell no authority at all and still be printed — a URL
// requests never prepared (`Url_Kind.Unprepared`), whose `Host` is the
// `urlsplit` netloc minus its userinfo and is therefore empty for
// `file:///etc/hostname` (models.py:150-151), exactly like the refused hop of a
// follow (`write_hop_messages`).
@(private)
request_head_defaults :: proc(ctx: ^Context, request: ^http.Request) -> output.Request_Head_Defaults {
	host, host_err := http.request_host_header(request, ctx.allocator)
	if host_err != .None {
		host = ""
	}
	return {
		host = host,
		host_always = request.url_kind == .Unprepared,
	}
}

// is_own_name reports whether a header name the CLI or the session asked for is
// one of httpie's request dict's own names. A Content-Length is not, once
// request_prepare has derived the length from the body: `requests` assigns that
// header over whatever the dict held (requests/models.py:499-513), so the line
// that renders belongs to requests and takes a contributed position.
@(private)
is_own_name :: proc(request: ^http.Request, name: string) -> bool {
	if request.content_length_derived && strings.equal_fold(name, "Content-Length") {
		return false
	}
	return true
}

// request_own_names is the provenance `order_request_headers` needs and the
// header list cannot express: the names httpie's *request dict* carries, in the
// order client.py builds it (client.py:60-96, :325-358). `requests` merges that
// dict under its own session defaults and httpie's transform_headers then
// re-appends every name in it — all occurrences of a name together — in the
// order the name sits in the merged list (client.py:212-260), which is what
// decides where a request's own headers print. Every name that is missing here
// was contributed by `requests` itself (its session defaults, the jar's Cookie,
// the body's Content-Length, a derived Transfer-Encoding, --auth's
// Authorization), and those print first.
//
// The order is `make_default_headers()`' own list first — User-Agent always,
// Accept for a JSON request type, Content-Type for the request types that get
// one from httpie rather than from `requests` — then the session's headers, then
// the item headers in the item dict's order (`fold`), then httpie's own
// Transfer-Encoding for `--offline --chunked`. The caller owns the result.
@(private)
request_own_names :: proc(
	ctx: ^Context,
	session: ^Session,
	request: ^http.Request,
	fold: ^cli.Header_Fold,
) -> ([]string, bool) {
	options := &ctx.options
	allocator := ctx.allocator

	session_headers := 0
	if session != nil {
		session_headers = len(session.headers)
	}
	items := len(options.item_set.headers)
	// The default names httpie's own list can contribute — User-Agent, Accept,
	// Content-Type, httpie's Transfer-Encoding, and a download's assigned
	// Accept-Encoding — plus one slot per session and item header: once the size
	// is known every name fits.
	names := make([]string, 5 + session_headers + items, allocator) or_else nil
	if names == nil {
		return nil, false
	}
	count := 0

	// make_default_headers (client.py:263-278): User-Agent always, and Accept
	// whenever the request type is JSON (`args.json or auto_json`, which is the
	// port's json_accept) — or the user asked for one, which replaces the
	// default's value but keeps its name in the dict.
	names[count] = "User-Agent"
	count += 1
	// `--download` assigns its own `Accept-Encoding` into that dict
	// (downloads.py:186-193, from core.py:205-206 — the hook runs on
	// `args.headers`, the dict client.py:343-358 builds the request from). The
	// name is therefore one of the request's own, and its slot is the second one
	// in `requests`' `default_headers()` — right after User-Agent — because the
	// merged list keeps the slot of a name the dict already carries
	// (sessions.py:461-476). That is where the line lands: after User-Agent and
	// before the session's and the item headers.
	if options.download {
		names[count] = "Accept-Encoding"
		count += 1
	}
	if request.json_accept || item_set_has_header(&options.item_set, "Accept") {
		names[count] = "Accept"
		count += 1
	}

	// The Content-Type's own position when httpie's defaults carry one. The
	// `.Last` case puts it after the session's and the item headers, so it is
	// appended at the end instead.
	content_type := content_type_position(ctx, session, request)
	if content_type == .Default {
		names[count] = "Content-Type"
		count += 1
	}

	// The session's headers are merged before the items, so they sit after the
	// defaults above and before them.
	if session != nil {
		for header in session.headers {
			if !is_own_name(request, header.name) {
				continue
			}
			names[count] = header.name
			count += 1
		}
	}
	// The item names in the order httpie's dict has them — the fold, not the
	// command line: a name the items unset is not in the finalized dict at all
	// (`finalize_headers` dropped the `None`) and is skipped here, which is what
	// keeps a header `requests` derived afterwards (the body's Content-Length,
	// a chunked Transfer-Encoding, --auth's Authorization) in its own band
	// rather than among the request's; a name an item set again after an unset
	// appears where the dict put it, at the end.
	for entry in fold.entries {
		if http.request_header_unset(request, entry.name) {
			continue
		}
		if !is_own_name(request, entry.name) {
			continue
		}
		names[count] = entry.name
		count += 1
	}

	if content_type == .Last {
		names[count] = "Content-Type"
		count += 1
	}

	// httpie's own Transfer-Encoding: the one `--offline --chunked` set
	// (client.py:347-350) or one an item spelled out. The online upload's
	// framing header is requests' own and takes the contributed place instead.
	if _, found := http.request_header_get(request, "Transfer-Encoding"); found && !request.transfer_encoding_derived {
		names[count] = "Transfer-Encoding"
		count += 1
	}
	return names[:count], true
}

// Content_Type_Position is where the request's Content-Type sits among the
// request's *own* headers, which the rendered order depends on.
@(private)
Content_Type_Position :: enum {
	// .None: no default behind it, so it keeps the position its item or the
	// session's header gave it (`X-Extra:a Content-Type:text/plain` on a
	// body-less request renders the item second).
	None,
	// .Default: httpie's make_default_headers carries one — a JSON request
	// type, a JSON body, a `@file` body, a form without file fields
	// (client.py:263-278) — so a Content-Type of any provenance sits where that
	// default was, two positions after User-Agent/Accept.
	Default,
	// .Last: the multipart Content-Type the CLI builds for a request with file
	// fields is assigned after the item headers (client.py:353-358), so it
	// follows them.
	Last,
}

// content_type_position is the Content-Type's provenance for
// request_own_names. `request` is the request after request_prepare, so the
// body's Content-Type is already on it.
@(private)
content_type_position :: proc(ctx: ^Context, session: ^Session, request: ^http.Request) -> Content_Type_Position {
	options := &ctx.options
	if _, found := http.request_header_get(request, "Content-Type"); !found {
		return .None
	}
	if request.json_accept {
		return .Default
	}
	if !form_like_body(options.body_kind) {
		return .None
	}
	if len(options.item_set.files) > 0 {
		// A file field makes the CLI build the multipart Content-Type itself,
		// after the item headers — unless an item or the session already
		// carries the name, which it replaces in place.
		if item_set_has_header(&options.item_set, "Content-Type") ||
		   session_has_header(session, "Content-Type") {
			return .None
		}
		return .Last
	}
	return .Default
}

// session_has_header reports whether the session's own header list carries
// `name`.
@(private)
session_has_header :: proc(session: ^Session, name: string) -> bool {
	if session == nil {
		return false
	}
	for header in session.headers {
		if strings.equal_fold(header.name, name) {
			return true
		}
	}
	return false
}

@(private)
item_set_has_header :: proc(set: ^cli.Item_Set, name: string) -> bool {
	for header in set.headers {
		if strings.equal_fold(header.name, name) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Failures and exit codes
// ---------------------------------------------------------------------------

@(private)
request_failure :: proc(ctx: ^Context, err: http.Error) -> bool {
	output.write_log_error(ctx.log, ctx.options.program_name, http.error_message(err))
	return false
}

// wire_failure prints the ValueError CPython's http.client raises while it
// writes a header line the prepare-time rule never saw — the first value of a
// repeated name, which `check_header_validity` does not validate (§3.1). The
// transport recorded the offending bytes and which half of the tuple they are;
// this is the only place it is printed. False when there is nothing to print.
@(private)
wire_failure :: proc(ctx: ^Context, req: ^http.Request) -> bool {
	if !req.wire_error.failed {
		return false
	}
	message := http.wire_header_message(&req.wire_error, ctx.allocator)
	defer delete(message, ctx.allocator)
	output.write_log_error(ctx.log, ctx.options.program_name, message)
	return true
}

// charset_failure prints the LookupError the reference raises while a message is
// written because one of the charset names it is about to use has no text codec
// in the registry — `Content-Type`'s `charset` parameter, or `--response-charset`
// (docs/PARITY.md section 3.4). The writer resolved the name where the reference
// does and recorded the exception (render.resolve_printed_charset); this is the
// only place it is printed, and it comes after whatever the run already wrote,
// because httpie's handler prints it from the frame the raise unwound through.
// False when there is nothing to print.
@(private)
charset_failure :: proc(ctx: ^Context, config: ^output.Write_Config) -> bool {
	if config.charset_error == "" {
		return false
	}
	output.write_log_error(ctx.log, ctx.options.program_name, config.charset_error)
	delete(config.charset_error, ctx.allocator)
	config.charset_error = ""
	return true
}

// encode_failure prints the UnicodeEncodeError the reference raises when one of
// the command line's strings cannot be re-encoded for the wire (a byte that is
// not valid UTF-8 in a value, a query item, a form field or a credential, or a
// header name that is not ASCII). The request recorded it where it happened;
// this is the only place it is printed. False when there is nothing to print.
@(private)
encode_failure :: proc(ctx: ^Context, req: ^http.Request) -> bool {
	if !req.encode_error.failed {
		return false
	}
	message := http.str_encode_error_message(&req.encode_error, ctx.allocator)
	defer delete(message, ctx.allocator)
	output.write_log_error(ctx.log, ctx.options.program_name, message)
	return true
}

// location_failure prints the UnicodeDecodeError the reference raises when a
// redirect's Location is not valid UTF-8: requests decodes the header inside
// its redirect loop (`get_redirect_target`, sessions.py:143-151), so the run
// ends with the exception's own message and exit 1 — with the response that
// answered the request already on stdout. The request recorded it where it
// happened (in the transport's redirect loop); this is the only place it is
// printed. False when there is nothing to print.
@(private)
location_failure :: proc(ctx: ^Context, req: ^http.Request) -> bool {
	if !req.location_error.failed {
		return false
	}
	message := http.str_utf8_decode_error_message(&req.location_error, ctx.allocator)
	defer delete(message, ctx.allocator)
	output.write_log_error(ctx.log, ctx.options.program_name, message)
	return true
}

// request_error is request_failure with the recorded UnicodeEncodeError first:
// the reference raises it while it prepares the request, so it is the error the
// run reports — and the port only ever reaches `err` when nothing was recorded.
@(private)
request_error :: proc(ctx: ^Context, req: ^http.Request, err: http.Error) -> bool {
	if encode_failure(ctx, req) {
		return false
	}
	return request_failure(ctx, err)
}

// transport_failure prints the error the transport reported, in httpie's own
// words: urllib3's exception text for a refusal and Python's gaierror plus
// httpie's hint for a name that will not resolve (docs/PARITY.md §7 item 4
// normalises these, but the port matches them byte-for-byte anyway); timeouts
// and the redirect limit have fixed wording (section 5).
@(private)
transport_failure :: proc(ctx: ^Context, req: ^http.Request, err: http.Error) -> int {
	options := &ctx.options
	// A header name that is not ASCII is what CPython's http.client refuses
	// while it writes the request line by line (`putheader`); nothing was sent.
	if encode_failure(ctx, req) {
		return int(cli.Exit_Code.Error)
	}
	// ...and a header line the wire rule refuses is the other half of that
	// same check, raised at the same site (the rendered head is already on
	// stdout, and no byte of the request went out).
	if wire_failure(ctx, req) {
		return int(cli.Exit_Code.Error)
	}
	// ...and a Location that is not valid UTF-8 ends the chain from inside the
	// redirect loop, with the UnicodeDecodeError's own message: the reference
	// decodes the header before the hop is made (§3.6).
	if location_failure(ctx, req) {
		return int(cli.Exit_Code.Error)
	}
	#partial switch err {
	case .No_Connection_Adapter:
		// requests' InvalidSchema, at the site the reference raises it: the
		// target a Location resolved to matched no mounted adapter, so the
		// request that was about to be sent never was (§3.6). The message is
		// requests' own and quotes the prepared URL with Python's `repr()`, so
		// the transport recorded the URL and the port builds the line from it.
		message := http.adapter_error_message(&req.adapter_error, ctx.allocator)
		defer delete(message, ctx.allocator)
		output.write_log_error(ctx.log, options.program_name, message)
		return int(cli.Exit_Code.Error)
	case .Connection_Failed:
		// urllib3's wording, which httpie prints as-is: requests wraps the
		// refusal in a retry wrapper, so the innermost cause carries the errno
		// (and the parity fixture only ever refuses on 127.0.0.1).
		port := req.port
		if port == 0 {
			port = req.scheme == .HTTPS ? 443 : 80
		}
		path := req.path
		if path == "" {
			path = "/"
		}
		message := fmt.aprintf(
			"ConnectionError: HTTPConnectionPool(host='%s', port=%d): Max retries exceeded with url: " +
			"%s (Caused by NewConnectionError(\"HTTPConnection(host='%s', port=%d): Failed to " +
			"establish a new connection: [Errno 111] Connection refused\")) while doing a %s " +
			"request to URL: %s",
			req.host,
			port,
			path,
			req.host,
			port,
			http.method_to_string(req.method),
			options.url,
			allocator = ctx.allocator,
		)
		defer delete(message, ctx.allocator)
		output.write_log_error(ctx.log, options.program_name, message)
		return int(cli.Exit_Code.Error)
	case .DNS_Failure:
		// socket.gaierror, then httpie's own hint line; unlike the other
		// transport failures this one carries no request/URL suffix
		// (client.py's gaierror handler).
		message := fmt.aprintf(
			"gaierror: [Errno -2] Name or service not known\nCouldn\u2019t resolve the given hostname. Please check the URL and try again.",
			allocator = ctx.allocator,
		)
		defer delete(message, ctx.allocator)
		output.write_log_error(ctx.log, options.program_name, message)
		return int(cli.Exit_Code.Error)
	case .Timeout:
		message := fmt.aprintf(
			"Request timed out (%ss).",
			timeout_text(options.timeout_s, ctx.allocator),
			allocator = ctx.allocator,
		)
		defer delete(message, ctx.allocator)
		output.write_log_error(ctx.log, options.program_name, message)
		return int(cli.Exit_Code.Timeout)
	case .Too_Many_Redirects:
		message := fmt.aprintf(
			"Too many redirects (--max-redirects=%d).",
			options.max_redirects,
			allocator = ctx.allocator,
		)
		defer delete(message, ctx.allocator)
		output.write_log_error(ctx.log, options.program_name, message)
		return int(cli.Exit_Code.Too_Many_Redirects)
	case .Max_Headers_Exceeded:
		// The response head grew past --max-headers: http.client's own wording,
		// wrapped the way requests wraps the HTTPException it raises. The
		// number in the message is the flag's value (client.py:143-153).
		base := http.max_headers_error_message(options.max_headers, ctx.allocator)
		defer delete(base, ctx.allocator)
		message := fmt.aprintf(
			"%s while doing a %s request to URL: %s",
			base,
			http.method_to_string(req.method),
			options.url,
			allocator = ctx.allocator,
		)
		defer delete(message, ctx.allocator)
		output.write_log_error(ctx.log, options.program_name, message)
		return int(cli.Exit_Code.Error)
	case:
		message := fmt.aprintf(
			"%s while doing a %s request to URL: %s",
			http.error_message(err),
			http.method_to_string(options.method),
			options.url,
			allocator = ctx.allocator,
		)
		defer delete(message, ctx.allocator)
		output.write_log_error(ctx.log, options.program_name, message)
		return int(cli.Exit_Code.Error)
	}
}

// timeout_text is the `1.0` in `Request timed out (1.0s)`: Python prints the
// float, which keeps one decimal for a whole number.
@(private)
timeout_text :: proc(seconds: f64, allocator: mem.Allocator) -> string {
	if seconds == f64(int(seconds)) {
		return fmt.aprintf("%d.0", int(seconds), allocator = allocator)
	}
	return fmt.aprintf("%v", seconds, allocator = allocator)
}

// status_exit_code maps the final status code to the process exit code when
// --check-status or --download asked for it (httpie/status.py, core.py:230-233).
//
// `console_fatal` reports that the warning this function prints for a failed
// reply is the message rich's console was about to render when `int(columns)`
// refused the run's `$COLUMNS`: the reference dies there — before it writes the
// reply and before any download starts (`env.log_error` builds the console,
// context.py:170-182) — so the caller ends the run instead (`write_log_crash`
// has written the exception's own line; docs/PARITY.md §3.1, §8.20).
@(private)
status_exit_code :: proc(ctx: ^Context, response: ^http.Response) -> (code: int, console_fatal: bool) {
	options := &ctx.options
	if !options.check_status && !options.download {
		return int(cli.Exit_Code.Ok), false
	}
	switch {
	case response.status >= 300 && response.status <= 399:
		if !(options.follow || options.download) {
			code = int(cli.Exit_Code.Http_3xx)
		}
	case response.status >= 400 && response.status <= 499:
		code = int(cli.Exit_Code.Http_4xx)
	case response.status >= 500 && response.status <= 599:
		code = int(cli.Exit_Code.Http_5xx)
	}
	if code != int(cli.Exit_Code.Ok) && (!options.env.stdout_is_tty || options.quiet == 1) {
		if !ctx.warnings_silenced {
			message := fmt.aprintf("HTTP %d %s", response.status, response.reason, allocator = ctx.allocator)
			defer delete(message, ctx.allocator)
			output.write_log_warning(ctx.log, options.program_name, message)
			return code, output.console_fatal(ctx.log)
		}
	}
	return code, false
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

// prepare_download opens the file the body will be written to and adjusts the
// request for it. It returns the open file, or nil when the body goes to
// stdout (`-d` without `-o` on a non-tty, cli/argparser.py:236-238).
@(private)
prepare_download :: proc(ctx: ^Context, request: ^http.Request) -> (file: ^os.File, err: http.Error) {
	options := &ctx.options
	allocator := ctx.allocator

	// httpie asks for an uncompressed stream so the file is exactly the body
	// (downloads.py:186-193: `request_headers['Accept-Encoding'] = 'identity'`,
	// the header dict it is building the request from). The assignment is a
	// dict one: it *replaces* the value the name already carries — the session's
	// `gzip, deflate` — rather than adding a second line, and the name's own
	// slot (right after User-Agent, where request_own_names puts it) is what
	// keeps the line there. request_assign_header is that assignment;
	// request_add_header would leave the announced line in place and append a
	// second one, both of them written since t_cf3b5f30.
	if err2 := http.request_assign_header(request, "Accept-Encoding", "identity"); err2 != .None {
		return nil, err2
	}

	resume_from: i64 = 0
	if options.output_file != "" {
		if options.download_resume {
			// os.stat hands back an owned File_Info (fullpath/name are
			// allocations of the allocator it was given), so it has to be
			// deleted — the resume path leaked its 271 bytes until this case
			// was added to the test suite.
			info, stat_err := os.stat(options.output_file, allocator)
			if stat_err == nil {
				resume_from = i64(info.size)
				os.file_info_delete(info, allocator)
			}
			if resume_from > 0 {
				handle, open_err := os.open(options.output_file, os.O_WRONLY | os.O_APPEND)
				if open_err != nil {
					return nil, .File_Read_Failed
				}
				file = handle
			}
		}
		if file == nil {
			handle, open_err := os.open(options.output_file, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
			if open_err != nil {
				return nil, .File_Read_Failed
			}
			file = handle
		}
	}

	if resume_from > 0 {
		range_value := fmt.aprintf("bytes=%d-", resume_from, allocator = allocator)
		defer delete(range_value, allocator)
		if err2 := http.request_add_header(request, "Range", range_value); err2 != .None {
			return file, err2
		}
	}
	ctx.download_resumed_from = resume_from
	return file, .None
}

// download_response writes the body where --download wants it and reports the
// two lines httpie prints on stderr (output/ui/rich_progress.py:22-54).
@(private)
download_response :: proc(
	ctx: ^Context,
	response: ^http.Response,
	config: ^output.Write_Config,
	target: ^os.File,
	elapsed_s: f64,
) -> int {
	options := &ctx.options
	allocator := ctx.allocator

	name := "<stdout>"
	if options.output_file != "" {
		name = options.output_file
	}

	// A resumed download only continues when the server agreed: httpie keeps
	// the bytes on disk when the reply is 206 Partial Content and throws them
	// away otherwise, because the body it just received starts at zero
	// (downloads.py:225-245, `if self._resume and
	// final_response.status_code == PARTIAL_CONTENT: ... else: seek(0);
	// truncate()`). The same test decides where the announced size comes from
	// below.
	resumed := options.download_resume && response.status == 206
	resumed_from := ctx.download_resumed_from
	if !resumed {
		if target != nil {
			// The file was opened for appending, so the first write after the
			// truncation lands at offset 0.
			_ = os.truncate(target, 0)
		}
		ctx.download_resumed_from = 0
		resumed_from = 0
	}

	// The size the progress display is given, and the two numbers the failure
	// below is decided from (downloads.py:219-231, 268-286): the final reply's
	// own `Content-Length`, replaced on the resumed 206 by the whole resource
	// size its `Content-Range` names — the body that just arrived is only the
	// remainder of it. A `Content-Range` that is missing or that does not name
	// the range the request asked for is the ContentRangeError the reference
	// raises out of `Downloader.start`: the display does not exist yet and no
	// byte has been written, so the run ends with the error line alone
	// (core.py:138-141).
	total_size: i64
	have_total := false
	if value, found := response_header_value(response, "Content-Length"); found {
		// `int(final_response.headers['Content-Length'])`: a value the
		// conversion refuses is an absent header (downloads.py:219-223).
		if number, ok := download_int(value); ok {
			total_size, have_total = number, true
		}
	}
	if resumed {
		value, found := response_header_value(response, "Content-Range")
		number, failure := download_content_range(value, found, resumed_from)
		if failure != .None {
			reason := content_range_error_reason(failure, value, resumed_from, allocator)
			defer delete(reason, allocator)
			message := fmt.aprintf("ContentRangeError: %s", reason, allocator = allocator)
			defer delete(message, allocator)
			output.write_log_error(ctx.log, options.program_name, message)
			return int(cli.Exit_Code.Error)
		}
		total_size, have_total = number, true
	}

	// The body: the file when -o was given, the real stdout otherwise. The
	// bytes that go out are the ones the reference's progress task is advanced
	// by, one chunk at a time (`chunk_downloaded`, downloads.py:278-286).
	//
	// Before a byte of it is written, the display the reference starts
	// (`self.status.started`, downloads.py:254 → `start_display` → the progress
	// bar) is a rich renderable whose console is `env.rich_error_console`
	// (output/ui/rich_progress.py:28, :110) — built out of the run's
	// `$COLUMNS`, so a value rich's `int()` refuses kills the reference right
	// here, with the reply's head already printed, the file already opened and
	// empty, and no byte of the body written. That is `console_fatal`: the port
	// writes the exception's own line and ends the run the same way
	// (`cli.console_crash`; docs/PARITY.md §3.1, §8.20, t_14a26d57).
	console := output.Console {
		writer = ctx.stderr,
		width  = cli.console_width(options.env),
		crash  = cli.console_crash(options.env),
	}
	if output.console_fatal(console) {
		output.write_log_crash(console, options.program_name)
		return int(cli.Exit_Code.Error)
	}

	moved: i64
	if target != nil {
		written, write_err := os.write(target, response.body)
		if write_err != nil {
			return int(cli.Exit_Code.Error)
		}
		moved = i64(written)
	} else if len(response.body) > 0 {
		if err := output.write_raw_bytes(ctx.stdout, response.body); err != .None {
			return int(cli.Exit_Code.Error)
		}
		moved = i64(len(response.body))
	}

	// "Downloading to X" first, then the summary once the transfer is over.
	// Both go through a rich Console in the reference, so both are wrapped to
	// the console's width (`cli.console_width`: $COLUMNS when it holds digits,
	// else rich's 80 — see output.write_console_line) and both are dropped by a
	// zero-width one, the blank line the bar leaves between them included: it
	// is part of the same rich renderable. A console rich cannot build never
	// gets this far (above).
	downloaded := moved + resumed_from
	message := fmt.aprintf("Downloading to %s", name, allocator = allocator)
	defer delete(message, allocator)
	if err := output.write_console_line(console, message); err != .None {
		return int(cli.Exit_Code.Error)
	}
	// The blank line between the description and the summary belongs to the
	// progress bar; the status spinner a reply without a `Content-Length` gets
	// prints the description alone and then the summary
	// (output/ui/rich_progress.py:63-79, 100-131).
	if have_total && !output.console_silent(console) {
		if err := output.write_raw_bytes(ctx.stderr, []u8{'\n'}); err != .None {
			return int(cli.Exit_Code.Error)
		}
	}
	// rich's `Task.finished` is set by the advance a body chunk makes, and only
	// once that advance reaches the total (rich/progress.py:1009-1011,
	// 1539-1545): a reply that never delivered a byte advances nothing, so the
	// task is never marked finished and the summary says `Interrupted.` even
	// though the download "succeeded" and exits 0
	// (output/ui/rich_progress.py:33-42, 122-131). Without a `Content-Length`
	// the display is a status spinner instead, and its summary verb is always
	// `Done` (rich_progress.py:63-79).
	finished := !have_total || (moved > 0 && downloaded >= total_size)
	speed := f64(downloaded) / elapsed_s
	elapsed := elapsed_text(elapsed_s, allocator)
	defer delete(elapsed, allocator)
	summary := fmt.aprintf(
		"%s. %d bytes in %s (%v bytes/s)",
		finished ? "Done" : "Interrupted",
		downloaded,
		elapsed,
		speed,
		allocator = allocator,
	)
	defer delete(summary, allocator)
	if err := output.write_console_line(console, summary); err != .None {
		return int(cli.Exit_Code.Error)
	}
	// The second half of the same accounting: a length the reply announced and
	// did not deliver is an error, printed after the summary and turned into
	// exit 1 (downloads.py:268-276, core.py:250-258). A `total_size` of 0 is
	// falsy in the reference, so a body announced as empty stays a success.
	if have_total && total_size != 0 && total_size != downloaded {
		message2 := fmt.aprintf(
			"Incomplete download: size=%d; downloaded=%d",
			total_size,
			downloaded,
			allocator = allocator,
		)
		defer delete(message2, allocator)
		output.write_log_error(ctx.log, options.program_name, message2)
		return int(cli.Exit_Code.Error)
	}
	return int(cli.Exit_Code.Ok)
}

// response_header_value reads one header out of the final reply, the way
// requests' CaseInsensitiveDict does: case-insensitively, first match wins.
@(private)
response_header_value :: proc(response: ^http.Response, name: string) -> (string, bool) {
	for header in response.headers {
		if strings.equal_fold(header.name, name) {
			return header.value, true
		}
	}
	return "", false
}

// download_int is the `int(...)` the reference applies to the `Content-Length`
// of a reply (downloads.py:221): surrounding whitespace, an optional sign,
// digits with single '_' separators — what cli/parse.odin's parse_python_int
// does for the command line, file-private there. A digit run longer than an i64
// saturates: Python's integers are unbounded, but such a length can never be
// met, so only the number an error prints can differ.
@(private)
download_int :: proc(value: string) -> (number: i64, ok: bool) {
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
	for index in 0 ..< len(text) {
		character := text[index]
		switch character {
		case '0' ..= '9':
			strings.write_byte(&digits, character)
			seen_digit = true
			previous_underscore = false
		case '_':
			if !seen_digit || previous_underscore || index == len(text) - 1 {
				return 0, false
			}
			previous_underscore = true
		case:
			return 0, false
		}
	}
	parsed, parsed_ok := strconv.parse_i64(strings.to_string(digits))
	if !parsed_ok {
		return negative ? min(i64) : max(i64), true
	}
	return negative ? -parsed : parsed, true
}

// Download_Content_Range_Error names the ContentRangeError `parse_content_range`
// raises for the Content-Range of a resumed 206 (downloads.py:29-81). `None` is
// the header that names the range the request asked for.
@(private)
Download_Content_Range_Error :: enum {
	None,
	Missing,
	Format,
	Invalid,
	Unexpected,
}

// download_content_range is `parse_content_range`: the whole resource size a
// `Content-Range` names — `last_byte_pos + 1` of
// `^bytes (?P<first>\d+)-(?P<last>\d+)/(\*|(?P<instance>\d+))$` — or why the
// header is refused, in the order the reference checks (downloads.py:34-81).
@(private)
download_content_range :: proc(
	value: string,
	found: bool,
	resumed_from: i64,
) -> (total: i64, failure: Download_Content_Range_Error) {
	if !found {
		return 0, .Missing
	}
	rest := value
	if !strings.has_prefix(rest, "bytes ") {
		return 0, .Format
	}
	rest = rest[len("bytes "):]
	first_end := digit_run_end(rest)
	if first_end == 0 {
		return 0, .Format
	}
	first, _ := download_int(rest[:first_end])
	rest = rest[first_end:]
	if len(rest) == 0 || rest[0] != '-' {
		return 0, .Format
	}
	rest = rest[1:]
	last_end := digit_run_end(rest)
	if last_end == 0 {
		return 0, .Format
	}
	last, _ := download_int(rest[:last_end])
	rest = rest[last_end:]
	if len(rest) == 0 || rest[0] != '/' {
		return 0, .Format
	}
	rest = rest[1:]
	instance: i64
	have_instance := false
	if rest == "*" {
		// `instance_length` stays None: the size is unknown.
	} else {
		instance_end := digit_run_end(rest)
		if instance_end == 0 || instance_end != len(rest) {
			return 0, .Format
		}
		instance, _ = download_int(rest[:instance_end])
		have_instance = true
	}

	// "A byte-content-range-spec whose last-byte-pos value is less than its
	// first-byte-pos value, or whose instance-length value is less than or
	// equal to its last-byte-pos value, is invalid." — then the range has to be
	// the one the request asked for (downloads.py:60-81).
	if first > last || (have_instance && instance <= last) {
		return 0, .Invalid
	}
	if first != resumed_from || (have_instance && last != instance - 1) {
		return 0, .Unexpected
	}
	return last == max(i64) ? last : last + 1, .None
}

// content_range_error_reason is `str(e)` of the ContentRangeError the reference
// raises: the header value spliced with `repr()`, as every value httpie prints
// is (downloads.py:34-81).
@(private)
content_range_error_reason :: proc(
	failure: Download_Content_Range_Error,
	value: string,
	resumed_from: i64,
	allocator: mem.Allocator,
) -> string {
	if failure == .Missing {
		return strings.clone("Missing Content-Range", allocator) or_else ""
	}
	if failure == .None {
		return strings.clone("", allocator) or_else ""
	}
	repr := cli.python_repr(value, allocator)
	defer delete(repr, allocator)
	switch failure {
	case .Format:
		return fmt.aprintf("Invalid Content-Range format %s", repr, allocator = allocator)
	case .Invalid:
		return fmt.aprintf("Invalid Content-Range returned: %s", repr, allocator = allocator)
	case .Unexpected:
		return fmt.aprintf(
			"Unexpected Content-Range returned (%s) for the requested Range (\"bytes=%d-\")",
			repr,
			resumed_from,
			allocator = allocator,
		)
	case .Missing, .None:
		return "" // handled above; the switch needs every case
	}
	return "" // unreachable: every case returns
}

// digit_run_end is the length of the leading `\d+` of `text`: the regex's own
// "one or more digits", which is how each part of a Content-Range is delimited.
@(private)
digit_run_end :: proc(text: string) -> int {
	index := 0
	for index < len(text) && text[index] >= '0' && text[index] <= '9' {
		index += 1
	}
	return index
}

// elapsed_text is rich's `MM:SS.fffff` (rich_progress.py:44-52).
@(private)
elapsed_text :: proc(seconds: f64, allocator: mem.Allocator) -> string {
	minutes := int(seconds) / 60
	rest := seconds - f64(minutes * 60)
	return fmt.aprintf("%02d:%.5f", minutes, rest, allocator = allocator)
}
