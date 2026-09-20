package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:http"

@(test)
test_request_create_takes_owned_copies :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The URL lives on the test's stack; the Request must not keep a pointer to
	// it. `url` is deliberately a local so a borrow would be visible.
	url := "http://user:pass@example.com:8080/path"
	request, err := http.request_create(allocator, .PATCH, url, nil)
	testing.expect_value(t, err, http.Error.None)
	testing.expect(t, len(track.allocation_map) > 0, "request_create must own copies")

	testing.expect_value(t, request.method, http.Method.PATCH)
	testing.expect_value(t, request.scheme, http.Scheme.HTTP)
	testing.expect_value(t, request.host, "example.com")
	testing.expect_value(t, request.port, 8080)
	testing.expect_value(t, request.path, "/path")
	testing.expect_value(t, request.userinfo, "user:pass")

	http.request_destroy(&request)
	expect_no_leaks(t, &track)
	testing.expect_value(t, request.host, "")
}

@(test)
test_request_destroy_is_idempotent :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	request, err := http.request_create(allocator, .GET, "https://example.com", nil)
	testing.expect_value(t, err, http.Error.None)
	http.request_destroy(&request)
	http.request_destroy(&request)
	expect_no_leaks(t, &track)
}

@(test)
test_request_create_propagates_url_errors :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// A URL requests has no adapter for is not a failure of `request_create` any
	// more: the request is built in the spelling requests would hold for it and
	// the *session* refuses it where requests does (`get_adapter`, docs/PARITY.md
	// §3.6, §8 item 21).
	ftp_request, err := http.request_create(allocator, .GET, "ftp://EXAMPLE.com:0009/a b", nil)
	testing.expect_value(t, err, http.Error.None)
	testing.expect_value(t, ftp_request.url_kind, http.Url_Kind.Unprepared)
	testing.expect_value(t, ftp_request.url_text, "ftp://EXAMPLE.com:0009/a b")
	testing.expect_value(t, ftp_request.host, "EXAMPLE.com:0009")
	testing.expect_value(t, ftp_request.path, "/a b")
	http.request_destroy(&ftp_request)

	// The other preparation: an http-prefixed URL is prepared, so the host rule
	// runs (its scheme is not one urllib3 normalizes) and the URL the refusal
	// quotes is the prepared one.
	httpx_request, httpx_err := http.request_create(allocator, .GET, "httpx://EXAMPLE.com:0009/a", nil)
	testing.expect_value(t, httpx_err, http.Error.None)
	testing.expect_value(t, httpx_request.url_kind, http.Url_Kind.Other_Scheme)
	testing.expect_value(t, httpx_request.host, "EXAMPLE.com")
	testing.expect_value(t, httpx_request.port, 9)
	testing.expect_value(t, httpx_request.url_text, "httpx://EXAMPLE.com:9/a")
	http.request_destroy(&httpx_request)

	_, empty_err := http.request_create(allocator, .GET, "", nil)
	testing.expect_value(t, empty_err, http.Error.Invalid_URL)

	// Nothing may be left behind by a failed create.
	expect_no_leaks(t, &track)
}

@(test)
test_request_create_honours_default_scheme :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	request, err := http.request_create(allocator, .GET, "example.com/x", http.Scheme.HTTP)
	testing.expect_value(t, err, http.Error.None)
	testing.expect_value(t, request.scheme, http.Scheme.HTTP)
	http.request_destroy(&request)

	fallback, fallback_err := http.request_create(allocator, .GET, "example.com/x", nil)
	testing.expect_value(t, fallback_err, http.Error.None)
	// No override: httpie's `http` script default, which is http:// (only the
	// `https` script defaults to https; cli/argparser.py:206-224).
	testing.expect_value(t, fallback.scheme, http.Scheme.HTTP)
	http.request_destroy(&fallback)

	expect_no_leaks(t, &track)
}

@(test)
test_response_destroy_accepts_zero_and_engine_shaped_values :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	zero: http.Response
	http.response_destroy(&zero)

	// The engine (t_3d62ca31) builds responses exactly like this: every string
	// and slice owned by the response's allocator, nothing borrowed from static
	// data (freeing a literal would be a bad free).
	response := http.Response {
		allocator = allocator,
		status    = 200,
	}
	response.reason = must_clone(t, "OK", allocator)
	response.http_version = must_clone(t, "HTTP/1.1", allocator)
	response.url = must_clone(t, "https://example.com/", allocator)
	response.headers = make([]http.Header, 1, allocator)
	response.headers[0] = {
		name  = must_clone(t, "Content-Type", allocator),
		value = must_clone(t, "application/json", allocator),
	}
	response.body = make([]u8, 2, allocator)
	response.body[0] = '{'
	response.body[1] = '}'

	http.response_destroy(&response)
	expect_no_leaks(t, &track)
}

// The header-value strip is Python's argument-less str.strip(): the ASCII
// whitespace, the four control separators (U+001C-U+001F) and the Unicode
// whitespace come off both ends, while an inner space stays and a byte that is
// not UTF-8 is not whitespace (Python decodes it to a surrogate and keeps it).
@(test)
test_header_value_strip_is_python_str_strip :: proc(t: ^testing.T) {
	cases := []struct {
		value: string,
		want:  string,
	} {
		{"", ""},
		{"1", "1"},
		{"  1  ", "1"},
		{"   ", ""},
		{"a b", "a b"},
		{" a b ", "a b"},
		{string_of_bytes({0x09, '1', 0x0a}), "1"},
		{string_of_bytes({0x1c, 0x1d, 0x1e, 0x1f, '1', 0x1f}), "1"},
		{string_of_bytes({0xc2, 0x85, '1', 0xc2, 0x85}), "1"},        // U+0085
		{string_of_bytes({0xc2, 0xa0, '1', 0xc2, 0xa0}), "1"},        // U+00A0
		{string_of_bytes({0xe1, 0x9a, 0x80, '1', 0xe1, 0x9a, 0x80}), "1"},  // U+1680
		{string_of_bytes({0xe2, 0x80, 0x80, '1', 0xe2, 0x80, 0x8a}), "1"},  // U+2000-U+200A
		{string_of_bytes({0xe2, 0x80, 0xa8, '1', 0xe2, 0x80, 0xa9}), "1"},  // U+2028-U+2029
		{string_of_bytes({0xe2, 0x80, 0xaf, '1', 0xe2, 0x81, 0x9f}), "1"},  // U+202F, U+205F
		{string_of_bytes({0xe3, 0x80, 0x80, '1', 0xe3, 0x80, 0x80}), "1"},  // U+3000
		{string_of_bytes({0xff, '1', 0xff}), string_of_bytes({0xff, '1', 0xff})},
		{string_of_bytes({0xe2, 0x80, 0x8b, '1'}), string_of_bytes({0xe2, 0x80, 0x8b, '1'})},  // U+200B
	}
	for entry in cases {
		testing.expect_value(t, http.header_value_strip(entry.value), entry.want)
	}
}

// string_of_bytes spells a string as its bytes: an escape sequence would hide
// which code point is in play, and Odin does not cast a compound literal to
// string directly.
string_of_bytes :: proc(bytes: []u8) -> string {
	return transmute(string)bytes
}

// request_strip_header_values rewrites the list in place: a value with nothing
// to strip is not reallocated, a stripped one is.
@(test)
test_request_strip_header_values_owns_the_stripped_copy :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	request, err := http.request_create(allocator, .GET, "http://example.com", nil)
	testing.expect_value(t, err, http.Error.None)

	testing.expect_value(t, http.request_add_header(&request, "X-First", "  1  "), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "X-Second", "2"), http.Error.None)
	untouched := raw_data(request.headers[1].value)

	testing.expect_value(t, http.request_strip_header_values(&request), http.Error.None)
	testing.expect_value(t, len(request.headers), 2)
	testing.expect_value(t, request.headers[0].value, "1")
	testing.expect_value(t, request.headers[1].value, "2")
	testing.expect_value(t, request.headers[0].name, "X-First")
	// The value that had nothing to strip is the very slice it was.
	testing.expect(t, raw_data(request.headers[1].value) == untouched,
	               "a value with nothing to strip must not be reallocated")

	http.request_destroy(&request)
	expect_no_leaks(t, &track)
}

