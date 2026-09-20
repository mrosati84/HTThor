// The language model of the printed body's *guess*: `cd.py`'s coherence
// detection, which is the other half of `from_bytes`'s ranking.
//
// A candidate that survives the mess detectors (`detect_md.odin`) is scored a
// second time: its reading of the payload is split into alphabet layers, each
// layer's characters are ranked by how often they appear, and the ranking is
// compared against `FREQUENCIES` — the per-language character tables of
// `constant.py` the reference ships (`cd.py:410-467`).  The score is what
// `CharsetMatch.coherence` reports and what `CharsetMatch.__lt__` uses to break
// a chaos tie of less than 0.5% (`models.py:51-71`), so a code page whose
// reading looks like a language can win over one that only looks clean.
//
// Ported literally: `alpha_unicode_split`'s layer construction (with the
// suspicious-range test deciding which discovered range a character joins),
// `alphabet_languages`' candidate languages, `characters_popularity_compare`'s
// rank projection, and `merge_coherence_ratios`' average.  The tables come from
// `detect_generated.odin`; the language list is `FREQUENCIES`' dictionary order,
// because the stable sort of the candidate list keeps it on ties.
package http

import "core:mem"
import "core:strings"

// Detect_Coherence is one `CoherenceMatches` entry: a language (or the group
// `filter_alt_coherence_matches` folds an em-dash name into) with its ratio.
Detect_Coherence :: struct {
	key:   int, // a language index, or DETECT_MAX_COHERENCE + a group index
	ratio: f64,
}

DETECT_MAX_COHERENCE :: 128

// DETECT_COHERENCE_SLOTS is how many distinct keys `detect_coherence` merges: the
// language list plus its groups.
@(private)
DETECT_COHERENCE_SLOTS :: DETECT_MAX_COHERENCE * 2

// detect_write_lower writes one layer's characters into `builder` the way
// `alpha_unicode_split` returns them: `"".join(chars).lower()`.  A layer can be
// the whole payload, so the caller reuses one builder rather than allocating a
// lowered string per layer.
detect_write_lower :: proc(builder: ^strings.Builder, runes: []rune) {
	strings.builder_reset(builder)
	for character in runes {
		if lowered, found := detect_lower_of(character); found {
			strings.write_string(builder, lowered)
		} else {
			strings.write_rune(builder, character)
		}
	}
}

