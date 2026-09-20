// The parity renderer: httpie's output contract, byte for byte.
//
// This is the layer `main` never sees directly: the session turns the parsed
// options plus one request/response pair into these calls, and everything the
// user reads comes out of the io.Writer passed in.
//
// Ported from httpie 3.2.4 (paths relative to the reference site-packages tree):
//
//	output/streams.py:30-254        the message pipeline: head + CRLF CRLF, body,
//	                                metadata, the binary-suppressed notice, and the
//	                                tty-only trailing blank line
//	output/writer.py:23-150         MESSAGE_SEPARATOR handling
//	output/processing.py:26-57      the plugin order: the `format` group, then the
//	                                `colors` group
//	output/formatters/headers.py    headers.sort (stable, status line first)
//	output/formatters/json.py       json.dumps(sort_keys, ensure_ascii=False, indent)
//	output/formatters/colors.py     header/body/metadata colouring selection
//	models.py:23-158                the header text and the metadata text
//	utils.py:143-153, 203-218       split_cookies, parse_content_type_header
//
// The colouring itself (Pygments' lexers and formatters) lives in colorize.odin;
// this file decides *which* lexer and formatter apply and in what order the
// pieces are written.
//
// Ownership: every allocation comes from Write_Config.allocator and is released
// before the proc that made it returns. Nothing here reads `context.allocator`.
package output

import "core:fmt"
import "core:io"
import "core:mem"
import "core:strings"

import "src:format"
import "src:http"
import "src:rich"

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Json_Indent is json.dumps' `indent` argument as the CLI can set it.
Json_Indent :: enum {
	None, // json.dumps(indent=None): newlines, no indentation
	Two,
	Four, // the default
	Tabs, // json.dumps(indent="\t")
}

// Write_Config is everything the renderer needs that is not part of the message:
// which parts to print, how far to prettify, and which colour tables to use.
// The session builds one per run; the renderer owns nothing in it.
Write_Config :: struct {
	allocator: mem.Allocator,

	// The two --pretty groups (httpie/output/processing.py:6-23).
	pretty_format: bool,
	pretty_colors: bool,

	// The resolved --style: the escape tables plus the header lexer they came
	// from (output/formatters/colors.py:64-96).
	style:   Style,
	variant: Lex_Variant,

	// --format-options, after the CLI defaults and every override.
	headers_sort:   bool,
	json_format:    bool,
	json_sort_keys: bool,
	json_indent:    Json_Indent,
	xml_format:     bool,
	xml_indent:     int,

	// --json: treat a body whose Content-Type says otherwise as JSON.
	explicit_json: bool,

	// --response-mime / --response-charset.
	response_mime:    string,
	response_charset: string,

	// charset_error is the exception the reference raises while a message is
	// written because a charset name could not be resolved — `LookupError`, from
	// `handle_generic_error`'s `f'{type(e).__name__}: {msg}'` already applied
	// (`resolve_printed_charset`). The session prints it and stops, which is what
	// httpie's handler does with it: nothing of the part that needed the charset
	// reaches stdout (core.py:54-65).
	charset_error: string,

	stdout_is_tty: bool,
}

// resolve_style maps a --style name and the terminal's colour count to the
// escape tables and the header lexer httpie would pick
// (output/formatters/colors.py:64-133):
//
//	`auto`, or any style on a terminal without 256 colours, uses the Pygments
//	HttpLexer with the TerminalFormatter tables;
//	the pie styles use SimplifiedHTTPLexer(precise=True);
//	every other style uses SimplifiedHTTPLexer(precise=False).
//
// An empty `name` is the untouched default (`auto`).
resolve_style :: proc(name: string, colors: int) -> (style: Style, variant: Lex_Variant, ok: bool) {
	use_auto := name == "" || name == DEFAULT_STYLE_NAME
	if use_auto || colors != 256 {
		found: bool
		style, found = style_lookup(DEFAULT_STYLE_NAME)
		return style, .Pygments_Http, found
	}
	found: bool
	style, found = style_lookup(name)
	if !found {
		return {}, .Simplified_Head, false
	}
	precise := name == "pie" || name == "pie-dark" || name == "pie-light"
	return style, precise ? .Simplified_Precise : .Simplified_Head, true
}

// Parts says which pieces of one message are printed; the session derives it
// from --print (docs/PARITY.md section 4.1).
Parts :: struct {
	head: bool,
	body: bool,
	meta: bool,
}

