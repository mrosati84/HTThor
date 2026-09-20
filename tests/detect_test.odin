// `detect_encoding` — the charset_normalizer pipeline behind httpie's
// `Content-Type`-less decode (src/http/detect.odin, detect_md.odin,
// detect_cd.odin, detect_generated.odin; docs/PARITY.md section 3.4).
//
// Every expectation below is the reference's own answer, read off it by
// build/probe_t_036c18c7_cases.py: the guess (httpie's `detect_encoding`, which
// is utf-8 at or under `TOO_SMALL_SEQUENCE` and `from_bytes(...).best().encoding`
// above it), the best encoding, and the kept candidates in order with their
// chaos.  The payloads are built by a rule those two files share — a literal, a
// byte pattern repeated to a length — so a code page table or a chunk rule that
// drifts makes this fail with the byte string that did it.
//
// This is the unit-test half of the gate.  The other half is the corpus
// comparison, `build/probe_t_036c18c7_detect_parity.py`, which runs this port and
// the reference over 782 bodies and compares every candidate's chaos and
// coherence as exact IEEE-754 bit patterns; it is what found the differences
// these cases now pin (the tail chunk of a chunked payload, the definitive-mode
// trigger, the submatch folding).
package tests

import "core:math"
import "core:mem"
import "core:testing"

import "src:http"

// `pattern` is cp1251's "Привет, мир! " and `sentence` the ASCII line the UTF-16
// case carries; both are the reference probe's own data.
@(private)
detect_pattern :: []u8{0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2, 0x2c, 0x20, 0xec, 0xe8, 0xf0, 0x21, 0x20}

@(private)
detect_sentence :: "The quick brown fox jumps over the lazy dog. "

// detect_repeat is `(pattern * (length / len(pattern) + 1))[:length]`.
@(private)
detect_repeat :: proc(buffer: []u8, pattern: []u8, length: int) -> string {
	for index in 0 ..< length {
		buffer[index] = pattern[index % len(pattern)]
	}
	return string(buffer[:length])
}

// A kept candidate, as the reference reports it: the encoding and the mean
// chaos.  Chaos is compared at 1e-9 — the reference prints twelve digits of it
// and the exact bits are the corpus probe's business, not this file's.
@(private)
Detect_Case :: struct {
	encoding: string,
	chaos:    f64,
}

// detect_expect runs one payload and checks the guess, the best encoding and
// every kept candidate against the reference's answer.
@(private)
detect_expect :: proc(
	t: ^testing.T,
	name: string,
	payload: string,
	guess: string,
	best: string,
	candidates: []Detect_Case,
) {
	results := http.detect_matches(payload, context.allocator)
	testing.expectf(
		t,
		results.count == len(candidates),
		"%s: %d candidates, the reference kept %d",
		name,
		results.count,
		len(candidates),
	)
	for candidate, index in candidates {
		if index >= results.count {
			break
		}
		match := results.items[index]
		testing.expectf(
			t,
			match.encoding == candidate.encoding,
			"%s: candidate %d is %s, the reference has %s",
			name,
			index,
			match.encoding,
			candidate.encoding,
		)
		testing.expectf(
			t,
			math.abs(match.chaos - candidate.chaos) < 1e-9,
			"%s: %s chaos %.12f, the reference measured %.12f",
			name,
			candidate.encoding,
			match.chaos,
			candidate.chaos,
		)
	}
	guess_actual := http.detect_encoding(payload, context.allocator)
	testing.expectf(
		t,
		guess_actual == guess,
		"%s: detect_encoding is %s, the reference answers %s",
		name,
		guess_actual,
		guess,
	)
	if results.count > 0 {
		testing.expectf(
			t,
			results.items[0].encoding == best,
			"%s: best is %s, the reference answers %s",
			name,
			results.items[0].encoding,
			best,
		)
	}
}

