package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:format"

@(test)
test_content_type_classification :: proc(t: ^testing.T) {
	cases := [?]struct {
		content_type: string,
		want:         format.Kind,
	}{
		{"application/json", format.Kind.Json},
		{"application/json; charset=utf-8", format.Kind.Json},
		{"APPLICATION/JSON", format.Kind.Json},
		{"application/vnd.api+json", format.Kind.Json},
		{"application/x-www-form-urlencoded", format.Kind.Form},
		{"multipart/form-data; boundary=x", format.Kind.Multipart},
		{"text/html; charset=UTF-8", format.Kind.Html},
		{"application/xml", format.Kind.Xml},
		{"text/plain", format.Kind.Text},
		{"image/png", format.Kind.Binary},
		{"", format.Kind.Unknown},
	}
	for entry in cases {
		got := format.kind_for_content_type(entry.content_type)
		testing.expectf(t, got == entry.want, "%q: want %v, got %v", entry.content_type, entry.want, got)
	}
}

// test_json_escape_surrogates pins json.loads' rule for a `\uXXXX` escape that
// spells a surrogate, which is the *parser* half of the JSON body's escaping
// (docs/PARITY.md §3.4). The parity scenarios `raw-json-surrogate-*` and
// `raw-json-lone-surrogate-*` compare the whole command against the reference;
// this test is what pins the halves no passing scenario can reach:
//
//   - the look-ahead's *range*: a high surrogate combines with a following
//     `\uDC00-\uDFFF` escape and with nothing else (a `\u0041` after it leaves
//     both characters where they are) — the `any-escape-combines` mutant moves
//     exactly this and no scenario notices;
//   - the *representation* of a lone surrogate outside U+DC80-U+DCFF, which has
//     no byte in the port's str layer: a Surrogate_String whose `text` holds one
//     U+FFFD placeholder per mark and whose marks carry the code unit itself
//     (the shape §3.4 records as the rule);
//   - the two spellings `write_escaped_string` gives a mark: the body's
//     ensure_ascii dump spells it `\udXXX` like json.dumps does, the formatter's
//     ensure_ascii=False dump writes the placeholder — the character the port
//     wrote before the mark existed (the printed request body's own rendering of
//     that character is t_bf308590).
@(test)
test_json_escape_surrogates :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// A U+FFFD: what an out-of-band surrogate stands on in the port's bytes.
	replacement :: "\xef\xbf\xbd"

	// The escapes the port can hold as characters: a pair combines, and a lone
	// low surrogate in U+DC80-U+DCFF *is* one of its bytes.
	combining := [?]struct {
		text: string,
		want: string,
	}{
		{`"\ud83d\ude00"`, "\xf0\x9f\x98\x80"},              // a pair combines
		{`"\uD83D\uDE00"`, "\xf0\x9f\x98\x80"},              // the hex case is the text's
		{`"\ud800\udc00"`, "\xf0\x90\x80\x80"},              // U+10000, the lowest astral one
		{`"\udbff\udfff"`, "\xf4\x8f\xbf\xbf"},              // U+10FFFF, the highest
		{`"\udcff"`, "\xff"},                                // a lone low surrogate: the byte
		{`"\udc80"`, "\x80"},                                // …at the low end of the range
		{`"\udcff\ud83d\ude00"`, "\xff\xf0\x9f\x98\x80"},    // a lone one, then a pair
		{`"\u00e9"`, "\xc3\xa9"},                            // a plain escape is untouched
	}
	for entry in combining {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%s: unexpected error %q", entry.text, err.message)
		got, ok := value.(string)
		testing.expectf(t, ok, "%s: not a plain string", entry.text)
		testing.expectf(t, got == entry.want, "%s: want %q, got %q", entry.text, entry.want, got)
		format.value_destroy(&value, allocator)
	}

	// The escapes with no byte: the value is a Surrogate_String, one mark per
	// character, each pointing at the placeholder that stands in for it. The
	// `\u0041` and `\ud800\ud800` rows are the look-ahead's range — a high
	// surrogate is a character of its own in front of anything but a low one —
	// and the last two are the pair/byte cases above, unchanged.
	lone := [?]struct {
		text:  string,
		bytes: string,
		marks: []format.Surrogate_Mark,
	}{
		{`"\ud800"`, replacement, []format.Surrogate_Mark{{offset = 0, code = 0xd800}}},
		{`"\udc01"`, replacement, []format.Surrogate_Mark{{offset = 0, code = 0xdc01}}},
		{`"\ude00"`, replacement, []format.Surrogate_Mark{{offset = 0, code = 0xde00}}},
		{`"\udfff"`, replacement, []format.Surrogate_Mark{{offset = 0, code = 0xdfff}}},
		{`"\ud800\u0041"`, replacement + "A", []format.Surrogate_Mark{{offset = 0, code = 0xd800}}},
		{`"\ud800x"`, replacement + "x", []format.Surrogate_Mark{{offset = 0, code = 0xd800}}},
		{
			`"\ud800\ud800"`,
			replacement + replacement,
			[]format.Surrogate_Mark{{offset = 0, code = 0xd800}, {offset = 3, code = 0xd800}},
		},
		{
			`"\u00e9\ud800"`,
			"\xc3\xa9" + replacement,
			[]format.Surrogate_Mark{{offset = 2, code = 0xd800}},
		},
		{
			// A low surrogate that follows a *high* one combines with it — an
			// escape, not a byte, but the same rule — so only the first high
			// surrogate is a character the port cannot hold.
			`"\ud800\ud800\udcff"`,
			replacement + "\xf0\x90\x83\xbf", // U+100FF
			[]format.Surrogate_Mark{{offset = 0, code = 0xd800}},
		},
	}
	for entry in lone {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%s: unexpected error %q", entry.text, err.message)
		marked, ok := value.(format.Surrogate_String)
		testing.expectf(t, ok, "%s: not a Surrogate_String", entry.text)
		if ok {
			testing.expectf(t, marked.text == entry.bytes, "%s: want text %q, got %q",
			                entry.text, entry.bytes, marked.text)
			testing.expectf(t, len(marked.marks) == len(entry.marks), "%s: want %d marks, got %d",
			                entry.text, len(entry.marks), len(marked.marks))
			for mark, i in entry.marks {
				if i >= len(marked.marks) {
					break
				}
				testing.expectf(t, marked.marks[i].offset == mark.offset && marked.marks[i].code == mark.code,
				                "%s: mark %d: want {offset %d, code %x}, got {offset %d, code %x}",
				                entry.text, i, mark.offset, mark.code,
				                marked.marks[i].offset, marked.marks[i].code)
			}
		}
		format.value_destroy(&value, allocator)
	}

	// The serialiser's half, through the three dumps httpie's streams use: the
	// request body escapes the character the way json.dumps' ensure_ascii does
	// (as a *value* and as a *key*), a response formatter's dump keeps the
	// placeholder the port's bytes carry for it — and the *printed* body's dump
	// spells a mark `?`, because the stream that writes that text encodes with
	// `errors='replace'` (output/streams.py:225, httpie/encoding.py:44-50), and
	// a lone surrogate is exactly a character that encoding cannot represent.
	// The in-band case is the one this layer does *not* spell: the dump writes
	// the byte its str layer holds for U+DC80-U+DCFF, and the printed `?` comes
	// from the stream's encoder one layer out (src/output/render.odin,
	// encode_printed_part) — which is why the expectation below is the byte.
	escaped := [?]struct {
		text:    string,
		want:    string,
		printed: string,
	}{
		{`{"a": "\ud800"}`, `{"a": "\ud800"}`, `{"a": "?"}`},
		{`{"\ud800": 1}`, `{"\ud800": 1}`, `{"?": 1}`},
		{
			`{"\ud800\ud801": ["\udc01", "\ud800x"]}`,
			`{"\ud800\ud801": ["\udc01", "\ud800x"]}`,
			`{"??": ["?", "?x"]}`,
		},
		{`{"a": "\udcff"}`, `{"a": "\udcff"}`, "{\"a\": \"\xff\"}"},
	}
	for entry in escaped {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%s: unexpected error %q", entry.text, err.message)
		got := format.dump_to_string(&value, format.body_dump_options(), allocator)
		testing.expectf(t, got == entry.want, "%s: body dump: want %s, got %s", entry.text, entry.want, got)
		delete(got, allocator)
		formatted := format.dump_to_string(&value, format.default_dump_options(), allocator)
		testing.expectf(t, !strings.contains(formatted, `\ud800`) && !strings.contains(formatted, "\xed\xa0\x80"),
		                "%s: the formatter's dump must not spell the surrogate, got %q", entry.text, formatted)
		delete(formatted, allocator)
		printed_options := format.default_dump_options()
		printed_options.printed = true
		printed := format.dump_to_string(&value, printed_options, allocator)
		testing.expectf(t, printed == entry.printed, "%s: printed dump: want %s, got %s",
		                entry.text, entry.printed, printed)
		delete(printed, allocator)
		format.value_destroy(&value, allocator)
	}

	// The lookup half of the key's rule: `object_find` compares characters, so a
	// marked key is never the argv text that stands on its bytes. A parity
	// scenario cannot pin *the lookup* here: the items that would show it write
	// into a `:=` value's live dict, and that value renders the pairs it was
	// parsed with (t_1cf72f31's freeze), so neither item's write ever lands and
	// both binaries agree whatever the lookup does
	// (build/probe_lone_surrogate_key_lookup.py: 8 same, 0 diff after that card;
	// `nested-json-frozen-marked-key-offline` pins the freeze on the same road).
	// The lookup is therefore asserted here, on the parsed object itself.
	lookup := [?]struct {
		text:  string,
		key:   string,
		found: bool,
	}{
		{`{"\ud800": 1}`, "\xef\xbf\xbd", false}, // the placeholder's bytes are not the character
		{`{"\ufffd": 1}`, "\xef\xbf\xbd", true},  // …but a key that *is* U+FFFD is found
		{`{"\udcff": 1}`, "\xff", true},          // a lone surrogate that *is* a byte is found
		{`{"a": 1}`, "a", true},
		{`{"a": 1}`, "b", false},
	}
	for entry in lookup {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%s: unexpected error %q", entry.text, err.message)
		object, ok := value.(format.Object)
		testing.expectf(t, ok, "%s: not an object", entry.text)
		if ok {
			index := format.object_find(&object, entry.key)
			testing.expectf(t, (index >= 0) == entry.found,
			                "%s: lookup %q: want found=%v, got index %d",
			                entry.text, entry.key, entry.found, index)
		}
		format.value_destroy(&value, allocator)
	}

	expect_no_leaks(t, &track)
}