parts_any :: proc(parts: Parts) -> bool {
	return parts.head || parts.body || parts.meta
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// MESSAGE_SEPARATOR goes between two printed messages when the previous one
// printed a body (output/writer.py:23, core.py:183).
MESSAGE_SEPARATOR :: "\n\n"

// BINARY_SUPPRESSED_NOTICE is what a printed body holding a NUL byte becomes
// (output/streams.py:12-17).
BINARY_SUPPRESSED_NOTICE :: "\n+-----------------------------------------+\n| NOTE: binary data not shown in terminal |\n+-----------------------------------------+"

// SKIP_HEADER is urllib3's sentinel for "this header must not be sent", and
// SKIPPABLE_HEADERS the names it is allowed on; both live in the http package
// because the transport needs them too (src/http/skippable.odin).
SKIP_HEADER :: http.SKIP_HEADER

DEFAULT_USER_AGENT :: "HTTPie/3.2.4"
DEFAULT_ACCEPT_ENCODING :: "gzip, deflate"
DEFAULT_CONNECTION :: "keep-alive"
JSON_ACCEPT :: "application/json, */*;q=0.5"
NON_JSON_ACCEPT :: "*/*"

// ---------------------------------------------------------------------------
// Request head
// ---------------------------------------------------------------------------

// Request_Head_Defaults is what the session contributes to a request that does
// not carry it itself: the `Host` the URL implies. Everything else in the head
// comes from the request's header list, which the session has already ordered
// (see order_request_headers).
Request_Head_Defaults :: struct {
	// host is rendered last, and only when the request carries no `Host` of its
	// own (models.py:142-144).
	host: string,
	// host_always renders that `Host` even when `host` is empty. httpie's model
	// appends the header for a request that carries none whatever the netloc is
	// (`headers['Host'] = url.netloc.split('@')[-1]`, models.py:150-151), so a
	// target requests has no adapter for — which nothing prepares and which may
	// spell no authority at all — prints `Host: ` where every sent request's
	// Host has a value. Only such a hop sets this.
	host_always: bool,
}

// OWN_FIRST is the front of the request's own headers when `requests` re-appends
// them: the names it merges *in front of* the request dict are its session
// defaults (sessions.py:461-476, `default_headers()`), so those come back in
// that order and every other own header follows in the request dict's order
// (client.py:241-258).
@(private)
OWN_FIRST := [?]string{"User-Agent", "Accept-Encoding", "Accept", "Connection"}

// CONTRIBUTED_ORDER is the order of the headers `requests` contributes itself:
// the session defaults it kept, in `default_headers()` order, then the ones it
// generated while preparing the request, in the order it adds them — the jar's
// `Cookie` (`prepare_cookies`), the body's `Content-Length` and a chunked
// `Transfer-Encoding` (`prepare_body`, `prepare_content_length`), and `--auth`'s
// `Authorization` (`prepare_auth`, requests/models.py:452-499). They all print
// *before* the request's own headers, because httpie's transform_headers moves
// the own ones to the back (client.py:212-260).
@(private)
CONTRIBUTED_ORDER := [?]string {
	"Accept-Encoding",
	"Accept",
	"Connection",
	"Cookie",
	"Content-Length",
	"Transfer-Encoding",
	"Authorization",
}

// POST_TRANSFORM_ORDER is what httpie adds to the prepared headers *after*
// transform_headers has already re-appended the request's own ones:
// `--compress`'s `Content-Encoding` (client.py:99-103). It therefore prints
// last, after them.
@(private)
POST_TRANSFORM_ORDER := [?]string{"Content-Encoding"}

// The rank bands: contributed headers first, then the request's own. The bands
// are far enough apart that a header list of any plausible length stays inside
// its band.
@(private)
UNKNOWN_RANK_BASE :: 1 << 10

@(private)
OWN_RANK_BASE :: 1 << 20

// header_rank is the position `name` gets in the rendered head. `own` is the
// request's provenance — the names httpie's request dict carried, in the order
// client.py builds it; `list_index` is where the header sits in the list, which
// is all an unknown contributed header has to go on.
@(private)
header_rank :: proc(name: string, own: []string, list_index: int) -> int {
	own_index := -1
	for candidate, i in own {
		if strings.equal_fold(candidate, name) {
			own_index = i
			break
		}
	}
	if own_index >= 0 {
		// The request's own: the session-default names first, in the session's
		// order, then the request dict's own order.
		for first, position in OWN_FIRST {
			if strings.equal_fold(first, name) {
				return OWN_RANK_BASE + position
			}
		}
		return OWN_RANK_BASE + len(OWN_FIRST) + own_index
	}
	for contributed, position in CONTRIBUTED_ORDER {
		if strings.equal_fold(contributed, name) {
			return position
		}
	}
	// Added after the transform: it follows every one of the request's own
	// headers.
	for appended, position in POST_TRANSFORM_ORDER {
		if strings.equal_fold(appended, name) {
			return OWN_RANK_BASE + len(OWN_FIRST) + len(own) + position
		}
	}
	// Not one of the request's own and not one of the headers this port knows
	// `requests` contributes: it keeps its place after them, in list order.
	return UNKNOWN_RANK_BASE + list_index
}

// order_request_headers rewrites the request's header list into httpie's order
// — the order the reference prints and sends. The transport does not know that
// order (libcurl derives its own), so the session calls this once the request is
// prepared and everything that renders or sends it sees the same sequence, which
// is the reference's: `requests` contributes its own headers first, and httpie
// then re-appends the request's own headers — every occurrence of a name
// together — in the order that name sits in the prepared list (client.py:60-96,
// :212-260).
//
// `own` is the provenance the list itself cannot express, and it is required:
// it is the names httpie's request dict carried, in the order client.py builds
// it (`make_default_headers`', the session's, the items', httpie's own
// `Transfer-Encoding`). A name missing from it was contributed by `requests`
// and is printed before the request's own headers. The session computes it in
// request_own_names; with an empty `own` the contributed names still lead, in
// the order CONTRIBUTED_ORDER gives them.
//
// The one header whose wire position this cannot decide is `Host`: libcurl
// emits it first whatever the list says (docs/PARITY.md §8).
order_request_headers :: proc(
	req: ^http.Request,
	own: []string,
	allocator: mem.Allocator,
) -> bool {
	if len(req.headers) < 2 {
		return true
	}
	ranks := make([]int, len(req.headers), allocator) or_else nil
	if ranks == nil {
		return false
	}
	defer delete(ranks, allocator)
	for header, i in req.headers {
		ranks[i] = header_rank(header.name, own, i)
	}

	// Insertion sort: stable, so the occurrences of one name keep their
	// relative order — the reference re-appends them in the order the command
	// line gave them.
	for i in 1 ..< len(req.headers) {
		j := i
		for j > 0 && ranks[j - 1] > ranks[j] {
			req.headers[j - 1], req.headers[j] = req.headers[j], req.headers[j - 1]
			ranks[j - 1], ranks[j] = ranks[j], ranks[j - 1]
			j -= 1
		}
	}
	return true
}

// The render filter of HTTPRequest.headers (models.py:153-157) is
// http.request_header_skipped (src/http/request.odin): a header only the *item*
// unset — the `None` urllib3 replaces with its sentinel — is left out of the
// head, which is also why the head and the wire cannot disagree about such a
// line (connection.py:477-487). `Host` is the special case: the caller must
// still count one as carried (see build_request_head).

// build_request_head is HTTPRequest.headers (models.py:130-158): the request
// line, then every header of the prepared list in the order it is sent
// (order_request_headers put it there), then `Host` when the request does not
// carry one. A request that *does* carry a Host renders it once per item, where
// its provenance puts it. The result has no trailing CRLF; the caller owns it.
//
// The block this builds is the *str* the reference renders, and the encoding of
// it is the stream's, over the whole block — `BaseStream`'s `.encode()` (utf-8)
// or, when a prettify group put the message in a `PrettyStream`, the message's
// own charset (:191-197). So nothing is checked here: `write_head` encodes the
// built block with the stream's codec and the failure it reports is the
// reference's, with the position in the block (docs/PARITY.md section 3.4). A
// character the *str layer* refuses on the way to the wire — a header value that
// is not valid UTF-8, which `finalize_headers` raises on before anything is
// rendered — is a different site, and the request keeps that first failure
// (request_encode_check).
build_request_head :: proc(
	req: ^http.Request,
	target: string,
	defaults: Request_Head_Defaults,
	allocator: mem.Allocator,
) -> string {
	builder := strings.builder_make(allocator)
	line := fmt.aprintf("%s %s HTTP/1.1", http.request_method(req), target, allocator = allocator)
	defer delete(line, allocator)
	strings.write_string(&builder, line)

	has_host := false
	for header in req.headers {
		if strings.equal_fold(header.name, "Host") {
			// models.py tests `'Host' not in headers` on the dict *after* the
			// sentinel substitution, so a `Host:` the user unset counts as
			// carried: the head appends no Host of its own and urllib3 writes
			// none either (the line itself is dropped by `is_skipped_header`).
			has_host = true
		}
		if http.request_header_skipped(req, header.name, header.value) {
			continue
		}
		fmt.sbprintf(&builder, "\r\n%s: %s", header.name, header.value)
	}

	// Host is appended last when the request has none (models.py:142-144); the
	// user's own Host lines came out with the request's headers. It is appended
	// even when it is empty for a request httpie's model synthesized one for
	// whatever the URL was (`host_always`, models.py:150-151) — and then the
	// line has no value *and no space*: the reference builds the block as
	// `'\r\n'.join(...)` and strips it (models.py:157), which eats the space a
	// trailing empty `Host: ` would leave.
	if !has_host && (defaults.host != "" || defaults.host_always) {
		if defaults.host == "" {
			fmt.sbprintf(&builder, "\r\nHost:")
		} else {
			fmt.sbprintf(&builder, "\r\nHost: %s", defaults.host)
		}
	}
	return strings.to_string(builder)
}

// ---------------------------------------------------------------------------
// Response head
// ---------------------------------------------------------------------------

// build_response_head is HTTPResponse.headers (models.py:71-87): the status line
// followed by every header, with each Set-Cookie value on a line of its own. The
// caller owns the result.
build_response_head :: proc(res: ^http.Response, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)

	version := res.http_version
	if version == "" {
		version = "HTTP/1.1"
	} else if !strings.has_prefix(version, "HTTP/") {
		version = fmt.aprintf("HTTP/%s", version, allocator = allocator)
	}
	fmt.sbprintf(&builder, "%s %d %s", version, res.status, res.reason)

	// Every header but Set-Cookie keeps its place in the head; the Set-Cookie
	// lines come last, one line per cookie (models.py:70-86).
	for header in res.headers {
		if strings.equal_fold(header.name, "Set-Cookie") {
			continue
		}
		fmt.sbprintf(&builder, "\r\n%s: %s", header.name, header.value)
	}
	for header in res.headers {
		if !strings.equal_fold(header.name, "Set-Cookie") {
			continue
		}
		rest := header.value
		for {
			piece, next, more := split_cookie_next(rest)
			fmt.sbprintf(&builder, "\r\n%s: %s", header.name, piece)
			if !more {
				break
			}
			rest = next
		}
	}
	return strings.to_string(builder)
}

// split_cookie_next is one step of RE_COOKIE_SPLIT = r', (?=[^ ;]+=)'
// (utils.py:21, :143-153): the next cookie starts at ", " when an unbroken run of
// non-space, non-';' characters follows and ends with '='.
@(private)
split_cookie_next :: proc(value: string) -> (piece: string, rest: string, more: bool) {
	for i := 0; i + 1 < len(value); i += 1 {
		if value[i] != ',' || value[i + 1] != ' ' {
			continue
		}
		j := i + 2
		found_equals := false
		for j < len(value) {
			c := value[j]
			if c == ' ' || c == ';' {
				break
			}
			if c == '=' {
				found_equals = true
				break
			}
			j += 1
		}
		if found_equals {
			return value[:i], value[i + 2:], true
		}
	}
	return value, "", false
}