// str_utf8_seq_len is the port's answer to CPython's `bytes.decode('utf-8')` on
// the byte in front of it: the length of the well-formed sequence, or 0 when
// there is none at that position. The invalid shapes are the ones CPython's
// decoder refuses, so each becomes the lone surrogate `surrogateescape` makes of
// the byte.
@(test)
test_str_utf8_seq_len_accepts_every_valid_length :: proc(t: ^testing.T) {
	cases := []struct {
		bytes: []u8,
		want:  int,
	}{
		{{0x41}, 1},                     // 'A'
		{{0xc3, 0xa9}, 2},               // U+00E9 é
		{{0xe2, 0x82, 0xac}, 3},         // U+20AC €
		{{0xf0, 0x9f, 0x98, 0x80}, 4},   // U+1F600
		{{0x7f}, 1},                     // the last one-byte code point
		{{0xdf, 0xbf}, 2},               // U+07FF, the last two-byte one
	}
	for entry in cases {
		got := http.str_utf8_seq_len(string_of_bytes(entry.bytes))
		testing.expectf(t, got == entry.want, "%v: got %d, want %d", entry.bytes, got, entry.want)
	}
}

@(test)
test_str_utf8_seq_len_rejects_every_invalid_shape :: proc(t: ^testing.T) {
	cases := [][]u8{
		{0xff},                     // not a lead byte at all
		{0xfe},
		{0x80},                     // stray continuation byte
		{0xc3},                     // truncated two-byte sequence
		{0xe2, 0x82},               // truncated three-byte sequence
		{0xf0, 0x9f, 0x98},         // truncated four-byte sequence
		{0xc3, 0x28},               // bad continuation
		{0xc0, 0x80},               // overlong two-byte
		{0xc1, 0xbf},               // overlong two-byte
		{0xe0, 0x80, 0x80},         // overlong three-byte
		{0xf0, 0x80, 0x80, 0x80},   // overlong four-byte
		{0xed, 0xa0, 0x80},         // CESU-8: U+D800, a surrogate
		{0xed, 0xbf, 0xbf},         // U+DFFF, the last surrogate
		{0xf5, 0x80, 0x80, 0x80},   // above U+10FFFF
		{0xf4, 0x90, 0x80, 0x80},   // U+110000, the first code point above
	}
	for bytes in cases {
		got := http.str_utf8_seq_len(string_of_bytes(bytes))
		testing.expectf(t, got == 0, "%v: got %d, want 0", bytes, got)
	}
}

// str_encode_failure is CPython's UnicodeEncodeError as a value, and its message
// is the contract: one character by repr, a run of them as the range of their
// positions, and `position` counting *characters*.
@(test)
test_str_encode_failure_reports_cpython_message_shape :: proc(t: ^testing.T) {
	// One unencodable character: its repr, and its code point index.
	single := http.str_encode_failure(string_of_bytes({'X', ':', 0xff}), .Utf8)
	testing.expect(t, single.failed, "a byte that is not UTF-8 must fail the utf-8 codec")
	testing.expect_value(t, single.position, 2)
	testing.expect_value(t, single.end, 2)
	testing.expect_value(t, string(single.char[:single.char_len]), string_of_bytes({0x5c, 'u', 'd', 'c', 'f', 'f'}))

	message := http.str_encode_error_message(&single, context.allocator)
	defer delete(message, context.allocator)
	testing.expect_value(
		t,
		message,
		"UnicodeEncodeError: 'utf-8' codec can't encode character '\\udcff' in position 2: surrogates not allowed",
	)

	// Two in a row: CPython reports the longest run of consecutive characters it
	// cannot encode, as a range — not the first one alone.
	run := http.str_encode_failure(string_of_bytes({0xff, 0xfe, 'a', 0xff}), .Utf8)
	testing.expect_value(t, run.position, 0)
	testing.expect_value(t, run.end, 1)
	run_message := http.str_encode_error_message(&run, context.allocator)
	defer delete(run_message, context.allocator)
	testing.expect_value(
		t,
		run_message,
		"UnicodeEncodeError: 'utf-8' codec can't encode characters in position 0-1: surrogates not allowed",
	)

	// A valid multi-byte character in front of the bad one: the position is the
	// character's index, not the byte offset (2 bytes of é, then the bad byte).
	after_multibyte := http.str_encode_failure(string_of_bytes({0xc3, 0xa9, 'a', 0xff}), .Utf8)
	testing.expect_value(t, after_multibyte.position, 2)

	// The ascii codec, which CPython's http.client uses for a header *name*:
	// every character above 0x7f is refused, not only a surrogate.
	ascii_failure := http.str_encode_failure(string_of_bytes({'X', '-', 0xc3, 0xa9}), .Ascii)
	testing.expect_value(t, ascii_failure.position, 2)
	testing.expect_value(t, ascii_failure.end, 2)
	testing.expect_value(t, ascii_failure.codec, "ascii")
	testing.expect_value(t, ascii_failure.reason, "ordinal not in range(128)")
	testing.expect_value(t, string(ascii_failure.char[:ascii_failure.char_len]), string_of_bytes({0x5c, 'x', 'e', '9'}))
	ascii_message := http.str_encode_error_message(&ascii_failure, context.allocator)
	defer delete(ascii_message, context.allocator)
	testing.expect_value(
		t,
		ascii_message,
		"UnicodeEncodeError: 'ascii' codec can't encode character '\\xe9' in position 2: ordinal not in range(128)",
	)
}

// The encodable cases are the common ones and must stay silent: a valid
// multi-byte string is fine in both codecs it can be, and a byte that is not
// UTF-8 is fine where the codec does not look for text.
@(test)
test_str_encode_failure_is_quiet_for_encodable_strings :: proc(t: ^testing.T) {
	testing.expect(t, !http.str_encode_failure("plain", .Utf8).failed, "ascii text")
	testing.expect(t, !http.str_encode_failure(string_of_bytes({0xc3, 0xa9}), .Utf8).failed, "valid non-ascii")
	testing.expect(t, !http.str_encode_failure("plain", .Ascii).failed, "ascii text, ascii codec")
	testing.expect(t, !http.str_encode_failure("", .Utf8).failed, "the empty string")
	testing.expect(t, !http.str_encode_failure("", .Ascii).failed, "the empty string, ascii codec")
	// latin-1 accepts é and refuses €: the boundary is U+00FF, not U+007F.
	testing.expect(t, !http.str_encode_failure(string_of_bytes({0xc3, 0xa9}), .Latin1).failed,
	               "é is one latin-1 byte")
	testing.expect(t, !http.str_encode_failure("", .Latin1).failed, "the empty string, latin-1 codec")
}

// The latin-1 codec is CPython's third one: `http.client.putheader` encodes a
// header *value* it still has as a `str` with it. The strings that reach it are
// the ones the port models with Header.str_value — the bearer token — so the
// numbers here are the measured reference's: `-A bearer -a $'tok\xff'` is
// position 10, two of them are the range 10-11, and $'tok\xe2\x82\xac' is the
// repr of U+20AC.
@(test)
test_str_encode_failure_latin1_codec :: proc(t: ^testing.T) {
	// The value in full, as the scenarios hand it over: `Bearer tok` and then
	// the bytes under test.
	single := http.str_encode_failure("Bearer tok\xff", .Latin1)
	testing.expect(t, single.failed, "a lone surrogate has no latin-1 encoding")
	testing.expect_value(t, single.position, 10)
	testing.expect_value(t, single.end, 10)
	testing.expect_value(t, single.codec, "latin-1")
	testing.expect_value(t, single.reason, "ordinal not in range(256)")
	single_message := http.str_encode_error_message(&single, context.allocator)
	defer delete(single_message, context.allocator)
	testing.expect_value(
		t,
		single_message,
		"UnicodeEncodeError: 'latin-1' codec can't encode character '\\udcff' in position 10: ordinal not in range(256)",
	)

	// A run of two: the range form, and the second character is index 11.
	run := http.str_encode_failure("Bearer tok\xff\xfe", .Latin1)
	testing.expect_value(t, run.position, 10)
	testing.expect_value(t, run.end, 11)
	run_message := http.str_encode_error_message(&run, context.allocator)
	defer delete(run_message, context.allocator)
	testing.expect_value(
		t,
		run_message,
		"UnicodeEncodeError: 'latin-1' codec can't encode characters in position 10-11: ordinal not in range(256)",
	)

	// A character above U+00FF that *is* valid UTF-8: utf-8 would accept it, so
	// this is what tells the two codecs apart.
	euro := http.str_encode_failure("Bearer tok\xe2\x82\xac", .Latin1)
	testing.expect_value(t, euro.position, 10)
	testing.expect_value(t, euro.end, 10)
	testing.expect_value(t, string(euro.char[:euro.char_len]), string_of_bytes({0x5c, 'u', '2', '0', 'a', 'c'}))
	euro_message := http.str_encode_error_message(&euro, context.allocator)
	defer delete(euro_message, context.allocator)
	testing.expect_value(
		t,
		euro_message,
		"UnicodeEncodeError: 'latin-1' codec can't encode character '\\u20ac' in position 10: ordinal not in range(256)",
	)

	// é is two argv bytes and one character: the position after it is 11.
	after_multibyte := http.str_encode_failure("Bearer tok\xc3\xa9\xff", .Latin1)
	testing.expect_value(t, after_multibyte.position, 11)
}