// test_json_invalid_u_escape pins the half of `case 'u'` the surrogate rule
// above leaves out (t_b671fe01): an escape whose four characters are not four
// hex digits is *refused*, and CPython's C scanner — the one `json.loads` uses —
// refuses it in two places (`Modules/_json.c:scanstring_unicode`):
//
//   - a character of the four that is not a hex digit (:505);
//   - an escape whose four digits are not followed by one more character of the
//     document (:487, `if (end >= len)`), which is why `"\u1234` is a refused
//     escape and not the unterminated string the port used to report, and why a
//     surrogate pair that ends the document does not combine.
//
// httpie prints the refusal as a usage error, so the message and its position
// are the observable: the `u` of the escape whose digits failed — char 2 for
// `"\uZZZZ"` and char 8, the *second* escape, for `"\ud800\uZZZZ"`. The parity
// scenarios `raw-json-invalid-escape-*` compare the whole command against the
// reference (both halves, a key, a nested value and the two controls that must
// keep parsing); this test asserts the exact wording, the boundary and the
// shapes a scenario's argv comparison would report as one mismatch.
@(test)
test_json_invalid_u_escape :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The refusals, word for word. The position is the `u` of the failing
	// escape in every one of them.
	refused := [?]struct {
		text: string,
		want: string,
	}{
		{`"\uZZZZ"`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u5"`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u12g4"`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u12x4"`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u123g"`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u"`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u1`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u12`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u123`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u1234`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"}, // digits, then end
		{`"\ud83d`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"}, // a high surrogate, then end
		{`"\ud800\uZZZZ"`, "Invalid \\uXXXX escape: line 1 column 9 (char 8)"},
		{`"\ud800\u12"`, "Invalid \\uXXXX escape: line 1 column 9 (char 8)"},
		{`"\ud83d\ude00`, "Invalid \\uXXXX escape: line 1 column 9 (char 8)"}, // the pair does not combine
		{`"\ud83d\ude00\udc`, "Invalid \\uXXXX escape: line 1 column 15 (char 14)"},
		{`{"\uZZZZ": 1}`, "Invalid \\uXXXX escape: line 1 column 4 (char 3)"},
		{`{"b": "\uZZZZ"}`, "Invalid \\uXXXX escape: line 1 column 9 (char 8)"},
		{`"\uZZZZ\uDC00"`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`  "\u12`, "Invalid \\uXXXX escape: line 1 column 5 (char 4)"}, // whitespace moves the position
	}
	for entry in refused {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == entry.want, "%s: want %q, got %q",
		                entry.text, entry.want, err.message)
		format.json_error_destroy(&err)
		format.value_destroy(&value, allocator)
	}

	// The controls. One more character behind the four digits is all the
	// boundary asks for (`"\u1234"` and `"\u1234a"`), and a literal backslash in
	// front of a `uXXXX` is not an escape at all.
	parsed := [?]struct {
		text: string,
		want: string,
	}{
		{`"\u1234"`, "\xe1\x88\xb4"},          // U+1234
		{`"\u1234a"`, "\xe1\x88\xb4a"},        // the boundary, one character later
		{`"\ud83d\ude00"`, "\xf0\x9f\x98\x80"}, // U+1F600
		{`"\u00e9"`, "\xc3\xa9"},              // U+00E9
		{`"\\uZZZZ"`, "\\uZZZZ"},              // a backslash, then the letters
	}
	for entry in parsed {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%s: unexpected error %q", entry.text, err.message)
		got, ok := value.(string)
		testing.expectf(t, ok, "%s: not a string", entry.text)
		testing.expectf(t, got == entry.want, "%s: want %q, got %q", entry.text, entry.want, got)
		format.value_destroy(&value, allocator)
	}

	expect_no_leaks(t, &track)
}

