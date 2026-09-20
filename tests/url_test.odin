package tests

import "core:mem"
import "core:testing"

import "src:http"

@(test)
test_url_split_keeps_explicit_scheme :: proc(t: ^testing.T) {
	target, err := http.url_split("https://example.com/a/b?x=1", nil)
	testing.expect_value(t, err, http.Error.None)
	testing.expect_value(t, target.scheme, http.Scheme.HTTPS)
	testing.expect_value(t, target.host, "example.com")
	testing.expect_value(t, target.port, 0)
	testing.expect_value(t, target.path, "/a/b")
	testing.expect_value(t, target.query, "x=1")
	testing.expect_value(t, target.userinfo, http.Split_Text{})
}

@(test)
test_url_split_default_scheme_is_http :: proc(t: ^testing.T) {
	// A URL with no scheme takes the script's default, which is `http` — not
	// https (cli/argparser.py:206-212).
	cases := [?]string{
		"localhost:8000/hello",
		"127.0.0.1/",
		"[::1]:9000/x",
		"localhost",
		"example.com/hello",
		"://example.com/x",
	}
	for url in cases {
		target, err := http.url_split(url, nil)
		testing.expectf(t, err == http.Error.None, "%s: %v", url, err)
		testing.expectf(t, target.scheme == http.Scheme.HTTP, "%s: expected http", url)
	}

	pasted, pasted_err := http.url_split("://example.com/x", nil)
	testing.expect_value(t, pasted_err, http.Error.None)
	testing.expect_value(t, pasted.host, "example.com")
	testing.expect_value(t, pasted.path, "/x")

	override := http.Scheme.HTTPS
	secure, secure_err := http.url_split("example.com/x", override)
	testing.expect_value(t, secure_err, http.Error.None)
	testing.expect_value(t, secure.scheme, http.Scheme.HTTPS)
}

@(test)
test_url_split_localhost_shorthand :: proc(t: ^testing.T) {
	// A schemeless URL that starts with ':' belongs to localhost: `:port`,
	// `:port/path`, `:/path` and bare `:` (httpie's _process_url prepends
	// `http://localhost` to it).
	cases := [?]struct {
		url:  string,
		port: int,
		path: string,
	} {
		{":8000", 8000, "/"},
		{":8000/echo?x=1", 8000, "/echo"},
		{":/path", 0, "/path"},
		{":", 0, "/"},
		{"localhost:", 0, "/"},
	}
	for c in cases {
		target, err := http.url_split(c.url, nil)
		testing.expectf(t, err == http.Error.None, "%s: %v", c.url, err)
		testing.expectf(t, target.host == "localhost", "%s: host", c.url)
		testing.expectf(t, target.port == c.port, "%s: port", c.url)
		testing.expectf(t, target.path == c.path, "%s: path", c.url)
	}

	// The alias means `::1/x` is `localhost::1` — a bad port, not an IPv6
	// address — and a plain host may not carry a second colon. The split hands
	// the authority on unexamined now; `url_host_normalize` is what refuses
	// these, and all of them exit 1 in the reference.
	for invalid in ([]string{"::1/x", "example.com::80", "a:b:c", ":8abc", "localhost:99999", "localhost:abc"}) {
		target, invalid_err := http.url_split(invalid, nil)
		testing.expect_value(t, invalid_err, http.Error.None)
		host, host_err := http.url_host_normalize(target.host_port, target.userinfo, target.url, context.allocator)
		testing.expectf(
			t,
			host_err == http.Error.Invalid_URL,
			"%s must be an invalid URL, got %v",
			invalid,
			host_err,
		)
		testing.expect_value(t, host, "")
	}

	// An IPv6 literal is bracketed, and keeps its brackets as the host.
	ipv6, ipv6_err := http.url_split("[::1]:8000/x", nil)
	testing.expect_value(t, ipv6_err, http.Error.None)
	testing.expect_value(t, ipv6.host, "[::1]")
	testing.expect_value(t, ipv6.port, 8000)
	testing.expect_value(t, ipv6.path, "/x")
}

