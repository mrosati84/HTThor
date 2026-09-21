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

// ---------------------------------------------------------------------------
// The extracted candidate-loop phases (backlog M8).  Every helper the refactor
// pulled out of `detect_matches` is @(private) to src/http, so each case below
// drives it through the loop and reads that phase's own observable output: the
// chunking plan (and its size classes), the mark's verdict, the admission
// cascade, the two slicing branches, the mean and its early stop, the fallback
// recording, the coherence merge, the fingerprint gate and the epilogue's
// fallback order.  The expectations are the port's answers for these payloads,
// measured on both the pre-refactor and the post-refactor file (they agree byte
// for byte over a 46-shape battery), so they pin the extracted phases rather
// than re-derive the reference.

// `utf8_ru` is "Привет, мир! " in UTF-8: the multibyte payload the slicing and
// specified-charset cases use.
@(private)
detect_utf8_ru :: []u8{0xd0, 0x9f, 0xd1, 0x80, 0xd0, 0xb8, 0xd0, 0xb2, 0xd0, 0xb5, 0xd1, 0x82, 0x2c, 0x20, 0xd0, 0xbc, 0xd0, 0xb8, 0xd1, 0x80, 0x21, 0x20}

// detect_chunk_plan — the `steps`/`chunk_size` collapse, the offset walk it
// feeds and the scratch room they set.  2560 bytes is exactly
// `chunk_size * steps`, so `from_bytes` measures the payload as one full-length
// chunk and cp1250's mean mess ratio is 0.0; 2561 bytes is one byte past that,
// so the same candidate is measured over six 512-byte chunks whose mean is
// 0.011 / 6 (the value tests/detect_test.odin's chunked-tail case pins from the
// reference).  A plan that rounds the boundary the other way, or that drops the
// last offset, moves both numbers.
@(test)
test_detect_chunk_plan_boundary :: proc(t: ^testing.T) {
	buffer: [2561]u8

	one_chunk := http.detect_matches(detect_repeat(buffer[:], detect_pattern, 2560), context.allocator)
	testing.expectf(t, one_chunk.count == 10, "2560 bytes: %d candidates, 10 expected", one_chunk.count)
	if one_chunk.count > 0 {
		testing.expectf(
			t,
			one_chunk.items[0].encoding == "cp1250",
			"2560 bytes: best is %s, cp1250 expected",
			one_chunk.items[0].encoding,
		)
		testing.expectf(
			t,
			math.abs(one_chunk.items[0].chaos) < 1e-12,
			"2560 bytes: cp1250 chaos %.12f, one full-length chunk measures 0",
			one_chunk.items[0].chaos,
		)
		testing.expectf(
			t,
			one_chunk.items[0].str_len == 2560,
			"2560 bytes: the reading is %d characters, 2560 expected",
			one_chunk.items[0].str_len,
		)
	}

	six_chunks := http.detect_matches(detect_repeat(buffer[:], detect_pattern, 2561), context.allocator)
	testing.expectf(t, six_chunks.count == 10, "2561 bytes: %d candidates, 10 expected", six_chunks.count)
	if six_chunks.count > 0 {
		testing.expectf(
			t,
			six_chunks.items[0].encoding == "cp1250",
			"2561 bytes: best is %s, cp1250 expected",
			six_chunks.items[0].encoding,
		)
		testing.expectf(
			t,
			math.abs(six_chunks.items[0].chaos - 0.011 / 6.0) < 1e-9,
			"2561 bytes: cp1250 chaos %.12f, six chunks measure 0.011 / 6",
			six_chunks.items[0].chaos,
		)
	}
}

// detect_chunk_plan's `is_too_large` class together with
// detect_huge_candidate_tail_is_defined and detect_candidate_fingerprint's size
// gate: a payload at or over `TOO_BIG_SEQUENCE` is decoded at its head only,
// its tail is validated as one window, the reading is the payload's own length,
// and no candidate carries the `str(match)` folding key.
@(test)
test_detect_huge_class :: proc(t: ^testing.T) {
	size := 12_000_000
	buffer := make([]u8, size, context.allocator)
	defer delete(buffer, context.allocator)
	payload := detect_repeat(buffer, detect_pattern, size)

	results := http.detect_matches(payload, context.allocator)
	testing.expectf(t, results.count == 15, "huge: %d candidates, 15 expected", results.count)
	if results.count > 0 {
		testing.expectf(t, results.items[0].encoding == "cp1251", "huge: best is %s, cp1251 expected", results.items[0].encoding)
		testing.expectf(
			t,
			math.abs(results.items[0].chaos) < 1e-12,
			"huge: cp1251 chaos %.12f, every chunk measures 0",
			results.items[0].chaos,
		)
		testing.expectf(
			t,
			results.items[0].str_len == size,
			"huge: the reading is %d characters, %d expected",
			results.items[0].str_len,
			size,
		)
		for candidate in results.items[:results.count] {
			testing.expectf(t, candidate.fingerprint == 0, "huge: %s carries fingerprint %d, TOO_BIG_SEQUENCE never folds", candidate.encoding, candidate.fingerprint)
		}
	}
	testing.expectf(
		t,
		http.detect_encoding(payload, context.allocator) == "cp1251",
		"huge: detect_encoding answers something other than cp1251",
	)

	// One byte cp1251 has no code for, at the very end of the payload: the head
	// decoded cleanly, so only the tail window catches it — the candidates that
	// read the tail as undefined are out (15 → 10), and the answer moves to the
	// first code page that reads it.
	buffer[size - 1] = 0x98
	tail := string(buffer)
	results = http.detect_matches(tail, context.allocator)
	testing.expectf(t, results.count == 10, "huge undefined tail: %d candidates, 10 expected", results.count)
	if results.count > 0 {
		testing.expectf(
			t,
			results.items[0].encoding == "cp1255",
			"huge undefined tail: best is %s, cp1255 expected",
			results.items[0].encoding,
		)
	}
	testing.expectf(
		t,
		http.detect_encoding(tail, context.allocator) == "cp1255",
		"huge undefined tail: detect_encoding answers something other than cp1255",
	)
}

