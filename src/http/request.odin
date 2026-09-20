package http

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// request_create splits `url` and takes owned copies of everything the Request
// keeps. Allocations come from `allocator`; the returned Request releases them
// through request_destroy, which uses that same allocator.
//
// The defaults match httpie: JSON bodies, verification on. The session copies
// the rest of the transport policy down from the CLI options (http deliberately
// does not import cli — docs/ARCHITECTURE.md §2).
//
// `path_as_is` is httpie's `--path-as-is`: the path is taken as the URL spells
// it — urllib3's dot-segment removal (`url_path_remove_dot_segments_into`) does
// not run — and, because the flag *puts the argv URL's path back into the
// prepared URL* (client.py:94-98, `ensure_path_as_is`), the port keeps that path
// raw: `request_target` copies it as it stands instead of requoting it, and only
// the connection's own encoding runs at send time (docs/PARITY.md §3.6,
// §2 --path-as-is).
//
// The host is not taken from the URL as it is spelled: `url_host_normalize`
// applies the reference's rule to it (lowercase, unquote an unreserved
// percent-escape, IDNA-encode a non-ASCII label, refuse an invalid one), and
// `host_error` receives the parts of the *InvalidURL* that rule raises — or of
// the `ValueError` CPython's own bracket check raises, which the port runs for
// the shapes the rule's pattern accepts (docs/PARITY.md §3.6, t_8a2dad4a) — the
// request is not built at all then.
request_create :: proc(
	allocator: mem.Allocator,
	method: Method,
	url: string,
	scheme_override: Maybe(Scheme) = nil,
	path_as_is: bool = false,
	host_error: ^Host_Error = nil,
) -> (req: Request, err: Error) {
	target, split_err := url_split(url, scheme_override)
	if split_err != .None {
		return {}, split_err
	}

	// A URL requests never prepares (its scheme is not http/https and its text
	// does not start with "http") goes down its own road: `prepare_url` returns
	// before it parses anything (models.py:498-505), so there is no host rule,
	// no requote and no dot-segment removal — `urlsplit` of the URL as the
	// command line spelled it is the whole of it (docs/PARITY.md §3.6, §8
	// item 21).
	if target.unprepared {
		return request_create_unprepared(allocator, method, target, path_as_is)
	}

	req.allocator = allocator
	req.method = method
	req.scheme = target.scheme
	req.body_kind = .JSON
	req.verify = true
	req.path_as_is = path_as_is
	req.userinfo_present = target.has_userinfo
	if target.other_scheme {
		req.url_kind = .Other_Scheme
		// `requote_uri` runs over the whole prepared URL (models.py:560), and
		// that one decision is what the netloc, the path and the query all
		// honour — urllib3's `_encode_invalid_chars` never ran over a scheme it
		// does not normalize, so this is the *only* pass the URL gets, and its
		// `InvalidURL` fallback is decided over the URL as requests holds it.
		req.requote_fallback = url_requote_is_invalid(target.url.text)
	}

	// The host and the port the reference would use, owned: the host is both the
	// Host header and the authority of the URL the transport is handed, and the
	// port is the one `_HOST_PORT_RE` read — `target.port` is only the split's
	// own read of it, for the callers that never build a request. The same call
	// decides whether requests' requote of the whole URL takes its `InvalidURL`
	// branch, which the target's path and query then honour.
	//
	// A scheme the port does not speak is the exception the *scheme* makes:
	// urllib3's `_normalize_host` only has a rule for a normalizable scheme
	// (`_NORMALIZABLE_SCHEMES = ("http", "https", None)`, util/url.py:13, :369),
	// so `httpx://EXAMPLE.com:9/` keeps the case urllib3 would have folded —
	// and only requests' own IDNA step and label check run after it
	// (models.py:526-532, docs/PARITY.md §3.6, §8 item 21).
	port := target.port
	host: string
	host_err: Error
	if target.other_scheme {
		host, host_err = url_host_normalize_flat(
			target.host_port,
			target.userinfo,
			target.url,
			allocator,
			host_error,
			&port,
			req.requote_fallback,
		)
	} else {
		host, host_err = url_host_normalize(
			target.host_port,
			target.userinfo,
			target.url,
			allocator,
			host_error,
			&port,
			&req.requote_fallback,
		)
	}
	if host_err != .None {
		return {}, host_err
	}
	req.host = host
	req.port = port

	if !split_text_clone_into(&req.userinfo, target.userinfo, allocator) ||
	   !clone_into(&req.query_raw, target.query, allocator) {
		request_destroy(&req)
		return {}, .Out_Of_Memory
	}
	if !request_set_path(&req, target.path, path_as_is, target.other_scheme) {
		request_destroy(&req)
		return {}, .Out_Of_Memory
	}
	// A URL requests prepared into a string of its own — the scheme lowercased,
	// the authority spelled out and the target requoted — is that string the
	// refusal quotes; an http/https URL keeps none (its `url_text` stays empty,
	// because it is never refused). It is built last, over the path and the
	// query the request now carries.
	if target.other_scheme {
		url_text, url_unquoted, items_at, url_text_err := request_other_scheme_url(&req, target, allocator)
		if url_text_err != .None {
			request_destroy(&req)
			return {}, url_text_err
		}
		req.url_text = url_text
		req.url_unquoted = url_unquoted
		req.url_unquoted_items_at = items_at
	}

	return req, .None
}