// ---------------------------------------------------------------------------
// Header block formatting
// ---------------------------------------------------------------------------

// format_headers_sort is HeadersFormatter.format_headers
// (output/formatters/headers.py:10-18): every line but the first is sorted by the
// text before the first ':' — a stable sort, so repeated names keep their
// relative order — and the lines are re-joined with CRLF. The caller owns the
// result.
format_headers_sort :: proc(head: string, allocator: mem.Allocator) -> string {
	if !strings.contains(head, "\r\n") {
		return strings.clone(head, allocator) or_else ""
	}
	lines := make([dynamic]string, 0, 16, allocator)
	defer delete(lines)
	rest := head
	for {
		index := strings.index(rest, "\r\n")
		if index < 0 {
			append(&lines, rest)
			break
		}
		append(&lines, rest[:index])
		rest = rest[index + 2:]
	}

	// Only the lines after the status line are sorted (Python: `sorted(lines[1:])`
	// then `lines[:1] + sorted_rest`), so the inner loop never reaches index 0.
	for i := 1; i < len(lines); i += 1 {
		key := header_sort_key(lines[i])
		j := i
		for j > 1 && header_sort_key(lines[j - 1]) > key {
			lines[j], lines[j - 1] = lines[j - 1], lines[j]
			j -= 1
		}
	}

	builder := strings.builder_make(allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_string(&builder, "\r\n")
		}
		strings.write_string(&builder, line)
	}
	// The builder's buffer is handed over as a *copy*: the caller must own a
	// string that outlives this proc's locals.
	result := strings.clone(strings.to_string(builder), allocator) or_else ""
	strings.builder_destroy(&builder)
	return result
}

@(private)
header_sort_key :: proc(line: string) -> string {
	if index := strings.index(line, ":"); index >= 0 {
		return line[:index]
	}
	return line
}

// ---------------------------------------------------------------------------
// Body formatting
// ---------------------------------------------------------------------------

// is_valid_mime is processing.py's MIME_RE: formatting only runs for a
// well-formed `type/subtype`.
@(private)
is_valid_mime :: proc(mime: string) -> bool {
	slash := strings.index(mime, "/")
	return slash > 0 && slash < len(mime) - 1
}

// mime_mentions_json is JSONFormatter's `any(token in mime for token in
// ['json', 'javascript', 'text'])` — a substring test, which is why a text/plain
// body is offered to the JSON parser as well.
@(private)
mime_mentions_json :: proc(mime: string) -> bool {
	return strings.contains(mime, "json") ||
	       strings.contains(mime, "javascript") ||
	       strings.contains(mime, "text")
}

// format_body applies the `format` group to a body: JSONFormatter first, then
// XMLFormatter, which is the order httpie's plugin registry runs them in
// (output/processing.py:26-57). `owned` says whether the result is a fresh
// allocation that the caller must release; when it is false the body itself is
// returned and nothing was allocated.
format_body :: proc(body: string, mime: string, cfg: ^Write_Config) -> (text: string, owned: bool) {
	if !is_valid_mime(mime) {
		return body, false
	}
	text = body
	if cfg.json_format {
		if json, allocated := format_json_body(text, mime, cfg); allocated {
			text = json
			owned = true
		}
	}
	// `'xml' in mime` is XMLFormatter's own gate (formatters/xml.py:50-51): a
	// substring test, so any mime type that mentions xml is offered the parser.
	if cfg.xml_format && strings.contains(mime, "xml") {
		if pretty, changed := format.xml_pretty_body(text, cfg.xml_indent, cfg.allocator); changed {
			if owned {
				delete(text, cfg.allocator)
			}
			text = pretty
			owned = true
		}
	}
	return text, owned
}

// format_json_body is JSONFormatter.format_body (output/formatters/json.py:12-34).
// The caller owns the result when `owned` is true; otherwise the body was left
// alone because it was not offered to the parser or did not parse.
@(private)
format_json_body :: proc(body: string, mime: string, cfg: ^Write_Config) -> (text: string, owned: bool) {
	if !cfg.explicit_json && !mime_mentions_json(mime) {
		return body, false
	}

	// load_prefixed_json + json.dumps: the non-JSON prefix is kept verbatim and
	// the JSON that follows is re-serialised. A body that does not parse is left
	// alone (JSONFormatter swallows the ValueError).
	value, prefix_len, json_err := format.parse_prefixed_json(body, cfg.allocator)
	if json_err.message != "" {
		format.json_error_destroy(&json_err)
		return body, false
	}
	defer format.value_destroy(&value, cfg.allocator)

	options := format.Dump_Options {
		indent       = -1,
		sort_keys    = cfg.json_sort_keys,
		ensure_ascii = false,
		// This dump is the *printed* body, and the stream that writes it then
		// encodes it with `errors='replace'`: a marked lone surrogate — a
		// character the port's bytes cannot hold — is written as '?' here
		// rather than as the placeholder it stands on
		// (format.Dump_Options.printed; the in-band half of the same rule is
		// encode_printed_part below).
		printed      = true,
	}
	switch cfg.json_indent {
	case .None:
		options.indent = -1
	case .Two:
		options.indent = 2
	case .Four:
		options.indent = 4
	case .Tabs:
		options.indent = 1
		options.indent_tabs = true
	}

	builder := strings.builder_make(cfg.allocator)
	if prefix_len > 0 {
		strings.write_string(&builder, body[:prefix_len])
	}
	dumped := format.dump_to_string(&value, options, cfg.allocator)
	// The dump is the caller's to release — it is the builder's own buffer
	// handed over as a string (json.odin:628-634).
	defer delete(dumped, cfg.allocator)
	strings.write_string(&builder, dumped)
	result := strings.clone(strings.to_string(builder), cfg.allocator) or_else ""
	strings.builder_destroy(&builder)
	return result, true
}

// ---------------------------------------------------------------------------
// Body colouring
// ---------------------------------------------------------------------------

// colorize_body runs the `colors` group on a body: the lexer httpie picks for
// the mime type, or the bytes untouched when no lexer applies
// (output/formatters/colors.py:135-193).
@(private)
colorize_body :: proc(body: string, mime: string, cfg: ^Write_Config, out: ^strings.Builder) {
	lexed: Lexed
	colored := true
	switch {
	case strings.equal_fold(mime, "application/json"),
	     strings.equal_fold(mime, "text/json"),
	     strings.has_suffix(mime, "+json"):
		lexed = lex_json(body, cfg.allocator)
	case strings.equal_fold(mime, "text/plain"):
		lexed = lex_text(body, cfg.allocator)
	case strings.equal_fold(mime, "application/xml"),
	     strings.equal_fold(mime, "text/xml"),
	     strings.equal_fold(mime, "image/svg+xml"),
	     strings.equal_fold(mime, "application/rss+xml"),
	     strings.equal_fold(mime, "application/atom+xml"):
		// Every mime type pygments' XmlLexer advertises (html.py:206-207).
		// Pygments resolves mime types case-insensitively, which is why the
		// comparison folds even though the XML *formatter*'s `'xml' in mime`
		// test does not.
		if xml, ok := lex_xml(body, cfg.allocator); ok {
			lexed = xml
		} else {
			colored = false
		}
	case:
		// Pygments resolves a lexer by mime type first and by name second. The
		// body lexers this port reaches are JSON, plain text and XML; anything
		// else (HTML/SVG, the XSLT lexer `application/xslt+xml` resolves to)
		// is not ported and stays uncoloured, which docs/COLORIZE.md records.
		if cfg.explicit_json {
			lexed = lex_json(body, cfg.allocator)
		} else {
			colored = false
		}
	}
	if !colored {
		strings.write_string(out, body)
		return
	}
	defer lexed_destroy(&lexed, cfg.allocator)
	render_tokens(strings.to_writer(out), lexed.tokens[:], cfg.style.body)
}

// ---------------------------------------------------------------------------
// Message rendering
// ---------------------------------------------------------------------------