// The credentials of a curl-style shorthand: the reference's `rpartition('@')`
// reads the netloc of the URL `_process_url` *built*, so the `localhost:<port>`
// it synthesized in front of the argv text is the userinfo — `:3000@example.org`
// authenticates as `localhost:3000`, and `:abc@example.org` as `localhostabc`
// (cli/argparser.py:205-225, docs/PARITY.md §3.6, t_452478e6). The split spells
// it as a literal prefix plus the argv slice, so no join is needed here; a URL
// that named its scheme is the normal road and stays one piece.
@(test)
test_url_split_shorthand_userinfo :: proc(t: ^testing.T) {
	cases := [?]struct {
		url:    string,
		prefix: string,
		text:   string,
	} {
		// The digits the shorthand read are not a port here: they are the
		// second half of the synthesized credentials.
		{":3000@example.org/x", "localhost:", "3000"},
		// No digits at all: `localhost` and the word are one piece of text.
		{":abc@example.org/x", "localhost", "abc"},
		{":@example.org/x", "localhost", ""},
		// The '@' is behind the path's first '/', so nothing of it is an
		// authority: the host is the shorthand's own `localhost` and this is
		// the path.
		{":/x@example.org/x", "", ""},
		// Only the *last* '@' is the partition's (`rpartition`), so the rest of
		// the userinfo stays the text argv spelled.
		{":3000@u:p@example.org/x", "localhost:", "3000@u:p"},
		{"http://u:p@example.org:8080/x", "", "u:p"},
		{"example.org@example.org/x", "", "example.org"},
	}
	for row in cases {
		target, err := http.url_split(row.url, nil)
		testing.expectf(t, err == http.Error.None, "%s: %v", row.url, err)
		testing.expectf(
			t,
			target.userinfo.prefix == row.prefix && target.userinfo.text == row.text,
			"%s: userinfo {%q, %q}, want {%q, %q}",
			row.url,
			target.userinfo.prefix,
			target.userinfo.text,
			row.prefix,
			row.text,
		)
	}
}

// The join the split deliberately does not do: `request_create` spells the
// userinfo's two pieces into the request's own memory, in one allocation
// (`split_text_clone_into` — a joined temporary copied afterwards would leak).
@(test)
test_request_create_joins_the_shorthand_userinfo :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := [?]struct {
		url:  string,
		want: string,
	} {
		{":3000@example.org/x", "localhost:3000"},
		{":abc@example.org/x", "localhostabc"},
		{":@example.org/x", "localhost"},
		{"http://user:pass@example.org/x", "user:pass"},
		{"http://example.org/x", ""},
	}
	for row in cases {
		request, err := http.request_create(allocator, .GET, row.url, nil)
		testing.expectf(t, err == http.Error.None, "%s: %v", row.url, err)
		testing.expectf(
			t,
			request.userinfo == row.want,
			"%s: userinfo %q, want %q",
			row.url,
			request.userinfo,
			row.want,
		)
		testing.expectf(t, request.host == "example.org", "%s: host %q", row.url, request.host)
		http.request_destroy(&request)
	}

	expect_no_leaks(t, &track)
}

@(test)
test_url_split_scheme_override_only_wins_without_scheme :: proc(t: ^testing.T) {
	override := http.Scheme.HTTP

	bare, bare_err := http.url_split("example.com/x", override)
	testing.expect_value(t, bare_err, http.Error.None)
	testing.expect_value(t, bare.scheme, http.Scheme.HTTP)

	explicit, explicit_err := http.url_split("https://example.com/x", override)
	testing.expect_value(t, explicit_err, http.Error.None)
	testing.expect_value(t, explicit.scheme, http.Scheme.HTTPS)
}

@(test)
test_url_split_parts :: proc(t: ^testing.T) {
	target, err := http.url_split("http://user:pass@example.com:8080/path/to?q=%20a#frag", nil)
	testing.expect_value(t, err, http.Error.None)
	testing.expect_value(t, target.userinfo, http.Split_Text{text = "user:pass"})
	testing.expect_value(t, target.host, "example.com")
	testing.expect_value(t, target.port, 8080)
	testing.expect_value(t, target.path, "/path/to")
	testing.expect_value(t, target.query, "q=%20a")

	default_path, default_err := http.url_split("https://example.com", nil)
	testing.expect_value(t, default_err, http.Error.None)
	testing.expect_value(t, default_path.path, "/")
	testing.expect_value(t, default_path.port, 0)
}

@(test)
test_url_split_rejects_broken_urls :: proc(t: ^testing.T) {
	// A scheme the port's transport does not speak is classified by the split and
	// refused by the *session*, where requests refuses it (docs/PARITY.md §3.6,
	// §8 item 21): the URL's text decides which preparation requests gives it.
	ftp_target, scheme_err := http.url_split("ftp://example.com/", nil)
	testing.expect_value(t, scheme_err, http.Error.None)
	testing.expect_value(t, ftp_target.scheme_name, "ftp")
	testing.expect_value(t, ftp_target.other_scheme, true)
	testing.expect_value(t, ftp_target.unprepared, true)
	testing.expect_value(t, ftp_target.host_port.text, "example.com")

	// ...and an http-prefixed URL takes the other preparation: its scheme is
	// just as unknown, but requests prepares it all the same
	// (`url.lower().startswith("http")`, models.py:504).
	httpx_target, httpx_err := http.url_split("httpx://example.com/", nil)
	testing.expect_value(t, httpx_err, http.Error.None)
	testing.expect_value(t, httpx_target.scheme_name, "httpx")
	testing.expect_value(t, httpx_target.other_scheme, true)
	testing.expect_value(t, httpx_target.unprepared, false)

	// Nothing at all, nothing but a scheme, and a port text the pattern cannot
	// read are not the split's business any more: the authority is handed on
	// and `url_host_normalize` refuses it — requests' own `No host supplied`,
	// and the pattern's `is not a valid host or port`.
	for url in ([]string{"", "http://", "http://example.com:notaport/"}) {
		target, err := http.url_split(url, nil)
		testing.expect_value(t, err, http.Error.None)
		host_error: http.Host_Error
		_, host_err := http.url_host_normalize(
			target.host_port,
			target.userinfo,
			target.url,
			context.allocator,
			&host_error,
		)
		testing.expectf(t, host_err == http.Error.Invalid_URL, "%q must be an invalid URL, got %v", url, host_err)
		http.host_error_destroy(&host_error, context.allocator)
	}
}