// test_json_invalid_escape pins the *position* of the `Invalid \escape` refusal
// (t_bbb94489) — the neighbour of the rule above in the same escape switch, and
// the one the port used to place wrong. A backslash escape that is neither one
// of the table escapes nor a `\u` is refused by both implementations with the
// same wording and the same block; CPython's C scanner reports the index of the
// **backslash** (`Modules/_json.c:479`,
// `raise_errmsg("Invalid \\escape", pystr, end - 2)`, `end` being one past the
// escaped character by then), where the port reported the position its own scan
// stopped at — `line 1 column 4 (char 3)` for `"\q"` against the reference's
// `line 1 column 2 (char 1)`.
//
// The position of this message is *counted* from the parser's origin rather than
// derived by subtracting from a column, and the shapes below are what that
// distinction is for: the escaped character can itself be a newline
// (`"ab\<LF>cd"` stays on line 1 at column 4), and a newline in front of the
// string moves the line instead (`[\n"\q"]` is line 2 column 2, char 3). The
// third half — the counting is in *characters* and not in bytes (§3.4,
// t_91f3546a) — is what makes `"é\q"` `char 2` on both sides; the shapes here
// either keep the escape in front of any multi-byte character or carry one
// *behind* the backslash, and `test_json_position_counts_characters` is where
// the multi-byte shapes themselves are asserted.
//
// The parity scenarios `raw-json-invalid-backslash-escape-*` compare the whole
// command against the reference (the CLI's item repr included); this test
// asserts the wording and the positions without the CLI in the way.
@(test)
test_json_invalid_escape :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The refusals, word for word: the position is the escape's *backslash*
	// (column = chars + 1), never the escaped character.
	refused := [?]struct {
		text: string,
		want: string,
	}{
		{`"\q"`, "Invalid \\escape: line 1 column 2 (char 1)"},
		{`"\UZZZZ"`, "Invalid \\escape: line 1 column 2 (char 1)"}, // the C scanner's `\U`
		{`"\x41"`, "Invalid \\escape: line 1 column 2 (char 1)"},
		{`"\0"`, "Invalid \\escape: line 1 column 2 (char 1)"},
		{`"ab\qcd"`, "Invalid \\escape: line 1 column 4 (char 3)"},
		{`"\\\q"`, "Invalid \\escape: line 1 column 4 (char 3)"}, // the *second* backslash
		{"\"ab\\\ncd\"", "Invalid \\escape: line 1 column 4 (char 3)"}, // the escaped char is a LF
		{"[\n\"\\q\"]", "Invalid \\escape: line 2 column 2 (char 3)"}, // the LF is outside the string
		{`{"a\qb": 1}`, "Invalid \\escape: line 1 column 4 (char 3)"},
		{`{"a": "\q"}`, "Invalid \\escape: line 1 column 8 (char 7)"},
		{`{"a": "x", "b": "y\qz"}`, "Invalid \\escape: line 1 column 19 (char 18)"},
		{`"\é"`, "Invalid \\escape: line 1 column 2 (char 1)"}, // the escaped char is not ASCII
	}
	for entry in refused {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == entry.want, "%s: want %q, got %q",
		                entry.text, entry.want, err.message)
		format.json_error_destroy(&err)
		format.value_destroy(&value, allocator)
	}

	// The controls: the table escapes are what the rule must not start refusing,
	// the escaped backslash included — a literal `\` in front of a `q` leaves the
	// `q` as ordinary text, and a `\n` that *is* an escape still moves the line.
	parsed := [?]struct {
		text: string,
		want: string,
	}{
		{`"\t"`, "\t"},
		{`"\""`, "\""},
		{`"\/"`, "/"},
		{`"\\q"`, "\\q"},
		{`"ab\ncd"`, "ab\ncd"},
	}
	for entry in parsed {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%s: unexpected error %q", entry.text, err.message)
		got, ok := value.(string)
		testing.expectf(t, ok, "%s: not a string", entry.text)
		testing.expectf(t, got == entry.want, "%s: want %q, got %q", entry.text, entry.want, got)
		format.value_destroy(&value, allocator)
	}

	expect_no_leaks(t, &track)
}

