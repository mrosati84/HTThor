// Package http owns the HTTP exchange: the request we are about to send, the
// response we received, and the transport error vocabulary shared by the CLI,
// the session and the output layers.
//
// Read docs/ARCHITECTURE.md before adding a type here: it fixes the module
// boundaries and the memory ownership rules.
//
// The scaffold declares the shapes, the URL splitter and the dispose helpers.
// Building the wire request (query params, headers, body encodings, auth) and
// performing the exchange is t_3d62ca31's job.
package http

import "core:fmt"
import "core:mem"
import "core:strings"

// Method is the HTTP verb. CONNECT is not something httpie exposes; it is here
// because the enum doubles as the source of CURLOPT_CUSTOMREQUEST.
Method :: enum {
	GET,
	HEAD,
	POST,
	PUT,
	PATCH,
	DELETE,
	OPTIONS,
	TRACE,
	CONNECT,
}

method_to_string :: proc(method: Method) -> string {
	switch method {
	case .GET:     return "GET"
	case .HEAD:    return "HEAD"
	case .POST:    return "POST"
	case .PUT:     return "PUT"
	case .PATCH:   return "PATCH"
	case .DELETE:  return "DELETE"
	case .OPTIONS: return "OPTIONS"
	case .TRACE:   return "TRACE"
	case .CONNECT: return "CONNECT"
	}
	return "GET"
}

// method_from_string accepts the method shorthands case-insensitively; whether
// httpie is that lax is pinned by docs/PARITY.md.
method_from_string :: proc(s: string) -> (method: Method, ok: bool) {
	switch {
	case strings.equal_fold(s, "GET"):     return .GET, true
	case strings.equal_fold(s, "HEAD"):    return .HEAD, true
	case strings.equal_fold(s, "POST"):    return .POST, true
	case strings.equal_fold(s, "PUT"):     return .PUT, true
	case strings.equal_fold(s, "PATCH"):   return .PATCH, true
	case strings.equal_fold(s, "DELETE"):  return .DELETE, true
	case strings.equal_fold(s, "OPTIONS"): return .OPTIONS, true
	case strings.equal_fold(s, "TRACE"):   return .TRACE, true
	case strings.equal_fold(s, "CONNECT"): return .CONNECT, true
	}
	return .GET, false
}

Scheme :: enum {
	HTTP,
	HTTPS,
}

scheme_to_string :: proc(scheme: Scheme) -> string {
	switch scheme {
	case .HTTP:  return "http"
	case .HTTPS: return "https"
	}
	return "http"
}

scheme_from_string :: proc(s: string) -> (scheme: Scheme, ok: bool) {
	switch {
	case strings.equal_fold(s, "http"):  return .HTTP, true
	case strings.equal_fold(s, "https"): return .HTTPS, true
	}
	return .HTTP, false
}

scheme_default_port :: proc(scheme: Scheme) -> int {
	switch scheme {
	case .HTTP:  return 80
	case .HTTPS: return 443
	}
	return 80
}

// Header keeps the caller's spelling and order; the engine writes them out
// verbatim, in the order given.
Header :: struct {
	name:  string,
	value: string,
	// str_value is true for a value httpie still has as a `str` — not bytes —
	// when the request goes on the wire. Every value the command line, the
	// session or an item supplied was encoded by `finalize_headers`
	// (client.py:203), so what reaches the wire is bytes; the auth plugin is
	// the one site that *assigns* a header after that, and the bare token it
	// was given is a string. CPython's `http.client.putheader` encodes such a
	// value with latin-1, so it is the one value that can fail there (a
	// character above U+00FF) and the one that travels as latin-1 bytes
	// (`Bearer toké` → `Bearer tok\xe9`) instead of the utf-8 the rest of the
	// request carries (src/http/python_str.odin, docs/PARITY.md §3.6).
	str_value: bool,
}

Query_Param :: struct {
	name:  string,
	value: string,
}

// Auth_Type is httpie's --auth-type vocabulary. `cli` keeps its own copy of the
// same three names (cli imports http, never the other way round); the session
// maps one onto the other.
Auth_Type :: enum {
	Basic,
	Digest,
	Bearer,
}

// Body_Kind is the body encoding: httpie's --json (default), --form,
// --multipart and --raw. It decides how Data_Items are serialised and which
// Content-Type/Accept the request carries.
Body_Kind :: enum {
	JSON,
	Form,
	Multipart,
	Raw,
}