// str_latin1_encode_into is the other half of that rule: it *is* the encoding
// the reference puts on the wire, one byte per character, and it refuses exactly
// what the check refuses.
@(test)
test_str_latin1_encode_into_writes_one_byte_per_character :: proc(t: ^testing.T) {
	buffer := http.buffer_make(context.allocator, 16)
	defer http.buffer_destroy(&buffer)

	testing.expect(t, http.str_latin1_encode_into(&buffer, "Bearer tok\xc3\xa9"),
	               "Bearer toké is encodable")
	testing.expect_value(
		t,
		string(buffer.data[:]),
		"Bearer tok\xe9",
	)

	// Nothing is appended for a string the codec refuses: the caller has
	// already turned it into the UnicodeEncodeError by then.
	before := len(buffer.data)
	testing.expect(t, !http.str_latin1_encode_into(&buffer, string_of_bytes({0xff})),
	               "a lone surrogate has no latin-1 byte")
	testing.expect(t, !http.str_latin1_encode_into(&buffer, string_of_bytes({0xe2, 0x82, 0xac})),
	               "U+20AC is above U+00FF")
	testing.expect_value(t, len(buffer.data), before)
}

// A header value the auth plugin assigned is the one that reaches CPython's
// latin-1 step as text; every other header is bytes. The flag is what carries
// that distinction from the auth site to the transport.
@(test)
test_request_add_header_marks_a_text_value :: proc(t: ^testing.T) {
	request, err := http.request_create(context.allocator, .GET, "http://example.com", nil)
	testing.expect_value(t, err, http.Error.None)
	defer http.request_destroy(&request)

	testing.expect_value(t, http.request_add_header(&request, "X-Item", "v"), http.Error.None)
	testing.expect(t, !request.headers[0].str_value, "an item's value is already bytes")

	testing.expect_value(t, http.request_add_header(&request, "Authorization", "Bearer tok", true),
	                     http.Error.None)
	testing.expect(t, request.headers[1].str_value, "the auth plugin assigns text")
}

// The request remembers the first failure and keeps it: the reference stops at
// the first site that raises, so a later check must not overwrite what the
// message will print.
@(test)
test_request_encode_check_keeps_the_first_failure :: proc(t: ^testing.T) {
	request, err := http.request_create(context.allocator, .GET, "http://example.com", nil)
	testing.expect_value(t, err, http.Error.None)
	defer http.request_destroy(&request)

	testing.expect_value(
		t,
		http.request_encode_check(&request, string_of_bytes({'q', '=', 0xff}), .Utf8),
		http.Error.Str_Not_Encodable,
	)
	testing.expect_value(t, request.encode_error.position, 2)
	testing.expect_value(t, request.encode_error.codec, "utf-8")

	// A second, different failure leaves the first in place — the request is
	// still unencodable, and the message still describes the first one.
	testing.expect_value(
		t,
		http.request_encode_check(&request, string_of_bytes({'X', '-', 0xc3, 0xa9}), .Ascii),
		http.Error.Str_Not_Encodable,
	)
	testing.expect_value(t, request.encode_error.position, 2)
	testing.expect_value(t, request.encode_error.codec, "utf-8")
}

// request_invalid_header is requests' `check_header_validity` over the request's
// finalized list: the name half first, then the value half, and — because
// requests merges the pairs into a case-insensitive dict before it validates —
// one visit per name, in first-appearance order, with the *last* pair stored
// under it (docs/PARITY.md §3.1). The parity scenarios pin the bytes the
// reference prints; this pins the walk their wording depends on, including the
// cases a scenario cannot reach (a name that is refused although its value is
// the one with the return character in it).
@(test)
test_request_invalid_header_reads_the_last_pair :: proc(t: ^testing.T) {
	// A value with a line feed: the case the rule exists for.
	{
		request := rule_request(t, {"X-Note"}, {"line1\nline2"})
		defer http.request_destroy(&request)
		text, part, found := http.request_invalid_header(&request)
		testing.expect(t, found, "a return character in a value is refused")
		testing.expect_value(t, part, http.Invalid_Header_Part.Value)
		testing.expect_value(t, text, "line1\nline2")
	}

	// Both halves bad: check_header_validity validates the name first.
	{
		request := rule_request(t, {"X-No\nte"}, {"a\nb"})
		defer http.request_destroy(&request)
		text, part, found := http.request_invalid_header(&request)
		testing.expect(t, found)
		testing.expect_value(t, part, http.Invalid_Header_Part.Name)
		testing.expect_value(t, text, "X-No\nte")
	}

	// A name whose colon sits *inside* it: `^[^:\s][^:\r\n]*\Z` refuses the
	// colon in both classes, not only as the leading character, and the item
	// grammar reaches such a name through an escaped `:` — `a\:b:v` is the header
	// name `a:b` with the value `v`, because `\:` is an `Escaped` token and the
	// separator scan skips it (tests/cli_test.odin,
	// test_parse_args_backslash_pair_consumes_the_character, pins that parse).
	{
		request := rule_request(t, {"a:b"}, {"v"})
		defer http.request_destroy(&request)
		text, part, found := http.request_invalid_header(&request)
		testing.expect(t, found, "an interior colon is refused")
		testing.expect_value(t, part, http.Invalid_Header_Part.Name)
		testing.expect_value(t, text, "a:b")
	}
	{
		request := rule_request(t, {"a:b:c"}, {"v"})
		defer http.request_destroy(&request)
		_, _, found := http.request_invalid_header(&request)
		testing.expect(t, found, "wherever in the name the colon sits")
	}
	{
		request := rule_request(t, {":"}, {"v"})
		defer http.request_destroy(&request)
		text, _, found := http.request_invalid_header(&request)
		testing.expect(t, found, "the name that is only `:` (the `\\::v` spelling)")
		testing.expect_value(t, text, ":")
	}

	// A repeated name is validated once, with its last value: the pair the
	// merged dict holds under the name.
	{
		request := rule_request(t, {"X-Note", "X-Note"}, {"ok", "a\nb"})
		defer http.request_destroy(&request)
		text, part, found := http.request_invalid_header(&request)
		testing.expect(t, found)
		testing.expect_value(t, part, http.Invalid_Header_Part.Value)
		testing.expect_value(t, text, "a\nb")
	}
	{
		request := rule_request(t, {"X-Note", "X-Note"}, {"a\nb", "ok"})
		defer http.request_destroy(&request)
		_, _, found := http.request_invalid_header(&request)
		testing.expect(t, !found, "the first of two values is never validated")
	}

	// Two refused names: the message names the pair at the *first* occurrence's
	// position, not the one assigned last.
	{
		request := rule_request(
			t,
			{"X-A", "X-B", "X-A"},
			{"v1", "b1\nb2", "a1\na2"},
		)
		defer http.request_destroy(&request)
		text, _, found := http.request_invalid_header(&request)
		testing.expect(t, found)
		testing.expect_value(t, text, "a1\na2")
	}
}