// request_create_unprepared builds the request for a URL `prepare_url`
// short-circuits (models.py:498-505): a URL that names a scheme the port does
// not speak and whose text does not start with "http". Nothing prepares it —
// not the host (a port spelled as `0009` or as nothing at all stays as it is
// written), not the path (its '.' and '..' segments and its escapes are its own
// bytes, and a space stays a space), and not the query — while the *rest* of the
// request is prepared exactly as usual (the body, `Authorization`, the derived
// headers: the reference's `prepare` runs them all after the short-circuit).
//
// Two things come from `urlsplit` of the URL itself and nowhere else, because
// httpie's model reads them off the URL requests held (models.py:137-151):
//
//   - the path and the query it prints (`path or '/'`, the query verbatim), with
//     the tab/CR/LF `urlsplit` removes before it parses; and
//   - `Host`: the netloc minus its userinfo, **as spelled** — a padded or empty
//     port included, and empty rather than absent for a URL with no authority
//     at all (`file:///etc/hostname`).
//
// `req.port` is 0 and `req.host` is that verbatim netloc: nothing connects with
// such a request (`Session.get_adapter` refuses it), so the authority is only
// ever printed.
//
// `--path-as-is` is the one transform: `ensure_path_as_is` rewrites the URL
// itself (`urlparse(url).geturl()`, client.py:94-98) before it is looked up, so
// the message quotes the rewritten URL and the head is `urlsplit` of *it*.
@(private)
request_create_unprepared :: proc(
	allocator: mem.Allocator,
	method: Method,
	target: Target,
	path_as_is: bool,
) -> (req: Request, err: Error) {
	req.allocator = allocator
	req.method = method
	// Nothing connects with this request, so the scheme is never read: it is
	// `.HTTP` because `Scheme` has no room for a name the port does not speak,
	// and `url_kind` is what says the URL has no adapter.
	req.scheme = target.scheme
	req.body_kind = .JSON
	req.verify = true
	req.path_as_is = path_as_is
	req.url_kind = .Unprepared
	req.userinfo_present = target.has_userinfo
	req.target_verbatim = true

	url_text := target.url.text
	url_owned := ""
	if path_as_is {
		buffer := buffer_make(allocator, len(url_text) + 8)
		if !url_path_as_is_into(&buffer, url_text) {
			buffer_destroy(&buffer)
			return {}, .Out_Of_Memory
		}
		url_owned = string(buffer_owned(&buffer))
		url_text = url_owned
	}
	if !clone_into(&req.url_text, url_text, allocator) {
		delete(url_owned, allocator)
		return {}, .Out_Of_Memory
	}
	delete(url_owned, allocator)

	// The split httpie's model makes: the same rule the refused *hop* of a
	// follow is spelled by (`url_refused_target`), because it is the same
	// reader — `urlsplit` over the URL requests held.
	stripped := buffer_make(allocator, len(req.url_text))
	defer buffer_destroy(&stripped)
	if !url_unsafe_bytes_strip_into(&stripped, req.url_text) {
		request_destroy(&req)
		return {}, .Out_Of_Memory
	}
	// The parse removes the three bytes itself, so it wants a buffer of its
	// own; they are already out of `stripped`, so this one stays empty.
	scratch := buffer_make(allocator)
	defer buffer_destroy(&scratch)
	split, split_ok := url_refused_target(string(stripped.data[:]), &scratch)
	if !split_ok {
		request_destroy(&req)
		return {}, .Out_Of_Memory
	}
	if !clone_into(&req.path, split.path, allocator) ||
	   !clone_into(&req.query_raw, split.query, allocator) ||
	   !clone_into(&req.host, split.host, allocator) ||
	   !clone_into(&req.userinfo, split.userinfo, allocator) {
		request_destroy(&req)
		return {}, .Out_Of_Memory
	}
	return req, .None
}

// request_other_scheme_url spells the URL requests held for a scheme the port
// does not speak but requests *did* prepare. `prepare_url` builds it out of the
// pieces `parse_url` read — the scheme it lowercased, the authority it kept
// (`auth` + `@` + host + `:<port>` when the port is not zero, models.py:533-538)
// and the requoted path, query and fragment (models.py:560) — which is the URL
// `request_url` builds for the transport, with the two things the transport
// leaves out put back: the userinfo in front of the host, and the `#fragment`.
//
// Every piece is written through requests' `requote_uri` (`url_requote_decided_into`),
// which is what `prepared_request.url` is — the host was already requoted by the
// host rule, with the same whole-URL decision, and `Host` is that same string
// (models.py:150, `netloc.split('@')[-1]`). The fragment takes the requote alone:
// urllib3's `parse_url` never ran `_encode_invalid_chars` over it (`_FRAGMENT_CHARS`
// exists only for `_encode_target`), so a `%2f` of its own survives as it is
// written where the path's would be uppercased.
//
// The *same* bytes are written a second time, through the other half of that same
// composition: `url_unquoted_into` writes `unquote_unreserved`'s output, which is
// the string CPython's `quote` is then handed and therefore the string its
// `UnicodeEncodeError` positions are counted in (`Request.url_unquoted`). The
// second string stops where the `name==value` items go in — right before the
// fragment, whose offset `items_at` is — because `prepare_url` appends the items
// to the query *before* the requote and the items do not exist yet.
//
// The caller owns both strings. False — `.Out_Of_Memory` — leaves both empty and
// both buffers released.
@(private)
request_other_scheme_url :: proc(
	req: ^Request,
	target: Target,
	allocator: mem.Allocator,
) -> (url_text: string, url_unquoted: string, items_at: int, err: Error) {
	buffer := buffer_make(allocator, 256)
	unquoted := buffer_make(allocator, 256)
	ok := true
	// Both buffers are dead on every path, including the two `buffer_owned` calls
	// below (which nil the buffer out) — a `buffer_destroy` of a dead buffer is a
	// no-op, so this `defer` covers the failure paths alone.
	defer if !ok {
		buffer_destroy(&buffer)
		buffer_destroy(&unquoted)
	}

	ok = url_location_write_scheme_into(&buffer, target.scheme_name) &&
	     url_location_write_scheme_into(&unquoted, target.scheme_name) &&
	     buffer_append_string(&buffer, "//") &&
	     buffer_append_string(&unquoted, "//")
	if !ok {
		return "", "", 0, .Out_Of_Memory
	}
	if req.userinfo != "" {
		ok = url_requote_decided_into(&buffer, req.userinfo, req.requote_fallback) &&
		     url_unquoted_into(&unquoted, req.userinfo, req.requote_fallback) &&
		     buffer_append_byte(&buffer, '@') &&
		     buffer_append_byte(&unquoted, '@')
		if !ok {
			return "", "", 0, .Out_Of_Memory
		}
	}
	ok = buffer_append_string(&buffer, req.host) && buffer_append_string(&unquoted, req.host)
	if req.port != 0 {
		ok = ok &&
		     buffer_append_byte(&buffer, ':') && buffer_append_int(&buffer, req.port) &&
		     buffer_append_byte(&unquoted, ':') && buffer_append_int(&unquoted, req.port)
	}
	if !ok {
		return "", "", 0, .Out_Of_Memory
	}

	target_text, target_err := request_target(req, allocator)
	if target_err != .None {
		return "", "", 0, target_err
	}
	defer delete(target_text, allocator)
	if !buffer_append_string(&buffer, target_text) {
		return "", "", 0, .Out_Of_Memory
	}
	// The path and the URL's own query for the *unquoted* half. `--path-as-is`
	// does not change it: the flag rewrites `prepared_request.url` after
	// `prepare_url` has already run (client.py:94-98), so the string `quote` was
	// handed still carries the path `parse_url` read — which for a scheme
	// urllib3 does not normalize is the argv path itself, '.' and '..' included.
	if !url_unquoted_into(&unquoted, req.path, req.requote_fallback) {
		return "", "", 0, .Out_Of_Memory
	}
	if req.query_raw != "" &&
	   (!buffer_append_byte(&unquoted, '?') ||
	    !url_unquoted_into(&unquoted, req.query_raw, req.requote_fallback)) {
		return "", "", 0, .Out_Of_Memory
	}
	// Everything after this belongs behind the items (see the proc's comment).
	items_at = len(unquoted.data)

	// The fragment, from the same `urlsplit` the head was split by. It is the
	// URL's own, not a `name==value` item: `prepare_url` appends the encoded
	// items to the *query* alone (models.py:550-557).
	fragment_scratch := buffer_make(allocator)
	defer buffer_destroy(&fragment_scratch)
	parsed, parsed_ok := url_location_parse(target.url.text, &fragment_scratch)
	if !parsed_ok {
		return "", "", 0, .Out_Of_Memory
	}
	if parsed.fragment != "" {
		ok = buffer_append_byte(&buffer, '#') &&
		     url_requote_decided_into(&buffer, parsed.fragment, req.requote_fallback) &&
		     buffer_append_byte(&unquoted, '#') &&
		     url_unquoted_into(&unquoted, parsed.fragment, req.requote_fallback)
		if !ok {
			return "", "", 0, .Out_Of_Memory
		}
	}
	return string(buffer_owned(&buffer)), string(buffer_owned(&unquoted)), items_at, .None
}