// test_json_control_character pins the refusal of a **raw** control character in
// a `:=` value's text (t_4dca8209). CPython's C scanner — the one `json.loads`
// uses — tests `d <= 0x1f` as it scans for the closing quote and words the
// refusal `Invalid control character at` (`Modules/_json.c:425`; the trailing
// `at` is that message's own, and the port printed it without), at the index of
// the character itself (`raise_errmsg(msg, pystr, next)`), so no look-back is
// involved and the port's `error_at` is the position Python reports.
//
// The pure-Python scanner words the same refusal differently — the character's
// own `repr()` sits in the middle of the message (`json/decoder.py:98`) — and is
// not the reference for the same reason it is not the reference for a malformed
// `\uXXXX` escape: `json.loads` uses the C scanner.
//
// The second table is the rule's three boundaries: every byte from 0x00 to 0x1f
// is refused, wherever it stands and in a key as well as a value; a control
// character an *escape* spells (`\u0001`, `\t`) is legal JSON; and 0x7f — one
// byte above the range — and a printable space are not refused at all, so a
// guard that grew one byte too wide shows up there. A byte at or above 0x80 is a
// rune to the guard and is kept as it stands.
//
// The parity scenarios `raw-json-control-character-*` compare the whole command
// against the reference and carry the card's own shapes — the raw 0x01 and the
// raw 0x02 — beside a TAB, an LF and a CR, a key, a nested value and one live
// shape; this test asserts the same wording for the characters the CLI has no
// shape for (0x00, 0x1f, and a character on the second line of the text) and
// pins the three boundaries of the range. Measured against the reference's own
// `json.loads` in build/control-character-parser.txt
// (build/probe_control_character_parser.py) and through both CLIs in
// build/control-character-shapes.txt (build/probe_control_character_shapes.py).
@(test)
test_json_control_character :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The refusals, word for word. The position is the control character's own,
	// counted in characters: a newline in front of it moves the line
	// (`[\n"\x01"]` is line 2 column 2, char 3).
	refused := [?]struct {
		text: string,
		want: string,
	}{
		{"\"a\tb\"", "Invalid control character at: line 1 column 3 (char 2)"},
		{"\"ab\ncd\"", "Invalid control character at: line 1 column 4 (char 3)"},
		{"\"ab\rcd\"", "Invalid control character at: line 1 column 4 (char 3)"},
		{"\"a\x01b\"", "Invalid control character at: line 1 column 3 (char 2)"},
		{"\"\x01\"", "Invalid control character at: line 1 column 2 (char 1)"},
		{"\"a\x00b\"", "Invalid control character at: line 1 column 3 (char 2)"},
		{"\"a\x1fb\"", "Invalid control character at: line 1 column 3 (char 2)"},
		{"\"\x1f\"", "Invalid control character at: line 1 column 2 (char 1)"},
		{"\"ab\nc\x01d\"", "Invalid control character at: line 1 column 4 (char 3)"},
		{"{\"a\": \"b\x02c\"}", "Invalid control character at: line 1 column 9 (char 8)"},
		{"{\"a\x02b\": 1}", "Invalid control character at: line 1 column 4 (char 3)"},
		{"{\"a\": {\"b\": \"\x01\"}}", "Invalid control character at: line 1 column 14 (char 13)"},
		{"\"\\n\x01\"", "Invalid control character at: line 1 column 4 (char 3)"},
		{"[\n\"\x01\"]", "Invalid control character at: line 2 column 2 (char 3)"},
	}
	for entry in refused {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == entry.want, "%q: want %q, got %q",
		                entry.text, entry.want, err.message)
		format.json_error_destroy(&err)
		format.value_destroy(&value, allocator)
	}

	// The controls: the escapes that spell a control character keep parsing, the
	// byte above the range and the printable ones are kept, and an empty string
	// is not a refusal either.
	parsed := [?]struct {
		text: string,
		want: string,
	}{
		{"\"\\u0001\"", "\x01"},
		{"\"\\u001f\"", "\x1f"},
		{"\"\\t\"", "\t"},
		{"\"\\n\"", "\n"},
		{"\"a\x7fb\"", "a\x7fb"},
		{"\"a b\"", "a b"},
		{"\"a\xe9b\"", "a\xe9b"},
		{"\"\"", ""},
	}
	for entry in parsed {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%q: unexpected error %q", entry.text, err.message)
		got, ok := value.(string)
		testing.expectf(t, ok, "%q: not a string", entry.text)
		testing.expectf(t, got == entry.want, "%q: want %q, got %q", entry.text, entry.want, got)
		format.value_destroy(&value, allocator)
	}

	expect_no_leaks(t, &track)
}

