// The reference's *str* layer, in bytes.
//
// CPython decodes the process's argv with the filesystem encoding and
// `surrogateescape` (PEP 383) — httpie/core.py's `decode_raw_args`, called from
// `raw_main` for every invocation. A byte that is not valid UTF-8 therefore does
// not fail there: it becomes a lone surrogate, U+DC80-U+DCFF for one byte, and
// every string httpie builds from the command line is a `str` that may carry
// one. What happens to it is then decided by each site that hands the string
// back to bytes:
//
//   - a header *value* is encoded by `finalize_headers` (client.py:203, the
//     default utf-8 codec) and the basic-auth credentials by the auth plugin
//     (plugins/builtin.py:33), so a surrogate raises `UnicodeEncodeError`;
//   - `requests` encodes the query items the same way while it prepares the URL
//     (models.py:176 `_encode_params`, called from prepare_url:550);
//   - the *rendered* head is one string encoded whole (models.py:143-160 joins
//     it, output/streams.py:53 encodes it), so a surrogate anywhere in it raises
//     with the offset in that block — and a header *name* that reaches the wire
//     is encoded by CPython's `http.client.putheader`, which insists on ascii;
//   - a header *value* that is still a `str` when `putheader` writes the line —
//     the bearer token is the one httpie has, because the auth plugin assigns it
//     after `finalize_headers` turned every other value into bytes — is encoded
//     with **latin-1**, so a character above U+00FF raises there and an
//     encodable one travels as its single latin-1 byte (`toké` → `tok\xe9`);
//   - urllib3 percent-encodes the URL's own path and query with
//     `encode("utf-8", "surrogatepass")` and one `%XX` per byte
//     (util/url.py:289-313), so the byte 0xff comes out as `%ED%B3%BF` — one
//     rule among several in that component's spelling, which is
//     `url_component_quote_into` (src/http/url.odin).
//
// The port keeps argv's bytes verbatim — the same bytes, read the way Python
// reads them — so it does not materialise a decoded copy of the command line.
// What such a string *means* is defined once, here: `str_utf8_seq_len` and the
// two checks below are the encode sites' rule, and the URL's is
// `url_component_quote_into` in src/http/url.odin. A site applies the rule of the
// reference site it mirrors; docs/PARITY.md §3.6 records the decision.
package http

import "core:fmt"
import "core:mem"
import "core:unicode/utf8"

// The wording of the exceptions these procs model. CPython's message is
// `UnicodeEncodeError: '<codec>' codec can't encode character '<repr>' in
// position <n>: <reason>`; the reason is the codec's own.
@(private)
STR_UTF8_CODEC :: "utf-8"
@(private)
STR_ASCII_CODEC :: "ascii"
@(private)
STR_LATIN1_CODEC :: "latin-1"
@(private)
STR_UTF8_REASON :: "surrogates not allowed"
@(private)
STR_ASCII_REASON :: "ordinal not in range(128)"
@(private)
STR_LATIN1_REASON :: "ordinal not in range(256)"

// The longest repr of one character: `\U0001f600`.
@(private)
STR_CHAR_REPR_MAX :: 12

// Str_Codec is the codec of the site that re-encodes a command-line string: the
// default utf-8 of Python's `str.encode()` (which requests uses for the query
// items too), the ascii CPython's `http.client.putheader` insists on for a
// header *name*, and the latin-1 it encodes a header *value* with when that
// value is still a `str` rather than bytes (Header.str_value).
Str_Codec :: enum {
	Utf8,
	Ascii,
	Latin1,
}

// Str_Encode_Error is CPython's UnicodeEncodeError for one string, as a value:
// which codec refused it, which character, and where. `position` and `end` are
// *code point* indices in the string — what Python counts, not the byte offset,
// which differs as soon as the string carries a non-ASCII character before it.
// CPython reports one character by its repr (`can't encode character '\udcff' in
// position 0`) and a longer run of consecutive ones as the range of their
// positions (`can't encode characters in position 0-2`), so `end` is
// `position` for the single case and the run's last index otherwise — and the
// repr, in a fixed buffer so the value owns nothing, is only needed for the
// single case.
//
// `failed` is the "did this happen" flag: a zero value means the string was
// encodable, which is the common case.
Str_Encode_Error :: struct {
	failed:   bool,
	codec:    string,
	reason:   string,
	position: int,
	end:      int,
	char:     [STR_CHAR_REPR_MAX]u8,
	char_len: int,
}

