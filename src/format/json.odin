// JSON value model, parser and serializer for the httpie port.
//
// Why hand-rolled instead of core:encoding/json: httpie's observable bytes are
// Python's `json.dumps`/`json.loads` bytes. The serializer here follows them
// (`, ` and `: ` separators without an indent, newline+indent per item with
// one, `sort_keys` sorting recursively, `ensure_ascii` as the caller asked for
// it) and the parser reports errors the way Python's json module words them,
// because httpie prints that message verbatim in its usage errors:
//
//     'a:=not-json': Expecting value: line 1 column 1 (char 0)
//     'a:="\uZZZZ"': Invalid \uXXXX escape: line 1 column 3 (char 2)
//
// `ensure_ascii` is the one option httpie does *not* pass consistently, and
// both spellings are load-bearing: the response formatter dumps with
// `ensure_ascii=False` (`output/formatters/json.py`), while the *request body*
// is `json.dumps(data)` with the module defaults (`client.py:317`), i.e.
// `ensure_ascii=True`. `default_dump_options` is the first and
// `body_dump_options` the second; docs/PARITY.md §3.4 has the body's rule.
//
// docs/PARITY.md §3.4 and §4.2 pin the behaviour; the captures in
// docs/parity-captures are the byte-level reference.
//
// Ownership: a Value owns every string, array and object below it, all
// allocated from the allocator passed to `parse` (or to the *_create helpers).
// `value_destroy` frees the whole tree.
package format

import "core:fmt"
import "core:io"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Null is the JSON null. It is a type rather than a nil so that a Value union
// can hold it explicitly.
Null :: struct {}

Member :: struct {
	key:   string,
	value: Value,
	// key_marks are the out-of-band surrogates `key` carries, the same rule the
	// string case of Value follows: `a:={"\ud800": 1}` is a *key* whose text has
	// no byte in the port either. A key built from argv (a bracket path, an item
	// name) never has one.
	key_marks: []Surrogate_Mark,
}

Object :: struct {
	members: []Member,
	// frozen is true for an object that came from a `:=`/`:=@` item's
	// json.loads, i.e. from `load_json_preserve_order_and_dupe_keys`
	// (httpie/utils.py:72-73). Such an object is the reference's
	// `JsonDictPreservingDuplicateKeys` (utils.py:27-71): the pairs it was
	// *parsed* with are what `json.dumps` renders (the class overrides
	// `items()` to return them), and every later write lands in the live dict
	// the serialiser never reads.
	//
	// `frozen_pairs` is that rendered list; the live dict is `members`, which
	// starts empty — the hook's `__init__` never copies the pairs into the real
	// OrderedDict — so a bracket-path write into a frozen object is invisible
	// in the body while a later path step that *reads* it still sees it
	// (docs/PARITY.md §3.3).
	frozen: bool,
	frozen_pairs: []Member,
}

// object_pairs is what json.dumps renders for an object: the pairs it was
// parsed with when it is a frozen `:=` value, its live members otherwise.
object_pairs :: proc(obj: Object) -> []Member {
	return obj.frozen ? obj.frozen_pairs : obj.members
}

// HACK_KEY is the key the reference plants in a parsed object's live dict
// (`_ensure_items_used`, httpie/utils.py:40-64): the C encoder skips a dict
// whose `ma_used` is 0 and reads its own storage, so one item is added whenever
// there are pairs to render. The port renders `frozen_pairs` and needs the key
// for the one thing that can see it — a bracket path that reads it.
@(private)
HACK_KEY :: "__hack__"

// Surrogate_Mark is one character of a Surrogate_String: a lone surrogate
// json.loads kept in the value whose character the port's byte-str layer cannot
// hold. `offset` is the byte offset in the string's own bytes of the one U+FFFD
// placeholder that stands in for it, and `code` is the code unit itself —
// U+D800-U+DBFF for a high surrogate, or a low one outside U+DC80-U+DCFF.
//
// Marks are what keeps the representation un-collidable: the byte space is
// already the image of CPython's surrogateescape decode (U+DC80-U+DCFF, one per
// byte 0x80-0xff), so *no* in-band spelling exists for another surrogate — the
// bytes `ED A0 BD` an argv can carry are three lone surrogates of their own to
// the reference (`\udced\udca0\udcbd` in the body, the `json-body-invalid-
// sequences-*` scenarios). The information therefore travels beside the bytes,
// not inside them.
Surrogate_Mark :: struct {
	offset: int,
	code:   u32,
}

// Surrogate_String is a JSON string value that carries at least one such
// surrogate. `text` is the surrogateescape byte image every other consumer of a
// `string` value expects, with one U+FFFD (three bytes, SURROGATE_PLACEHOLDER_LEN)
// where each mark sits — so a reader that ignores `marks` sees exactly the
// character the serialiser wrote before this representation existed, and the
// request body's own escape (`\udXXX`, json.dumps' ensure_ascii spelling of the
// character) is the only road that has to know. A string is this type when and
// only when it has at least one mark.
Surrogate_String :: struct {
	text:  string,
	marks: []Surrogate_Mark,
}

// SURROGATE_PLACEHOLDER is the character a mark's slot in `Surrogate_String.text`
// holds: U+FFFD, the character the port used to write for every lone surrogate.
@(private)
SURROGATE_PLACEHOLDER :: "\xef\xbf\xbd"

// SURROGATE_PLACEHOLDER_LEN is its length in bytes — what a writer adds to its
// own offset when it steps over a marked slot.
@(private)
SURROGATE_PLACEHOLDER_LEN :: 3

Value :: union {
	Null,
	bool,
	i64,
	f64,
	string,
	Surrogate_String,
	[]Value,
	Object,
}

// string_parts answers the byte image and the out-of-band surrogates of a
// parsed string value: what every consumer that does not care about the marks
// reads, and what the two that do (the body serialiser and the form encoder)
// need beside it.
string_parts :: proc(v: Value) -> (text: string, marks: []Surrogate_Mark) {
	#partial switch s in v {
	case string:
		return s, nil
	case Surrogate_String:
		return s.text, s.marks
	}
	return "", nil
}

// value_is_string answers whether a value is a string at all — the plain case or
// the Surrogate_String one. string_parts cannot tell an empty string from a
// value that is no string, and a JSON document can carry both.
value_is_string :: proc(v: Value) -> bool {
	#partial switch s in v {
	case string, Surrogate_String:
		return true
	}
	return false
}

// Dump_Options mirrors the part of json.dumps' signature httpie uses.
Dump_Options :: struct {
	indent:     int, // -1: no indentation (json.dumps(indent=None))
	sort_keys:  bool,
	ensure_ascii: bool, // True escapes every character outside ' '..'~' (json.dumps' own default)
	indent_tabs: bool, // json.dumps(indent="	"): one tab per level
	// printed is the *printing* side's dump: the response formatter's output is
	// the text a stream then encodes with `errors='replace'`
	// (output/streams.py:225, httpie/encoding.py:44-50), and a marked surrogate
	// is exactly a character that encoding cannot represent — so its slot holds
	// '?' here, one per character. The other two spellings of the same
	// character are the *sending* side's (`\udXXX`, the ensure_ascii dump of a
	// request body) and the placeholder the marks point at, which is what a
	// reader that does not know about the marks must keep seeing.
	printed: bool,
}