// request_set_path stores the request's owned copy of the URL's path, with
// urllib3's dot-segment removal applied to it — the reference reduces the path
// inside `parse_url`, before it is encoded and requoted, so `/a/../b` becomes
// the `/b` that is rendered and sent (util/url.py:551-553,
// `url_path_remove_dot_segments_into` in url.odin). `path_as_is` is the one way
// past it (httpie's flag of that name), and it is the *raw* path the request
// keeps then, because that is the path the reference puts back into its
// prepared URL (see request_create). The request owns the result, and releases
// it with the rest of its fields in request_destroy.
//
// `keep_dot_segments` is the second way past it, for a scheme urllib3 does not
// normalize: the reduction runs behind `if normalize_uri and path:`
// (util/url.py:517, :551), which is false for every scheme outside
// `_NORMALIZABLE_SCHEMES`, so `httpx://h/a/../b` keeps its dots — and its path
// is *still* requoted afterwards (`request_target`), unlike `--path-as-is`.
@(private)
request_set_path :: proc(
	req: ^Request,
	path: string,
	path_as_is: bool,
	keep_dot_segments: bool = false,
) -> bool {
	if path_as_is || keep_dot_segments {
		return clone_into(&req.path, path, req.allocator)
	}
	// Capacity is the path's own length: the removal only ever drops bytes, so
	// the buffer stays in this one allocation.
	buffer := buffer_make(req.allocator, len(path))
	defer buffer_destroy(&buffer)
	if !url_path_remove_dot_segments_into(&buffer, path) {
		return false
	}
	delete(req.path, req.allocator)
	req.path = string(buffer_owned(&buffer))
	return true
}

// request_add_query appends a `name==value` query item. The name and the value
// are stored raw; request_target percent-encodes them when the target is built.

request_add_query :: proc(req: ^Request, name: string, value: string) -> Error {
	param: Query_Param
	if !clone_into(&param.name, name, req.allocator) {
		return .Out_Of_Memory
	}
	if !clone_into(&param.value, value, req.allocator) {
		delete(param.name, req.allocator)
		return .Out_Of_Memory
	}
	if !slice_push(&req.query, param, req.allocator) {
		delete(param.name, req.allocator)
		delete(param.value, req.allocator)
		return .Out_Of_Memory
	}
	return .None
}

// request_header_unset reports whether the command line unset `name` — an item
// spelled `Name:` with an empty value, which the reference records as a `None`
// and drops before `requests` prepares anything
// (cli/requestitems.py:process_header_arg, cli/dicts.py:26-28,
// client.py:190-207). `requests` drops the key from the merged dict as well
// (`merge_setting` removes every `None`, sessions.py:85-110), so the name is
// gone from the prepared request — which is why `request_prepare` treats it as
// absent for the headers `requests` itself derives, and why the two httpie
// defaults of `make_default_headers` (client.py:263-278) have to ask: those
// are entries of the same dict the unset emptied, so they do not come back.
request_header_unset :: proc(req: ^Request, name: string) -> bool {
	for candidate in req.unset_headers {
		if strings.equal_fold(candidate, name) {
			return true
		}
	}
	return false
}

// request_unset_header records `name` as unset (owned by the request) unless it
// is already there. Order is command-line order, which nothing reads.
request_unset_header :: proc(req: ^Request, name: string) -> Error {
	if request_header_unset(req, name) {
		return .None
	}
	owned: string
	if !clone_into(&owned, name, req.allocator) {
		return .Out_Of_Memory
	}
	if !slice_push(&req.unset_headers, owned, req.allocator) {
		delete(owned, req.allocator)
		return .Out_Of_Memory
	}
	return .None
}

// request_header_skipped reports whether the entry `name`/`value` is a header
// urllib3 drops on the way out — and which the rendered head therefore leaves
// out too (models.py:153-157) — rather than a line that is sent.
//
// The *value* alone is not the test. urllib3 compares `isinstance(v, str) and v
// == SKIP_HEADER` (connection.py:477-487), and only a `None` in the dict
// becomes that `str`: `finalize_headers` replaces it (client.py:204-207) and
// leaves it un-encoded, while every *value* — a session file's stored sentinel
// included, which is read back as a `str` — is encoded to `bytes`
// (client.py:201-203) and so fails the same comparison. A session that recorded
// a sentinel therefore sends the literal text, and only an item on the command
// line that unset a skippable name (request_header_unset) is magic. That is the
// mechanism behind the asymmetry the parity harness pins: a `User-Agent:` item
// sends no line, while the `User-Agent: @@@SKIP_HEADER@@@` a session file holds
// is sent as it stands.
request_header_skipped :: proc(req: ^Request, name, value: string) -> bool {
	return (
		value == SKIP_HEADER &&
		is_skippable_header(name) &&
		request_header_unset(req, name) \
	)
}

// request_remove_headers drops every entry `name` carries: the dict assignment
// a `None` value performs keeps no value for the name (`self[key] = None`,
// cli/dicts.py:26-28). It reports the index of the first entry it dropped, or
// -1 when there was none, and how many it dropped — build_request needs the
// first to keep the session-header boundary straight.
request_remove_headers :: proc(req: ^Request, name: string) -> (first: int, count: int) {
	first = -1
	kept := 0
	for i in 0 ..< len(req.headers) {
		header := req.headers[i]
		if strings.equal_fold(header.name, name) {
			if first < 0 {
				first = i
			}
			count += 1
			delete(header.name, req.allocator)
			delete(header.value, req.allocator)
			continue
		}
		req.headers[kept] = header
		kept += 1
	}
	req.headers = req.headers[:kept]
	return first, count
}

// request_insert_header writes a header in at `index`, keeping the caller's
// spelling — the place a name's slot has in httpie's request dict when the port
// has to put it back after an unset removed it (the slot `User-Agent` holds in
// `make_default_headers`, before the session's headers).
request_insert_header :: proc(req: ^Request, index: int, name: string, value: string) -> Error {
	if index < 0 || index > len(req.headers) {
		return request_add_header(req, name, value)
	}
	header: Header
	if !clone_into(&header.name, name, req.allocator) {
		return .Out_Of_Memory
	}
	if !clone_into(&header.value, value, req.allocator) {
		delete(header.name, req.allocator)
		return .Out_Of_Memory
	}
	if !slice_push(&req.headers, Header{}, req.allocator) {
		delete(header.name, req.allocator)
		delete(header.value, req.allocator)
		return .Out_Of_Memory
	}
	for i := len(req.headers) - 1; i > index; i -= 1 {
		req.headers[i] = req.headers[i - 1]
	}
	req.headers[index] = header
	return .None
}

