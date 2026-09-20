// The codec layer of the reference's *printed* text: `smart_decode` and
// `smart_encode` (httpie/encoding.py:34-50), and the registry the name an
// encoding comes from is resolved against.
//
// `smart_decode(content, encoding)` decodes a printed message part with the
// message's charset and `smart_encode(content, encoding)` encodes what is
// written back out with the stream's *output* encoding (the terminal's for a
// terminal, the message's charset for a pipe, `UTF8` when neither;
// output/streams.py:120-131).  Both take a name and both are `errors='replace'`
// on the way through CPython's codecs — which is what makes an undecodable byte
// U+FFFD and an unencodable character `?`.
//
// The *name* is resolved the way CPython resolves one (`_PyCodec_Lookup`): the
// spelling is normalized (ASCII lower-cased; every run of characters that are
// not alphanumeric and not '.' collapses to one '_' — the rule
// `build/gen_charset_tables.py` measures against the registry), then matched
// against the Python `encodings` package's aliases and modules.  A name that
// does not resolve raises `LookupError: unknown encoding: <name>`; one that
// resolves to a codec that is not a *text* codec raises
// `LookupError: '<name>' is not a text encoding; use codecs.decode()` /
// `codecs.encode() to handle arbitrary codecs` — the two messages the reference
// prints through `handle_generic_error` (core.py:54-65), with the name as it was
// written and not as it was normalized.
//
// `charset_generated.odin` is the registry itself, read off the reference's own
// interpreter.  What this file implements of it:
//
//   - the utf-8 family (`utf_8`, and `utf_8_sig`, whose decoder strips a leading
//     BOM and whose encoder writes one), as a walk over maximal subparts;
//   - every single-byte codec, from its generated table (296 names over 74
//     codecs — "single-byte" there means the whole 256-byte decode composes out
//     of the per-byte ones, which is what makes a table of it);
//   - the *name* resolution above, in full: an unknown name and a non-text codec
//     are refused exactly as the reference refuses them.
//
// What it does not: the codecs the generated file records as `Other` — the
// multi-byte and stateful ones (`big5`/`gbk`/`shift_jis`/`euc-*`/`iso2022_*`/
// `utf_16`/`utf_32`/`utf_7`/`punycode`/`idna`/`unicode_escape` … , 117 names) —
// fall back to the utf-8 walk, and so does the one codec that resolves and then
// raises on use (`undefined`).  `idna` is the sharpest of the 117: its decoder
// refuses the `errors='replace'` the reference decodes a printed body with, so
// the reference ends the run with a `UnicodeError` where this prints the utf-8
// reading (docs/PARITY.md section 3.4 records both, with the rest).
package http

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// CHARSET_UNDEFINED is the value a generated `Single_Byte` table holds for a byte
// CPython's decoder refuses. It is deliberately not 0: byte 0x00 maps to U+0000
// in every codec here, and a decoder has to be able to tell them apart.
CHARSET_UNDEFINED :: u32(0xFFFFFFFF)

// Charset_Kind is what the port can do with a resolved codec. `Single_Byte` has
// one table per codec (shared by its aliases); `Other` is a codec the port has no
// decoder for.
Charset_Kind :: enum u8 {
	Utf8,
	Utf8_Sig,
	Single_Byte,
	Other,
}