@(test)
test_scheme_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, http.scheme_default_port(.HTTP), 80)
	testing.expect_value(t, http.scheme_default_port(.HTTPS), 443)
	testing.expect_value(t, http.scheme_to_string(.HTTPS), "https")

	scheme, ok := http.scheme_from_string("HTTPS")
	testing.expect(t, ok, "scheme matching must be case-insensitive")
	testing.expect_value(t, scheme, http.Scheme.HTTPS)

	_, ok = http.scheme_from_string("gopher")
	testing.expect(t, !ok, "gopher is not supported")
}

@(test)
test_method_helpers :: proc(t: ^testing.T) {
	method, ok := http.method_from_string("patch")
	testing.expect(t, ok, "method matching must be case-insensitive")
	testing.expect_value(t, method, http.Method.PATCH)
	testing.expect_value(t, http.method_to_string(method), "PATCH")

	_, ok = http.method_from_string("FETCH")
	testing.expect(t, !ok, "FETCH is not an HTTP method")
}

// The path's dot segments: urllib3's `_remove_path_dot_segments`
// (util/url.py:323-350), which the port runs where the request takes its owned
// copy of the path. The rows are the reference's own measurements — the table in
// docs/PARITY.md §3.6, and build/probe_dot_segments_reference.py.
@(test)
test_url_path_removes_dot_segments :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		path: string,
		want: string,
	}{
		// '.' is dropped and '..' pops the segment before it.
		{"/a/./b", "/a/b"},
		{"/a/../b", "/b"},
		{"/a/b/../../../c", "/c"},
		// A '..' above the root is dropped, not kept; the leading empty segment
		// it would have popped is put back by the join.
		{"/../b", "/b"},
		{"/a/../../b", "/b"},
		{"/..", "/"},
		// A trailing '/.' or '/..' leaves a trailing '/'.
		{"/a/.", "/a/"},
		{"/a/..", "/"},
		{"/.", "/"},
		{"/a/./", "/a/"},
		// An empty segment is not a dot segment. `..` pops it like any other
		// segment, which is what keeps a single leading '/'.
		{"//a//b", "//a//b"},
		{"//./a", "//a"},
		{"//../a", "/a"},
		// Nothing to remove, and the '...' that is not a dot segment.
		{"/a/b", "/a/b"},
		{"/a/.../b", "/a/.../b"},
		{"/", "/"},
		// A `%2e` is an ordinary segment here: the removal runs before the
		// encoding, so only the requoting rule turns it into a '.'
		// (`url_component_quote_into`).
		{"/a/%2e/b", "/a/%2e/b"},
		{"/a/%2E%2E/b", "/a/%2E%2E/b"},
		// A non-ASCII segment is a segment like any other.
		{"/h\u00e9llo/../b", "/b"},
	}
	for row in cases {
		buffer := http.buffer_make(allocator, len(row.path))
		testing.expectf(
			t,
			http.url_path_remove_dot_segments_into(&buffer, row.path),
			"%q must be written",
			row.path,
		)
		testing.expectf(t, string(buffer.data[:]) == row.want, "%q → %q, want %q",
		                row.path, string(buffer.data[:]), row.want)
		http.buffer_destroy(&buffer)
	}

	// The function appends: what the buffer already held stays in front.
	buffer := http.buffer_make(allocator, 0)
	testing.expect(t, http.buffer_append_string(&buffer, "GET "), "the prefix must be written")
	testing.expect(t, http.url_path_remove_dot_segments_into(&buffer, "/a/./b"), "the path must be written")
	testing.expect_value(t, string(buffer.data[:]), "GET /a/b")
	http.buffer_destroy(&buffer)

	expect_no_leaks(t, &track)
}