// request_add_header appends a header, keeping the caller's spelling and order.
// `str_value` marks a value httpie still has as text when CPython writes the
// request line by line (Header.str_value): every header built from an item, the
// session or the command line is bytes, which is the default.
request_add_header :: proc(req: ^Request, name: string, value: string, str_value := false) -> Error {
	header: Header
	header.str_value = str_value
	if !clone_into(&header.name, name, req.allocator) {
		return .Out_Of_Memory
	}
	if !clone_into(&header.value, value, req.allocator) {
		delete(header.name, req.allocator)
		return .Out_Of_Memory
	}
	if !slice_push(&req.headers, header, req.allocator) {
		delete(header.name, req.allocator)
		delete(header.value, req.allocator)
		return .Out_Of_Memory
	}
	return .None
}

// request_set_header gives `name` the single value `value`: an entry the request
// already carries under that name is released, so the value the caller sets is
// the only one — and it is stored under the caller's spelling, which is what the
// reference renders (it assigns into a case-insensitive dict).
// request_prepare uses it for the Content-Length `requests` derives from the
// body, which *replaces* whatever the CLI or the session put there
// (requests/models.py:499-513).

request_set_header :: proc(req: ^Request, name: string, value: string) -> Error {
	kept := 0
	for i in 0 ..< len(req.headers) {
		header := req.headers[i]
		if strings.equal_fold(header.name, name) {
			delete(header.name, req.allocator)
			delete(header.value, req.allocator)
			continue
		}
		req.headers[kept] = header
		kept += 1
	}
	req.headers = req.headers[:kept]
	return request_add_header(req, name, value)
}

// request_assign_header is the assignment into a case-insensitive dict: the
// entry the request already carries under `name` keeps its place and takes the
// new value — the first one, when the list carries several, which the
// assignment collapses into this single entry — and a request without one gains
// the header at the end. The value is stored under the caller's spelling,
// because the key that renders is the one that was assigned.
//
// request_set_header appends instead, which is what `requests` does to the
// length it derives: it assigns into the header dict it built from scratch
// (requests/models.py:499-513), while httpie's multipart branch assigns into the
// dict it already merged the session and the items into (client.py:353-358), so
// that Content-Type keeps the place of the entry it replaces.
request_assign_header :: proc(req: ^Request, name: string, value: string) -> Error {
	first := -1
	for header, i in req.headers {
		if strings.equal_fold(header.name, name) {
			first = i
			break
		}
	}
	if first < 0 {
		return request_add_header(req, name, value)
	}

	// The two clones come first: a failed allocation leaves the list as it was.
	owned_name: string
	if !clone_into(&owned_name, name, req.allocator) {
		return .Out_Of_Memory
	}
	owned_value: string
	if !clone_into(&owned_value, value, req.allocator) {
		delete(owned_name, req.allocator)
		return .Out_Of_Memory
	}
	delete(req.headers[first].name, req.allocator)
	delete(req.headers[first].value, req.allocator)
	req.headers[first] = {name = owned_name, value = owned_value}

	// Every later occurrence is released: a dict assignment leaves one entry
	// under the name, and it is the one it assigned.
	kept := first + 1
	for i in first + 1 ..< len(req.headers) {
		header := req.headers[i]
		if strings.equal_fold(header.name, name) {
			delete(header.name, req.allocator)
			delete(header.value, req.allocator)
			continue
		}
		req.headers[kept] = header
		kept += 1
	}
	req.headers = req.headers[:kept]
	return .None
}

// request_strip_header_values applies httpie's `finalize_headers` to every value
// the request carries (client.py:192-209): the surrounding whitespace comes off
// each one, and nothing else changes. The reference runs it once, right after
// its own defaults, the session's headers and the items have been merged into
// the request dict, so the values that reach the wire are the stripped ones —
// and so are the values `Session.update_headers` records back (client.py:75).
//
// `finalize_headers` does not stop at the strip: it encodes every finalized
// value back to bytes with the default codec (client.py:203), so a value that is
// not valid UTF-8 — a byte the argv decode turned into a lone surrogate — raises
// the UnicodeEncodeError that ends the run. The port's value stays a string, but
// the check is the reference's: it runs on the stripped value, in header order,
// and the position it reports is the character's index *in that value*.
//
// The port runs it at the same point in build_request, before anything reads
// the list: output.order_request_headers reorders the same list the transport
// sends, so the rendered head and the wire cannot disagree.
request_strip_header_values :: proc(req: ^Request) -> Error {
	for i in 0 ..< len(req.headers) {
		stripped := header_value_strip(req.headers[i].value)
		if err := request_encode_check(req, stripped, .Utf8); err != .None {
			return err
		}
		if len(stripped) == len(req.headers[i].value) {
			// The common case: there is nothing to strip, so the value stays
			// exactly where it is.
			continue
		}
		replacement: string
		if !clone_into(&replacement, stripped, req.allocator) {
			return .Out_Of_Memory
		}
		delete(req.headers[i].value, req.allocator)
		req.headers[i].value = replacement
	}
	return .None
}

// header_value_strip is the argument-less Python `str.strip()` the reference
// applies to a header value: the characters `str.isspace()` accepts come off
// both ends — the ASCII whitespace (space, tab, newline, vertical tab, form
// feed, carriage return), the four control separators U+001C-U+001F, and the
// Unicode whitespace U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029,
// U+202F, U+205F and U+3000.
// `trim_space` is the ASCII half of that set only, so it is *not* the same rule.
//
// The result is a slice of `value`: nothing is allocated.
header_value_strip :: proc(value: string) -> string {
	start := 0
	for start < len(value) {
		is_space, width := header_value_rune(value[start:])
		if !is_space {
			break
		}
		start += width
	}
	// The tail is trimmed by walking the rest one rune at a time and remembering
	// where the last rune that is *not* whitespace ends: that is where the value
	// stops, whatever whitespace follows it.
	end := start
	index := start
	for index < len(value) {
		is_space, width := header_value_rune(value[index:])
		index += width
		if !is_space {
			end = index
		}
	}
	return value[start:end]
}

// header_value_rune decodes the rune at the front of `text` and answers the two
// things the strip needs: whether it is one of Python's whitespace characters
// (`str.isspace()` — a closed set of 29 code points), and how many bytes it
// takes. `text` must be non-empty; `width` is at least 1 otherwise (an invalid
// byte decodes as the error rune with width 1, and it is not whitespace, which
// is what Python's `surrogateescape` decode reaches too).
//
// The set is Python's `\s` as well as its `str.isspace()`, so the header-name
// half of `check_header_validity` asks the same question with it
// (src/http/header_validity.odin) — which is why it is package-private rather
// than private to this file.
@(private = "package")
header_value_rune :: proc(text: string) -> (is_space: bool, width: int) {
	if len(text) == 0 {
		return false, 1
	}
	// The ASCII half first: it is the whole set for an ordinary header value.
	switch text[0] {
	case 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x1c, 0x1d, 0x1e, 0x1f:
		return true, 1
	}
	code, size := utf8.decode_rune_in_string(text)
	if size <= 0 {
		return false, 1
	}
	switch code {
	case 0x85, 0xa0, 0x1680, 0x2000 ..= 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000:
		return true, size
	}
	return false, size
}