// default_dump_options is json.dumps with the arguments httpie's *response*
// formatter passes (`ensure_ascii=False`, json.py:12-34).
default_dump_options :: proc() -> Dump_Options {
	return {indent = -1, sort_keys = false, ensure_ascii = false, indent_tabs = false}
}

// body_dump_options is json.dumps with *no* arguments beyond the value: the
// call that serialises the request body (`json.dumps(data)` inside
// json_dict_to_request_body, client.py:311-319). The difference from
// default_dump_options is ensure_ascii, which Python defaults to True, so every
// character outside `' '..'~'` is escaped — `é` is the six bytes `\u00e9`, an
// astral one its surrogate pair, and a byte that is not valid UTF-8 the
// `\udcXX` of the lone surrogate the reference's argv decode made of it
// (docs/PARITY.md §3.4, §3.6).
body_dump_options :: proc() -> Dump_Options {
	return {indent = -1, sort_keys = false, ensure_ascii = true, indent_tabs = false}
}

value_destroy :: proc(v: ^Value, allocator: mem.Allocator) {
	if v == nil {
		return
	}
	#partial switch value in v^ {
	case string:
		delete(value, allocator)
	case Surrogate_String:
		delete(value.text, allocator)
		delete(value.marks, allocator)
	case []Value:
		for i in 0 ..< len(value) {
			value_destroy(&value[i], allocator)
		}
		delete(value, allocator)
	case Object:
		for i in 0 ..< len(value.members) {
			delete(value.members[i].key, allocator)
			delete(value.members[i].key_marks, allocator)
			value_destroy(&value.members[i].value, allocator)
		}
		delete(value.members, allocator)
		// A frozen object owns both halves: the rendered parse-time pairs and
		// the live dict its later writes landed in. They are disjoint slices.
		if value.frozen {
			for i in 0 ..< len(value.frozen_pairs) {
				delete(value.frozen_pairs[i].key, allocator)
				delete(value.frozen_pairs[i].key_marks, allocator)
				value_destroy(&value.frozen_pairs[i].value, allocator)
			}
			delete(value.frozen_pairs, allocator)
		}
	}
	v^ = Null{}
}

// value_freeze drills a value in place as one a `:=`/`:=@` item's json.loads
// produced. Every object in it becomes the reference's
// `JsonDictPreservingDuplicateKeys` (httpie/utils.py:27-71), because that is what
// `load_json_preserve_order_and_dupe_keys` — the parser behind *every* `:=` value
// (requestitems.py:226-230) — passes as json's `object_pairs_hook`:
//
//   - the pairs the object was parsed with move to `frozen_pairs` and are what
//     the serialiser renders, so a later bracket-path write into the object is
//     dropped from the body (`interpret.py:75`/`:88`/`:98` write into the dict
//     `json.dumps` never reads);
//   - the live dict (`members`) starts empty — the hook's `__init__` never
//     copies the pairs into the real OrderedDict — plus the `'__hack__'` key
//     `_ensure_items_used` plants when there is something to render, which is
//     what makes `a[__hack__]` *find* a string on a non-empty parsed object and
//     nothing at all on an empty one;
//   - so a write is invisible in the body but visible to a later read:
//     `a:={"b": 1}` `a[c]:=3` `a[c][d]:=4` is the reference's type error, and
//     `a:={"b": {"c": 1}}` `a[b][c][d]:=2` is a body that still says `1`.
//
// Lists are *not* frozen: json.loads' object hook only ever sees objects, so
// `a:=[1,2]` `a[]:=3` appends like any other array (§3.3, measured in
// build/probe_frozen_dict.py). The recursion is what the hook's own recursion
// does — every object of the document, however deep, including the ones inside
// arrays. Idempotent.
value_freeze :: proc(v: ^Value, allocator: mem.Allocator) {
	#partial switch value in v^ {
	case Object:
		if value.frozen {
			return
		}
		live: []Member
		if len(value.members) > 0 {
			live = make([]Member, 1, allocator)
			live[0] = Member {
				key   = strings.clone(HACK_KEY, allocator) or_else "",
				value = strings.clone(HACK_KEY, allocator) or_else "",
			}
		}
		pairs := value.members
		v^ = Object {
			members      = live,
			frozen       = true,
			frozen_pairs = pairs,
		}
		for i in 0 ..< len(pairs) {
			value_freeze(&pairs[i].value, allocator)
		}
	case []Value:
		for i in 0 ..< len(value) {
			value_freeze(&value[i], allocator)
		}
	}
}

// object_find returns the index of `key` in an object, or -1. Later duplicate
// keys shadow earlier ones, as they do in Python dicts.
//
// The search is over `members`, the *live* dict — which for a frozen `:=` object
// is the one its later writes went to and not the pairs it renders, exactly as a
// `d[key]` on the reference's `JsonDictPreservingDuplicateKeys` reads the real
// OrderedDict and never `_items` (docs/PARITY.md §3.3).
//
// A key that carries an out-of-band surrogate is never *equal* to `key`: the
// lookup key is argv text, whose str cannot hold one, and Python's `'\ud800'`
// is not `'\ufffd'` even though both stand on three identical bytes here. The
// mark-less test is what keeps the two apart.
object_find :: proc(obj: ^Object, key: string) -> int {
	index := -1
	for member, i in obj.members {
		if member.key == key && len(member.key_marks) == 0 {
			index = i
		}
	}
	return index
}

