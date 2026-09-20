// The mess detectors of the printed body's *guess*: `md.py`'s ten plugins and
// `mess_ratio`.
//
// `detect_encoding` (httpie/encoding.py:16-31) is `from_bytes(content).best()`
// above `charset_normalizer.constant.TOO_SMALL_SEQUENCE`, and `from_bytes`
// ranks every candidate code page by how *messy* its reading of the payload is
// (`md.py:909-1063`).  This file is that ranking's per-candidate half: what one
// decoded chunk's `mess_ratio` is, as the sum of ten detectors' ratios.
//
// Every detector is fed the characters of a chunk in one pass, and each one is
// the port of a plugin class in `md.py` — same fields, same branches, same
// thresholds, same order of the ten ratios in the sum, because the sum is a
// float and a different order is a different float.  `CharInfo`'s per-code-point
// properties (`md.py:44-243`) come out of `detect_generated.odin` as a run table;
// `src/http/detect.odin` is the candidate loop that calls this.
//
// What the reference measures and this does not invent:
//
//   - `mess_ratio` walks the decoded chunk in blocks of `step` characters
//     (32/64/128 by length) and *stops* once the running sum has reached the
//     threshold — a chunk whose first block is already messy is never measured
//     past it, which is how a candidate is rejected early;
//   - on a clean pass the loop lands in the `else` clause instead: a synthetic
//     `\n` is fed to the word plugin's buffer and to two others (the ASCII
//     shortcut decides which), and the sum is recomputed once more;
//   - `ratio` is `round(..., 3)` (Python's correctly-rounded decimal, which
//     `detect_round3` reproduces through the C `printf`).
package http

import "core:fmt"
import "core:math"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// The character table (`md.py:44-257`)