// request_method is the verb that goes in the request line and on the wire:
// `method_raw` when the caller set one, the enum's spelling otherwise.
request_method :: proc(req: ^Request) -> string {
	if req.method_raw != "" {
		return req.method_raw
	}
	return method_to_string(req.method)
}

// method_may_have_body reports whether requests would announce
// `Content-Length: 0` for a request that carries no body: every method but GET,
// HEAD and OPTIONS, whose absence of a body is already implied
// (requests/models.py prepare_content_length, plus httpie's removal of the
// header for OPTIONS in client.py:36,215-230).
method_may_have_body :: proc(method: string) -> bool {
	return method != "GET" && method != "HEAD" && method != "OPTIONS"
}

// request_set_method_raw stores the caller's verb (already upper-cased).
request_set_method_raw :: proc(req: ^Request, raw: string) -> Error {
	if !clone_into(&req.method_raw, raw, req.allocator) {
		return .Out_Of_Memory
	}
	return .None
}

// request_set_content_type_item stores the CLI's own `Content-Type` item — the
// one a multipart body's Content-Type is built from (body.odin's
// multipart_content_type). The value is kept verbatim, whitespace included: the
// reference strips it where the multipart value is built.
request_set_content_type_item :: proc(req: ^Request, value: string) -> Error {
	if !clone_into(&req.content_type_item, value, req.allocator) {
		return .Out_Of_Memory
	}
	return .None
}

// request_header_get is httpie's case-insensitive header lookup: names compare
// case-insensitively, the spelling on the wire stays the caller's.
request_header_get :: proc(req: ^Request, name: string) -> (value: string, found: bool) {
	for header in req.headers {
		if strings.equal_fold(header.name, name) {
			return header.value, true
		}
	}
	return "", false
}

// request_add_items records the request's data items. The CLI applies the item
// grammar (docs/PARITY.md §3) and hands the parsed items over; request_prepare
// turns them into the wire body.

request_add_items :: proc(req: ^Request, items: []Data_Item) -> Error {
	for item in items {
		owned: Data_Item
		owned.kind = item.kind
		if !clone_into(&owned.name, item.name, req.allocator) ||
		   !clone_into(&owned.value, item.value, req.allocator) ||
		   !clone_into(&owned.filename, item.filename, req.allocator) ||
		   !clone_into(&owned.mime, item.mime, req.allocator) {
			data_item_destroy(&owned, req.allocator)
			return .Out_Of_Memory
		}
		// The lone surrogates the value's bytes cannot hold are owned like the
		// value itself (and like the CLI's clone of the same list).
		if len(item.lone) > 0 {
			owned.lone = make([]Lone_Surrogate, len(item.lone), req.allocator)
			copy(owned.lone, item.lone)
		}
		if !slice_push(&req.items, owned, req.allocator) {
			data_item_destroy(&owned, req.allocator)
			return .Out_Of_Memory
		}
	}
	req.body_source = .Items
	return .None
}

// request_set_raw_body makes `data` the whole request body, verbatim (`--raw`
// or a bare `@file`). `content_type` is what the caller decided the body is —
// "application/json" for `--raw` in JSON mode, the extension's guess for a bare
// `@file`; "" leaves Content-Type unset.