// write_request writes one request message: the `H` and `B` parts of --print.
write_request :: proc(
	w: io.Writer,
	req: ^http.Request,
	parts: Parts,
	defaults: Request_Head_Defaults,
	cfg: ^Write_Config,
) -> io.Error {
	if !parts_any(parts) {
		return .None
	}
	// The message's own charset (models.py:48-59), from the request's
	// `Content-Type` header — the header the CLI's body and the user's own item
	// both end up in, and the one header the printed head drops when the request
	// has no body (the charset lookup still sees it, which is why a body-less
	// `-p H` with a bad charset still ends in the LookupError). A request has no
	// `--response-charset`-style override (output/writer.py:184-192 passes
	// `encoding_overwrite` for a response only).
	declared, _ := charset_parameter(content_type_value(req.headers))
	decode_charset := printed_decode_charset(declared, "")
	output_charset := printed_output_charset(declared, cfg)
	if parts.head {
		target, target_err := http.request_target(req, cfg.allocator)
		if target_err != .None {
			return .None
		}
		defer delete(target, cfg.allocator)
		head := build_request_head(req, target, defaults, cfg.allocator)
		defer delete(head, cfg.allocator)
		// The charset is resolved before the head's own encoder runs: the
		// reference's `format_headers(...).encode(output_encoding)` looks the
		// codec up first (`encoding.py:50`), so an unresolvable name is reported
		// for a head that also carries an unencodable character.
		codec, resolved := resolve_printed_pretty_codec(output_charset, cfg)
		if !resolved {
			return .None
		}
		err, failure := write_head(w, head, cfg, codec)
		if failure.failed {
			// The reference raises while it encodes the head, i.e. before any
			// of it is written: the session prints the exception and stops. A
			// failure the request already carries is the first one — the
			// reference raised there and never reached the rendering.
			if !req.encode_error.failed {
				req.encode_error = failure
			}
			return .None
		}
		if err != .None {
			return err
		}
	}
	if parts.body && len(req.body) > 0 {
		if err := write_body(
			w,
			string(req.body),
			content_type_media(req.body_content_type),
			decode_charset,
			output_charset,
			cfg,
		); err != .None {
			return err
		}
	}
	// A terminal gets a blank line after the body (output/writer.py:146-150) —
	// for the *request* too: the reference writes it from
	// build_output_stream_for_message (:137-150), the one function both messages
	// go through, so `--offline -p B` on a tty ends on `\n\n` and not on the
	// body alone. The condition is the message's own: a body part was asked for,
	// no metadata part, and the output is the terminal — and no exception came
	// out of the stream, because the reference yields this separator only after
	// the stream was iterated to its end.
	if cfg.stdout_is_tty && parts.body && !parts.meta && cfg.charset_error == "" {
		if _, err := io.write_string(w, MESSAGE_SEPARATOR); err != .None {
			return err
		}
	}
	return .None
}

// write_response writes one response message: the `h`, `b` and `m` parts.
write_response :: proc(
	w: io.Writer,
	res: ^http.Response,
	parts: Parts,
	elapsed_s: f64,
	cfg: ^Write_Config,
) -> io.Error {
	if !parts_any(parts) {
		return .None
	}
	// `message.encoding` (the `Content-Type` charset) and its two overrides
	// (output/writer.py:184-192): `--response-charset` replaces the *decode*
	// name, `--response-mime` the mime the formatter and lexer are chosen by —
	// it is not part of the charset, which stays the header's
	// (`content_type_value`).
	declared, _ := charset_parameter(content_type_value(res.headers))
	decode_charset := printed_decode_charset(declared, cfg.response_charset)
	output_charset := printed_output_charset(declared, cfg)
	if parts.head {
		head := build_response_head(res, cfg.allocator)
		defer delete(head, cfg.allocator)
		// The transport hands the reference a *str* per header value (urllib3
		// decodes the wire bytes as latin-1), and that is the text the stream
		// formats and encodes — so the wire bytes are read as characters first,
		// which is what makes `X-Latin: caf\xe9` the one character U+00E9 and
		// not a byte to copy (docs/PARITY.md section 3.4).
		text, text_owned := http.charset_latin1_text(head, cfg.allocator)
		defer if text_owned {
			delete(text, cfg.allocator)
		}
		codec, resolved := resolve_printed_pretty_codec(output_charset, cfg)
		if !resolved {
			return .None
		}
		err, failure := write_head(w, text, cfg, codec)
		if failure.failed {
			record_charset_failure(cfg, &failure)
			return .None
		}
		if err != .None {
			return err
		}
	}
	if parts.body {
		mime := mime_of_response(res, cfg)
		if err := write_body(w, string(res.body), mime, decode_charset, output_charset, cfg); err != .None {
			return err
		}
	}
	if parts.meta {
		if parts.body {
			if _, err := io.write_string(w, "\n\n"); err != .None {
				return err
			}
		}
		codec, resolved := resolve_printed_pretty_codec(output_charset, cfg)
		if !resolved {
			return .None
		}
		metadata := format_metadata(elapsed_s, cfg.allocator)
		defer delete(metadata, cfg.allocator)
		rendered := metadata
		if cfg.pretty_colors {
			builder := strings.builder_make(cfg.allocator)
			defer strings.builder_destroy(&builder)
			lexed := lex_metadata(metadata, cfg.variant == .Simplified_Precise, cfg.allocator)
			render_tokens(strings.to_writer(&builder), lexed.tokens[:], cfg.style.header)
			lexed_destroy(&lexed, cfg.allocator)
			rendered = strip_whitespace(strings.to_string(builder))
		} else {
			rendered = strip_whitespace(metadata)
		}
		// The metadata block goes through `get_metadata`
		// (`formatting.format_metadata(...).encode(self.output_encoding)`,
		// output/streams.py:196-197), so it takes the same codec as the head —
		// which shows on the one block whose text the port builds itself: it is
		// ASCII, so no codec can refuse it, and `utf-8-sig` puts its BOM on it.
		text, text_owned, failure := http.charset_encode_strict(codec, rendered, cfg.allocator)
		defer if text_owned {
			delete(text, cfg.allocator)
		}
		if failure.failed {
			record_charset_failure(cfg, &failure)
			return .None
		}
		if _, err := io.write_string(w, text); err != .None {
			return err
		}
		if _, err := io.write_string(w, "\n\n"); err != .None {
			return err
		}
	}
	// A terminal gets a blank line after the body (output/writer.py:146-150) —
	// only when the stream reached its end: the separator is what the reference
	// yields *after* iterating the stream, so an exception out of it (a charset
	// the registry has no text codec for) takes the blank line with it.
	if cfg.stdout_is_tty && parts.body && !parts.meta && cfg.charset_error == "" {
		if _, err := io.write_string(w, MESSAGE_SEPARATOR); err != .None {
			return err
		}
	}
	return .None
}

// write_head renders a head block: the optional sort, the optional colouring,
// the *encoder* and the CRLF CRLF that always follows
// (output/streams.py:65-67). `head` is the str layer's text — a request head is
// the port's str representation, a response head has been read as one
// (`charset_latin1_text`) — and `codec` is the codec the stream writes it with
// (`resolve_printed_pretty_codec`): the whole block is one string encoded after
// the formatting (`self.formatting.format_headers(self.msg.headers).encode(
// self.output_encoding)`, :191-197), strict, so a character the codec has no byte
// for is the reference's `UnicodeEncodeError` and nothing of the block is
// written. The caller stores the failure in its own place (`req.encode_error` for
// a request, `cfg.charset_error` for a response, which are the two the session
// prints).
@(private)
write_head :: proc(
	w: io.Writer,
	head: string,
	cfg: ^Write_Config,
	codec: ^http.Charset_Entry,
) -> (io.Error, http.Str_Encode_Error) {
	text := head
	owned := "" // set when `text` is ours and must be released
	defer if owned != "" {
		delete(owned, cfg.allocator)
	}
	if cfg.pretty_format && cfg.headers_sort {
		text = format_headers_sort(head, cfg.allocator)
		owned = text
	}
	if cfg.pretty_colors {
		builder := strings.builder_make(cfg.allocator)
		lexed := lex_headers(text, cfg.variant, cfg.allocator)
		render_tokens(strings.to_writer(&builder), lexed.tokens[:], cfg.style.header)
		// ColorsFormatter.format_headers strips the highlighted result
		// (output/formatters/colors.py:87-93), and the coloured text replaces
		// the sorted one — as a copy that outlives the builder.
		colored := strings.clone(strip_whitespace(strings.to_string(builder)), cfg.allocator) or_else ""
		strings.builder_destroy(&builder)
		lexed_destroy(&lexed, cfg.allocator)
		if owned != "" {
			delete(owned, cfg.allocator)
		}
		text = colored
		owned = colored
	}
	encoded, encoded_owned, failure := http.charset_encode_strict(codec, text, cfg.allocator)
	defer if encoded_owned {
		delete(encoded, cfg.allocator)
	}
	if failure.failed {
		return .None, failure
	}
	if _, err := io.write_string(w, encoded); err != .None {
		return err, {}
	}
	return write_str(w, "\r\n\r\n"), {}
}

