// The libcurl transport: the only code in the program that touches the
// network. `send` is the seam (backend.odin); everything here is behind it.
//
// Structure of one exchange:
//
//   * the request line, the headers and the body are handed to one easy handle;
//   * libcurl follows redirects itself (so scheme, TLS and auth behaviour on
//     each hop is the audited one), and the header callback re-assembles the
//     hop-by-hop view from the status lines it sees;
//   * the response body is buffered into the Response, or streamed into a
//     caller-supplied writer for downloads;
//   * every C string that crosses the boundary lives in a C_String_List that
//     outlives the transfer, and every allocation is released on both the
//     success and the error path.
//
// Two things are deliberately *not* modelled here because libcurl owns them on
// the wire: the `Host` header (derived from the target, unless the caller
// supplied one), and content *decoding* — the `Accept-Encoding` line itself is
// the caller's own header entry, which libcurl writes in its place and honours
// instead of adding one of its own.
package http

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:strconv"
import "core:strings"

// httpie's identity on the wire. The port claims the reference client's
// User-Agent and Accept-Encoding so a server sees the same request as the
// reference implementation (docs/PARITY.md, "Reference identity"); the
// renderer prints the same User-Agent.
USER_AGENT :: "HTTPie/3.2.4"
ACCEPT_ENCODING :: "gzip, deflate"

// ENV_SCRATCH_SIZE is the stack buffer the environment lookups write into
// (os.get_env_buf is limited to 512 UTF-16 values per name and value).
ENV_SCRATCH_SIZE :: 1024

// ---------------------------------------------------------------------------
// C strings and slists
// ---------------------------------------------------------------------------

// C_String_List owns the NUL-terminated copies of every string handed to
// libcurl. libcurl keeps the pointers for the duration of the transfer and
// never owns them, so they must outlive the call — and they must all be freed
// even when the transfer fails half-way.
C_String_List :: struct {
	allocator: mem.Allocator,
	entries:   [dynamic]cstring,
}

c_strings_make :: proc(allocator: mem.Allocator) -> C_String_List {
	return {allocator = allocator, entries = make([dynamic]cstring, allocator)}
}

c_strings_add :: proc(list: ^C_String_List, value: string) -> (entry: cstring, ok: bool) {
	clone, clone_err := strings.clone_to_cstring(value, list.allocator)
	if clone_err != .None {
		return nil, false
	}
	if _, append_err := append(&list.entries, clone); append_err != .None {
		delete(clone, list.allocator)
		return nil, false
	}
	return clone, true
}

c_strings_destroy :: proc(list: ^C_String_List) {
	for entry in list.entries {
		delete(entry, list.allocator)
	}
	delete(list.entries)
	list^ = {}
}

slist_destroy :: proc(list: ^CURL_slist) {
	if list != nil {
		curl_slist_free_all(list)
	}
}

// ---------------------------------------------------------------------------
// Hop parsing
// ---------------------------------------------------------------------------

// Exchange (types.odin) is one hop. exchange_destroy releases one and zeroes
// it, so a moved-out hop can still be destroyed.
exchange_destroy :: proc(hop: ^Exchange, allocator: mem.Allocator) {
	if hop == nil {
		return
	}
	for &header in hop.headers {
		delete(header.name, allocator)
		delete(header.value, allocator)
	}
	delete(hop.headers, allocator)
	delete(hop.url, allocator)
	delete(hop.reason, allocator)
	delete(hop.http_version, allocator)
	hop^ = {}
}

// Transfer is the state of one *hop*. It owns every buffer and every string the
// callbacks allocate; `transport_send` destroys it on every path.
Transfer :: struct {
	allocator: mem.Allocator,
	out:       ^Response,

	// body
	body:   Buffer,           // buffered reply (used when sink == nil)
	sink:   Maybe(io.Writer), // when set, the body streams here instead
	failed: Error,            // set by a callback: why the transfer was aborted

	// `sink` is honoured only for a hop that will not be followed: the body of
	// a redirect is discarded, exactly as requests discards it (a `-d --follow`
	// download must not collect the intermediate bodies).
	stream_this_hop: bool,
	follow:          bool,

	// head parsing
	line:      Buffer,    // partial header line
	hop:       Exchange,  // the hop being parsed
	history:   []Exchange,// hops already followed, oldest first
	hop_url:   string,    // URL requested for `hop` (owned)
	hop_method: Method,   // method used for `hop`
	have_hop:  bool,      // a status line has been seen

	// head_reply_only is apply_hop's verdict that this hop's *reply is its
	// head*: the HEAD whose request carries bytes (or a chunked framing), the
	// one shape libcurl cannot be asked for both halves of — CURLOPT_NOBODY
	// would take the request body with it (see apply_hop). head_complete is
	// the parser's own "the head ended" mark, and the header callback cuts the
	// transfer where the two meet. Both are cleared for the next hop.
	head_reply_only: bool,
	head_complete:   bool,

	// The Digest handshake, as the callbacks have to see it. digest_possible is
	// the hop's (`-A digest` with credentials to answer a challenge with) and
	// digest_answered is the request in flight's (true for the *second* send of
	// a hop, whose reply is the caller's whatever its status). The body of a
	// challenge this hop can answer is not the caller's: requests reads and
	// discards it before it re-sends the request (`r.content`, handle_401), so
	// process_header_line leaves it out of a stream (see there).
	digest_possible: bool,
	digest_answered: bool,

	// max_headers is `--max-headers` (0 = no limit) and head_lines is how many
	// lines of the current head have been read, the terminating blank line
	// included — that is the number http.client checks its limit against.
	max_headers: int,
	head_lines:  int,

	// Chunked uploads: the read callback libcurl calls feeds the hop's body
	// from here, one call at a time.
	upload:      []byte,
	upload_pos:  int,
}

transfer_make :: proc(allocator: mem.Allocator, out: ^Response, sink: Maybe(io.Writer), follow: bool) -> Transfer {
	return Transfer {
		allocator = allocator,
		out       = out,
		sink      = sink,
		follow    = follow,
		body      = buffer_make(allocator, 1024),
		line      = buffer_make(allocator, 256),
	}
}

// transfer_start_hop resets the parser for the hop about to be performed. False
// means the URL copy could not be allocated; the parser is still reset.
transfer_start_hop :: proc(transfer: ^Transfer, method: Method, url: string) -> bool {
	exchange_destroy(&transfer.hop, transfer.allocator)
	transfer.hop = {}
	transfer.hop_method = method
	transfer.have_hop = false
	transfer.head_lines = 0
	transfer.head_complete = false
	transfer.stream_this_hop = false
	buffer_clear(&transfer.body)
	return clone_into(&transfer.hop_url, url, transfer.allocator)
}

transfer_destroy :: proc(transfer: ^Transfer) {
	buffer_destroy(&transfer.body)
	buffer_destroy(&transfer.line)
	exchange_destroy(&transfer.hop, transfer.allocator)
	for &hop in transfer.history {
		exchange_destroy(&hop, transfer.allocator)
	}
	delete(transfer.history, transfer.allocator)
	delete(transfer.hop_url, transfer.allocator)
	transfer^ = {}
}

// redirect_method is requests' method rewriting for the hop that follows a
// response with `status`: a **303** turns anything but HEAD into a GET, a
// **302** turns anything but HEAD into a GET too ("do what the browsers do,
// despite standards"), a **301** turns a POST — and only a POST — into a GET,
// and 307/308 (and everything else) keep the method and the body.
// rebuild_method (sessions.py:370-392, called from `resolve_redirects`,
// :265) is three separate tests, and the two below were one `case 301, 302`
// here before t_5565a2b7: HEAD is the single verb a 302 keeps, so a `PUT`,
// `PATCH`, `DELETE` or `OPTIONS` answered by a 302 has to come out a GET while
// the same verb on a 301 stays put. requests applies this in
// `resolve_redirects` and because the engine drives the redirect itself it is
// applied to the bytes on the wire too — libcurl would keep a CUSTOMREQUEST
// method across a 303.
redirect_method :: proc(method: Method, status: int) -> Method {
	switch status {
	case 301:
		return method == .POST ? .GET : method
	case 302, 303:
		return method == .HEAD ? .HEAD : .GET
	case:
		return method
	}
}

// is_followable_redirect is the *status* half of requests' `is_redirect`: the
// five codes `resolve_redirects` follows, and the only ones whose bodies the
// engine discards. It is deliberately not "any 3xx": `REDIRECT_STATI` is
// `(301, 302, 303, 307, 308)` (models.py:96-102) and `is_redirect` is that set
// *and* a `Location` (models.py:875-879), so a `300 Multiple Choices`, a
// `304 Not Modified`, or a `305 Use Proxy` that carries a `Location` is
// answered by the reference — status, head and body — and used to be followed
// here (docs/PARITY.md §8 item 19). The Location half is `is_redirect_hop`,
// which the hop loop and the sink decision both read.
is_followable_redirect :: proc(status: int) -> bool {
	switch status {
	case 301, 302, 303, 307, 308:
		return true
	}
	return false
}

// is_redirect_hop is `resp.is_redirect` over a hop whose head has been parsed:
// one of the five statuses above *and* a `Location` header (models.py:875-879,
// `"location" in self.headers and self.status_code in REDIRECT_STATI`). It is
// what `resolve_redirects`' `while url:` needs (sessions.py:134-143, :204), so
// it decides both whether a hop is followed and whether its body is the
// caller's: a 3xx the reference answers has its body read like any other reply.
is_redirect_hop :: proc(hop: ^Exchange) -> bool {
	if !is_followable_redirect(hop.status) {
		return false
	}
	_, has_location := hop_header_value(hop, "location")
	return has_location
}

// redirect_keeps_body is requests' one exception in the redirect loop: a 307 or
// a 308 keeps the body and the headers that describe it, every other followed
// redirect loses both (`codes.temporary_redirect`, `codes.permanent_redirect`,
// sessions.py:249-258).
redirect_keeps_body :: proc(status: int) -> bool {
	return status == 307 || status == 308
}