// detect_bom_encoding_answer and the admission cascade's mark-only codecs: a
// `utf_16` mark decides the answer only where the payload behind it is a whole
// number of code units (the 92-byte case above); one or three bytes past that
// and the mark is not a reading at all, so the search runs on and nothing
// survives (`ff`/`fe` is not valid utf-8, and utf_16 without the mark's shape is
// skipped).  A `+/v8` mark is the other side of the same rule: it is *not*
// treated as utf_7, so the ASCII payload behind it answers ascii over all 100
// bytes.
@(test)
test_detect_bom_mark_shape :: proc(t: ^testing.T) {
	body: [200]u8
	length := 2
	body[0] = 0xff
	body[1] = 0xfe
	for character in detect_sentence {
		body[length + 0] = u8(character)
		body[length + 1] = 0
		length += 2
	}
	testing.expectf(t, length == 92, "the even payload is %d bytes, 92 expected", length)

	for extra in ([?]int{1, 3}) {
		payload := string(body[:length + extra])
		results := http.detect_matches(payload, context.allocator)
		testing.expectf(
			t,
			results.count == 0,
			"utf16 mark + %d bytes: %d candidates, the mark decides nothing and the search keeps none",
			extra,
			results.count,
		)
		testing.expectf(
			t,
			http.detect_encoding(payload, context.allocator) == "utf_8",
			"utf16 mark + %d bytes: detect_encoding answers something other than utf_8",
			extra,
		)
	}

	for index in 0 ..< 100 {
		body[index] = 'a'
	}
	body[0] = 0x2b
	body[1] = 0x2f
	body[2] = 0x76
	sig := http.detect_matches(string(body[:100]), context.allocator)
	testing.expectf(t, sig.count == 1, "utf7 sig: %d candidates, 1 expected", sig.count)
	if sig.count > 0 {
		testing.expectf(t, sig.items[0].encoding == "ascii", "utf7 sig: best is %s, ascii expected", sig.items[0].encoding)
		testing.expectf(t, sig.items[0].str_len == 100, "utf7 sig: the reading is %d bytes, the whole payload expected", sig.items[0].str_len)
		testing.expect(t, !sig.items[0].bom, "utf7 sig: the match carries a mark it must not")
	}
}

// detect_slice_candidate_chunks' multibyte branch: a multibyte candidate is
// sliced byte-wise (utils.py:401-452), and this payload's chunk boundaries fall
// inside its multi-byte sequences — the reading and the chunk set are what the
// assertions pin (a chunk set that lost or mis-cut a slice changes the ratio or
// the candidate list), and the payload is kept with chaos 0.
@(test)
test_detect_multibyte_chunk_slicing :: proc(t: ^testing.T) {
	buffer: [6000]u8
	payload := detect_repeat(buffer[:], detect_utf8_ru, 6000)
	results := http.detect_matches(payload, context.allocator)
	testing.expectf(t, results.count == 1, "utf8-cut: %d candidates, 1 expected", results.count)
	if results.count > 0 {
		testing.expectf(t, results.items[0].encoding == "utf_8", "utf8-cut: best is %s, utf_8 expected", results.items[0].encoding)
		testing.expectf(
			t,
			results.items[0].str_len == 3545,
			"utf8-cut: the reading is %d characters, 3545 expected",
			results.items[0].str_len,
		)
		testing.expectf(
			t,
			math.abs(results.items[0].chaos) < 1e-12,
			"utf8-cut: chaos %.12f, every chunk of the reading measures 0",
			results.items[0].chaos,
		)
	}
	testing.expectf(
		t,
		http.detect_encoding(payload, context.allocator) == "utf_8",
		"utf8-cut: detect_encoding answers something other than utf_8",
	)
}