// test_json_unterminated_string_position pins the *position* of the
// `Unterminated string starting at` refusal (t_cd0dff90), the message of
// `parse_string`'s own end-of-text branch. CPython's C scanner words it with
// `begin` — the index of the string's opening quote (`Modules/_json.c:444` and
// `:460`, `raise_errmsg("Unterminated string starting at", pystr, begin)` with
// `begin = end - 1`) — and `JSONDecodeError` counts the line and the column from
// that same offset, while the `char` it prints is that offset too. The port
// printed the string's `char` beside the position its own scan stopped at
// (`"abc` was `line 1 column 5 (char 0)` where the reference says `line 1
// column 1 (char 0)`), so the two halves came from different places.
//
// The shapes below are what the rule has to hold for:
//
//   * the string anywhere in the document — a value, a key, a nested value, a
//     document that is only the string — with the column where the quote stands;
//   * a string that starts on a **later line**, where the line number is part of
//     the message (`[\n"abc` is line 2 column 1, char 2) and the column restarts
//     on that line instead of counting the bytes in front of the quote;
//   * the two ways the scan can reach the end of the text without a broken
//     escape first: an ordinary character (or none at all) and a trailing
//     backslash, whose escape has no character behind it.
//
// The two tables after the refusals are the neighbours this rule must not
// swallow: a newline *inside* the string is the control-character refusal of
// `test_json_control_character`, and a `\uXXXX` escape that ends the text is the
// refused escape of `test_json_invalid_u_escape` — both keep their own position,
// which a rule that reported the string's position for every string failure
// would break.
//
// The position convention of §3.4 (t_91f3546a) reaches this message through the
// same `position_of`: the counts are in *characters*, so a multi-byte character
// in front of the opening quote moves it by one character and not by its bytes —
// `a:={"é": "abc` is `char 6` on both sides, asserted in
// `test_json_position_counts_characters`. The shapes here keep their multi-byte
// characters *behind* the quote, where the two conventions agreed by accident,
// and are the ASCII half of this rule. The parity scenarios
// `raw-json-unterminated-string-*` compare the whole command against the
// reference (the CLI's item repr included); this test asserts the wording and the
// positions without the CLI in the way. Measured against the reference's own
// `json.loads` in build/unterminated-string-parser.txt
// (build/probe_unterminated_string_parser.py) and through both CLIs in
// build/unterminated-string-shapes.txt (build/probe_unterminated_string_shapes.py).
@(test)
test_json_unterminated_string_position :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The refusals, word for word: the position is the opening quote's, so
	// column = the quote's offset + 1 on its own line (line 1 unless a newline
	// stands in front of the string).
	refused := [?]struct {
		text: string,
		want: string,
	}{
		{`"abc`, "Unterminated string starting at: line 1 column 1 (char 0)"},
		{`{"a": "abc`, "Unterminated string starting at: line 1 column 7 (char 6)"},
		{`"\u1234a`, "Unterminated string starting at: line 1 column 1 (char 0)"},
		{`{"abc`, "Unterminated string starting at: line 1 column 2 (char 1)"}, // a *key*
		{`["abc`, "Unterminated string starting at: line 1 column 2 (char 1)"},
		{`[[["abc`, "Unterminated string starting at: line 1 column 4 (char 3)"},
		{`{"a": [1, "abc`, "Unterminated string starting at: line 1 column 11 (char 10)"},
		{`"a\`, "Unterminated string starting at: line 1 column 1 (char 0)"}, // the escape has no character
		{`"`, "Unterminated string starting at: line 1 column 1 (char 0)"},
		{`"\`, "Unterminated string starting at: line 1 column 1 (char 0)"},
		// A later line: the line number is the string's, and the column
		// restarts there rather than counting the bytes in front of the quote.
		{"[\n\"abc", "Unterminated string starting at: line 2 column 1 (char 2)"},
		{"{\n\"abc", "Unterminated string starting at: line 2 column 1 (char 2)"},
		{"{\n\"a\": \"abc", "Unterminated string starting at: line 2 column 6 (char 7)"},
		{"{\"a\":\n\"abc", "Unterminated string starting at: line 2 column 1 (char 6)"},
		{"[\n   \"abc", "Unterminated string starting at: line 2 column 4 (char 5)"},
		{"[\n\n\"abc", "Unterminated string starting at: line 3 column 1 (char 3)"},
	}
	for entry in refused {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == entry.want, "%s: want %q, got %q",
		                entry.text, entry.want, err.message)
		format.json_error_destroy(&err)
		format.value_destroy(&value, allocator)
	}

	// The neighbours: the two refusals that fire *before* the string can run to
	// the end of the text, each with the position of the thing it names.
	neighbours := [?]struct {
		text: string,
		want: string,
	}{
		{"[\n\"ab\ncd", "Invalid control character at: line 2 column 4 (char 5)"},
		{`["\u1234`, "Invalid \\uXXXX escape: line 1 column 4 (char 3)"},
	}
	for entry in neighbours {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == entry.want, "%s: want %q, got %q",
		                entry.text, entry.want, err.message)
		format.json_error_destroy(&err)
		format.value_destroy(&value, allocator)
	}

	// The controls: a string that does close parses as it always did, and a
	// newline *outside* the string is ordinary JSON whitespace.
	parsed := [?]struct {
		text: string,
		want: string, // empty when the value is not a string
	}{
		{`"abc"`, "abc"},
		{`"a\nb"`, "a\nb"},
		{`{"a": "abc"}`, ""},
		{`["abc", "def"]`, ""},
		{"[1,\n 2]", ""},
	}
	for entry in parsed {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%s: unexpected error %q", entry.text, err.message)
		if entry.want != "" {
			got, ok := value.(string)
			testing.expectf(t, ok, "%s: not a string", entry.text)
			testing.expectf(t, got == entry.want, "%s: want %q, got %q", entry.text, entry.want, got)
		}
		format.value_destroy(&value, allocator)
	}

	expect_no_leaks(t, &track)
}

// test_json_prefixed_escape_position guards the *origin* of the positions above
// on the one road that has a non-JSON prefix in front of the JSON value: httpie's
// response formatter keeps an XSSI prefix and re-parses what follows
// (`load_prefixed_json`), which is `parse_prefixed_json`, so the positions count
// from the value's own start and not from the text handed in — the count a
// line/column *counter* used to produce before t_bbb94489 replaced it with the
// parser's `origin` (`src/format/json.odin`). The `char` half is an offset into
// that same value and not into the whole text (t_91f3546a): it is the
// reference's own convention, because the second attempt CPython's
// `load_prefixed_json` makes hands `json.loads` the *value* alone
// (`httpie/output/utils.py:20-22`), so `char 8` and not the byte 13 the port used
// to print. The message itself never reaches a CLI comparison on this road — the
// formatter swallows the parse error (src/output/render.odin:575) — so what this
// test pins is the convention the two other roads are measured against.
@(test)
test_json_prefixed_escape_position :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// `XSSI)` is the prefix: five bytes, so the backslash is at byte 13 of the
	// text and char 8 of the value (`{"a": "b\qc"}` → index 8), column 9.
	body := `XSSI){"a": "b` + "\\" + `qc"}`
	value, prefix_len, err := format.parse_prefixed_json(body, allocator)
	testing.expectf(t, err.message == "Invalid \\escape: line 1 column 9 (char 8)",
	                "prefixed escape: got %q", err.message)
	testing.expectf(t, prefix_len == 5, "prefixed escape: want prefix_len 5, got %d", prefix_len)
	format.json_error_destroy(&err)
	format.value_destroy(&value, allocator)

	// The same refusal one line down: the prefix's own bytes are not counted as a
	// line, and the value's newline is — char 8 again, since nothing above the
	// escape is multi-byte.
	body2 := `XSSI){"a":` + "\n" + `"b` + "\\" + `qc"}`
	value2, prefix_len2, err2 := format.parse_prefixed_json(body2, allocator)
	testing.expectf(t, err2.message == "Invalid \\escape: line 2 column 3 (char 8)",
	                "prefixed escape on line 2: got %q", err2.message)
	testing.expectf(t, prefix_len2 == 5, "prefixed escape: want prefix_len 5, got %d", prefix_len2)
	format.json_error_destroy(&err2)
	format.value_destroy(&value2, allocator)

	expect_no_leaks(t, &track)
}