// The half the rule does *not* refuse: a non-ASCII value (the byte pattern's
// `\S` accepts every byte above 0x7f), a whitespace *character* that is not a
// return character, and a name whose first character is not whitespace to
// Python — U+200B is a format character, not a space.
@(test)
test_request_invalid_header_accepts_the_rest :: proc(t: ^testing.T) {
	{
		request := rule_request(t, {"X-Note", "X-Text"}, {"caf\u00e9", "\u65e5\u672c"})
		defer http.request_destroy(&request)
		_, _, found := http.request_invalid_header(&request)
		testing.expect(t, !found, "a non-ASCII value is a value requests sends")
	}
	{
		request := rule_request(t, {"X-Note"}, {"a\tb"})
		defer http.request_destroy(&request)
		_, _, found := http.request_invalid_header(&request)
		testing.expect(t, !found, "an interior tab is not a return character")
	}
	// The colon rule is the *name*'s: a value keeps every colon it carries
	// (`a:b:c` is the header `a` with the value `b:c`).
	{
		request := rule_request(t, {"a"}, {"b:c"})
		defer http.request_destroy(&request)
		_, _, found := http.request_invalid_header(&request)
		testing.expect(t, !found, "a colon in a value is not the name's business")
	}
	{
		request := rule_request(t, {"\u200bX-Note"}, {"1"})
		defer http.request_destroy(&request)
		_, _, found := http.request_invalid_header(&request)
		testing.expect(t, !found, "U+200B is not Python whitespace")
	}
	// ...while the three shapes that are refused for the *name* are refused.
	// An empty name is the one the item grammar can produce (`:1`).
	{
		request := rule_request(t, {""}, {"1"})
		defer http.request_destroy(&request)
		text, part, found := http.request_invalid_header(&request)
		testing.expect(t, found, "an empty name is refused")
		testing.expect_value(t, part, http.Invalid_Header_Part.Name)
		testing.expect_value(t, text, "")
	}
	{
		request := rule_request(t, {" X-Note"}, {"1"})
		defer http.request_destroy(&request)
		_, part, found := http.request_invalid_header(&request)
		testing.expect(t, found, "a name keeps its leading space, so it is refused")
		testing.expect_value(t, part, http.Invalid_Header_Part.Name)
	}
	{
		request := rule_request(t, {"\u00a0X-Note"}, {"1"})
		defer http.request_destroy(&request)
		_, _, found := http.request_invalid_header(&request)
		testing.expect(t, found, "the name pattern's \\s is Python's whitespace")
	}
	{
		request := rule_request(t, {"\u3000X-Note"}, {"1"})
		defer http.request_destroy(&request)
		_, _, found := http.request_invalid_header(&request)
		testing.expect(t, found, "above U+00FF too")
	}
}

// invalid_header_message is the exception httpie prints, reprs included: the
// value as a `bytes` repr (it was encoded before requests saw it) and the name
// as a `str` repr (docs/PARITY.md §3.1).
@(test)
test_invalid_header_message_writes_the_reference_repr :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	PREFIX :: "InvalidHeader: Invalid leading whitespace, reserved character(s), or " +
	          "return character(s) in header "

	cases := []struct {
		text:     string,
		part:     http.Invalid_Header_Part,
		expected: string,
	}{
		{
			"line one\nline two",
			.Value,
			PREFIX + "value: b'line one\\nline two'",
		},
		// Every byte above 0x7f is `\xNN`: the repr is of the encoded value.
		{"caf\u00e9\nx", .Value, PREFIX + "value: b'caf\\xc3\\xa9\\nx'"},
		// The delimiter rules: `'` unless the value carries one and no `"`.
		{"it's\nb", .Value, PREFIX + "value: b\"it's\\nb\""},
		{"it's \"a\"\nb", .Value, PREFIX + "value: b'it\\'s \"a\"\\nb'"},
		{"a\\b\nc", .Value, PREFIX + "value: b'a\\\\b\\nc'"},
		// A name is a str: a non-printable character is escaped by code point,
		// a printable one is itself.
		{"X-No\nte", .Name, PREFIX + "name: 'X-No\\nte'"},
		{"\u00a0X-Note", .Name, PREFIX + "name: '\\xa0X-Note'"},
		{"\u3000X-Note", .Name, PREFIX + "name: '\\u3000X-Note'"},
		{"X-N\u00e9te", .Name, PREFIX + "name: 'X-N\u00e9te'"},
		{"", .Name, PREFIX + "name: ''"},
	}

	for sample in cases {
		message := http.invalid_header_message(sample.text, sample.part, allocator)
		testing.expect_value(t, message, sample.expected)
		delete(message, allocator)
	}

	expect_no_leaks(t, &track)
}

// wire_header_refusal is the *second* rule of §3.1: CPython's `putheader`
// validates every header line as it writes it, so the value requests never
// validated — the first of a repeated name — can still end the run. What is
// reachable, and what is not, is the point of this test: the value half takes
// every shape the pattern admits, the name half is legal for every name the
// prepare-time rule already let through, and the two lookahead exceptions (the
// obs-folds) are not refusals.
@(test)
test_wire_header_refusal_reads_the_value_and_the_name :: proc(t: ^testing.T) {
	cases := []struct {
		name:  string,
		value: string,
		part:  http.Invalid_Header_Part,
		found: bool,
		text:  string,
	}{
		// The value half: `\n(?![ \t])|\r(?![ \t\n])`.
		{"X-Note", "a\nb", .Value, true, "a\nb"},
		{"X-Note", "a\rb", .Value, true, "a\rb"},
		// The CR is legal before a LF; the LF after it is examined on its own.
		{"X-Note", "a\r\nb", .Value, true, "a\r\nb"},
		// A return character at the end of the value has nothing to look at.
		{"X-Note", "a\n", .Value, true, "a\n"},
		{"X-Note", "\r", .Value, true, "\r"},
		{"X-Note", "\n\tb", .Value, false, ""},
		{"X-Note", "a\n b", .Value, false, ""},
		{"X-Note", "a\n\tb", .Value, false, ""},
		{"X-Note", "a\r b", .Value, false, ""},
		{"X-Note", "a\r\n b", .Value, false, ""},
		{"X-Note", "Bearer tok\nen", .Value, true, "Bearer tok\nen"},
		// The refusal names the bytes as they are: a non-ASCII byte is itself
		// until the repr escapes it.
		{"X-Note", "caf\u00e9\nx", .Value, true, "caf\u00e9\nx"},
		{"X-Note", "ok", .Value, false, ""},
		{"X-Note", "", .Value, false, ""},
		// The name half: `[^:\s][^:\r\n]*`, with the *bytes* `\s`.
		{"", "1", .Name, true, ""},
		{" X-Note", "1", .Name, true, " X-Note"},
		{"X-Note ", "1", .Name, false, ""},
		{"X:Y", "1", .Name, true, "X:Y"},
		{"X-No\rte", "1", .Name, true, "X-No\rte"},
		{"X-No\nte", "1", .Name, true, "X-No\nte"},
		{"\tX-Note", "1", .Name, true, "\tX-Note"},
		// A byte above 0x7f is not whitespace to the bytes pattern...
		{"X-\u00e9te", "1", .Name, false, ""},
		// ...and the name is examined first, the way putheader validates.
		{"X:Y", "a\nb", .Name, true, "X:Y"},
	}
	for sample in cases {
		text, part, found := http.wire_header_refusal(sample.name, sample.value)
		testing.expectf(
			t,
			found == sample.found,
			"%q: %q: found %v, want %v",
			sample.name,
			sample.value,
			found,
			sample.found,
		)
		if !found {
			continue
		}
		testing.expect_value(t, part, sample.part)
		testing.expect_value(t, text, sample.text)
	}
}

// wire_header_message is the exception httpie prints for it, through the same
// handler as the prepare-time one — but with a `b'…'` repr on *both* halves,
// because `putheader` encodes the name ascii before it validates it, and the
// latin-1 bytes of a `str` value are what its message carries.
@(test)
test_wire_header_message_writes_the_reference_repr :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		text:     string,
		part:     http.Invalid_Header_Part,
		expected: string,
	}{
		{"a\nb", .Value, "ValueError: Invalid header value b'a\\nb'"},
		{"a\rb", .Value, "ValueError: Invalid header value b'a\\rb'"},
		{"a\r\nb", .Value, "ValueError: Invalid header value b'a\\r\\nb'"},
		{"Bearer tok\nen", .Value, "ValueError: Invalid header value b'Bearer tok\\nen'"},
		{"caf\u00e9\nx", .Value, "ValueError: Invalid header value b'caf\\xc3\\xa9\\nx'"},
		{"it's\nb", .Value, "ValueError: Invalid header value b\"it's\\nb\""},
		// The name is the ascii-encoded one, so its repr is a bytes repr too.
		{"X:Y", .Name, "ValueError: Invalid header name b'X:Y'"},
		{"", .Name, "ValueError: Invalid header name b''"},
	}

	for sample in cases {
		failure := http.Wire_Header_Error {
			failed = true,
			part   = sample.part,
			text   = sample.text,
		}
		message := http.wire_header_message(&failure, allocator)
		testing.expect_value(t, message, sample.expected)
		delete(message, allocator)
	}

	expect_no_leaks(t, &track)
}