// str_encode_error_message renders the exception the reference prints
// (core.py's `handle_generic_error`: `f'{type(e).__name__}: {msg}'` through
// `env.log_error`). The caller owns the result.
str_encode_error_message :: proc(err: ^Str_Encode_Error, allocator: mem.Allocator) -> string {
	if err.end > err.position {
		return fmt.aprintf(
			"UnicodeEncodeError: '%s' codec can't encode characters in position %d-%d: %s",
			err.codec,
			err.position,
			err.end,
			err.reason,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"UnicodeEncodeError: '%s' codec can't encode character '%s' in position %d: %s",
		err.codec,
		err.char[:err.char_len],
		err.position,
		err.reason,
		allocator = allocator,
	)
}

// Str_Char is one decoded character of an argv string: how many bytes it takes
// and which code point it is. A byte that is not part of a well-formed sequence
// is the lone surrogate U+DC80+byte — CPython's surrogateescape decode — and no
// codec here encodes it.
@(private)
Str_Char :: struct {
	width: int,
	code:  rune,
}

// Str_Char_Rule answers whether one codec refuses a character. `entry` is the
// codec the rule reads its table from when it has one — the registry's strict
// head encoder decides a character by the inverted decode table
// (charset.charset_strict_rule) — and the three codecs of the str layer decide on
// the code point alone and take nil.
Str_Char_Rule :: #type proc(entry: ^Charset_Entry, code: rune) -> bool

// Str_Encode_Rule is one codec as the walk below needs it: which characters it
// refuses, and the codec name and reason CPython's `UnicodeEncodeError` carries
// for it. The str layer's three codecs are built by str_codec_rule; the charset
// layer builds its own for the codecs of the registry
// (charset.charset_strict_rule), where the wording is the codec's own and not the
// spelling's.
Str_Encode_Rule :: struct {
	bad:    Str_Char_Rule,
	entry:  ^Charset_Entry,
	codec:  string,
	reason: string,
}

// The str layer's three rules, on the code point alone: utf-8 has no encoding
// for a surrogate (the only character it refuses), ascii for anything at or
// above 0x80, latin-1 for anything above 0xFF.
@(private)
str_bad_utf8 :: proc(entry: ^Charset_Entry, code: rune) -> bool {
	return code >= 0xd800 && code <= 0xdfff
}

@(private)
str_bad_ascii :: proc(entry: ^Charset_Entry, code: rune) -> bool {
	return code >= 0x80
}

@(private)
str_bad_latin1 :: proc(entry: ^Charset_Entry, code: rune) -> bool {
	return code > 0xff
}

@(private)
str_codec_rule :: proc(codec: Str_Codec) -> Str_Encode_Rule {
	switch codec {
	case .Ascii:
		return {bad = str_bad_ascii, codec = STR_ASCII_CODEC, reason = STR_ASCII_REASON}
	case .Latin1:
		return {bad = str_bad_latin1, codec = STR_LATIN1_CODEC, reason = STR_LATIN1_REASON}
	case .Utf8:
	}
	return {bad = str_bad_utf8, codec = STR_UTF8_CODEC, reason = STR_UTF8_REASON}
}

@(private)
str_char_at :: proc(s: string, index: int) -> Str_Char {
	size := str_utf8_seq_len(s[index:])
	if size <= 0 {
		return {width = 1, code = rune(0xdc00) + rune(s[index])}
	}
	code, _ := utf8.decode_rune_in_string(s[index:])
	return {width = size, code = code}
}

// str_encode_failure is the check itself: it walks `s` the way CPython's decoder
// did and reports the first stretch of characters `codec` cannot encode —
// CPython's encoder hands the exception the longest run of consecutive
// unencodable characters, which is why `b'X-First:\xff\xff'` is reported as
// `characters in position 0-1` and not as the first one alone. The empty result
// means the string is encodable.
str_encode_failure :: proc(s: string, codec: Str_Codec) -> Str_Encode_Error {
	return str_encode_failure_lone(s, nil, codec)
}

// Lone_Surrogate is one character of a *data item's value* that the value's own
// bytes cannot represent: a lone surrogate a `:=` JSON text carried, which the
// reference holds as a character of its `str` (format.Surrogate_String,
// src/format/json.odin). `offset` is the byte offset in `value` of the one
// U+FFFD placeholder that stands in for it, `code` the code unit itself.
//
// It is the same pair the format package records, in the terms this check
// needs, and the two must agree: the marker travels here because a form body is
// built in *this* package, which does not import `format` (docs/ARCHITECTURE.md
// §1, the module boundaries).
Lone_Surrogate :: struct {
	offset: int,
	code:   rune,
}

// STR_LONE_PLACEHOLDER_LEN is the length in bytes of the U+FFFD placeholder a
// Lone_Surrogate's `offset` points at (format.SURROGATE_PLACEHOLDER).
@(private)
STR_LONE_PLACEHOLDER_LEN :: 3

// str_encode_failure_lone is str_encode_failure for a value that carries such
// characters. A lone surrogate is a character CPython's encoder refuses like
// any other, and it belongs to the same *run*: `a:="\udcff\ud800"` is
// `UnicodeEncodeError: 'utf-8' codec can't encode characters in position 0-1:
// surrogates not allowed` to the reference — one in-band byte and one
// out-of-band mark here, two characters there.
str_encode_failure_lone :: proc(s: string, lone: []Lone_Surrogate, codec: Str_Codec) -> Str_Encode_Error {
	return str_encode_failure_rule(s, lone, str_codec_rule(codec))
}

// str_encode_failure_rule is the walk itself, for any codec as a value: the
// first stretch of characters `rule` refuses, as the exception its own codec
// words. It is the one place the *positions* are counted (in characters of `s`,
// which is what CPython counts) and where a run of refusals collapses into the
// range CPython reports, so the two encoders of the printed text — the str
// layer's three codecs here and the registry's strict head encoder in
// charset.odin — cannot disagree about either.
str_encode_failure_rule :: proc(s: string, lone: []Lone_Surrogate, rule: Str_Encode_Rule) -> Str_Encode_Error {
	position := 0
	start := -1
	last := -1
	first: Str_Char
	next := 0
	for index := 0; index < len(s); {
		character := str_char_or_lone(s, index, lone, &next)
		if rule.bad(rule.entry, character.code) {
			if start < 0 {
				start = position
				first = character
			}
			last = position
		} else if start >= 0 {
			break
		}
		index += character.width
		position += 1
	}
	if start < 0 {
		return {}
	}
	return str_char_failure(first.code, start, last, rule.codec, rule.reason)
}

// str_char_or_lone is one character of `s` at byte `index`: the lone surrogate a
// mark records when one sits there (`next` walks the marks, which ascend), the
// decoded character otherwise. The placeholder counts as the one character the
// mark stands for, so `position` stays the code point index CPython reports.
@(private)
str_char_or_lone :: proc(s: string, index: int, lone: []Lone_Surrogate, next: ^int) -> Str_Char {
	if next^ < len(lone) && lone[next^].offset == index {
		code := lone[next^].code
		next^ += 1
		return {width = STR_LONE_PLACEHOLDER_LEN, code = code}
	}
	return str_char_at(s, index)
}

// str_char_failure builds the error for one stretch of characters: `code` is the
// first of them, `position`..`end` their code point indices, and `codec`/`reason`
// the wording the codec's own exception carries.
@(private)
str_char_failure :: proc(code: rune, position, end: int, codec, reason: string) -> Str_Encode_Error {
	failure: Str_Encode_Error
	failure.failed = true
	failure.position = position
	failure.end = end
	failure.codec = codec
	failure.reason = reason
	if end == position {
		failure.char_len = str_char_repr_into(failure.char[:], code)
	}
	return failure
}

// str_char_repr_into writes Python's `repr()` of the single character `code`,
// without the surrounding quotes, and answers its length. The ranges are
// CPython's own: latin-1 goes hexadecimal, everything below U+10000 is `\uNNNN`
// and the astral planes `\UNNNNNNNN`, all lowercase.
str_char_repr_into :: proc(dst: []u8, code: rune) -> int {
	written := 0
	write_hex :: proc(dst: []u8, written: ^int, prefix: string, value: rune, digits: int) {
		copy(dst[written^:], prefix)
		written^ += len(prefix)
		hex := "0123456789abcdef"
		for shift := (digits - 1) * 4; shift >= 0; shift -= 4 {
			dst[written^] = hex[(int(value) >> uint(shift)) & 0xf]
			written^ += 1
		}
	}
	switch {
	case code < 0x80:
		switch code {
		case 0x09:
			copy(dst, "\\t")
			return 2
		case 0x0a:
			copy(dst, "\\n")
			return 2
		case 0x0d:
			copy(dst, "\\r")
			return 2
		case 0x5c:
			copy(dst, "\\\\")
			return 2
		case 0x27:
			copy(dst, "\\'")
			return 2
		case:
			if code >= 0x20 && code < 0x7f {
				dst[0] = u8(code)
				return 1
			}
			write_hex(dst, &written, "\\x", code, 2)
		}
	case code < 0x100:
		write_hex(dst, &written, "\\x", code, 2)
	case code < 0x10000:
		write_hex(dst, &written, "\\u", code, 4)
	case:
		write_hex(dst, &written, "\\U", code, 8)
	}
	return written
}

// str_utf8_seq_len is the length of the well-formed UTF-8 sequence at the front
// of `s`, or 0 when `s` does not start one — which is also the answer for the
// sequences CPython's decoder rejects although a laxer one accepts them: an
// overlong form, an *encoded* surrogate (`ED A0 80`, CESU-8) and anything above
// U+10FFFF. `decode_utf8` answers the first and the third; the surrogate range
// is checked here.
str_utf8_seq_len :: proc(s: string) -> int {
	if len(s) == 0 {
		return 0
	}
	code, size := decode_utf8(s)
	if size <= 0 {
		return 0
	}
	if code >= 0xd800 && code <= 0xdfff {
		return 0
	}
	return size
}

// str_is_printable answers CPython's `str.isprintable()` for one code point:
// False for the Unicode `C*` (other) and `Z*` (separator) categories — the
// controls, the format characters, the separators, the unassigned code points,
// the private-use ones and the surrogate range — and True for everything else,
// the ASCII space U+0020 included.
//
// CPython's `repr()` (`Objects/unicodeobject.c`, the `unicode_repr` walk) copies
// a character only when it is printable and spells every other one `\xNN` below
// 0x100, `\uNNNN` below 0x10000 and `\UNNNNNNNN` above it, so this predicate is
// the non-ASCII half of that walk's condition (the ASCII half is repr's own
// `ch < 32 || ch == 127` test); the item grammar's `python_repr`
// (src/cli/items.odin) is where the port spells the two halves out, and
// docs/PARITY.md §3.6 is the rule.
//
// The data is PYTHON_NON_PRINTABLE_RANGES (the generated
// src/http/unicode_printable_generated.odin): the code points of the *reference
// interpreter's* Unicode database that are not printable, sorted and disjoint.
// It is that interpreter's database and not a newer one on purpose —
// `str.isprintable()` is a property of the CPython the messages are compared
// against, so a code point assigned after its Unicode version (U+1FAE8, which
// Unicode 15.0 assigned and 14.0.0 leaves unassigned) is escaped, as the
// reference escapes it.
//
// One code point can never reach it: `str_utf8_seq_len` rejects an *encoded*
// surrogate, so a `C*` code point of the `Cs` half is only ever the `\udcXX` of
// the byte that starts no sequence. The `Cs` ranges are in the table all the
// same, because they are what `str.isprintable()` answers for those code points
// and the suite checks the predicate against the whole database
// (tests/http_test.odin:test_str_is_printable_matches_the_generated_bitmap).
str_is_printable :: proc(code: rune) -> bool {
	ranges := PYTHON_NON_PRINTABLE_RANGES[:]
	lo, hi := 0, len(ranges)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		span := ranges[mid]
		if code < span[0] {
			hi = mid
		} else if code > span[1] {
			lo = mid + 1
		} else {
			return false
		}
	}
	return true
}