// The threshold and the two one-candidate shapes: the guess answers utf-8
// without running the pipeline at all at or under 32 bytes (httpie's
// `detect_encoding`), and above it an ASCII body is `ascii`'s.
@(test)
test_detect_threshold_and_ascii :: proc(t: ^testing.T) {
	detect_expect(t, "empty", "", "utf_8", "utf_8", []Detect_Case{{"utf_8", 0.0}})

	thirty_two := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	detect_expect(t, "threshold-32", thirty_two, "utf_8", "ascii", []Detect_Case{{"ascii", 0.0}})

	thirty_three := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	detect_expect(t, "threshold-33", thirty_three, "ascii", "ascii", []Detect_Case{{"ascii", 0.0}})

	detect_expect(
		t,
		"english-64",
		"The quick brown fox jumps over the lazy dog. The quick brown fox",
		"ascii",
		"ascii",
		[]Detect_Case{{"ascii", 0.0}},
	)
}

// A body of nothing but letters plus one byte at or above 0x80: EBCDIC's cp037
// reads it cleanly and wins, and nine other single-byte code pages survive the
// chaos probe behind it — this is the shape the card's own measured example uses
// (`b"a" * 40 + b"\x81"` is `/////…` to the reference), and the order is the
// iteration order after the stable sort, so it pins the whole candidate list.
@(test)
test_detect_letters_and_high_byte :: proc(t: ^testing.T) {
	buffer: [41]u8
	for index in 0 ..< 40 {
		buffer[index] = 'a'
	}
	buffer[40] = 0x81
	detect_expect(
		t,
		"ascii-40-81",
		string(buffer[:]),
		"cp037",
		"cp037",
		[]Detect_Case {
			{"cp037", 0.0},
			{"cp864", 0.0},
			{"mac_greek", 0.0},
			{"cp1125", 0.049},
			{"cp1251", 0.049},
			{"cp737", 0.049},
			{"cp855", 0.049},
			{"koi8_r", 0.049},
			{"ptcp154", 0.049},
			{"cp1006", 0.19},
		},
	)
}

// A real decode rather than a coincidence: latin-1's `café ` read back as the
// code page whose letters it is, and the same text in UTF-8 read as utf_8 with
// the reading shorter than the payload (the BOM-less utf_8 candidate decodes
// 72 bytes to 60 characters).
@(test)
test_detect_latin1_and_utf8 :: proc(t: ^testing.T) {
	latin1: [60]u8
	for index in 0 ..< 12 {
		latin1[index * 5 + 0] = 'c'
		latin1[index * 5 + 1] = 'a'
		latin1[index * 5 + 2] = 'f'
		latin1[index * 5 + 3] = 0xe9
		latin1[index * 5 + 4] = ' '
	}
	detect_expect(
		t,
		"latin1-cafe-60",
		string(latin1[:]),
		"cp1250",
		"cp1250",
		[]Detect_Case{{"cp1250", 0.0}, {"cp775", 0.0}, {"mac_latin2", 0.0}},
	)

	utf8: [72]u8
	for index in 0 ..< 12 {
		utf8[index * 6 + 0] = 'c'
		utf8[index * 6 + 1] = 'a'
		utf8[index * 6 + 2] = 'f'
		utf8[index * 6 + 3] = 0xc3
		utf8[index * 6 + 4] = 0xa9
		utf8[index * 6 + 5] = ' '
	}
	detect_expect(
		t,
		"utf8-cafe-72",
		string(utf8[:]),
		"utf_8",
		"utf_8",
		[]Detect_Case{{"utf_8", 0.0}},
	)
}

