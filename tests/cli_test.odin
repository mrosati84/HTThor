package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "src:cli"
import "src:http"
import "src:rich"

@(test)
test_parse_args_defaults :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	options, err := parse_cli([]string{"oj", "example.com"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	testing.expect_value(t, options.method, http.Method.GET)
	testing.expect_value(t, options.url, "example.com")
	testing.expect_value(t, options.body_kind, cli.Body_Kind.JSON)
	testing.expect_value(t, options.print, cli.Print_Set{cli.Print_Kind.Response_Headers, cli.Print_Kind.Response_Body})
	testing.expect(t, options.verify == "yes", "TLS verification follows httpie's default (\"yes\")")
	testing.expect(t, options.format_options.json_sort_keys, "keys are sorted by default")
	testing.expect(t, options.format_options.headers_sort, "headers are sorted by default")
	testing.expect(t, options.max_redirects > 0, "redirect following has a default budget")
	// httpie's `http` script defaults to http:// for a URL that names no
	// scheme; only the `https` script defaults to https (cli/argparser.py).
	scheme, has_default_scheme := options.default_scheme.?
	testing.expect(t, has_default_scheme, "the program's default scheme is always set")
	testing.expect_value(t, scheme, http.Scheme.HTTP)

	cli.options_destroy(&options)
	expect_no_leaks(t, &track)
}

@(test)
test_parse_args_reads_flags_in_both_forms :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	argv := []string{
		"oj",
		"--offline",
		"--follow",
		"--timeout=5",
		"--max-redirects", "7",
		"-p", "HBhb",
		"--default-scheme=http",
		"-a", "user:pass",
		"POST",
		"https://example.com/things",
		"name=value",
	}
	options, err := parse_cli(argv, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

	testing.expect(t, options.offline, "--offline")
	testing.expect(t, options.follow, "--follow")
	testing.expect_value(t, options.timeout_s, 5)
	testing.expect_value(t, options.max_redirects, 7)
	testing.expect_value(t, options.method, http.Method.POST)
	testing.expect_value(t, options.url, "https://example.com/things")
	testing.expect_value(t, options.auth, "user:pass")
	testing.expect_value(t, len(options.items), 1)
	testing.expect_value(t, options.items[0], "name=value")
	testing.expect_value(t, options.print, cli.Print_Set{
		cli.Print_Kind.Request_Headers,
		cli.Print_Kind.Request_Body,
		cli.Print_Kind.Response_Headers,
		cli.Print_Kind.Response_Body,
	})
	scheme, has_scheme := options.default_scheme.?
	testing.expect(t, has_scheme, "--default-scheme was given")
	testing.expect_value(t, scheme, http.Scheme.HTTP)

	cli.options_destroy(&options)
	expect_no_leaks(t, &track)
}

@(test)
test_parse_args_usage_errors_release_partial_options :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// --offline and the URL allocate before --bogus is rejected, so this also
	// covers the cleanup path in usage_error.
	argv := []string{"oj", "--offline", "https://example.com/", "--bogus"}
	_, err := parse_cli(argv, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
	testing.expectf(t, strings.contains(err.message, "--bogus"), "unexpected message: %s", err.message)
	cli.parse_error_destroy(&err)
	expect_no_leaks(t, &track)
}

@(test)
test_parse_args_rejects_missing_value :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	_, err := parse_cli([]string{"oj", "example.com", "--timeout"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
	testing.expectf(t, strings.contains(err.message, "--timeout"), "unexpected message: %s", err.message)
	cli.parse_error_destroy(&err)
	expect_no_leaks(t, &track)
}

@(test)
test_parse_args_double_dash_ends_flags :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	options, err := parse_cli([]string{"oj", "--offline", "--", "example.com", "--offline=x"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	testing.expect_value(t, options.url, "example.com")
	testing.expect_value(t, len(options.items), 1)
	testing.expect_value(t, options.items[0], "--offline=x")

	cli.options_destroy(&options)
	expect_no_leaks(t, &track)
}

@(test)
test_parse_args_second_method_like_item_is_an_item :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// `http example.com POST`: the URL slot is not a method, so `example.com`
	// takes it and `POST` has to be a request item — and a bare word without a
	// separator is not one. The reference exits 1 with "'POST' is not a valid
	// value".
	_, err := parse_cli([]string{"oj", "example.com", "POST"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
	testing.expectf(
		t,
		strings.contains(err.message, "'POST' is not a valid value"),
		"unexpected message: %s",
		err.message,
	)

	cli.parse_error_destroy(&err)
	expect_no_leaks(t, &track)
}

// The item half of every message an item reader raises is `repr()`ed
// (requestitems.py:147-155, :212-232), and CPython's `repr()` spells a
// **non-printable code point below 0x100** as `\xNN` with two lowercase hex
// digits. `python_repr` (src/cli/items.odin) escaped the backslash, the
// delimiter and `	`/`\n`/`\r` and copied every other control byte as itself, so
// the message's item half carried the byte where the reference carries its
// escape (t_b7f70eee). A **C1** control (U+0080-U+009F) is the same escape one
// code point higher — it is above 0x7f, so the walk copied the two UTF-8 bytes
// it is — and DEL is the byte at the top of the ASCII half.
//
// The escape belongs to the item grammar, so it is in every message that quotes
// an item. The table is one shape per case of the walk:
//
//   * a control character the JSON scanner itself refuses — `a:="a\x01b"` is
//     `Invalid control character at: line 1 column 3 (char 2)`, and the position
//     is the character's own on both sides (that half was never the defect);
//   * a control character that is *not* a JSON-string character, so the refusal
//     that quotes the item is `Expecting value` instead: DEL, one byte above the
//     scanner's `d <= 0x1f`, and a C1 control, above 0x7f;
//   * the bounds of each half — 0x1f at the top of the refused range, 0x80 and
//     0x9f at the two ends of the C1 range;
//   * the controls: `	` is a short escape the port always spelled the
//     reference's way, and U+00A1 is a *printable* two-byte character whose lead
//     byte is the same 0xc2 a C1 control's is, so it has to stay literal.
//
// The parity block `item-repr-control-*` compares the whole command (usage line,
// message, stderr bytes and exit status) against the reference; this test
// asserts the same message at the parser, without a process in the way.
@(test)
test_parse_args_item_message_repr_escapes_a_control_character :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := [?]struct {
		item: string,
		want: string,
	}{
		// The JSON scanner's own refusal (the card's measured shapes).
		{"a:=\"a\x01b\"", "'a:=\"a\\x01b\"': Invalid control character at: line 1 column 3 (char 2)"},
		{"a:=\"\x01\"", "'a:=\"\\x01\"': Invalid control character at: line 1 column 2 (char 1)"},
		{"a:=\"a\x1fb\"", "'a:=\"a\\x1fb\"': Invalid control character at: line 1 column 3 (char 2)"},
		// A control character that is not a JSON-string character: DEL sits one
		// byte above the scanner's range and a C1 control above 0x7f, so both
		// parse as far as the scanner is concerned and the other refusal quotes
		// the item.
		{"a:=\x7f", "'a:=\\x7f': Expecting value: line 1 column 1 (char 0)"},
		{"a:=\x01", "'a:=\\x01': Expecting value: line 1 column 1 (char 0)"},
		{"a:=\xc2\x85", "'a:=\\x85': Expecting value: line 1 column 1 (char 0)"},
		{"a:=\xc2\x80", "'a:=\\x80': Expecting value: line 1 column 1 (char 0)"},
		{"a:=\xc2\x9f", "'a:=\\x9f': Expecting value: line 1 column 1 (char 0)"},
		// The controls.
		{"a:=\"a\tb\"", "'a:=\"a\\tb\"': Invalid control character at: line 1 column 3 (char 2)"},
		{"a:=\xc2\xa1", "'a:=\xc2\xa1': Expecting value: line 1 column 1 (char 0)"},
	}
	for entry in cases {
		argv := []string{
			"oj", "--offline", "--ignore-stdin", "-p", "HB", "POST", "example.com", entry.item,
		}
		_, err := parse_cli(argv, allocator)
		testing.expectf(
			t,
			err.kind == cli.Parse_Error_Kind.Usage && err.message == entry.want,
			"%q: want %q, got %v / %q",
			entry.item,
			entry.want,
			err.kind,
			err.message,
		)
		cli.parse_error_destroy(&err)
	}

	expect_no_leaks(t, &track)
}

// The second half of the same walk (t_b7f70eee is the first): CPython's
// `repr()` copies a character only when `str.isprintable()` answers True for
// it, so a code point of the `C*` (other) or `Z*` (separator) categories is
// escaped — `\xNN` below 0x100, `\uNNNN` below 0x10000 and `\UNNNNNNNN` above
// it, all lowercase — where the port used to copy the argv bytes it holds.
// The shapes below are the measured table of build/probe_repr_nonprintable.py
// (which is where the three boundaries come from: 0xad is the last
// non-printable below 0x100, 0x378 the first above it and 0xffff the last
// below 0x10000), and the ones at the end are the controls — a printable
// character of the same width, which the walk must keep copying. §3.6 is the
// rule; `str_is_printable` (tests/http_test.odin) is the predicate.
@(test)
test_parse_args_item_message_repr_escapes_a_nonprintable_character :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := [?]struct {
		item: string,
		want: string,
	}{
		// The format characters (`Cf`).
		{"a:=\"\uFEFF\" x", "'a:=\"\\ufeff\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\u200B\" x", "'a:=\"\\u200b\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\u00AD\" x", "'a:=\"\\xad\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\u0600\" x", "'a:=\"\\u0600\" x': Extra data: line 1 column 5 (char 4)"},
		// The astral one, whose escape is eight hex digits.
		{"a:=\"\U000E0001\" x", "'a:=\"\\U000e0001\" x': Extra data: line 1 column 5 (char 4)"},
		// The separators (`Zs`, `Zl`, `Zp`).
		{"a:=\"\u00A0\" x", "'a:=\"\\xa0\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\u2028\" x", "'a:=\"\\u2028\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\u3000\" x", "'a:=\"\\u3000\" x': Extra data: line 1 column 5 (char 4)"},
		// The unassigned code points (`Cn`) and the private-use ones (`Co`).
		{"a:=\"\u0378\" x", "'a:=\"\\u0378\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\uFFFF\" x", "'a:=\"\\uffff\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\uE000\" x", "'a:=\"\\ue000\" x': Extra data: line 1 column 5 (char 4)"},
		// U+1FAE8 was assigned by Unicode 15.0 and is unassigned to the
		// reference interpreter's database, which is the one the table is
		// generated from: the escape is the astral one.
		{"a:=\"\U0001FAE8\" x", "'a:=\"\\U0001fae8\" x': Extra data: line 1 column 5 (char 4)"},
		// The controls: printable characters of the same width, copied.
		{"a:=\"\u0377\" x", "'a:=\"\u0377\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\u00E9\" x", "'a:=\"é\" x': Extra data: line 1 column 5 (char 4)"},
		{"a:=\"\U0001F780\" x", "'a:=\"\U0001f780\" x': Extra data: line 1 column 5 (char 4)"},
	}
	for entry in cases {
		argv := []string{
			"oj", "--offline", "--ignore-stdin", "-p", "HB", "POST", "example.com", entry.item,
		}
		_, err := parse_cli(argv, allocator)
		testing.expectf(
			t,
			err.kind == cli.Parse_Error_Kind.Usage && err.message == entry.want,
			"%q: want %q, got %v / %q",
			entry.item,
			entry.want,
			err.kind,
			err.message,
		)
		cli.parse_error_destroy(&err)
	}

	expect_no_leaks(t, &track)
}

// A `\` in an item consumes the character that follows it
// (httpie/cli/argtypes.py:121-127): an even run in front of a separator keeps
// its pairs whole — `\\:` is two literal backslashes and a *live* `:`, not an
// escaped one — and an odd run leaves the `\` that escapes the character. Both
// call sites of that rule are in `src/cli/items.odin` and both are asserted
// here, because only one of them is visible at a time: `unescape` is what the
// key, the value and the path of a missing-file message are made of, while
// `split_point` is what decides *which* separator the item is split on (a scan
// that escaped the `=` of `a\\=b=c` would read the second `=` instead, and the
// key would be `a\\=b`). t_7dce3f8a; §3.2, the `request-items-backslash-pair-*`
// scenarios and build/probe_item_backslash_pairs.py measure the same rule end
// to end.
@(test)
test_parse_args_backslash_pair_consumes_the_character :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The pair is kept whole and the separator behind it is live: the item is
	// the header `a\\` with the value `b` (two backslashes, then `b`).
	options, err := parse_cli([]string{"oj", "--offline", "example.com", "a\\\\:b"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	testing.expect_value(t, len(options.item_set.headers), 1)
	testing.expect_value(t, options.item_set.headers[0].name, "a\\\\")
	testing.expect_value(t, options.item_set.headers[0].value, "b")
	cli.options_destroy(&options)

	// Four backslashes are two pairs, all four kept.
	options, err = parse_cli([]string{"oj", "--offline", "example.com", "a\\\\\\\\:b"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	testing.expect_value(t, options.item_set.headers[0].name, "a\\\\\\\\")
	cli.options_destroy(&options)

	// An odd run is a pair and then an escape: three backslashes leave two and
	// escape the `:`, so the *next* `:` is the separator and the name keeps it.
	options, err = parse_cli([]string{"oj", "--offline", "example.com", "a\\\\\\:b:value"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	testing.expect_value(t, options.item_set.headers[0].name, "a\\\\:b")
	testing.expect_value(t, options.item_set.headers[0].value, "value")
	cli.options_destroy(&options)

	// The separator *scan*'s half: the pair makes the first `=` live, so the key
	// is `a\\` and the value `b=c` — not the key `a\\=b` a one-byte scan reads.
	options, err = parse_cli([]string{"oj", "--offline", "example.com", "a\\\\=b=c"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	testing.expect_value(t, len(options.item_set.data), 1)
	testing.expect_value(t, options.item_set.data[0].key, "a\\\\")
	value := options.item_set.data[0].value
	str, is_string := value.(string)
	testing.expect(t, is_string, "a `=` item's value is a string")
	testing.expect_value(t, str, "b=c")
	cli.options_destroy(&options)

	// And the unescape's half, where it is visible on its own: the message a
	// missing file raises quotes the path the *unescape* produced, and it is a
	// `repr()`, so each of the two backslashes is spelled twice.
	argv := []string{"oj", "--offline", "--ignore-stdin", "-p", "H", "POST", "example.com",
	                 "x=@a\\\\:b.txt"}
	_, err = parse_cli(argv, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
	testing.expect_value(
		t,
		err.message,
		"'x=@a\\\\\\\\:b.txt': [Errno 2] No such file or directory: 'a\\\\\\\\:b.txt'",
	)
	cli.parse_error_destroy(&err)

	expect_no_leaks(t, &track)
}

@(test)
test_parse_args_embed_refuses_a_file_that_is_not_utf8 :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// A file whose bytes are not UTF-8 is refused by the text reader *while the
	// command line is read* — the reference's `load_text_file`
	// (requestitems.py:212-223) decodes strictly — so the item never becomes a
	// request. This is the `=@` road; the other three (`:@`, `==@`, `:=@`) share
	// read_text_file, and the parity scenarios pin all four.
	directory, path := embed_sandbox_file(t, "bad", []u8{0x61, 0xff, 0x62, 0x0a}, allocator)
	item := strings.concatenate({"note=@", path}, allocator)
	argv := []string{"oj", "--offline", "--ignore-stdin", "-p", "H", "POST", "example.com", item}
	_, err := parse_cli(argv, allocator)

	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
	want := strings.concatenate(
		{"'", item, "': cannot embed the content of '", path,
		 "', not a UTF-8 or ASCII-encoded text file"},
		allocator,
	)
	testing.expectf(t, err.message == want, "unexpected message: %s", err.message)

	cli.parse_error_destroy(&err)
	os.remove_all(directory)
	delete(want, allocator)
	delete(item, allocator)
	delete(path, allocator)
	delete(directory, allocator)
	expect_no_leaks(t, &track)
}

// The `--form`/`--multipart` wrapper around the two raw-JSON processors
// (requestitems.py:169-190) catches *every* ParseError its processor raises, so
// on the `:=@` road the reader's own refusals are swallowed with the decoder's:
// a missing file, a file that is not UTF-8 and a JSON error all report the
// complex-value error instead. The `=@` road reads through the same
// load_text_file and is *not* a JSON processor, so its message survives the
// flag. The wrapper's value test is `isinstance(output, (str, int, float))`,
// which is why a parsed `null` is complex and a parsed `true` is not.
// The parity scenarios pin the same rule live and offline
// (`form-raw-json-file-*`, `json-bom-form-file-*`, `form-data-embed-*`).
@(test)
test_parse_args_form_wrapper_swallows_the_raw_json_file_refusals :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	bad_directory, bad_path := embed_sandbox_file(t, "form-bad", []u8{0x61, 0xff, 0x62, 0x0a}, allocator)
	bom_directory, bom_path := embed_sandbox_file(
		t,
		"form-bom",
		[]u8{0xef, 0xbb, 0xbf, '{', '}', 0x0a},
		allocator,
	)
	missing_path := strings.concatenate({bad_directory, "/nope.json"}, allocator)

	// The three file shapes: the reader's `[Errno 2]`, the reader's non-UTF-8
	// refusal, and the decoder's own BOM error. The *inline* road is the fourth
	// shape of the same wrapper, so it is asserted beside them.
	paths := []string{missing_path, bad_path, bom_path}
	for path, index in paths {
		item := strings.concatenate({"x:=@", path}, allocator)
		_, err := parse_cli(
			[]string{"oj", "--offline", "--ignore-stdin", "-f", "-p", "H", "POST", "example.com", item},
			allocator,
		)
		testing.expectf(
			t,
			err.kind == cli.Parse_Error_Kind.Usage && err.message == cli.COMPLEX_JSON_IN_FORM_MESSAGE,
			"file case %d: got %v / %s",
			index,
			err.kind,
			err.message,
		)
		cli.parse_error_destroy(&err)
		delete(item, allocator)
	}
	_, inline_err := parse_cli(
		[]string{"oj", "--offline", "--ignore-stdin", "-f", "-p", "H", "POST", "example.com", "x:=not-json"},
		allocator,
	)
	testing.expectf(
		t,
		inline_err.kind == cli.Parse_Error_Kind.Usage && inline_err.message == cli.COMPLEX_JSON_IN_FORM_MESSAGE,
		"inline case: got %v / %s",
		inline_err.kind,
		inline_err.message,
	)
	cli.parse_error_destroy(&inline_err)

	// The `null` half of the value rule — and its `true` control, which is a
	// primitive to the wrapper (`True` on the wire, Python's `str(int)`).
	_, null_err := parse_cli(
		[]string{"oj", "--offline", "--ignore-stdin", "-f", "-p", "H", "POST", "example.com", "x:=null"},
		allocator,
	)
	testing.expectf(
		t,
		null_err.kind == cli.Parse_Error_Kind.Usage && null_err.message == cli.COMPLEX_JSON_IN_FORM_MESSAGE,
		"null case: got %v / %s",
		null_err.kind,
		null_err.message,
	)
	cli.parse_error_destroy(&null_err)

	options, bool_err := parse_cli(
		[]string{"oj", "--offline", "--ignore-stdin", "-f", "-p", "H", "POST", "example.com", "x:=true"},
		allocator,
	)
	testing.expect_value(t, bool_err.kind, cli.Parse_Error_Kind.None)
	testing.expect_value(t, len(options.item_set.data), 1)
	if len(options.item_set.data) == 1 {
		form_value, is_string := options.item_set.data[0].value.(string)
		testing.expectf(t, is_string && form_value == "True", "the bool form value: %v", options.item_set.data[0].value)
	}
	cli.options_destroy(&options)

	// The control: the `=@` road is not a JSON processor, with and without the
	// flag, so the embed refusal is what both command lines report.
	control_item := strings.concatenate({"note=@", bad_path}, allocator)
	control_want := strings.concatenate(
		{"'", control_item, "': cannot embed the content of '", bad_path,
		 "', not a UTF-8 or ASCII-encoded text file"},
		allocator,
	)
	for with_form in ([]bool{true, false}) {
		argv := []string{
			"oj", "--offline", "--ignore-stdin", "-p", "H", "POST", "example.com", control_item,
		}
		if with_form {
			argv = []string{
				"oj", "--offline", "--ignore-stdin", "-f", "-p", "H", "POST", "example.com", control_item,
			}
		}
		_, err := parse_cli(argv, allocator)
		testing.expectf(
			t,
			err.kind == cli.Parse_Error_Kind.Usage && err.message == control_want,
			"embed control (form=%v): got %v / %s",
			with_form,
			err.kind,
			err.message,
		)
		cli.parse_error_destroy(&err)
	}
	delete(control_item, allocator)
	delete(control_want, allocator)

	os.remove_all(bad_directory)
	os.remove_all(bom_directory)
	delete(missing_path, allocator)
	delete(bad_path, allocator)
	delete(bom_path, allocator)
	delete(bad_directory, allocator)
	delete(bom_directory, allocator)
	expect_no_leaks(t, &track)
}

// The bare `@file` road is not a text reader: the body is the file's bytes,
// bad ones included (requestitems.py:147-161 opens it 'rb', and
// argparser.py:382-389 *always* reads bytes). The two roads differ by the
// reader they take — read_binary_file vs read_text_file — so this asserts the
// refusal above is the decode, not the read.
@(test)
test_parse_args_bare_atfile_keeps_non_utf8_bytes :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	directory, path := embed_sandbox_file(t, "bare", []u8{0x61, 0xff, 0x62, 0x0a}, allocator)
	item := strings.concatenate({"@", path}, allocator)
	argv := []string{"oj", "--offline", "--ignore-stdin", "-p", "H", "POST", "example.com", item}
	options, err := parse_cli(argv, allocator)

	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	cli.options_destroy(&options)
	os.remove_all(directory)
	delete(item, allocator)
	delete(path, allocator)
	delete(directory, allocator)
	expect_no_leaks(t, &track)
}

// embed_sandbox_file writes `data` to a fresh file under $TMPDIR and returns
// its directory and path, both owned by `allocator` (the caller deletes the
// directory, which takes the file with it). Everything it allocates with
// `allocator` is returned or freed here — `expect_no_leaks` runs before the
// caller's `defer`s, so scratch strings come from the temp allocator.
@(private)
embed_sandbox_file :: proc(
	t: ^testing.T,
	name: string,
	data: []u8,
	allocator: mem.Allocator,
) -> (
	directory: string,
	path: string,
) {
	base := "tmp"
	if tmp := os.get_env("TMPDIR", context.temp_allocator); tmp != "" {
		base = tmp
	}
	unique := fmt.aprintf(
		"%d",
		time.time_to_unix(time.now()),
		allocator = context.temp_allocator,
	)
	directory = strings.concatenate(
		{base, "/oj-embed-selftest-", name, "-", unique},
		allocator,
	)
	if err := os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist {
		testing.expectf(t, false, "cannot create the sandbox %s: %v", directory, err)
	}
	path = strings.concatenate({directory, "/item-file"}, allocator)
	if err := os.write_entire_file_from_bytes(path, data); err != nil {
		testing.expectf(t, false, "cannot write %s: %v", path, err)
	}
	return directory, path
}

// The `--raw` body is encoded while the reference *parses the arguments*:
// `_body_from_input`'s `data.encode()` (argparser.py:397) is reached from
// `if self.args.raw is not None` (:183), and that call sits outside httpie's own
// error handling.  The `--raw` value is a `str` by then, so the argv byte 0xff
// is the lone surrogate '\udcff' and the strict utf-8 codec refuses it: rc 1,
// nothing on stdout, nothing sent, and no `usage:` block — the run ends with an
// unhandled traceback whose last line is the exception itself (docs/PARITY.md
// §3.6; §8.20 records the traceback's frames as not reproduced, which is why the
// parity scenarios compare rc and stdout and this test pins the wording).
//
// The two roads that are *not* a `--raw` value are bytes on both sides
// (`_body_from_file`, argparser.py:381-389) and stay bytes here:
// `test_parse_args_bare_atfile_keeps_non_utf8_bytes` above is the `@file` one,
// and the `raw-body-stdin-bytes-*` parity scenarios are the stdin one.
@(test)
test_parse_args_refuses_a_raw_body_the_utf8_codec_cannot_encode :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// One argv byte that is not valid UTF-8 — `0xff` — which CPython's argv
	// decode (PEP 383, surrogateescape) hands the reference as '\udcff'.
	BAD :: "\xff"

	// (the `--raw` body, the exception's own line)
	refusals := []struct {
		body: string,
		want: string,
	}{
		{
			"{\"a\": \"" + BAD + "\"}",
			"UnicodeEncodeError: 'utf-8' codec can't encode character '\\udcff' in position 7: surrogates not allowed",
		},
		{
			// In front of the body: the position is 0.
			BAD + "{\"a\": 1}",
			"UnicodeEncodeError: 'utf-8' codec can't encode character '\\udcff' in position 0: surrogates not allowed",
		},
		{
			// Two in a row: CPython reports the *run* of positions.
			"{\"a\": \"" + BAD + BAD + "\"}",
			"UnicodeEncodeError: 'utf-8' codec can't encode characters in position 7-8: surrogates not allowed",
		},
		{
			// The position counts *characters*: `é` is one of them (and two
			// bytes), so the byte is 8 while its byte offset is 9.
			"{\"a\": \"é" + BAD + "\"}",
			"UnicodeEncodeError: 'utf-8' codec can't encode character '\\udcff' in position 8: surrogates not allowed",
		},
		{
			// A continuation byte on its own is a lone surrogate like any
			// other — 0x80 is U+DC80.
			"{\"a\": \"\x80\"}",
			"UnicodeEncodeError: 'utf-8' codec can't encode character '\\udc80' in position 7: surrogates not allowed",
		},
	}
	for entry in refusals {
		raw := strings.concatenate({"--raw=", entry.body}, context.temp_allocator)
		argv := []string{"oj", "--offline", "-p", "b", "POST", "example.com", raw}
		options, err := parse_cli(argv, allocator)
		testing.expectf(
			t,
			err.kind == cli.Parse_Error_Kind.Exception,
			"%s: kind %v, want the exception (not a usage error)",
			entry.body,
			err.kind,
		)
		testing.expectf(
			t,
			err.message == entry.want,
			"%s: unexpected message: %s",
			entry.body,
			err.message,
		)
		cli.parse_error_destroy(&err)
		// A successful shape (what a mutant of the check makes of one) owns its
		// options here; on the error path the parse already destroyed them, so
		// this is the zero value and the leak check still sees the real one.
		cli.options_destroy(&options)
	}

	// The controls: a body the same codec *can* encode is not refused — ASCII,
	// a valid multi-byte character, an astral one (four bytes), and the empty
	// body (`--raw=`, which is a `--raw` with an empty value).
	controls := []string{"{\"a\": 1}", "{\"a\": \"é\"}", "{\"a\": \"😀\"}", ""}
	for body in controls {
		raw := strings.concatenate({"--raw=", body}, context.temp_allocator)
		argv := []string{"oj", "--offline", "-p", "b", "POST", "example.com", raw}
		options, err := parse_cli(argv, allocator)
		testing.expectf(t, err.kind == cli.Parse_Error_Kind.None, "%s: refused: %v", body, err.message)
		cli.options_destroy(&options)
	}

	// Where in the sequence the refusal sits.  `_body_from_input` runs its
	// one-data-source check *before* it encodes (:396-397), so a data item
	// beside `--raw` is the mixing usage error and never this exception — the
	// item has to stand *before* the option for argparse to accept it at all
	// (`--raw=<body> a=1` leaves the item as argparse's own leftover, below).
	{
		raw := strings.concatenate({"--raw=", "{\"a\": \"", BAD, "\"}"}, context.temp_allocator)
		argv := []string{"oj", "--offline", "-p", "b", "POST", "example.com", "a=1", raw}
		options, err := parse_cli(argv, allocator)
		testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
		testing.expectf(
			t,
			strings.contains(err.message, "cannot be mixed"),
			"unexpected message: %s",
			err.message,
		)
		cli.parse_error_destroy(&err)
		// A successful shape (what a mutant of the check makes of one) owns its
		// options here; on the error path the parse already destroyed them, so
		// this is the zero value and the leak check still sees the real one.
		cli.options_destroy(&options)
	}
	// The same option with the item *after* it is argparse's own leftover, and
	// that error is raised while the command line is scanned — before `process`
	// is reached at all, so the encode is never asked about it.
	{
		raw := strings.concatenate({"--raw=", "{\"a\": \"", BAD, "\"}"}, context.temp_allocator)
		argv := []string{"oj", "--offline", "-p", "b", "POST", "example.com", raw, "a=1"}
		options, err := parse_cli(argv, allocator)
		testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
		testing.expectf(
			t,
			strings.contains(err.message, "unrecognized arguments: a=1"),
			"unexpected message: %s",
			err.message,
		)
		cli.parse_error_destroy(&err)
		// A successful shape (what a mutant of the check makes of one) owns its
		// options here; on the error path the parse already destroyed them, so
		// this is the zero value and the leak check still sees the real one.
		cli.options_destroy(&options)
	}
	// …while the --compress checks come *after* it (:187-192): the exception
	// ends the parse first, so a combination that is a usage error on its own
	// (`cannot combine --compress and --chunked`) is never reported.
	{
		raw := strings.concatenate({"--raw=", "{\"a\": \"", BAD, "\"}"}, context.temp_allocator)
		argv := []string{"oj", "--offline", "--compress", "--chunked", "-p", "b", "POST", "example.com", raw}
		options, err := parse_cli(argv, allocator)
		testing.expectf(
			t,
			err.kind == cli.Parse_Error_Kind.Exception,
			"the exception ends the parse before the --compress checks: %v (%s)",
			err.kind,
			err.message,
		)
		cli.parse_error_destroy(&err)
		// A successful shape (what a mutant of the check makes of one) owns its
		// options here; on the error path the parse already destroyed them, so
		// this is the zero value and the leak check still sees the real one.
		cli.options_destroy(&options)
	}

	expect_no_leaks(t, &track)
}

@(test)
test_options_zero_value_is_destroyable :: proc(t: ^testing.T) {
	options: cli.Options
	cli.options_destroy(&options)
	testing.expect_value(t, options.program_name, "")
}

// `-vv` / `-xx` / `-vvv` go through consume_optional's short-option clustering
// loop, which rewrites the option name to a glued clone (the name `-v` plus the
// tail of `-vv`). The rewritten name is only borrowed from there on, so the
// clone used to be leaked: one block per cluster step, invisible to every
// behavioural assertion (t_bf380400). The tracking allocator is the assertion.
@(test)
test_parse_args_short_option_clusters_do_not_leak :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// `-vv` and `-xx` are two Count actions each; `-vvv` clusters twice, so the
	// first clone is still live when the second one is made.
	argv := []string{
		"oj",
		"--offline",
		"-vv",
		"-xx",
		"-vvv",
		"-p", "H",
		"http://127.0.0.1:8000/echo",
	}
	options, err := parse_cli(argv, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)
	testing.expect_value(t, options.verbose, 5) // 2 from -vv, 3 from -vvv
	testing.expect_value(t, options.compress, 2) // 2 from -xx

	cli.options_destroy(&options)
	expect_no_leaks(t, &track)
}

// A malformed `config.json` is a *warning* in the reference, not a failure:
// `Environment.config` catches `ConfigFileError` and logs it, and the run
// carries on with `Config.DEFAULTS`' empty `default_options`
// (httpie/context.py:143-149). The reader is `read_raw_config`
// (httpie/config.py:60-78), whose two wordings are `invalid config file: {e}
// [{path}]` for the ValueError `json.load` (or the utf-8 decode of `open`)
// raised and `cannot read config file: {e}` for an OSError. A file that is not
// there is never read at all (`is_new` is `not path.exists()`) and stays silent.
//
// The warning is parse_args_with's third result — main.odin prints it before
// anything else the run writes — so this pins the wording and the shapes; the
// parity scenarios pin the printed block, in that position.
@(test)
test_parse_args_reports_a_malformed_config_file :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// `want` is the message with `%s` where the config file's path goes ("" is
	// the silent shape); the BOM and the bad byte are the two halves of the
	// decoder's own refusal.
	checks := []struct {
		name:   string,
		data:   []u8,
		write:  bool, // false: leave the path empty (the missing-file shape)
		as_dir: bool,
		want:   string,
	}{
		{
			"bom",
			{0xef, 0xbb, 0xbf, '{', '}', '\n'},
			true,
			false,
			"invalid config file: Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0) [%s]",
		},
		{"garbage", {'n', 'o', 't', ' ', 'j', 's', 'o', 'n', '\n'}, true, false,
		 "invalid config file: Expecting value: line 1 column 1 (char 0) [%s]"},
		// An empty file is a JSON error like any other: `json.load` has nothing
		// to read.
		{"empty", {}, true, false,
		 "invalid config file: Expecting value: line 1 column 1 (char 0) [%s]"},
		// The file's *bytes* are decoded before json.load sees them: the codec's
		// own message, and no `UnicodeDecodeError: ` prefix (read_raw_config
		// interpolates the value, not the exception's repr).
		{"not-utf8", {'a', 0xff, 'b', '\n'}, true, false,
		 "invalid config file: 'utf-8' codec can't decode byte 0xff in position 1: invalid start byte [%s]"},
		// The `cannot read` branch: Python's OSError str, path repr'd.
		{"directory", {}, false, true,
		 "cannot read config file: [Errno 21] Is a directory: '%s'"},
		// ...and the control: no file, no warning.
		{"missing", {}, false, false, ""},
	}

	argv := []string{"oj", "--offline", "-p", "H", "POST", "example.org/x"}
	for check in checks {
		directory, path := config_sandbox(t, check.name, allocator)
		if check.as_dir {
			if err := os.make_directory(path); err != nil {
				testing.expectf(t, false, "cannot create %s: %v", path, err)
			}
		} else if check.write {
			if err := os.write_entire_file_from_bytes(path, check.data); err != nil {
				testing.expectf(t, false, "cannot write %s: %v", path, err)
			}
		}

		config_var := fmt.aprintf("HTTPIE_CONFIG_DIR=%s", directory, allocator = allocator)
		env := cli.env_info_from_strings(
			[]string{
				"TERM=xterm-256color",
				"COLUMNS=80",
				config_var,
			},
			true,
			false,
			false,
			allocator,
		)
		options, err, warning := cli.parse_args_with(env, argv, allocator)

		testing.expectf(t, err.kind == .None, "%s: parse error: %s", check.name, err.message)
		want := ""
		if check.want != "" {
			want = fmt.aprintf(check.want, path, allocator = allocator)
		}
		testing.expectf(
			t,
			warning == want,
			"%s: warning %q, want %q",
			check.name,
			warning,
			want,
		)
		testing.expectf(t, options.url == "example.org/x", "%s: the run carries on", check.name)

		cli.options_destroy(&options)
		cli.env_info_destroy(&env, allocator)
		delete(config_var, allocator)
		delete(warning, allocator)
		delete(want, allocator)
		os.remove_all(directory)
		delete(directory, allocator)
		delete(path, allocator)
	}
	expect_no_leaks(t, &track)
}

// The warning is emitted *before* argparse runs in the reference
// (`env.config` is touched at the top of `raw_main`, core.py:46), so it precedes
// a usage block as well — the parse's error paths carry it out alongside the
// message main.odin prints.
@(test)
test_parse_args_config_warning_precedes_a_usage_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	directory, path := config_sandbox(t, "usage", allocator)
	if err := os.write_entire_file_from_bytes(path, []u8{0xef, 0xbb, 0xbf, '{', '}'}); err != nil {
		testing.expectf(t, false, "cannot write %s: %v", path, err)
	}
	config_var := fmt.aprintf("HTTPIE_CONFIG_DIR=%s", directory, allocator = allocator)
	env := cli.env_info_from_strings(
		[]string{
			"COLUMNS=80",
			config_var,
		},
		true,
		false,
		false,
		allocator,
	)

	// No URL at all: the run ends as a usage error, and the warning still comes
	// out first.
	_, err, warning := cli.parse_args_with(env, []string{"oj"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
	want := fmt.aprintf(
		"invalid config file: Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0) [%s]",
		path,
		allocator = allocator,
	)
	testing.expectf(t, warning == want, "warning %q, want %q", warning, want)

	cli.parse_error_destroy(&err)
	cli.env_info_destroy(&env, allocator)
	delete(config_var, allocator)
	delete(warning, allocator)
	delete(want, allocator)
	os.remove_all(directory)
	delete(directory, allocator)
	delete(path, allocator)
	expect_no_leaks(t, &track)
}

// A `config.json` *value* the code cannot use ends the run with an exception the
// reference never catches: `BaseConfigDict.load`'s `self.update(data)` — i.e.
// `dict.update` (config.py:103-108) — and `raw_main`'s
// `env.config.default_options + args` (core.py:48-49) both sit outside
// `read_raw_config`'s `except ConfigFileError`, so there is no warning, nothing
// on stdout, nothing sent and rc 1: the run dies inside `env.config`, before
// argparse and so before `--help`/`--version` too. The port answers with the
// exception's own line, which is what Parse_Error_Kind.Exception is for —
// §8.20's decision, because the reference's stderr here is a traceback whose
// frames name the interpreter it happens to run in
// (`build/probe_config_value_shapes.py` measures the half that *can* be compared:
// rc, empty stdout, that last line).
//
// The three moments are separate and all three are pinned here: a root value
// `update` refuses, a `default_options` that is not a list against `+ args`, an
// element argparse's `_parse_optional` refuses *by type*, and the element it uses
// as an argument string — the `unrecognized arguments` block a null leaves the
// URL in, and `_process_url`'s `AttributeError` when the element reached the URL
// slot. The controls are the well-formed list and the root *array* pair that
// really does deliver options.
@(test)
test_parse_args_config_value_shapes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// `timeout` is the option a delivered `default_options` sets, so the shapes
	// that carry on prove the list reached the command line.
	checks := []struct {
		name:    string,
		data:    string,
		argv:    []string,
		kind:    cli.Parse_Error_Kind,
		message: string,
		timeout: f64,
	}{
		// The root value `dict.update` refuses.
		{"root-int", `5`, {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: 'int' object is not iterable", 0},
		{"root-string", `"x"`, {"oj", "--offline", "example.org/x"},
		 .Exception, "ValueError: dictionary update sequence element #0 has length 1; 2 is required", 0},
		{"root-bool", `true`, {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: 'bool' object is not iterable", 0},
		// A string counts *characters*, and an array its elements.
		{"root-list-short", `[[1]]`, {"oj", "--offline", "example.org/x"},
		 .Exception, "ValueError: dictionary update sequence element #0 has length 1; 2 is required", 0},
		{"root-list-scalar", `[5]`, {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: cannot convert dictionary update sequence element #0 to a sequence", 0},
		{"root-list-later", `[["a", "b"], 5]`, {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: cannot convert dictionary update sequence element #1 to a sequence", 0},
		// ...and a pair whose key could not be a dict key.
		{"root-unhashable-key", `[[["a"], "b"]]`, {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: unhashable type: 'list'", 0},
		// A `default_options` that is not a list: the `+ args` of raw_main.
		{"defaults-string", `{"default_options": "--style=pie"}`,
		 {"oj", "--offline", "example.org/x"},
		 .Exception, `TypeError: can only concatenate str (not "list") to str`, 0},
		{"defaults-float", `{"default_options": 1.5}`, {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: unsupported operand type(s) for +: 'float' and 'list'", 0},
		{"defaults-object", `{"default_options": {"a": 1}}`,
		 {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: unsupported operand type(s) for +: 'dict' and 'list'", 0},
		// An element `_parse_optional` refuses by type: a scalar has no `[0]`, a
		// mapping has no key `0`, and an array's first element is fed to
		// `in self.prefix_chars`.
		{"item-int", `{"default_options": [5]}`, {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: 'int' object is not subscriptable", 0},
		{"item-nested-int", `{"default_options": [[1]]}`, {"oj", "--offline", "example.org/x"},
		 .Exception, "TypeError: 'in <string>' requires string as left operand, not int", 0},
		{"item-mapping", `{"default_options": [{"a": 1}]}`,
		 {"oj", "--offline", "example.org/x"}, .Exception, "KeyError: 0", 0},
		{"item-empty-first-string", `{"default_options": [[""]]}`,
		 {"oj", "--offline", "example.org/x"}, .Exception,
		 "TypeError: unhashable type: 'list'", 0},
		// An element argparse uses as an argument string: the URL is left in
		// `extras` (the block), or the element itself reaches the URL slot.
		{"item-null-unrecognized", `{"default_options": [null]}`,
		 {"oj", "--offline", "example.org/x"}, .Usage,
		 "unrecognized arguments: example.org/x", 0},
		{"item-null-url-slot", `{"default_options": [null]}`, {"oj", "--offline"},
		 .Exception, "AttributeError: 'NoneType' object has no attribute 'startswith'", 0},
		{"item-object-url-slot", `{"default_options": [{}]}`, {"oj", "--offline"},
		 .Exception, "AttributeError: 'dict' object has no attribute 'startswith'", 0},
		// The controls: the options a well-formed list carries really are used,
		// and a root array's pair is one of the shapes that delivers them.
		{"defaults-delivered", `{"default_options": ["--timeout=5"]}`,
		 {"oj", "--offline", "example.org/x"}, .None, "", 5},
		{"root-pair-delivered", `[["default_options", ["--timeout=5"]]]`,
		 {"oj", "--offline", "example.org/x"}, .None, "", 5},
		{"root-falsy", `[]`, {"oj", "--offline", "example.org/x"}, .None, "", 0},
		{"defaults-empty-object", `{"default_options": {}}`,
		 {"oj", "--offline", "example.org/x"}, .None, "", 0},
	}

	for check in checks {
		directory, path := config_sandbox(t, check.name, allocator)
		if err := os.write_entire_file_from_bytes(path, transmute([]u8)check.data); err != nil {
			testing.expectf(t, false, "%s: cannot write %s: %v", check.name, path, err)
		}
		config_var := fmt.aprintf("HTTPIE_CONFIG_DIR=%s", directory, allocator = allocator)
		env := cli.env_info_from_strings(
			[]string{"COLUMNS=80", config_var},
			true,
			false,
			false,
			allocator,
		)
		options, err, warning := cli.parse_args_with(env, check.argv, allocator)

		testing.expectf(t, warning == "", "%s: warning %q, want none", check.name, warning)
		testing.expectf(
			t,
			err.kind == check.kind,
			"%s: kind %v, want %v (message %q)",
			check.name,
			err.kind,
			check.kind,
			err.message,
		)
		testing.expectf(
			t,
			err.message == check.message,
			"%s: message %q, want %q",
			check.name,
			err.message,
			check.message,
		)
		if check.kind == .None {
			testing.expectf(
				t,
				options.timeout_s == check.timeout,
				"%s: timeout %v, want %v",
				check.name,
				options.timeout_s,
				check.timeout,
			)
			testing.expectf(t, options.url == "example.org/x", "%s: the run carries on", check.name)
		}

		cli.parse_error_destroy(&err)
		cli.options_destroy(&options)
		cli.env_info_destroy(&env, allocator)
		delete(config_var, allocator)
		delete(warning, allocator)
		os.remove_all(directory)
		delete(directory, allocator)
		delete(path, allocator)
	}
	expect_no_leaks(t, &track)
}

// `CONFIG_FILE = Path(directory) / 'config.json'` (config.py:56) is a PurePath
// join, so the path the warning prints is the normalised one: a trailing
// separator, a doubled one and a `.` component are not in it, while a `..`
// component is kept as it stands (pathlib does not resolve it — the OS does that
// when the file is opened, which is why the path may be unnormalised and the
// `config.json` still be read). The port concatenated the directory's bytes as
// given, so a `$HTTPIE_CONFIG_DIR` ending in `/` printed `…//config.json`.
@(test)
test_parse_args_config_path_is_a_pure_join :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	directory, path := config_sandbox(t, "pure-join", allocator)
	if err := os.write_entire_file_from_bytes(path, []u8{'n', 'o', 't', ' ', 'j', 's', 'o', 'n'}); err != nil {
		testing.expectf(t, false, "cannot write %s: %v", path, err)
	}
	// The `..` spelling walks through a real directory, as the OS will.
	sub := strings.concatenate({directory, "/sub"}, allocator)
	if err := os.make_directory(sub); err != nil {
		testing.expectf(t, false, "cannot create %s: %v", sub, err)
	}

	checks := []struct {
		suffix: string,
		path:   string, // the `[path]` the warning prints
	}{
		{"", path},
		{"/", path},
		{"//", path},
		{"/./", path},
		{"/sub/..", strings.concatenate({directory, "/sub/../config.json"}, context.temp_allocator)},
	}

	for check in checks {
		config_dir := strings.concatenate({directory, check.suffix}, allocator)
		config_var := fmt.aprintf("HTTPIE_CONFIG_DIR=%s", config_dir, allocator = allocator)
		env := cli.env_info_from_strings(
			[]string{"COLUMNS=80", config_var},
			true,
			false,
			false,
			allocator,
		)
		options, err, warning := cli.parse_args_with(
			env,
			[]string{"oj", "--offline", "example.org/x"},
			allocator,
		)
		want := fmt.aprintf(
			"invalid config file: Expecting value: line 1 column 1 (char 0) [%s]",
			check.path,
			allocator = allocator,
		)
		testing.expectf(
			t,
			err.kind == .None,
			"suffix %q: parse error %s %q",
			check.suffix,
			err.kind,
			err.message,
		)
		testing.expectf(
			t,
			warning == want,
			"suffix %q: warning %q, want %q",
			check.suffix,
			warning,
			want,
		)

		cli.parse_error_destroy(&err)
		cli.options_destroy(&options)
		cli.env_info_destroy(&env, allocator)
		delete(config_dir, allocator)
		delete(config_var, allocator)
		delete(warning, allocator)
		delete(want, allocator)
	}

	os.remove_all(directory)
	delete(sub, allocator)
	delete(directory, allocator)
	delete(path, allocator)
	expect_no_leaks(t, &track)
}

// config_sandbox makes a fresh directory under $TMPDIR for one config-file
// shape and returns it with the `config.json` path inside it; the caller writes
// the file (or a directory at that path) and removes the directory when done.
// Both returned strings are owned by `allocator`.
@(private)
config_sandbox :: proc(t: ^testing.T, name: string, allocator: mem.Allocator) -> (directory, path: string) {
	base := "tmp"
	if tmp := os.get_env("TMPDIR", context.temp_allocator); tmp != "" {
		base = tmp
	}
	unique := fmt.aprintf(
		"%d",
		time.time_to_unix(time.now()),
		allocator = context.temp_allocator,
	)
	directory = strings.concatenate(
		{base, "/oj-config-selftest-", name, "-", unique},
		allocator,
	)
	if err := os.make_directory_all(
		directory,
		os.Permissions{.Read_User, .Write_User, .Execute_User},
	); err != nil && err != .Exist {
		testing.expectf(t, false, "cannot create the sandbox %s: %v", directory, err)
	}
	path = strings.concatenate({directory, "/config.json"}, allocator)
	return directory, path
}

// The usage-error message is fed to rich's markup parser before it is printed
// (httpie splices it into a markup template and prints that through its rich
// console, cli/argparser.py:598-612), so a `[…]` an item carries is a tag and
// not text. The table is rich 15.0.0's tag grammar, one row per rule
// (docs/PARITY.md §3.1; the scenarios in tests/parity/scenarios.py pin the same
// rules end to end).
@(test)
test_usage_error_markup_follows_richs_tag_rules :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cases := []struct {
		markup: string,
		want:   string,
	}{
		// A tag is `[`, one of `[a-z#/@]`, then the first `]` before any other
		// `[`. Its text is dropped whatever the name means — a known style, an
		// unknown one (the style is only looked up later and an unknown name
		// resolves to "none"), a colour, a link, a close.
		{"note=@[b]nope.txt", "note=@nope.txt"},
		{"[bold]red[/bold]", "red"},
		{"[nope]", ""},
		{"[#ff0000]", ""},
		{"[link=http://x]here[/link]", "here"},
		{"[@click=x]here[/@click]", "here"},
		{"[red][green]x", "x"},
		{"[bold]x", "x"}, // unclosed: still a tag, still dropped
		// What is *not* a tag stays: the character after the `[` must be lower
		// case and the bracket group must meet its `]` before the next `[`.
		{"[BOLD]x", "[BOLD]x"},
		{"[]x", "[]x"},
		{"[ax", "[ax"},
		{"x[y", "x[y"},
		{"nope[.txt", "nope[.txt"},
		{"x[ ", "x[ "},
		{"[a[b]", "[a"},
		// Backslashes escape a tag: each pair prints as itself, an odd
		// remainder leaves the tag as its own text.
		{"\\[b]", "[b]"},
		{"\\\\[b]", "\\"},
		{"\\\\\\[b]", "\\[b]"},
		// A backslash in front of a bracket that opens no tag is that bracket's
		// escape and goes away with it.
		{"x\\[y", "x[y"},
		{"x\\\\[y", "x\\[y"},
	}
	for c in cases {
		got := cli.rich_markup_text(c.markup, context.temp_allocator)
		testing.expectf(
			t,
			got == c.want,
			"rich_markup_text(%q) = %q, want %q",
			c.markup,
			got,
			c.want,
		)
	}
}

// The pass runs before rich wraps the block, not after: the tag is gone from
// the cell count the 80-cell break is measured on, so a message with a tag in
// it renders — breaks included — as the same message without one.
@(test)
test_usage_error_block_renders_markup_before_it_wraps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	filler := strings.repeat("x", 70, context.temp_allocator)
	tagged := strings.concatenate(
		{
			"'note=@[bold]",
			filler,
			"nope.txt': [Errno 2] No such file or directory: '[bold]",
			filler,
			"nope.txt'",
		},
		context.temp_allocator,
	)
	plain := strings.concatenate(
		{
			"'note=@",
			filler,
			"nope.txt': [Errno 2] No such file or directory: '",
			filler,
			"nope.txt'",
		},
		context.temp_allocator,
	)

	got := cli.usage_error_text("http", tagged, cli.RICH_WIDTH, context.temp_allocator)
	want := cli.usage_error_text("http", plain, cli.RICH_WIDTH, context.temp_allocator)
	testing.expectf(
		t,
		got == want,
		"the tag changed the block (a pass applied after the wrap would do this):\n  got  %q\n  want %q",
		got,
		want,
	)

	// The measured bytes of the missing-file road, which is the case the card
	// was filed from (build/probe_usage_markup.py, `bold-tag`): both halves of
	// the message lose the `[b]` and the block is the reference's.
	message := "'note=@[b]nope.txt': [Errno 2] No such file or directory: '[b]nope.txt'"
	block := cli.usage_error_text("http", message, cli.RICH_WIDTH, context.temp_allocator)
	reference_block := "usage:\n" +
		"    http [METHOD] URL [REQUEST_ITEM ...]\n" +
		"\n" +
		"error:\n" +
		"    'note=@nope.txt': [Errno 2] No such file or directory: 'nope.txt'\n" +
		"\n" +
		"for more information:\n" +
		"    run 'http --help' or visit https://httpie.io/docs/cli\n" +
		"\n"
	testing.expectf(
		t,
		block == reference_block,
		"the block is not the reference's:\n  got  %q\n  want %q",
		block,
		reference_block,
	)
}

// The *second* transform of the same pass: after the tags are parsed, rich runs
// `_emoji_replace` over every plain piece (rich/markup.py:130, :157), so a
// `:code:` that names an entry of rich 15.0.0's `EMOJI` table is substituted on
// the way to stderr. One row per rule of rich/_emoji_replace.py and of the table
// lookup (docs/PARITY.md §3.1; the scenarios in tests/parity/scenarios.py pin
// the same rules end to end, the non-ASCII `:boo\u212a:` row included — it is
// the `item-repr-emoji-nonascii-markup-offline` scenario, which was unreachable
// until the item-message repr copied a valid multi-byte character whole, §3.6 /
// t_adbd35b4).
@(test)
test_usage_error_emoji_follows_richs_table_rules :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cases := []struct {
		markup: string,
		want:   string,
	}{
		// A hit is the table's own value — U+1F604 for `smile`, and U+2764 for
		// `heart`, with no U+FE0F after it.
		{":smile:", "\U0001F604"},
		{":heart:", "\u2764"},
		{"note=@:smile:.txt", "note=@\U0001F604.txt"},
		// The name is lower-cased before the lookup, and both suffixes append a
		// variation selector (U+FE0F for `-emoji`, U+FE0E for `-text`).
		{":SMILE:", "\U0001F604"},
		{":Smile:", "\U0001F604"},
		{":smile-emoji:", "\U0001F604\ufe0f"},
		{":smile-text:", "\U0001F604\ufe0e"},
		// The two code points whose `str.lower()` lands on an ASCII letter, and
		// one whose upper case is a non-ASCII letter the keys carry (`curaçao`):
		// `str.lower()` is Unicode's, not ASCII's.
		{":boo\u212a:", "\U0001F4D6"},
		{":cura\u00c7ao:", "\U0001F1E8\U0001F1FC"},
		// A miss keeps the code as it stands — and the scan resumes *after* the
		// match, so `:12:` is one failed code and the `smile:` behind it opens
		// nothing new.
		{":nope-emoji:", ":nope-emoji:"},
		{":12:smile:", ":12:smile:"},
		{"http://example.org:8080/x", "http://example.org:8080/x"},
		// A `:` that opens no code is text: an empty name matches the regex and
		// is not a key, and a name stops at the first whitespace.
		{":", ":"},
		{"::", "::"},
		{"a:b", "a:b"},
		{":smile\u00a0:", ":smile\u00a0:"},
		{":smi le:", ":smi le:"},
		// Several codes, and the shortest-name rule: `:a:b:` is the code `a`
		// (U+1F170) followed by text, not the code `a:b`.
		{":smile::heart:", "\U0001F604\u2764"},
		{":a:b:", "\U0001F170b:"},
		{":smile:x:heart:", "\U0001F604x\u2764"},
		// The pass is per *plain piece*, so a tag that splits a code splits the
		// match with it — while a code that survives the tag is expanded.
		{":smi[b]le:", ":smile:"},
		{"[b]:smile:", "\U0001F604"},
		// A name longer than every key cannot hit, and the lookup must not read
		// past its buffer to find that out.
		{":" + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" + ":", ":" + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" + ":"},
	}
	for c in cases {
		got := cli.rich_markup_text(c.markup, context.temp_allocator)
		testing.expectf(
			t,
			got == c.want,
			"rich_markup_text(%q) = %q, want %q",
			c.markup,
			got,
			c.want,
		)
	}
}

// The emoji pass runs *before* rich wraps the block, as the tag pass does, and
// it moves the cell count the wrap measures: an emoji is two cells wide, so the
// block a code renders to is the block the same message with the character
// spelled out renders to — breaks included.
@(test)
test_usage_error_block_renders_emoji_before_it_wraps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	smile := "\U0001F604"
	with_code := "'note=@:smile:.txt': [Errno 2] No such file or directory: ':smile:.txt'"
	spelled_out := strings.concatenate(
		{
			"'note=@",
			smile,
			".txt': [Errno 2] No such file or directory: '",
			smile,
			".txt'",
		},
		context.temp_allocator,
	)
	got := cli.usage_error_text("http", with_code, cli.RICH_WIDTH, context.temp_allocator)
	want := cli.usage_error_text("http", spelled_out, cli.RICH_WIDTH, context.temp_allocator)
	testing.expectf(
		t,
		got == want,
		"the code did not render as the character:\n  got  %q\n  want %q",
		got,
		want,
	)

	// The measured bytes of the card's case (build/probe_usage_markup.py,
	// `emoji`): the reference's stderr for
	// `--offline --ignore-stdin -p H --pretty=none POST http://example.org/x
	// note=@:smile:.txt`.
	reference_block := strings.concatenate(
		{
			"usage:\n",
			"    http [METHOD] URL [REQUEST_ITEM ...]\n",
			"\n",
			"error:\n",
			"    'note=@",
			smile,
			".txt': [Errno 2] No such file or directory: '",
			smile,
			".txt'\n",
			"\n",
			"for more information:\n",
			"    run 'http --help' or visit https://httpie.io/docs/cli\n",
			"\n",
		},
		context.temp_allocator,
	)
	testing.expectf(
		t,
		got == reference_block,
		"the block is not the reference's:\n  got  %q\n  want %q",
		got,
		reference_block,
	)

	// And the wrap itself: eight codes are 64 cells of text and 16 cells of
	// output, so a pass applied after the wrap would break this line elsewhere.
	// The block must equal the one built from the literal characters, which is
	// the same property the tag pair of the test above pins for `[…]`.
	codes := strings.repeat(":smile:", 8, context.temp_allocator)
	characters := strings.repeat(smile, 8, context.temp_allocator)
	long_code := strings.concatenate(
		{
			"'note=@",
			codes,
			".txt': [Errno 2] No such file or directory: '",
			codes,
			".txt'",
		},
		context.temp_allocator,
	)
	long_spelled := strings.concatenate(
		{
			"'note=@",
			characters,
			".txt': [Errno 2] No such file or directory: '",
			characters,
			".txt'",
		},
		context.temp_allocator,
	)
	long_got := cli.usage_error_text("http", long_code, cli.RICH_WIDTH, context.temp_allocator)
	long_want := cli.usage_error_text("http", long_spelled, cli.RICH_WIDTH, context.temp_allocator)
	testing.expectf(
		t,
		long_got == long_want && strings.count(long_got, "\n") > 4,
		"the wrap was measured before the emoji pass:\n  got  %q\n  want %q",
		long_got,
		long_want,
	)
}

// The usage block is wrapped to the width rich's console would size itself to:
// `$COLUMNS` when it holds digits, otherwise rich's 80 (t_0c137e8a;
// src/cli/usage.odin's `console_width`), and a width of zero is no width at all:
// the block is dropped whole (t_e0f7b7b3, `console_silent`). The three expected
// blocks below are the
// reference's own stderr for the same command line at `COLUMNS=200`, `40` and
// `10`, measured whole by build/probe_usage_wrap_width.py — which is where the
// fold, the whitespace a wrapped line keeps at its end and the labels are
// measured over the whole width matrix (1..2000), while
// build/probe_zero_width_console.py measures the zero over every writer.
@(test)
test_usage_error_block_wraps_at_the_console_width :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// `'note=@<path>': [Errno 2] No such file or directory: '<path>'`, the
	// message the missing-file road produces (src/cli/items.odin). It is 158
	// cells, so with the four-space indent the `error:` line is 162: one line at
	// 200, and folded at 40.
	path := "a-very-long-missing-file-name-that-does-not-exist-anywhere.txt"
	message := strings.concatenate(
		{"'note=@", path, "': [Errno 2] No such file or directory: '", path, "'"},
		context.temp_allocator,
	)

	wide_want := strings.concatenate(
		{
			"usage:\n    http [METHOD] URL [REQUEST_ITEM ...]\n\nerror:\n    ",
			message,
			"\n\nfor more information:\n    run 'http --help' or visit https://httpie.io/docs/cli\n\n",
		},
		context.temp_allocator,
	)
	wide_got := cli.usage_error_text("http", message, 200, context.temp_allocator)
	testing.expectf(
		t,
		wide_got == wide_want,
		"the 200-cell block is not the reference's:\n  got  %q\n  want %q",
		wide_got,
		wide_want,
	)

	// At 40 the message folds: the break goes at the whitespace before the word
	// that does not fit, that whitespace stays at the end of the wrapped line,
	// and the two 45-cell words are folded in place. The 65-cell hint line wraps
	// too, and its continuation gets no indent (the indent is part of the text).
	narrow_want := strings.concatenate(
		{
			"usage:\n    http [METHOD] URL [REQUEST_ITEM ...]\n\nerror:\n",
			"    'note=@a-very-long-missing-file-name\n",
			"-that-does-not-exist-anywhere.txt': \n",
			"[Errno 2] No such file or directory: \n",
			"'a-very-long-missing-file-name-that-does\n",
			"-not-exist-anywhere.txt'\n",
			"\nfor more information:\n",
			"    run 'http --help' or visit \n",
			"https://httpie.io/docs/cli\n\n",
		},
		context.temp_allocator,
	)
	narrow_got := cli.usage_error_text("http", message, 40, context.temp_allocator)
	testing.expectf(
		t,
		narrow_got == narrow_want,
		"the 40-cell block is not the reference's:\n  got  %q\n  want %q",
		narrow_got,
		narrow_want,
	)

	// The labels are part of the Text rich wraps, so on a console narrower than
	// one of them that label folds like any other word: `for more information:`
	// is 20 cells and comes apart at 10, while `usage:` (6) and `error:` (6)
	// still fit. `missing-url` is the shortest message there is.
	tiny_want := strings.concatenate(
		{
			"usage:\n    http \n[METHOD] \nURL \n[REQUEST_I\nTEM ...]\n",
			"\nerror:\n    the \nfollowing \narguments \nare \nrequired: \nURL\n",
			"\nfor more \ninformatio\nn:\n    run \n'http \n--help' or\nvisit \n",
			"https://ht\ntpie.io/do\ncs/cli\n\n",
		},
		context.temp_allocator,
	)
	tiny_got := cli.usage_error_text(
		"http",
		"the following arguments are required: URL",
		10,
		context.temp_allocator,
	)
	testing.expectf(
		t,
		tiny_got == tiny_want,
		"the 10-cell block is not the reference's:\n  got  %q\n  want %q",
		tiny_got,
		tiny_want,
	)

	// A zero-width console renders nothing at all: rich's `Console.render`
	// returns an empty segment list below one cell of width, so neither of
	// httpie's two prints reaches stderr and the newline its SystemExit handler
	// writes is the whole of the block (src/cli/usage.odin's `console_silent`;
	// docs/PARITY.md §3.1, t_e0f7b7b3).
	zero_got := cli.usage_error_text("http", message, 0, context.temp_allocator)
	testing.expectf(
		t,
		zero_got == "\n",
		"a zero-width console did not drop the block: got %q, want %q",
		zero_got,
		"\n",
	)
	testing.expectf(
		t,
		cli.console_silent(0) && !cli.console_silent(1),
		"console_silent did not reject the zero width alone",
	)
}

// console_width is the width rich's Console would size itself to, and rich reads
// `$COLUMNS` only when it holds digits (rich/console.py:685-694 — the console's
// own `_width` — and `Console.size`'s `width = width or 80` for the rest):
// anything else, the variable unset and the empty string included, leaves the
// 80-column fallback. The gate is `str.isdigit()` and not "an integer": a sign,
// a space at either end, an underscore or a `0x`/`0b` prefix all leave the
// variable unread, so `1_0` is 80 columns and not 10 (docs/PARITY.md §3.1).
// `0` passes the gate like any other digit string and is a width rich takes
// literally — the zero-width console `console_silent` reports. So does a digit
// string longer than this port's `int`, which names a console wider than any
// line and is clamped to `max(int)` (t_3a12ca73, `width_of_digits`).
@(test)
test_console_width_reads_columns_like_rich :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cases := []struct {
		vars: []string,
		want: int,
	}{
		{[]string{"COLUMNS=80"}, 80},
		{[]string{"COLUMNS=200"}, 200},
		{[]string{"COLUMNS=1"}, 1},
		{[]string{"COLUMNS=99999"}, 99999},
		{[]string{"COLUMNS=08"}, 8},
		// The gate's *range* is Python's as well: `int()` is unbounded, so a
		// digit string too long for an `int` names a console wider than any
		// line and is clamped to `max(int)` — a width no line reaches — instead
		// of being wrapped. `strconv.parse_int` wrapped it silently, which read
		// `10000000000000000000` as a *negative* width (the silent console
		// `console_silent` reports) and `18446744073709551621` as 5 (t_3a12ca73).
		{[]string{"COLUMNS=9223372036854775807"}, max(int)},
		{[]string{"COLUMNS=9223372036854775808"}, max(int)},
		{[]string{"COLUMNS=10000000000000000000"}, max(int)},
		{[]string{"COLUMNS=9999999999999999999"}, max(int)},
		{[]string{"COLUMNS=100000000000000000000"}, max(int)},
		{[]string{"COLUMNS=18446744073709551616"}, max(int)},
		{[]string{"COLUMNS=18446744073709551621"}, max(int)},
		// ...but the digits are still a *number*: leading zeros do not overflow,
		// so a twenty-digit string that spells 1 is the width 1 (and a 20-digit
		// string of zeros is the zero width, above).
		{[]string{"COLUMNS=00000000000000000001"}, 1},
		// The gate is Unicode-wide, because `str.isdigit()` is: the width is the
		// number the digits *spell* in their own script, read out of the
		// reference interpreter's Unicode database (src/cli/python_digits.odin,
		// t_14a26d57). ARABIC-INDIC `٠` is the zero-width console above,
		// ARABIC-INDIC `١٢` is twelve cells, and the other scripts' digits are
		// the numbers they name — mixed with ASCII ones included.
		{[]string{"COLUMNS=٠"}, 0},
		{[]string{"COLUMNS=٠٠"}, 0},
		{[]string{"COLUMNS=١٢"}, 12},
		{[]string{"COLUMNS=１２"}, 12},
		{[]string{"COLUMNS=٣"}, 3},
		{[]string{"COLUMNS=๓๕"}, 35},
		{[]string{"COLUMNS=१००"}, 100},
		{[]string{"COLUMNS=𝟡𝟡"}, 99},
		{[]string{"COLUMNS=1٢"}, 12},
		{[]string{"COLUMNS=١0"}, 10},
		// A digit `int()` refuses — a superscript or subscript, which has no
		// decimal value — spells no width at all: the reference dies inside
		// `Console.__init__` before the console exists (`console_crash`), so
		// this proc never publishes a width for it and stays total.
		{[]string{"COLUMNS=²"}, 80},
		{[]string{"COLUMNS=1²"}, 80},
		{[]string{"COLUMNS=₀"}, 80},
		// `0`, `00`, `000`: digits, and the width rich takes literally. The
		// console renders nothing at that size (console_silent).
		{[]string{"COLUMNS=0"}, 0},
		{[]string{"COLUMNS=00"}, 0},
		{[]string{"COLUMNS=000"}, 0},
		// Not a width: rich's `isdigit()` gate, then the port's own parse.
		{[]string{"COLUMNS="}, 80},
		// A digit string rich's `int()` would turn into a width the port reads
		// as no width at all: the sign is not a digit.
		{[]string{"COLUMNS=-0"}, 80},
		{[]string{"COLUMNS=+0"}, 80},
		{[]string{"COLUMNS=+80"}, 80},
		{[]string{"COLUMNS=-5"}, 80},
		{[]string{"COLUMNS=abc"}, 80},
		{[]string{"COLUMNS= 120"}, 80},
		{[]string{"COLUMNS=120 "}, 80},
		{[]string{"COLUMNS= 0"}, 80},
		{[]string{"COLUMNS=0 "}, 80},
		{[]string{"COLUMNS=2.5"}, 80},
		{[]string{"COLUMNS=80x"}, 80},
		// A separator or a base prefix is not a digit either: rich never sees
		// these, although Odin's own `parse_int` would (0x10 is 16 to it).
		{[]string{"COLUMNS=1_0"}, 80},
		{[]string{"COLUMNS=0x10"}, 80},
		{[]string{"COLUMNS=0x0"}, 80},
		{[]string{"COLUMNS=0b0"}, 80},
		// Unset.
		{[]string{"TERM=xterm-256color"}, 80},
	}
	for c in cases {
		env := cli.env_info_from_strings(c.vars, false, false, false, context.temp_allocator)
		got := cli.console_width(env)
		testing.expectf(t, got == c.want, "console_width(%v) = %d, want %d", c.vars, got, c.want)
	}
}

// console_crash is the other half of the same gate: the `$COLUMNS` values that
// pass `str.isdigit()` and that `int(columns)` then refuses — the superscripts
// and subscripts, which have a numeric *type* and no decimal value. rich raises
// `ValueError: invalid literal for int() with base 10: '…'` inside
// `Console.__init__` and the reference dies there, before any console exists
// (rich/console.py:685-694; docs/PARITY.md §3.1, §8.20; t_14a26d57). The result
// is the value rich refused — the one the port's line quotes — and "" for every
// console rich can build.
@(test)
test_console_crash_marks_the_columns_rich_cannot_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cases := []struct {
		vars: []string,
		want: string,
	}{
		// `isdigit()` yes, `int()` no: every superscript and subscript digit,
		// alone, in a run and mixed with decimal digits.
		{[]string{"COLUMNS=²"}, "²"},
		{[]string{"COLUMNS=³"}, "³"},
		{[]string{"COLUMNS=¹"}, "¹"},
		{[]string{"COLUMNS=⁴"}, "⁴"},
		{[]string{"COLUMNS=₀"}, "₀"},
		{[]string{"COLUMNS=²²"}, "²²"},
		{[]string{"COLUMNS=1²"}, "1²"},
		{[]string{"COLUMNS=٢²"}, "٢²"},
		// Every value rich can read is "": the widths (the zero one included),
		// the digits of every other script, the fallbacks.
		{[]string{"COLUMNS="}, ""},
		{[]string{"COLUMNS=0"}, ""},
		{[]string{"COLUMNS=00"}, ""},
		{[]string{"COLUMNS=80"}, ""},
		{[]string{"COLUMNS=١٢"}, ""},
		{[]string{"COLUMNS=𝟡𝟡"}, ""},
		{[]string{"COLUMNS=abc"}, ""},
		{[]string{"COLUMNS=-1"}, ""},
		{[]string{"COLUMNS= 80"}, ""},
		{[]string{"COLUMNS=1_0"}, ""},
		{[]string{"COLUMNS=0x10"}, ""},
		{[]string{"COLUMNS=\x80"}, ""},
		{[]string{"TERM=xterm-256color"}, ""},
	}
	for c in cases {
		env := cli.env_info_from_strings(c.vars, false, false, false, context.temp_allocator)
		got := cli.console_crash(env)
		testing.expectf(t, got == c.want, "console_crash(%v) = %q, want %q", c.vars, got, c.want)
		// The two are one gate: a value rich cannot read is no width at all —
		// the fallback keeps `console_width` total, and the crash is what the
		// writers act on — while a value it can read is never a crash.
		if got != "" {
			testing.expectf(
				t,
				cli.console_width(env) == cli.RICH_WIDTH,
				"%v: a value rich cannot read names no width, got %d",
				c.vars,
				cli.console_width(env),
			)
		}
	}
}

// The two `$COLUMNS` predicates are CPython's `str.isdigit()` and the decimal
// half of `int()`, and the tables behind them are generated from the *reference
// interpreter's* Unicode database (src/cli/python_digits_generated.odin,
// build/gen_python_digits_table.py). The hashes below are the check that the
// compiled predicates answer for **every** code point the way that database
// does: FNV-1a 64 over the bitmap of each predicate's bit for every code point
// 0x0..0x10ffff in order, most-significant bit first — the same values the
// generator computes from `unicodedata`, so a table that drifted, or a binary
// search that misses a range by one, fails here rather than on one shape.
@(test)
test_python_digits_match_the_generated_bitmaps :: proc(t: ^testing.T) {
	// The boundaries the gate turns on, named one by one: the ASCII ten, the
	// space either side of them, the first astral code point, the end of the
	// range, the ARABIC-INDIC and fullwidth digits, the mathematical ones — and
	// the superscripts, which are digits with no decimal value, i.e. the one
	// place the two predicates disagree.
	testing.expect(t, cli.python_char_is_digit('0'), "'0' is a digit")
	testing.expect(t, cli.python_char_is_digit('9'), "'9' is a digit")
	testing.expect(t, !cli.python_char_is_digit('/'), "'/' is not")
	testing.expect(t, !cli.python_char_is_digit(':'), "':' is not")
	testing.expect(t, !cli.python_char_is_digit(' '), "the space is not")
	testing.expect(t, cli.python_char_is_digit('\u0660'), "ARABIC-INDIC DIGIT ZERO is")
	testing.expect(t, cli.python_char_is_digit('\uff10'), "FULLWIDTH DIGIT ZERO is")
	testing.expect(t, cli.python_char_is_digit('\u0e53'), "THAI DIGIT THREE is")
	testing.expect(t, cli.python_char_is_digit('\u0966'), "DEVANAGARI ZERO is")
	testing.expect(t, cli.python_char_is_digit('\U0001d7ce'), "MATHEMATICAL BOLD ZERO is")
	testing.expect(t, cli.python_char_is_digit('\U0001d7ff'), "and its fifty-range's end")
	testing.expect(t, !cli.python_char_is_digit(0x10ffff), "the last code point is not")
	testing.expect(t, cli.python_char_is_digit('\u00b2'), "SUPERSCRIPT TWO passes isdigit()")
	testing.expect(t, cli.python_char_is_digit('\u2080'), "SUBSCRIPT ZERO passes isdigit()")

	testing.expect(t, cli.python_char_is_digit('0'), "the ASCII zero is a digit")
	value, decimal := cli.python_decimal_value('7')
	testing.expect(t, decimal && value == 7, "'7' is worth 7")
	value, decimal = cli.python_decimal_value('\u0660')
	testing.expect(t, decimal && value == 0, "ARABIC-INDIC ZERO is worth 0")
	value, decimal = cli.python_decimal_value('\uff19')
	testing.expect(t, decimal && value == 9, "FULLWIDTH NINE is worth 9")
	value, decimal = cli.python_decimal_value('\U0001d7d8')
	testing.expect(t, decimal && value == 0, "MATHEMATICAL DOUBLE-STRUCK ZERO is 0")
	value, decimal = cli.python_decimal_value('\U0001d7e1')
	testing.expect(t, decimal && value == 9, "the same range's nine is 9")
	value, decimal = cli.python_decimal_value('\U0001d7ff')
	testing.expect(t, decimal && value == 9, "MATHEMATICAL MONOSPACE NINE is 9")
	_, decimal = cli.python_decimal_value('\u00b2')
	testing.expect(t, !decimal, "SUPERSCRIPT TWO has no decimal value")
	_, decimal = cli.python_decimal_value('\u2080')
	testing.expect(t, !decimal, "SUBSCRIPT ZERO has no decimal value")
	_, decimal = cli.python_decimal_value('a')
	testing.expect(t, !decimal, "'a' has no decimal value")

	digit_hash := u64(0xcbf29ce484222325)
	decimal_hash := u64(0xcbf29ce484222325)
	digit_byte := u8(0)
	decimal_byte := u8(0)
	bit := u8(0x80)
	for code := rune(0); code <= 0x10ffff; code += 1 {
		if cli.python_char_is_digit(code) {
			digit_byte |= bit
		}
		if _, ok := cli.python_decimal_value(code); ok {
			decimal_byte |= bit
		}
		bit >>= 1
		if bit == 0 {
			digit_hash = (digit_hash ~ u64(digit_byte)) * u64(0x100000001b3)
			decimal_hash = (decimal_hash ~ u64(decimal_byte)) * u64(0x100000001b3)
			digit_byte = 0
			decimal_byte = 0
			bit = 0x80
		}
	}
	testing.expect_value(t, digit_hash, cli.PYTHON_DIGIT_BITMAP_HASH)
	testing.expect_value(t, decimal_hash, cli.PYTHON_DECIMAL_BITMAP_HASH)
}

// The cell measure the wrap breaks on is rich's `get_character_cell_size`
// (rich/cells.py) for the code points an emoji value can introduce: two cells
// for an emoji, zero for the joiners and the variation selectors, and one cell
// for everything the generated table does not name (which is rich's answer for
// the ASCII range and the port's standing approximation outside it).
@(test)
test_emoji_cell_width_follows_richs_table :: proc(t: ^testing.T) {
	cases := []struct {
		code: rune,
		want: int,
	}{
		{'\U0001F604', 2}, // smile, and the emoji an item cannot spell otherwise
		{'a', 1},
		{'\u2764', 1}, // heart: the table's one-cell value
		{'\u200d', 0}, // ZWJ
		{'\ufe0e', 0}, // the `-text` selector
		{'\ufe0f', 0}, // the `-emoji` selector
		{'\U0001F3FB', 0}, // a skin-tone modifier
		{'\n', 0}, // rich drops the control characters
		{'\u007f', 0},
		{'\u009f', 0}, // Cc, not DEL: rich counts 0x7f..0x9f as zero cells
		{'\u00a0', 1},
		{'\u4e2d', 1}, // outside the table: the port's approximation, unchanged
	}
	for c in cases {
		got := rich.cell_width(c.code)
		testing.expectf(
			t,
			got == c.want,
			"cell_width(U+%04X) = %d, want %d",
			c.code,
			got,
			c.want,
		)
	}
}