object_get :: proc(obj: ^Object, key: string) -> (^Value, bool) {
	index := object_find(obj, key)
	if index < 0 {
		return nil, false
	}
	return &obj.members[index].value, true
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

JSON_Error :: struct {
	allocator: mem.Allocator,
	message:   string, // Python's json.JSONDecodeError wording
}

json_error_destroy :: proc(err: ^JSON_Error) {
	if err == nil {
		return
	}
	delete(err.message, err.allocator)
	err^ = {}
}

Parser :: struct {
	allocator: mem.Allocator,
	text:      string,
	pos:       int,
	// The byte `line`/`col` are counted from: 0 for a whole document, and the
	// JSON value's own start when httpie keeps a non-JSON prefix in front of it
	// (parse_prefixed_json). It is the only position state the parser keeps —
	// `error_at_offset` counts the line, the column and the `char` offset of a
	// position from here when it needs them, so no counter can drift from `pos`.
	origin: int,
}

// advance consumes `count` bytes. There is no line/column counter to move along
// with it: the position a message names is computed from `origin` and the text
// when an error is raised (`error_at_offset`), so it cannot drift from `pos`.
@(private)
advance :: proc(p: ^Parser, count: int = 1) {
	for _ in 0 ..< count {
		if p.pos >= len(p.text) {
			return
		}
		p.pos += 1
	}
}

// UTF8_BOM is the UTF-8 encoding of U+FEFF, the character a byte order mark
// decodes to. It is a *decoder* rule, not part of the grammar: `json.loads`
// refuses it at the very start of a str, before it looks at the text at all
// (CPython's json/__init__.py:loads):
//
//	if isinstance(s, str):
//	    if s.startswith('\ufeff'):
//	        raise JSONDecodeError("Unexpected UTF-8 BOM (decode using utf-8-sig)",
//	                              s, 0)
//
// The position is 0 by construction, so the message is always the one below and
// the text behind the mark is never parsed. httpie prints it verbatim, wrapped
// in the item's own `f'{arg.orig!r}: {e}'` (httpie/cli/requestitems.py:226-230):
//
//	'x:=\ufeff{"a":1}': Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)
//
// — the shape docs/PARITY.md §8.18(f) pins, on the `:=` road (value inline or
// from a file), on the session file (`json.load`) and on the config file.
//
// Only the *text* is a port decision: the same bytes reached `parse_json` on
// this road before, as an "Expecting value" at the same position, because the
// port modelled the decoder's parse and not the check that precedes it. A BOM
// anywhere else stays ordinary text: mid-document it is the parse error the
// character deserves (`\n\ufeff{…}` is still `Expecting value: line 2 column 1
// (char 1)`), and inside a string it is content.
@(private)
UTF8_BOM :: "\xef\xbb\xbf"

@(private)
BOM_ERROR_MESSAGE :: "Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)"

// parse_json parses `text` as a JSON document, exactly one value, the way
// Python's json.loads does (trailing whitespace allowed, anything else an
// "Extra data" error), and refuses a leading byte order mark the way it does
// too (see UTF8_BOM above).
parse_json :: proc(text: string, allocator: mem.Allocator) -> (value: Value, err: JSON_Error) {
	// json.loads' own pre-check, which runs before the decoder looks at the
	// text at all: a leading U+FEFF is *its* error, so the message and the
	// position are the decoder's and the text behind the mark is never parsed
	// (see UTF8_BOM). Every caller httpie builds on `json.loads`/`json.load`
	// reaches it — the `:=` and `:=@` item readers (src/cli/items.odin), the
	// session file (src/session/store.odin) and the config file
	// (src/cli/parse.odin) — and each prints the message in its own shape.
	if strings.has_prefix(text, UTF8_BOM) {
		return Null{}, JSON_Error {
			allocator = allocator,
			message   = strings.clone(BOM_ERROR_MESSAGE, allocator) or_else "",
		}
	}
	p := Parser{allocator = allocator, text = text}
	skip_whitespace(&p)
	value = parse_value(&p, &err)
	if err.message != "" {
		return Null{}, err
	}
	skip_whitespace(&p)
	if p.pos < len(p.text) {
		msg := error_at(&p, "Extra data")
		value_destroy(&value, allocator)
		return Null{}, JSON_Error{allocator = allocator, message = msg}
	}
	return value, {}
}

// parse_prefix parses the leading JSON value of `text` and reports how many
// bytes it consumed; httpie's `load_prefixed_json` keeps any non-JSON prefix.
//
// A leading BOM is deliberately *not* refused here the way parse_json refuses
// it: json.loads' BOM check is the reference's *first* attempt only, and
// `load_prefixed_json` (output/utils.py:9-25) catches every ValueError of that
// attempt and retries with the XSSI prefix `PREFIX_REGEX` = `[^{\["]+` cut off
// the front (output/lexers/json.py:8). A BOM is such a prefix, so the JSON
// behind it parses and the mark travels through as part of the prefix — which
// is exactly what the scan below does, and why a response body that starts with
// a BOM is pretty-printed with the BOM kept (build/probe_json_bom.py's
// `bom-json-format` case).
parse_prefixed_json :: proc(text: string, allocator: mem.Allocator) -> (value: Value, prefix_len: int, err: JSON_Error) {
	p := Parser{allocator = allocator, text = text}
	skip_whitespace(&p)
	// A JSON document must open with one of these; anything else is a prefix.
	if p.pos >= len(text) {
		return Null{}, 0, JSON_Error{allocator = allocator, message = error_at(&p, "Expecting value")}
	}
	switch text[p.pos] {
	case '{', '[', '"', 't', 'f', 'n', '-', '0' ..= '9':
	// fall through: this is the JSON body
	case:
		// Try to find the first plausible JSON start, mirroring the prefix
		// handling of httpie's EnhancedJsonLexer / load_prefixed_json.
		start := -1
		for i in p.pos ..< len(text) {
			switch text[i] {
			case '{', '[', '"':
				start = i
			case:
				continue
			}
			break
		}
		if start < 0 {
			return Null{}, 0, JSON_Error{allocator = allocator, message = error_at(&p, "Expecting value")}
		}
		p.pos = start
		// The positions the parser reports now count from the JSON value's own
		// start, not from the text handed in (`error_at_offset`).
		p.origin = start
	}
	// `prefix_len` is how many bytes precede the JSON document: httpie keeps
	// that prefix verbatim and re-serialises only what follows
	// (utils.load_prefixed_json's `data_prefix`).
	prefix_len = p.pos
	value = parse_value(&p, &err)
	if err.message != "" {
		return Null{}, prefix_len, err
	}
	return value, prefix_len, {}
}

@(private)
skip_whitespace :: proc(p: ^Parser) {
	for p.pos < len(p.text) {
		switch p.text[p.pos] {
		case ' ', '\t', '\n', '\r':
			advance(p)
		case:
			return
		}
	}
}

// error_at renders Python's json.JSONDecodeError message for the position we
// are at: "<reason>: line L column C (char N)".
@(private)
error_at :: proc(p: ^Parser, reason: string) -> string {
	return error_at_offset(p, reason, 0)
}

// error_at_offset renders the same message for a position `back` bytes behind
// the parser's own. Python reports the position its *scanner* names, and that is
// not always where the port stopped: the C scanner refuses a malformed `\uXXXX`
// escape at the escape's `u` (Modules/_json.c:488 and :506 both pass `next - 1` /
// `end - 5`, the index of the `u`), two bytes behind the first digit the port has
// consumed, and a backslash escape it does not know at the *backslash*
// (`Modules/_json.c:479`, `end - 2`), two bytes behind the escaped character the
// port has consumed.
//
// The position is counted again from the parser's `origin` rather than derived
// by subtracting `back` from a running column, because the bytes handed back can
// contain a newline — `\<LF>` is refused by the escape switch that uses
// `back = 2` — and a subtraction cannot undo a line break.
@(private)
error_at_offset :: proc(p: ^Parser, reason: string, back: int) -> string {
	return error_at_target(p, reason, p.pos - back)
}

// error_at_target renders the same message for an absolute *byte* index into
// the parser's text, which is what the scanner's own positions are counted
// from: the escape's `u` and the unterminated string's opening quote are both
// byte indices in `p.text`, and `position_of` turns one into the line, the
// column and the `char` offset the reference prints.
@(private)
error_at_target :: proc(p: ^Parser, reason: string, target: int) -> string {
	line, col, char := position_of(p, target)
	return fmt.aprintf(
		"%s: line %d column %d (char %d)",
		reason,
		line,
		col,
		char,
		allocator = p.allocator,
	)
}

// position_of counts the 1-based line and column of the *byte* index `target`,
// and the character offset Python prints as `char`, from the parser's `origin`.
//
// All three are counted in **characters**, which is how `json.JSONDecodeError`
// counts them (json/decoder.py:__init__):
//
//	lineno = doc.count('\n', 0, pos) + 1
//	colno = pos - doc.rfind('\n', 0, pos)
//
// where `doc` is a `str` and `pos` is the index CPython's C scanner passed
// (`Modules/_json.c`'s `raise_errmsg(msg, pystr, end)` — `end` is an index into
// the `PyUnicode`, not into its UTF-8 encoding). A multi-byte character is
// therefore **one** position and not the two to four bytes its encoding takes:
// `a:="é\uZZZZ"` is `char 3` (t_91f3546a — the port counted bytes and reported
// `char 4`). The step is the scanner's own (`parse_string` copies a whole UTF-8
// sequence at a time; a byte that starts no sequence is one position), so the
// `char` counted here is the index the scanner itself is standing at.
@(private)
position_of :: proc(p: ^Parser, target: int) -> (line: int, col: int, char: int) {
	line, col, char = 1, 1, 0
	for i := p.origin; i < target; i += char_span(p.text, i) {
		if p.text[i] == '\n' {
			line += 1
			col = 1
		} else {
			col += 1
		}
		char += 1
	}
	return
}

// char_span is how many bytes the character at `index` occupies: the step
// `parse_string` copies with, and the step `position_of` counts with — a whole
// UTF-8 sequence, or one byte where none starts (`utf8.decode_rune`'s size 0,
// the lone continuation byte the str layer keeps one position wide too).
@(private)
char_span :: proc(text: string, index: int) -> int {
	_, size := utf8.decode_rune(text[index:])
	return max(size, 1)
}

@(private)
parse_value :: proc(p: ^Parser, err: ^JSON_Error) -> Value {
	if p.pos >= len(p.text) {
		err^ = JSON_Error{allocator = p.allocator, message = error_at(p, "Expecting value")}
		return Null{}
	}
	switch c := p.text[p.pos]; c {
	case 'n':
		if !expect_literal(p, "null") {
			err^ = JSON_Error{allocator = p.allocator, message = error_at(p, "Expecting value")}
			return Null{}
		}
		return Null{}
	case 't':
		if !expect_literal(p, "true") {
			err^ = JSON_Error{allocator = p.allocator, message = error_at(p, "Expecting value")}
			return Null{}
		}
		return true
	case 'f':
		if !expect_literal(p, "false") {
			err^ = JSON_Error{allocator = p.allocator, message = error_at(p, "Expecting value")}
			return Null{}
		}
		return false
	case '"':
		return parse_string(p, err)
	case '[':
		return parse_array(p, err)
	case '{':
		return parse_object(p, err)
	case '-', '0' ..= '9':
		return parse_number(p, err)
	}
	err^ = JSON_Error{allocator = p.allocator, message = error_at(p, "Expecting value")}
	return Null{}
}

@(private)
expect_literal :: proc(p: ^Parser, literal: string) -> bool {
	if !strings.has_prefix(p.text[p.pos:], literal) {
		return false
	}
	advance(p, len(literal))
	return true
}

@(private)
parse_string :: proc(p: ^Parser, err: ^JSON_Error) -> Value {
	start := p.pos
	advance(p) // opening quote
	builder := strings.builder_make(p.allocator)
	// The lone surrogates this string carries that have no byte of their own
	// (see Surrogate_Mark). Empty for every string an argv value can hold, so
	// the value is a plain `string` unless one of these was collected.
	marks := make([dynamic]Surrogate_Mark, p.allocator)
	// The successful path hands the builder's buffer to the caller; every other
	// path releases it here, and the marks with it.
	taken := false
	defer if !taken {
		strings.builder_destroy(&builder)
		delete(marks)
	}

	for {
		if p.pos >= len(p.text) {
			// The reference words this one with the *string's* position,
			// and not with the position the scan stopped at: the C
			// scanner passes `begin` — the index of the opening quote
			// (`Modules/_json.c:444` and `:460`, `raise_errmsg(
			// "Unterminated string starting at", pystr, begin)` with
			// `begin = end - 1`) — and `JSONDecodeError` counts the line,
			// the column and the `char` offset from that same index. The
			// port used to print its own `p.line`/`p.col` here (`a:="abc`
			// was `column 5 (char 0)` where the reference says `column 1
			// (char 0)`), so the position now comes from `start` like the
			// `char` always did: measured shape by shape in
			// build/unterminated-string-shapes.txt, and a string that
			// starts on a later line differs in the line number too
			// (`a:=[<LF>"abc` is `line 2 column 1 (char 2)`). All three
			// are counted in characters, like every other position
			// (`position_of`) — a string behind a multi-byte character
			// is one position further along, not two.
			err^ = JSON_Error {
				allocator = p.allocator,
				message   = error_at_target(p, "Unterminated string starting at", start),
			}
			return Null{}
		}
		c := p.text[p.pos]
		switch c {
		case '"':
			advance(p)
			taken = true
			text := strings.to_string(builder)
			if len(marks) == 0 {
				delete(marks)
				return text
			}
			return Surrogate_String{text = text, marks = marks[:]}
		case '\\':
			advance(p)
			if p.pos >= len(p.text) {
				continue
			}
			escape := p.text[p.pos]
			advance(p)
			switch escape {
			case '"':
				strings.write_byte(&builder, '"')
			case '\\':
				strings.write_byte(&builder, '\\')
			case '/':
				strings.write_byte(&builder, '/')
			case 'b':
				strings.write_byte(&builder, 8)
			case 'f':
				strings.write_byte(&builder, 12)
			case 'n':
				strings.write_byte(&builder, '\n')
			case 'r':
				strings.write_byte(&builder, '\r')
			case 't':
				strings.write_byte(&builder, '\t')
			case 'u':
				code: u32
				if !parse_hex4(p, &code) {
					// The escape is not four hex digits, which CPython's
					// scanner refuses outright (json.loads' "Invalid \uXXXX
					// escape" — see parse_hex4). httpie prints the refusal as a
					// usage error, verbatim, and the position is the *escape's*
					// `u`, not the digit the scan stopped on: `error_at_offset`
					// walks back the two bytes the caller consumed (`\` and
					// `u`), which is what the reference reports (`char 2` for
					// `a:="\uZZZZ"`, `char 8` for `a:="\ud800\uZZZZ"` — the
					// *second* escape, whose digits are the ones that failed).
					err^ = JSON_Error {
						allocator = p.allocator,
						message   = error_at_offset(p, "Invalid \\uXXXX escape", 1),
					}
					return Null{}
				}
				switch {
				case code >= 0xd800 && code <= 0xdbff:
					// A high surrogate. json.loads looks ahead for a
					// `\uDC00-\uDFFF` escape and combines the two into one
					// astral character; with anything else after it the high
					// surrogate is a character of its own (py_scanstring's
					// `0xd800 <= code <= 0xdbff and s[end:end+2] == '\\u'`
					// plus the `0xdc00 <= code2 <= 0xdfff` test).
					if low, found := low_surrogate_escape_at(p); found {
						advance(p, ESCAPE_U_LEN)
						combined := 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
						strings.write_rune(&builder, rune(combined))
					} else {
						write_lone_surrogate(&builder, &marks, code)
					}
				case code >= 0xdc00 && code <= 0xdfff:
					// A low surrogate that combines with nothing: it is a
					// character of its own.
					write_lone_surrogate(&builder, &marks, code)
				case:
					strings.write_rune(&builder, rune(code))
				}
			case:
				// A backslash escape that is neither one of the table escapes
				// above nor a `\u`: CPython's C scanner refuses it at the
				// **backslash** (`Modules/_json.c:479`, `end - 2` — the two
				// bytes the scan here has consumed, `\` and the character
				// behind it), and httpie prints that refusal verbatim as a
				// usage error. The pure-Python scanner words the same thing
				// differently (`Invalid \escape: 'q'`, at the escaped
				// character), and it is not the reference: `json.loads` uses
				// the C scanner.
				err^ = JSON_Error {
					allocator = p.allocator,
					message   = error_at_offset(p, "Invalid \\escape", 2),
				}
				return Null{}
			}
		case:
			// Copy a whole UTF-8 rune at a time.
			r, size := utf8.decode_rune(p.text[p.pos:])
			if size == 0 {
				size = 1
			}
			if r < 0x20 {
				// A **raw** control character in the string's text. CPython's
				// C scanner refuses it with the wording `Invalid control
				// character at` (`Modules/_json.c:425` — the trailing `at` is
				// that message's own, and the port dropped it, t_4dca8209),
				// at the index of the character itself (`raise_errmsg(msg,
				// pystr, next)`, `next` being where the scan is), which is
				// where this parser stands: `error_at`, not
				// `error_at_offset`. The pure-Python fallback words the same
				// refusal differently (`Invalid control character '\x01' at`,
				// `json/decoder.py:98`, with the character's repr in the
				// middle) and is not the reference: `json.loads` uses the C
				// scanner.
				//
				// The escape road is not this rule: `\u0001` and the table
				// escapes spell a control character in legal JSON, and only a
				// byte below 0x20 that stands in the text is refused.
				err^ = JSON_Error {
					allocator = p.allocator,
					message   = error_at(p, "Invalid control character at"),
				}
				return Null{}
			}
			strings.write_string(&builder, p.text[p.pos:p.pos + size])
			advance(p, size)
		}
	}
}

// parse_hex4 decodes the four hex digits of a `\uXXXX` escape — the caller has
// consumed the backslash and the `u`, so `p` stands on the first digit — leaves
// `p` just past the fourth, and answers false in exactly the two places
// CPython's scanner refuses the escape (Modules/_json.c:scanstring_unicode,
// which is the scanner `json.loads` uses):
//
//   - `if (end >= len)` (:487): the four digits must be followed by at least one
//     more character *of the document*. A `\uXXXX` escape therefore cannot end
//     the text — `a:="\u1234` is a refused escape and not an unterminated
//     string, and `a:="\ud83d\ude00` refuses the *second* escape for the same
//     reason. The very next character makes it ordinary text again, so
//     `a:="\u1234a` (no closing quote) is the unterminated one and
//     `a:="\u1234"` parses;
//   - a character of the four that is not a hex digit (:505).
//
// Both are the caller's `Invalid \uXXXX escape`; nothing is consumed when the
// answer is false, so the `u` the message points at is still behind `p`.
@(private)
parse_hex4 :: proc(p: ^Parser, code: ^u32) -> bool {
	if p.pos + 4 >= len(p.text) {
		return false
	}
	value: u32
	for i in 0 ..< 4 {
		c := p.text[p.pos + i]
		digit: u32
		switch {
		case c >= '0' && c <= '9':
			digit = u32(c - '0')
		case c >= 'a' && c <= 'f':
			digit = u32(c - 'a') + 10
		case c >= 'A' && c <= 'F':
			digit = u32(c - 'A') + 10
		case:
			return false
		}
		value = value * 16 + digit
	}
	advance(p, 4)
	code^ = value
	return true
}

@(private)
is_digit_at :: proc(p: ^Parser) -> bool {
	return p.pos < len(p.text) && p.text[p.pos] >= '0' && p.text[p.pos] <= '9'
}

// ESCAPE_U_LEN is the length of one `\uXXXX` escape: the two introducer bytes
// and four hex digits.
@(private)
ESCAPE_U_LEN :: 6

// low_surrogate_escape_at answers the code unit of the `\uXXXX` escape at
// `p.pos` when it spells a *low* surrogate (U+DC00-U+DFFF), and leaves the
// position alone whatever the answer is. json.loads peeks for exactly this
// shape before it decides that a high surrogate combines with its neighbour
// (`s[end:end + 2] == '\\u'` then `0xdc00 <= code2 <= 0xdfff`), and the peek is
// what keeps `\ud800\u0041` — and the escapes CPython rejects as malformed —
// from being consumed here: both leave the high surrogate a character of its
// own, and the following escape is parsed by the ordinary path.
//
// The peek needs the same "one more character" margin the ordinary escape does
// (`end + 6 < len`, Modules/_json.c:511): a pair that ends the document is not
// combined either, and the second escape is then refused by the ordinary path —
// `a:="\ud83d\ude00` is `Invalid \uXXXX escape` at char 8 in the reference, not
// the astral character followed by an unterminated string.
@(private)
low_surrogate_escape_at :: proc(p: ^Parser) -> (code: u32, found: bool) {
	if p.pos + ESCAPE_U_LEN >= len(p.text) || p.text[p.pos] != '\\' || p.text[p.pos + 1] != 'u' {
		return 0, false
	}
	value: u32
	for c in p.text[p.pos + 2:p.pos + ESCAPE_U_LEN] {
		switch {
		case c >= '0' && c <= '9':
			value = value * 16 + u32(c - '0')
		case c >= 'a' && c <= 'f':
			value = value * 16 + u32(c - 'a') + 10
		case c >= 'A' && c <= 'F':
			value = value * 16 + u32(c - 'A') + 10
		case:
			return 0, false
		}
	}
	if value < 0xdc00 || value > 0xdfff {
		return 0, false
	}
	return value, true
}

// write_lone_surrogate writes one surrogate code unit that json.loads kept in
// the value: the high surrogate of a pair it could not combine, or a low
// surrogate that follows nothing.
//
// The port's str layer holds a Python str as the bytes CPython's surrogateescape
// decode made of it (src/http/python_str.odin), and that decode covers exactly
// the low surrogates U+DC80-U+DCFF — one per byte 0x80-0xff. json.loads' own
// `\udcXX` escape spells the same character, so those are written as that byte:
// the body serialiser spells the byte back as `\udcXX` (write_escaped_string),
// byte for byte, and every other site that re-encodes the string fails exactly
// where the reference's str does — `-f a:="\udcff"` is the reference's
// UnicodeEncodeError for `'\udcff'`, offset and all (docs/PARITY.md §3.4, §3.6).
//
// A surrogate outside that range has **no** byte representation: the byte space
// is already the image of the decode, so an in-band marker for it would collide
// with a byte an argv value can carry, and the collision would be silent
// (`ED A0 BD` from argv is three lone surrogates to the reference, and the body
// serialiser spells it `\udced\udca0\udcbd` — a rule the `json-body-*`
// scenarios pin). The character is therefore recorded **out of band**: a mark
// beside the bytes (see Surrogate_Mark), with one U+FFFD placeholder written in
// the string's place for it. The reference keeps such a character, json.dumps
// spells it `\udXXX` in the body and the form encoder refuses it; both halves
// are implemented on top of the mark (write_escaped_string, and
// `Lone_Surrogate` in src/http/python_str.odin).
@(private)
write_lone_surrogate :: proc(builder: ^strings.Builder, marks: ^[dynamic]Surrogate_Mark, code: u32) {
	if code >= 0xdc80 && code <= 0xdcff {
		strings.write_byte(builder, u8(code - 0xdc00))
		return
	}
	append(marks, Surrogate_Mark{offset = strings.builder_len(builder^), code = code})
	strings.write_string(builder, SURROGATE_PLACEHOLDER)
}

@(private)
parse_number :: proc(p: ^Parser, err: ^JSON_Error) -> Value {
	start := p.pos
	if p.pos < len(p.text) && p.text[p.pos] == '-' {
		advance(p)
	}
	// NOTE: `break` inside a switch only leaves the switch, so the digit runs
	// are scanned with the condition rather than a switch.
	for is_digit_at(p) {
		advance(p)
	}
	is_float := false
	if p.pos < len(p.text) && p.text[p.pos] == '.' {
		is_float = true
		advance(p)
		for is_digit_at(p) {
			advance(p)
		}
	}
	if p.pos < len(p.text) {
		switch p.text[p.pos] {
		case 'e', 'E':
			is_float = true
			advance(p)
			if p.pos < len(p.text) && (p.text[p.pos] == '+' || p.text[p.pos] == '-') {
				advance(p)
			}
			for is_digit_at(p) {
				advance(p)
			}
		}
	}
	raw := p.text[start:p.pos]
	if raw == "" || raw == "-" {
		err^ = JSON_Error{allocator = p.allocator, message = error_at(p, "Expecting value")}
		return Null{}
	}
	if !is_float {
		if int_value, ok := strconv.parse_i64(raw); ok {
			return int_value
		}
	}
	if float_value, ok := strconv.parse_f64(raw); ok {
		return float_value
	}
	err^ = JSON_Error{allocator = p.allocator, message = error_at(p, "Expecting value")}
	return Null{}
}

@(private)
parse_array :: proc(p: ^Parser, err: ^JSON_Error) -> Value {
	advance(p) // '['
	items := make([dynamic]Value, p.allocator)
	skip_whitespace(p)
	if p.pos < len(p.text) && p.text[p.pos] == ']' {
		advance(p)
		return items[:]
	}
	for {
		skip_whitespace(p)
		if p.pos >= len(p.text) {
			delete(items)
			err^ = JSON_Error{allocator = p.allocator, message = error_at(p, "Expecting value")}
			return Null{}
		}
		item := parse_value(p, err)
		if err.message != "" {
			for i in 0 ..< len(items) {
				value_destroy(&items[i], p.allocator)
			}
			delete(items)
			return Null{}
		}
		append(&items, item)
		skip_whitespace(p)
		if p.pos >= len(p.text) {
			for i in 0 ..< len(items) {
				value_destroy(&items[i], p.allocator)
			}
			delete(items)
			err^ = JSON_Error {
				allocator = p.allocator,
				message   = error_at(p, "Expecting ',' delimiter"),
			}
			return Null{}
		}
		switch p.text[p.pos] {
		case ',':
			advance(p)
		case ']':
			advance(p)
			return items[:]
		case:
			for i in 0 ..< len(items) {
				value_destroy(&items[i], p.allocator)
			}
			delete(items)
			err^ = JSON_Error {
				allocator = p.allocator,
				message   = error_at(p, "Expecting ',' delimiter"),
			}
			return Null{}
		}
	}
}

// free_members releases an object literal that will not be returned: its keys
// and values are owned, and every error return of parse_object used to drop
// them (so a malformed `:=` value leaked everything parsed up to the error).
free_members :: proc(members: ^[dynamic]Member, allocator: mem.Allocator) {
	for i in 0 ..< len(members) {
		delete(members[i].key, allocator)
		delete(members[i].key_marks, allocator)
		value_destroy(&members[i].value, allocator)
	}
	delete(members^)
	members^ = nil
}

@(private)
parse_object :: proc(p: ^Parser, err: ^JSON_Error) -> Value {
	advance(p) // '{'
	members := make([dynamic]Member, p.allocator)
	// Until the closing brace is seen the half-built object belongs to the
	// error path; `ok` hands it to the caller.
	ok := false
	defer if !ok {
		free_members(&members, p.allocator)
	}
	skip_whitespace(p)
	if p.pos < len(p.text) && p.text[p.pos] == '}' {
		advance(p)
		ok = true
		return Object{members = members[:]}
	}
	for {
		skip_whitespace(p)
		if p.pos >= len(p.text) {
			err^ = JSON_Error {
				allocator = p.allocator,
				message   = error_at(p, "Expecting property name enclosed in double quotes"),
			}
			return Null{}
		}
		if p.text[p.pos] != '"' {
			err^ = JSON_Error {
				allocator = p.allocator,
				message   = error_at(p, "Expecting property name enclosed in double quotes"),
			}
			return Null{}
		}
		key_value := parse_string(p, err)
		if err.message != "" {
			return Null{}
		}
		// A key is a string like any other: `{"\ud800": 1}` carries the same
		// out-of-band character, and the member keeps it beside its bytes.
		key, key_marks := string_parts(key_value)
		skip_whitespace(p)
		if p.pos >= len(p.text) || p.text[p.pos] != ':' {
			delete(key, p.allocator)
			delete(key_marks, p.allocator)
			err^ = JSON_Error {
				allocator = p.allocator,
				message   = error_at(p, "Expecting ':' delimiter"),
			}
			return Null{}
		}
		advance(p)
		skip_whitespace(p)
		value := parse_value(p, err)
		if err.message != "" {
			delete(key, p.allocator)
			delete(key_marks, p.allocator)
			return Null{}
		}
		append(&members, Member{key = key, key_marks = key_marks, value = value})
		skip_whitespace(p)
		if p.pos >= len(p.text) {
			err^ = JSON_Error {
				allocator = p.allocator,
				message   = error_at(p, "Expecting ',' delimiter"),
			}
			return Null{}
		}
		switch p.text[p.pos] {
		case ',':
			advance(p)
		case '}':
			advance(p)
			ok = true
			return Object{members = members[:]}
		case:
			err^ = JSON_Error {
				allocator = p.allocator,
				message   = error_at(p, "Expecting ',' delimiter"),
			}
			return Null{}
		}
	}
}

// value_to_form_string renders a JSON primitive the way httpie's
// `str(value)` does when a `:=` item is used with --form/--multipart: strings
// stay as they are, numbers print as Python prints them, and booleans print as
// `True`/`False` (Python's str, not json's `true`).
//
// A string that carries an out-of-band surrogate is a string too, and the
// reference's `str(value)` is the value itself — so the Surrogate_String stays
// exactly as it is and the *form encoder* is where the character is refused
// (src/http/python_str.odin's Lone_Surrogate, which is also what
// `-f a:="\udcff"` already goes through for a byte that has no utf-8 encoding).
value_to_form_string :: proc(v: Value, allocator: mem.Allocator) -> Value {
	switch value in v {
	case string, Surrogate_String:
		return value
	case i64:
		return fmt.aprintf("%d", value, allocator = allocator)
	case f64:
		if value == f64(i64(value)) && value < 1e16 && value > -1e16 {
			return fmt.aprintf("%d.0", i64(value), allocator = allocator)
		}
		return fmt.aprintf("%v", value, allocator = allocator)
	case bool:
		return strings.clone(value ? "True" : "False", allocator) or_else ""
	case Null, []Value, Object:
		// Complex values are rejected by the caller before it gets here.
		return v
	}
	return v
}

// ---------------------------------------------------------------------------
// Serialisation
// ---------------------------------------------------------------------------

// dump writes `v` the way json.dumps(value, indent=opt.indent,
// sort_keys=opt.sort_keys, ensure_ascii=opt.ensure_ascii) writes it.
dump :: proc(w: io.Writer, v: ^Value, opt: Dump_Options) -> io.Error {
	write_value(w, v, opt, 0) or_return
	return .None
}

// dump_to_string is dump into a fresh string from `allocator`.
dump_to_string :: proc(v: ^Value, opt: Dump_Options, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	writer := strings.to_writer(&builder)
	write_value(writer, v, opt, 0)
	return strings.to_string(builder)
}

@(private)
write_indent :: proc(w: io.Writer, opt: Dump_Options, depth: int) -> io.Error {
	if opt.indent < 0 {
		return .None
	}
	io.write_byte(w, '\n') or_return
	for _ in 0 ..< opt.indent * depth {
		io.write_byte(w, opt.indent_tabs ? '	' : ' ') or_return
	}
	return .None
}

// member_rank is the position `index` takes in a stable sort of the object's
// keys: the number of members that sort strictly before it, plus the number of
// equal keys that appear earlier (which is how Python breaks ties). Computing
// ranks instead of sorting an index array keeps this allocation-free.
//
// `pairs` is what the object renders — `object_pairs`, i.e. a frozen `:=`
// object's parse-time pairs — because `json.dumps(sort_keys=True)` sorts the
// list `items()` returns, which for a frozen object is the parsed one.
@(private)
member_rank :: proc(pairs: []Member, index: int) -> int {
	rank := 0
	for other in 0 ..< len(pairs) {
		if other == index {
			continue
		}
		key := pairs[index].key
		other_key := pairs[other].key
		other_marks := pairs[other].key_marks
		marks := pairs[index].key_marks
		if key_less(other_key, other_marks, key, marks) ||
		   (key_equal(other_key, other_marks, key, marks) && other < index) {
			rank += 1
		}
	}
	return rank
}

// key_less is Python's `a < b` for two object keys.
//
// For two keys the port holds as plain bytes this is the byte comparison the
// serialiser always used, and byte order *is* code point order for well-formed
// UTF-8 — a string that carries an out-of-band surrogate is the only case the
// bytes cannot decide, because its U+FFFD placeholder stands on the same three
// bytes as a real U+FFFD while Python compares the code units themselves
// (`'\ud800'` sorts before `'\ufffd'`, `'\ud800'` before `'\ud801'`). Both
// sides are then walked as the characters of the reference's str: a mark is its
// code unit, a byte that is not a well-formed sequence is the lone surrogate
// its surrogateescape decode made of it.
@(private)
key_less :: proc(a_text: string, a_marks: []Surrogate_Mark, b_text: string, b_marks: []Surrogate_Mark) -> bool {
	if len(a_marks) == 0 && len(b_marks) == 0 {
		return a_text < b_text
	}
	a, b := 0, 0
	for a < len(a_text) && b < len(b_text) {
		a_code, a_width := key_char_at(a_text, a_marks, a)
		b_code, b_width := key_char_at(b_text, b_marks, b)
		if a_code != b_code {
			return a_code < b_code
		}
		a += a_width
		b += b_width
	}
	// The shorter of two strings that agree up to the end of one of them sorts
	// first; equal lengths are equal, not less.
	return a >= len(a_text) && b < len(b_text)
}

// key_equal is Python's `a == b` for two object keys: the same characters, so
// the same bytes *and* the same out-of-band surrogates (a key whose placeholder
// stands for U+D800 is not the key whose byte is a real U+FFFD).
@(private)
key_equal :: proc(a_text: string, a_marks: []Surrogate_Mark, b_text: string, b_marks: []Surrogate_Mark) -> bool {
	if a_text != b_text || len(a_marks) != len(b_marks) {
		return false
	}
	for mark, i in a_marks {
		if mark.offset != b_marks[i].offset || mark.code != b_marks[i].code {
			return false
		}
	}
	return true
}

// key_char_at is one character of a key: its code unit and its width in bytes.
@(private)
key_char_at :: proc(text: string, marks: []Surrogate_Mark, index: int) -> (code: u32, width: int) {
	for mark in marks {
		if mark.offset == index {
			return mark.code, SURROGATE_PLACEHOLDER_LEN
		}
	}
	r, size := utf8.decode_rune(text[index:])
	if size <= 0 {
		return 0xdc00 + u32(text[index]), 1
	}
	return u32(r), size
}

@(private)
write_value :: proc(w: io.Writer, v: ^Value, opt: Dump_Options, depth: int) -> io.Error {
	switch value in v^ {
	case Null:
		io.write_string(w, "null") or_return
	case bool:
		io.write_string(w, value ? "true" : "false") or_return
	case i64:
		_ = fmt.wprintf(w, "%d", value)
	case f64:
		write_float(w, value) or_return
	case string:
		write_escaped_string(w, value, nil, opt) or_return
	case Surrogate_String:
		write_escaped_string(w, value.text, value.marks, opt) or_return
	case []Value:
		if len(value) == 0 {
			io.write_string(w, "[]") or_return
			return .None
		}
		io.write_byte(w, '[') or_return
		for i in 0 ..< len(value) {
			if i > 0 {
				// json.dumps' item_separator is ',' with an indent and
				// ', ' without one (Python's default separators).
				io.write_string(w, opt.indent < 0 ? ", " : ",") or_return
			}
			write_indent(w, opt, depth + 1) or_return
			write_value(w, &value[i], opt, depth + 1) or_return
		}
		write_indent(w, opt, depth) or_return
		io.write_byte(w, ']') or_return
	case Object:
		// `object_pairs` is what json.dumps renders here: a frozen `:=`
		// object's parse-time pairs, an ordinary object's live members.
		pairs := object_pairs(value)
		if len(pairs) == 0 {
			io.write_string(w, "{}") or_return
			return .None
		}
		io.write_byte(w, '{') or_return
		count := len(pairs)
		emitted := 0
		for rank in 0 ..< count {
			// Without sort_keys the members are emitted in document order; with
			// it, `rank` selects the member whose key sorts into that position.
			index := rank
			if opt.sort_keys {
				for i in 0 ..< count {
					if member_rank(pairs, i) == rank {
						index = i
						break
					}
				}
			}
			if emitted > 0 {
				io.write_string(w, opt.indent < 0 ? ", " : ",") or_return
			}
			emitted += 1
			write_indent(w, opt, depth + 1) or_return
			write_escaped_string(w, pairs[index].key, pairs[index].key_marks, opt) or_return
			io.write_string(w, ": ") or_return
			write_value(w, &pairs[index].value, opt, depth + 1) or_return
		}
		write_indent(w, opt, depth) or_return
		io.write_byte(w, '}') or_return
	}
	return .None
}

@(private)
write_float :: proc(w: io.Writer, value: f64) -> io.Error {
	// Python writes floats with repr(); Odin's %v is also shortest-round-trip.
	// The two differ only for values repr() renders in exponent form, which
	// httpie's own output path never produces for the captures in this repo.
	if value == f64(int(value)) && value < 1e16 && value > -1e16 {
		_ = fmt.wprintf(w, "%d.0", int(value))
		return .None
	}
	_ = fmt.wprintf(w, "%v", value)
	return .None
}

// write_escaped_string writes one JSON string, quotes included, with the
// escaping of the dump it belongs to.
//
// Both spellings are json.dumps':
//
//   - every byte below 0x20 gets the short escape where there is one (`\n`,
//     `\r`, `	`, `\b`, `\f`) and `\u00XX` otherwise — with or without
//     ensure_ascii, both codecs do this;
//   - with `ensure_ascii` (the request body's options) everything outside
//     `' '..'~'` becomes `\uXXXX`: a code point above the BMP its surrogate
//     pair, and a byte that is not valid UTF-8 — which the reference's str
//     holds as the lone surrogate its argv decode made of it — the `\udcXX`
//     of that lone surrogate. The range is `' '..'~'`, so DEL (0x7f) is
//     escaped as `\u007f`; anything at or above it is escaped too.
//   - without `ensure_ascii` (the response formatter's options) a rune above
//     0x20 is copied through as its UTF-8 bytes.
//
// `marks` are the out-of-band surrogates the string carries (Surrogate_Mark),
// which its bytes cannot spell: each one sits on its U+FFFD placeholder, and
// which of the three spellings its slot gets is the dump's own business —
// `printed` writes `?` (the stream that encodes the printed body cannot encode
// the character), the ensure_ascii dump writes `\udXXX` (what json.dumps spells
// for it in a request body), and everything else copies the placeholder, which
// is what a reader that does not know about the marks must keep seeing. Nothing
// else in the string moves.
@(private)
write_escaped_string :: proc(w: io.Writer, value: string, marks: []Surrogate_Mark, opt: Dump_Options) -> io.Error {
	mark := 0
	io.write_byte(w, '"') or_return
	for i := 0; i < len(value); {
		if mark < len(marks) && marks[mark].offset == i {
			switch {
			case opt.printed:
				// output/streams.py:225 encodes this text with
				// `errors='replace'` (encoding.py:44-50), one '?' per
				// character the encoding cannot represent.
				io.write_byte(w, '?') or_return
			case opt.ensure_ascii:
				write_u16_escape(w, u16(marks[mark].code)) or_return
			case:
				io.write_string(w, SURROGATE_PLACEHOLDER) or_return
			}
			mark += 1
			i += SURROGATE_PLACEHOLDER_LEN
			continue
		}
		c := value[i]
		switch c {
		case '"':
			io.write_string(w, "\\\"") or_return
			i += 1
		case '\\':
			io.write_string(w, "\\\\") or_return
			i += 1
		case '\n':
			io.write_string(w, "\\n") or_return
			i += 1
		case '\r':
			io.write_string(w, "\\r") or_return
			i += 1
		case '	':
			io.write_string(w, "\\t") or_return
			i += 1
		case 8:
			io.write_string(w, "\\b") or_return
			i += 1
		case 12:
			io.write_string(w, "\\f") or_return
			i += 1
		case:
			switch {
			case c < 0x20:
				_ = fmt.wprintf(w, "\\u%04x", uint(c))
				i += 1
			case opt.ensure_ascii && c >= 0x7f:
				codepoint, size := decode_utf8_strict(value[i:])
				if size == 0 {
					// Not valid UTF-8: escape the single byte as the lone
					// surrogate Python's surrogateescape made of it, so the
					// escape is the one json.dumps writes for it.
					write_u16_escape(w, u16(0xdc00) | u16(c)) or_return
					i += 1
				} else {
					write_codepoint_escape(w, codepoint) or_return
					i += size
				}
			case:
				// Copy the whole UTF-8 rune; non-ASCII stays literal because
				// this dump was asked for ensure_ascii=False.
				_, size := utf8.decode_rune(value[i:])
				if size == 0 {
					size = 1
				}
				io.write_string(w, value[i:i + size]) or_return
				i += size
			}
		}
	}
	io.write_byte(w, '"') or_return
	return .None
}

// write_codepoint_escape writes `\uXXXX`, or the surrogate pair json.dumps
// writes for a code point above the basic multilingual plane.
@(private)
write_codepoint_escape :: proc(w: io.Writer, codepoint: u32) -> io.Error {
	if codepoint < 0x10000 {
		return write_u16_escape(w, u16(codepoint))
	}
	adjusted := codepoint - 0x10000
	write_u16_escape(w, u16(0xd800) + u16(adjusted >> 10)) or_return
	return write_u16_escape(w, u16(0xdc00) + u16(adjusted & 0x3ff))
}

// write_u16_escape writes `\uXXXX` with four lowercase hex digits, Python's
// spelling.
@(private)
write_u16_escape :: proc(w: io.Writer, value: u16) -> io.Error {
	_ = fmt.wprintf(w, "\\u%04x", uint(value))
	return .None
}

// decode_utf8_strict decodes one code point the way CPython's utf-8 codec does,
// for the escaping above: the whole sequence has to be well-formed, so a
// truncated sequence, a stray continuation byte, an overlong encoding, a
// surrogate (U+D800-U+DFFF) — which Python's json.dumps escapes but its decoder
// never produces — and anything above U+10FFFF all report size 0 and the byte
// is then treated as the lone surrogate of the reference's str layer.
@(private)
decode_utf8_strict :: proc(s: string) -> (codepoint: u32, size: int) {
	if len(s) == 0 {
		return 0, 0
	}
	first := s[0]
	switch {
	case first < 0x80:
		return u32(first), 1
	case first & 0xe0 == 0xc0:
		if len(s) < 2 || s[1] & 0xc0 != 0x80 {
			return 0, 0
		}
		value := u32(first & 0x1f) << 6 | u32(s[1] & 0x3f)
		if value < 0x80 {
			return 0, 0 // overlong
		}
		return value, 2
	case first & 0xf0 == 0xe0:
		if len(s) < 3 || s[1] & 0xc0 != 0x80 || s[2] & 0xc0 != 0x80 {
			return 0, 0
		}
		value := u32(first & 0x0f) << 12 | u32(s[1] & 0x3f) << 6 | u32(s[2] & 0x3f)
		if value < 0x800 || (value >= 0xd800 && value <= 0xdfff) {
			return 0, 0 // overlong, or a surrogate
		}
		return value, 3
	case first & 0xf8 == 0xf0:
		if len(s) < 4 || s[1] & 0xc0 != 0x80 || s[2] & 0xc0 != 0x80 || s[3] & 0xc0 != 0x80 {
			return 0, 0
		}
		value := u32(first & 0x07) << 18 | u32(s[1] & 0x3f) << 12 |
		         u32(s[2] & 0x3f) << 6 | u32(s[3] & 0x3f)
		if value < 0x10000 || value > 0x10ffff {
			return 0, 0
		}
		return value, 4
	}
	return 0, 0
}