// test_json_position_counts_characters pins the convention every parse error
// above is worded with (t_91f3546a): `line`, `column` and `char` count
// **characters** of the document, the way `json.JSONDecodeError.__init__` counts
// them (`lineno = doc.count('\n', 0, pos) + 1`, `colno = pos - doc.rfind('\n', 0,
// pos)`, with `pos` the index CPython's C scanner passed into a `str`) — and not
// the bytes of their UTF-8 encoding. The port counted bytes, so `a:="é\uZZZZ"`
// was `char 4` where the reference says `char 3`.
//
// One character, whatever its width: a two-byte `é`, a three-byte `€`, a
// four-byte 😀 and a three-byte U+FEFF — content once the parse has started, see
// test_json_leading_bom — each move the position by exactly one, and two of them
// in a row by two. The ASCII shapes must not move at all. The parity scenarios
// `raw-json-position-nonascii-*` compare the same shapes against the reference
// through the CLI (both item roads); this test asserts the exact wording without
// the CLI, the width boundary a "non-ASCII is two bytes" reading gets wrong, and
// the `char` offset of a message the reference words with the *string's*
// position rather than the scan's.
@(test)
test_json_position_counts_characters :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// Refusals, word for word: `é` is `\xc3\xa9`, `€` is `\xe2\x82\xac`, `😀` is
	// `\xf0\x9f\x98\x80` and the mark is `\xef\xbb\xbf`. Each row's position was
	// measured against the reference on both the `:=` and the `:=@file` road,
	// which agree on the message (build/json-positions-nonascii.txt).
	refused := [?]struct {
		text: string,
		want: string,
	}{
		// The malformed escape behind one character of each width: two, three
		// and four bytes are all one position.
		{"\"\xc3\xa9\\uZZZZ\"", "Invalid \\uXXXX escape: line 1 column 4 (char 3)"},
		{"\"\xe2\x82\xac\\uZZZZ\"", "Invalid \\uXXXX escape: line 1 column 4 (char 3)"},
		{"\"\xf0\x9f\x98\x80\\uZZZZ\"", "Invalid \\uXXXX escape: line 1 column 4 (char 3)"},
		// Two characters in a row are two positions, and one ASCII character
		// beside them is one more.
		{"\"\xc3\xa9\xc3\xa9\\uZZZZ\"", "Invalid \\uXXXX escape: line 1 column 5 (char 4)"},
		{"\"a\xc3\xa9\\uZZZZ\"", "Invalid \\uXXXX escape: line 1 column 5 (char 4)"},
		// The same decoder in a key, and behind a line break.
		{"{\"\xc3\xa9\\uZZZZ\": 1}", "Invalid \\uXXXX escape: line 1 column 5 (char 4)"},
		{"[\n\"\xc3\xa9\\uZZZZ\"]", "Invalid \\uXXXX escape: line 2 column 4 (char 5)"},
		// The other three refusals behind a non-ASCII character.
		{"\"\xc3\xa9\x1f\"", "Invalid control character at: line 1 column 3 (char 2)"},
		{"\"\xc3\xa9\\q\"", "Invalid \\escape: line 1 column 3 (char 2)"},
		{"\"\xc3\xa9\" x", "Extra data: line 1 column 5 (char 4)"},
		{"\"\xc3\xa9\"\nx", "Extra data: line 2 column 1 (char 4)"},
		// The unterminated message names the *string's* position (:444/:460),
		// counted in characters: the key in front of it is `{`, `"`, `é`, `"`,
		// `:`, ` ` — six of them.
		{"{\"\xc3\xa9\": \"abc", "Unterminated string starting at: line 1 column 7 (char 6)"},
		// A mark inside a string is content, and counts as one character like
		// every other (test_json_leading_bom pins the same rule after the
		// document, `char 9`).
		{"\"\xef\xbb\xbf\" x", "Extra data: line 1 column 5 (char 4)"},
		{"\"\xef\xbb\xbf\\uZZZZ\"", "Invalid \\uXXXX escape: line 1 column 4 (char 3)"},
		// The no-move controls: ASCII-only documents keep every position they
		// had, the two halves of the rule that are *not* about the width of a
		// character included.
		{"{\"a\": \"b\\qc\"}", "Invalid \\escape: line 1 column 9 (char 8)"},
		{"{\"a\": \"b\x02c\"}", "Invalid control character at: line 1 column 9 (char 8)"},
		{"\"ab\\uZZZZ\"", "Invalid \\uXXXX escape: line 1 column 5 (char 4)"},
	}
	for entry in refused {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == entry.want, "%s: want %q, got %q",
		                entry.text, entry.want, err.message)
		format.json_error_destroy(&err)
		format.value_destroy(&value, allocator)
	}

	// The controls: a character of any width is *content* in a well-formed
	// document, and the counting does not touch what the value is.
	parsed := [?]struct {
		text: string,
		want: string,
	}{
		{"\"\xc3\xa9\"", "\xc3\xa9"},
		{"\"\xe2\x82\xac\"", "\xe2\x82\xac"},
		{"\"\xf0\x9f\x98\x80\"", "\xf0\x9f\x98\x80"},
		{"\"\xef\xbb\xbf\"", "\xef\xbb\xbf"},          // the mark, inside a string
		{"\"\xc3\xa9\\u00e9\"", "\xc3\xa9\xc3\xa9"},   // an escape beside a raw one
		{"\"\xc3\xa9\\ud83d\\ude00\"", "\xc3\xa9\xf0\x9f\x98\x80"}, // a pair behind it
	}
	for entry in parsed {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == "", "%s: unexpected error %q", entry.text, err.message)
		got, ok := value.(string)
		testing.expectf(t, ok, "%s: not a string", entry.text)
		testing.expectf(t, got == entry.want, "%s: want %q, got %q", entry.text, entry.want, got)
		format.value_destroy(&value, allocator)
	}

	expect_no_leaks(t, &track)
}