// record_charset_failure stores the UnicodeEncodeError a printed block raised
// where the *response* path reports its charset exceptions (`cfg.charset_error`,
// the same place `resolve_printed_charset` puts the `LookupError`); the session
// prints it and stops (charset_failure). The first one wins: the reference raises
// once, from the frame the stream was being iterated in.
@(private)
record_charset_failure :: proc(cfg: ^Write_Config, failure: ^http.Str_Encode_Error) {
	if cfg.charset_error == "" {
		cfg.charset_error = http.str_encode_error_message(failure, cfg.allocator)
	}
}

// write_body renders a body: the wire bytes when nothing is prettified, the
// formatted and/or coloured text otherwise (output/streams.py:105-254).
// `decode_charset` is the name `smart_decode` decodes with and `output_charset`
// the one `smart_encode` writes with (printed_decode_charset /
// printed_output_charset); both are "" for "utf-8", and both are resolved — and,
// if the registry has no text codec under them, refused — here.
@(private)
write_body :: proc(
	w: io.Writer,
	body: string,
	mime: string,
	decode_charset: string,
	output_charset: string,
	cfg: ^Write_Config,
) -> io.Error {
	if len(body) == 0 {
		// A buffered pretty stream processes a body even when the message has
		// none — its generator yields one outside the read loop
		// (streams.py:238-247) — so a name the *encoder* cannot resolve ends the
		// run there too. The *decoder* is not asked: CPython skips the codec
		// lookup for empty bytes (`b''.decode('bogus', 'replace')` is `''` —
		// build/probe_t_aff4fc91_emptycodec.py), where the encoder's lookup always
		// happens (`''.encode('utf-8-sig')` is the BOM itself). The line-oriented
		// streams — `EncodedStream` on a terminal, `PrettyStream` for an event
		// stream, `RawStream` — see no line and resolve nothing.
		if !buffered_pretty_body(cfg, mime) {
			return .None
		}
		return write_printed_body(w, "", output_charset, cfg)
	}
	if is_binary(body) {
		// Binary data is suppressed on any path that would decode it, and
		// silently streamed when the body is passed through verbatim. Whether
		// to suppress is decided on the raw bytes, *before* any decode
		// (output/streams.py:236-247), which is why a body holding a NUL is
		// suppressed even when its charset would not resolve.
		if printed_body_stream(cfg) {
			return write_str(w, BINARY_SUPPRESSED_NOTICE)
		}
		return write_bytes(w, transmute([]u8)body)
	}

	text := body
	// `defer` runs at the end of its enclosing *block*, so the release lives at
	// proc scope: a defer inside the `if` below would free the string before the
	// write.
	owned := false
	defer if owned {
		delete(text, cfg.allocator)
	}
	// The stream's *decoder* runs before any formatting, which is the whole
	// point of the order: `smart_decode` (output/streams.py:146) is what turns
	// the wire bytes into the text a formatter or a lexer then reads, so an
	// ill-formed byte is U+FFFD by the time either sees it and the encoder at
	// the far end can no longer be confused with it (decode_printed_part). The
	// stream that decodes nothing — `RawStream`, no `--pretty` group and no
	// terminal — keeps its bytes (streams.py:172-180).
	if printed_body_stream(cfg) {
		if !resolve_printed_charset(decode_charset, false, cfg) {
			return .None
		}
		text, owned = decode_printed_part(text, decode_charset, cfg.allocator)
	}
	if cfg.pretty_format {
		// `format_body` reports whether it allocated a replacement; without
		// that flag a formatted body that happens to render to the same bytes
		// as the wire body would leak its allocation.
		if formatted, allocated := format_body(text, mime, cfg); allocated {
			if owned {
				delete(text, cfg.allocator)
			}
			text = formatted
			owned = true
		}
	}
	if cfg.pretty_colors {
		builder := strings.builder_make(cfg.allocator)
		defer strings.builder_destroy(&builder)
		colorize_body(text, mime, cfg, &builder)
		return write_printed_body(w, strings.to_string(builder), output_charset, cfg)
	}
	if !cfg.pretty_format && cfg.stdout_is_tty && !strings.has_suffix(text, "\n") {
		// EncodedStream walks the body by line and always writes an LF
		// (output/streams.py:138-143).
		if err := write_printed_body(w, text, output_charset, cfg); err != .None {
			return err
		}
		return write_str(w, "\n")
	}
	return write_printed_body(w, text, output_charset, cfg)
}

// buffered_pretty_body is the stream a prettify group puts a message in when its
// content is not streamed: `BufferedPrettyStream` reads the whole body before
// printing it, where an event stream's body arrives a line at a time and gets
// `PrettyStream` instead (writer.py:182-192).
@(private)
buffered_pretty_body :: proc(cfg: ^Write_Config, mime: string) -> bool {
	return (cfg.pretty_format || cfg.pretty_colors) && !stream_mime(mime)
}

// stream_mime is the reference's auto-stream check (writer.py:163-171): a
// *response* whose `Content-Type` is `text/event-stream` is printed line by line
// by `PrettyStream`, which is why an empty body never reaches its formatter or
// its encoder. `--stream` forces that stream for any content, and the mime here
// is the effective one (`--response-mime` included); the port does not model
// either, which is part of the streamed-body gap docs/PARITY.md section 3.4
// records.
@(private)
stream_mime :: proc(mime: string) -> bool {
	return strings.equal_fold(mime, "text/event-stream")
}

// write_printed_body writes the text one printed body part ended up with,
// through the encoder of the stream that carries it: a body that no processing
// touches is streamed verbatim (RawStream — no terminal, no `--pretty` group);
// every other stream re-encodes what it writes, because the reference's
// EncodedStream and PrettyStream/BufferedPrettyStream hand every body part to
// `smart_encode` (output/streams.py:143 and :225; the head and the metadata are
// the strict `.encode()` of :53/:192/:196, which is §3.6's rule and not this
// one).
@(private)
write_printed_body :: proc(w: io.Writer, text: string, charset: string, cfg: ^Write_Config) -> io.Error {
	if !printed_body_stream(cfg) {
		return write_str(w, text)
	}
	if !resolve_printed_charset(charset, true, cfg) {
		return .None
	}
	encoded, owned := encode_printed_part(text, charset, cfg.allocator)
	defer if owned {
		delete(encoded, cfg.allocator)
	}
	return write_str(w, encoded)
}

// printed_body_stream is which stream carries a printed body, in the terms both
// of its ends are asked for: `get_stream_type_and_kwargs` builds `RawStream` for
// exactly `not env.stdout_isatty and not prettify_groups` and an
// EncodedStream/PrettyStream/BufferedPrettyStream otherwise
// (output/writer.py:172-192). The streams differ in *two* places — RawStream
// decodes nothing and encodes nothing, every other stream does both — so the
// question is asked once, here, and both ends read their answer from it.
@(private)
printed_body_stream :: proc(cfg: ^Write_Config) -> bool {
	return cfg.pretty_format || cfg.pretty_colors || cfg.stdout_is_tty
}