request_set_raw_body :: proc(req: ^Request, data: []byte, content_type: string) -> Error {
	body, err := make([]byte, len(data), req.allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	copy(body, data)
	delete(req.body, req.allocator)
	req.body = body

	if !clone_into(&req.body_content_type, content_type, req.allocator) {
		return .Out_Of_Memory
	}
	req.body_source = .Raw
	return .None
}

// request_set_auth stores the credentials. `auth` is "user:pass" for basic and
// digest, and the token for bearer.

request_set_auth :: proc(req: ^Request, auth: string, auth_type: Auth_Type) -> Error {
	if !clone_into(&req.auth, auth, req.allocator) {
		return .Out_Of_Memory
	}
	req.auth_type = auth_type
	return .None
}

// request_credentials is the "user:pass" the request authenticates with:
// --auth wins, the URL's userinfo is the fallback (httpie's rule).
request_credentials :: proc(req: ^Request) -> string {
	if req.auth != "" {
		return req.auth
	}
	return req.userinfo
}

// request_prepare finishes the request: it encodes the body (when it comes from
// items) and adds the headers httpie derives from the request itself —
// Content-Length, Accept, Authorization and Content-Type. A header the caller
// supplied wins, case-insensitively. Calling it twice is a no-op.

request_prepare :: proc(req: ^Request) -> Error {
	if req.body_source == .Items {
		if len(req.items) == 0 && req.body_kind != .Multipart {
			// No items and no multipart framing: no body, no Content-Type.
			// httpie asks for JSON only when it is actually sending a JSON body.
			req.body_source = .None
		} else if err := body_encode_items(req); err != .None {
			return err
		}
	}

	// --compress deflates the encoded body before Content-Length is derived
	// from it (uploads.py:252-269; httpie compresses the prepared request, so
	// the length it announces is the compressed one).
	if err := body_compress(req); err != .None {
		return err
	}

	has_body := req.body_source != .None

	// Content-Length. Three cases, all from requests' prepare_content_length
	// plus httpie's OPTIONS special case (client.py:36, :215-230):
	//   * a body of known length announces it — as an assignment, so an item or
	//     a session header that spelled the name out is *replaced* rather than
	//     kept (requests/models.py:652-666);
	//   * a chunked upload announces no length at all — the framing carries it
	//     (only `--offline` keeps the length, because httpie only adds the
	//     Transfer-Encoding header itself there);
	//   * no body at all still announces `0` for every method that may carry
	//     one, which is every method but GET, HEAD and OPTIONS, and only when
	//     the request carries no length of its own.
	//
	// "No body at all" is requests' `body is None`, and a `--chunked` request
	// is never that: `prepare_request_body` hands requests a *stream* whatever
	// the items are — with none at all, `raw_body` is `b''` and the `elif
	// chunked:` branch still wraps it, `ChunkedUploadStream(stream=iter([b'']))`
	// (uploads.py:221-224) — and a ChunkedUploadStream is not None and not
	// falsy, so `prepare_content_length` takes its `if body is not None`
	// branch, finds no length and adds nothing (requests/models.py:652-666).
	// That is also why the *stream* upload is the test below rather than the
	// bytes: with no items `req.body` is empty for a chunked POST just as it
	// is for a POST that never had a body, and only the first of the two is
	// framed.
	chunked_upload := req.chunked && !req.offline
	if len(req.body) > 0 && !chunked_upload {
		number: [24]u8
		length_text := strconv.write_int(number[:], i64(len(req.body)), 10)
		if err := request_set_header(req, "Content-Length", length_text); err != .None {
			return err
		}
		req.content_length_derived = true
	} else if _, found := request_header_get(req, "Content-Length"); !found {
		if len(req.body) == 0 && !chunked_upload && method_may_have_body(request_method(req)) {
			// requests sets no length unless it is non-zero, so an empty body
			// is indistinguishable from no body: `if length:` falls through to
			// the zero header below.
			if err := request_add_header(req, "Content-Length", "0"); err != .None {
				return err
			}
		}
	}

	// --chunked asks for a chunked request body. httpie sets the header itself
	// in offline mode and lets requests derive it otherwise; either way the
	// header is `Transfer-Encoding: chunked` and there is no Content-Length.
	// Which of the two added it decides the header's position in the head, so
	// the derived case is recorded (see Request.transfer_encoding_derived):
	// only the online upload is requests' own header.
	// httpie's own Transfer-Encoding is guarded by its dict key existing at all
	// — `if args.offline and args.chunked and 'Transfer-Encoding' not in
	// headers` (client.py:347-350) — so an item that unset the name blocks it
	// (`Name:` left the key there with a `None`). The online upload's framing
	// header is requests' own: it is assigned while the streamed body is
	// prepared, after `merge_setting` dropped the `None` pair, so it comes back.
	if req.chunked && !(req.offline && request_header_unset(req, "Transfer-Encoding")) {
		if _, found := request_header_get(req, "Transfer-Encoding"); !found {
			if err := request_add_header(req, "Transfer-Encoding", "chunked"); err != .None {
				return err
			}
			req.transfer_encoding_derived = !req.offline
		}
	}

	// The automatic Accept is httpie's own dict entry (`make_default_headers`,
	// client.py:263-278), and requests' session default is dropped by
	// `merge_setting` for the same reason (sessions.py:85-110), so an item that
	// unset the name leaves the request with no Accept at all.
	if _, found := request_header_get(req, "Accept"); !found && !request_header_unset(req, "Accept") {
		accept := req.json_accept ? JSON_ACCEPT : NON_JSON_ACCEPT
		if err := request_add_header(req, "Accept", accept); err != .None {
			return err
		}
	}

	if _, found := request_header_get(req, "Authorization"); !found {
		authorization, applicable := authorization_header(req)
		// The credentials are the one string the auth scheme encodes itself:
		// a pair that is not valid UTF-8 raises inside the reference's plugin
		// (plugins/builtin.py:33) after the body has been prepared and before
		// anything is rendered — request_encode_check recorded it.
		if req.encode_error.failed {
			return .Str_Not_Encodable
		}
		if applicable {
			defer delete(authorization, req.allocator)
			// The reference's plugin assigns this value *after* the headers
			// were finalized, so it is the one value that reaches
			// `http.client.putheader` as a `str` (Header.str_value).
			if err := request_add_header(req, "Authorization", authorization, true); err != .None {
				return err
			}
		}
	}

	// The body's Content-Type is httpie's own default as well — a JSON request
	// type, a JSON body, a `@file` body or a form without file fields
	// (client.py:263-278) — so an item that unset the name leaves the body
	// without one. A multipart body never reaches this branch: it assigned its
	// Content-Type above, because the CLI's own item is what that value is
	// built from (client.py:353-358), and that assignment comes *after* the
	// finalized dict dropped the unset pair, so it wins.
	if _, found := request_header_get(req, "Content-Type"); !found &&
	   !request_header_unset(req, "Content-Type") && has_body && req.body_content_type != "" {
		if err := request_add_header(req, "Content-Type", req.body_content_type); err != .None {
			return err
		}
	}

	return .None
}

// request_check_query_items is the half of requests' `prepare_url` that can
// fail: `_encode_params` encodes every `name==value` item — the name first, then
// the value, item by item — with the default utf-8 codec (models.py:171-186,
// called from models.py:550), so a byte that is not valid UTF-8 raises there.
// requests prepares the URL for *every* invocation, whether or not anything is
// printed and before the body and the auth are prepared, so the port checks the
// items there too: build_request calls this right after the header values and
// before request_prepare, which is the same order (make_request_kwargs, then
// prepare_url, then prepare_body, then prepare_auth).
//
// request_target re-checks each item where it encodes it; this is the earlier,
// unconditional call, which is what keeps an invocation that renders no request
// at all (`-p b`) failing exactly as the reference does.
request_check_query_items :: proc(req: ^Request) -> Error {
	for param in req.query {
		if err := request_encode_check(req, param.name, .Utf8); err != .None {
			return err
		}
		if err := request_encode_check(req, param.value, .Utf8); err != .None {
			return err
		}
	}
	return .None
}

// request_check_other_scheme_url is the other half of requests' `prepare_url`
// that can fail, for the one URL kind that reaches it with a string the port did
// not write byte by byte: the `.Other_Scheme` branch hands the whole
// reconstruction to `requote_uri`, which is `quote(unquote_unreserved(url),
// safe=…)` (utils.py:704-723, models.py:560) — and CPython's `quote` encodes
// that string with `errors='strict'`, so a character utf-8 has no encoding for
// raises `UnicodeEncodeError` there, before any adapter is looked up and before
// anything is rendered.
//
// The character is the lone surrogate PEP 383 made of an argv byte that is not
// valid UTF-8 (docs/PARITY.md §3.6, the str layer), and the position the
// exception carries is its **code point index in the string `quote` was handed**
// — the *unquoted* reconstruction `request_other_scheme_url` keeps, not the argv
// URL and not the requoted one (`httpx://127.0.0.1:9/a b\xff` reports 23, where
// the space is one character and the URL spells it `%20`; `…/a%41\xff` reports 22,
// because `unquote_unreserved` turns `%41` back into `A` first; and the exception
// reports the longest *run* of such characters, which `str_encode_failure`
// collapses the same way).
//
// The `name==value` items are inside that string: `_encode_params` appends them
// to the query before `urlunparse` (models.py:550-558), so their length counts
// for a character that sits behind them — in the fragment, the only place one can
// (`url_unquoted_items_at` is where they go). An item that cannot be encoded
// itself raises *earlier*, inside `_encode_params`, which is
// request_check_query_items' half — and that half is checked first, below.
//
// The host is the one component that never reaches here: requests' own IDNA step
// refuses a host that is not ASCII before the reconstruction is built
// (models.py:526-532, `url_host_normalize_flat`'s `.Invalid_Label`).
//
// This is where requests raises it, and the port reaches it at the same point:
// build_request calls it immediately after the query items, before the header
// validity check, the body and the auth — and it runs whether or not anything is
// printed, which is what keeps `-p b` and `--offline` failing as the reference
// does (nothing of the request is on stdout then).
request_check_other_scheme_url :: proc(req: ^Request) -> Error {
	if req.url_kind != .Other_Scheme || req.url_unquoted == "" {
		return .None
	}
	// No items: what the URL builder kept is the whole of what `quote` is handed.
	if len(req.query) == 0 {
		return request_encode_check(req, req.url_unquoted, .Utf8)
	}

	// The items are spliced in at the offset the builder recorded, spelled
	// exactly as `request_target` spells them (the same rule, the same
	// separators: the '?' the query gets when the URL carried none, and an '&'
	// before every item the URL's own query does not already lead).
	buffer := buffer_make(req.allocator, len(req.url_unquoted) + 32)
	defer buffer_destroy(&buffer)
	items_at := req.url_unquoted_items_at
	if !buffer_append_string(&buffer, req.url_unquoted[:items_at]) {
		return .Out_Of_Memory
	}
	if req.query_raw == "" && !buffer_append_byte(&buffer, '?') {
		return .Out_Of_Memory
	}
	for param, i in req.query {
		if (i > 0 || req.query_raw != "") && !buffer_append_byte(&buffer, '&') {
			return .Out_Of_Memory
		}
		if !url_encode_into(&buffer, param.name) ||
		   !buffer_append_byte(&buffer, '=') ||
		   !url_encode_into(&buffer, param.value) {
			return .Out_Of_Memory
		}
	}
	if !buffer_append_string(&buffer, req.url_unquoted[items_at:]) {
		return .Out_Of_Memory
	}
	return request_encode_check(req, string(buffer.data[:]), .Utf8)
}

// request_target is the request-target: the path plus the query, with the
// `name==value` items percent-encoded and appended to whatever query the URL
// already carried. The caller owns the returned string.
//
// The path and the URL's own query go through the URL's requoting rule —
// urllib3's `_encode_invalid_chars` and requests' `requote_uri`, which is
// `url_component_quote_into` (src/http/url.odin): a space, a non-ASCII character
// or a stray `%` is percent-encoded, an escape the URL already carried keeps its
// octet and gains uppercase hex, and an escape that spells an unreserved
// character is unquoted again. It is the same string requests puts on the wire
// and httpie renders (models.py:143-147 reads the *prepared* URL's path). The
// items are the other rule: requests encodes them as text (methods below), which
// raises instead of quoting.
//
// `requote_fallback` — the decision `url_host_normalize` took for this URL
// (`url_host_normalize`'s out-param, `http.Request.requote_fallback`) — is the
// third case of that requote, and it is not any one component's: requests hands
// the *whole* prepared URL to `requote_uri` (models.py:560), so one unreadable
// window behind a '%' in the netloc makes the path, the URL's own query *and* the
// items spell every '%' of theirs as `%25` and skip the unquoting
// (`url_component_quote_into`'s `requote_fallback`, and the pass the item bytes
// get here). docs/PARITY.md §3.6, kanban t_75b15cf5.
//
// Two cases keep the path as it stands instead, and they are different rules
// that meet here:
//
//   - `target_verbatim` (a followed hop): the path and the URL's own query are
//     already in the spelling requests prepared the hop's URL with, and that
//     spelling is the one the history renders.
//   - `path_as_is` (`--path-as-is`): the path is the *argv* URL's, not the
//     prepared one — httpie replaces the prepared URL's path component with
//     `urlparse(args.url).path` (client.py:94-98, `ensure_path_as_is`), so the
//     path is neither reduced nor requoted: `GET /a/./b c`, `GET /a/%2e/b`.
//     The URL's own query is *not* part of that replacement (urlunparse keeps
//     the prepared one), so it is requoted like any other — which is why this
//     branch is the path's alone, not target_verbatim's. What the connection
//     sends is that path encoded once, with no requote after it: urllib3's
//     `_encode_target` (util/url.py:453-467), which the transport applies
//     (`url_wire_url_into` on the prepared URL, docs/PARITY.md §3.6).
//
// A scheme urllib3 does not normalize (`Url_Kind.Other_Scheme`) is the third:
// `parse_url`'s two `_encode_invalid_chars` calls sit behind
// `if normalize_uri and …` (util/url.py:517-555), which that scheme turns false,
// so the path and the URL's own query reach requests' `requote_uri` as they were
// spelled. `url_requote_decided_into` is that pass alone — a `%2f` keeps its
// lowercase hex, where the path rule of an http URL would hand back `%2F` — and
// the netloc is spelled by the same one pass (`request_other_scheme_url`).
request_target :: proc(req: ^Request, allocator: mem.Allocator) -> (string, Error) {
	// The one decision this target honours, read once: the URL's requote took
	// its except-branch, so the path, the URL's own query and the items all
	// spell their '%' as `%25` and none of them is unquoted.
	fallback := req.requote_fallback
	requote_only := req.url_kind == .Other_Scheme
	buffer := buffer_make(allocator, len(req.path) + 16)
	if req.target_verbatim || req.path_as_is {
		if !buffer_append_string(&buffer, req.path) {
			return "", .Out_Of_Memory
		}
	} else if requote_only {
		if !url_requote_decided_into(&buffer, req.path, fallback) {
			return "", .Out_Of_Memory
		}
	} else if !url_component_quote_into(&buffer, req.path, .Path, fallback) {
		return "", .Out_Of_Memory
	}

	if req.query_raw != "" || len(req.query) > 0 {
		if !buffer_append_byte(&buffer, '?') {
			buffer_destroy(&buffer)
			return "", .Out_Of_Memory
		}
		if req.target_verbatim {
			if !buffer_append_string(&buffer, req.query_raw) {
				buffer_destroy(&buffer)
				return "", .Out_Of_Memory
			}
		} else if requote_only {
			if !url_requote_decided_into(&buffer, req.query_raw, fallback) {
				buffer_destroy(&buffer)
				return "", .Out_Of_Memory
			}
		} else if !url_component_quote_into(&buffer, req.query_raw, .Query, fallback) {
			buffer_destroy(&buffer)
			return "", .Out_Of_Memory
		}
		for param, i in req.query {
			if i > 0 || req.query_raw != "" {
				if !buffer_append_byte(&buffer, '&') {
					buffer_destroy(&buffer)
					return "", .Out_Of_Memory
				}
			}
			if err := request_encode_check(req, param.name, .Utf8); err != .None {
				buffer_destroy(&buffer)
				return "", err
			}
			if err := request_encode_check(req, param.value, .Utf8); err != .None {
				buffer_destroy(&buffer)
				return "", err
			}
			item_start := len(buffer.data)
			if !url_encode_into(&buffer, param.name) ||
			   !buffer_append_byte(&buffer, '=') ||
			   !url_encode_into(&buffer, param.value) {
				buffer_destroy(&buffer)
				return "", .Out_Of_Memory
			}
			if fallback {
				// The item's bytes are inside the string requests requotes as
				// well: `_encode_params`' `quote_plus` output is appended to the
				// query *before* `urlunparse`, so the except-branch's `quote`
				// sees its '%' too and doubles it (`y==%41` → `y=%252541`).
				url_quote_literal_percents_into(&buffer, item_start)
			}
		}
	}
	return string(buffer_owned(&buffer)), .None
}

// request_url is the absolute URL the transport requests: no userinfo (the
// credentials travel in the Authorization header or in libcurl's auth options),
// and the port only when the URL spelled one out.
request_url :: proc(req: ^Request, allocator: mem.Allocator) -> (string, Error) {
	target, target_err := request_target(req, allocator)
	if target_err != .None {
		return "", target_err
	}
	defer delete(target, allocator)

	buffer := buffer_make(allocator, len(req.host) + len(target) + 16)
	if !buffer_append_string(&buffer, scheme_to_string(req.scheme)) ||
	   !buffer_append_string(&buffer, "://") ||
	   !buffer_append_string(&buffer, req.host) {
		buffer_destroy(&buffer)
		return "", .Out_Of_Memory
	}
	if req.port != 0 {
		if !buffer_append_byte(&buffer, ':') || !buffer_append_int(&buffer, req.port) {
			buffer_destroy(&buffer)
			return "", .Out_Of_Memory
		}
	}
	if !buffer_append_string(&buffer, target) {
		buffer_destroy(&buffer)
		return "", .Out_Of_Memory
	}
	return string(buffer_owned(&buffer)), .None
}

// host_header_value is the Host header httpie derives. Its value is the
// **prepared** URL's netloc with its userinfo stripped — httpie prints
// `urlsplit(self._orig.url).netloc.split('@')[-1]` (models.py:141-151) — and
// requests spells that netloc as the host plus `:<port>` whenever the port
// `parse_url` read is *not zero*: `netloc += f":{port}"` behind `if port:`
// (requests/models.py:533-538), over the `port_int` of `util/url.py:542-547`.
//
// Two things follow, and neither is about the scheme: an explicit `:80` under
// `http` / `:443` under `https` is *kept*, because the scheme's default port is
// no branch of that road, and a padded `:0080` contributes the value `int()`
// gave (requests did not keep the text), which is the spelling that reaches the
// prepared URL. A port spelled as zeros is dropped — `:0`, `:00000` and `:000`
// alike — because the reference's test is the value, not the spelling, and an
// authority that spelled no port at all is the same `host` on its own.
//
// `port` is the value `url_host_port_value` read out of the authority, and 0 is
// where "no port" and "a zero port" meet — deliberately, since the reference
// writes the same header for both. The caller owns the returned string.
host_header_value :: proc(host: string, port: int, allocator: mem.Allocator) -> (string, Error) {
	// Both branches hand back a string the caller releases with `delete(..,
	// allocator)`; request_destroy is what does it for the request's own header.
	if port == 0 {
		host_clone, host_clone_err := strings.clone(host, allocator)
		return host_clone, host_clone_err == .None ? Error.None : Error.Out_Of_Memory
	}
	buffer := buffer_make(allocator, len(host) + 8)
	if !buffer_append_string(&buffer, host) || !buffer_append_byte(&buffer, ':') ||
	   !buffer_append_int(&buffer, port) {
		buffer_destroy(&buffer)
		return "", .Out_Of_Memory
	}
	return string(buffer_owned(&buffer)), .None
}

// request_host_header is host_header_value for the request's own authority:
// `host` and `port` are what `request_create` took off the URL (see
// request_create), which is also why the port is kept in the authority the
// transport is handed. The caller owns the returned string.
request_host_header :: proc(req: ^Request, allocator: mem.Allocator) -> (string, Error) {
	return host_header_value(req.host, req.port, allocator)
}

// request_destroy releases everything request_create and the builder procs
// allocated and zeroes the struct, so destroying twice is a no-op.
request_destroy :: proc(req: ^Request) {
	if req == nil {
		return
	}
	for &header in req.headers {
		delete(header.name, req.allocator)
		delete(header.value, req.allocator)
	}
	for &param in req.query {
		delete(param.name, req.allocator)
		delete(param.value, req.allocator)
	}
	for &item in req.items {
		data_item_destroy(&item, req.allocator)
	}
	delete(req.host, req.allocator)
	delete(req.path, req.allocator)
	delete(req.userinfo, req.allocator)
	delete(req.query_raw, req.allocator)
	delete(req.headers, req.allocator)
	delete(req.query, req.allocator)
	delete(req.items, req.allocator)
	delete(req.body, req.allocator)
	delete(req.body_content_type, req.allocator)
	delete(req.boundary, req.allocator)
	delete(req.content_type_item, req.allocator)
	delete(req.method_raw, req.allocator)
	delete(req.auth, req.allocator)
	// req.wire_error.text is the one string the wire rule owns (the offending
	// header name or value, cloned when the transport refused it).
	delete(req.wire_error.text, req.allocator)
	// req.adapter_error.url is the target requests had no adapter for, cloned
	// by the transport's redirect loop where the refusal was recorded — or the
	// request's own URL for the argv form (`adapterless_failure`).
	delete(req.adapter_error.url, req.allocator)
	// req.url_text is the URL requests held for a request the port has no
	// adapter for (the refusal's URL, and the spelling the head was split
	// from); "" for every request that has an adapter.
	delete(req.url_text, req.allocator)
	// req.url_unquoted is the string `quote` was handed for an `.Other_Scheme`
	// URL — the spelling `UnicodeEncodeError`'s position is counted in.
	// req.unset_headers holds the names the command line unset (`Header:`);
	// each is owned like a header name.
	for name in req.unset_headers {
		delete(name, req.allocator)
	}
	delete(req.unset_headers, req.allocator)
	delete(req.url_unquoted, req.allocator)
	// req.follow_history is the transport's chain for a follow that failed: the
	// entries own their strings exactly like Response.history's do.
	for &hop in req.follow_history {
		exchange_destroy(&hop, req.allocator)
	}
	delete(req.follow_history, req.allocator)
	// req.proxy / req.cert / req.cert_key / req.cert_key_pass are BORROWED
	// from cli.Options (the session aliases them in, see session/context.odin);
	// cli.options_destroy owns and frees them. Freeing them here as well is a
	// double free, and that is exactly what used to crash every `--cert` run at
	// exit (docs/ARCHITECTURE.md §4, the ownership table).
	req^ = {}
}

// data_item_destroy releases one item's strings. It zeroes the item, so a
// second call is safe.
data_item_destroy :: proc(item: ^Data_Item, allocator: mem.Allocator) {
	if item == nil {
		return
	}
	delete(item.name, allocator)
	delete(item.value, allocator)
	delete(item.filename, allocator)
	delete(item.mime, allocator)
	delete(item.lone, allocator)
	item^ = {}
}

// response_destroy releases a response produced by send, including its redirect
// history. A zero Response is valid input, so callers may always
// `defer response_destroy(&res)`.
response_destroy :: proc(res: ^Response) {
	if res == nil {
		return
	}
	for &header in res.headers {
		delete(header.name, res.allocator)
		delete(header.value, res.allocator)
	}
	for &exchange in res.history {
		exchange_destroy(&exchange, res.allocator)
	}
	delete(res.reason, res.allocator)
	delete(res.http_version, res.allocator)
	delete(res.url, res.allocator)
	delete(res.headers, res.allocator)
	delete(res.history, res.allocator)
	delete(res.body, res.allocator)
	res^ = {}
}