// test_json_leading_bom pins the decoder's own pre-check against a byte order
// mark (docs/PARITY.md §8.18(f)): `json.loads` refuses a leading U+FEFF before
// it parses anything, with a message of its own, so a `:=` value that *is* a BOM
// followed by valid JSON reports the BOM and not `Expecting value`. The
// reference reaches it through `f'{arg.orig!r}: {e}'`
// (httpie/cli/requestitems.py:226-230); the parity scenarios
// `json-bom-raw-json-file-*`, `json-bom-session-file-*` and
// `json-bom-form-*` compare the whole command, and build/probe_json_bom.py is
// the measurement the rule came from.
//
// Two things the scenarios cannot pin are asserted here, because they are the
// boundary the rule would silently get wrong:
//
//   * the check is at *character zero only*: a whitespace character in front of
//     the mark is the ordinary parse error, with the position the reference
//     reports for it;
//   * the mark is content once the parse has started — inside a string, and
//     after the document (`Extra data`), where its three bytes are three bytes
//     and the reported `char` offset counts them as one (the reference's
//     decoder counts *characters*).
//     The response-body entry point is asserted beside them: `load_prefixed_json`
//     retries a failed parse through the XSSI prefix, so a BOM there is a
//     *prefix* and must stay parseable (the `bom-json-format` case of
//     build/probe_json_bom.py pretty-prints the JSON behind it).
@(test)
test_json_leading_bom :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	bom :: "\xef\xbb\xbf"
	bom_message :: "Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)"

	// The shapes that reach the check: the mark first, whatever follows it.
	refused := [?]string{
		bom + `{"a": 1}`,      // valid JSON behind it: not a parse error
		bom + `1`,             // a bare number
		bom,                   // nothing but the mark
		bom + "\n\n[1, 2]\n",  // the position is 0 whatever the rest says
		bom + bom + `{}`,      // two marks: still the first character's error
	}
	for text in refused {
		value, err := format.parse_json(text, allocator)
		testing.expectf(t, err.message == bom_message, "%q: want the BOM message, got %q",
		                text, err.message)
		format.json_error_destroy(&err)
		format.value_destroy(&value, allocator)
	}

	// The boundary: the check is at character zero, and a mark anywhere else is
	// ordinary text with the parse error it deserves.
	controls := [?]struct {
		text: string,
		want: string, // "" means the text parses
	}{
		{" " + bom + `{"a": 1}`, "Expecting value: line 1 column 2 (char 1)"},
		{"\n" + bom + `{"a": 1}`, "Expecting value: line 2 column 1 (char 1)"},
		{`{"a": "` + bom + `"}`, ""},
		{`{"a": 1}` + "\n" + bom, "Extra data: line 2 column 1 (char 9)"},
	}
	for entry in controls {
		value, err := format.parse_json(entry.text, allocator)
		testing.expectf(t, err.message == entry.want, "%q: want %q, got %q",
		                entry.text, entry.want, err.message)
		format.json_error_destroy(&err)
		format.value_destroy(&value, allocator)
	}

	// The response body: the prefix scan keeps the mark, so the JSON behind it
	// is still parsed and re-serialised (output/utils.py:9-25).
	body := bom + `{"b" : 2, "a": 1}`
	value, prefix_len, err := format.parse_prefixed_json(body, allocator)
	testing.expectf(t, err.message == "", "prefixed: unexpected error %q", err.message)
	testing.expectf(t, prefix_len == len(bom), "prefixed: want prefix_len %d, got %d",
	                len(bom), prefix_len)
	testing.expectf(t, body[:prefix_len] == bom, "prefixed: the mark is not in the prefix")
	format.json_error_destroy(&err)
	format.value_destroy(&value, allocator)

	expect_no_leaks(t, &track)
}