// encode_printed_part is `smart_encode(content, output_encoding)`
// (httpie/encoding.py:44-50): the printed part is encoded with the output
// encoding, and a character that encoding cannot represent is replaced — by
// `?` (0x3f), the *encoder's* replacement, not the U+FFFD a decoder's
// `errors='replace'` writes. `smart_decode` (:34-42) is the other end of the
// same pipeline and runs *first*: it decodes the body's *bytes* before any
// formatter sees them (decode_printed_part, called from write_body), so the
// only ill-formed byte left here is one the JSON parser itself put in the text
// (a `:=` escape's in-band U+DC80-U+DCFF), and the two sources stay
// distinguishable — which is what t_afcdf46c's `?` needs to be unambiguous.
//
// `output_encoding` is `printed_output_charset`: the terminal's encoding on a
// terminal (utf-8 here), the *message's* charset otherwise, utf-8 when it has
// none. A pipe with `Content-Type: text/plain; charset=iso-8859-1` therefore
// prints the latin-1 bytes the wire carried — decoded and re-encoded, so a byte
// the charset has no character for comes out as `?` — and a *terminal* prints the
// utf-8 of what was decoded instead (docs/PARITY.md section 3.4). The port holds
// a Python str as the bytes CPython's surrogateescape decode made of it, so "a
// character the codec cannot encode" is one thing here: for the utf-8 rule, a
// byte that does not start a well-formed UTF-8 sequence — exactly what
// `str_utf8_seq_len` answers, CPython's own notion of well-formed (an overlong
// form, an encoded surrogate and anything above U+10FFFF are ill-formed to it) —
// and, for a single-byte codec, every character whose code point its table has no
// byte for. One such byte is one lone surrogate character to the reference (the
// argv byte 0xff is the str `'\udcff'`), so it becomes one `?`; a well-formed
// sequence is copied through byte for byte, so `é` or `€` in a printed body are
// untouched whatever their width.
//
// The result is `text` itself when nothing had to be replaced, which is the
// common case; when it is not, the caller owns the result and releases it with
// `allocator`.
@(private)
encode_printed_part :: proc(text: string, charset: string, allocator: mem.Allocator) -> (encoded: string, owned: bool) {
	if charset != "" {
		if entry, class := http.charset_entry(charset); class == .Text {
			return http.charset_encode(entry, text, allocator)
		}
	}
	return http.charset_encode_utf8(text, allocator)
}

// decode_printed_part is `smart_decode(content, encoding)` (httpie/encoding.py:
// 34-42, called from output/streams.py:146) for the port's bytes: the body part
// the stream is about to format is *decoded* first, and what the decoder refuses
// becomes U+FFFD (EF BF BD) — the **decoder's** replacement, where
// encode_printed_part's encoder writes `?`. The order is the rule: after this
// step an ill-formed byte can no longer come from the wire, so the `?` the
// encoder writes one layer out belongs to the JSON parser's own lone surrogate
// and to nothing else.
//
// Which *codec* decodes is `smart_decode`'s `encoding` argument:
//
//   - no name (the message declares no charset, or declares an empty one) is
//     `detect_encoding`, which is utf-8 below `charset_normalizer`'s
//     `TOO_SMALL_SEQUENCE` (32 bytes) and a `charset_normalizer` guess above it
//     (`http.detect_encoding`, a port of the library's whole detection
//     pipeline): a 33-byte body ending `0xff` decodes with `cp1125`, a body of
//     `b'a' * 40 + b'\x81'` with `cp037`, and a body of Cyrillic cp1251 bytes
//     with the code page whose reading of it looks most like a language.  What
//     the guess cannot reach it does not fake: a *multibyte* code page the port
//     has no decoder for keeps the pre-existing gap docs/PARITY.md section 3.4
//     records, and the utf-8 walk is what is left for it;
//   - a *declared* name is that codec — `Content-Type`'s `charset` parameter
//     (models.py:44-50) or `--response-charset`, which overrides it for a
//     response (output/writer.py:184-192). http/charset.odin implements the utf-8
//     family and every single-byte codec of CPython's registry; a name that does
//     not resolve is the reference's `LookupError` and `resolve_printed_charset`
//     has already recorded it; a name whose codec the port has no decoder for
//     falls back to the utf-8 walk (the same recorded gap).
//
// The One U+FFFD per ill-formed **maximal subpart** rule is the utf-8 codec's own
// (CPython's unit: `E0 A0 05` is one, a sequence the input cuts short is one, an
// encoded surrogate is three, a byte that cannot open a sequence at all is one
// each — `http.str_utf8_decode_failure` is exactly that span, checked against
// CPython in build/probe_printed_body_decode.py). A single-byte codec's unit is
// one byte, so its undefined entries are one U+FFFD each.
//
// The result is `text` itself when nothing had to be replaced, which is the
// common case; when it is not, the caller owns the result and releases it with
// `allocator`.
@(private)
decode_printed_part :: proc(text: string, charset: string, allocator: mem.Allocator) -> (decoded: string, owned: bool) {
	if charset != "" {
		return decode_printed_with_codec(text, charset, allocator)
	}
	// `detect_encoding(content)` (encoding.py:16-31), then that codec decodes.
	return decode_printed_with_codec(text, http.detect_encoding(text, allocator), allocator)
}

// decode_printed_with_codec decodes a printed part with a resolved name: the
// codec's own decoder, and the utf-8 walk where the registry has none (a guessed
// name always resolves — it comes from the detection tables, which are CPython
// codec names — so this is the declared-name case and the recorded
// multibyte-decoder gap).
@(private)
decode_printed_with_codec :: proc(text: string, charset: string, allocator: mem.Allocator) -> (decoded: string, owned: bool) {
	if entry, class := http.charset_entry(charset); class == .Text {
		return http.charset_decode(entry, text, allocator)
	}
	return http.charset_decode_utf8(text, allocator)
}

// ---------------------------------------------------------------------------
// The printed charset
// ---------------------------------------------------------------------------

@(private)
is_binary :: proc(body: string) -> bool {
	return strings.contains(body, "\x00")
}

// charset_parameter is `parse_content_type_header`'s `params.get('charset', '')`
// (utils.py:203-218), which is where `message.encoding` comes from
// (models.py:44-50): everything after the first ';' is one parameter per ';',
// each split at its first '=', with the key lower-cased and both sides stripped
// of `"`, `'` and spaces; a later duplicate replaces an earlier one. An empty
// value is falsy in Python, which is why `charset=` means "no charset" and not
// "the empty encoding" — the reference falls back to `detect_encoding` there.
//
// The result is a slice of `value` when the parameter carries one.
@(private)
charset_parameter :: proc(value: string) -> (charset: string, spelled: bool) {
	semi := strings.index(value, ";")
	if semi < 0 {
		return "", false
	}
	rest := value[semi + 1:]
	for len(rest) > 0 {
		param := rest
		if next := strings.index(rest, ";"); next >= 0 {
			param, rest = rest[:next], rest[next + 1:]
		} else {
			rest = ""
		}
		param = strings.trim_space(param)
		if param == "" {
			continue
		}
		key := param
		has_value := false
		value_part := ""
		if equals := strings.index(param, "="); equals >= 0 {
			key, has_value = param[:equals], true
			value_part = param[equals + 1:]
		}
		key = strings.trim(strings.to_lower(strings.trim_space(key), context.temp_allocator), PARAM_STRIP)
		if key != "charset" {
			continue
		}
		if !has_value {
			// `charset` with no '=' is the Python boolean True, which no codec
			// lookup accepts: the reference ends with a TypeError, not a
			// LookupError, and the port keeps the record of that shape with the
			// other unresolvable-name cases (docs/PARITY.md section 3.4).
			return "", false
		}
		charset = strings.trim(strings.trim_space(value_part), PARAM_STRIP)
		spelled = charset != ""
	}
	return charset, spelled
}

// PARAM_STRIP is `items_to_strip` (utils.py:208): the characters stripped from
// both sides of a parameter's key and value.
@(private)
PARAM_STRIP :: "\"' "

// content_type_value is the message's own `Content-Type` header value, which is
// what `message.encoding` is parsed from (models.py:48-59: `self._orig.headers
// .get('Content-Type', '')`) — *not* the mime `--response-mime` may have
// replaced (that one decides the formatter only, output/writer.py:184-192). A
// request's charset lives here too, and it is the one header that is *not* in
// the head the run prints when the message has no body: the head formatter drops
// it, the charset lookup still sees it, so `--offline -p H ... 'Content-Type:
// text/plain; charset=bogus'` ends in a LookupError with no head on stdout
// (build/probe_t_aff4fc91_empty.py).
@(private)
content_type_value :: proc(headers: []http.Header) -> string {
	for header in headers {
		if strings.equal_fold(header.name, "Content-Type") {
			return header.value
		}
	}
	return ""
}