// Charset_Strict_Class is what a codec's *strict* encoder — `str.encode` with no
// `errors=`, which is what a printed head is written with
// (output/streams.py:191-197) — refuses and what its exception names. It is
// measured off the reference interpreter by `build/gen_charset_tables.py` and
// carried per entry (`Charset_Entry.strict`), because neither half of it can be
// derived from the decode table:
//
//	.Charmap  the encoder is the table inverted, and the exception names
//	          `charmap`: `isomorphic` codecs such as `cp1252` leave a byte
//	          undefined and the *character* at that position has no byte back
//	          (`character maps to <undefined>`);
//	.Latin1   the table is latin-1's — the identity — and the exception names
//	          `latin-1` (`ordinal not in range(256)`);
//	.Ascii    the table is ascii's and the exception names `ascii`
//	          (`ordinal not in range(128)`).
//
// The three agree with the port's own encoder on *which* code points fail (the
// inverted table's misses, `build/probe_t_016baf45_encoder.py`) and differ only
// in the wording. `.None` is everything else: a codec whose strict encoder is
// not that table at all (`hz`'s four spellings, whose encoder is a stateful
// multibyte one, and `raw_unicode_escape`, which escapes instead of refusing),
// and the codecs the port has no encoder for at all (`.Other`, and the utf-8
// family, whose strict encoder the utf-8 walk is). A head written with one of
// those takes the utf-8 rule, which is the recorded gap of docs/PARITY.md
// section 3.4.
Charset_Strict_Class :: enum u8 {
	None,
	Charmap,
	Latin1,
	Ascii,
}

// Charset_Entry is one canonical codec of the registry, under every normalized
// name the registry resolves to it.
Charset_Entry :: struct {
	name:   string,
	kind:   Charset_Kind,
	// decode maps a byte to its code point for a `Single_Byte` codec;
	// CHARSET_UNDEFINED is a byte CPython's decoder refuses (the entry
	// `errors='replace'` writes U+FFFD for). The encoder is this table
	// *inverted*, last index wins, which is `codecs.charmap_build(decoding_table)`.
	decode: ^[256]u32,
	// strict is the wording class of the same codec's strict encoder; the
	// zero value is `.None` (see Charset_Strict_Class).
	strict: Charset_Strict_Class,
}

// Charset_Class is what the registry says about a spelling before anything is
// decoded or encoded with it.
Charset_Class :: enum u8 {
	Text, // resolves to a text codec
	Non_Text, // resolves, and is not a text codec (rot_13, hex, base64, ...)
	Raising, // resolves and raises on use (typeof its own codec is fixed)
	Unknown, // does not resolve at all
}

// charset_normalize is CPython's name normalization, which works on the *bytes*
// of the name: ASCII lower-cased, every other byte — a separator, and each byte
// of a character above U+007F is one — collapsed with its neighbours into a
// single `_`, a run at either end dropped. So `utf-8`, `UTF 8` and `éutf-8` all
// normalize to `utf_8` while `uétf-8` normalizes to `u_tf_8` and does not
// resolve, which is what the reference does
// (`build/probe_t_aff4fc91_nonascii_name.py`: `codecs.lookup('éutf-8')` is
// utf-8, `codecs.lookup('uétf-8')` is a LookupError). The result is owned by
// `allocator`.
charset_normalize :: proc(name: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	punctuation := false
	for index := 0; index < len(name); index += 1 {
		byte := name[index]
		lower := byte
		if byte >= 'A' && byte <= 'Z' {
			lower = byte + ('a' - 'A')
		}
		alnum := (lower >= 'a' && lower <= 'z') || (lower >= '0' && lower <= '9')
		if alnum || lower == '.' {
			if punctuation && strings.builder_len(builder) > 0 {
				strings.write_byte(&builder, '_')
			}
			strings.write_byte(&builder, lower)
			punctuation = false
		} else {
			punctuation = true
		}
	}
	return strings.to_string(builder)
}

// charset_class is the registry's answer for the spelling `name` — what
// `codecs.lookup` + `str.encode`/`bytes.decode` together decide. The three
// generated lists are sorted by the normalized name, so each is a binary search.
charset_class :: proc(name: string) -> Charset_Class {
	normalized := charset_normalize(name, context.temp_allocator)
	if _, found := charset_entry_named(normalized); found {
		return .Text
	}
	if charset_name_in(CHARSET_NON_TEXT_NAMES, normalized) {
		return .Non_Text
	}
	if charset_name_in(CHARSET_RAISING_NAMES, normalized) {
		return .Raising
	}
	return .Unknown
}