// Data_Item_Kind is one request item after the CLI has applied the item grammar
// in docs/PARITY.md §3. The separators are the CLI's; the *encoding* is here.
Data_Item_Kind :: enum {
	String,   // `name=value` / `name=@file`: a JSON string, or a form field
	Raw_JSON, // `name:=json` / `name:=@file`: JSON spliced in verbatim
	File,     // `name@file`: a multipart upload (value is the path)
}

// Data_Item is owned by the Request that holds it: request_destroy releases
// every string in it with the request's allocator.
Data_Item :: struct {
	kind: Data_Item_Kind,
	name: string,
	// The value for .String/.Raw_JSON; the file *path* for .File.
	value: string,
	// .File only: the multipart filename. "" means "the path's leaf, with its
	// `\` in a Windows-style path still intact" (see filename_of).
	filename: string,
	// .File only: the `;type=` override of `name@file;type=text/csv`. "" means
	// "guess from the filename extension".
	mime: string,
	// lone are the characters of `value` the value's own bytes cannot represent:
	// a `:=` JSON text's lone surrogate, recorded by format.Surrogate_String
	// (src/format/json.odin) and carried here in the terms the encode check
	// below needs. Empty for every other item, and for a marked string too when
	// the request is JSON — the body serialiser owns that half.
	lone: []Lone_Surrogate,
}

// Url_Kind says what `requests` did with the request's URL and whether the
// session has an adapter for it at all. `Session.get_adapter` tests the URL
// against the mounted prefixes and raises `InvalidSchema` when none matches
// (sessions.py:870-881), and httpie mounts the two HTTP ones — so the URL's
// *scheme* and how it was prepared decide both the message and the request head
// that precedes it (docs/PARITY.md §3.6, §8 item 21).
Url_Kind :: enum {
	// HTTP: http/https — `prepare_url` ran and an adapter is mounted.
	HTTP,
	// Other_Scheme: a scheme the port does not speak whose text starts with
	// "http" (`httpx://…`, `httpfoo://…`). requests prepares such a URL like
	// any other (models.py:498-505 only short-circuits what does *not* start
	// with "http"), so it is requoted and its host rule is `parse_url`'s
	// non-normalizable one (util/url.py:517, :549, :369) — and then no adapter
	// matches it.
	Other_Scheme,
	// Unprepared: a URL `prepare_url` short-circuits outright — `":" in url
	// and not url.lower().startswith("http")` (models.py:498-505) — so
	// *nothing* prepares it: the head httpie prints is `urlsplit` of the URL
	// as the command line spelled it, and no adapter matches it either.
	Unprepared,
}

// Body_Source says where the request body comes from. .Items means "encode
// `items` according to `body_kind`"; .Raw means "`body` is already the wire
// bytes" (--raw or a bare `@file`); .None means "no body at all".
Body_Source :: enum {
	None,
	Items,
	Raw,
}