// printed_decode_charset is the name `smart_decode` decodes a printed body part
// with (encoding.py:34-42, called from output/streams.py:146): the *message's*
// charset — `Content-Type`'s `charset` parameter, `--response-charset` for a
// response — and with none the empty name, which is `detect_encoding`'s guess
// (`decode_printed_part` asks for it there, because the guess is the payload's
// and this function only sees the header).
@(private)
printed_decode_charset :: proc(declared, override: string) -> string {
	if override != "" {
		return override
	}
	return declared
}

// printed_output_charset is `output_encoding` (output/streams.py:120-131): the
// terminal's encoding when stdout is a terminal, the *message's* charset
// otherwise, and utf-8 when there is none. `--response-charset` is not part of it
// — it overrides the *decode* and nothing else, which is why a pipe prints the
// utf-8 of what `--response-charset=latin1` decoded rather than latin-1's own
// bytes. The port's terminal is utf-8, which is what the harness's terminal is.
@(private)
printed_output_charset :: proc(declared: string, cfg: ^Write_Config) -> string {
	if cfg.stdout_is_tty {
		return ""
	}
	return declared
}

// resolve_printed_charset resolves a charset name the way the reference does
// where it first *uses* it, and records the exception when the registry has no
// text codec under it: `charset_error` is then set and the part the name belonged
// to is not written at all. It answers whether rendering may go on.
//
// `.Raising` is the one class this does not reproduce — a name whose codec
// raises rather than refusing to resolve (`undefined`) ends the reference with a
// `UnicodeError`, and the port falls back to the utf-8 rule for it, which is part
// of the recorded gap in docs/PARITY.md section 3.4. A name the registry resolves
// to a codec with no port decoder (`.Other`) is *not* an error here either: the
// decode/encode falls back to the utf-8 rule, the same recorded gap.
@(private)
resolve_printed_charset :: proc(name: string, encoding: bool, cfg: ^Write_Config) -> bool {
	if name == "" {
		return true // no name: UTF8, the reference's own default
	}
	class := http.charset_class(name)
	switch class {
	case .Text, .Raising:
		return true
	case .Non_Text, .Unknown:
	}
	if cfg.charset_error == "" {
		cfg.charset_error = http.charset_error_message(class, name, encoding, cfg.allocator)
	}
	return false
}

// resolve_printed_pretty_codec is the same lookup where the *head* and the
// *metadata* need it — both their name and the codec to encode with: those two go
// through `PrettyStream.get_headers` / `get_metadata`
// (`formatting.format_headers(...).encode(self.output_encoding)`,
// output/streams.py:191-197), so the charset is used for them only when a
// prettify group put the message in a `PrettyStream` — `EncodedStream` and
// `RawStream` take `BaseStream`'s plain `.encode()` (`:50-57`, utf-8), which is
// the nil entry `charset_encode_strict` reads as the utf-8 rule. That is also why
// a terminal never fails here: its output encoding is the terminal's.
//
// The name is resolved but not encoded yet: the reference looks the codec up
// before it encodes anything (`encoding.py:50`), so an unresolvable name is the
// run's exception even for a block that would also be unencodable. `ok` false
// means the LookupError was recorded and nothing of the part may be written.
@(private)
resolve_printed_pretty_codec :: proc(
	output_charset: string,
	cfg: ^Write_Config,
) -> (^http.Charset_Entry, bool) {
	if !cfg.pretty_format && !cfg.pretty_colors {
		return nil, true
	}
	if !resolve_printed_charset(output_charset, true, cfg) {
		return nil, false
	}
	return http.charset_strict_codec(output_charset), true
}

@(private)
mime_of_response :: proc(res: ^http.Response, cfg: ^Write_Config) -> string {
	if cfg.response_mime != "" {
		return cfg.response_mime
	}
	for header in res.headers {
		if strings.equal_fold(header.name, "Content-Type") {
			return content_type_media(header.value)
		}
	}
	return ""
}

// content_type_media is parse_content_type_header's first return value
// (utils.py:203-218): everything before the first ';', stripped.
@(private)
content_type_media :: proc(value: string) -> string {
	media := value
	if semi := strings.index(media, ";"); semi >= 0 {
		media = media[:semi]
	}
	return strings.trim_space(media)
}

// format_metadata is HTTPResponse.metadata (models.py:89-102): the elapsed time,
// printed the way `str(round(t, 10))` prints it. The value is normalised by the
// parity harness (docs/PARITY.md section 7.4), so only the shape matters.
format_metadata :: proc(elapsed_s: f64, allocator: mem.Allocator) -> string {
	rounded := fmt.aprintf("%.10f", elapsed_s, allocator = allocator)
	defer delete(rounded, allocator)

	end := len(rounded)
	for end > 0 && rounded[end - 1] == '0' {
		end -= 1
	}
	if end > 0 && rounded[end - 1] == '.' {
		end += 1 // Python always prints at least one decimal digit.
	}
	return fmt.aprintf("Elapsed time: %ss", rounded[:end], allocator = allocator)
}

// strip_whitespace is Python's str.strip() for the bytes a rendered block can
// carry. The result is a slice of `value`.
strip_whitespace :: proc(value: string) -> string {
	start := 0
	for start < len(value) && is_py_space(value[start]) {
		start += 1
	}
	end := len(value)
	for end > start && is_py_space(value[end - 1]) {
		end -= 1
	}
	return value[start:end]
}


// ---------------------------------------------------------------------------
// Errors and warnings
// ---------------------------------------------------------------------------

// Console is one of httpie's own `rich` consoles: the stream it prints to, the
// width it was sized to — the run's `$COLUMNS` when that holds digits, and
// rich's 80 for everything else (`cli.console_width`) — and the value rich
// refuses to read at all (`crash`, `cli.console_crash`).
//
// The width is load-bearing even where nothing is wrapped. rich's
// `Console.render` returns an empty segment list for any `max_width` below one
// cell, "No space to render anything" (rich/console.py:1312-1314), so a console
// sized to 0 cells prints *nothing at all*: every message that goes through it
// is dropped, and what still reaches the stream is only what httpie writes
// around it (the newline its SystemExit handler writes). `$COLUMNS=0` is such a
// console — rich takes the value literally (`Console.size` returns the `_width`
// the digits of `$COLUMNS` set; rich/console.py:685-694, :1005-1050) — and the
// port models it as the width `cli.console_silent` rejects, so the whole family
// of `http: error:`/`warning:` lines can vanish at once
// (docs/PARITY.md §4.2; t_e0f7b7b3).
//
// Building one allocates nothing: it is the writer, the width and the refused
// value the caller already has. Widths are counted in bytes, which is what rich
// counts in cells for the ASCII messages that go through here.
Console :: struct {
	writer: io.Writer,
	width:  int,
	// crash is the `$COLUMNS` value rich's `int(columns)` refuses: the console
	// the reference dies building, before a byte of any message is rendered
	// (`cli.console_crash`, rich/console.py:685-694; docs/PARITY.md §3.1,
	// t_14a26d57). "" for every console rich can build, the zero-width ones
	// included. The value is borrowed from the run's environment, which
	// outlives the console.
	crash:  string,
}

// console_fatal reports whether `console` is the one rich cannot build: its
// `crash` is set, so the reference never reaches the message and dies inside
// `Console.__init__` — the writers print the exception's own line instead
// (`write_log_crash`, docs/PARITY.md §8.20).
console_fatal :: proc(console: Console) -> bool {
	return console.crash != ""
}

// console_silent reports whether `console` renders anything at all: anything
// narrower than one cell does not (rich/console.py:1312-1314, `cli.console_silent`).
// A console rich cannot build is not this shape — it never exists to render —
// so `console_fatal` is its own question.
console_silent :: proc(console: Console) -> bool {
	return console.width < 1
}