@(test)
test_request_create_reduces_the_path_dot_segments :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		url:  string,
		want: string,
	}{
		{"http://example.org/a/./b", "/a/b"},
		{"http://example.org/a/../b", "/b"},
		{"http://example.org/../b", "/b"},
		{"http://example.org/a/..", "/"},
		{"http://example.org//a//b", "//a//b"},
		{"http://example.org/a/%2e/b", "/a/%2e/b"},
		{"http://example.org", "/"},
	}
	for row in cases {
		request, err := http.request_create(allocator, .GET, row.url, nil)
		testing.expect_value(t, err, http.Error.None)
		testing.expectf(t, request.path == row.want, "%q → %q, want %q",
		                row.url, request.path, row.want)
		http.request_destroy(&request)
	}

	// `--path-as-is` is the one way past the rule: the path is taken as the URL
	// spells it (httpie's `ensure_path_as_is`, client.py:94-98).
	as_is, as_is_err := http.request_create(allocator, .GET, "http://example.org/a/./b", nil, true)
	testing.expect_value(t, as_is_err, http.Error.None)
	testing.expect_value(t, as_is.path, "/a/./b")
	http.request_destroy(&as_is)

	expect_no_leaks(t, &track)
}

// A redirect target with no netloc is resolved by CPython `urljoin`
// (urllib/parse.py:585-621) — a rule of its own next to urllib3's path removal:
// the base's *path* is merged with the Location's, the empty segments between
// them are dropped, and only then does the '.'/'..' loop run. The rows are the
// reference's own values — `urljoin(resp.url, requote_uri(location))` for the
// netloc-less branch, the requoted Location alone otherwise (sessions.py:225-245)
// — and every one of them is also measured end to end by
// build/probe_wire_target.py (the table in docs/PARITY.md §3.6).
@(test)
test_resolve_location_writes_cpythons_target :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		base:     string,
		location: string,
		want:     string,
	}{
		// The base's query is not a directory: only its path is merged, which
		// `urlparse` has already split the query off (urllib/parse.py:564-567).
		{"http://h/a/b?dir=/x", "target", "http://h/a/target"},
		// Everything from the Location's first '?' or '#' is put back as it was
		// written: urljoin resolves the path and nothing else.
		{"http://h/a/b", "/a/./b?q=1#f", "http://h/a/b?q=1#f"},
		// The Location's path is merged onto the base's directory and reduced,
		// a trailing '.' or '..' leaving the '/' it implies.
		{"http://h/a/b", "/a/./target", "http://h/a/target"},
		{"http://h/a/b", "/a/../target", "http://h/target"},
		{"http://h/a/b", "/../../target", "http://h/target"},
		{"http://h/a/b", "../target", "http://h/target"},
		{"http://h/a/b", "/a/b/..", "http://h/a/"},
		{"http://h/a/b/", "../c", "http://h/a/c"},
		// A '.' inside a segment is a character of the path, not a dot segment.
		{"http://h/a/b", "/a.b/target", "http://h/a.b/target"},
		// A Location that starts with '/' is resolved on its own — the base's
		// path contributes nothing, and its empty segments are not filtered
		// (that filter is the merge's, urllib/parse.py:598).
		{"http://h/a/b", "/a//b/../c", "http://h/a//c"},
		// The merge, on the other hand, drops the empty segments between the
		// base's directory and the Location: `x//y` is `x/y`, where the path
		// removal alone would leave `/x//y` (`url_path_remove_dot_segments_into`).
		{"http://h/re//dir/start", "x/y", "http://h/re/dir/x/y"},
		{"http://h/redirect-location", "x//y", "http://h/x/y"},
		// A Location with a netloc keeps its dots: urljoin is not called for it,
		// so they are the Location's own bytes (`//` takes the base's scheme).
		{"http://h/a/b", "//other/./x", "http://other/./x"},
		{"http://h/a/b", "http://o/a/../b", "http://o/a/../b"},
		// An empty Location is the base itself.
		{"http://h/a/b", "", "http://h/a/b"},
		// The three bytes `urlsplit` deletes from the whole URL before it reads
		// anything — tab, CR and LF (`_UNSAFE_URL_BYTES_TO_REMOVE`,
		// urllib/parse.py:92, the loop at :497-500 right after the lstrip). They
		// are gone from every field, the scheme's own text and the authority
		// included, and the deletion runs before the ':'-scheme scan and before
		// the requote, so no spelling of the byte survives into the resolved
		// URL (docs/PARITY.md §8 item 23, kanban t_2e0476c7; the fuzz over the
		// same rule is `build/probe_location_resolution_rule.py`, whose
		// generator now carries all three bytes).
		{"http://h/a/b", "/a	b", "http://h/ab"},
		{"http://h/a/b", "/a\rb\nc", "http://h/abc"},
		{"http://h/a/b", "/e	cho", "http://h/echo"},
		{"http://h/a/b", "/a	b/../c", "http://h/c"},
		{"http://h/a/b", "ht	tp://h/x", "http://h/x"},
		{"http://h/a/b", "//h	/x", "http://h/x"},
		{"http://h/a/b", "http://o/a	b", "http://o/ab"},
		{"http://h/a/b?q=1", "?	q=2", "http://h/a/b?q=2"},
		// The *base* of `urljoin` is the same parse, and the deletion is made
		// there too — the base requests held is a URL the run resolved, so a
		// live row cannot carry one of the bytes, but the rule is the rule: a
		// base holding a tab merges as if it never had one.
		{"http://h/a	b", "x", "http://h/x"},
		{"http://h/a	b/", "x", "http://h/ab/x"},
		{"http://h	/a/b", "../x", "http://h/x"},
	}
	for row in cases {
		got, err := http.resolve_location(row.base, row.location, allocator)
		testing.expect_value(t, err, http.Error.None)
		testing.expectf(t, got == row.want, "resolve_location(%q, %q) = %q, want %q",
		                row.base, row.location, got, row.want)
		delete(got, allocator)
	}

	// The resolution appends, like the removal next to it: what the buffer
	// already holds stays in front of the resolved path.
	buffer := http.buffer_make(allocator, 0)
	testing.expect(t, http.buffer_append_string(&buffer, "http://h"), "the origin must be written")
	testing.expect(t, http.url_join_reduced_path_into(&buffer, "/a/b", "/a/../target"),
	               "the resolved path must be written")
	testing.expect_value(t, string(buffer.data[:]), "http://h/target")
	http.buffer_destroy(&buffer)

	expect_no_leaks(t, &track)
}