// str_latin1_encode_into writes `s` the way CPython's latin-1 codec would: every
// character becomes the single byte of its code point, so a character above
// U+00FF has no encoding at all (`false`, and the caller has already refused it
// through str_encode_failure/request_encode_check — the two agree, because both
// walk the string through str_char_at).
//
// This is the step that puts `Bearer toké` on the wire as `Bearer tok\xe9`: the
// `é` is one latin-1 byte, not the two utf-8 bytes the port's argv carries.
str_latin1_encode_into :: proc(buffer: ^Buffer, s: string) -> bool {
	for index := 0; index < len(s); {
		size := str_utf8_seq_len(s[index:])
		if size <= 0 {
			return false
		}
		if size == 1 {
			if !buffer_append_byte(buffer, s[index]) {
				return false
			}
			index += 1
			continue
		}
		code, _ := utf8.decode_rune_in_string(s[index:])
		if code > 0xff {
			return false
		}
		if !buffer_append_byte(buffer, u8(code)) {
			return false
		}
		index += size
	}
	return true
}

// request_encode_check is the check a site of the *request* runs before it
// re-encodes one of the request's strings. The first failure is the one the
// reference raises — it stops at the first header, query item or credential it
// cannot encode, and the exception ends the run — so a request that already
// carries one keeps it and reports it again.
request_encode_check :: proc(req: ^Request, s: string, codec: Str_Codec) -> Error {
	return request_encode_check_lone(req, s, nil, codec)
}