// write_log_crash writes the line that stands in for the reference's traceback
// when this console is the one rich cannot build. The reference dies inside
// `Console.__init__` — `int(columns)` raises `ValueError: invalid literal for
// int() with base 10: '…'` — so the message that was going to be printed is
// never rendered, and the port prints that exception's own wording in the
// `http: error:` shape every failure of this family takes; the frames around it
// name the reference interpreter's own paths and are not reproduced
// (docs/PARITY.md §8.20, §3.1; t_14a26d57).
//
// The line is written the way `write_log_line` writes a message, with one
// difference: the *value* is the refused `$COLUMNS` itself and not a
// transformed message. Python's `int()` quotes it with `repr()`, which for a
// value that passed `str.isdigit()` is the value between two `'` — every
// character of it is a printable digit, so nothing is escaped — and rich's
// emoji pass has nothing to do here either, because a digit run holds no
// `:code:`. Nothing allocates.
write_log_crash :: proc(console: Console, program_name: string) -> io.Error {
	w := console.writer
	if err := write_str(w, "\n"); err != .None {
		return err
	}
	if err := write_str(w, program_name); err != .None {
		return err
	}
	if err := write_str(w, ": error: "); err != .None {
		return err
	}
	if err := write_str(w, "ValueError: invalid literal for int() with base 10: '"); err != .None {
		return err
	}
	if err := write_str(w, console.crash); err != .None {
		return err
	}
	return write_str(w, "'\n\n\n")
}

// write_log_error reproduces httpie's runtime error convention
// (httpie/context.py:170-182, docs/PARITY.md section 5): a leading blank line,
// the program name, `error:`, the message, and three newlines.
//
// The message goes through rich's emoji pass on the way out, and *only* that
// pass: httpie prints this line through its own console with `markup=False`
// (context.py:176-182), so a `:code:` is expanded while a `[…]` stays text —
// which is the difference between this printer and the usage-error block of
// src/cli/usage.odin, where both passes run. `env.log_error` is also what
// prints `InvalidURL: …` for a malformed authority, which is the measurement
// docs/PARITY.md §3.6 records (`build/probe_authority_shortcode.py`).
//
// The console's width matters only at zero: the reference prints this line with
// `soft_wrap=True`, so it is never wrapped — but a zero-width console drops it
// whole, the leading and trailing newlines included (`console_silent`).
write_log_error :: proc(console: Console, program_name: string, message: string) -> io.Error {
	if err := write_log_line(console, program_name, "error", message); err != .None {
		return err
	}
	return .None
}

// write_log_warning is the same shape with `warning:` (the same console: the
// level decides the word and the colour, not the printing).
write_log_warning :: proc(console: Console, program_name: string, message: string) -> io.Error {
	if err := write_log_line(console, program_name, "warning", message); err != .None {
		return err
	}
	return .None
}

// write_log_line is the shape both levels share: the leading blank line, the
// program name, the level word, the message through rich's emoji pass, and
// three newlines. It writes with `write_str` (the renderer's own writer
// helper) so the message is transformed without an intermediate string — the
// renderer writes into the caller's `io.Writer` and allocates nothing
// (docs/ARCHITECTURE.md §2).
//
// A zero-width console prints none of it: rich never renders the renderable, so
// not one of those newlines is written either.
//
// A console rich cannot build prints none of *this* either, and prints the
// exception's own line instead (`write_log_crash`): the reference dies while
// the console is being built, so the caller's message is never rendered — and
// the line that does come out is the same one for `write_log_error` and
// `write_log_warning`, because what killed the run is neither an error nor a
// warning httpie chose (`$COLUMNS=²`, docs/PARITY.md §3.1, §8.20).
@(private)
write_log_line :: proc(
	console: Console,
	program_name: string,
	level: string,
	message: string,
) -> io.Error {
	if console_fatal(console) {
		return write_log_crash(console, program_name)
	}
	if console_silent(console) {
		return .None
	}
	w := console.writer
	if err := write_str(w, "\n"); err != .None {
		return err
	}
	if err := write_str(w, program_name); err != .None {
		return err
	}
	if err := write_str(w, ": "); err != .None {
		return err
	}
	if err := write_str(w, level); err != .None {
		return err
	}
	if err := write_str(w, ": "); err != .None {
		return err
	}
	if err := rich.emoji_write(w, message); err != .None {
		return err
	}
	return write_str(w, "\n\n\n")
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------


// write_str writes a string and drops the byte count (core:io returns one).
@(private)
write_str :: proc(w: io.Writer, s: string) -> io.Error {
	_, err := io.write_string(w, s)
	return err
}

// write_raw_bytes writes bytes that are not a message: the download body and
// the progress lines httpie sends to stderr. (colorize.odin's write_raw is the
// string-shaped one the lexers use.)
write_raw_bytes :: proc(w: io.Writer, p: []byte) -> io.Error {
	if len(p) == 0 {
		return .None
	}
	_, err := io.write(w, p)
	return err
}

// write_console_line writes one of httpie's own messages the way rich prints it
// (`Console.print`): wrapped to the console's width, terminated by a newline.
//
// httpie's progress messages go through a rich Console, which wraps at the
// terminal width (rich/console.py `Console.size`, $COLUMNS), so a `--download`
// target long enough puts `Downloading to ` and the path on separate lines. The
// rules are divide_line's (rich/_wrap.py:26-78):
//
//   - a "word" is a run of non-space characters plus the whitespace after it;
//   - a word that fits in the space left on the line is appended — its trailing
//     whitespace counts towards the line, so `Downloading to ` keeps its space;
//   - a word that does not fit but is no longer than a whole line starts the
//     next line;
//   - a word longer than a whole line is folded into `width`-wide pieces.
//
// A zero-width console prints none of it, the terminating newline included
// (`console_silent`): the reference's progress display is a rich renderable and
// `Console.render` draws nothing below one cell of width, so a `$COLUMNS=0`
// `--download` prints neither `Downloading to …`, nor the blank line the bar
// leaves between them, nor the summary.
//
// Widths are counted in bytes, which is what rich counts in cells for the ASCII
// messages this writes; a wide (CJK) character would be one cell too narrow.
// Nothing here allocates: the text is written out slice by slice.
//
// A console rich cannot build never reaches this printer: the progress display
// the reference was about to start is not a renderable rich ever gets to draw,
// so nothing is written and the caller is the one that ends the run
// (`console_fatal`, session/context.odin's `download_response`).
write_console_line :: proc(console: Console, text: string) -> io.Error {
	if console_silent(console) || console_fatal(console) {
		return .None
	}
	w := console.writer
	line_width := console.width

	line_start := 0 // byte offset the current line starts at
	cell := 0       // cells the current line already holds
	index := 0
	for index < len(text) {
		word_start := index
		for index < len(text) && text[index] != ' ' && text[index] != '	' {
			index += 1
		}
		word_end := index // the word without its trailing whitespace
		for index < len(text) && (text[index] == ' ' || text[index] == '	') {
			index += 1
		}
		word_length := word_end - word_start
		chunk_length := index - word_start

		switch {
		case line_width - cell >= word_length:
			// It fits: the trailing whitespace stays on this line.
			cell += chunk_length
		case word_length > line_width:
			// Longer than a whole line: break before it, then fold it.
			if cell > 0 && word_start > line_start {
				if err := write_bytes(w, transmute([]u8)text[line_start:word_start]); err != .None {
					return err
				}
				if err := write_raw_bytes(w, []u8{'\n'}); err != .None {
					return err
				}
				line_start = word_start
			}
			at := word_start
			for word_end - at > line_width {
				at += line_width
				if err := write_bytes(w, transmute([]u8)text[line_start:at]); err != .None {
					return err
				}
				if err := write_raw_bytes(w, []u8{'\n'}); err != .None {
					return err
				}
				line_start = at
			}
			cell = index - line_start
		case cell > 0 && word_start > line_start:
			// It fits on a line of its own: start one.
			if err := write_bytes(w, transmute([]u8)text[line_start:word_start]); err != .None {
				return err
			}
			if err := write_raw_bytes(w, []u8{'\n'}); err != .None {
				return err
			}
			line_start = word_start
			cell = chunk_length
		}
	}

	if err := write_bytes(w, transmute([]u8)text[line_start:]); err != .None {
		return err
	}
	return write_raw_bytes(w, []u8{'\n'})
}

// write_bytes is write_str for raw bytes.
@(private)
write_bytes :: proc(w: io.Writer, p: []byte) -> io.Error {
	_, err := io.write(w, p)
	return err
}