// next_line finds the next complete line in `buffer` (CRLF trimmed) without
// touching the buffer: `consumed` is how many bytes the caller drops with
// buffer_drop once it is done with the line. The line borrows from the buffer,
// so it stays valid until then.
next_line :: proc(buffer: ^Buffer) -> (line: string, consumed: int, ok: bool) {
	for i in 0 ..< len(buffer.data) {
		if buffer.data[i] != '\n' {
			continue
		}
		line = string(buffer.data[:i])
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		return line, i + 1, true
	}
	return "", 0, false
}

// process_header_line consumes one line of a response head. A line starting
// with "HTTP/" opens the hop (replacing whatever head came before it), a blank
// line ends the head, and anything else is a header of the current hop.
process_header_line :: proc(transfer: ^Transfer, line: string) -> Error {
	if strings.has_prefix(line, "HTTP/") {
		if transfer.have_hop {
			// A second status line inside one transfer: an interim 1xx block
			// (`100 Continue`), which is not the reply. It is the only producer
			// left now that the Digest handshake is the port's own — its two
			// sends are two transfers of the hop loop — and requests'
			// http.client keeps only the last head, so the earlier one and its
			// body are thrown away and the count restarts.
			exchange_destroy(&transfer.hop, transfer.allocator)
			transfer.have_hop = false
			transfer.head_lines = 0
			buffer_clear(&transfer.body)
		}
		version, status, reason := parse_status_line(line)
		if !transfer.have_hop {
			transfer.hop.status = status
			transfer.hop.method = transfer.hop_method
			if !clone_into(&transfer.hop.url, transfer.hop_url, transfer.allocator) ||
			   !clone_into(&transfer.hop.http_version, version, transfer.allocator) ||
			   !clone_into(&transfer.hop.reason, reason, transfer.allocator) {
				return .Out_Of_Memory
			}
			transfer.have_hop = true
			// The hop's body is the caller's unless the engine will follow
			// the hop — but the status line alone cannot settle that: a
			// redirect is requests' `is_redirect`, which wants the
			// `Location` header as well, and the head is not read yet. So
			// this is the status half of the answer
			// (`is_followable_redirect`), and the end of the head below
			// finishes it for the case this half cannot see: a status of the
			// five that carries *no* `Location` is not a redirect at all,
			// and its body belongs to the caller like a 200's.
			transfer.stream_this_hop = transfer.sink != nil &&
			                           !(transfer.follow && is_followable_redirect(status))
		}
		return .None
	}

	// Every line of the head counts towards --max-headers, the blank line that
	// ends it included: http.client reads the status line separately and then
	// checks `len(headers) > _MAXHEADERS` after appending each line it takes,
	// so a limit of N refuses a head of N lines (client.py:218-234, patched by
	// client.py:143-153).
	transfer.head_lines += 1
	if transfer.max_headers > 0 && transfer.head_lines > transfer.max_headers {
		return .Max_Headers_Exceeded
	}

	if line == "" {
		// End of a head. The blank line before the body is not a header.
		//
		// The head is what the rest of the redirect question needs: a status
		// of the five is only a redirect when it carries a `Location`
		// (`is_redirect_hop`), and the reference *answers* one that does not.
		// Its body is therefore the caller's exactly like a 200's, and the
		// decision the status line could only half-take is revised here.
		// The other direction cannot happen: a status outside the five was
		// already settled above, and following is off means it was never in
		// question.
		if !transfer.stream_this_hop && transfer.sink != nil && transfer.follow &&
		   is_followable_redirect(transfer.hop.status) && !is_redirect_hop(&transfer.hop) {
			transfer.stream_this_hop = true
		}
		// It is also where a HEAD's *reply* ends. apply_hop could not ask
		// libcurl for that — CURLOPT_NOBODY, its only "the reply has no body"
		// switch, would have taken the request body with it — so the header
		// callback cuts the transfer here instead
		// (`Transfer.head_reply_only`). Two heads this is not the end of: one
		// that has not started yet, and a `100 Continue`, which http.client
		// skips and reads past (`while True: … if status != CONTINUE: break`,
		// CPython 3.11.15 Lib/http/client.py:328-337).
		//
		// A Digest challenge is a third head that cut lands on, and it is why
		// the handshake had to move into the port: a HEAD reply announces
		// `Content-Length` and sends nothing, so anything waiting for that body
		// waits forever — which is what libcurl's own retry did here
		// (`build/probe_digest_head.py`, docs/PARITY.md §4.1). The head is
		// complete at the cut either way, so the challenge is parsed and
		// answered like any other (src/http/digest.odin).
		transfer.head_complete = transfer.have_hop && transfer.hop.status != 100

		// The Digest handshake's first reply is not the caller's body: requests
		// reads and discards it (`r.content`, handle_401) before it re-sends
		// the request with the answer on it. A challenge this hop can answer is
		// therefore not streamed to the caller's writer — it is buffered, and
		// the buffer goes when the hop is reset for the re-send. Only the first
		// send is in question: `digest_answered` is true for the second one,
		// whose reply is the caller's whatever its status.
		if transfer.head_complete && transfer.digest_possible && !transfer.digest_answered &&
		   transfer.hop.status >= 400 && transfer.hop.status < 500 {
			if _, has_challenge := digest_challenge_of(&transfer.hop); has_challenge {
				transfer.stream_this_hop = false
			}
		}
		return .None
	}
	if !transfer.have_hop {
		// A header before any status line is not something HTTP produces; the
		// conservative answer is to ignore it rather than to guess.
		return .None
	}

	colon := strings.index(line, ":")
	if colon < 0 {
		return .None
	}
	name := line[:colon]
	value := strings.trim_left(line[colon + 1:], " 	")

	header: Header
	if !clone_into(&header.name, name, transfer.allocator) {
		return .Out_Of_Memory
	}
	if !clone_into(&header.value, value, transfer.allocator) {
		delete(header.name, transfer.allocator)
		return .Out_Of_Memory
	}
	if !slice_push(&transfer.hop.headers, header, transfer.allocator) {
		delete(header.name, transfer.allocator)
		delete(header.value, transfer.allocator)
		return .Out_Of_Memory
	}
	return .None
}

// hop_header_value reads one header out of a parsed hop, case-insensitively.
hop_header_value :: proc(hop: ^Exchange, name: string) -> (string, bool) {
	for header in hop.headers {
		if strings.equal_fold(header.name, name) {
			return header.value, true
		}
	}
	return "", false
}

// parse_status_line splits "HTTP/1.1 200 OK" (and the HTTP/2 spelling, which
// has no reason phrase) into its three parts. The parts borrow from `line`.
parse_status_line :: proc(line: string) -> (version: string, status: int, reason: string) {
	rest := line
	if space := strings.index_byte(rest, ' '); space >= 0 {
		version = rest[:space]
		rest = strings.trim_left(rest[space + 1:], " ")
	}
	if space := strings.index_byte(rest, ' '); space >= 0 {
		status_text := rest[:space]
		reason = strings.trim_left(rest[space + 1:], " ")
		if value, ok := strconv.parse_int(status_text, 10); ok {
			status = value
		}
	} else if value, ok := strconv.parse_int(rest, 10); ok {
		status = value
	}
	return version, status, reason
}

// resolve_location turns a Location header into the URL the next hop asks for:
// requests' own pipeline for a Location, end to end — the scheme-relative step,
// `urlparse`/`geturl`, `requote_uri` and the join (sessions.py:224-243).
// `http.url_location_resolve_into` carries the rule; this proc is the
// allocation around it.
//
// The result only feeds the history and the next hop's target: the transfer
// itself is libcurl's, and the final URL comes from CURLINFO_EFFECTIVE_URL.
resolve_location :: proc(base: string, location: string, allocator: mem.Allocator) -> (string, Error) {
	joined_buffer := buffer_make(allocator, len(base) + len(location) + 8)
	if !url_location_resolve_into(&joined_buffer, base, location) {
		buffer_destroy(&joined_buffer)
		return "", .Out_Of_Memory
	}
	return string(buffer_owned(&joined_buffer)), .None
}

// url_has_http_adapter is `requests`' test for a URL it can send to at all:
// `Session.get_adapter` returns the first mounted adapter whose `prefix` the
// URL starts with, and httpie mounts the two HTTP adapters (client.py:173-174,
// sessions.py:870-881 — `url.lower().startswith(prefix.lower())` in the
// reference; the third mount is for transport plugins, and the reference has
// none installed). Anything else is refused with `InvalidSchema` when sent.
url_has_http_adapter :: proc(url: string) -> bool {
	return url_has_http_prefix(url, "http://") || url_has_http_prefix(url, "https://")
}

// Adapter_Error is that refusal as a value: the `InvalidSchema` requests raises
// when a *prepared* URL matches no mounted adapter, carrying the URL its message
// quotes. `failed` is the "did this happen" flag, so a zero value means "nothing
// to print" — the common case, since every URL that reaches this test with an
// adapter goes on to be sent. `url` is the prepared URL requests held (the
// resolved, requoted redirect target) and is owned by the request that recorded
// the error.
Adapter_Error :: struct {
	failed: bool,
	url:    string,
}

// adapter_error_message renders the exception the reference prints. requests'
// own text is `f"No connection adapters were found for {url!r}"` (the raise in
// `Session.get_adapter`), and httpie prefixes the exception's class name
// (`f'{type(e).__name__}: {msg}'`, core.py:54-67) — so the line is
// `InvalidSchema: No connection adapters were found for '<url>'`, with Python's
// `repr()` of the URL, single quotes and all. The caller owns the result.
adapter_error_message :: proc(err: ^Adapter_Error, allocator: mem.Allocator) -> string {
	if !err.failed {
		return strings.clone("", allocator) or_else ""
	}
	url_repr := python_str_repr(err.url, allocator)
	defer delete(url_repr, allocator)
	return fmt.aprintf(
		"InvalidSchema: No connection adapters were found for %s",
		url_repr,
		allocator = allocator,
	)
}