// The refusal the transport records is owned by the request: the text is cloned
// (the transport's own copy of a `str` value is a temporary of its header loop),
// a second refusal replaces the first without leaking it, and request_destroy
// releases whatever is left.
@(test)
test_wire_header_refuse_owns_its_text :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	{
		request, err := http.request_create(allocator, .GET, "http://example.com", nil)
		testing.expect_value(t, err, http.Error.None)
		source := "a\nb"
		testing.expect_value(
			t,
			http.wire_header_refuse(&request, source, .Value),
			http.Error.Wire_Header_Refused,
		)
		testing.expect(t, request.wire_error.failed)
		testing.expect_value(t, request.wire_error.part, http.Invalid_Header_Part.Value)
		testing.expect_value(t, request.wire_error.text, source)
		// The recorded text is the request's own copy, not the caller's string.
		testing.expect(
			t,
			raw_data(request.wire_error.text) != raw_data(source),
			"the recorded text is a copy",
		)
		// A second refusal replaces the first — and frees it, which the leak
		// check at the end of this test would report otherwise.
		testing.expect_value(
			t,
			http.wire_header_refuse(&request, "X:Y", .Name),
			http.Error.Wire_Header_Refused,
		)
		testing.expect_value(t, request.wire_error.part, http.Invalid_Header_Part.Name)
		testing.expect_value(t, request.wire_error.text, "X:Y")
		http.request_destroy(&request)
	}

	expect_no_leaks(t, &track)
}

// rule_request builds the request the two tests above read, so each case is
// data rather than plumbing.
@(private)
rule_request :: proc(t: ^testing.T, names: []string, values: []string) -> http.Request {
	request, err := http.request_create(context.allocator, .GET, "http://example.com", nil)
	testing.expect_value(t, err, http.Error.None)
	for name, index in names {
		testing.expect_value(
			t,
			http.request_add_header(&request, name, values[index]),
			http.Error.None,
		)
	}
	return request
}

// An argv byte that is not UTF-8 is not whitespace and is not stripped by the
// strip rule: the two are independent, and only the strip's owner (t_05c396f1)
// has a say in what the value becomes before the encoder sees it.
@(test)
test_str_encode_failure_reads_the_string_it_is_given :: proc(t: ^testing.T) {
	// The reference strips the value first, then encodes it (client.py:192-209),
	// so a padded value's error position is inside the *stripped* value.
	stripped := http.header_value_strip(string_of_bytes({0x20, 0xff, 0x20}))
	testing.expect_value(t, stripped, string_of_bytes({0xff}))
	failure := http.str_encode_failure(stripped, .Utf8)
	testing.expect_value(t, failure.position, 0)
}

// The URL's own spelling: urllib3's `_encode_invalid_chars` and requests'
// `requote_uri` (docs/PARITY.md §3.6). The table is the rule's decision points —
// which characters are allowed in which component, what happens to an escape the
// URL already carried, and the '%' that is a literal — which is the half a live
// run cannot show cheaply, because the component is spelled before anything is
// sent.
@(test)
test_url_component_quote_writes_the_reference_spelling :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		component: string,
		part:      http.Url_Component,
		want:      string,
	}{
		// The allowed set is a character set, not "quote everything": the
		// unreserved characters, the sub-delimiters, ':' and '/' stay.
		{"a-b_c.d~e!f$g&h", .Path, "a-b_c.d~e!f$g&h"},
		{"'()*+,;=:@-._~", .Path, "'()*+,;=:@-._~"},
		// '?' is the query's extra character, and only the query's.
		{"a?b", .Path, "a%3Fb"},
		{"a?b", .Query, "a?b"},
		// Everything else is encoded, byte by byte, with uppercase hex.
		{"a b", .Path, "a%20b"},
		{"a|b", .Path, "a%7Cb"},
		{"a[b", .Path, "a%5Bb"},
		{"a^b", .Query, "a%5Eb"},
		// A character above ASCII is the bytes of its UTF-8 form.
		{"h\u00e9llo", .Path, "h%C3%A9llo"},
		{"\u20ac\U0001f600", .Query, "%E2%82%AC%F0%9F%98%80"},
		// A byte that is not valid UTF-8 is the lone surrogate it became.
		{string_of_bytes({'x', 0xff}), .Path, "x%ED%B3%BF"},
		{string_of_bytes({0x80, 0x81}), .Query, "%ED%B2%80%ED%B2%81"},
		// An escape that spells an unreserved character is unquoted again (`%41`
		// → `A`, `%7e` → `~`); one that does not is kept, hex uppercased.
		{"a%41%7eb%5Fc%2Dd", .Path, "aA~b_c-d"},
		{"a%c3%a9b", .Path, "a%C3%A9b"},
		{"a%20b%2Fc", .Query, "a%20b%2Fc"},
		{"a%00b", .Path, "a%00b"},
		// The whole component decides: one '%' that does not start an escape
		// makes every '%' of it a literal — and the hex digits behind it keep the
		// uppercased spelling the normalization gave them (`%4a` → `%254A`).
		{"a%zzb", .Path, "a%25zzb"},
		{"a%b", .Path, "a%25b"},
		{"a%", .Path, "a%25"},
		{"a%%41", .Query, "a%25%2541"},
		{"a%4ab%}", .Path, "a%254Ab%25%7D"},
		{"a%41%zzb", .Path, "a%2541%25zzb"},
	}
	for entry in cases {
		buffer := http.buffer_make(allocator, 0)
		ok := http.url_component_quote_into(&buffer, entry.component, entry.part)
		got := string(buffer.data[:])
		testing.expectf(t, ok, "%q: the write failed", entry.component)
		testing.expectf(
			t,
			got == entry.want,
			"%q: got %q, want %q",
			entry.component,
			got,
			entry.want,
		)
		http.buffer_destroy(&buffer)
	}
	expect_no_leaks(t, &track)
}

// The rule writes *after* whatever the buffer already holds: request_target
// builds the path and then the query in one buffer, and the in-place unquoting
// pass is scoped to the bytes this call wrote.
@(test)
test_url_component_quote_appends_after_what_the_buffer_holds :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	buffer := http.buffer_make(allocator, 0)
	testing.expect(t, http.buffer_append_string(&buffer, "GET /"), "the prefix must be written")
	testing.expect(
		t,
		http.url_component_quote_into(&buffer, "a%41%zz b", .Path),
		"the component must be written",
	)
	testing.expect_value(t, string(buffer.data[:]), "GET /a%2541%25zz%20b")
	http.buffer_destroy(&buffer)
	expect_no_leaks(t, &track)
}