// detect_prioritized_hints, detect_record_soft_failure and the epilogue's
// fallback order: an ASCII `<meta charset="cp1251">` in the payload's first 8192
// bytes names the payload's own charset, so cp1251 is a prioritized candidate
// even though the bytes behind it are UTF-8 — every candidate fails the probing
// and the *specified* entry answers as the fallback, whose chaos is the 0.2
// threshold rather than a measurement (api.py:506-551) and whose `str_len` is
// the full payload (the fallback decode in full).
@(test)
test_detect_specified_charset_fallback :: proc(t: ^testing.T) {
	buffer: [3000]u8
	detect_repeat(buffer[:], detect_utf8_ru, 3000)
	copy(buffer[:], `<meta charset="cp1251">`)
	payload := string(buffer[:])

	results := http.detect_matches(payload, context.allocator)
	testing.expectf(t, results.count == 1, "specified: %d candidates, 1 expected", results.count)
	if results.count > 0 {
		testing.expectf(t, results.items[0].encoding == "cp1251", "specified: best is %s, cp1251 expected", results.items[0].encoding)
		testing.expect(t, results.items[0].chaos == 0.2, "specified: the fallback's chaos is the 0.2 threshold, not a measurement")
		testing.expectf(t, results.items[0].str_len == 3000, "specified: the reading is %d characters, 3000 expected", results.items[0].str_len)
	}
	testing.expectf(
		t,
		http.detect_encoding(payload, context.allocator) == "cp1251",
		"specified: detect_encoding answers something other than cp1251",
	)
}

// detect_chunk_coherence and detect_candidate_fingerprint: an XML declaration
// naming koi8-r is that same hint path, this time with candidates that survive.
// The coherence is the *merged* per-language average (0.2727 for cp1250 over
// this body — not the per-chunk maximum), and the folding key is non-zero below
// `TOO_BIG_SEQUENCE` (test_detect_huge_class pins the zero side).
@(test)
test_detect_coherence_merge_and_fingerprint :: proc(t: ^testing.T) {
	buffer: [3000]u8
	detect_repeat(buffer[:], detect_pattern, 3000)
	copy(buffer[:], `<?xml version="1.0" encoding="koi8-r"?><root>`)

	results := http.detect_matches(string(buffer[:]), context.allocator)
	testing.expectf(t, results.count == 10, "koi8-r hint: %d candidates, 10 expected", results.count)
	if results.count > 0 {
		testing.expectf(t, results.items[0].encoding == "cp1250", "koi8-r hint: best is %s, cp1250 expected", results.items[0].encoding)
		testing.expectf(
			t,
			math.abs(results.items[0].coherence - 0.2727) < 1e-9,
			"koi8-r hint: cp1250 coherence %.12f, the merged average is 0.2727",
			results.items[0].coherence,
		)
		testing.expectf(
			t,
			results.items[0].fingerprint != 0,
			"koi8-r hint: cp1250 carries no folding key below TOO_BIG_SEQUENCE",
		)
	}
}

// The epilogue's no-survivor path (detect_finish_matches): a payload no
// candidate decodes and no fallback answers keeps an empty result, and
// `detect_encoding` turns that into utf_8 on its own (encoding.py:16-31).
@(test)
test_detect_no_survivor_epilogue :: proc(t: ^testing.T) {
	buffer: [3000]u8
	for index in 0 ..< 3000 {
		buffer[index] = u8((index * 7 + index / 3) % 256)
	}
	payload := string(buffer[:])
	results := http.detect_matches(payload, context.allocator)
	testing.expectf(t, results.count == 0, "mixed: %d candidates, none expected", results.count)
	testing.expectf(
		t,
		http.detect_encoding(payload, context.allocator) == "utf_8",
		"mixed: detect_encoding answers something other than utf_8",
	)
}

// detect_prioritized_hints' ordering rule: the payload's own declared charset is
// tested *first*, ahead of the fixed candidate table.  It changes no measured
// value on this body — cp866 and cp1125 read the same mess ratios — but it
// decides which of two tied candidates the stable sort keeps first, which is the
// order `prioritized_encodings` produces in the reference.
@(test)
test_detect_prioritized_hint_order :: proc(t: ^testing.T) {
	buffer: [3000]u8
	detect_repeat(buffer[:], detect_pattern, 3000)
	copy(buffer[:], `<meta charset="cp866">`)

	results := http.detect_matches(string(buffer[:]), context.allocator)
	testing.expectf(t, results.count == 10, "cp866 hint: %d candidates, 10 expected", results.count)
	if results.count == 10 {
		testing.expectf(
			t,
			results.items[0].encoding == "cp1250",
			"cp866 hint: best is %s, cp1250 expected",
			results.items[0].encoding,
		)
		testing.expectf(
			t,
			math.abs(results.items[0].chaos - 0.011 / 5.0) < 1e-9,
			"cp866 hint: cp1250 chaos %.12f, five chunks measure 0.011 / 5",
			results.items[0].chaos,
		)
		order := [?]string {
			"cp1250",
			"cp1251",
			"cp1253",
			"cp1255",
			"cp874",
			"iso8859_6",
			"mac_cyrillic",
			"cp866",
			"cp1125",
			"mac_greek",
		}
		for candidate, index in order {
			testing.expectf(
				t,
				results.items[index].encoding == candidate,
				"cp866 hint: candidate %d is %s, the declared charset is tested first (%s expected)",
				index,
				results.items[index].encoding,
				candidate,
			)
		}
	}
}