// url_has_http_prefix is that test's comparison over one prefix: an upper-ASCII
// fold, which is what `url.lower()` does to a *prepared* URL's first bytes (its
// scheme is ASCII by construction). `prefix` is always lowercase here.
@(private)
url_has_http_prefix :: proc(url: string, prefix: string) -> bool {
	if len(url) < len(prefix) {
		return false
	}
	for i in 0 ..< len(prefix) {
		c := url[i]
		if c >= 'A' && c <= 'Z' {
			c = c - 'A' + 'a'
		}
		if c != prefix[i] {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// libcurl callbacks
// ---------------------------------------------------------------------------

// write_callback buffers the reply body, or streams it into the caller's
// writer. Returning anything but the byte count aborts the transfer.
//
// A `proc "c"` has no Odin context, and everything it calls here (io.write, the
// buffer helpers) is an ordinary procedure, so the callback installs the
// runtime's default context the way Odin expects a C callback to. Nothing below
// this line reads an allocator out of it: the buffers carry their own and every
// allocation takes one as an argument.
write_callback :: proc "c" (data: [^]u8, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	transfer := (^Transfer)(userdata)
	length := int(size * nmemb)
	if length == 0 {
		return 0
	}
	bytes := data[:length]

	if writer, streaming := transfer.sink.?; streaming && transfer.stream_this_hop {
		written, write_err := io.write(writer, bytes)
		if write_err != .None || written != length {
			transfer.failed = .Write_Failed
			return CURL_WRITEFUNC_ERROR
		}
		return c.size_t(length)
	}

	if !buffer_append(&transfer.body, bytes) {
		transfer.failed = .Out_Of_Memory
		return CURL_WRITEFUNC_ERROR
	}
	return c.size_t(length)
}

// read_callback feeds a chunked upload: libcurl asks for bytes, the callback
// hands over the rest of the hop's body (or nothing, which ends the stream).
// It installs the runtime context for the same reason write_callback does.
read_callback :: proc "c" (data: [^]u8, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	transfer := (^Transfer)(userdata)
	want := int(size * nmemb)
	remaining := len(transfer.upload) - transfer.upload_pos
	if want <= 0 || remaining <= 0 {
		return 0
	}
	if want > remaining {
		want = remaining
	}
	copy(data[:want], transfer.upload[transfer.upload_pos:transfer.upload_pos + want])
	transfer.upload_pos += want
	return c.size_t(want)
}

// header_callback reassembles the response heads. libcurl hands them over
// line by line; the parser does not assume one line per call. It installs the
// runtime context for the same reason write_callback does.
header_callback :: proc "c" (data: [^]u8, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	transfer := (^Transfer)(userdata)
	length := int(size * nmemb)
	if length == 0 {
		return 0
	}
	if !buffer_append(&transfer.line, data[:length]) {
		transfer.failed = .Out_Of_Memory
		return CURL_WRITEFUNC_ERROR
	}
	for {
		line, consumed, ok := next_line(&transfer.line)
		if !ok {
			break
		}
		if err := process_header_line(transfer, line); err != .None {
			transfer.failed = err
			return CURL_WRITEFUNC_ERROR
		}
		// A HEAD's reply is its head, and libcurl was not told so (it cannot
		// be: see apply_hop), so the transfer ends where the head does. The
		// abort is the *deliberate* one — CURLE_WRITE_ERROR is what libcurl
		// reports and transport_send reads `head_complete` before it maps it —
		// and it costs the connection, which is what the reference's own
		// transport does with a HEAD as well (`self._close_conn()`,
		// CPython 3.11.15 Lib/http/client.py:467-469).
		if transfer.head_reply_only && transfer.head_complete {
			return CURL_WRITEFUNC_ERROR
		}
		buffer_drop(&transfer.line, consumed)
	}
	return c.size_t(length)
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

// map_curl_error turns libcurl's vocabulary into ours. The user-visible
// wording of each Error is short and ours on purpose: docs/PARITY.md §7.4
// makes the reference's network messages a normalisation allowlist, because
// they embed the Python library's wording and the OS errno text.
map_curl_error :: proc(code: CURLcode) -> Error {
	switch code {
	case CURLE_OK:
		return .None
	case CURLE_COULDNT_RESOLVE_HOST, CURLE_COULDNT_RESOLVE_PROXY:
		return .DNS_Failure
	case CURLE_OPERATION_TIMEDOUT:
		return .Timeout
	case CURLE_TOO_MANY_REDIRECTS:
		return .Too_Many_Redirects
	case CURLE_SSL_CONNECT_ERROR, CURLE_PEER_FAILED_VERIFICATION, CURLE_SSL_CERTPROBLEM,
	     CURLE_SSL_CACERT_BADFILE, CURLE_SSL_CIPHER, CURLE_SSL_ISSUER_ERROR, CURLE_SSL_PINNEDPUBKEYNOTMATCH:
		return .TLS_Failure
	case CURLE_URL_MALFORMAT:
		return .Invalid_URL
	case CURLE_UNSUPPORTED_PROTOCOL:
		return .Unsupported_Scheme
	case CURLE_WRITE_ERROR:
		return .Write_Failed
	case CURLE_OUT_OF_MEMORY, CURLE_FAILED_INIT:
		return .Out_Of_Memory
	case CURLE_COULDNT_CONNECT, CURLE_SEND_ERROR, CURLE_RECV_ERROR, CURLE_GOT_NOTHING, CURLE_PARTIAL_FILE:
		return .Connection_Failed
	case:
		return .Connection_Failed
	}
}

// ---------------------------------------------------------------------------
// The transfer
// ---------------------------------------------------------------------------

// Hop is one request of the chain: what changes when a redirect is followed.
// `url` and `body` are borrowed; the transport owns the string it resolved.
// `method_raw` is the verb as it goes on the wire (see Request.method_raw).
//
// `url` is the URL requests *prepared* — the Location, requoted and resolved
// (sessions.py:237-243) — which is what the history renders; `wire_url` is what
// the connection is pointed at, the same URL with its path and query encoded as
// urllib3 encodes them at send time (url.odin's `url_wire_url_into`). For the
// first hop the two are usually the same string (request_url already carries the
// prepared spelling); `--path-as-is` is the case where they differ, because the
// prepared URL then holds a path that has not been encoded yet (see
// transport_send).
Hop :: struct {
	method:             Method,
	method_raw:         string,
	url:                string,
	wire_url:           string,
	body:               []byte,
	chunked:            bool,
	// body_spent is a `--chunked` upload whose bytes an earlier hop of the
	// chain already sent. The reference's chunked body is a *stream* —
	// `ChunkedUploadStream(stream=iter([body]))` (uploads.py:221-224) — and a
	// followed 307/308 re-uses the prepared request that stream was put on
	// (`resolve_redirects`' `prepared_request = req.copy()`, sessions.py:206,
	// which keeps the body and the three headers a purge would have popped,
	// :247-258). So the hop announces the framing and sends the terminator
	// alone; only the *first* send of the chain carries the bytes. A port with
	// the body in a buffer it still owns would re-send them (t_43183eec).
	body_spent:         bool,
	via_proxy:          bool,
	keep_authorization: bool,
	// purge_body_headers is requests' redirect purge: once a followed redirect
	// was not a 307/308, `Content-Length`, `Content-Type` and
	// `Transfer-Encoding` are gone from the request — and they do not come
	// back on a later hop, because each hop's prepared request is a copy of
	// the previous one (sessions.py:204-258).
	purge_body_headers: bool,
	// redirect_target is true for every hop the chain followed into: the
	// request's own `Cookie` header was derived for the *first* URL only and
	// must be re-derived for this one (requests' resolve_redirects,
	// sessions.py:235-243).
	redirect_target: bool,
}

// method_expects_a_body is the complement of urllib3's
// `_METHODS_NOT_EXPECTING_BODY` (util/request.py:57): the verbs `body_to_chunks`
// hands a `Content-Length: 0` to when it is given no body at all, where the six
// it names get no framing line. `method` is upper-case here by the time it is
// read — requests' `prepare_method` upper-cases the verb it is handed, which is
// what urllib3's `method.upper()` sees, and the port's own `method_raw` is
// upper-cased where it is parsed (parse.odin:2783) — and this set is
// deliberately *not* `method_may_have_body` (src/http/request.odin:338): that
// one is requests' `prepare_content_length` set, which spares `OPTIONS` alone
// of the six above and is what a *first* request's `Content-Length: 0` comes
// from.
method_expects_a_body :: proc(method: string) -> bool {
	switch method {
	case "GET", "HEAD", "DELETE", "TRACE", "OPTIONS", "CONNECT":
		return false
	}
	return true
}

// apply_hop points `handle` at one hop: the URL, the method (and whether it
// carries a body), the headers that survive a rewrite, and the body bytes. The
// header list comes back through `slist`; the caller owns it and must keep it
// alive until the transfer is done.
//
// `digest_authorization` is the `Authorization: Digest …` value the hop is
// *re-sent* with, once the server has been asked and has answered with a
// challenge (src/http/digest.odin); it is empty for every hop that has not been
// challenged, and the caller owns the string.
apply_hop :: proc(
	handle: CURL,
	req: ^Request,
	transfer: ^Transfer,
	c_strings: ^C_String_List,
	hop: Hop,
	digest_authorization: string,
	slist: ^^CURL_slist,
) -> Error {
	url_c, url_ok := c_strings_add(c_strings, hop.wire_url)
	if !url_ok {
		return .Out_Of_Memory
	}
	if code := setopt_string(handle, CURLOPT_URL, url_c); code != CURLE_OK {
		return map_curl_error(code)
	}

	method_text := hop.method_raw
	if method_text == "" {
		method_text = method_to_string(hop.method)
	}
	method_c, method_ok := c_strings_add(c_strings, method_text)
	if !method_ok {
		return .Out_Of_Memory
	}
	if code := setopt_string(handle, CURLOPT_CUSTOMREQUEST, method_c); code != CURLE_OK {
		return map_curl_error(code)
	}

	has_body := len(hop.body) > 0
	// The framing decision is not the body's, it is the *upload's*: a
	// `--chunked` request is chunked-framed on the wire whatever the items
	// are. httpie hands requests a **stream** either way — with no data at
	// all `raw_body` is `b''` and `prepare_request_body`'s `elif chunked:`
	// branch still wraps it, `ChunkedUploadStream(stream=iter([body]))`
	// (uploads.py:221-224; the `is_file_like` and `offline` branches are not
	// taken) — and requests frames an iterable it cannot measure itself: the
	// header dict gets `Transfer-Encoding: chunked` and no `Content-Length`
	// (`is_stream` takes the stream branch, whose `if length:` is false for a
	// ChunkedUploadStream and whose `else` writes the framing —
	// `requests/models.py:605-628` — and `prepare_content_length`'s zero
	// header belongs to `body is None`, which a stream is not, :652-666), and
	// CPython's http.client writes the terminating `0\r\n\r\n` when the stream
	// ends without handing over a byte. So zero bytes to send is not zero
	// upload. The framing also
	// survives a 307/308 hop whose bytes the first send already spent
	// (Hop.body_spent): urllib3 writes the head it kept and the terminating
	// chunk alone. The header list still carries the caller's own
	// `Transfer-Encoding: chunked` line, which is the renderer's derived one
	// (`request_prepare` in src/http/request.odin) — the wire line is the
	// caller's, not a libcurl-written framing of ours (docs/PARITY.md §4.1).
	//
	// The one hop that is *not* an upload is the one a purge reached:
	// `resolve_redirects` pops `Transfer-Encoding` with the other two body
	// headers and sets the body to `None` on every followed redirect that is
	// not a 307/308 (sessions.py:247-258), and every later hop is a copy of
	// that prepared request (`prepared_request = req.copy()`, :206), so the
	// framing does not come back. `hop.purge_body_headers` is that pop, and a
	// purged hop has no body either — which is why the body bytes
	// (`has_body`, `hop.body_spent`) are not the test here.
	//
	// A HEAD is no exception to *this* — the framing is the upload's there too,
	// `--chunked` being a branch on the option and not on the data — but it is
	// the one verb whose *reply* libcurl will not let the port decide
	// separately. The only switch for "a HEAD reply carries no body" is
	// CURLOPT_NOBODY, and it suppresses the *request* body with it: measured,
	// build/probe_libcurl_head.c's `upload-head-nobody` writes the framing line
	// (it is the caller's entry) and then nothing at all — no chunk, no
	// terminating chunk — so the server waits for a body that never comes, and
	// its `fields-head-nobody` shows the same switch taking a *known-length*
	// body away. Framing a HEAD under that switch is therefore not an option,
	// and holding the framing flag down instead is the wire-only divergence
	// this card's parent filed (build/chunked-no-items-probe-htthor.txt's
	// `chunked-no-items-head` row). requests has no such coupling: CPython's
	// http.client writes the chunked body and reads no reply body because the
	// *method* says so (`if (status == NO_CONTENT or status == NOT_MODIFIED or
	// 100 <= status < 200 or self._method == "HEAD"): self.length = 0`,
	// CPython 3.11.15 Lib/http/client.py:381-385, and `read` answers b'' for a
	// HEAD at :462-469). So a HEAD that carries bytes — a known body, or a
	// chunked framing whose only byte is the terminating chunk — takes the same
	// options as any other hop and is *not* marked CURLOPT_NOBODY; the
	// transport cuts the transfer at the end of the reply head instead
	// (`Transfer.head_reply_only`, the header callback), which is what
	// build/probe_libcurl_head.c's `upload-head-abort` measures: the same bytes
	// as `upload-head` and no wait for a reply body. Both halves of the
	// exchange then reach the server as the reference sends them.
	chunked := hop.chunked && !hop.purge_body_headers

	// The option that selects the body source also selects the handle's request
	// kind, so the kind is fixed first and CUSTOMREQUEST — which only replaces
	// the method *string* — is applied after it:
	//   * a chunked body is a stream of unknown length (CURLOPT_UPLOAD with no
	//     INFILESIZE makes libcurl frame it with `Transfer-Encoding: chunked`);
	//   * a known body is CURLOPT_POSTFIELDS;
	//   * no body at all is reset to a bodyless GET — clearing POSTFIELDS alone
	//     would leave a POST-shaped request announcing `Content-Length: 0`,
	//     which is what a followed redirect that dropped its body must not send.
	if chunked {
		if code := setopt_long(handle, CURLOPT_UPLOAD, 1); code != CURLE_OK {
			return map_curl_error(code)
		}
		if code := setopt_read_callback(handle, CURLOPT_READFUNCTION, read_callback); code != CURLE_OK {
			return map_curl_error(code)
		}
		if code := setopt_ptr(handle, CURLOPT_READDATA, transfer); code != CURLE_OK {
			return map_curl_error(code)
		}
		// -1: "the size is not known" — libcurl chunks the upload.
		if code := setopt_long(handle, CURLOPT_INFILESIZE, -1); code != CURLE_OK {
			return map_curl_error(code)
		}
	} else if has_body {
		if code := setopt_ptr(handle, CURLOPT_POSTFIELDS, raw_data(hop.body)); code != CURLE_OK {
			return map_curl_error(code)
		}
		if code := setopt_long(handle, CURLOPT_POSTFIELDSIZE, c.long(len(hop.body))); code != CURLE_OK {
			return map_curl_error(code)
		}
	} else {
		if code := setopt_long(handle, CURLOPT_HTTPGET, 1); code != CURLE_OK {
			return map_curl_error(code)
		}
		if code := setopt_long(handle, CURLOPT_POSTFIELDSIZE, 0); code != CURLE_OK {
			return map_curl_error(code)
		}
	}

	if code := setopt_string(handle, CURLOPT_CUSTOMREQUEST, method_c); code != CURLE_OK {
		return map_curl_error(code)
	}
	// CURLOPT_HTTPGET above has reset the internal request kind to GET, and
	// libcurl decides whether to wait for a response body from that kind — not
	// from the CUSTOMREQUEST string. A HEAD must therefore be marked *after*
	// the reset, or libcurl would wait for the Content-Length bytes a HEAD
	// response never carries. It is asked for only where it costs nothing —
	// the HEAD whose *request* carries no byte at all — because the switch
	// takes the request body with it; every other HEAD is cut at the head
	// instead (see the framing note above).
	head_without_request := hop.method == .HEAD && !chunked && !has_body
	if code := setopt_long(handle, CURLOPT_NOBODY, head_without_request ? 1 : 0); code != CURLE_OK {
		return map_curl_error(code)
	}
	transfer.head_reply_only = hop.method == .HEAD && !head_without_request

	slist^ = nil
	// One line the head does not carry. A followed redirect that purged the
	// body has popped the `Content-Length` requests' `prepare_content_length`
	// had put in the header dict, so the loop below writes none — and libcurl
	// writes none either, because it has no body to measure. The reference's
	// urllib3 frames that request itself: `body_to_chunks` recommends
	// `Content-Length: 0` for `body is None` and a verb outside
	// `_METHODS_NOT_EXPECTING_BODY` (util/request.py:57, :251-256), and
	// `_send_request` writes the line *before* the head's own headers
	// (connection.py:543-560). So the rendered head and the wire disagree here
	// — the one measured case in §4.1 — and the wire is the half the fixture
	// can see. The entry therefore goes first in the list, which is where
	// urllib3's `putheader` puts it: right after the `Host` libcurl writes
	// itself and ahead of the head's own lines. The purge is the whole test
	// for "the dict has no length": `Content-Length` is one of the three names
	// `resolve_redirects` pops, and it is the only way a request that would
	// have carried one loses it.
	if hop.purge_body_headers && !has_body && method_expects_a_body(method_text) {
		framing, framing_ok := c_strings_add(c_strings, "Content-Length: 0")
		if !framing_ok {
			return .Out_Of_Memory
		}
		slist^ = curl_slist_append(slist^, framing)
		if slist^ == nil {
			return .Out_Of_Memory
		}
	}
	// libcurl writes defaults of its own on a request that carries none of
	// these names — `Accept: */*` on every request, `Content-Type:
	// application/x-www-form-urlencoded` on a request with a body — where the
	// reference sends only what its dict holds. An item that unsets one of them
	// (`Accept:`, `Content-Type:`) leaves the dict without the name, so the
	// reference sends nothing and libcurl's own line is the difference; the
	// removal form drops it. A name the request does carry needs no entry: the
	// line in the list already suppresses the default (Curl_checkheaders).
	//
	// The other two names among libcurl's defaults are `Host` and
	// `Accept-Encoding`, and they take the same road through the sentinel above,
	// where the item's unset leaves their entry in the list. `Content-Length`
	// is not here: the only request that should reach the wire without one is
	// the chunked upload, which libcurl frames itself.
	libcurl_defaults := [?]string{"Accept", "Content-Type"}
	for name in libcurl_defaults {
		if _, found := request_header_get(req, name); found {
			continue
		}
		if !request_header_unset(req, name) {
			continue
		}
		removal, removal_err := strings.concatenate({name, ":"}, req.allocator)
		if removal_err != .None {
			return .Out_Of_Memory
		}
		entry, entry_ok := c_strings_add(c_strings, removal)
		delete(removal, req.allocator)
		if !entry_ok {
			return .Out_Of_Memory
		}
		slist^ = curl_slist_append(slist^, entry)
		if slist^ == nil {
			return .Out_Of_Memory
		}
	}
	// Whether the Digest answer went out in the place of an `Authorization` the
	// request already carried (see the loop below): a name written once is not
	// written twice.
	digest_authorization_written := false
	for header in req.headers {
		// `Host` is libcurl's on the wire unless the caller supplied one (see
		// the note further down). Everything else travels as a header entry so
		// it goes out where the list puts it — libcurl puts a header of its own
		// first, right after `Host`, and the reference does not. That includes
		// `Accept-Encoding` and `Content-Length`: libcurl suppresses a header of
		// its own when the caller supplied that name (Curl_checkheaders) and the
		// port still asks for the decoding with CURLOPT_ACCEPT_ENCODING, so the
		// caller's line is what goes out, in the caller's place.
		//
		// What is dropped is exactly what requests drops, and only when it
		// drops it: `resolve_redirects` pops `Content-Length`, `Content-Type`
		// and `Transfer-Encoding` — and clears the body — on every followed
		// redirect that is not a 307/308 (sessions.py:249-258,
		// `purged_headers`). It is *not* a rule about a request that never had
		// a body: a `Content-Type` or `Content-Length` item on the first,
		// bodyless request reaches the wire unchanged, which is why the caller
		// sees the fixture wait for a length nothing follows when the item
		// announces one.
		skip := header.name == ""
		// urllib3's sentinel: the header is not sent at all (connection.py:477-487),
		// and for the names libcurl has a default of its own for the port asks
		// for that default to be dropped with libcurl's own `Name:` removal form
		// — `Host` (derived from the target) and `Accept-Encoding`
		// (CURLOPT_ACCEPT_ENCODING below) are the two that matter; libcurl sends
		// no User-Agent unless asked, so that name needs no entry. Only these
		// three names ever carry the sentinel (src/http/skippable.odin).
		//
		// The value alone does not make a line magic: a session file records
		// the sentinel as ordinary text, and the reference sends that back
		// verbatim (http.request_header_skipped has the mechanism), so only
		// the pair an *item* unset takes this road.
		if request_header_skipped(req, header.name, header.value) {
			removal, removal_err := strings.concatenate({header.name, ":"}, req.allocator)
			if removal_err != .None {
				return .Out_Of_Memory
			}
			entry, entry_ok := c_strings_add(c_strings, removal)
			delete(removal, req.allocator)
			if !entry_ok {
				return .Out_Of_Memory
			}
			slist^ = curl_slist_append(slist^, entry)
			if slist^ == nil {
				return .Out_Of_Memory
			}
			continue
		}
		if hop.purge_body_headers {
			skip = strings.equal_fold(header.name, "Content-Length") ||
			       strings.equal_fold(header.name, "Content-Type") ||
			       strings.equal_fold(header.name, "Transfer-Encoding")
		}
		if strings.equal_fold(header.name, "Transfer-Encoding") {
			// A chunked upload's framing is libcurl's own; a header for it is
			// only written when the hop really is that upload.
			skip = skip || !chunked
		}
		// Credentials do not follow a redirect to another origin (requests'
		// rebuild_auth).
		if !hop.keep_authorization && strings.equal_fold(header.name, "Authorization") {
			skip = true
		}
		// requests pops `Cookie` on every followed redirect and re-derives it
		// from the merged jar for the new URL (sessions.py:235-243). The header
		// this request carries was built for the *first* URL only, so it is
		// never replayed onto a hop the chain followed into; the re-derived
		// value is appended after the loop, where this hop's URL is known.
		if hop.redirect_target && strings.equal_fold(header.name, "Cookie") {
			skip = true
		}
		if skip {
			continue
		}
		// An empty value travels as libcurl's `Name;` form: libcurl reads
		// `Name: ` (nothing after the colon) as its own *removal* syntax and
		// sends no line at all, while requests sends the header with an empty
		// value — which is what an item like `X-Empty;` and a value stripped to
		// nothing both ask for. The port's generated headers are never empty;
		// the caller's and the session's can be.
		//
		// CPython's http.client writes the request line by line when nothing of
		// the head is rendered (`putheader`), and it validates every line as it
		// writes it: the *name* is encoded ascii first — so a name carrying any
		// character above 0x7f (the lone surrogate an invalid argv byte became,
		// or an ordinary non-ASCII character) raises a UnicodeEncodeError
		// before the pattern below even runs — and then matched against
		// `[^:\s][^:\r\n]*`, while the *value* is matched against
		// `\n(?![ 	])|\r(?![ 	\n])`. Values are bytes: requests has already
		// turned each of them into bytes (client.py:203) and libcurl sends
		// those as they are; the one exception is the bearer token httpie still
		// holds as a `str`, encoded latin-1 a few lines below.
		//
		// This is the *second* rule of §3.1 and the reason a request that
		// passed the first can still end the run: `check_header_validity`
		// validated the merged dict, i.e. the last value of a repeated name,
		// while every value is written here (src/http/header_validity.odin has
		// the rule, the reference sites and the reachable set). Both checks run
		// while the header list is built — before libcurl is asked to transfer
		// anything — so a refused run has already printed the rendered head on
		// stdout (the render happens before the send) and sends no byte at all.
		if err := request_encode_check(req, header.name, .Ascii); err != .None {
			return err
		}
		// The exception is the value httpie still has as a `str` — the bearer
		// token its plugin assigns after the headers were finalized. CPython
		// encodes that one with latin-1 (the reason its message names that
		// codec), which both refuses a character above U+00FF and *is* the
		// encoding of the value: `Bearer toké` travels as `Bearer tok\xe9`,
		// one byte, not the two bytes the argv string carries.
		value := header.value
		// The Digest answer takes the place of an `Authorization` the request
		// already carries: requests assigns it onto the copy of the prepared
		// request (`handle_401`), and a dict assignment of a name that is
		// already there replaces its *value*, keeping its position. A request
		// with no such header gets the answer appended instead, in the block
		// below the loop — where requests' own assignment puts a new name too.
		if digest_authorization != "" && strings.equal_fold(header.name, "Authorization") {
			value = digest_authorization
			digest_authorization_written = true
		}
		text_value: string
		if header.str_value {
			if err := request_encode_check(req, value, .Latin1); err != .None {
				return err
			}
			buffer := buffer_make(req.allocator, len(value))
			if !str_latin1_encode_into(&buffer, value) {
				buffer_destroy(&buffer)
				return .Out_Of_Memory
			}
			text_value = string(buffer_owned(&buffer))
			value = text_value
		}
		// The latin-1 bytes are what `putheader` validated, so a refusal names
		// those (`b'Bearer tok\nen'`), not the argv string the port carries the
		// token in.
		if text, part, found := wire_header_refusal(header.name, value); found {
			refusal := wire_header_refuse(req, text, part)
			delete(text_value, req.allocator)
			return refusal
		}
		separator := value == "" ? ";" : ": "
		line, concat_err := strings.concatenate({header.name, separator, value}, req.allocator)
		delete(text_value, req.allocator)
		if concat_err != .None {
			return .Out_Of_Memory
		}
		entry, entry_ok := c_strings_add(c_strings, line)
		delete(line, req.allocator)
		if !entry_ok {
			return .Out_Of_Memory
		}
		slist^ = curl_slist_append(slist^, entry)
		if slist^ == nil {
			return .Out_Of_Memory
		}
	}
	// The `Cookie` a followed hop carries, re-derived from the jar for its own
	// URL. requests' own order: `resolve_redirects` pops the header and
	// `prepare_cookies` puts it back at the end of the head (sessions.py:235-243),
	// so the line closes the request's own headers and the Digest answer below
	// still comes after it. No hook (no session in this run) or an empty value
	// appends nothing — the reference sends a followed hop no cookie its jar
	// does not supply for that URL.
	if hop.redirect_target && req.cookie_hook.value != nil {
		value := req.cookie_hook.value(req.cookie_hook.data, hop.url, req.allocator)
		defer if value != "" {
			delete(value, req.allocator)
		}
		if value != "" {
			line, line_err := strings.concatenate({"Cookie: ", value}, req.allocator)
			if line_err != .None {
				return .Out_Of_Memory
			}
			entry, entry_ok := c_strings_add(c_strings, line)
			delete(line, req.allocator)
			if !entry_ok {
				return .Out_Of_Memory
			}
			slist^ = curl_slist_append(slist^, entry)
			if slist^ == nil {
				return .Out_Of_Memory
			}
		}
	}
	// The Digest answer, last — which is where requests puts it: the header is
	// assigned onto the copy of the prepared request (`handle_401`) after
	// everything the request already carried, so the request's own headers come
	// first and this line closes the list (`CaseInsensitiveDict.__setitem__`
	// keeps a missing name at the end). Measured on a raw socket:
	// build/probe_digest_head.py --wire.
	if digest_authorization != "" && !digest_authorization_written {
		authorization, authorization_err := strings.concatenate({"Authorization: ", digest_authorization}, req.allocator)
		if authorization_err != .None {
			return .Out_Of_Memory
		}
		entry, entry_ok := c_strings_add(c_strings, authorization)
		delete(authorization, req.allocator)
		if !entry_ok {
			return .Out_Of_Memory
		}
		slist^ = curl_slist_append(slist^, entry)
		if slist^ == nil {
			return .Out_Of_Memory
		}
	}
	if hop.via_proxy {
		// libcurl adds `Proxy-Connection: Keep-Alive` to a request it sends
		// through an HTTP proxy; requests does not send that header at all, and
		// the parity fixture echoes the request verbatim, so the extra line is
		// visible. A header entry with no value is libcurl's documented way to
		// remove one of its own headers — the same trick as the `Expect:` line
		// below.
		proxy_connection, proxy_connection_ok := c_strings_add(c_strings, "Proxy-Connection:")
		if !proxy_connection_ok {
			return .Out_Of_Memory
		}
		slist^ = curl_slist_append(slist^, proxy_connection)
		if slist^ == nil {
			return .Out_Of_Memory
		}
	}
	if chunked || has_body {
		// requests does not send `Expect: 100-continue`; libcurl adds it for
		// bodies over its threshold unless the header is suppressed like this.
		// A chunked upload is over that threshold by construction — libcurl
		// cannot measure it and asks for the continuation as soon as it is an
		// upload at all, with a body, with a spent one (`Hop.body_spent`) or
		// with none (the `--chunked` request whose items contribute no byte),
		// so suppressing it belongs to the upload, not the body.
		empty_expect, expect_ok := c_strings_add(c_strings, "Expect:")
		if !expect_ok {
			return .Out_Of_Memory
		}
		slist^ = curl_slist_append(slist^, empty_expect)
		if slist^ == nil {
			return .Out_Of_Memory
		}
	}
	if slist^ != nil {
		if code := setopt_ptr(handle, CURLOPT_HTTPHEADER, slist^); code != CURLE_OK {
			return map_curl_error(code)
		}
	}
	return .None
}

// url_parts splits a URL far enough to compare origins. The parts borrow.
Url_Parts :: struct {
	scheme: string,
	host:   string, // brackets kept for an IPv6 literal
	port:   int,    // 0 when the URL does not spell one out
}

url_parts :: proc(url: string) -> Url_Parts {
	parts: Url_Parts
	rest := url
	if scheme_end := strings.index(rest, "://"); scheme_end >= 0 {
		parts.scheme = rest[:scheme_end]
		rest = rest[scheme_end + 3:]
	}
	authority := rest
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		authority = rest[:slash]
	}
	if at := strings.last_index_byte(authority, '@'); at >= 0 {
		authority = authority[at + 1:]
	}
	if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
		parts.host = authority[:colon]
		if value, parsed := strconv.parse_int(authority[colon + 1:], 10); parsed {
			parts.port = value
		}
	} else {
		parts.host = authority
	}
	return parts
}

// should_strip_authorization is requests' should_strip_auth: the credentials do
// not follow a redirect to another host, another port or another scheme. The
// one exception the reference makes is an upgrade from http to https on the
// same host — on their *standard* ports — and requests evaluates it before any
// default-port normalisation, so the order below is the reference's
// (sessions.py:128-158).
should_strip_authorization :: proc(old_url: string, new_url: string) -> bool {
	if strings.equal_fold(old_url, new_url) {
		return false
	}
	old := url_parts(old_url)
	new := url_parts(new_url)
	if !strings.equal_fold(old.host, new.host) {
		return true
	}
	// The reference's one exception, evaluated *before* any default-port
	// normalisation: http (80 or absent) -> https (443 or absent) keeps them
	// (sessions.py:138-144).
	if strings.equal_fold(old.scheme, "http") && (old.port == 0 || old.port == 80) &&
	   strings.equal_fold(new.scheme, "https") && (new.port == 0 || new.port == 443) {
		return false
	}
	changed_port := old.port != new.port
	changed_scheme := !strings.equal_fold(old.scheme, new.scheme)
	// A same-scheme hop that only spells the default port differently is the same
	// origin (sessions.py:146-155, `default_port`).
	default_port := strings.equal_fold(old.scheme, "https") ? 443 : 80
	if !changed_scheme &&
	   (old.port == 0 || old.port == default_port) &&
	   (new.port == 0 || new.port == default_port) {
		return false
	}
	return changed_port || changed_scheme
}

// transport_send performs the exchange for `req` (already prepared) and fills
// `res`, which must be zeroed. When `sink` is not nil the final reply body is
// written there instead of being buffered. On failure `res` is left zeroed:
// nothing the engine allocated is handed to a caller that will not free it.
//
// The redirect chain is driven here rather than by CURLOPT_FOLLOWLOCATION: a
// custom request method survives libcurl's own redirect handling unchanged, so
// only a loop of our own can apply httpie's rewriting rules (303 -> GET,
// 301/302 POST -> GET, 307/308 preserve) to the bytes that actually go out.
transport_send :: proc(req: ^Request, res: ^Response, sink: Maybe(io.Writer)) -> Error {
	// requests looks the URL up in the mounted adapters before anything else it
	// does with the request (`Session.send` → `get_adapter`, sessions.py:874-881),
	// and httpie mounts the two HTTP prefixes — so a request whose URL kind is
	// not `.HTTP` ends here, with requests' own `InvalidSchema` and without
	// libcurl having been asked for anything. The initial request is the argv
	// one (docs/PARITY.md §3.6, §8 item 21); a *redirect* target with no adapter
	// is refused further down, where the chain resolves it.
	if req.url_kind != .HTTP {
		return adapterless_failure(req)
	}

	global_code := curl_global_init(CURL_GLOBAL_DEFAULT)
	if global_code != CURLE_OK {
		return map_curl_error(global_code)
	}
	// Paired with the init above on every path out of here. libcurl reference
	// counts these calls, and the engine keeps no process-global state of its
	// own (docs/ARCHITECTURE.md §4).
	defer curl_global_cleanup()

	handle := curl_easy_init()
	if handle == nil {
		return .Out_Of_Memory
	}
	defer curl_easy_cleanup(handle)

	url, url_err := request_url(req, req.allocator)
	if url_err != .None {
		return url_err
	}
	defer delete(url, req.allocator)

	// `--path-as-is` is where the prepared URL and the wire URL part company:
	// `request_url` carries the argv URL's path as it was written (`/a/./b c`),
	// which is what the history renders, and the connection is handed that path
	// *encoded* once — the reference's `_encode_target` (util/url.py:453-467) is
	// the only thing that touches it at send time, so the raw space reaches the
	// server as `%20` and a `%2e` keeps its escape with uppercase hex
	// (`url_wire_url_into`, docs/PARITY.md §3.6). Every other first hop's
	// prepared target is already in that encoded form, which is why the two
	// URLs are otherwise the same string.
	first_wire_url := url
	first_wire_url_owned: string
	defer if first_wire_url_owned != "" {
		delete(first_wire_url_owned, req.allocator)
	}
	if req.path_as_is {
		wire_buffer := buffer_make(req.allocator, len(url) + 8)
		if !url_wire_url_into(&wire_buffer, url) {
			buffer_destroy(&wire_buffer)
			return .Out_Of_Memory
		}
		first_wire_url_owned = string(buffer_owned(&wire_buffer))
		first_wire_url = first_wire_url_owned
	}

	transfer := transfer_make(req.allocator, res, sink, req.follow_redirects)
	defer transfer_destroy(&transfer)
	// --max-headers is enforced by the head parser, per hop (see
	// process_header_line).
	transfer.max_headers = req.max_headers

	c_strings := c_strings_make(req.allocator)
	defer c_strings_destroy(&c_strings)

	// --- reply capture
	if code := setopt_write_callback(handle, CURLOPT_WRITEFUNCTION, write_callback); code != CURLE_OK {
		return map_curl_error(code)
	}
	if code := setopt_ptr(handle, CURLOPT_WRITEDATA, &transfer); code != CURLE_OK {
		return map_curl_error(code)
	}
	if code := setopt_header_callback(handle, CURLOPT_HEADERFUNCTION, header_callback); code != CURLE_OK {
		return map_curl_error(code)
	}
	if code := setopt_ptr(handle, CURLOPT_HEADERDATA, &transfer); code != CURLE_OK {
		return map_curl_error(code)
	}

	// --- decoding
	// The option is what makes libcurl decode the reply; the `Accept-Encoding`
	// *line* is the caller's own header entry (the item's spelling and
	// position, or the port's `gzip, deflate` identity when the caller spelled
	// none), because libcurl leaves a header of its own out once that name is
	// in CURLOPT_HTTPHEADER. The announced value here is what the reference
	// client announced; libcurl decodes whatever Content-Encoding the server
	// actually sends (gzip, deflate, br, zstd — whatever the system libcurl
	// was built with).
	//
	// An `Accept-Encoding:` an *item* unset announces nothing: the reference
	// sends no such line at all, because the sentinel the item left in the
	// header dict suppresses urllib3's (connection.py:477-487, and the removal
	// entry above tells libcurl the same). The option still asks libcurl for
	// the decoding, which is what the reference's client does regardless of
	// what it announced.
	//
	// The sentinel a *session file* holds is not that case: the reference
	// encodes it and sends it verbatim, and its decoding is driven by the
	// reply's own Content-Encoding, not by the line it announced — so the
	// option keeps the port's identity there and the caller's line is what goes
	// out (request_header_skipped tells the two apart).
	encoding := ACCEPT_ENCODING
	if announced, found := request_header_get(req, "Accept-Encoding"); found && announced != "" {
		if !request_header_skipped(req, "Accept-Encoding", announced) {
			encoding = announced
		}
	}
	encoding_c, encoding_ok := c_strings_add(&c_strings, encoding)
	if !encoding_ok {
		return .Out_Of_Memory
	}
	if code := setopt_string(handle, CURLOPT_ACCEPT_ENCODING, encoding_c); code != CURLE_OK {
		return map_curl_error(code)
	}

	// --- transport policy
	if req.timeout_s > 0 {
		// httpie's --timeout is a per-socket inactivity timeout; libcurl's
		// CURLOPT_TIMEOUT is the whole transfer, which is the closest thing it
		// has, plus the connect timeout for the connection phase.
		if code := setopt_long(handle, CURLOPT_TIMEOUT, c.long(req.timeout_s)); code != CURLE_OK {
			return map_curl_error(code)
		}
		if code := setopt_long(handle, CURLOPT_CONNECTTIMEOUT, c.long(req.timeout_s)); code != CURLE_OK {
			return map_curl_error(code)
		}
	}
	if code := setopt_long(handle, CURLOPT_NOSIGNAL, 1); code != CURLE_OK {
		return map_curl_error(code)
	}
	if code := setopt_long(handle, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1); code != CURLE_OK {
		return map_curl_error(code)
	}
	// The target handed to libcurl is final, with or without `--path-as-is`:
	// the port removed the dot segments the reference removes (urllib3's
	// `parse_url` for the requested URL, `urljoin` for a netloc-less redirect
	// target) and kept the ones it keeps (an absolute or scheme-relative
	// Location, and the `%2e` the requoting rule unquoted into a literal `.`).
	// libcurl's own dot-segment removal (`CURLOPT_PATH_AS_IS`, 0 by default)
	// would run over that result a second time: it turned `GET /a/./b` — the
	// prepared target of `http://…/a/%2e/b`, and a `--path-as-is` path — into
	// `GET /a/b`, and squashed the `/a/../b` an absolute Location keeps. The
	// reference's transport only encodes at this point (`_encode_target`,
	// util/url.py:453-467), so the option is the port's version of "nothing
	// else may normalize it" (docs/PARITY.md §3.6).
	if code := setopt_long(handle, CURLOPT_PATH_AS_IS, 1); code != CURLE_OK {
		return map_curl_error(code)
	}

	// --- TLS
	if code := setopt_long(handle, CURLOPT_SSL_VERIFYPEER, req.verify ? 1 : 0); code != CURLE_OK {
		return map_curl_error(code)
	}
	// 2 is "verify that the host name matches the certificate"; 0 disables the
	// check, which is what --verify=no means.
	if code := setopt_long(handle, CURLOPT_SSL_VERIFYHOST, req.verify ? 2 : 0); code != CURLE_OK {
		return map_curl_error(code)
	}
	// `--verify=<ca-bundle>`: verify against this bundle instead of the system
	// store. requests hands the path to urllib3 as `ca_certs`, so an explicit
	// path is exactly what the reference trusts (nothing else changes: peer and
	// host verification stay on).
	if req.ca_bundle != "" {
		ca_c, ca_ok := c_strings_add(&c_strings, req.ca_bundle)
		if !ca_ok {
			return .Out_Of_Memory
		}
		if code := setopt_string(handle, CURLOPT_CAINFO, ca_c); code != CURLE_OK {
			return map_curl_error(code)
		}
	}
	// `--ciphers` is OpenSSL's cipher-list grammar and libcurl hands it to
	// OpenSSL verbatim: a list the library cannot use fails the handshake with
	// CURLE_SSL_CIPHER (mapped to .TLS_Failure above), which is the loud failure
	// the help text promises.
	if req.ciphers != "" {
		ciphers_c, ciphers_ok := c_strings_add(&c_strings, req.ciphers)
		if !ciphers_ok {
			return .Out_Of_Memory
		}
		if code := setopt_string(handle, CURLOPT_SSL_CIPHER_LIST, ciphers_c); code != CURLE_OK {
			return map_curl_error(code)
		}
	}
	if req.cert != "" {
		cert_c, cert_ok := c_strings_add(&c_strings, req.cert)
		if !cert_ok {
			return .Out_Of_Memory
		}
		if code := setopt_string(handle, CURLOPT_SSLCERT, cert_c); code != CURLE_OK {
			return map_curl_error(code)
		}
	}
	if req.cert_key != "" {
		key_c, key_ok := c_strings_add(&c_strings, req.cert_key)
		if !key_ok {
			return .Out_Of_Memory
		}
		if code := setopt_string(handle, CURLOPT_SSLKEY, key_c); code != CURLE_OK {
			return map_curl_error(code)
		}
		// An encrypted key: without the passphrase libcurl falls back to
		// prompting on the terminal ("Enter PEM pass phrase:"), which is what
		// `--cert-key-pass` exists to prevent.
		if req.cert_key_pass != "" {
			pass_c, pass_ok := c_strings_add(&c_strings, req.cert_key_pass)
			if !pass_ok {
				return .Out_Of_Memory
			}
			if code := setopt_string(handle, CURLOPT_KEYPASSWD, pass_c); code != CURLE_OK {
				return map_curl_error(code)
			}
		}
	}

	// --- proxy (explicit, so libcurl's own environment lookup stays out of the
	// way; see proxy.odin)
	env_scratch: [ENV_SCRATCH_SIZE]u8
	proxy, use_proxy := proxy_for(req, env_scratch[:])
	// Function-scoped: the URL must outlive the block that built it, and a
	// `defer` inside the `if` below would free it as that block ends.
	prepared_proxy: string
	defer delete(prepared_proxy, req.allocator)
	proxy_text := ""
	if use_proxy {
		prepared, prepared_ok := proxy_url(proxy, req.allocator)
		if !prepared_ok {
			return .Out_Of_Memory
		}
		prepared_proxy = prepared
		proxy_text = prepared_proxy
	}
	proxy_c, proxy_ok := c_strings_add(&c_strings, proxy_text)
	if !proxy_ok {
		return .Out_Of_Memory
	}
	if code := setopt_string(handle, CURLOPT_PROXY, proxy_c); code != CURLE_OK {
		return map_curl_error(code)
	}

	// --- auth: basic and bearer travel as headers (request_prepare built
	// them). Digest is answered *here*, not by libcurl: the handshake is two
	// requests, and libcurl can only send the second one when it can rewind the
	// first one's body — which a `--chunked` upload (INFILESIZE_UNKNOWN, a read
	// callback with no seek) and a HEAD that carries bytes are not. The port
	// therefore sends both requests as the reference does, with the answer it
	// computes itself (src/http/digest.odin, docs/PARITY.md §4.1).
	credentials := request_credentials(req)
	digest_possible := req.auth_type == .Digest && (credentials != "" || req.userinfo_present)
	// The `Authorization: Digest …` line the hop in flight is *re-sent* with: it
	// belongs to one hop, so it is cleared before every hop of the chain (a
	// redirect target gets its own challenge, and requests' copy does not carry
	// the answer of the hop it was copied from).
	digest_authorization: string
	defer if digest_authorization != "" {
		delete(digest_authorization, req.allocator)
	}
	digest_answered := false

	// --- the hop loop (see the note above on why the chain is driven here)
	hop := Hop {
		method             = req.method,
		method_raw         = request_method(req),
		url                = url,            // borrowed: `url` outlives the loop
		wire_url           = first_wire_url, // the first hop's prepared URL, encoded (see above)
		body               = req.body_source != .None ? req.body : nil,
		chunked            = req.chunked,
		via_proxy          = use_proxy,
		keep_authorization = true,
	}
	// The URL a followed redirect resolved to, owned here because `hop.url`
	// borrows it (the first hop borrows the caller's `url` instead).
	hop_url_owned: string
	defer if hop_url_owned != "" {
		delete(hop_url_owned, req.allocator)
	}
	// The same for the URL the connection is pointed at: `url_wire_url_into`
	// builds it for every hop after the first (which borrows `url`).
	hop_wire_owned: string
	defer if hop_wire_owned != "" {
		delete(hop_wire_owned, req.allocator)
	}

	redirects := 0
	for {
		// A Digest answer belongs to the hop it was computed for: the next hop
		// of the chain starts its own handshake, with no header of its own.
		if digest_authorization != "" {
			delete(digest_authorization, req.allocator)
			digest_authorization = ""
		}
		digest_answered = false
		// The hop's send, and the one re-send the Digest handshake can add to
		// it: requests' auth hook sends the request a second time with the
		// answer to the challenge on it (`handle_401`), and that is what the
		// reference's wire carries — the same request bytes and framing, the
		// answer appended after the caller's own headers.
		for {
			hop_slist: ^CURL_slist
			// The hop's chunked body is handed to libcurl only while it is still
			// there to send: a hop whose chain already sent it (Hop.body_spent)
			// gets the framing and no bytes.
			transfer.upload = hop.chunked && !hop.body_spent ? hop.body : nil
			transfer.upload_pos = 0
			if apply_err := apply_hop(handle, req, &transfer, &c_strings, hop, digest_authorization, &hop_slist); apply_err != .None {
				slist_destroy(hop_slist)
				return follow_abort(req, &transfer, apply_err, hop)
			}
			if !transfer_start_hop(&transfer, hop.method, hop.url) {
				slist_destroy(hop_slist)
				return follow_abort(req, &transfer, .Out_Of_Memory, hop)
			}
			// What the callbacks need to know about the handshake: whether this
			// hop has one at all, and whether the request in flight already
			// carries the answer (in which case the reply is the caller's,
			// challenge or not — requests sends the request twice and never a
			// third time, `num_401_calls < 2`).
			transfer.digest_possible = digest_possible
			transfer.digest_answered = digest_authorization != ""

			code := curl_easy_perform(handle)
			// The handle must not keep pointing at a list that is about to die.
			setopt_ptr(handle, CURLOPT_HTTPHEADER, nil)
			slist_destroy(hop_slist)

			if transfer.failed != .None {
				return follow_abort(req, &transfer, transfer.failed, hop)
			}
			// The one abort that is not a failure: a HEAD's reply ends where
			// its head does, and the header callback cut the transfer there on
			// purpose — CURLE_WRITE_ERROR is libcurl's word for a callback that
			// said stop. `head_complete` is only set once the head is parsed
			// and its status is not an interim `100`, so nothing is being
			// swallowed here: the hop is answered exactly as the reference
			// answered it (docs/PARITY.md §4.1).
			if transfer.head_reply_only && transfer.head_complete && code == CURLE_WRITE_ERROR {
				code = CURLE_OK
			}
			if code != CURLE_OK {
				return follow_abort(req, &transfer, map_curl_error(code), hop)
			}

			// The Digest answer, and with it the second request. requests'
			// `handle_401` is an auth hook that runs once per prepared request
			// (`num_401_calls < 2`) on the 4xx it gets back; the answer it
			// computes goes on the wire after the request's own headers, and
			// the request itself is re-sent — not modelled by libcurl's own
			// retry, which cannot rewind the bodies this card is about
			// (src/http/digest.odin).
			if transfer.digest_possible && !transfer.digest_answered {
				if answer, answered := digest_answer_for(hop, &transfer.hop, credentials, req.allocator); answered {
					digest_authorization = answer
					digest_answered = true
					// The reference's `--chunked` body is a *stream* and the
					// first send spent it, so the re-send announces the framing
					// and hands over the terminating chunk alone — the same
					// fact `Hop.body_spent` records for a followed 307/308, and
					// what the reference's own retry puts on the wire
					// (measured: build/probe_digest_head.py --wire).
					if hop.chunked {
						hop.body_spent = true
					}
					continue
				}
			}
			break
		}

		// The follow question is requests' `is_redirect` — one of the five
		// statuses *and* a `Location` (models.py:875-879) — which drives its
		// `while url:` loop (sessions.py:134-143, :204). Both halves live in
		// `is_redirect_hop`; the value is read here as well because it is the
		// next hop's URL, but a 3xx outside the five, or one without the
		// header, is the answer and the chain stops.
		location, _ := hop_header_value(&transfer.hop, "location")
		followable := req.follow_redirects && is_redirect_hop(&transfer.hop)
		if !followable {
			break
		}
		// requests reads the Location before it decides anything else about
		// the hop: `get_redirect_target` decodes the header's bytes as UTF-8
		// (sessions.py:142-151), and a Location the codec refuses raises there
		// — before the redirect limit is consulted and before any hop is made.
		// The port holds the header as the bytes it arrived in (§3.6), so the
		// codec is a check rather than a conversion: a valid Location and the
		// bytes are the same string.
		location_error := str_utf8_decode_failure(location)
		if location_error.failed {
			req.location_error = location_error
			return follow_abort(req, &transfer, .Redirect_Location_Not_Utf8, hop)
		}
		// `while url:` (sessions.py:204) — a Location that is empty is a
		// falsy target, so the chain stops here and the 3xx stays the response.
		if location == "" {
			break
		}
		if req.max_redirects > 0 && redirects + 1 >= req.max_redirects {
			// httpie counts responses, not followed redirects: it aborts as
			// soon as the response number reaches --max-redirects
			// (client.py:120-127, `if args.max_redirects and response_count ==
			// args.max_redirects`), so `--max-redirects=1` refuses the first
			// redirect outright. The abort happens after this hop's request
			// went out, and that request is part of what the run printed
			// (`follow_abort`).
			return follow_abort(req, &transfer, .Too_Many_Redirects, hop)
		}
		redirects += 1

		// The response that led to this hop, read now: `transfer.hop` is reset
		// a few lines below, when it becomes history. Both the method rewrite
		// and the purge of the body's headers are decided from its status.
		led_to_status := transfer.hop.status
		next_method := redirect_method(hop.method, led_to_status)

		// The Location becomes the hop's URL in one step, `resolve_location`,
		// which is requests' whole pipeline for it (sessions.py:224-243): the
		// scheme-relative step, `urlparse`/`geturl`, `requote_uri` and then
		// `urljoin` or the requote alone. The order matters and the rule lives
		// with its own comments in src/http/url.odin
		// (`url_location_resolve_into`); what comes out is the *prepared* URL,
		// the one requests holds in `prepared_request.url` and the one httpie
		// renders (`urlsplit` of it, models.py:141-147).
		next_url, next_err := resolve_location(hop.url, location, req.allocator)
		if next_err != .None {
			return follow_abort(req, &transfer, next_err, hop)
		}
		// requests holds that target in `prepared_request.url` and looks for an
		// adapter to send it with; `Session.get_adapter` matches the URL
		// against the mounted prefixes — httpie mounts `http://` and
		// `https://` only — and a URL that starts with neither raises
		// `InvalidSchema: No connection adapters were found for '…'` before
		// anything connects (sessions.py:870-881). The port refuses that target
		// at the same site, with the reference's own message (Adapter_Error,
		// rendered by adapter_error_message), which also keeps libcurl from
		// opening a protocol conversation the server will never answer — an
		// `ftp://` target used to sit in one until the request timed out
		// (docs/PARITY.md §3.6).
		//
		// The refused request is part of the chain the caller has to print:
		// requests' own loop built it and httpie yielded it before the send
		// that refused it (`yield prepared_request`, client.py:105), so it is
		// the *last* entry of the history rather than the hop in flight
		// (`follow_abort_refused`).
		if !url_has_http_adapter(next_url) {
			return follow_abort_refused(req, &transfer, hop, next_url, next_method)
		}

		// What the hop is *sent* with is that same URL with its path and query
		// encoded the way urllib3 encodes them at send time; the URL above is
		// the one the history renders (docs/PARITY.md §3.6).
		wire_buffer := buffer_make(req.allocator, len(next_url) + 8)
		if !url_wire_url_into(&wire_buffer, next_url) {
			buffer_destroy(&wire_buffer)
			delete(next_url, req.allocator)
			return follow_abort(req, &transfer, .Out_Of_Memory, hop)
		}
		next_wire_url := string(buffer_owned(&wire_buffer))

		// The hop just performed becomes history; what `res` will describe is
		// whatever the chain ends on.
		if !slice_push(&transfer.history, transfer.hop, req.allocator) {
			delete(next_wire_url, req.allocator)
			delete(next_url, req.allocator)
			return follow_abort(req, &transfer, .Out_Of_Memory, hop)
		}
		transfer.hop = {}

		if hop_url_owned != "" {
			delete(hop_url_owned, req.allocator)
		}
		hop_url_owned = next_url
		if hop_wire_owned != "" {
			delete(hop_wire_owned, req.allocator)
		}
		hop_wire_owned = next_wire_url

		// Only the method survives, not the body: a rewritten hop is a fresh
		// request (requests drops the body with the method). The verb string
		// has to follow the rewrite too — apply_hop reads `method_raw` before
		// the enum, so leaving the original spelling there would put POST on
		// the wire with no body.
		if next_method != hop.method {
			hop.method_raw = method_to_string(next_method)
		}
		if !redirect_keeps_body(led_to_status) {
			// requests' purge, body and headers together: anything but a
			// 307/308 loses the body *and* `Content-Length`/`Content-Type`/
			// `Transfer-Encoding`, even when the method was not rewritten at
			// all (a 303 keeps a `GET` a `GET` and still clears its body).
			// `hop.body` stays nil for every hop after this one: the reference
			// copies the purged prepared request forward.
			hop.purge_body_headers = true
			hop.body = nil
		} else if hop.chunked && len(hop.body) > 0 {
			// A 307/308 keeps the body, but the reference's `--chunked` body
			// is a stream, and the hop just sent it: the iterator the hop's
			// prepared request still points at is exhausted, so the *next*
			// hop announces the framing and sends nothing (Hop.body_spent,
			// and src/session/context.odin's `write_hop_request`, which stops
			// printing the body of such a hop for the same reason). A body
			// the purge above took away is not this case: it is gone for
			// good, and `hop.body` stays nil, so nothing is set here.
			hop.body_spent = true
		}
		hop.keep_authorization = !should_strip_authorization(hop.url, next_url)
		hop.redirect_target = true
		hop.method = next_method
		hop.url = next_url
		hop.wire_url = next_wire_url
	}

	return transport_finish(req, res, &transfer, handle)
}

// follow_abort is the failure path of a followed chain: it hands the renderer
// the requests the chain already made and then reports the error. httpie prints
// a hop's request *before* it sends it (client.py:105, `yield
// prepared_request`), so a chain that dies mid-follow has printed every request
// it made — the one in flight included, whose reply never came — and the
// failure path owes the caller those messages, not just the first hop's
// (docs/PARITY.md §3.6). The history carries the hops that completed; the hop in
// flight joins it as a request-only entry, because there is no reply to render
// for it (the reference's `--all` shows a reply only once the next hop has been
// chosen, which by definition did not happen here).
@(private)
follow_abort :: proc(req: ^Request, transfer: ^Transfer, err: Error, pending: Hop) -> Error {
	if pending.url != "" {
		entry := Exchange {
			method = pending.method,
			url    = strings.clone(pending.url, req.allocator) or_else "",
		}
		if entry.url == "" || !slice_push(&transfer.history, entry, req.allocator) {
			exchange_destroy(&entry, req.allocator)
		}
	}
	// Published on the request, not the reply: `send` leaves `res` zeroed on
	// every failure path, and the caller frees what it owns through the request
	// (request_destroy). See the field's comment in types.odin.
	req.follow_history = transfer.history
	transfer.history = nil
	return err
}

// adapterless_failure refuses the *request being sent* when its own URL is one
// requests has no adapter for — the argv form of the same refusal
// `follow_abort_refused` makes for a redirect target. `Session.send` reaches
// `get_adapter` before anything connects (sessions.py:874-881), so the run ends
// with `InvalidSchema: No connection adapters were found for '<url>'` and
// nothing was asked of libcurl; the URL the message quotes is the one requests
// held (`Request.url_text`), and the error owns a copy of it — request_destroy
// releases it (types.odin, `Adapter_Error`).
@(private)
adapterless_failure :: proc(req: ^Request) -> Error {
	url_copy := strings.clone(req.url_text, req.allocator) or_else ""
	if url_copy == "" {
		return .Out_Of_Memory
	}
	req.adapter_error = {failed = true, url = url_copy}
	return .No_Connection_Adapter
}

// follow_abort_refused is follow_abort for the one abort that refuses the
// *next* request rather than the one in flight. requests looks the target the
// Location resolved to up in `Session.get_adapter`, httpie has mounted the two
// HTTP adapters only, and a target that matches neither raises `InvalidSchema`
// before anything connects (sessions.py:870-881). httpie has already printed
// that request — it prints a request before it sends it (`yield
// prepared_request`, client.py:105) — so the chain the caller owes the renderer
// ends with it, one entry past the hop that was in flight, and the error names
// the URL requests named.
//
// `refused_url` is the loop's own resolved target, handed over: the error owns
// it from here, and the chain entry gets a clone of it.
@(private)
follow_abort_refused :: proc(
	req: ^Request,
	transfer: ^Transfer,
	pending: Hop,
	refused_url: string,
	refused_method: Method,
) -> Error {
	req.adapter_error = {failed = true, url = refused_url}
	// The hop in flight is appended — and the chain published — by
	// follow_abort; the refused request follows it, in the order httpie printed
	// them. A clone that cannot be made costs the request line, not the error.
	err := follow_abort(req, transfer, .No_Connection_Adapter, pending)
	entry := Exchange {
		method = refused_method,
		url    = strings.clone(refused_url, req.allocator) or_else "",
	}
	if entry.url == "" || !slice_push(&req.follow_history, entry, req.allocator) {
		exchange_destroy(&entry, req.allocator)
	}
	return err
}

// transport_finish moves what the parser collected into `res`: the final hop
// becomes the Response itself (the history keeps the hops that led to it) and
// the effective URL comes from libcurl. On failure `res` is destroyed and left
// zeroed, so the caller never has to free a reply it did not receive.
transport_finish :: proc(req: ^Request, res: ^Response, transfer: ^Transfer, handle: CURL) -> Error {
	res.allocator = req.allocator

	status := transfer.hop.status
	if !transfer.have_hop {
		// No head was parsed at all; the response code is still authoritative.
		response_code: c.long
		if code := curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &response_code); code == CURLE_OK {
			status = int(response_code)
		}
	}
	res.status = status

	// The final hop joins the history like the ones before it, so a renderer can
	// print the request of every hop in order (httpie's client yields each hop's
	// request as it sends it, client.py:104-127). Its headers are about to move
	// into the Response, so this entry carries only what the request line needs
	// and owns its own copy of the URL.
	final_hop := Exchange {
		method = transfer.hop.method,
		url    = strings.clone(transfer.hop.url, req.allocator) or_else "",
		status = transfer.hop.status,
	}
	if !slice_push(&transfer.history, final_hop, req.allocator) {
		exchange_destroy(&final_hop, req.allocator)
		response_destroy(res)
		return .Out_Of_Memory
	}

	if !clone_into(&res.reason, transfer.hop.reason, req.allocator) ||
	   !clone_into(&res.http_version, transfer.hop.http_version, req.allocator) {
		response_destroy(res)
		return .Out_Of_Memory
	}

	// The final hop's headers are moved (not copied) out of the parser, which
	// leaves the history holding the hops that led to it.
	res.headers = transfer.hop.headers
	transfer.hop.headers = nil

	effective: cstring
	if code := curl_easy_getinfo(handle, CURLINFO_EFFECTIVE_URL, &effective); code == CURLE_OK && effective != nil {
		if !clone_into(&res.url, string(effective), req.allocator) {
			response_destroy(res)
			return .Out_Of_Memory
		}
	} else if !clone_into(&res.url, transfer.hop_url, req.allocator) {
		response_destroy(res)
		return .Out_Of_Memory
	}

	res.history = transfer.history
	transfer.history = nil

	// A streamed body went to the caller's writer; the Response keeps no copy.
	if transfer.sink == nil {
		res.body = buffer_owned(&transfer.body)
	}
	return .None
}