// The bracketed authorities CPython's `urlsplit` refuses (docs/PARITY.md §3.6,
// "The bracketed authority CPython refuses, shape by shape" — kanban
// t_17caa1d7). httpie calls `urlsplit` while the arguments are parsed
// (cli/argparser.py:287), so `_check_bracketed_netloc` refuses these before
// urllib3's pattern is ever reached and the reference dies with a Python
// traceback whose frames are the interpreter's — which no scenario can compare.
// What the port owes on that road is the refusal itself: exit 1, nothing on
// stdout, nothing sent, and urllib3's message (the one the reference *would*
// print if CPython were not in the way). The `url-host-bracket-cpython-*`
// scenarios pin the first half with `compare=('stdout', 'rc')`; the wording is
// pinned here, one row per shape of `build/url-host-bracket-traceback.txt`.
@(test)
test_url_host_normalize_refuses_the_bracketed_authorities_cpython_does :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		url:  string,
		want: string,
	}{
		{"http://[zzz]/x", "InvalidURL: Failed to parse: '[zzz]' is not a valid host or port"},
		{"http://[]/x", "InvalidURL: Failed to parse: '[]' is not a valid host or port"},
		{"http://[::1/x", "InvalidURL: Failed to parse: '[::1' is not a valid host or port"},
		{"http://[::1]x/x", "InvalidURL: Failed to parse: '[::1]x' is not a valid host or port"},
		{"http://::1]/x", "InvalidURL: Failed to parse: '::1]' is not a valid host or port"},
		{"http://x[::1]/x", "InvalidURL: Failed to parse: 'x[::1]' is not a valid host or port"},
		{"http://u@[zzz]/x", "InvalidURL: Failed to parse: '[zzz]' is not a valid host or port"},
		{"http://[::1][::1]/x",
		 "InvalidURL: Failed to parse: '[::1][::1]' is not a valid host or port"},
		{"http://[1:2:3:4:5:6:7:8:9]/x",
		 "InvalidURL: Failed to parse: '[1:2:3:4:5:6:7:8:9]' is not a valid host or port"},
		{"http://[12345::1]/x",
		 "InvalidURL: Failed to parse: '[12345::1]' is not a valid host or port"},
		{"http://[fe80::1%]/x", "InvalidURL: Failed to parse: '[fe80::1%]' is not a valid host or port"},
		{"http://[1.2.3.4]/x", "InvalidURL: Failed to parse: '[1.2.3.4]' is not a valid host or port"},
		{"http://[v1.]/x", "InvalidURL: Failed to parse: '[v1.]' is not a valid host or port"},
		{"http://example.org:8]0/x",
		 "InvalidURL: Failed to parse: 'example.org:8]0' is not a valid host or port"},
	}
	for row in cases {
		// The split hands the authority on: the refusal belongs to
		// `url_host_normalize` (and, in the reference, to CPython two layers
		// above urllib3) — the same seam `test_url_split_rejects_broken_urls`
		// asserts.
		target, split_err := http.url_split(row.url, nil)
		testing.expectf(t, split_err == http.Error.None,
		                "%s: the split must hand the authority on, got %v", row.url, split_err)

		host_error: http.Host_Error
		_, host_err := http.url_host_normalize(
			target.host_port,
			target.userinfo,
			target.url,
			allocator,
			&host_error,
		)
		testing.expectf(t, host_err == http.Error.Invalid_URL, "%s: must be refused, got %v",
		                row.url, host_err)
		testing.expect_value(t, host_error.kind, http.Host_Error_Kind.Invalid_Authority)

		message := http.host_error_message(&host_error, allocator)
		testing.expectf(t, message == row.want, "%s: message %q, want %q", row.url, message, row.want)
		delete(message, allocator)
		http.host_error_destroy(&host_error, allocator)
	}

	expect_no_leaks(t, &track)
}