// Request describes one HTTP exchange. Every string and slice in it is owned by
// `allocator` and released by request_destroy; nothing borrows from argv or
// from a caller-owned buffer.
Request :: struct {
	allocator: mem.Allocator,

	method:   Method,
	scheme:   Scheme,
	host:     string, // "example.com", "127.0.0.1", "[::1]" (brackets kept)
	port:     int,    // 0 means "the scheme's default port"
	path:     string, // always non-empty; "/" when the URL carries no path
	// "user:pass" from the URL, "" when absent. The curl-style shorthand's is
	// the one the reference *synthesizes*: its '@' puts the `localhost:<port>`
	// httpie's rule prepended into the credentials, so those digits are not a
	// port (`http.url_split`, docs/PARITY.md §3.6).
	userinfo: string,
	// userinfo_present is true when the URL spelled a userinfo at all —
	// `urlsplit(url).username is not None`, which is the test httpie's
	// `_process_auth` makes before it turns one into credentials
	// (cli/argparser.py:289-299). An `@` with nothing in front of it is the
	// credentials `:` (`password or ''`), not "no credentials", so the empty
	// userinfo cannot be told from the absent one by `userinfo == ""` alone.
	userinfo_present: bool,
	// url_kind is how requests prepared this URL and whether the port has an
	// adapter for it (`Url_Kind`). `.HTTP` is the ordinary case: the URL was
	// prepared and the transport sends it.
	url_kind: Url_Kind,
	// url_text is the URL requests holds for a request the port has **no
	// adapter** for — the one `Session.get_adapter` refuses, whose `repr()` the
	// message quotes and whose `urlsplit` (models.py:137-151) the request head
	// is spelled from. Nothing else spells such a URL: the unprepared one was
	// never prepared, and the other-scheme one was prepared *into* this string.
	// Owned, and "" for a request with an adapter.
	url_text: string,
	// url_unquoted is the *input* of that preparation for an `.Other_Scheme`
	// URL: the string `prepare_url` hands requests' `requote_uri`
	// (models.py:560, `urlunparse((scheme, netloc, path, "", query, fragment))`),
	// which is `quote(unquote_unreserved(url), safe=…)` — the requoted
	// `url_text` is that call's *output*, so the two are the same URL in the two
	// spellings the reference's position numbers are counted in. `quote` encodes
	// with `errors='strict'`, so a character utf-8 has no encoding for — the lone
	// surrogate PEP 383 made of an argv byte that is not valid UTF-8 — raises
	// inside it with that character's *code point index in this string*; the
	// requoted URL cannot say where it was, because every such byte is already
	// `%XX` in it. Owned; "" for every other kind.
	url_unquoted: string,
	// url_unquoted_items_at is the byte offset in `url_unquoted` the
	// `name==value` items go in at: `prepare_url` appends their `quote_plus`
	// spelling to the URL's own query (`_encode_params`, models.py:550-558)
	// *before* the requote, and the fragment follows them, so this is the offset
	// of the '#' that opens it — or the end of the string. The items are not
	// known when the URL is built (the CLI's grammar adds them after
	// `request_create`), so the reconstruction is spliced together where it is
	// checked (`request_check_other_scheme_url`).
	url_unquoted_items_at: int,

	// query_raw is the URL's own query string, verbatim and without the '?';
	// `query` holds the `name==value` items, URL-encoded when the target is
	// built. httpie keeps the URL's query as given and appends the items.
	query_raw: string,
	query:     []Query_Param,
	// path_as_is is httpie's `--path-as-is` as it reaches the request: `path`
	// is then the argv URL's path exactly as it was written — `ensure_path_as_is`
	// puts it back into the prepared URL after requests has prepared it
	// (client.py:94-98), which is why the target is not requoted either
	// (http.request_target). Only the connection's own encoding runs on it
	// (url.odin's `url_wire_url_into`), so a space is a raw space in the
	// rendered request line and `%20` on the wire. docs/PARITY.md §3.6.
	path_as_is: bool,
	// target_verbatim is set on the synthetic request the session builds for a
	// followed hop: `path` and `query_raw` are then already in the spelling
	// requests prepared the hop's URL with — `requote_uri` + urljoin, with no
	// `_encode_invalid_chars` after it — and that spelling is what the history
	// renders (models.py:141-147 reads `urlsplit(request.url)`). What the hop
	// actually sends is the re-encoded form, which the transport derives from
	// the hop's URL (url.odin's `url_wire_url_into`). docs/PARITY.md §3.6.
	target_verbatim: bool,
	// requote_fallback is requests' `requote_uri` except-branch for the URL this
	// request was prepared from. `requote_uri` runs over the *whole* prepared URL
	// (models.py:560), and when one window of two alphanumeric characters behind a
	// '%' is not hexadecimal `unquote_unreserved` raises and the whole string is
	// quoted with '%' out of the safe set: no escape is unquoted and every '%' of
	// the path, of the URL's own query and of the `name==value` items becomes a
	// literal `%25`. Only the netloc can make that window appear — urllib3's
	// `_encode_invalid_chars` leaves every component it touches with each '%'
	// followed by two hex digits, and the zone-id branch of `_normalize_host`
	// writes the RFC 6874 separator back as a bare '%' — so the decision comes out
	// of `url_host_normalize` (its `requote_fallback` out-param, set by
	// `http.request_create`) and `request_target` honours it for all three
	// spellings. docs/PARITY.md §3.6, kanban t_75b15cf5.
	requote_fallback: bool,
	headers:          []Header,
	// unset_headers is the names the command line *unset* — an item whose
	// separator is `:` and whose value is empty (`Header:`), which the
	// reference turns into a `None` (`requestitems.py:process_header_arg`
	// answers `arg.value or None`) — in command-line order, owned like every
	// other string.
	//
	// The pair itself never reaches this list: `HTTPHeadersDict.add`'s `None`
	// replaces every value of the name (`cli/dicts.py:26-28`) and
	// `finalize_headers` skips it (`client.py:190-207`), so the name is gone
	// before `requests` sees the dict. The names are kept here because two of
	// the headers the port adds *after* the merge are entries of that same
	// dict — httpie's automatic `Accept` and the body's `Content-Type`
	// (`make_default_headers`, client.py:263-278) — and the unset removed
	// them, while the headers `requests` derives itself (Content-Length,
	// Transfer-Encoding, Authorization) are assigned after the `None` pair
	// was dropped and come back (requests/models.py:452-513, :652-666).
	unset_headers: []string,

	// The body: `items` (encoded according to body_kind) or `body` (.Raw).
	items:             []Data_Item,
	body_source:       Body_Source,
	body_kind:         Body_Kind,
	body:              []byte,
	body_content_type: string, // .Raw: the Content-Type the CLI chose ("" = none)
	boundary:          string, // --boundary; "" means "generate one"

	// content_type_item is the CLI's own `Content-Type` item verbatim — the
	// value a multipart body's Content-Type is built from, because client.py
	// reads `args.headers.get('Content-Type')` and the session's base headers
	// are not part of `args.headers` (client.py:353-358). "" means the command
	// line carried no such item. Owned like every other string.
	content_type_item: string,

	// method_raw is the request line's verb as the caller spelled it, already
	// upper-cased (requests' prepare_method). "" means "use method_to_string
	// (method)"; a verb outside the nine standard ones — PROPFIND, say — lives
	// here because Method has no room for it. Owned like every other string.
	method_raw:  string,
	chunked:     bool, // --chunked: Transfer-Encoding instead of Content-Length
	offline:     bool, // --offline: --chunked still prints its Content-Length
	compress:    int,  // --compress is a counter: > 1 forces deflate
	// body_compressed is set once body_compress has replaced the body with its
	// deflate stream, so a second request_prepare cannot deflate it twice.
	body_compressed: bool,
	// transfer_encoding_derived is true when request_prepare added the
	// Transfer-Encoding header itself — an online `--chunked` upload — rather
	// than receiving it from the CLI or the session. requests adds that
	// framing header while preparing the body, *after* it has merged the
	// session's headers, so the header keeps a position among the derived
	// group instead of joining httpie's own headers at the end
	// (cli/client.py:215-256; output/render.odin's header slots).
	transfer_encoding_derived: bool,
	// content_length_derived is true when request_prepare derived the
	// Content-Length from the body. requests *assigns* that header while
	// preparing the body, so a length the CLI or the session spelled out is
	// replaced by it — the line that renders belongs to requests, and takes a
	// position among the derived headers rather than among the request's own
	// (requests/models.py:499-513; output/render.odin's header order).
	content_length_derived: bool,
	// json_accept mirrors httpie's `args.json or auto_json`
	// (client.py:263-278): it decides between the JSON Accept/Content-Type pair
	// and requests' session default `Accept: */*`. The session computes it —
	// httpie derives it from whether the request carries a body.
	json_accept: bool,

	// Auth. `auth` is "user:pass" (basic/digest) or the token (bearer);
	// `auth_type` selects the scheme. `userinfo` from the URL is the fallback.
	auth:      string,
	auth_type: Auth_Type,

	// Transport policy copied down from the CLI options.
	timeout_s:        int, // 0: libcurl's own default
	follow_redirects: bool,
	max_redirects:    int,
	// max_headers is `--max-headers`: the number of response-head lines (the
	// blank line that ends the head included) that may be read before the
	// response is refused. 0 means "no limit", which is httpie's default
	// (docs/PARITY.md §2 --max-headers). The count and the failure wording are
	// http.client's own — see max_headers_error_message.
	max_headers: int,
	verify:      bool, // --verify / --verify=no; true unless turned off
	// proxy is the `--proxy` entry the session selected for this request's
	// scheme, in the reference's `PROTOCOL:PROXY_URL` grammar (PARITY.md §2,
	// definition.py:715-722). The key is dropped when the URL is built; an
	// entry without a key is taken as the URL itself (proxy.odin).
	proxy:    string,
	// cert / cert_key / cert_key_pass / ca_bundle / proxy are BORROWED from
	// cli.Options — the session aliases them in and only cli.options_destroy
	// frees them (ARCHITECTURE §4). Nothing here may release them.
	cert:          string,
	cert_key:      string,
	cert_key_pass: string,
	// ca_bundle is `--verify=<path>`: when non-empty libcurl verifies the peer
	// against this CA bundle instead of the system store (CURLOPT_CAINFO).
	// `--verify=no` is `verify = false` and leaves ca_bundle empty.
	ca_bundle: string,

	// encode_error is the UnicodeEncodeError the reference raises while it
	// re-encodes one of the request's strings: the first header value, query
	// item, form field, credential or header name that reaches a codec it cannot
	// satisfy (python_str.odin has the rule and the reference sites). The site
	// that hits it records it here and returns .Str_Not_Encodable — including
	// the renderer's, whose position is the offset in the *rendered* head — so
	// the session can print the reference's message with the reference's
	// position. A value: the request owns nothing for it, and request_destroy
	// zeroes it with the rest of the struct.
	encode_error: Str_Encode_Error,

	// wire_error is the ValueError the reference raises while it *writes* the
	// request head: CPython's http.client.putheader validates every header line
	// as it writes it, and the first one it refuses ends the run (the rule is
	// the second half of §3.1, header_validity.odin). The site is inside the
	// transport, after the render — the head is on stdout by then — and before
	// libcurl is asked to transfer anything, so a refusal here prints the head
	// and sends nothing. The text is owned by the request; request_destroy
	// releases it with the rest of the struct.
	wire_error: Wire_Header_Error,

	// location_error is the UnicodeDecodeError the reference raises while it
	// reads a redirect's Location header: the bytes there are handed to the
	// utf-8 codec (`get_redirect_target`'s `to_native_string(location, "utf8")`,
	// §3.6), and one the codec refuses ends the run before the hop is made —
	// whatever the redirect limit says, because the decode comes first. The
	// site is inside the redirect loop, so the request that answered is on
	// stdout by then. A value: the request owns nothing for it, and
	// request_destroy zeroes it with the rest of the struct.
	location_error: Str_Decode_Error,

	// adapter_error is requests' InvalidSchema for a redirect target that
	// matches no mounted adapter: requests looks the *prepared* URL up in
	// `Session.get_adapter` (sessions.py:870-881) and httpie has mounted the two
	// HTTP adapters only, so a target with any other scheme is refused there —
	// before anything connects, and after the request that was refused has been
	// printed. The message is requests' own, built around the repr of that URL
	// (`f"No connection adapters were found for {url!r}"`), so the URL is what
	// the request carries: `url` is owned here, the site inside the transport's
	// redirect loop, and the session is the only printer (§3.6).
	adapter_error: Adapter_Error,

	// follow_history is the chain a *failed* follow had already made: the hops
	// that completed, oldest first, plus the hop that was in flight as a
	// request-only entry. httpie prints a hop's request *before* it sends it
	// (`yield prepared_request`, client.py:105), so a chain that dies mid-follow
	// — the redirect limit, a refused connection, a Location the codec refuses —
	// has already printed every request it made; `Response.history` cannot carry
	// them, because a failed `send` leaves the reply zeroed, so the transport
	// publishes them here instead (§3.6). The one abort that refused the *next*
	// request rather than the one in flight (`.No_Connection_Adapter`) ends the
	// chain with that request's entry. The request owns the entries;
	// request_destroy releases them.
	follow_history: []Exchange,
}