// The redirect target's rule is `requote_uri` *alone* — the composition
// `url_component_quote_into` implements for the first request is not what
// requests applies to a Location (sessions.py:241-243). The rows here are the
// reference's own output for each Location, measured with
// build/probe_redirect_requote.py; the ones that differ from the composition are
// the whole point of the proc: `%c3%a9` keeps its lowercase hex, a raw '%' stays
// a '%', and `[` is in the safe set.
@(test)
test_url_requote_writes_the_reference_spelling :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		location: string,
		want:     string,
	}{
		{"", ""},
		{"/echo", "/echo"},
		// The safe set: always_safe plus `!#$%&'()*+,/:;=?@[]~`.
		{"/echo%20x", "/echo%20x"},
		{"/echo%2Fx", "/echo%2Fx"},
		{"/echo?q=a#b", "/echo?q=a#b"},
		{"/echo?q=a[b]c", "/echo?q=a[b]c"},
		{"/echo?q=a+b;b,c:d@b!b$b&b'b(b)b*b=b", "/echo?q=a+b;b,c:d@b!b$b&b'b(b)b*b=b"},
		// Everything else is quoted, byte by byte, uppercase hex — and a
		// character above ASCII becomes the bytes of its UTF-8 form.
		{"/echo?q=a b", "/echo?q=a%20b"},
		{"/echo?q=a|b", "/echo?q=a%7Cb"},
		{"/echo?q=a{}b", "/echo?q=a%7B%7Db"},
		{"/echo?q=a^b", "/echo?q=a%5Eb"},
		{"/echo?q=a<b>c", "/echo?q=a%3Cb%3Ec"},
		{"/echo?q=a\\b", "/echo?q=a%5Cb"},
		{"/echo?q=h\u00e9llo", "/echo?q=h%C3%A9llo"},
		{"/echo/\u20ac", "/echo/%E2%82%AC"},
		{"/echo/\U0001f600", "/echo/%F0%9F%98%80"},
		// An escape that spells an unreserved character is unquoted again; one
		// that does not is kept *as it is*, hex case included.
		{"/%65cho", "/echo"},
		{"/echo?q=a%41b", "/echo?q=aAb"},
		{"/echo?q=%7e%5F%2D%2E", "/echo?q=~_-."},
		{"/echo%c3%a9", "/echo%c3%a9"},
		// '%' is in the safe set, so a '%' that starts no escape survives.
		{"/echo?q=100%", "/echo?q=100%"},
		{"/echo?q=a%41%", "/echo?q=aA%"},
		{"/echo?q=a%%41", "/echo?q=a%A"},
		// One unreadable escape decides for the whole string: `%` leaves the
		// safe set and the escapes that would have been unquoted are not.
		{"/echo?q=%zz", "/echo?q=%25zz"},
		{"/echo?q=%0x", "/echo?q=%250x"},
		{"/echo?q=a%41%zz", "/echo?q=a%2541%25zz"},
		{"/echo?q=%C3%A9%zz", "/echo?q=%25C3%25A9%25zz"},
		// A non-ASCII character in the two-character escape window: a letter
		// makes `h.isalnum()` true and `int(h, 16)` raise (InvalidURL, the
		// whole-string branch), a symbol leaves the '%' alone.
		{"/echo?q=%\u00e91", "/echo?q=%25%C3%A91"},
		{"/echo?q=%\u20ac1", "/echo?q=%%E2%82%AC1"},
		{"/echo?q=a%41%\u00e91", "/echo?q=a%2541%25%C3%A91"},
		{"/echo?q=a%41%\u20ac1", "/echo?q=aA%%E2%82%AC1"},
		{"/echo?q=a%41%\U0001f6001", "/echo?q=aA%%F0%9F%98%801"},
		// A whole URL: the rule is applied to the string, host and all.
		{"http://example.org/x?a=b c", "http://example.org/x?a=b%20c"},
		{"http://example.org/%65cho", "http://example.org/echo"},
		{"//example.org/a b", "//example.org/a%20b"},
		// A byte that is not valid UTF-8.  The reference never asks requote_uri
		// for this spelling: `get_redirect_target` decodes the Location as UTF-8
		// and raises UnicodeDecodeError on a byte like this one, so the hop is
		// never made (build/probe_location_decoding.py).  The row pins what the
		// proc does with the bytes it is handed, not a reference answer.
		{string_of_bytes({'/', 0xff}), "/%FF"},
	}
	for entry in cases {
		buffer := http.buffer_make(allocator, 0)
		ok := http.url_requote_into(&buffer, entry.location)
		got := string(buffer.data[:])
		testing.expectf(t, ok, "%q: the write failed", entry.location)
		testing.expectf(
			t,
			got == entry.want,
			"%q: got %q, want %q",
			entry.location,
			got,
			entry.want,
		)
		http.buffer_destroy(&buffer)
	}
	expect_no_leaks(t, &track)
}

// url_unquoted_into writes the *input* of `requote_uri` — `unquote_unreserved`
// alone, with CPython's `quote` left out — which is the string `quote` is handed
// and therefore the string the positions of the `UnicodeEncodeError` a byte that
// is not valid UTF-8 raises in are counted in (docs/PARITY.md §3.6, §8 item 21,
// t_dabbcebf). It is the rows above with the quoting step taken back out: an
// escape of an unreserved character is unquoted, every other byte — a kept
// escape, a '%' that starts none, the space `quote` would spell `%20` — is
// written as it is.
@(test)
test_url_unquoted_writes_the_string_quote_is_handed :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		component: string,
		fallback:  bool,
		want:      string,
	}{
		{"", false, ""},
		{"/echo", false, "/echo"},
		{"/echo%20x", false, "/echo%20x"},
		{"/echo?q=a b", false, "/echo?q=a b"},
		{"/%65cho", false, "/echo"},
		{"/echo?q=a%41b", false, "/echo?q=aAb"},
		{"/echo?q=%7e%5F%2D%2E", false, "/echo?q=~_-."},
		{"/echo%c3%a9", false, "/echo%c3%a9"},
		{"/echo?q=a%%41", false, "/echo?q=a%A"},
		{"/echo/\\u00e9", false, "/echo/\\u00e9"},
		// The except-branch: `unquote_unreserved` raised, so `quote` is handed
		// the *raw* string and nothing in it is unquoted.
		{"/echo?q=%zz", true, "/echo?q=%zz"},
		{"/echo?q=a%41%zz", true, "/echo?q=a%41%zz"},
		// A byte that is not valid UTF-8 is a character like any other to this
		// half: it writes it as it stands, and the refusal is `quote`'s.
		{"/\xff", false, "/\xff"},
		{"/\xff", true, "/\xff"},
	}
	for entry in cases {
		buffer := http.buffer_make(allocator, 0)
		ok := http.url_unquoted_into(&buffer, entry.component, entry.fallback)
		got := string(buffer.data[:])
		testing.expectf(t, ok, "%q: the write failed", entry.component)
		testing.expectf(
			t,
			got == entry.want,
			"%q (fallback=%v): got %q, want %q",
			entry.component,
			entry.fallback,
			got,
			entry.want,
		)
		http.buffer_destroy(&buffer)
	}
	expect_no_leaks(t, &track)
}

// `request_other_scheme_url` keeps the URL in both of the spellings
// `requote_uri` works in: the requoted one requests holds (`url_text`, the
// string the refusal quotes) and the *unquoted* one it was handed
// (`url_unquoted`), which is where the position of a `UnicodeEncodeError` is
// counted. The `name==value` items are not known when the URL is built, so the
// second string stops at the offset they go in at — right before the fragment.
@(test)
test_request_other_scheme_url_keeps_the_unquoted_reconstruction :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		url:      string,
		unquoted: string,
		url_text: string,
		items_at: int,
	}{
		// The escape of an unreserved character is unquoted in both, so the
		// two strings agree here and the offset is the fragment's '#'.
		{
			"httpx://127.0.0.1:9/a%41b?q=1#f",
			"httpx://127.0.0.1:9/aAb?q=1#f",
			"httpx://127.0.0.1:9/aAb?q=1#f",
			len("httpx://127.0.0.1:9/aAb?q=1"),
		},
		// A space is one character of the unquoted string where the requoted
		// one spells it `%20` — the difference the position is counted in.
		{
			"httpx://127.0.0.1:9/a b#f",
			"httpx://127.0.0.1:9/a b#f",
			"httpx://127.0.0.1:9/a%20b#f",
			len("httpx://127.0.0.1:9/a b"),
		},
		// No query and no fragment: the offset is the end of the string, and
		// the items put their own '?' there (`request_check_other_scheme_url`).
		{
			"httpx://127.0.0.1:9/echo",
			"httpx://127.0.0.1:9/echo",
			"httpx://127.0.0.1:9/echo",
			len("httpx://127.0.0.1:9/echo"),
		},
		// The except-branch: every '%' of the raw URL is a literal, so the
		// unquoted string keeps them all and unquotes nothing.
		{
			"httpx://127.0.0.1:9/a%41%zz",
			"httpx://127.0.0.1:9/a%41%zz",
			"httpx://127.0.0.1:9/a%2541%25zz",
			len("httpx://127.0.0.1:9/a%41%zz"),
		},
	}
	for entry in cases {
		req, err := http.request_create(allocator, .GET, entry.url, nil)
		testing.expectf(t, err == http.Error.None, "%q: request_create failed", entry.url)
		if err != .None {
			continue
		}
		testing.expectf(t, req.url_unquoted == entry.unquoted,
		                "%q → unquoted %q, want %q", entry.url, req.url_unquoted, entry.unquoted)
		testing.expectf(t, req.url_text == entry.url_text,
		                "%q → url_text %q, want %q", entry.url, req.url_text, entry.url_text)
		testing.expectf(t, req.url_unquoted_items_at == entry.items_at,
		                "%q → items_at %d, want %d", entry.url, req.url_unquoted_items_at, entry.items_at)
		// Nothing here is unencodable: the check is quiet.
		testing.expectf(t, http.request_check_other_scheme_url(&req) == http.Error.None,
		                "%q: the URL was refused", entry.url)
		http.request_destroy(&req)
	}
	expect_no_leaks(t, &track)
}