// test_json_object_freeze pins the value model behind t_1cf72f31's rule, which
// the parity scenarios `nested-json-frozen-*` only reach through the CLI.
//
// A `:=`/`:=@` value is parsed the reference's way — every object in it is a
// `JsonDictPreservingDuplicateKeys` (httpie/utils.py:27-71) — so `format.Object`
// carries the pairs it was parsed with (`frozen_pairs`, the class's `_items`)
// beside the live dict later writes go to (`members`, the real OrderedDict), and
// `object_pairs` is what the serialiser renders. What this test asserts is the
// shape of that representation, which no scenario can show on its own:
//
//   - the pairs move to `frozen_pairs` and render, whatever the live dict says;
//   - the live dict starts *empty*, plus the `'__hack__'` key
//     `_ensure_items_used` plants when there is something to render — so
//     `object_find` never finds a parsed key there, and finds `__hack__` only on
//     a non-empty value (an empty `{}` has no pairs to render and gets no key);
//   - a write into the live dict (what `object_set`/`object_child` do) changes
//     nothing about the rendered bytes, in either dump — and the write is still
//     *readable*, which is the half that makes a deeper path continue through it;
//   - the recursion: an object inside an array or inside another object is
//     frozen too, because json's object hook is called for every object;
//   - `value_freeze` is idempotent, and a value that never went through it (a
//     response body, a session file, a config file — every other `parse_json`
//     caller) is untouched.
@(test)
test_json_object_freeze :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	body_opts := format.body_dump_options()
	sorted_opts := format.Dump_Options {
		indent       = -1,
		sort_keys    = true,
		ensure_ascii = true,
	}

	// The parsed object, frozen, and a write into its live dict — the shape
	// `a:={"b": 1, "a": {"c": 2}}` `a[c]:=3` builds.
	text :: `{"b": 1, "a": {"c": 2}}`
	value, err := format.parse_json(text, allocator)
	testing.expectf(t, err.message == "", "unexpected error %q", err.message)
	format.json_error_destroy(&err)
	format.value_freeze(&value, allocator)
	// Idempotent: a second freeze must not move anything again.
	format.value_freeze(&value, allocator)

	object, ok := value.(format.Object)
	testing.expectf(t, ok, "frozen value is not an object")
	testing.expectf(t, object.frozen, "the object is not frozen")
	testing.expectf(t, len(object.frozen_pairs) == 2, "want 2 rendered pairs, got %d",
	                len(object.frozen_pairs))
	testing.expectf(t, len(format.object_pairs(object)) == 2, "object_pairs: want 2, got %d",
	                len(format.object_pairs(object)))
	// The live dict: the planted key alone, so no parsed key is *readable* here.
	testing.expectf(t, len(object.members) == 1, "the live dict wants the planted key, got %d",
	                len(object.members))
	testing.expectf(t, format.object_find(&object, "b") == -1,
	                "a parsed key must not be in the live dict")
	testing.expectf(t, format.object_find(&object, "a") == -1,
	                "a parsed key must not be in the live dict")
	testing.expectf(t, format.object_find(&object, "__hack__") == 0,
	                "the planted key is missing from a non-empty live dict")

	// The write (the slice `object_set`/`object_child` grow) is invisible in the
	// body and in a sorted dump, and readable through `object_find`.
	written := make([]format.Member, len(object.members) + 1, allocator)
	copy(written, object.members)
	written[len(object.members)] = format.Member {
		key   = strings.clone("c", allocator) or_else "",
		value = i64(3),
	}
	delete(object.members, allocator)
	object.members = written
	value = object

	testing.expectf(t, format.object_find(&object, "c") == 1,
	                "the written key must be readable in the live dict")
	rendered := format.dump_to_string(&value, body_opts, allocator)
	testing.expectf(t, rendered == text, "the write moved the body: want %s, got %s", text, rendered)
	delete(rendered, allocator)
	rendered = format.dump_to_string(&value, sorted_opts, allocator)
	testing.expectf(t, rendered == `{"a": {"c": 2}, "b": 1}`,
	                "the write moved the sorted dump: got %s", rendered)
	delete(rendered, allocator)
	format.value_destroy(&value, allocator)

	// The recursion and the empty case: `[{"b": 1}]` freezes the object inside the
	// list; `{}` is frozen with nothing to render and gets no planted key.
	value, err = format.parse_json(`[{"b": 1}, {}, [{"c": 2}]]`, allocator)
	testing.expectf(t, err.message == "", "unexpected error %q", err.message)
	format.json_error_destroy(&err)
	format.value_freeze(&value, allocator)
	items, is_list := value.([]format.Value)
	testing.expectf(t, is_list, "not a list")
	inner, is_object := items[0].(format.Object)
	testing.expectf(t, is_object && inner.frozen, "the object inside the list is not frozen")
	testing.expectf(t, len(format.object_pairs(inner)) == 1, "the inner list object lost its pairs")
	empty, is_empty_object := items[1].(format.Object)
	testing.expectf(t, is_empty_object && empty.frozen, "the empty object inside the list is not frozen")
	testing.expectf(t, len(empty.frozen_pairs) == 0 && len(empty.members) == 0,
	                "an empty parsed object must render nothing and plant no key")
	deep_list, is_deep_list := items[2].([]format.Value)
	testing.expectf(t, is_deep_list, "not a list")
	deep, is_deep_object := deep_list[0].(format.Object)
	testing.expectf(t, is_deep_object && deep.frozen,
	                "the object inside the list inside the list is not frozen")
	rendered = format.dump_to_string(&value, body_opts, allocator)
	testing.expectf(t, rendered == `[{"b": 1}, {}, [{"c": 2}]]`,
	                "the frozen list moved: got %s", rendered)
	delete(rendered, allocator)
	format.value_destroy(&value, allocator)

	// The other half: a value that never went through `value_freeze` — every
	// other caller of `parse_json` (a response body, a session or config file) —
	// keeps the plain object it always had.
	value, err = format.parse_json(`{"b": 1}`, allocator)
	testing.expectf(t, err.message == "", "unexpected error %q", err.message)
	format.json_error_destroy(&err)
	plain, is_plain := value.(format.Object)
	testing.expectf(t, is_plain && !plain.frozen, "an unfrozen parse must not be frozen")
	testing.expectf(t, format.object_find(&plain, "b") == 0,
	                "an unfrozen object keeps its members")
	rendered = format.dump_to_string(&value, body_opts, allocator)
	testing.expectf(t, rendered == `{"b": 1}`, "an unfrozen object renders its members: got %s", rendered)
	delete(rendered, allocator)
	format.value_destroy(&value, allocator)

	expect_no_leaks(t, &track)
}