// charset_entry resolves `name` to the codec the reference would decode with.
// `entry` is nil unless the class is `Text`. An `Other` entry is a text codec the
// port has no decoder for — the caller falls back to the utf-8 rule, which is the
// recorded gap.
charset_entry :: proc(name: string) -> (entry: ^Charset_Entry, class: Charset_Class) {
	normalized := charset_normalize(name, context.temp_allocator)
	if found, ok := charset_entry_named(normalized); ok {
		return found, .Text
	}
	return nil, charset_class(name)
}

@(private)
charset_entry_named :: proc(normalized: string) -> (entry: ^Charset_Entry, found: bool) {
	low, high := 0, len(CHARSET_ENTRIES)
	for low < high {
		middle := (low + high) / 2
		switch strings.compare(CHARSET_ENTRIES[middle].name, normalized) {
		case -1:
			low = middle + 1
		case 1:
			high = middle
		case:
			return &CHARSET_ENTRIES[middle], true
		}
	}
	return nil, false
}

@(private)
charset_name_in :: proc(names: []string, normalized: string) -> bool {
	low, high := 0, len(names)
	for low < high {
		middle := (low + high) / 2
		switch strings.compare(names[middle], normalized) {
		case -1:
			low = middle + 1
		case 1:
			high = middle
		case:
			return true
		}
	}
	return false
}

// charset_name_is_text is httpie's own test for `--response-charset`
// (`''.encode(encoding)`, cli/argtypes.py:262-268).
charset_name_is_text :: proc(name: string) -> bool {
	return charset_class(name) == .Text
}

// charset_name_raises_codec is the one class argparse reports differently: a name
// that resolves to a codec whose own use raises (a `UnicodeError`, which is a
// `ValueError`) is not `LookupError`-refused, so `type=` propagates it and
// argparse prints its generic wording.
charset_name_raises_codec :: proc(name: string) -> bool {
	return charset_class(name) == .Raising
}

// CHARSET_REPLACEMENT is U+FFFD, EF BF BD: what a decoding `errors='replace'`
// writes where CPython's decoder refuses.
CHARSET_REPLACEMENT :: "\xef\xbf\xbd"

// charset_decode_utf8 is `content.decode('utf-8', 'replace')`: one U+FFFD per
// ill-formed **maximal subpart**, CPython's own unit (`E0 A0 05` is one, a
// sequence the input cuts short is one, an encoded surrogate is three, a byte
// that cannot open a sequence at all is one each). `str_utf8_seq_len` is the
// well-formedness the walk is defined by and `str_utf8_decode_failure` the span
// of the refusing read — the two procs the reference's utf-8 codec was checked
// against directly (build/probe_printed_body_decode.py). The result is `content`
// itself when nothing had to be replaced; otherwise the caller owns it.
charset_decode_utf8 :: proc(content: string, allocator: mem.Allocator) -> (string, bool) {
	index := 0
	for index < len(content) {
		size := str_utf8_seq_len(content[index:])
		if size <= 0 {
			break
		}
		index += size
	}
	if index == len(content) {
		return content, false
	}
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, content[:index])
	for index < len(content) {
		size := str_utf8_seq_len(content[index:])
		if size > 0 {
			strings.write_string(&builder, content[index:index + size])
			index += size
			continue
		}
		failure := str_utf8_decode_failure(content[index:])
		span := failure.end - failure.start
		if span <= 0 {
			// Unreachable for a byte the walk above refused, and a step of one
			// keeps the loop a walk even so.
			span = 1
		}
		strings.write_string(&builder, CHARSET_REPLACEMENT)
		index += span
	}
	return strings.to_string(builder), true
}