// request_encode_check_lone is request_encode_check for a data item's value,
// whose `str` may carry a character the value's own bytes cannot represent (a
// lone surrogate of a `:=` JSON text: Lone_Surrogate). `s` then holds the
// character's U+FFFD placeholder and `lone` says where and which it was; a
// header name, query item or credential has no such character and passes nil.
request_encode_check_lone :: proc(req: ^Request, s: string, lone: []Lone_Surrogate, codec: Str_Codec) -> Error {
	if req.encode_error.failed {
		// The reference stops at the first string it cannot encode, and that
		// exception ends the run: a later check reports the same failure.
		return .Str_Not_Encodable
	}
	failure := str_encode_failure_lone(s, lone, codec)
	if !failure.failed {
		return .None
	}
	req.encode_error = failure
	return .Str_Not_Encodable
}

// ---------------------------------------------------------------------------
// The other direction: CPython's utf-8 *decode*, and the error it raises
// ---------------------------------------------------------------------------

// The wording of the exception below. CPython's message is
// `UnicodeDecodeError: 'utf-8' codec can't decode byte <repr> in position <n>:
// <reason>` for a one-byte span and `… can't decode bytes in position <n>-<m>:
// <reason>` for a longer one.
@(private)
STR_UTF8_INVALID_START :: "invalid start byte"
@(private)
STR_UTF8_INVALID_CONTINUATION :: "invalid continuation byte"
@(private)
STR_UTF8_UNEXPECTED_END :: "unexpected end of data"