@(private)
detect_lower_of :: proc(character: rune) -> (string, bool) {
	low, high := 0, len(DETECT_LOWER_SRC)
	for low < high {
		middle := (low + high) / 2
		if DETECT_LOWER_SRC[middle] < u32(character) {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low < len(DETECT_LOWER_SRC) && DETECT_LOWER_SRC[low] == u32(character) {
		return DETECT_LOWER_DST[low], true
	}
	return "", false
}

// Detect_Layer is one `layers` entry of `alpha_unicode_split`: the unicode range
// the layer is keyed by and the characters that joined it.
@(private)
Detect_Layer :: struct {
	range: u16,
	runes: [dynamic]rune,
}

// detect_alpha_unicode_split is `alpha_unicode_split` (cd.py:282-352): the
// decoded text's letters, grouped into layers by unicode range — a character
// joins a discovered range when the two are not suspiciously successive, and the
// *target* range of the previous character is remembered so a run of one range
// does not re-test it per character.
detect_alpha_unicode_split :: proc(sequence: string, allocator: mem.Allocator) -> [dynamic]Detect_Layer {
	layers := make([dynamic]Detect_Layer, allocator)
	single_layer_key: u16 = 0
	has_single_layer := false
	multi_layer := false
	previous_range: u16 = 0
	has_previous_range := false
	previous_target: u16 = 0

	index := 0
	for index < len(sequence) {
		character := detect_next_rune(sequence, &index)
		info := detect_char_info(character)
		if (info.bits & DETECT_BITS_ALPHA) == 0 {
			continue
		}
		character_range := info.range
		if character_range == 0 {
			continue
		}
		if has_previous_range && character_range == previous_range {
			if target, found := detect_layer_index(layers[:], previous_target); found {
				append(&layers[target].runes, character)
			}
			continue
		}

		target_range: u16 = 0
		has_target := false
		if multi_layer {
			for layer in layers {
				if !detect_ranges_are_suspicious(layer.range, character_range) {
					target_range = layer.range
					has_target = true
					break
				}
			}
		} else if has_single_layer {
			if !detect_ranges_are_suspicious(single_layer_key, character_range) {
				target_range = single_layer_key
				has_target = true
			}
		}
		if !has_target {
			target_range = character_range
		}

		target, found := detect_layer_index(layers[:], target_range)
		if !found {
			append(&layers, Detect_Layer{range = target_range, runes = make([dynamic]rune, allocator)})
			target = len(layers) - 1
			if !has_single_layer {
				single_layer_key = target_range
				has_single_layer = true
			} else {
				multi_layer = true
			}
		}
		append(&layers[target].runes, character)
		previous_range = character_range
		has_previous_range = true
		previous_target = target_range
	}
	return layers
}

// detect_alpha_unicode_split_destroy releases the layers it built.
detect_alpha_unicode_split_destroy :: proc(layers: ^[dynamic]Detect_Layer) {
	for &layer in layers {
		delete(layer.runes)
	}
	delete(layers^)
}

@(private)
detect_layer_index :: proc(layers: []Detect_Layer, range: u16) -> (int, bool) {
	for layer, index in layers {
		if layer.range == range {
			return index, true
		}
	}
	return 0, false
}

// Detect_Count is one `char_counts` entry: a character of a layer and how often
// it appears.  The order is first appearance, which is what makes the stable
// sort below reproduce `Counter.most_common()`'s tie order.
@(private)
Detect_Count :: struct {
	character: rune,
	count:     int,
}

// detect_layer_counts is the stable count-desc ranking of one lowered layer.
@(private)
detect_layer_counts :: proc(layer: string, allocator: mem.Allocator) -> [dynamic]Detect_Count {
	counts := make([dynamic]Detect_Count, allocator)
	index := 0
	for index < len(layer) {
		character := detect_next_rune(layer, &index)
		found := false
		for &entry in counts {
			if entry.character == character {
				entry.count += 1
				found = true
				break
			}
		}
		if !found {
			append(&counts, Detect_Count{character = character, count = 1})
		}
	}
	// Stable insertion sort by count, descending.
	for slot := 1; slot < len(counts); slot += 1 {
		entry := counts[slot]
		position := slot
		for position > 0 && counts[position - 1].count < entry.count {
			counts[position] = counts[position - 1]
			position -= 1
		}
		counts[position] = entry
	}
	return counts
}

// detect_language_rank is `_FREQUENCIES_RANK[language].get(character)`: the
// character's popularity rank inside a language, if it has one.
@(private)
detect_language_rank :: proc(language: int, character: rune) -> (int, bool) {
	language_row := DETECT_LANGUAGES[language]
	low := int(language_row.cp_start)
	high := low + int(language_row.cp_count)
	for low < high {
		middle := (low + high) / 2
		cp := DETECT_LANG_CP[middle]
		if cp < u32(character) {
			low = middle + 1
		} else if cp > u32(character) {
			high = middle
		} else {
			return int(DETECT_LANG_RANK[middle]), true
		}
	}
	return 0, false
}

// detect_language_by_name resolves a language name (`encoding_languages`'
// answer, which comes from FREQUENCIES or is the label "Latin Based").
@(private)
detect_language_by_name :: proc(name: string) -> (int, bool) {
	for index in 0 ..< len(DETECT_LANGUAGES) {
		if DETECT_LANGUAGES[index].name == name {
			return index, true
		}
	}
	return 0, false
}

// detect_characters_popularity_compare is `characters_popularity_compare`
// (cd.py:193-279): how well a layer's character ranking matches a language, from
// 0.0 to 1.0.
detect_characters_popularity_compare :: proc(
	language: int,
	ordered: []rune,
	allocator: mem.Allocator,
) -> f64 {
	if len(ordered) == 0 {
		return 0.0
	}
	language_row := DETECT_LANGUAGES[language]
	target_count := int(language_row.count)
	ordered_count := len(ordered)
	large_alphabet := target_count > 26
	large_alphabet_threshold := f64(target_count) / 3
	expected_projection_ratio := f64(target_count) / f64(ordered_count)

	common_language_rank := make([dynamic]int, 0, ordered_count, allocator)
	defer delete(common_language_rank)
	common_ordered_rank := make([dynamic]int, 0, ordered_count, allocator)
	defer delete(common_ordered_rank)

	for popularity_rank in 0 ..< ordered_count {
		if language_rank, found := detect_language_rank(language, ordered[popularity_rank]); found {
			append(&common_language_rank, language_rank)
			append(&common_ordered_rank, popularity_rank)
		}
	}

	approved := 0
	for index in 0 ..< len(common_language_rank) {
		character_rank_in_language := common_language_rank[index]
		character_rank := common_ordered_rank[index]
		character_rank_projection := int(f64(character_rank) * expected_projection_ratio)

		if !large_alphabet && detect_abs_int(character_rank_projection - character_rank_in_language) > 4 {
			continue
		}
		if large_alphabet && f64(detect_abs_int(character_rank_projection - character_rank_in_language)) < large_alphabet_threshold {
			approved += 1
			continue
		}
		if character_rank_in_language == 0 {
			approved += 1
			continue
		}

		after_length := target_count - character_rank_in_language
		before_match_count := 0
		after_match_count := 0
		for other in 0 ..< len(common_language_rank) {
			language_rank := common_language_rank[other]
			ordered_rank := common_ordered_rank[other]
			if language_rank < character_rank_in_language {
				if ordered_rank < character_rank {
					before_match_count += 1
					if 5 * before_match_count >= 2 * character_rank_in_language {
						approved += 1
						break
					}
				}
			} else {
				if ordered_rank >= character_rank {
					after_match_count += 1
					if 5 * after_match_count >= 2 * after_length {
						approved += 1
						break
					}
				}
			}
		}
	}

	return f64(approved) / f64(ordered_count)
}

@(private)
detect_abs_int :: proc(value: int) -> int {
	return value < 0 ? -value : value
}

// detect_alphabet_languages is `alphabet_languages` (cd.py:153-190): the
// languages whose character set covers at least a fifth of the layer, most
// covering first.  The candidate languages are walked in `FREQUENCIES`' order
// and the sort is stable, so ties keep that order.
detect_alphabet_languages :: proc(
	characters: []rune,
	ignore_non_latin: bool,
	allocator: mem.Allocator,
) -> [dynamic]int {
	languages := make([dynamic]int, allocator)
	ratios := make([dynamic]f64, allocator)

	source_have_accents := false
	for character in characters {
		info := detect_char_info(character)
		if (info.bits & DETECT_BITS_ACCENTUATED) != 0 {
			source_have_accents = true
			break
		}
	}

	letters := make([dynamic]rune, 0, len(characters), allocator)
	defer delete(letters)
	for character in characters {
		found := false
		for existing in letters {
			if existing == character {
				found = true
				break
			}
		}
		if !found {
			append(&letters, character)
		}
	}

	for language in 0 ..< len(DETECT_LANGUAGES) {
		language_row := DETECT_LANGUAGES[language]
		if ignore_non_latin && !language_row.pure_latin {
			continue
		}
		if !language_row.have_accents && source_have_accents {
			continue
		}
		character_count := int(language_row.count)
		if character_count == 0 {
			continue
		}
		character_match_count := 0
		start := int(language_row.cp_start)
		stop := start + int(language_row.cp_count)
		for index in start ..< stop {
			cp := DETECT_LANG_CP[index]
			for character in letters {
				if u32(character) == cp {
					character_match_count += 1
					break
				}
			}
		}
		ratio := f64(character_match_count) / f64(character_count)
		if ratio >= 0.2 {
			append(&languages, language)
			append(&ratios, ratio)
		}
	}

	for index := 1; index < len(languages); index += 1 {
		language := languages[index]
		ratio := ratios[index]
		position := index
		for position > 0 && ratios[position - 1] < ratio {
			languages[position] = languages[position - 1]
			ratios[position] = ratios[position - 1]
			position -= 1
		}
		languages[position] = language
		ratios[position] = ratio
	}
	delete(ratios)
	return languages
}

// detect_coherence_ratio is `coherence_ratio` (cd.py:410-467): every language
// the sequence's layers can be read as, with its ratio.  Entries are keyed the
// way `filter_alt_coherence_matches` keys them — the em-dash name folded into
// its shorter form — and the list is sorted by ratio, most first.  The caller
// owns the result.
detect_coherence_ratio :: proc(
	sequence: string,
	threshold: f64,
	inclusion: []string,
	allocator: mem.Allocator,
) -> [dynamic]Detect_Coherence {
	results := make([dynamic]Detect_Coherence, allocator)
	language_results := make([dynamic]int, allocator)
	defer delete(language_results)
	sufficient_match_count := 0

	ignore_non_latin := false
	included := make([dynamic]int, allocator)
	defer delete(included)
	for name in inclusion {
		if name == "Latin Based" {
			ignore_non_latin = true
			continue
		}
		if language, found := detect_language_by_name(name); found {
			append(&included, language)
		}
	}

	layers := detect_alpha_unicode_split(sequence, allocator)
	defer detect_alpha_unicode_split_destroy(&layers)

	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)

	for &layer in layers {
		detect_write_lower(&builder, layer.runes[:])
		layer_text := strings.to_string(builder)

		if detect_rune_count(layer_text) <= DETECT_TOO_SMALL_SEQUENCE {
			continue
		}

		counts := detect_layer_counts(layer_text, allocator)
		defer delete(counts)
		ordered := make([dynamic]rune, 0, len(counts), allocator)
		defer delete(ordered)
		for entry in counts {
			append(&ordered, entry.character)
		}

		if len(included) > 0 {
			for language in included {
				ratio := detect_characters_popularity_compare(language, ordered[:], allocator)
				if detect_coherence_append(&results, &language_results, &sufficient_match_count, language, ratio, threshold) {
					break
				}
			}
		} else {
			languages := detect_alphabet_languages(ordered[:], ignore_non_latin, allocator)
			defer delete(languages)
			for language in languages {
				ratio := detect_characters_popularity_compare(language, ordered[:], allocator)
				if detect_coherence_append(&results, &language_results, &sufficient_match_count, language, ratio, threshold) {
					break
				}
			}
		}
	}

	return detect_filter_alt_coherence(results, language_results)
}

// detect_coherence_append is the body of `coherence_ratio`'s language loop: the
// ratio is kept when it clears the threshold, and the loop *stops* once three
// languages have matched at 0.8 or more.
@(private)
detect_coherence_append :: proc(
	results: ^[dynamic]Detect_Coherence,
	language_results: ^[dynamic]int,
	sufficient_match_count: ^int,
	language: int,
	ratio: f64,
	threshold: f64,
) -> bool {
	if ratio < threshold {
		return false
	}
	if ratio >= 0.8 {
		sufficient_match_count^ += 1
	}
	append(results, Detect_Coherence{key = language, ratio = detect_round4(ratio)})
	append(language_results, language)
	return sufficient_match_count^ >= 3
}

// detect_stripped_language is `language.replace("—", "")`: the language an
// em-dash spelling is an alternative of, which is the first language of its
// generated group.
@(private)
detect_stripped_language :: proc(language: int) -> int {
	group := int(DETECT_LANG_GROUP[language])
	for index in 0 ..< len(DETECT_LANGUAGES) {
		if int(DETECT_LANG_GROUP[index]) == group {
			return index
		}
	}
	return language
}

// detect_filter_alt_coherence is `filter_alt_coherence_matches` (cd.py:383-407)
// followed by the ratio sort: "We shall NOT return 'English—' in
// CoherenceMatches because it is an alternative of 'English'. This function
// only keeps the best match and remove the em-dash in it."
//
// Two entries of this *one* call that strip to the same name are the trigger;
// then every entry is re-keyed by the stripped name, in first-appearance order,
// and the best ratio of each is kept.  The key is the stripped name's language
// index, which is also what a non-colliding call keys by — so `merge_coherence`
// groups the way the reference's name-keyed dict does even when one chunk
// collapsed em-dash alternatives and another did not.
@(private)
detect_filter_alt_coherence :: proc(
	results: [dynamic]Detect_Coherence,
	language_results: [dynamic]int,
) -> [dynamic]Detect_Coherence {
	collision := false
	for index in 0 ..< len(language_results) {
		group := int(DETECT_LANG_GROUP[language_results[index]])
		for other in 0 ..< index {
			if int(DETECT_LANG_GROUP[language_results[other]]) == group {
				collision = true
				break
			}
		}
		if collision {
			break
		}
	}

	filtered := results
	if !collision {
		for index in 0 ..< len(filtered) {
			filtered[index].key = language_results[index]
		}
	} else {
		names := make([dynamic]int, 0, len(language_results), results.allocator)
		defer delete(names)
		best := make([dynamic]f64, 0, len(language_results), results.allocator)
		defer delete(best)
		for index in 0 ..< len(language_results) {
			language := detect_stripped_language(language_results[index])
			position := -1
			for name, name_index in names {
				if name == language {
					position = name_index
					break
				}
			}
			if position < 0 {
				append(&names, language)
				append(&best, results[index].ratio)
			} else if results[index].ratio > best[position] {
				best[position] = results[index].ratio
			}
		}
		collapsed := make([dynamic]Detect_Coherence, 0, len(names), results.allocator)
		for index in 0 ..< len(names) {
			append(&collapsed, Detect_Coherence{key = names[index], ratio = best[index]})
		}
		delete(filtered)
		filtered = collapsed
	}

	// `sorted(..., key=ratio, reverse=True)`: stable, most coherent first.
	for index := 1; index < len(filtered); index += 1 {
		entry := filtered[index]
		position := index
		for position > 0 && filtered[position - 1].ratio < entry.ratio {
			filtered[position] = filtered[position - 1]
			position -= 1
		}
		filtered[position] = entry
	}
	return filtered
}

// detect_coherence is the `coherence` a match reports: `merge_coherence_ratios`
// (cd.py:355-380) over the per-chunk results — the average of each key's ratios,
// rounded to four decimals — of which the best is `languages[0][1]`.
detect_coherence :: proc(entries: []Detect_Coherence) -> f64 {
	if len(entries) == 0 {
		return 0.0
	}
	keys: [DETECT_COHERENCE_SLOTS]int
	sums: [DETECT_COHERENCE_SLOTS]f64
	counts: [DETECT_COHERENCE_SLOTS]int
	used := 0
	for entry in entries {
		position := -1
		for index in 0 ..< used {
			if keys[index] == entry.key {
				position = index
				break
			}
		}
		if position < 0 {
			if used >= len(keys) {
				break
			}
			position = used
			keys[used] = entry.key
			used += 1
		}
		sums[position] += entry.ratio
		counts[position] += 1
	}
	best := 0.0
	for index in 0 ..< used {
		ratio := detect_round4(sums[index] / f64(counts[index]))
		if ratio > best {
			best = ratio
		}
	}
	return best
}