// charset_decode is `content.decode(encoding, 'replace')` for a resolved codec.
// A `Single_Byte` codec refuses undefined bytes one at a time, so it writes one
// U+FFFD per byte, where the utf-8 walk writes one per maximal subpart.
charset_decode :: proc(
	entry: ^Charset_Entry,
	content: string,
	allocator: mem.Allocator,
) -> (string, bool) {
	switch entry.kind {
	case .Single_Byte:
		table := entry.decode
		builder := strings.builder_make(allocator)
		for byte in transmute([]u8)content {
			code := table[byte]
			if code == CHARSET_UNDEFINED {
				strings.write_string(&builder, CHARSET_REPLACEMENT)
				continue
			}
			strings.write_rune(&builder, rune(code))
		}
		return strings.to_string(builder), true
	case .Utf8_Sig:
		// The decoder drops one leading BOM; its encoder writes one (below).
		body := content
		if strings.has_prefix(body, "\xef\xbb\xbf") {
			body = body[3:]
		}
		return charset_decode_utf8(body, allocator)
	case .Utf8:
		return charset_decode_utf8(content, allocator)
	case .Other:
		// No decoder for this codec: the utf-8 rule is the recorded gap, not a
		// claim (docs/PARITY.md section 3.4).
		return charset_decode_utf8(content, allocator)
	}
	return content, false
}

// charset_encode_utf8 is `content.encode(utf-8, 'replace')` as the printed text
// can need it: every well-formed sequence is copied byte for byte, and a byte
// that is not part of one is one character CPython's str holds as a lone
// surrogate (the surrogateescape decode of src/http/python_str.odin), which this
// codec refuses — one `?` per such byte. The result is `text` itself when
// nothing had to be replaced.
charset_encode_utf8 :: proc(text: string, allocator: mem.Allocator) -> (string, bool) {
	index := 0
	for index < len(text) {
		size := str_utf8_seq_len(text[index:])
		if size <= 0 {
			break
		}
		index += size
	}
	if index == len(text) {
		return text, false
	}
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, text[:index])
	for index < len(text) {
		size := str_utf8_seq_len(text[index:])
		if size <= 0 {
			strings.write_byte(&builder, '?')
			index += 1
			continue
		}
		strings.write_string(&builder, text[index:index + size])
		index += size
	}
	return strings.to_string(builder), true
}

// charset_encode is `content.encode(encoding, 'replace')` for a resolved codec.
// A character the codec has no byte for is `?` (CPython's encoder replacement,
// where its decoder writes U+FFFD), and so is an ill-formed byte — a lone
// surrogate to the reference, which no codec here encodes either.
charset_encode :: proc(
	entry: ^Charset_Entry,
	text: string,
	allocator: mem.Allocator,
) -> (string, bool) {
	switch entry.kind {
	case .Single_Byte:
		table := entry.decode
		builder := strings.builder_make(allocator)
		index := 0
		for index < len(text) {
			size := str_utf8_seq_len(text[index:])
			if size <= 0 {
				strings.write_byte(&builder, '?')
				index += 1
				continue
			}
			code, _ := utf8.decode_rune_in_string(text[index:])
			byte, found := charset_byte_for(table, code)
			if !found {
				strings.write_byte(&builder, '?')
			} else {
				strings.write_byte(&builder, byte)
			}
			index += size
		}
		return strings.to_string(builder), true
	case .Utf8_Sig:
		encoded, owned := charset_encode_utf8(text, allocator)
		defer if owned {
			delete(encoded, allocator)
		}
		if len(encoded) == 0 {
			// `''.encode('utf-8-sig')` is empty: the BOM opens a body, it does
			// not stand alone.
			return encoded, false
		}
		builder := strings.builder_make(allocator)
		strings.write_string(&builder, "\xef\xbb\xbf")
		strings.write_string(&builder, encoded)
		return strings.to_string(builder), true
	case .Utf8:
		return charset_encode_utf8(text, allocator)
	case .Other:
		// No encoder for this codec: the utf-8 rule is the recorded gap.
		return charset_encode_utf8(text, allocator)
	}
	return text, false
}