// The other half of the same CPython check (t_8a2dad4a): `_check_bracketed_netloc`
// partitions the userinfo off the netloc *first* (`netloc.rpartition('@')[2]`,
// urllib/parse.py:442) and only then looks for a '['. A netloc whose brackets
// sit *in the userinfo* therefore takes the `else` branch (:452-453), which
// hands the *host* to `_check_bracketed_host` and demands an IP literal of it:
// `ipaddress` refuses a host it cannot read, refuses an IPv4 one after reading
// it, and the IPvFuture branch in front of both refuses a `v…` host that does
// not match `\Av[a-fA-F0-9]+\..+\Z` (:458-465). The reference dies with an
// unhandled `ValueError` there and the port's own rule — urllib3's pattern —
// would have accepted the authority, which is why the port runs the check
// itself (`src/http/host.odin`'s `url_host_bracketed_netloc`, right after the
// match, so the shapes the pattern refuses keep its message).
//
// The ten `url-host-bracket-cpython-userinfo-*` scenarios pin the half both
// sides own — exit 1 and an empty stdout; the *wording* is the exception's own
// and the reference's is a traceback's last line, so it is asserted here, byte
// for byte, and released through `host_error_destroy` (the quoted host is a
// borrow of the URL's own string, `Host_Error`'s usual convention).
@(test)
test_url_host_normalize_refuses_a_bracket_the_userinfo_swallowed :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		url:  string,
		kind: http.Host_Error_Kind,
		want: string,
	}{
		// The `else` branch, one host per message: a host `ipaddress` cannot
		// read at all...
		{"http://u[x]@example.org/x", .Invalid_Bracketed_Host,
		 "ValueError: 'example.org' does not appear to be an IPv4 or IPv6 address"},
		{"http://u[x]@example.org:80/x", .Invalid_Bracketed_Host,
		 "ValueError: 'example.org' does not appear to be an IPv4 or IPv6 address"},
		{"http://u[x]@localhost/x", .Invalid_Bracketed_Host,
		 "ValueError: 'localhost' does not appear to be an IPv4 or IPv6 address"},
		// ... the other userinfo spellings of the same shape, `rpartition('@')`
		// taking the last one (so `u[x]` is inside the credentials)...
		{"http://[x]@example.org/x", .Invalid_Bracketed_Host,
		 "ValueError: 'example.org' does not appear to be an IPv4 or IPv6 address"},
		{"http://u]x[@example.org/x", .Invalid_Bracketed_Host,
		 "ValueError: 'example.org' does not appear to be an IPv4 or IPv6 address"},
		{"http://u:p[a]@example.org/x", .Invalid_Bracketed_Host,
		 "ValueError: 'example.org' does not appear to be an IPv4 or IPv6 address"},
		{"http://@u[x]@example.org/x", .Invalid_Bracketed_Host,
		 "ValueError: 'example.org' does not appear to be an IPv4 or IPv6 address"},
		// ... and the curl-style shorthand, whose synthesized `localhost:3000`
		// is the userinfo in front of argv's bracket (t_452478e6).
		{":3000@u[x]@example.org/x", .Invalid_Bracketed_Host,
		 "ValueError: 'example.org' does not appear to be an IPv4 or IPv6 address"},
		// An empty host is refused by this check before requests' own — which
		// is why the message is `ipaddress`'s and not `No host supplied`.
		{"http://u[x]@/x", .Invalid_Bracketed_Host,
		 "ValueError: '' does not appear to be an IPv4 or IPv6 address"},
		// A host `ipaddress` *does* read as an IPv4 address is refused after it.
		{"http://u[x]@1.2.3.4/x", .Invalid_Bracketed_IPv4,
		 "ValueError: An IPv4 address cannot be in brackets"},
		{"http://u[x]@127.0.0.1:80/x", .Invalid_Bracketed_IPv4,
		 "ValueError: An IPv4 address cannot be in brackets"},
		// ... and the ones urllib3's looser `_IPV4_RE` would call an IPv4
		// address but `ipaddress` does not: a leading zero, `0x` hex, five
		// groups. They take the message above, not the bracket one.
		{"http://u[x]@010.1.1.1/x", .Invalid_Bracketed_Host,
		 "ValueError: '010.1.1.1' does not appear to be an IPv4 or IPv6 address"},
		{"http://u[x]@0x7f.1/x", .Invalid_Bracketed_Host,
		 "ValueError: '0x7f.1' does not appear to be an IPv4 or IPv6 address"},
		{"http://u[x]@1.2.3.4.5/x", .Invalid_Bracketed_Host,
		 "ValueError: '1.2.3.4.5' does not appear to be an IPv4 or IPv6 address"},
		// A host starting with 'v' is the IPvFuture branch: `v1.x` is an
		// address to CPython (asserted below, accepted), `v.x` and `vx1.y` are
		// not `v[hex]+\..+` and are refused by name.
		{"http://u[x]@v.x/x", .Invalid_IPvFuture, "ValueError: IPvFuture address is invalid"},
		{"http://u[x]@vx1.y/x", .Invalid_IPvFuture, "ValueError: IPvFuture address is invalid"},
		// `urlsplit`'s own check, over the whole netloc: one half of the pair
		// is in the userinfo and the other is nowhere.
		{"http://u[x@example.org/x", .Invalid_IPv6_URL, "ValueError: Invalid IPv6 URL"},
		{"http://x]@example.org/x", .Invalid_IPv6_URL, "ValueError: Invalid IPv6 URL"},
		{"http://u]x@example.org/x", .Invalid_IPv6_URL, "ValueError: Invalid IPv6 URL"},
		{"http://[x@example.org/x", .Invalid_IPv6_URL, "ValueError: Invalid IPv6 URL"},
	}
	for row in cases {
		target, split_err := http.url_split(row.url, nil)
		testing.expectf(t, split_err == http.Error.None,
		                "%s: the split must hand the authority on, got %v", row.url, split_err)

		host_error: http.Host_Error
		_, host_err := http.url_host_normalize(
			target.host_port,
			target.userinfo,
			target.url,
			allocator,
			&host_error,
		)
		testing.expectf(t, host_err == http.Error.Invalid_URL, "%s: must be refused, got %v",
		                row.url, host_err)
		testing.expect_value(t, host_error.kind, row.kind)

		message := http.host_error_message(&host_error, allocator)
		testing.expectf(t, message == row.want, "%s: message %q, want %q", row.url, message, row.want)
		delete(message, allocator)
		http.host_error_destroy(&host_error, allocator)
	}

	// The controls: the two shapes the same netloc leaves alone. A host the
	// IPvFuture regex accepts is a valid bracketed host to CPython — brackets
	// or not — and when the *host* holds the brackets it is the urllib3
	// pattern's `_IPV6_ADDRZ_PAT` that decides, which is the block above's
	// business, not this check's.
	accepted := []string{
		"http://u[x]@v1.x/x",
		"http://u[x]@v1.x:80/x",
		"http://u[x]@v1.example.org/x",
		"http://u[x]@[::1]/x",
		"http://u[x]@[::1]:80/x",
		"http://example.org/u[x]/x",
		"http://u@example.org/x",
		"http://example.org/x?q=[y]",
	}
	for url in accepted {
		target, split_err := http.url_split(url, nil)
		testing.expectf(t, split_err == http.Error.None, "%s: split, got %v", url, split_err)
		host, host_err := http.url_host_normalize(
			target.host_port,
			target.userinfo,
			target.url,
			allocator,
		)
		testing.expectf(t, host_err == http.Error.None, "%s: must be accepted, got %v", url, host_err)
		delete(host, allocator)
	}

	expect_no_leaks(t, &track)
}