// Exchange is one request/response pair of an exchange: a redirect hop, or the
// final reply. `Response` keeps the final one in its own fields and *all* of
// them, in order, in `history` — that is what `--all` renders and what the
// redirect tests assert on.
Exchange :: struct {
	method:       Method,
	url:          string, // the URL requested for this hop
	status:       int,
	reason:       string,
	http_version: string, // "HTTP/1.1"; "" when unknown
	headers:      []Header,
}

// Response is a fully buffered reply: the body is in memory, never a stream the
// caller has to drain (unless it asked for `send_to`'s writer).
Response :: struct {
	allocator: mem.Allocator,

	status:       int,
	reason:       string,
	http_version: string, // "HTTP/1.1"; "" when unknown
	headers:      []Header,
	body:         []byte,
	url:          string,      // the final URL, after any redirects
	history:      []Exchange,  // every hop, oldest first, the final one last
}

// Error is the transport vocabulary. The user-visible wording of each value is
// finalised with the engine; docs/PARITY.md pins what httpie prints. Network
// messages are normalised by the parity harness (docs/PARITY.md §7.4), so the
// wording here stays short and ours.
Error :: enum {
	None,
	Not_Implemented,
	Invalid_URL,
	Unsupported_Scheme,
	Out_Of_Memory,
	Connection_Failed,
	DNS_Failure,
	TLS_Failure,
	Timeout,
	Too_Many_Redirects,
	Max_Headers_Exceeded,
	Write_Failed,
	File_Read_Failed,
	Unsupported_Body,
	// Str_Not_Encodable is the UnicodeEncodeError the reference raises while it
	// re-encodes one of the command line's strings for the wire — a byte that is
	// not valid UTF-8 reaching a value, a query item or a credential. The
	// request carries the message's parts (Request.encode_error); the session
	// prints them, because http does not format messages.
	Str_Not_Encodable,
	// Wire_Header_Refused is the ValueError the reference raises while it writes
	// a header line the prepare-time check never saw (§3.1's second rule). The
	// request carries the message's parts (Request.wire_error) and the session
	// prints them, the same way it prints the UnicodeEncodeError above.
	Wire_Header_Refused,
	// Redirect_Location_Not_Utf8 is the UnicodeDecodeError the reference raises
	// in the redirect loop, when a Location header's bytes are not valid UTF-8
	// (`to_native_string(location, "utf8")`, §3.6). It stops the chain before
	// the hop, whatever the redirect limit says. The request carries the
	// message's parts (Request.location_error) and the session prints them.
	Redirect_Location_Not_Utf8,
	// No_Connection_Adapter is requests' InvalidSchema for a redirect target it
	// has no adapter for: `Session.get_adapter` matches the *prepared* URL
	// against the mounted prefixes, httpie mounts the two HTTP ones, and a
	// target that starts with neither is refused there — before anything
	// connects (sessions.py:870-881). The message is requests' own
	// (`f"No connection adapters were found for {url!r}"`), so the request
	// carries the URL that is printed (Request.adapter_error) and the session
	// builds the line. §3.6.
	No_Connection_Adapter,
}