// The position requests' `UnicodeEncodeError` carries is the code point index of
// the character in the *unquoted reconstruction*, and the rows below are the
// reference's own output (build/probe_no_adapter_target.py): a space counts as
// one character where the URL spells it `%20`, an escape of an unreserved
// character is unquoted first, the `name==value` items sit inside the string
// (so the fragment's position moves by their length), and a run of such
// characters is reported as a range.
@(test)
test_request_check_other_scheme_url_counts_the_reconstruction :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	BASE :: "httpx://127.0.0.1:9/"
	cases := []struct {
		url:      string,
		item:     string, // "name=value", or "" for no item
		failed:   bool,
		position: int,
		end:      int,
	}{
		// The card's two rows.
		{BASE + "\xff", "", true, 20, 20},
		{BASE + "a b\xff", "", true, 23, 23},
		// The fragment, with and without the item that goes in front of it.
		{BASE + "?q=1#\xff", "", true, 25, 25},
		{BASE + "?q=1#\xff", "k=v", true, 29, 29},
		// The userinfo, which is a component of the same string.
		{"httpx://us\xffer@127.0.0.1:9/x", "", true, 10, 10},
		// `unquote_unreserved` first: `%41` is `A` by the time `quote` counts.
		{BASE + "a%41\xff", "", true, 22, 22},
		// The except-branch counts in the *raw* string.
		{BASE + "a%zz\xff", "", true, 24, 24},
		// Two in a row is the range CPython reports.
		{BASE + "x\xff\xff", "", true, 21, 22},
		// The control: a prepared no-adapter URL with no such byte is not this
		// failure — the adapter lookup is what refuses it.
		{BASE + "echo?q=1#f", "k=v", false, 0, 0},
	}
	for entry in cases {
		req, err := http.request_create(allocator, .GET, entry.url, nil)
		testing.expectf(t, err == http.Error.None, "%q: request_create failed", entry.url)
		if err != .None {
			continue
		}
		if entry.item != "" {
			eq := strings.index_byte(entry.item, '=')
			err = http.request_add_query(&req, entry.item[:eq], entry.item[eq + 1:])
			testing.expectf(t, err == http.Error.None, "%q: request_add_query failed", entry.item)
		}
		check_err := http.request_check_other_scheme_url(&req)
		if !entry.failed {
			testing.expectf(t, check_err == http.Error.None, "%q: refused, want it quiet", entry.url)
			http.request_destroy(&req)
			continue
		}
		testing.expectf(t, check_err == http.Error.Str_Not_Encodable,
		                "%q: check_error %v, want Str_Not_Encodable", entry.url, check_err)
		testing.expectf(t, req.encode_error.failed, "%q: no error was recorded", entry.url)
		testing.expectf(t, req.encode_error.position == entry.position,
		                "%q: position %d, want %d", entry.url, req.encode_error.position, entry.position)
		testing.expectf(t, req.encode_error.end == entry.end,
		                "%q: end %d, want %d", entry.url, req.encode_error.end, entry.end)
		http.request_destroy(&req)
	}

	// The exception's own wording, from the first row: `quote` re-encodes with
	// the default codec, so the character is the lone surrogate PEP 383 made of
	// the byte and the reason is CPython's.
	req, err := http.request_create(allocator, .GET, BASE + "\xff", nil)
	testing.expect_value(t, err, http.Error.None)
	testing.expect_value(t, http.request_check_other_scheme_url(&req), http.Error.Str_Not_Encodable)
	message := http.str_encode_error_message(&req.encode_error, allocator)
	testing.expect_value(
		t,
		message,
		"UnicodeEncodeError: 'utf-8' codec can't encode character '\\udcff' in position 20: surrogates not allowed",
	)
	// Released before the leak check: the message is the caller's, and this is
	// the site that owns it.
	delete(message, allocator)
	http.request_destroy(&req)

	expect_no_leaks(t, &track)
}

// The wire's spelling of a followed hop: the URL requests prepared, with its
// path and query encoded by urllib3 at send time (`_encode_target`,
// util/url.py:453-467) — no requote, so the cases above whose rendering keeps a
// lowercase escape, a raw '%' or a bracket are the ones this pass changes.
@(test)
test_url_wire_url_encodes_the_prepared_target :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		prepared: string,
		want:     string,
	}{
		{"http://h/echo", "http://h/echo"},
		{"http://h", "http://h/"},
		{"http://h?q=1", "http://h/?q=1"},
		// The origin is left as it stands, the target is encoded.
		{"http://h:8080/echo?q=a b", "http://h:8080/echo?q=a%20b"},
		{"http://h/echo?q=a|b", "http://h/echo?q=a%7Cb"},
		{"http://h/echo?q=a[b]c", "http://h/echo?q=a%5Bb%5Dc"},
		{"http://h/echo%c3%a9", "http://h/echo%C3%A9"},
		{"http://h/echo?q=100%", "http://h/echo?q=100%25"},
		{"http://h/echo?q=aA%%E2%82%AC1", "http://h/echo?q=aA%25%25E2%2582%25AC1"},
		{"http://h/echo?q=%25zz", "http://h/echo?q=%25zz"},
		{"http://h/\u20ac", "http://h/%E2%82%AC"},
		// The fragment is not part of the target (requests' `path_url`).
		{"http://h/echo?q=x#frag", "http://h/echo?q=x"},
		{"http://h/echo?a=b#frag", "http://h/echo?a=b"},
	}
	for entry in cases {
		buffer := http.buffer_make(allocator, 0)
		ok := http.url_wire_url_into(&buffer, entry.prepared)
		got := string(buffer.data[:])
		testing.expectf(t, ok, "%q: the write failed", entry.prepared)
		testing.expectf(
			t,
			got == entry.want,
			"%q: got %q, want %q",
			entry.prepared,
			got,
			entry.want,
		)
		http.buffer_destroy(&buffer)
	}
	expect_no_leaks(t, &track)
}

// A hop's history message renders the URL requests prepared, not the one the
// wire carries: `target_verbatim` is what keeps the second pass off the path and
// the query (the session sets it in write_hop_request).
@(test)
test_request_target_verbatim_keeps_the_prepared_spelling :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	req := http.Request {
		allocator = allocator,
		path      = "/echo",
		query_raw = "q=a[b]c%c3%a9",
	}
	req.target_verbatim = true
	target, err := http.request_target(&req, allocator)
	testing.expect_value(t, err, http.Error.None)
	testing.expect_value(t, target, "/echo?q=a[b]c%c3%a9")
	delete(target, allocator)

	req.target_verbatim = false
	quoted, quote_err := http.request_target(&req, allocator)
	testing.expect_value(t, quote_err, http.Error.None)
	testing.expect_value(t, quoted, "/echo?q=a%5Bb%5Dc%C3%A9")
	delete(quoted, allocator)
	expect_no_leaks(t, &track)
}

