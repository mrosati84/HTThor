// The codec registry of the printed text (src/http/charset.odin,
// src/http/charset_generated.odin; docs/PARITY.md §3.4).
//
// The generated tables are the reference's own data, read off its interpreter by
// build/gen_charset_tables.py, and the hash below is the check that the compiled
// tables are still that data: FNV-1a 64 over CHARSET_ENTRIES in order (each name,
// a NUL, its kind as one byte, its strict-encoder class as one byte, and for a
// `Single_Byte` entry its 256 code points as four little-endian bytes each) and
// then the two name lists behind 0x01 and 0x02 — the same value the generator
// computes, so a table that drifted, or an entry a lookup misses, fails here
// rather than on one shape.
package tests

import "core:mem"
import "core:testing"

import "src:http"

@(private)
charset_hash_eat :: proc(hash: ^u64, byte: u8) {
	hash^ = (hash^ ~ u64(byte)) * u64(0x100000001b3)
}

@(private)
charset_hash_eat_string :: proc(hash: ^u64, text: string) {
	for byte in transmute([]u8)text {
		charset_hash_eat(hash, byte)
	}
}

@(test)
test_charset_tables_match_the_generator :: proc(t: ^testing.T) {
	hash := u64(0xcbf29ce484222325)
	for entry in http.CHARSET_ENTRIES {
		charset_hash_eat_string(&hash, entry.name)
		charset_hash_eat(&hash, 0)
		charset_hash_eat(&hash, u8(entry.kind))
		charset_hash_eat(&hash, u8(entry.strict))
		if entry.kind == .Single_Byte {
			for code in entry.decode {
				for shift in 0 ..< 4 {
					charset_hash_eat(&hash, u8(code >> (8 * u32(shift))))
				}
			}
		}
	}
	for name in http.CHARSET_NON_TEXT_NAMES {
		charset_hash_eat(&hash, 0x01)
		charset_hash_eat_string(&hash, name)
	}
	for name in http.CHARSET_RAISING_NAMES {
		charset_hash_eat(&hash, 0x02)
		charset_hash_eat_string(&hash, name)
	}
	testing.expectf(
		t,
		hash == http.CHARSET_TABLE_HASH,
		"the compiled charset tables hash to %#016x, the generator's own value is %#016x",
		hash,
		http.CHARSET_TABLE_HASH,
	)
}

// The four classes a spelling can fall into, named one by one — including the
// spellings only the *normalized* name separates (`latin-1`, `latin_1` and
// `LATIN1` are one codec; `rot-13` is not a text codec while `mbcs` and `oem` do
// not resolve at all on this interpreter).
@(test)
test_charset_class_named_shapes :: proc(t: ^testing.T) {
	names := []string {
		"utf-8", "UTF-8", "utf 8", "u8", "cp65001", "utf-8-sig", "UTF_8_SIG",
		"latin-1", "latin_1", "LATIN1", "iso-8859-1", "ISO_8859-1:1987",
		"windows-1252", "cp1252", "koi8-r", "iso-8859-7", "cp037",
		"EBCDIC-CP-BE", "charmap", "big5", "utf-16", "idna",
		"undefined",
		"rot-13", "rot13", "hex", "base64", "zlib",
		"nope-enc", "", "mbcs", "oem", "pal", "utf-8x",
		"éutf-8", "utf-8☃", "uétf-8",
	}
	classes := []http.Charset_Class {
		.Text, .Text, .Text, .Text, .Text, .Text, .Text,
		.Text, .Text, .Text, .Text, .Text,
		.Text, .Text, .Text, .Text, .Text,
		.Text, .Text, .Text, .Text, .Text,
		.Raising,
		.Non_Text, .Non_Text, .Non_Text, .Non_Text, .Non_Text,
		.Unknown, .Unknown, .Unknown, .Unknown, .Unknown, .Unknown,
		.Text, .Text, .Unknown,
	}
	testing.expectf(t, len(names) == len(classes), "%d names, %d classes", len(names), len(classes))
	for name, index in names {
		testing.expectf(
			t,
			http.charset_class(name) == classes[index],
			"%q: class %v, expected %v",
			name,
			http.charset_class(name),
			classes[index],
		)
	}
	// The two helpers the CLI and the writer call are this same answer.
	testing.expect(t, http.charset_name_is_text("UTF 8"), "'UTF 8' is text")
	testing.expect(t, !http.charset_name_is_text("rot-13"), "'rot-13' is not")
	testing.expect(t, http.charset_name_raises_codec("undefined"), "`undefined` raises on use")
	testing.expect(t, !http.charset_name_raises_codec("utf-8"), "`utf-8` does not")
}