// The RFC 6874 zone-id half of `_normalize_host`'s bracketed alternative, and
// the requote requests puts the netloc through afterwards (util/url.py:369-390
// and `requote_uri`, models.py:560 — t_2e08b2f9). The rows are the reference's
// own measurements; `build/probe_zone_id.py` is the probe they came from and
// the `url-host-bracket-zone-*` scenarios pin the same bytes end to end.
@(test)
test_url_host_normalize_requotes_a_bracketed_zone_id :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		url:  string,
		want: string,
	}{
		// The bare separator: `_normalize_host` writes it back as one `%`, and
		// requests' `requote_uri` reads the two characters behind it (a zone's
		// letters) as no escape at all, so the netloc is quoted with '%' out
		// of its safe set.
		{"http://[fe80::1%eth0]/x", "[fe80::1%25eth0]"},
		// The escaped separator is stripped the same way, so both spellings
		// come out as the one the wire carries.
		{"http://[fe80::1%25eth0]/x", "[fe80::1%25eth0]"},
		// Only the address in front of the separator is lowercased.
		{"http://[FE80::1%25ETH0]/x", "[fe80::1%25ETH0]"},
		// A separator whose two characters *are* hexadecimal is read as the
		// escape they spell: `%41` is the unreserved `A`, so it is unquoted.
		{"http://[fe80::1%41]/x", "[fe80::1A]"},
		// A zone that is not exactly `%25` loses the three bytes of the
		// `%25` separator, so only the zone's own `25` follows the one `%`.
		{"http://[fe80::1%2525]/x", "[fe80::1%25]"},
		// No zone id at all: the whole host is lowercased, and there is no
		// '%' left for the requote to see.
		{"http://[::FFFF:1]/x", "[::ffff:1]"},
	}
	for row in cases {
		target, split_err := http.url_split(row.url, nil)
		testing.expectf(t, split_err == http.Error.None,
		                "%s: the split must hand the authority on, got %v", row.url, split_err)

		host, host_err := http.url_host_normalize(target.host_port, target.userinfo, target.url, allocator)
		testing.expectf(t, host_err == http.Error.None, "%s: normalized, got %v",
		                row.url, host_err)
		testing.expectf(t, host == row.want, "%s: host %q, want %q", row.url, host, row.want)
		delete(host, allocator)
	}

	expect_no_leaks(t, &track)
}