// Str_Decode_Error is CPython's UnicodeDecodeError for one byte string, as a
// value — the mirror of Str_Encode_Error above, for the site that hands a
// string *to* the utf-8 codec rather than back from it. That site is requests'
// `get_redirect_target`, which decodes the bytes urllib3 kept for a Location
// header (`to_native_string(location, "utf8")`, sessions.py:143-151), so a
// Location that is not valid UTF-8 ends the run before any hop is made
// (docs/PARITY.md §3.6, `resolve_location`'s caller).
//
// A decode error counts its position in **bytes**, where an encode error counts
// characters: the object CPython failed on is a `bytes`, not a `str`
// (Str_Encode_Error's comment has the other half). `start` is the offset of the
// first byte of the sequence that failed and `end` the offset just after the
// part of it CPython had read — the byte before a bad continuation byte, the
// whole partial sequence for one the input cuts short, one byte for a byte it
// will not open a sequence with.
Str_Decode_Error :: struct {
	failed: bool,
	byte:   u8,  // the sequence's first byte, which the message names
	start:  int, // byte offset of that byte
	end:    int, // byte offset just after the part of the sequence read
	reason: string,
}

// str_utf8_decode_error_text is the same failure as `str(e)`: the codec's own
// message, without the exception's type name. CPython's message is
// `'utf-8' codec can't decode byte <repr> in position <n>: <reason>` for a
// one-byte span and `… can't decode bytes in position <n>-<m>: <reason>` for a
// longer one; the caller owns the result.
//
// Two sites interpolate the two forms differently: `read_raw_config`
// (httpie/config.py:60-78) wraps the *value* in
// `ConfigFileError(f'invalid config file: {e} [{path}]')`, while core.py's
// `handle_generic_error` prefixes the type name
// (`f'{type(e).__name__}: {msg}'`) — str_utf8_decode_error_message below.
str_utf8_decode_error_text :: proc(err: ^Str_Decode_Error, allocator: mem.Allocator) -> string {
	if err.end - err.start == 1 {
		return fmt.aprintf(
			"'utf-8' codec can't decode byte 0x%02x in position %d: %s",
			err.byte,
			err.start,
			err.reason,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"'utf-8' codec can't decode bytes in position %d-%d: %s",
		err.start,
		err.end - 1,
		err.reason,
		allocator = allocator,
	)
}

// str_utf8_decode_error_message renders the exception the reference prints
// through core.py's `handle_generic_error` (`f'{type(e).__name__}: {msg}'`),
// which httpie's `error` writes as `http: error: …` and turns into exit 1. The
// caller owns the result.
str_utf8_decode_error_message :: proc(err: ^Str_Decode_Error, allocator: mem.Allocator) -> string {
	text := str_utf8_decode_error_text(err, allocator)
	defer delete(text, allocator)
	return fmt.aprintf("UnicodeDecodeError: %s", text, allocator = allocator)
}

// str_utf8_decode_failure is CPython's strict utf-8 decoder's refusal, as a
// value: the first sequence the bytes cannot spell. The empty result means the
// bytes are valid UTF-8, which is the common case for a Location.
//
// It is a transliteration of `unicode_decode_utf8`'s checks (Objects/
// unicodeobject.c), in its own order:
//
//   - 0x80-0xC1 (a continuation byte, or an overlong two-byte lead) and
//     0xF5-0xFF cannot open a sequence at all — `invalid start byte`;
//   - the second byte has a range of its own, which is where an overlong form,
//     an *encoded* surrogate and a code point above U+10FFFF are refused:
//     `E0` needs `A0..BF`, `ED` needs `80..9F`, `F0` needs `90..BF` and `F4`
//     needs `80..8F`, every other lead `80..BF` — `invalid continuation byte`;
//   - a byte below 0x80 that is not a continuation byte is the same reason;
//   - and a sequence the input cuts short is `unexpected end of data`.
//
// A bad byte *inside* a sequence is reported one byte short of itself (`E0 A0
// 05` is `position 0-1`), which is what CPython's `end` says for it; the reason
// is never `surrogates not allowed` here — that is the *encode* side, because a
// surrogate is a character a `str` can hold and a byte string cannot spell.
//
// The rule and the message are checked against CPython itself over 4.6 million
// byte strings by build/probe_utf8_decode_rule.py (0 mismatches).
str_utf8_decode_failure :: proc(s: string) -> Str_Decode_Error {
	index := 0
	for index < len(s) {
		byte := s[index]
		if byte < 0x80 {
			index += 1
			continue
		}
		if byte < 0xC2 || byte > 0xF4 {
			return {
				failed = true,
				byte = byte,
				start = index,
				end = index + 1,
				reason = STR_UTF8_INVALID_START,
			}
		}
		width := 2
		second_min, second_max := u8(0x80), u8(0xBF)
		switch {
		case byte < 0xE0:
		case byte < 0xF0:
			width = 3
		case:
			width = 4
		}
		switch byte {
		case 0xE0:
			second_min = 0xA0
		case 0xED:
			second_max = 0x9F
		case 0xF0:
			second_min = 0x90
		case 0xF4:
			second_max = 0x8F
		}
		available := min(width, len(s) - index)
		for offset in 1 ..< available {
			follower := s[index + offset]
			if (follower & 0xC0) != 0x80 ||
			   (offset == 1 && (follower < second_min || follower > second_max)) {
				return {
					failed = true,
					byte = byte,
					start = index,
					end = index + offset,
					reason = STR_UTF8_INVALID_CONTINUATION,
				}
			}
		}
		if available < width {
			return {
				failed = true,
				byte = byte,
				start = index,
				end = index + available,
				reason = STR_UTF8_UNEXPECTED_END,
			}
		}
		index += width
	}
	return {}
}