// A `Single_Byte` codec's table: a byte CPython's decoder accepts is its code
// point, a byte it refuses is CHARSET_UNDEFINED (and one U+FFFD when decoded) —
// and the encoder is that table inverted, last index wins, which is what
// `codecs.charmap_build` leaves.
@(test)
test_charset_single_byte_decode_and_encode :: proc(t: ^testing.T) {
	buffer: [4096]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	allocator := mem.arena_allocator(&arena)

	latin1, latin1_class := http.charset_entry("latin1")
	testing.expect(t, latin1_class == .Text && latin1 != nil, "latin1 resolves to an entry")
	testing.expect(t, latin1.kind == .Single_Byte, "latin1 is single-byte")
	testing.expect(t, latin1.decode[0x00] == 0x0000, "NUL is U+0000, not undefined")
	testing.expect(t, latin1.decode[0xe9] == 0x00e9, "0xe9 is U+00E9")
	testing.expect(t, latin1.decode[0xff] == 0x00ff, "0xff is U+00FF: every byte is defined")

	// 0x81 is the one byte windows-1252 leaves undefined: the decode writes one
	// U+FFFD there, and the character only U+FFFD stands for encodes as `?`.
	cp1252, cp1252_class := http.charset_entry("windows-1252")
	testing.expect(t, cp1252_class == .Text && cp1252 != nil, "windows-1252 resolves")
	testing.expect(t, cp1252.decode[0x81] == http.CHARSET_UNDEFINED, "0x81 is undefined")
	testing.expect(t, cp1252.decode[0xe9] == 0x00e9, "0xe9 is U+00E9")
	decoded, owned := http.charset_decode(cp1252, "a\x81b", allocator)
	testing.expect(t, owned, "the undefined byte had to be replaced")
	testing.expect(t, decoded == "a\xef\xbf\xbdb", "the undefined byte is U+FFFD")
	encoded, encoded_owned := http.charset_encode(cp1252, "a\u2603b", allocator)
	testing.expect(t, encoded_owned, "the snowman has no byte in windows-1252")
	testing.expect(t, encoded == "a?b", "an unencodable character is `?`")
	decoded, _ = http.charset_decode(cp1252, "caf\xe9", allocator)
	testing.expect(t, decoded == "caf\xc3\xa9", "0xe9 decodes to U+00E9, which is two utf-8 bytes")
	encoded, _ = http.charset_encode(cp1252, "caf\xc3\xa9", allocator)
	testing.expect(t, encoded == "caf\xe9", "and U+00E9 is 0xe9 back")

	// The utf-8 family: the walk the printed body always took, plus the BOM
	// utf-8-sig drops on the way in and writes on the way out.
	utf8_sig, utf8_sig_class := http.charset_entry("utf_8_sig")
	testing.expect(t, utf8_sig_class == .Text && utf8_sig != nil, "utf_8_sig resolves")
	testing.expect(t, utf8_sig.kind == .Utf8_Sig, "and is the BOM codec")
	decoded, _ = http.charset_decode(utf8_sig, "\xef\xbb\xbfcaf\xc3\xa9", allocator)
	testing.expect(t, decoded == "caf\xc3\xa9", "the decoder drops the BOM")
	encoded, _ = http.charset_encode(utf8_sig, "caf\xc3\xa9", allocator)
	testing.expect(t, encoded == "\xef\xbb\xbfcaf\xc3\xa9", "the encoder writes one")
	encoded, _ = http.charset_encode(utf8_sig, "", allocator)
	testing.expect(t, encoded == "", "`''.encode('utf-8-sig')` is empty")

	// The three failures the reference prints, in CPython's own words.
	message := http.charset_error_message(.Unknown, "NoPe", false, allocator)
	testing.expect(t, message == "LookupError: unknown encoding: NoPe", message)
	message = http.charset_error_message(.Non_Text, "rot-13", true, allocator)
	testing.expect(
		t,
		message ==
		"LookupError: 'rot-13' is not a text encoding; use codecs.encode() to handle arbitrary codecs",
		message,
	)
	message = http.charset_error_message(.Non_Text, "hex", false, allocator)
	testing.expect(
		t,
		message ==
		"LookupError: 'hex' is not a text encoding; use codecs.decode() to handle arbitrary codecs",
		message,
	)
}