// The other thing that same call decides: requests hands the *whole* prepared
// URL to `requote_uri` (models.py:560), so when the netloc's bare '%' makes
// `unquote_unreserved` raise, the except-branch quotes every '%' of the URL with
// `safe_without_percent` — every one a literal `%25`, no escape unquoted — and
// the path, the URL's own query and the `name==value` items are all inside that
// string. The decision is a property of the URL rather than of a component, so
// it leaves `url_host_normalize` through its out-param and `request_target`
// honours it (kanban t_75b15cf5). The rows are the reference's own measurements
// (`build/probe_zone_id.py`, and the `url-host-bracket-zone-path-*` scenarios
// for the bytes end to end); `item_name` empty means the case carries no item.
@(test)
test_request_target_honours_the_netlocs_requote_fallback :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		url:         string,
		host:        string,
		fallback:    bool,
		item_name:   string,
		item_value:  string,
		want_target: string,
	}{
		// The zone's own letters behind the separator's '%' are alphanumeric
		// and not hexadecimal, so the escape pass raises for the whole URL:
		// the path's `%41` is a literal `%2541`, not the `A` it spells.
		{"http://[fe80::1%eth0]/%41x", "[fe80::1%25eth0]", true, "", "", "/%2541x"},
		// ... and the `%25` the path's own step wrote is quoted again.
		{"http://[fe80::1%eth0]/%zzx", "[fe80::1%25eth0]", true, "", "", "/%2525zzx"},
		// The URL's own query is the same string's other component.
		{"http://[fe80::1%eth0]/x?q=%41", "[fe80::1%25eth0]", true, "", "", "/x?q=%2541"},
		// The escaped separator reaches the same host, so the same fallback.
		{"http://[fe80::1%25eth0]/x?q=%41", "[fe80::1%25eth0]", true, "", "", "/x?q=%2541"},
		// The `name==value` items are appended to the query *before* requests
		// builds that string, so the fallback's quote sees their '%' too: the
		// item's `%41` is `quote_plus`'s `%2541` quoted once more.
		{"http://[fe80::1%eth0]/x", "[fe80::1%25eth0]", true, "y", "%41", "/x?y=%252541"},
		// A separator whose two characters *are* hexadecimal is read as the
		// escape they spell, so nothing raises and the path keeps the ordinary
		// rule: `%41` goes back to `A`.
		{"http://[fe80::1%41]/%41x", "[fe80::1A]", false, "", "", "/Ax"},
		// A zone `25` alone is a readable escape too, so nothing raises here
		// either: the host keeps its one `%25` and the path its ordinary rule.
		{"http://[fe80::1%2525]/%41x", "[fe80::1%25]", false, "", "", "/Ax"},
		{"http://example.org/%41x", "example.org", false, "", "", "/Ax"},
	}
	for row in cases {
		target, split_err := http.url_split(row.url, nil)
		testing.expectf(t, split_err == http.Error.None,
		                "%s: the split must hand the authority on, got %v", row.url, split_err)

		fallback := false
		host, host_err := http.url_host_normalize(
			target.host_port,
			target.userinfo,
			target.url,
			allocator,
			nil,
			nil,
			&fallback,
		)
		testing.expectf(t, host_err == http.Error.None, "%s: normalized, got %v",
		                row.url, host_err)
		testing.expectf(t, host == row.host, "%s: host %q, want %q", row.url, host, row.host)
		testing.expectf(t, fallback == row.fallback, "%s: the URL's requote fallback is %v, want %v",
		                row.url, fallback, row.fallback)
		delete(host, allocator)

		request, create_err := http.request_create(allocator, .GET, row.url, nil)
		testing.expectf(t, create_err == http.Error.None, "%s: built, got %v",
		                row.url, create_err)
		testing.expectf(t, request.requote_fallback == row.fallback,
		                "%s: the request carries %v, want %v",
		                row.url, request.requote_fallback, row.fallback)
		if row.item_name != "" {
			testing.expect_value(t, http.request_add_query(&request, row.item_name,
			                                              row.item_value), http.Error.None)
		}
		spelling, target_err := http.request_target(&request, allocator)
		testing.expectf(t, target_err == http.Error.None, "%s: target built, got %v",
		                row.url, target_err)
		testing.expectf(t, spelling == row.want_target, "%s: target %q, want %q",
		                row.url, spelling, row.want_target)
		delete(spelling, allocator)
		http.request_destroy(&request)
	}

	expect_no_leaks(t, &track)
}