// A payload over `steps * chunk_size` bytes is measured in chunks, and the last
// offset of a *deferred single-byte* candidate yields the tail of the payload —
// one byte here, and that byte is part of the mean.  cp1250's chaos is 0.0018333
// for this body precisely because the mean is over six ratios, five of 512 bytes
// and one of a single byte (0.011 / 6); a chunk set without that tail gives
// 0.011 / 5 and loses the shape the reference has.
@(test)
test_detect_chunked_tail :: proc(t: ^testing.T) {
	buffer: [2561]u8
	payload := detect_repeat(buffer[:], detect_pattern, 2561)
	detect_expect(
		t,
		"cp1251-2561",
		payload,
		"cp1250",
		"cp1250",
		[]Detect_Case {
			{"cp1250", 0.0018333333333333333},
			{"cp1251", 0.0},
			{"cp1253", 0.0},
			{"cp1255", 0.0},
			{"cp874", 0.0},
			{"iso8859_6", 0.0},
			{"mac_cyrillic", 0.0},
			{"cp1125", 0.128},
			{"cp866", 0.128},
			{"mac_greek", 0.128},
		},
	)
}

// The same body with a byte cp1251 has no code for as its **last** byte: the
// tail chunk is a strict decode, so every code page without that byte is out —
// the answer moves to mac_cyrillic and only four candidates are kept.  This is
// the rule that makes the last offset matter in both directions.
@(test)
test_detect_chunked_tail_undefined :: proc(t: ^testing.T) {
	buffer: [2561]u8
	payload := detect_repeat(buffer[:], detect_pattern, 2560)
	buffer[2560] = 0x98
	payload = string(buffer[:])
	detect_expect(
		t,
		"cp1251-2560-tail-98",
		payload,
		"mac_cyrillic",
		"mac_cyrillic",
		[]Detect_Case {
			{"mac_cyrillic", 0.0},
			{"ptcp154", 0.0},
			{"cp1125", 0.128},
			{"cp866", 0.128},
		},
	)
}

// A UTF-16 BOM: the reference decodes the payload with `utf_16` and answers it —
// the search ends at the mark's candidate — and this port answers the mark's
// codec without decoding it (it has no utf-16 decoder, docs/PARITY.md section
// 3.4), so the name and the BOM flag are what it can pin.
@(test)
test_detect_utf16_bom :: proc(t: ^testing.T) {
	buffer: [96]u8
	buffer[0] = 0xff
	buffer[1] = 0xfe
	length := 2
	for character in detect_sentence {
		buffer[length + 0] = u8(character)
		buffer[length + 1] = 0
		length += 2
	}
	payload := string(buffer[:length])
	results := http.detect_matches(payload, context.allocator)
	testing.expectf(t, len(payload) == 92, "the payload is %d bytes, the reference case is 92", len(payload))
	testing.expectf(t, results.count == 1, "%d candidates, the reference keeps 1", results.count)
	if results.count > 0 {
		testing.expectf(
			t,
			results.items[0].encoding == "utf_16",
			"the best is %s, the reference answers utf_16",
			results.items[0].encoding,
		)
		testing.expect(t, results.items[0].bom, "the match carries the mark")
	}
	guess := http.detect_encoding(payload, context.allocator)
	testing.expectf(t, guess == "utf_16", "detect_encoding is %s, the reference answers utf_16", guess)
}

// Every path through the loop allocates per candidate — the chunk rooms, the
// coherence lists, the language tables — and each one has to be released before
// the answer is built: the pipeline runs on the writer's own allocator, once per
// printed body, so a leak here is a leak per response.  The tracking allocator
// answers that question the way the CLI tests do.
@(test)
test_detect_leaks_nothing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	short := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	guess := http.detect_encoding(short, allocator)
	testing.expect(t, guess == "ascii", "the ASCII body is ascii")

	buffer: [2561]u8
	long := detect_repeat(buffer[:], detect_pattern, 2561)
	results := http.detect_matches(long, allocator)
	testing.expect(t, results.count == 10, "the chunked body keeps 10 candidates")
	testing.expect(t, http.detect_encoding(long, allocator) == "cp1250", "and answers cp1250")

	// An unreadable one: the loop's early exits allocate too.
	testing.expect(t, http.detect_encoding("\xff\xfe\x00\x00", allocator) == "utf_8", "a short body is utf_8")

	expect_no_leaks(t, &track)
}