// The normalization CPython's `_PyCodec_Lookup` applies before its alias table:
// it works on the name's bytes — ASCII lower-cased, every other byte collapsed
// with its neighbours into one '_', a run at either end dropped. The generated
// entry names are these normalized spellings, which is why a lookup normalizes
// first. `build/probe_t_aff4fc91_nonascii_name.py` is the measurement behind the
// non-ASCII cases: each byte of a character above U+007F is a separator, so
// `éutf-8` is utf-8 to the reference while `uétf-8` is a LookupError.
@(test)
test_charset_normalize_named_shapes :: proc(t: ^testing.T) {
	spellings := []string {
		"utf-8", "UTF-8", "utf 8", "utf-8-sig", "UTF_8_SIG",
		"ISO_8859-1:1987", "iso-ir-6", "utf-8-", "-utf-8", "--utf--8--",
		"latin.1", "", "nope-enc", "NOPE ENC", "euc_jp", "euc jp",
		"utf/8", "utf_8 ", " utf_8", "utf_8	",
		"éutf-8", "utf-8é", "utf-8☃", "☃utf-8", "latin-1é", "uétf-8",
	}
	normalized_names := []string {
		"utf_8", "utf_8", "utf_8", "utf_8_sig", "utf_8_sig",
		"iso_8859_1_1987", "iso_ir_6", "utf_8", "utf_8", "utf_8",
		"latin.1", "", "nope_enc", "nope_enc", "euc_jp", "euc_jp",
		"utf_8", "utf_8", "utf_8", "utf_8",
		"utf_8", "utf_8", "utf_8", "utf_8", "latin_1", "u_tf_8",
	}
	testing.expectf(
		t,
		len(spellings) == len(normalized_names),
		"%d spellings, %d names",
		len(spellings),
		len(normalized_names),
	)
	for spelling, index in spellings {
		normalized := http.charset_normalize(spelling, context.temp_allocator)
		testing.expectf(
			t,
			normalized == normalized_names[index],
			"%q normalizes to %q, expected %q",
			spelling,
			normalized,
			normalized_names[index],
		)
	}
	// The normalized name is the registry's key: a spelling and its normalized
	// form are the same class.
	testing.expect(
		t,
		http.charset_class("UTF 8") == http.charset_class("utf_8"),
		"a spelling and its normalized form resolve the same way",
	)
}