// `--path-as-is` is the third spelling of the path, beside the two above: httpie
// puts the *argv* URL's path component back into the prepared URL
// (client.py:94-98, `ensure_path_as_is`), so the path the request owns and
// renders is the raw one — neither reduced nor requoted — while the URL's own
// query is not part of that replacement and is requoted as always. The prepared
// URL keeps the same raw path; encoding it once is the connection's job
// (docs/PARITY.md §3.6).
@(test)
test_request_path_as_is_keeps_the_argv_path :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		url:      string,
		path:     string, // what the Request owns
		target:   string, // what the request line renders
		prepared: string, // `request_url`: the URL the transport is handed
	}{
		{"http://example.org/a/./b", "/a/./b", "/a/./b", "http://example.org/a/./b"},
		{"http://example.org/a/../b c", "/a/../b c", "/a/../b c", "http://example.org/a/../b c"},
		{"http://example.org/a/%2e/b", "/a/%2e/b", "/a/%2e/b", "http://example.org/a/%2e/b"},
		{"http://example.org/a/%41/../b", "/a/%41/../b", "/a/%41/../b", "http://example.org/a/%41/../b"},
		{"http://example.org/a[b]/../c", "/a[b]/../c", "/a[b]/../c", "http://example.org/a[b]/../c"},
		{"http://example.org/a/./b?q=a b", "/a/./b", "/a/./b?q=a%20b",
		 "http://example.org/a/./b?q=a%20b"},
		{"http://example.org", "/", "/", "http://example.org/"},
	}
	for row in cases {
		req, err := http.request_create(allocator, .GET, row.url, nil, true)
		testing.expect_value(t, err, http.Error.None)
		if err != .None {
			continue
		}
		testing.expectf(t, req.path_as_is, "%q: the flag did not reach the request", row.url)
		testing.expectf(t, req.path == row.path, "%q → path %q, want %q", row.url, req.path, row.path)

		target, target_err := http.request_target(&req, allocator)
		testing.expect_value(t, target_err, http.Error.None)
		testing.expectf(t, target == row.target, "%q → target %q, want %q", row.url, target, row.target)
		delete(target, allocator)

		// The URL the transport is handed carries the raw path as well: it is
		// the connection that encodes it on the way out.
		prepared, url_err := http.request_url(&req, allocator)
		testing.expect_value(t, url_err, http.Error.None)
		testing.expectf(t, prepared == row.prepared, "%q → prepared URL %q, want %q",
		                row.url, prepared, row.prepared)
		delete(prepared, allocator)
		http.request_destroy(&req)
	}
	expect_no_leaks(t, &track)
}

// The `Host` header is the *prepared* URL's netloc minus its userinfo, so the
// port survives whenever the value `_HOST_PORT_RE` read is not zero — an
// explicit scheme default included — and what a padded text contributes is the
// value, not the text (docs/PARITY.md §3.6, t_e0694c8a). The reference's own
// bytes are the `url-host-port-default-*` scenarios' business; this is the unit
// proof of the two branches and of what they own.
@(test)
test_host_header_keeps_the_port_the_url_spelled :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		url:  string,
		host: string,
	}{
		{"http://example.org/x", "example.org"},
		{"http://example.org:80/x", "example.org:80"},
		{"http://example.org:0080/x", "example.org:80"},
		{"http://example.org:000/x", "example.org"},
		{"http://example.org:0/x", "example.org"},
		{"http://example.org:8080/x", "example.org:8080"},
		{"https://example.org:443/x", "example.org:443"},
		{"https://example.org:80/x", "example.org:80"},
		{"http://[::1]:80/x", "[::1]:80"},
	}
	for row in cases {
		req, err := http.request_create(allocator, .GET, row.url, nil)
		testing.expect_value(t, err, http.Error.None)
		if err != .None {
			continue
		}
		host, host_err := http.request_host_header(&req, allocator)
		testing.expect_value(t, host_err, http.Error.None)
		testing.expectf(t, host == row.host, "%q → Host %q, want %q", row.url, host, row.host)
		delete(host, allocator)
		http.request_destroy(&req)
	}
	expect_no_leaks(t, &track)
}

// must_clone is the two-value form with the error checked: a test that cannot
// allocate has nothing useful to continue with.
must_clone :: proc(t: ^testing.T, s: string, allocator: mem.Allocator) -> string {
	clone, err := strings.clone(s, allocator)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	return clone
}

// `str_is_printable` is CPython's `str.isprintable()`, and the table behind it
// is generated from the *reference interpreter's* Unicode database
// (src/http/unicode_printable_generated.odin,
// build/gen_unicode_printable_table.py). The hash below is the check that the
// compiled predicate answers for **every** code point the way that database
// does: FNV-1a 64 over the bitmap of the printable bit of each code point
// 0x0..0x10ffff in order, most-significant bit first — the same value the
// generator computes from `unicodedata`, so a table that drifted, or a binary
// search that misses a range by one, fails here rather than on one shape.
@(test)
test_str_is_printable_matches_the_generated_bitmap :: proc(t: ^testing.T) {
	// The boundaries the rule turns on, named one by one: the ASCII space, the
	// last printable byte, DEL, the C1 bottom, the two sides of the `\xNN`
	// boundary (0xa0 and 0xad are not printable, 0xa1 and 0x377 are), the
	// private-use range, the last code point of the BMP and the first astral
	// one — which is printable.
	testing.expect(t, http.str_is_printable(0x20), "the ASCII space is printable")
	testing.expect(t, http.str_is_printable(0x7e), "~ is printable")
	testing.expect(t, !http.str_is_printable(0x7f), "DEL is not")
	testing.expect(t, !http.str_is_printable(0x85), "U+0085 (C1) is not")
	testing.expect(t, !http.str_is_printable(0xa0), "U+00A0 (Zs) is not")
	testing.expect(t, http.str_is_printable(0xa1), "U+00A1 is printable")
	testing.expect(t, !http.str_is_printable(0xad), "U+00AD (Cf) is not")
	testing.expect(t, !http.str_is_printable(0x378), "U+0378 (Cn) is not")
	testing.expect(t, http.str_is_printable(0x377), "U+0377 is printable")
	testing.expect(t, !http.str_is_printable(0x200b), "U+200B (Cf) is not")
	testing.expect(t, !http.str_is_printable(0x3000), "U+3000 (Zs) is not")
	testing.expect(t, !http.str_is_printable(0xe000), "U+E000 (Co) is not")
	testing.expect(t, http.str_is_printable(0xf900), "U+F900 is printable")
	testing.expect(t, !http.str_is_printable(0xffff), "U+FFFF (Cn) is not")
	testing.expect(t, http.str_is_printable(0x10000), "U+10000 is printable")
	testing.expect(t, !http.str_is_printable(0xe0001), "U+E0001 (Cf) is not")
	testing.expect(t, http.str_is_printable(0xe0100), "U+E0100 is printable")
	testing.expect(t, !http.str_is_printable(0x1fae8), "U+1FAE8 (Cn) is not")
	testing.expect(t, http.str_is_printable(0x1f780), "U+1F780 is printable")

	hash := u64(0xcbf29ce484222325)
	byte_value := u8(0)
	bit := u8(0x80)
	for code := rune(0); code <= 0x10ffff; code += 1 {
		if http.str_is_printable(code) {
			byte_value |= bit
		}
		bit >>= 1
		if bit == 0 {
			hash = (hash ~ u64(byte_value)) * u64(0x100000001b3)
			byte_value = 0
			bit = 0x80
		}
	}
	testing.expect_value(t, hash, http.PYTHON_PRINTABLE_BITMAP_HASH)
}

// should_strip_authorization is requests' should_strip_auth (sessions.py:128-158)
// case for case: credentials do not follow a redirect to another host, another
// port or another scheme, with the one exception of a standard-port http ->
// https upgrade on the same host. The expected column is the reference's own
// answer, measured against requests 2.33.0 (docs/security-findings.md §9.1).
@(test)
test_should_strip_authorization_matches_requests :: proc(t: ^testing.T) {
	cases := [?]struct {
		old_url: string,
		new_url: string,
		strip:   bool,
	}{
		{"http://h/a", "https://h/b", false},
		{"http://h:80/a", "https://h:443/b", false},
		{"http://h/a", "http://h/b", false},
		{"http://h:443/a", "https://h:443/b", true},
		{"https://h:80/a", "https://h/b", true},
		{"http://h:8080/a", "https://h:8080/b", true},
		{"http://h/a", "https://h:8443/b", true},
		{"http://h/a", "http://h:8080/b", true},
		{"http://h/a", "https://other/b", true},
	}
	for test_case in cases {
		got := http.should_strip_authorization(test_case.old_url, test_case.new_url)
		testing.expectf(
			t,
			got == test_case.strip,
			"%s -> %s: got strip=%v, want %v",
			test_case.old_url,
			test_case.new_url,
			got,
			test_case.strip,
		)
	}
}