// detect_char_info is `_char_info(character)` / `_ASCII_CHAR_INFO[codepoint]`:
// the ASCII fast path is a 128-entry table, everything else a run lookup.
detect_char_info :: proc(cp: rune) -> Detect_Info {
	if cp >= 0 && cp < 128 {
		return DETECT_ASCII[cp]
	}
	low, high := 0, len(DETECT_RUN_START)
	for low < high {
		middle := (low + high) / 2
		if DETECT_RUN_START[middle] <= u32(cp) {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low == 0 {
		// Unreachable: the first run starts at code point 0.
		return Detect_Info{}
	}
	return DETECT_RUNS[low - 1]
}

// detect_char_range is `unicode_range(character)`: the range *name*, "" for the
// `None` a code point outside every range gets.
detect_char_range :: proc(info: Detect_Info) -> string {
	return DETECT_RANGE_NAMES[info.range]
}

// detect_is_basic_latin is the `unicode_range_a == "Basic Latin"` test
// `is_suspiciously_successive_range` makes by name.
@(private)
detect_range_is_basic_latin :: proc(range_id: u16) -> bool {
	return range_id != 0 && DETECT_RANGE_NAMES[range_id] == "Basic Latin"
}

// detect_ranges_are_suspicious is `is_suspiciously_successive_range`
// (md.py:874-906) over range ids: 0 is `None`.
detect_ranges_are_suspicious :: proc(range_a, range_b: u16) -> bool {
	if range_a == 0 || range_b == 0 {
		return true
	}
	family_a := DETECT_RANGE_FAMILY[range_a]
	family_b := DETECT_RANGE_FAMILY[range_b]
	if family_a == family_b {
		return false
	}
	if DETECT_FAMILY_ANY[family_a] || DETECT_FAMILY_ANY[family_b] {
		return false
	}
	low, high := 0, len(DETECT_FAMILY_COMPATIBLE)
	key := family_a < family_b ? (u32(family_a) << 8) | u32(family_b) : (u32(family_b) << 8) | u32(family_a)
	for low < high {
		middle := (low + high) / 2
		if DETECT_FAMILY_COMPATIBLE[middle] < key {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low < len(DETECT_FAMILY_COMPATIBLE) && DETECT_FAMILY_COMPATIBLE[low] == key {
		return false
	}
	if detect_range_is_basic_latin(range_a) {
		return !DETECT_FAMILY_BASIC_LATIN[family_b]
	}
	if detect_range_is_basic_latin(range_b) {
		return !DETECT_FAMILY_BASIC_LATIN[family_a]
	}
	return true
}

// detect_round3 / detect_round4 are Python's `round(x, 3)` / `round(x, 4)`: the
// correctly rounded decimal of the *binary* value, half-to-even on an exact tie.
// `%.3f` through the C library rounds the same way, and the digits it prints are
// read back as one integer over an exact power of ten, so the division that
// produces the double is the single correctly rounded operation the decimal
// requires — `f64(47) / 1000.0` is the nearest double to 0.047, which is what
// `round(0.047, 3)` answers, where multiplying by 0.001 would not be.
detect_round3 :: proc(value: f64) -> f64 {
	if math.is_nan(value) || math.is_inf(value) {
		// Python answers the value itself for nan/inf, where `%.3f` prints text.
		return value
	}
	buffer: [64]u8
	return detect_parse_decimal(fmt.bprintf(buffer[:], "%.3f", value))
}

detect_round4 :: proc(value: f64) -> f64 {
	if math.is_nan(value) || math.is_inf(value) {
		return value
	}
	buffer: [64]u8
	return detect_parse_decimal(fmt.bprintf(buffer[:], "%.4f", value))
}

// detect_parse_decimal reads a fixed-point decimal back as the one division the
// digits describe: `"0.047"` is `47 / 100`, a single correctly rounded division
// by an exactly representable power of ten.
@(private)
detect_parse_decimal :: proc(text: string) -> f64 {
	digits: u64 = 0
	fraction := 0
	negative := false
	seen_point := false
	for index := 0; index < len(text); index += 1 {
		character := text[index]
		if character == '-' {
			negative = true
		} else if character == '.' {
			seen_point = true
		} else if character >= '0' && character <= '9' {
			digits = digits * 10 + u64(character - '0')
			if seen_point {
				fraction += 1
			}
		}
	}
	value := f64(digits)
	power: f64 = 1
	for _ in 0 ..< fraction {
		power *= 10
	}
	value = value / power
	return negative ? -value : value
}

// ---------------------------------------------------------------------------
// The ten detectors (`md.py:260-870`)

// Mess_Sp is TooManySymbolOrPunctuationPlugin: a run of distinct punctuation or
// symbol characters is a third of the chunk or more.
@(private)
Mess_Sp :: struct {
	punctuation_count: int,
	symbol_count:      int,
	character_count:   int,
	last_character:    rune,
	has_last:          bool,
}

@(private)
mess_sp_feed :: proc(state: ^Mess_Sp, character: rune, info: Detect_Info) {
	state.character_count += 1
	if !(state.has_last && character == state.last_character) && (info.bits & DETECT_BITS_SAFE) == 0 {
		if (info.bits & DETECT_BITS_PUNCT) != 0 {
			state.punctuation_count += 1
		} else if (info.bits & DETECT_BITS_DIGIT) == 0 && (info.bits & DETECT_BITS_SYM) != 0 && (info.bits & DETECT_BITS_EMOTICON) == 0 {
			state.symbol_count += 2
		}
	}
	state.last_character = character
	state.has_last = true
}

@(private)
mess_sp_ratio :: proc(state: ^Mess_Sp) -> f64 {
	if state.character_count == 0 {
		return 0.0
	}
	ratio := f64(state.punctuation_count + state.symbol_count) / f64(state.character_count)
	return ratio >= 0.3 ? ratio : 0.0
}

// Mess_Ta is TooManyAccentuatedPlugin.
@(private)
Mess_Ta :: struct {
	character_count:  int,
	accentuated_count: int,
}

@(private)
mess_ta_feed :: proc(state: ^Mess_Ta, info: Detect_Info) {
	state.character_count += 1
	if (info.bits & DETECT_BITS_ACCENTUATED) != 0 {
		state.accentuated_count += 1
	}
}

@(private)
mess_ta_ratio :: proc(state: ^Mess_Ta) -> f64 {
	if state.character_count < 8 {
		return 0.0
	}
	ratio := f64(state.accentuated_count) / f64(state.character_count)
	return ratio >= 0.35 ? ratio : 0.0
}

// Mess_Up is UnprintablePlugin: an escape character fails the chunk outright.
@(private)
Mess_Up :: struct {
	unprintable_count: int,
	character_count:   int,
	has_escape:        bool,
}

@(private)
mess_up_feed :: proc(state: ^Mess_Up, character: rune, info: Detect_Info) {
	if character == 0x1b {
		state.has_escape = true
	}
	if (info.bits & DETECT_BITS_PRINTABLE) == 0 && (info.bits & DETECT_BITS_SPACE) == 0 && character != 0x1a && character != 0xfeff {
		state.unprintable_count += 1
	}
	state.character_count += 1
}

@(private)
mess_up_ratio :: proc(state: ^Mess_Up) -> f64 {
	if state.character_count == 0 {
		return 0.0
	}
	if state.has_escape {
		return 1.0
	}
	return f64(state.unprintable_count * 8) / f64(state.character_count)
}

// Mess_Sda is SuspiciousDuplicateAccentPlugin: two accentuated characters in a
// row that share an uppercase form or an unaccented form.
@(private)
Mess_Sda :: struct {
	successive_count:      int,
	character_count:       int,
	has_last:              bool,
	last_upper:            bool,
	last_unaccented:       rune,
	last_was_accentuated:  bool,
}

@(private)
mess_sda_feed :: proc(state: ^Mess_Sda, info: Detect_Info) {
	state.character_count += 1
	accentuated := (info.bits & DETECT_BITS_ACCENTUATED) != 0
	if state.has_last && accentuated && state.last_was_accentuated {
		if (info.bits & DETECT_BITS_UPPER) != 0 && state.last_upper {
			state.successive_count += 1
		}
		if info.unaccented == state.last_unaccented {
			state.successive_count += 1
		}
	}
	state.has_last = true
	state.last_upper = (info.bits & DETECT_BITS_UPPER) != 0
	state.last_unaccented = info.unaccented
	state.last_was_accentuated = accentuated
}

@(private)
mess_sda_ratio :: proc(state: ^Mess_Sda) -> f64 {
	if state.character_count == 0 {
		return 0.0
	}
	return f64(state.successive_count * 2) / f64(state.character_count)
}

// Mess_Sr is SuspiciousRange: two adjacent printable characters whose unicode
// ranges cannot be written next to each other.
@(private)
Mess_Sr :: struct {
	suspicious_count: int,
	character_count:  int,
	has_last:         bool,
	last_range:       u16,
}

@(private)
mess_sr_feed :: proc(state: ^Mess_Sr, info: Detect_Info) {
	state.character_count += 1
	if (info.bits & DETECT_BITS_SPACE) != 0 || (info.bits & DETECT_BITS_PUNCT) != 0 || (info.bits & DETECT_BITS_SAFE) != 0 {
		state.has_last = false
		state.last_range = 0
		return
	}
	if !state.has_last {
		state.has_last = true
		state.last_range = info.range
		return
	}
	if state.last_range != info.range || state.last_range == 0 {
		if detect_ranges_are_suspicious(state.last_range, info.range) {
			state.suspicious_count += 1
		}
	}
	state.last_range = info.range
}

@(private)
mess_sr_ratio :: proc(state: ^Mess_Sr) -> f64 {
	if state.character_count <= 13 {
		return 0.0
	}
	return f64(state.suspicious_count * 2) / f64(state.character_count)
}

// Mess_Sw is SuperWeirdWordPlugin: the words of a chunk that no natural writing
// produces — mixed accents, a lone glyph in a long word, inverse capitalisation,
// or a long run of non-Latin letters that is not camel-cased.
@(private)
Mess_Sw :: struct {
	word_count:                  int,
	bad_word_count:              int,
	foreign_long_count:          int,
	is_current_word_bad:         bool,
	foreign_long_watch:          bool,
	character_count:             int,
	bad_character_count:         int,
	buffer_length:               int,
	buffer_last_char_upper:      bool,
	buffer_last_char_accentuated: bool,
	buffer_accent_count:         int,
	buffer_glyph_count:          int,
	buffer_upper_count:          int,
	buffer_first_lower:          bool,
	buffer_has_non_ascii:        bool,
	buffer_last_char_ligature:   bool,
	buffer_has_internal_ligature: bool,
	is_current_word_invalid:     bool,
	invalid_word_count:          int,
}

@(private)
mess_sw_feed :: proc(state: ^Mess_Sw, character: rune, info: Detect_Info) {
	if (info.bits & DETECT_BITS_ALPHA) != 0 {
		if state.buffer_last_char_ligature {
			state.buffer_has_internal_ligature = true
		}
		state.buffer_last_char_ligature = (info.bits & DETECT_BITS_IS_LIGATURE) != 0
		if state.buffer_length == 0 {
			state.buffer_first_lower = (info.bits & DETECT_BITS_LOWER) != 0
		}
		state.buffer_length += 1
		state.buffer_last_char_upper = (info.bits & DETECT_BITS_UPPER) != 0
		if state.buffer_last_char_upper {
			state.buffer_upper_count += 1
		}
		if character >= 128 {
			state.buffer_has_non_ascii = true
		}
		state.buffer_last_char_accentuated = (info.bits & DETECT_BITS_ACCENTUATED) != 0
		if state.buffer_last_char_accentuated {
			state.buffer_accent_count += 1
		}
		if (info.bits & DETECT_BITS_IS_GLYPH) != 0 {
			state.buffer_glyph_count += 1
		} else if !state.foreign_long_watch && ((info.bits & DETECT_BITS_LATIN) == 0 || state.buffer_last_char_accentuated) {
			state.foreign_long_watch = true
		}
		return
	}
	if state.buffer_length == 0 {
		return
	}
	if (info.bits & DETECT_BITS_IS_SENTENCE_OPEN_PUNCTUATION) != 0 ||
	   ((info.bits & DETECT_BITS_IS_SUPERSCRIPT) != 0 && state.buffer_has_internal_ligature) {
		state.is_current_word_bad = true
		state.is_current_word_invalid = true
	}
	if (info.bits & DETECT_BITS_SPACE) != 0 || (info.bits & DETECT_BITS_PUNCT) != 0 || (info.bits & DETECT_BITS_SEP) != 0 {
		state.word_count += 1
		length := state.buffer_length
		state.character_count += length
		if length >= 4 {
			if f64(state.buffer_accent_count) / f64(length) >= 0.5 {
				state.is_current_word_bad = true
			} else if state.buffer_last_char_accentuated && state.buffer_last_char_upper && state.buffer_upper_count != length {
				state.foreign_long_count += 1
				state.is_current_word_bad = true
			} else if state.buffer_glyph_count == 1 {
				state.is_current_word_bad = true
				state.foreign_long_count += 1
			} else if state.buffer_has_non_ascii && state.buffer_first_lower && state.buffer_upper_count == length - 1 {
				state.foreign_long_count += 1
				state.is_current_word_bad = true
			}
		}
		if length >= 24 && state.foreign_long_watch {
			probable_camel_cased := state.buffer_upper_count > 0 && f64(state.buffer_upper_count) / f64(length) <= 0.3
			if !probable_camel_cased {
				state.foreign_long_count += 1
				state.is_current_word_bad = true
			}
		}
		if state.is_current_word_bad {
			state.bad_word_count += 1
			state.bad_character_count += length
			state.is_current_word_bad = false
		}
		if state.is_current_word_invalid {
			state.invalid_word_count += 1
			state.is_current_word_invalid = false
		}
		state.foreign_long_watch = false
		state.buffer_length = 0
		state.buffer_last_char_accentuated = false
		state.buffer_accent_count = 0
		state.buffer_glyph_count = 0
		state.buffer_upper_count = 0
		state.buffer_first_lower = false
		state.buffer_has_non_ascii = false
		state.buffer_last_char_ligature = false
		state.buffer_has_internal_ligature = false
	} else if character != '<' && character != '>' && character != '-' && character != '=' && character != '~' && character != '|' && character != '_' &&
	   (info.bits & DETECT_BITS_DIGIT) == 0 && (info.bits & DETECT_BITS_SYM) != 0 {
		state.is_current_word_bad = true
		state.buffer_length += 1
		state.buffer_last_char_accentuated = false
	}
}

@(private)
mess_sw_ratio :: proc(state: ^Mess_Sw) -> f64 {
	if state.invalid_word_count != 0 {
		return 1.0
	}
	if state.word_count <= 10 && state.foreign_long_count == 0 {
		return 0.0
	}
	return f64(state.bad_character_count) / f64(state.character_count)
}

// Mess_Cu is CjkUncommonPlugin.
@(private)
Mess_Cu :: struct {
	character_count: int,
	uncommon_count:  int,
}

@(private)
mess_cu_feed :: proc(state: ^Mess_Cu, info: Detect_Info) {
	state.character_count += 1
	if (info.bits & DETECT_BITS_COMMON_CJK) == 0 {
		state.uncommon_count += 1
	}
}

@(private)
mess_cu_ratio :: proc(state: ^Mess_Cu) -> f64 {
	if state.character_count < 4 {
		return 0.0
	}
	usage := f64(state.uncommon_count) / f64(state.character_count)
	return usage > 0.5 ? usage / 5 : 0.0
}

// Mess_Sk is SuspiciousKatakanaPlugin.
@(private)
Mess_Sk :: struct {
	katakana_count:   int,
	halfwidth_count:  int,
	cjk_count:        int,
	uncommon_count:   int,
}

@(private)
mess_sk_feed :: proc(state: ^Mess_Sk, info: Detect_Info) {
	if (info.bits & DETECT_BITS_IS_KATAKANA) != 0 {
		state.katakana_count += 1
		if (info.bits & DETECT_BITS_IS_HALFWIDTH_KATAKANA) != 0 {
			state.halfwidth_count += 1
		}
		return
	}
	state.cjk_count += 1
	if (info.bits & DETECT_BITS_COMMON_CJK) == 0 {
		state.uncommon_count += 1
	}
}

@(private)
mess_sk_ratio :: proc(state: ^Mess_Sk) -> f64 {
	if state.halfwidth_count >= 4 && state.halfwidth_count == state.katakana_count && 3 <= state.cjk_count && state.cjk_count == state.uncommon_count {
		return 1.0
	}
	return 0.0
}

// Mess_Au is ArchaicUpperLowerPlugin: upper/lower alternation inside a run of
// case-variable letters, which only archaic scripts do.
@(private)
Mess_Au :: struct {
	buffer:                    bool,
	character_count_since_sep: int,
	successive_count:          int,
	successive_final:          int,
	character_count:           int,
	last_alpha_upper:          bool,
	last_alpha_lower:          bool,
	current_ascii_only:        bool,
}

@(private)
mess_au_feed :: proc(state: ^Mess_Au, info: Detect_Info) {
	is_concerned := (info.bits & DETECT_BITS_ALPHA) != 0 && (info.bits & DETECT_BITS_CASE_VARIABLE) != 0
	chunk_sep := !is_concerned
	if chunk_sep && state.character_count_since_sep > 0 {
		if state.character_count_since_sep <= 64 && (info.bits & DETECT_BITS_DIGIT) == 0 && !state.current_ascii_only {
			state.successive_final += state.successive_count
		}
		state.successive_count = 0
		state.character_count_since_sep = 0
		state.buffer = false
		state.character_count += 1
		state.current_ascii_only = true
		return
	}
	if state.current_ascii_only && (info.bits & DETECT_BITS_IS_ASCII) == 0 {
		state.current_ascii_only = false
	}
	if state.character_count_since_sep > 0 {
		if (((info.bits & DETECT_BITS_UPPER) != 0) && state.last_alpha_lower) || (((info.bits & DETECT_BITS_LOWER) != 0) && state.last_alpha_upper) {
			if state.buffer {
				state.successive_count += 2
				state.buffer = false
			} else {
				state.buffer = true
			}
		} else {
			state.buffer = false
		}
	}
	state.character_count += 1
	state.character_count_since_sep += 1
	state.last_alpha_upper = (info.bits & DETECT_BITS_UPPER) != 0
	state.last_alpha_lower = (info.bits & DETECT_BITS_LOWER) != 0
}

@(private)
mess_au_ratio :: proc(state: ^Mess_Au) -> f64 {
	if state.character_count == 0 {
		return 0.0
	}
	return f64(state.successive_final) / f64(state.character_count)
}

// Mess_Ai is ArabicIsolatedFormPlugin.
@(private)
Mess_Ai :: struct {
	character_count: int,
	isolated_count:  int,
}

@(private)
mess_ai_feed :: proc(state: ^Mess_Ai, info: Detect_Info) {
	state.character_count += 1
	if (info.flags & DETECT_FLAG_ARABIC_ISOLATED_FORM) != 0 {
		state.isolated_count += 1
	}
}

@(private)
mess_ai_ratio :: proc(state: ^Mess_Ai) -> f64 {
	if state.character_count < 8 {
		return 0.0
	}
	return f64(state.isolated_count) / f64(state.character_count)
}

// Mess_State is one chunk's ten detectors (`md.py:943-952`).
Mess_State :: struct {
	sp:  Mess_Sp,
	ta:  Mess_Ta,
	up:  Mess_Up,
	sda: Mess_Sda,
	sr:  Mess_Sr,
	sw:  Mess_Sw,
	cu:  Mess_Cu,
	sk:  Mess_Sk,
	au:  Mess_Au,
	ai:  Mess_Ai,
}

@(private)
mess_state_sum :: proc(state: ^Mess_State) -> f64 {
	return mess_sp_ratio(&state.sp) +
	       mess_ta_ratio(&state.ta) +
	       mess_up_ratio(&state.up) +
	       mess_sda_ratio(&state.sda) +
	       mess_sr_ratio(&state.sr) +
	       mess_sw_ratio(&state.sw) +
	       mess_cu_ratio(&state.cu) +
	       mess_sk_ratio(&state.sk) +
	       mess_au_ratio(&state.au) +
	       mess_ai_ratio(&state.ai)
}

// detect_next_rune walks a decoded sequence the way CPython walks a `str`: one
// code point at a time. The decoder that produced these sequences (a single-byte
// table, the utf-8 walk) only ever writes well-formed UTF-8 below U+10000, so a
// plain decode is the same unit.
@(private)
detect_next_rune :: proc(sequence: string, index: ^int) -> rune {
	character, size := utf8.decode_rune_in_string(sequence[index^:])
	if size <= 0 {
		index^ += 1
		return rune(sequence[index^ - 1])
	}
	index^ += size
	return character
}

// detect_rune_slice is `decoded[start:stop]` for a Python `str`: a slice by
// *code point* index, returned as the byte span those code points cover.
detect_rune_slice :: proc(sequence: string, start, stop: int) -> string {
	index := 0
	count := 0
	begin := -1
	for index < len(sequence) && count < stop {
		if count == start {
			begin = index
		}
		_, size := utf8.decode_rune_in_string(sequence[index:])
		if size <= 0 {
			size = 1
		}
		index += size
		count += 1
	}
	if begin < 0 {
		return ""
	}
	return sequence[begin:index]
}

// detect_rune_count is `len(decoded_sequence)` for a Python `str`.
detect_rune_count :: proc(sequence: string) -> int {
	index := 0
	count := 0
	for index < len(sequence) {
		_, size := utf8.decode_rune_in_string(sequence[index:])
		if size <= 0 {
			size = 1
		}
		index += size
		count += 1
	}
	return count
}

// detect_mess_ratio is `mess_ratio(decoded_sequence, maximum_threshold)`
// (md.py:909-1063): the block-walk, the early stop, the trailing `\n` flush and
// the `round(..., 3)`.  The result is a float, so the ten ratios are summed in
// the reference's order — a different order is a different sum.
detect_mess_ratio :: proc(sequence: string, maximum_threshold: f64) -> f64 {
	sequence_length := detect_rune_count(sequence)

	step := 128
	if sequence_length < 511 {
		step = 32
	} else if sequence_length < 1024 {
		step = 64
	}

	// `decoded_sequence.isascii()`: seven of the ten detectors provably stay at
	// 0.0 on ASCII-only input and are not fed at all (md.py:925-928).
	pure_ascii := true
	for index := 0; index < len(sequence); index += 1 {
		if sequence[index] >= 128 {
			pure_ascii = false
			break
		}
	}

	state: Mess_State
	mean_mess_ratio := 0.0
	completed := true

	index := 0
	count := 0
	for count < sequence_length {
		block_stop := count + step
		if block_stop > sequence_length {
			block_stop = sequence_length
		}
		for count < block_stop {
			character := detect_next_rune(sequence, &index)
			info := detect_char_info(character)
			mess_up_feed(&state.up, character, info)
			mess_sw_feed(&state.sw, character, info)
			if pure_ascii {
				if (info.bits & DETECT_BITS_PRINTABLE) != 0 {
					mess_sp_feed(&state.sp, character, info)
				}
				count += 1
				continue
			}
			mess_au_feed(&state.au, info)
			if (info.bits & DETECT_BITS_PRINTABLE) != 0 {
				mess_sp_feed(&state.sp, character, info)
				mess_sr_feed(&state.sr, info)
			}
			if (info.bits & DETECT_BITS_ALPHA) != 0 {
				mess_ta_feed(&state.ta, info)
				if (info.bits & DETECT_BITS_LATIN) != 0 {
					mess_sda_feed(&state.sda, info)
				}
				if (info.bits & DETECT_BITS_IS_CJK) != 0 {
					mess_cu_feed(&state.cu, info)
					mess_sk_feed(&state.sk, info)
				} else if (info.bits & DETECT_BITS_IS_KATAKANA) != 0 {
					mess_sk_feed(&state.sk, info)
				}
				if (info.bits & DETECT_BITS_IS_ARABIC) != 0 {
					mess_ai_feed(&state.ai, info)
				}
			}
			count += 1
		}
		mean_mess_ratio = mess_state_sum(&state)
		if mean_mess_ratio >= maximum_threshold {
			completed = false
			break
		}
	}

	if completed {
		// The `for ... else` clause: the word plugin's buffer is flushed with a
		// trailing newline, and so are the two detectors the ASCII shortcut
		// decides about (md.py:1025-1044).
		newline := detect_char_info(0x0a)
		mess_sw_feed(&state.sw, 0x0a, newline)
		if !pure_ascii {
			mess_au_feed(&state.au, newline)
		}
		mess_up_feed(&state.up, 0x0a, newline)
		mean_mess_ratio = mess_state_sum(&state)
	}

	return detect_round3(mean_mess_ratio)
}