// The strict encoder a *head* is written with (docs/PARITY.md §3.4): which codec
// a stream picks for a name, the bytes it writes over the port's str
// representation — one character per code point, which is what CPython's
// positions count — and the exception it would raise instead.  The same rule
// runs for the metadata block and for a request's own declared charset, so this
// is the one place the two wordings and the positions are pinned without a
// fixture.
@(test)
test_charset_strict_head_encoder :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	// Which codec a name stands for — and nil (the utf-8 rule) for every name a
	// head cannot be written with: no name at all, a name that stands for no
	// text codec, one of the 117 the port has no encoder for, and the five `hz*`
	// spellings, whose strict encoder escapes instead of inverting the table.
	codecs := []struct {
		name:  string,
		kind:  http.Charset_Kind,
		found: bool,
	} {
		{"utf-8", .Utf8, true},
		{"UTF 8", .Utf8, true},
		{"utf-8-sig", .Utf8_Sig, true},
		{"windows-1252", .Single_Byte, true},
		{"iso-8859-1", .Single_Byte, true},
		{"ascii", .Single_Byte, true},
		{"big5", .Utf8, false},
		{"utf-16", .Utf8, false},
		{"hz", .Utf8, false},
		{"nope-enc", .Utf8, false},
		{"", .Utf8, false},
	}
	for codec in codecs {
		entry := http.charset_strict_codec(codec.name)
		if !codec.found {
			testing.expectf(t, entry == nil, "%q: expected the utf-8 rule", codec.name)
			continue
		}
		testing.expectf(t, entry != nil, "%q: expected a codec", codec.name)
		if entry != nil {
			testing.expectf(t, entry.kind == codec.kind, "%q: kind %v", codec.name, entry.kind)
		}
	}

	// latin-1 is the identity: U+00E9 goes back to the byte the transport read
	// it from, which is why a prettified head of a latin-1 response is the same
	// bytes on the wire and in the output.
	latin1 := http.charset_strict_codec("iso-8859-1")
	text, owned, failure := http.charset_encode_strict(latin1, "X-Latin: caf\xc3\xa9", allocator)
	testing.expect(t, !failure.failed, "latin-1 has a byte for U+00E9")
	testing.expect(t, owned, "the head had to be re-encoded")
	testing.expect(t, text == "X-Latin: caf\xe9", "and the byte is the wire's own")

	// utf-8-sig opens the block with its BOM, and the empty string stays empty
	// (`''.encode('utf-8-sig')` is the BOM only when there is something after
	// it).
	sig := http.charset_strict_codec("UTF_8_SIG")
	text, owned, failure = http.charset_encode_strict(sig, "HTTP/1.1 200 OK", allocator)
	testing.expect(t, !failure.failed && owned, "utf-8-sig opens the block")
	testing.expect(t, text == "\xef\xbb\xbfHTTP/1.1 200 OK", "with the BOM in front")
	text, owned, failure = http.charset_encode_strict(sig, "", allocator)
	testing.expect(t, !failure.failed && !owned && text == "", "`''.encode('utf-8-sig')` is empty")

	// The utf-8 rule: an ASCII head is written through untouched, and a byte the
	// argv layer kept raw is the lone surrogate CPython's encoder refuses —
	// `\udcff` for the byte 0xff, one position per character before it.
	text, owned, failure = http.charset_encode_strict(nil, "HTTP/1.1 200 OK", allocator)
	testing.expect(t, !failure.failed && !owned, "the utf-8 rule is the identity here")
	testing.expect(t, text == "HTTP/1.1 200 OK", "and writes the text it was given")
	_, _, failure = http.charset_encode_strict(nil, "X-Latin: caf\xff", allocator)
	testing.expect(t, failure.failed, "a raw byte is not utf-8")
	testing.expectf(
		t,
		failure.codec == "utf-8" && failure.reason == "surrogates not allowed",
		"codec %q, reason %q",
		failure.codec,
		failure.reason,
	)
	testing.expectf(
		t,
		failure.position == 12 && failure.end == 12,
		"positions %d-%d, expected 12",
		failure.position,
		failure.end,
	)
	message := http.str_encode_error_message(&failure, allocator)
	testing.expectf(
		t,
		message ==
		"UnicodeEncodeError: 'utf-8' codec can't encode character '\\udcff' in position 12: surrogates not allowed",
		message,
	)

	// The three wordings a single-byte codec's refusal carries, each naming
	// *its* codec — which is the half the table cannot answer, since ascii's and
	// latin-1's tables are spelled many ways and cp037's is isomorphic.
	cp1252 := http.charset_strict_codec("cp1252")
	_, _, failure = http.charset_encode_strict(cp1252, "X-Undefined: a\xc2\x81" + "b", allocator)
	testing.expect(t, failure.failed, "cp1252 has no byte for U+0081")
	message = http.str_encode_error_message(&failure, allocator)
	testing.expectf(
		t,
		message ==
		"UnicodeEncodeError: 'charmap' codec can't encode character '\\x81' in position 14: character maps to <undefined>",
		message,
	)

	ascii_codec := http.charset_strict_codec("us-ascii")
	_, _, failure = http.charset_encode_strict(ascii_codec, "caf\xc3\xa9", allocator)
	message = http.str_encode_error_message(&failure, allocator)
	testing.expectf(
		t,
		message ==
		"UnicodeEncodeError: 'ascii' codec can't encode character '\\xe9' in position 3: ordinal not in range(128)",
		message,
	)

	// A run of two: CPython reports the longest stretch of characters the codec
	// refuses, and the run is counted in *characters* even though `€` is three
	// bytes of the port's str — `caf` and `é` are latin-1, so the two `€` are
	// one character each, at positions 4 and 5.
	_, _, failure = http.charset_encode_strict(latin1, "caf\xc3\xa9\xe2\x82\xac\xe2\x82\xac", allocator)
	testing.expectf(
		t,
		failure.position == 4 && failure.end == 5,
		"positions %d-%d, expected 4-5",
		failure.position,
		failure.end,
	)
	message = http.str_encode_error_message(&failure, allocator)
	testing.expectf(
		t,
		message ==
		"UnicodeEncodeError: 'latin-1' codec can't encode characters in position 4-5: ordinal not in range(256)",
		message,
	)

	// The response head's own reading: the transport's bytes, one character per
	// byte, and nothing at all for a head that is ASCII (the common case, and
	// the one that must not allocate).
	text, owned = http.charset_latin1_text("HTTP/1.1 200 OK", allocator)
	testing.expect(t, !owned && text == "HTTP/1.1 200 OK", "an ASCII head is left where it is")
	text, owned = http.charset_latin1_text("X-Latin: caf\xe9", allocator)
	testing.expect(t, owned, "0xe9 has to become a character")
	testing.expect(t, text == "X-Latin: caf\xc3\xa9", "the character U+00E9")
}