// charset_byte_for is the inverted table: the last byte index whose entry is
// `code`, which is what `codecs.charmap_build`'s dict comprehension leaves.
@(private)
charset_byte_for :: proc(table: ^[256]u32, code: rune) -> (byte: u8, found: bool) {
	for index := 255; index >= 0; index -= 1 {
		if table[index] == u32(code) {
			return u8(index), true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// The strict encoder of the printed *head*
// ---------------------------------------------------------------------------

// The wording each strict class carries, as the reference's own exception words
// it: the codec name is the codec's (`charmap` for everything built through
// `codecs.charmap_build`, `latin-1` and `ascii` for the C codecs of those two
// tables) and not the spelling the message arrived under.
@(private)
CHARSET_STRICT_CHARMAP_NAME :: "charmap"
@(private)
CHARSET_STRICT_CHARMAP_REASON :: "character maps to <undefined>"
@(private)
CHARSET_STRICT_LATIN1_NAME :: "latin-1"
@(private)
CHARSET_STRICT_LATIN1_REASON :: "ordinal not in range(256)"
@(private)
CHARSET_STRICT_ASCII_NAME :: "ascii"
@(private)
CHARSET_STRICT_ASCII_REASON :: "ordinal not in range(128)"

// charset_strict_codec is the codec a *head* is written with: the registry entry
// for `name`, or nil for the utf-8 rule — no name at all, a codec the port has no
// encoder for (`.Other`), or a single-byte codec whose strict encoder is not the
// inverted table (`.None`). The caller has already resolved the name's *class* (a
// name no text codec stands behind is the reference's LookupError, raised before
// anything is encoded), so this only picks the entry to encode with.
charset_strict_codec :: proc(name: string) -> ^Charset_Entry {
	if name == "" {
		return nil
	}
	entry, class := charset_entry(name)
	if class != .Text {
		return nil
	}
	switch entry.kind {
	case .Utf8, .Utf8_Sig:
		return entry
	case .Single_Byte:
		if entry.strict != .None {
			return entry
		}
	case .Other:
	}
	return nil
}

// charset_strict_bad is whether a single-byte codec's strict encoder refuses one
// character: exactly when the inverted decode table has no byte for it. That is
// the port's encoder's own model, and the three classes agree with the reference
// on the *set* it refuses (build/probe_t_016baf45_encoder.py) — they differ only
// in the wording.
@(private)
charset_strict_bad :: proc(entry: ^Charset_Entry, code: rune) -> bool {
	_, found := charset_byte_for(entry.decode, code)
	return !found
}

// charset_strict_rule is one single-byte codec as the str layer's shared walk
// needs it (http.str_encode_failure_rule): the table's refusal, and the name and
// reason the reference's UnicodeEncodeError carries for the class.
// `entry.strict` is never `.None` here (`charset_strict_codec` filtered those).
@(private)
charset_strict_rule :: proc(entry: ^Charset_Entry) -> Str_Encode_Rule {
	switch entry.strict {
	case .Latin1:
		return {
			bad = charset_strict_bad,
			entry = entry,
			codec = CHARSET_STRICT_LATIN1_NAME,
			reason = CHARSET_STRICT_LATIN1_REASON,
		}
	case .Ascii:
		return {
			bad = charset_strict_bad,
			entry = entry,
			codec = CHARSET_STRICT_ASCII_NAME,
			reason = CHARSET_STRICT_ASCII_REASON,
		}
	case .Charmap, .None:
	}
	return {
		bad = charset_strict_bad,
		entry = entry,
		codec = CHARSET_STRICT_CHARMAP_NAME,
		reason = CHARSET_STRICT_CHARMAP_REASON,
	}
}

// charset_latin1_text is the str layer's reading of a byte string the transport
// holds: what urllib3's latin-1 decode of a head makes of it, one character per
// byte (docs/PARITY.md section 3.4) — `caf\xe9` is the str `'café'`, and the head
// the reference writes is written from *that*. So a byte above 0x7F is a
// character to the stream's codec, not a byte to copy. The result is `text`
// itself when every byte is ASCII (there is no character to convert) and
// otherwise a new string the caller owns.
charset_latin1_text :: proc(text: string, allocator: mem.Allocator) -> (string, bool) {
	ascii := true
	for byte in transmute([]u8)text {
		if byte >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		return text, false
	}
	builder := strings.builder_make(allocator)
	for byte in transmute([]u8)text {
		strings.write_rune(&builder, rune(byte))
	}
	return strings.to_string(builder), true
}

// charset_encode_strict is `text.encode(name)` for a *head*: the strict encoder
// (no `errors='replace'`, which is what the *body* takes), for a codec of the
// registry, and the `UnicodeEncodeError` the reference raises when one character
// has no encoding — as a value, because nothing of the head is written when it
// happens (output/streams.py:191-197 followed by core.py's handler).
//
// `entry` is nil for the utf-8 rule (`charset_strict_codec`), which is also what
// the codecs the port does not model get (`.Other`, `.None`): the recorded gap of
// docs/PARITY.md section 3.4.
//
// `text` is the port's *str* representation and not wire bytes (§3.6): a response
// head is converted first (charset_latin1_text), so one character here is one
// character to CPython on both messages and the positions in the exception are
// the ones the reference reports. The result is `text` itself when the codec
// leaves it alone (an ASCII head, the utf-8 rule) and otherwise a new string the
// caller owns.
charset_encode_strict :: proc(
	entry: ^Charset_Entry,
	text: string,
	allocator: mem.Allocator,
) -> (string, bool, Str_Encode_Error) {
	kind := Charset_Kind.Utf8
	if entry != nil {
		kind = entry.kind
	}
	switch kind {
	case .Utf8, .Other:
		failure := str_encode_failure(text, .Utf8)
		if failure.failed {
			return text, false, failure
		}
		return text, false, {}
	case .Utf8_Sig:
		failure := str_encode_failure(text, .Utf8)
		if failure.failed {
			return text, false, failure
		}
		if len(text) == 0 {
			// `''.encode('utf-8-sig')` is empty: the BOM opens a head, it does
			// not stand alone.
			return text, false, {}
		}
		builder := strings.builder_make(allocator)
		strings.write_string(&builder, "\xef\xbb\xbf")
		strings.write_string(&builder, text)
		return strings.to_string(builder), true, {}
	case .Single_Byte:
		if entry.strict != .None {
			failure := str_encode_failure_rule(text, nil, charset_strict_rule(entry))
			if failure.failed {
				return text, false, failure
			}
			// Every character of an ASCII text is its own byte in every codec
			// here, so there is nothing to re-encode.
			ascii := true
			for byte in transmute([]u8)text {
				if byte >= 0x80 {
					ascii = false
					break
				}
			}
			if ascii {
				return text, false, {}
			}
			builder := strings.builder_make(allocator)
			for index := 0; index < len(text); {
				size := str_utf8_seq_len(text[index:])
				if size <= 0 {
					// Unreachable: the walk above refused every character
					// without a byte. One `?` keeps this a walk.
					strings.write_byte(&builder, '?')
					index += 1
					continue
				}
				code, _ := utf8.decode_rune_in_string(text[index:])
				byte, found := charset_byte_for(entry.decode, code)
				if !found {
					strings.write_byte(&builder, '?')
				} else {
					strings.write_byte(&builder, byte)
				}
				index += size
			}
			return strings.to_string(builder), true, {}
		}
		failure := str_encode_failure(text, .Utf8)
		if failure.failed {
			return text, false, failure
		}
		return text, false, {}
	}
	return text, false, {}
}

// charset_error_message is the exception the reference raises when the registry
// has no text codec under this name, `handle_generic_error`'s
// `f'{type(e).__name__}: {msg}'` already applied. `encoding` picks the tail the
// side asks for (`codecs.encode()` where the name is used to write bytes out,
// `codecs.decode()` where it is used to read bytes in). The caller owns the
// result, and the name is the one as it was written, not its normalized form,
// which is how CPython words both messages.
charset_error_message :: proc(
	class: Charset_Class,
	name: string,
	encoding: bool,
	allocator: mem.Allocator,
) -> string {
	if class == .Non_Text {
		return fmt.aprintf(
			"LookupError: '%s' is not a text encoding; use codecs.%s() to handle arbitrary codecs",
			name,
			encoding ? "encode" : "decode",
			allocator = allocator,
		)
	}
	return fmt.aprintf("LookupError: unknown encoding: %s", name, allocator = allocator)
}