error_message :: proc(err: Error) -> string {
	switch err {
	case .None:
		return ""
	case .Not_Implemented:
		return "the HTTP transport is not wired up yet (scaffold; see docs/ARCHITECTURE.md)"
	case .Invalid_URL:
		return "invalid URL"
	case .Unsupported_Scheme:
		return "unsupported URL scheme"
	case .Out_Of_Memory:
		return "out of memory"
	case .Connection_Failed:
		return "connection failed"
	case .DNS_Failure:
		return "could not resolve host"
	case .TLS_Failure:
		return "TLS handshake failed"
	case .Timeout:
		return "request timed out"
	case .Too_Many_Redirects:
		return "too many redirects"
	case .Max_Headers_Exceeded:
		return "the response head is larger than --max-headers allows"
	case .Write_Failed:
		return "failed to write the response body"
	case .File_Read_Failed:
		return "could not read the request body's file"
	case .Unsupported_Body:
		return "unsupported request body"
	case .Str_Not_Encodable:
		// The message is the UnicodeEncodeError itself; the session builds it
		// from Request.encode_error (this text is never printed).
		return "the command line is not valid UTF-8"
	case .Wire_Header_Refused:
		// The message is the ValueError itself; the session builds it from
		// Request.wire_error (this text is never printed).
		return "the transport refused a header line"
	case .Redirect_Location_Not_Utf8:
		// The message is the UnicodeDecodeError itself; the session builds it
		// from Request.location_error (this text is never printed).
		return "a Location header is not valid UTF-8"
	case .No_Connection_Adapter:
		// The message is requests' InvalidSchema itself; the session builds it
		// from Request.adapter_error (this text is never printed).
		return "no connection adapter for the redirect target"
	}
	return ""
}

// max_headers_error_message is the warning httpie prints when the response head
// grows past --max-headers. Its bytes are the reference's: CPython's
// `http.client._read_headers` raises `HTTPException("got more than %d headers" %
// _MAXHEADERS)` (client.py:218-234), requests wraps that exception in its
// ConnectionError, and the parity capture `max-headers-failure` records the
// result. httpie patches the limit around the send (client.py:143-153), so the
// number in the message is the flag's value. The caller owns the result.
max_headers_error_message :: proc(limit: int, allocator: mem.Allocator) -> string {
	return fmt.aprintf(
		"ConnectionError: ('Connection aborted.', HTTPException('got more than %d headers'))",
		limit,
		allocator = allocator,
	)
}
