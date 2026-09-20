// `detect_encoding`: the printed body's guess when the message declares no
// charset.
//
// httpie's `smart_decode(content, encoding)` (encoding.py:34-42) decodes with
// the message's charset when it has one and with `detect_encoding(content)` when
// it does not, and `detect_encoding` (:16-31) is *not* latin-1 and not "utf-8
// with replacement": at or under `charset_normalizer.constant.TOO_SMALL_SEQUENCE`
// (32 bytes) it is utf-8, and above it it is `charset_normalizer.from_bytes(
// content).best().encoding` — a guess, produced by the library's whole detection
// pipeline.  This file is that pipeline:
//
//   - `api.py:50-807`'s candidate loop: a BOM/SIG and a charset *declared inside
//     the body* are prioritised, then `ascii`, `utf_8`, then every code page of
//     `IANA_SUPPORTED_MB_FIRST` (multibyte first, IANA order inside each group);
//   - each candidate is decoded, sliced into `cut_sequence_chunks` chunks and
//     measured by `detect_mess_ratio` (`detect_md.odin`); a candidate whose mean
//     chaos has reached the threshold is dropped and its similar code pages are
//     skipped too;
//   - the survivors are scored again by `detect_coherence_ratio`
//     (`detect_cd.odin`) and appended to the result list, and the *first* of the
//     lowest-chaos results wins (`models.py:51-71`'s comparator, then a stable
//     sort), so the iteration order is part of the answer whenever two code
//     pages are equally clean — which, for a body that is nothing but letters,
//     is exactly how `cp1125` comes out of a 33-byte body ending `0xff` and
//     `cp037` out of `b'a' * 40 + b'\x81'`;
//   - the two shortcuts are kept: a prioritised candidate with a chaos of
//     exactly 0.0 ends the search at once, and the first candidate that is clean
//     and has a language with a coherence of 0.5 or more puts the loop in
//     "definitive" mode, where later candidates from other language families are
//     skipped.
//
// The boundary this port draws is *decoders*, not the rule: it evaluates every
// candidate whose bytes it can read — `ascii`, the utf-8 family and the
// single-byte code pages `charset_generated.odin` holds a table for — and treats
// the reference's multibyte/stateful code pages (the `Other` entries) the way
// the reference treats a payload its own decoder refuses: a hard failure, which
// is exact for every payload that does not decode under them.  A payload that
// *is* GB2312/Big5/Shift-JIS encoded keeps the pre-existing gap
// docs/PARITY.md section 3.4 records — the port has no decoder for the codec the
// reference would then print with.
//
// What the port *does* model of those code pages, exactly, is the bookkeeping
// that changes which single-byte candidate wins: `utf_16`/`utf_32`/`utf_7` are
// skipped without a BOM, an unsupported candidate still counts as `tested`, and
// the language-family skip of definitive mode uses the reference's own
// `encoding_languages` table.
package http

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// Detect_Match is one candidate the loop kept, in `CharsetMatch`'s terms
// (models.py:11-98): the encoding, its mean chaos, its coherence and
// `len(str(match))` — the last one only because `multi_byte_usage` compares
// readings that decoded to different lengths.
//
// `fingerprint` is not the reference's `hash(str(match))` (Python's string hash
// is salted per process) but what that hash is *used* for: `CharsetMatches
// .append` folds a match whose reading and chaos are those of one already kept
// into that one as a submatch (`match.fingerprint == item.fingerprint and
// match.chaos == item.chaos`, models.py:306-310).  Two readings are equal
// exactly when their decodes are, so the key is a hash of the decoded bytes —
// zero when the payload is too large to fold (`len(item.raw) < TOO_BIG_SEQUENCE`
// gates it, which a payload of `DETECT_TOO_BIG_SEQUENCE` bytes fails).
Detect_Match :: struct {
	encoding:    string,
	chaos:       f64,
	coherence:   f64,
	str_len:     int,
	bom:         bool,
	fingerprint: u64,
}

// DETECT_MATCH_CAPACITY is more than the loop can keep: at most one entry per
// code page plus the prioritised ones.
DETECT_MATCH_CAPACITY :: 128

// DETECT_CHUNK_CAPACITY is more than `cut_sequence_chunks` can yield: `steps`
// is 5, so `range(start, length, length / 5)` holds at most six offsets.
DETECT_CHUNK_CAPACITY :: 8

// Detect_Kept is one `CharsetMatches.append` call's bookkeeping: which candidate
// was appended (or folded into an existing entry as a submatch) and which result
// it answers for.  `results[encoding_iana]` — the BOM/SIG lookup — resolves
// through `could_be_from_charset`, which includes the folded submatches, so the
// map is what that lookup reads.
@(private)
Detect_Kept :: struct {
	name:         string,
	result_index: int,
}

// Detect_Results is the result list of `from_bytes(content)`.
Detect_Results :: struct {
	count: int,
	items: [DETECT_MATCH_CAPACITY]Detect_Match,
}

// Detect_Fallbacks are `fallback_ascii` / `fallback_u8` / `fallback_specified`
// (api.py:206-208): the entries used when *no* candidate survived.
@(private)
Detect_Fallbacks :: struct {
	ascii:     Detect_Match,
	utf8:      Detect_Match,
	specified: Detect_Match,
	has_ascii: bool,
	has_utf8:  bool,
	has_spec:  bool,
}

// detect_encoding is httpie's `detect_encoding(content)` (encoding.py:16-31):
// utf-8 at or under the threshold, `from_bytes(content).best().encoding` above
// it, and utf-8 when the library found nothing at all.
detect_encoding :: proc(content: string, allocator: mem.Allocator) -> string {
	if len(content) <= DETECT_TOO_SMALL_SEQUENCE {
		return "utf_8"
	}
	results := detect_matches(content, allocator)
	if results.count == 0 {
		return "utf_8"
	}
	return results.items[0].encoding
}

// detect_matches is `from_bytes(content)` with the reference's own defaults
// (steps 5, chunk_size 512, threshold 0.2, language_threshold 0.1,
// preemptive_behaviour and enable_fallback on): the kept candidates, in
// `best()`'s order.
detect_matches :: proc(content: string, allocator: mem.Allocator) -> Detect_Results {
	result: Detect_Results
	length := len(content)

	if length == 0 {
		// `from_bytes(b"")` is one utf_8 match with a chaos of 0.0 (api.py:94-99).
		result.count = 1
		result.items[0] = Detect_Match{encoding = "utf_8"}
		return result
	}

	steps := 5
	chunk_size := 512
	if length <= chunk_size * steps {
		steps = 1
		chunk_size = length
	}
	if steps > 1 && length / steps < chunk_size {
		chunk_size = length / steps
	}
	is_too_large := length >= DETECT_TOO_BIG_SEQUENCE

	// The payload's own hints: a charset declared *inside* the bytes is
	// `prioritized_encodings`' first entry, a BOM/SIG is inserted before it
	// (api.py:153-228).
	specified := detect_any_specified_encoding(content)
	sig_encoding, sig_length := detect_identify_sig_or_bom(content)

	// A `utf_16`/`utf_32` BOM decides the answer outright where the payload after
	// it has that codec's own shape, and the port has no decoder for either: the
	// reference decodes such a payload with the mark's codec and returns
	// `results[sig_encoding]` — the search ends there — as soon as that candidate
	// passes its chaos probe, which a payload whose length is a whole number of
	// code units is the case for.  What the port cannot reproduce is the
	// *measurement* (the chaos and coherence of the decoded reading), so the
	// match it answers with carries none; what it must not do is fall through to
	// the single-byte candidates, which is where a `utf_16` body would otherwise
	// land.  `utf_7` and gb18030's SIG are *not* treated this way: their codecs
	// fail on payloads the reference hands them in practice (a `+/v8` mark
	// followed by ASCII text is `ascii` to the reference, not `utf_7`), so those
	// two stay part of the decoder gap and the loop skips them.
	if sig_encoding == "utf_16" || sig_encoding == "utf_32" {
		unit := sig_encoding == "utf_16" ? 2 : 4
		if (length - sig_length) % unit == 0 {
			result.count = 1
			result.items[0] = Detect_Match{encoding = sig_encoding, bom = true}
			return result
		}
	}

	prioritized: [8]string
	prioritized_count := 0
	if sig_encoding != "" {
		prioritized[prioritized_count] = sig_encoding
		prioritized_count += 1
	}
	if specified != "" {
		prioritized[prioritized_count] = specified
		prioritized_count += 1
	}
	prioritized[prioritized_count] = "ascii"
	prioritized_count += 1
	if !detect_name_in(prioritized[:prioritized_count], "utf_8") {
		prioritized[prioritized_count] = "utf_8"
		prioritized_count += 1
	}

	tested: [DETECT_MATCH_CAPACITY]string
	tested_count := 0
	soft_skip: [DETECT_MATCH_CAPACITY]string
	soft_skip_count := 0

	results: [DETECT_MATCH_CAPACITY]Detect_Match
	results_count := 0
	kept: [DETECT_MATCH_CAPACITY]Detect_Kept
	kept_count := 0
	early: [DETECT_MATCH_CAPACITY]Detect_Match
	early_count := 0

	fallbacks: Detect_Fallbacks

	definitive_match_found := false
	definitive_target_languages: [8]string
	definitive_target_count := 0
	post_definitive_sb_success_count := 0
	POST_DEFINITIVE_SB_CAP :: 7

	// `cut_sequence_chunks`' offsets: `range(0 if not bom else len(sig), length,
	// int(length / steps))` (api.py:386-390).
	offsets: [DETECT_CHUNK_CAPACITY]int
	offset_count := 0
	offset_step := length / steps
	offset_start := 0
	if sig_encoding != "" {
		offset_start = sig_length
	}
	for offset := offset_start; offset < length; offset += offset_step {
		if offset_count >= len(offsets) {
			break
		}
		offsets[offset_count] = offset
		offset_count += 1
	}
	max_chunk_gave_up := offset_count / 4
	if max_chunk_gave_up < 2 {
		max_chunk_gave_up = 2
	}

	// The chunks a candidate yields are measured *and* scored for coherence, so
	// they all have to be in hand at once.  A chunk is a slice of the payload
	// decoded on the spot: one byte per character for a single-byte code page,
	// at most as many bytes as it covers for utf-8.
	chunk_room := 0
	for offset_index in 0 ..< offset_count {
		chunk_room += min(chunk_size, length - offsets[offset_index])
	}
	scratch := make([]u8, 4 * chunk_room + 64, allocator)
	defer delete(scratch, allocator)

	total_candidates := prioritized_count + len(DETECT_CANDIDATES)
	for candidate_index in 0 ..< total_candidates {
		name: string
		multi_byte := false
		kind := Detect_Port_Kind.Unsupported
		if candidate_index < prioritized_count {
			name = prioritized[candidate_index]
			multi_byte, kind = detect_candidate_class(name)
		} else {
			candidate := DETECT_CANDIDATES[candidate_index - prioritized_count]
			name = candidate.name
			multi_byte = candidate.multi_byte
			kind = candidate.kind
		}

		if detect_name_in(tested[:tested_count], name) {
			continue
		}
		tested[tested_count] = name
		tested_count += 1

		// A BOM/SIG only ever is a mark of the utf-8 family, gb18030 or
		// utf-16/utf-32, so `strip_sig_or_bom` is the reference's
		// `should_strip_sig_or_bom` here: utf_16/utf_32 keep their mark.
		bom_or_sig_available := sig_encoding != "" && sig_encoding == name
		strip_sig_or_bom := bom_or_sig_available && name != "utf_16" && name != "utf_32"
		// The bytes a decode starts from: the payload, minus a mark the codec
		// is asked to strip.
		body_offset := strip_sig_or_bom ? sig_length : 0

		if (name == "utf_16" || name == "utf_32") && !bom_or_sig_available {
			continue
		}
		if name == "utf_7" && !bom_or_sig_available {
			continue
		}
		if detect_name_in(soft_skip[:soft_skip_count], name) {
			continue
		}

		// `is_multi_byte_encoding`'s decoder probe and the decode that follows
		// both fail for a code page this port has no table for: the reference's
		// hard failure.  The boundary is in the file header.
		if kind == .Unsupported {
			continue
		}

		if definitive_match_found {
			if !detect_languages_intersect(detect_targets(name), definitive_target_languages[:definitive_target_count]) {
				continue
			}
		}
		if definitive_match_found && !multi_byte && post_definitive_sb_success_count >= POST_DEFINITIVE_SB_CAP {
			continue
		}

		// A single-byte candidate of a regular-size payload is not decoded as a
		// whole before the chunk probing: one byte is one character, so the
		// chunk slices decode to exactly the chunks the whole payload would
		// have given, and a candidate the probing rejects never pays for it
		// (api.py:332-340).
		deferred_decoding := !multi_byte && !is_too_large

		decoded := ""
		has_decoded := false
		decoded_length := 0

		if kind == .Utf8 {
			// The eager, strict, whole-payload decode of a multibyte candidate
			// (api.py:342-374).
			bytes := content[body_offset:]
			if strip_sig_or_bom && strings.has_prefix(bytes, "\xef\xbb\xbf") {
				// utf_8_sig's own decoder drops a leading BOM as well.
				bytes = bytes[3:]
			}
			if !detect_utf8_is_valid(bytes) {
				continue
			}
			decoded = bytes
			decoded_length = detect_rune_count(bytes)
			has_decoded = true
		} else if is_too_large {
			// api.py:343-351: the first 500000 bytes are decoded eagerly — the
			// reading is thrown away (it stays `None`), so this is the
			// validation of the head of the payload.
			stop := min(length, 500000)
			start := min(body_offset, stop)
			if !detect_bytes_are_defined(name, content[start:stop]) {
				continue
			}
		}

		chunks: [DETECT_CHUNK_CAPACITY]string
		chunk_count := 0
		cursor := 0
		lazy_str_hard_failure := false
		hard_failure := false
		early_stop_count := 0

		if multi_byte {
			// `cut_sequence_chunks`' byte-slicing branch for a multibyte decoder
			// (utils.py:401-452): the raw slice read with `errors="ignore"`, plus
			// the bad-cut adjustment when a slice starts mid-sequence.
			for offset_index in 0 ..< offset_count {
				if chunk_count >= len(chunks) {
					break
				}
				offset := offsets[offset_index]
				chunk_end := offset + chunk_size
				if chunk_end > length + 8 {
					continue
				}
				cut_end := min(chunk_end, length)
				cut := content[offset:cut_end]
				if bom_or_sig_available && !strip_sig_or_bom {
					cut, _ = strings.concatenate({content[:sig_length], cut}, context.temp_allocator)
				}
				chunk, _ := detect_write_utf8_ignore(cut, scratch[cursor:])
				if offset > 0 && has_decoded {
					partial := min(min(chunk_size, 16), len(chunk))
					prefix := chunk[:partial]
					expected_offset := offset * decoded_length / length
					search_start := max(0, expected_offset - 32768)
					search_end := min(decoded_length, expected_offset + 32768)
					_, found_nearby := detect_find(decoded, prefix, search_start, search_end)
					_, in_payload := detect_find(decoded, prefix, 0, len(decoded))
					if !found_nearby && !in_payload {
						for previous := offset; previous > offset - 4 && previous >= 0; previous -= 1 {
							retry_cut := content[previous:cut_end]
							if bom_or_sig_available && !strip_sig_or_bom {
								retry_cut, _ = strings.concatenate({content[:sig_length], retry_cut}, context.temp_allocator)
							}
							retry_chunk, _ := detect_write_utf8_ignore(retry_cut, scratch[cursor:])
							retry_partial := min(min(chunk_size, 16), len(retry_chunk))
							if _, ok := detect_find(decoded, retry_chunk[:retry_partial], 0, len(decoded)); ok {
								chunk = retry_chunk
								break
							}
						}
					}
				}
				chunks[chunk_count] = chunk
				chunk_count += 1
				cursor += len(chunk)
			}
		} else {
			// The deferred (regular-size) and eager-truncated (huge) single-byte
			// probing: raw slices decoded strictly, one byte per character.
			// A chunk that does not decode ends the walk — a hard failure when
			// the decoding was deferred, and `lazy_str_hard_failure` when the
			// payload is huge (api.py:445-468).
			for offset_index in 0 ..< offset_count {
				if chunk_count >= len(chunks) {
					break
				}
				offset := offsets[offset_index]
				chunk_end := offset + chunk_size
				// The trailing-slice guard is the *byte-slicing* branch's
				// (utils.py:401-403).  A deferred single-byte candidate slices
				// `sequences[i:i + chunk_size]` with no such guard
				// (utils.py:394-396), so its last offset — `int(length / steps)`
				// short of the end — still yields the tail of the payload, one
				// or more bytes of it, and that short chunk is measured with the
				// rest: a 2561-byte payload's candidate is the mean of six
				// chunks, five of 512 bytes and one of one byte.
				if !deferred_decoding && chunk_end > length + 8 {
					continue
				}
				cut := content[offset:min(chunk_end, length)]
				if len(cut) == 0 {
					break
				}
				chunk, ok := detect_write_single_byte(name, cut, scratch[cursor:])
				if !ok {
					if deferred_decoding {
						// Identical outcome and bookkeeping to the whole-payload
						// decode failing: the candidate is out.
						hard_failure = true
					} else {
						early_stop_count = max_chunk_gave_up
						lazy_str_hard_failure = true
					}
					break
				}
				chunks[chunk_count] = chunk
				chunk_count += 1
				cursor += len(chunk)
			}
			if hard_failure {
				continue
			}
		}

		ratios: [DETECT_CHUNK_CAPACITY]f64
		ratio_count := 0
		for chunk_index in 0 ..< chunk_count {
			ratio := detect_mess_ratio(chunks[chunk_index], 0.2)
			ratios[ratio_count] = ratio
			ratio_count += 1
			if ratio >= 0.2 {
				early_stop_count += 1
			}
			if early_stop_count >= max_chunk_gave_up || (bom_or_sig_available && !strip_sig_or_bom) {
				break
			}
		}
		// `sum(md_ratios) / len(md_ratios)`, summed in the reference's order.
		mean_mess_ratio := 0.0
		if ratio_count > 0 {
			sum := 0.0
			for ratio_index in 0 ..< ratio_count {
				sum += ratios[ratio_index]
			}
			mean_mess_ratio = sum / f64(ratio_count)
		}

		// A huge single-byte payload that survived so far has its tail checked
		// as a whole (api.py:474-491).
		if !lazy_str_hard_failure && is_too_large && !multi_byte && mean_mess_ratio < 0.2 && early_stop_count < max_chunk_gave_up {
			if !detect_bytes_are_defined(name, content[50000:]) {
				continue
			}
		}

		if mean_mess_ratio >= 0.2 || early_stop_count >= max_chunk_gave_up {
			// A soft failure: this candidate and its similar code pages are out.
			for other in detect_similar(name) {
				if soft_skip_count < len(soft_skip) && !detect_name_in(soft_skip[:soft_skip_count], other) {
					soft_skip[soft_skip_count] = other
					soft_skip_count += 1
				}
			}
			if (name == "ascii" || name == "utf_8" || (specified != "" && name == specified)) && !lazy_str_hard_failure {
				// The payload is decoded in full before a fallback is kept, and
				// its chaos is the *threshold*, not the measurement
				// (api.py:506-551).
				if !has_decoded {
					if !detect_bytes_are_defined(name, content[body_offset:]) {
						continue
					}
					decoded_length = length
					has_decoded = true
				}
				entry := Detect_Match{
					encoding = name,
					chaos    = 0.2,
					bom      = bom_or_sig_available,
					str_len  = decoded_length,
				}
				if specified != "" && name == specified {
					fallbacks.specified = entry
					fallbacks.has_spec = true
				} else if name == "ascii" {
					fallbacks.ascii = entry
					fallbacks.has_ascii = true
				} else {
					fallbacks.utf8 = entry
					fallbacks.has_utf8 = true
				}
			}
			continue
		}

		if deferred_decoding {
			// The candidate passed: the whole payload is decoded now, which is
			// also the check that no byte later in it is undefined
			// (api.py:554-574).
			if !detect_bytes_are_defined(name, content) {
				continue
			}
			decoded_length = length
			has_decoded = true
		} else if kind == .Single_Byte {
			// The huge single-byte case: the head was decoded eagerly and the
			// tail was checked above, so the payload is known to decode whole
			// and one byte is one character.  The reference keeps no reading
			// (`decoded_payload` stays `None`) and `len(str(match))` decodes it
			// lazily when the comparator needs the length.
			decoded_length = length
			has_decoded = true
		}

		targets := detect_targets(name)

		// The coherence pass, chunk by chunk; `ascii` is skipped
		// (api.py:603-619).
		coherence_entries: [DETECT_COHERENCE_SLOTS]Detect_Coherence
		coherence_count := 0
		if name != "ascii" {
			for chunk_index in 0 ..< chunk_count {
				entries := detect_coherence_ratio(chunks[chunk_index], 0.1, targets, allocator)
				for entry in entries {
					if coherence_count < len(coherence_entries) {
						coherence_entries[coherence_count] = entry
						coherence_count += 1
					}
				}
				delete(entries)
			}
		}
		coherence := detect_coherence(coherence_entries[:coherence_count])

		// `str(match)`, as a hash: the key `CharsetMatches.append` folds equal
		// readings by (`len(item.raw) < TOO_BIG_SEQUENCE` gates the folding).
		fingerprint: u64
		if length < DETECT_TOO_BIG_SEQUENCE {
			if kind == .Single_Byte {
				if entry, class := charset_entry(name); class == .Text {
					fingerprint = detect_fingerprint_single_byte(entry, content)
				}
			} else {
				fingerprint = detect_fingerprint_text(decoded)
			}
		}

		match := Detect_Match{
			encoding    = name,
			chaos       = mean_mess_ratio,
			coherence   = coherence,
			str_len     = decoded_length,
			bom         = bom_or_sig_available,
			fingerprint = fingerprint,
		}
		detect_keep_match(&results, &results_count, &kept, &kept_count, name, match, length)

		if definitive_match_found && !multi_byte && mean_mess_ratio < 0.02 {
			post_definitive_sb_success_count += 1
		}

		if (name == "ascii" || name == "utf_8" || (specified != "" && name == specified)) && mean_mess_ratio < 0.1 {
			if mean_mess_ratio == 0.0 {
				// "If md says nothing to worry about, then... stop immediately!"
				result.count = 1
				result.items[0] = match
				return result
			}
			duplicate := false
			if length < DETECT_TOO_BIG_SEQUENCE {
				for index in 0 ..< early_count {
					if early[index].fingerprint == match.fingerprint && early[index].chaos == match.chaos {
						duplicate = true
						break
					}
				}
			}
			if !duplicate && early_count < len(early) {
				early[early_count] = match
				early_count += 1
			}
		}

		if early_count > 0 && (specified == "" || detect_name_in(tested[:tested_count], specified)) && detect_name_in(tested[:tested_count], "ascii") && detect_name_in(tested[:tested_count], "utf_8") {
			result.count = 1
			result.items[0] = detect_best_match(early[:early_count], length)
			return result
		}

		if !definitive_match_found && !multi_byte {
			// `best_coherence` is the top of `cd_ratios_merged`
			// (api.py:702-705), i.e. the *merged* per-language average —
			// `merge_coherence_ratios` sorts them, `CharsetMatch.coherence` is
			// `self._languages[0][1]`, and the two are the same number.  The
			// maximum over the *per-chunk* entries is a different, larger one
			// (a single chunk can read Hebrew at 0.57 while the payload
			// averages 0.41), and using it fires the mode too early.
			best_coherence := coherence
			if best_coherence >= 0.5 && detect_name_in(tested[:tested_count], "ascii") && detect_name_in(tested[:tested_count], "utf_8") {
				definitive_match_found = true
				for language in targets {
					if definitive_target_count < len(definitive_target_languages) && !detect_name_in(definitive_target_languages[:definitive_target_count], language) {
						definitive_target_languages[definitive_target_count] = language
						definitive_target_count += 1
					}
				}
			}
		}

		if name == sig_encoding {
			// A BOM/SIG candidate that decoded ends the search
			// (api.py:755-764): `results[encoding_iana]`, which resolves a name
			// through `could_be_from_charset` — the submatches included, which
			// is why the answer is the entry this candidate was folded into when
			// it was one.
			for kept_index in 0 ..< kept_count {
				if kept[kept_index].name == name {
					result.count = 1
					result.items[0] = results[kept[kept_index].result_index]
					return result
				}
			}
		}
	}

	if results_count == 0 {
		// api.py:766-792: the specified encoding first, then utf_8, then ascii.
		found := false
		entry := Detect_Match{}
		switch {
		case fallbacks.has_spec:
			entry = fallbacks.specified
			found = true
		case fallbacks.has_utf8:
			entry = fallbacks.utf8
			found = true
		case fallbacks.has_ascii:
			entry = fallbacks.ascii
			found = true
		}
		if found {
			results[0] = entry
			results_count = 1
		}
	}

	for index in 0 ..< results_count {
		result.items[index] = results[index]
	}
	result.count = results_count
	detect_sort(result.items[:result.count], length)
	return result
}

// detect_keep_match is `CharsetMatches.append` (models.py:294-311): a match whose
// reading and chaos equal an already-kept one becomes a submatch of it — the
// entry is *not* added, and the candidate is remembered as answering for that
// entry (`results[iana_name]` sees it through `could_be_from_charset`).  A
// payload of `DETECT_TOO_BIG_SEQUENCE` bytes or more never folds, which is how
// the reference keeps RAM: it also carries no fingerprint at all.
@(private)
detect_keep_match :: proc(
	results: ^[DETECT_MATCH_CAPACITY]Detect_Match,
	count: ^int,
	kept: ^[DETECT_MATCH_CAPACITY]Detect_Kept,
	kept_count: ^int,
	name: string,
	match: Detect_Match,
	raw_length: int,
) -> int {
	if raw_length < DETECT_TOO_BIG_SEQUENCE {
		for index in 0 ..< count^ {
			if results[index].fingerprint == match.fingerprint && results[index].chaos == match.chaos {
				if kept_count^ < len(kept) {
					kept[kept_count^] = Detect_Kept{name = name, result_index = index}
					kept_count^ += 1
				}
				return index
			}
		}
	}
	index := count^
	if index < len(results) {
		results[index] = match
		count^ = index + 1
	}
	if kept_count^ < len(kept) {
		kept[kept_count^] = Detect_Kept{name = name, result_index = index}
		kept_count^ += 1
	}
	return index
}

// detect_fingerprint_text hashes a decoded reading.
@(private)
detect_fingerprint_text :: proc(text: string) -> u64 {
	hash := DETECT_FNV_OFFSET
	for byte in transmute([]u8)text {
		hash = (hash ~ u64(byte)) * DETECT_FNV_PRIME
	}
	return hash
}

// detect_fingerprint_single_byte hashes `str(bytes, name)` without building it:
// one code page table entry per byte, written as the UTF-8 the decoder would
// have produced.
@(private)
detect_fingerprint_single_byte :: proc(entry: ^Charset_Entry, bytes: string) -> u64 {
	hash := DETECT_FNV_OFFSET
	for byte in transmute([]u8)bytes {
		code := entry.decode[byte]
		if code == CHARSET_UNDEFINED {
			continue
		}
		encoded, size := utf8.encode_rune(rune(code))
		for index in 0 ..< size {
			hash = (hash ~ u64(encoded[index])) * DETECT_FNV_PRIME
		}
	}
	return hash
}

@(private)
DETECT_FNV_OFFSET :: u64(0xcbf29ce484222325)

@(private)
DETECT_FNV_PRIME :: u64(0x100000001b3)

// detect_best_match is `CharsetMatches.best()`: the first entry of the stable
// chaos sort.
@(private)
detect_best_match :: proc(matches: []Detect_Match, raw_length: int) -> Detect_Match {
	best := matches[0]
	for index in 1 ..< len(matches) {
		if detect_match_less(matches[index], best, raw_length) {
			best = matches[index]
		}
	}
	return best
}

// detect_sort is `sorted(results)`: `CharsetMatch.__lt__` (models.py:51-71) and
// a stable sort, so an equal pair keeps the order the loop appended it in.
@(private)
detect_sort :: proc(matches: []Detect_Match, raw_length: int) {
	for index := 1; index < len(matches); index += 1 {
		entry := matches[index]
		position := index
		for position > 0 && detect_match_less(entry, matches[position - 1], raw_length) {
			matches[position] = matches[position - 1]
			position -= 1
		}
		matches[position] = entry
	}
}

// detect_match_less is `a < b` for two matches: chaos decides, unless the two
// chaos values are within 0.5% of each other — then the more coherent reading
// wins, and if the coherence is close too, the reading that decoded as many
// multibyte characters as possible is preferred.
@(private)
detect_match_less :: proc(a, b: Detect_Match, raw_length: int) -> bool {
	chaos_difference := detect_abs_f64(a.chaos - b.chaos)
	coherence_difference := detect_abs_f64(a.coherence - b.coherence)
	if chaos_difference < 0.005 && coherence_difference > 0.02 {
		return a.coherence > b.coherence
	} else if chaos_difference < 0.005 && coherence_difference <= 0.02 {
		if raw_length >= DETECT_TOO_BIG_SEQUENCE {
			return a.chaos < b.chaos
		}
		return detect_multi_byte_usage(a, raw_length) > detect_multi_byte_usage(b, raw_length)
	}
	return a.chaos < b.chaos
}

@(private)
detect_abs_f64 :: proc(value: f64) -> f64 {
	return value < 0 ? -value : value
}

// detect_multi_byte_usage is `CharsetMatch.multi_byte_usage`: `1 - len(str) /
// len(raw)`, 0.0 for an empty payload.
@(private)
detect_multi_byte_usage :: proc(match: Detect_Match, raw_length: int) -> f64 {
	if raw_length == 0 {
		return 0.0
	}
	return 1.0 - f64(match.str_len) / f64(raw_length)
}

// ---------------------------------------------------------------------------
// The payload's own hints

// detect_identify_sig_or_bom is `identify_sig_or_bom` (utils.py:278-293): the
// first mark of `ENCODING_MARKS` the payload starts with, and its length.
detect_identify_sig_or_bom :: proc(content: string) -> (name: string, length: int) {
	for mark in DETECT_MARKS {
		if strings.has_prefix(content, mark.mark) {
			return mark.name, len(mark.mark)
		}
	}
	return "", 0
}

// detect_any_specified_encoding is `any_specified_encoding` (utils.py:225-250):
// a charset declared inside the first 8192 bytes of the payload itself.  The
// reference decodes that zone with ASCII (`errors='ignore'`) and runs
// `RE_POSSIBLE_ENCODING_INDICATION` over it; a byte above 0x7F is dropped there
// and can never be part of a match here, so the scan reads the raw zone.
detect_any_specified_encoding :: proc(content: string) -> string {
	zone := content[:min(len(content), 8192)]
	if !detect_bytes_contain_fold(zone, "coding") && !detect_bytes_contain_fold(zone, "charset") {
		return ""
	}
	index := 0
	for index < len(zone) {
		keyword_length := 0
		if detect_match_keyword(zone[index:], "encoding") {
			keyword_length = len("encoding")
		} else if detect_match_keyword(zone[index:], "charset") {
			keyword_length = len("charset")
		} else if detect_match_keyword(zone[index:], "coding") {
			keyword_length = len("coding")
		}
		if keyword_length == 0 {
			index += 1
			continue
		}
		position := index + keyword_length
		separators := 0
		for position < len(zone) && separators < 10 && (zone[position] == ':' || zone[position] == '=' || zone[position] == ' ') {
			separators += 1
			position += 1
		}
		if separators == 0 {
			index += 1
			continue
		}
		if position < len(zone) && (zone[position] == '"' || zone[position] == '\'') {
			position += 1
		}
		name_start := position
		for position < len(zone) && detect_byte_is_name(zone[position]) {
			position += 1
		}
		if position == name_start {
			index += 1
			continue
		}
		name_end := position
		if position < len(zone) && (zone[position] == '"' || zone[position] == '\'') {
			position += 1
		}
		spelling := detect_lower_bytes(zone[name_start:name_end], context.temp_allocator)
		if iana, found := detect_iana_name(spelling); found {
			return iana
		}
		index = position
	}
	return ""
}

@(private)
detect_byte_is_name :: proc(byte: u8) -> bool {
	return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_'
}

@(private)
detect_match_keyword :: proc(text: string, keyword: string) -> bool {
	if len(text) < len(keyword) {
		return false
	}
	for index in 0 ..< len(keyword) {
		byte := text[index]
		if byte >= 'A' && byte <= 'Z' {
			byte = byte + ('a' - 'A')
		}
		if byte != keyword[index] {
			return false
		}
	}
	return true
}

@(private)
detect_bytes_contain_fold :: proc(text: string, needle: string) -> bool {
	if len(needle) > len(text) {
		return false
	}
	for start in 0 ..= len(text) - len(needle) {
		if detect_match_keyword(text[start:], needle) {
			return true
		}
	}
	return false
}

// detect_lower_bytes is the ASCII lower-casing and `-` to `_` collapsing
// `iana_name` applies to the spelling before the lookup (utils.py:300-311).
@(private)
detect_lower_bytes :: proc(text: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	for byte in transmute([]u8)text {
		if byte >= 'A' && byte <= 'Z' {
			strings.write_byte(&builder, byte + ('a' - 'A'))
		} else if byte == '-' {
			strings.write_byte(&builder, '_')
		} else {
			strings.write_byte(&builder, byte)
		}
	}
	return strings.to_string(builder)
}

// detect_iana_name is `_IANA_NAMES.get(spelling)`, over the sorted table.
@(private)
detect_iana_name :: proc(spelling: string) -> (string, bool) {
	low, high := 0, len(DETECT_IANA_NAMES)
	for low < high {
		middle := (low + high) / 2
		if strings.compare(DETECT_IANA_NAMES[middle].spelling, spelling) < 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low < len(DETECT_IANA_NAMES) && DETECT_IANA_NAMES[low].spelling == spelling {
		return DETECT_IANA_NAMES[low].name, true
	}
	return "", false
}

// ---------------------------------------------------------------------------
// The candidate's reading

// detect_candidate_class is a name's multi-byte class and whether the port can
// decode it.  Every name of the loop's own list comes from the generated table;
// a prioritised name (a BOM/SIG, or a spelling declared inside the payload) may
// not be in it, and the port's own codec registry answers for those.
detect_candidate_class :: proc(name: string) -> (multi_byte: bool, kind: Detect_Port_Kind) {
	for candidate in DETECT_CANDIDATES {
		if candidate.name == name {
			return candidate.multi_byte, candidate.kind
		}
	}
	if entry, class := charset_entry(name); class == .Text {
		switch entry.kind {
		case .Single_Byte:
			return false, .Single_Byte
		case .Utf8, .Utf8_Sig:
			return true, .Utf8
		case .Other:
			return true, .Unsupported
		}
	}
	return true, .Unsupported
}

// detect_similar is `IANA_SUPPORTED_SIMILAR[name]`.
detect_similar :: proc(name: string) -> []string {
	for row in DETECT_SIMILAR {
		if row.name == name {
			return row.similar
		}
	}
	return nil
}

// detect_targets is `encoding_languages` / `mb_encoding_languages` for a name.
detect_targets :: proc(name: string) -> []string {
	for row in DETECT_TARGETS {
		if row.name == name {
			return row.languages
		}
	}
	return nil
}

@(private)
detect_languages_intersect :: proc(a, b: []string) -> bool {
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	for left in a {
		for right in b {
			if left == right {
				return true
			}
		}
	}
	return false
}

@(private)
detect_name_in :: proc(names: []string, name: string) -> bool {
	for existing in names {
		if existing == name {
			return true
		}
	}
	return false
}

// detect_bytes_are_defined is the single-byte codec's strictness over a byte
// range: an undefined byte is what `str(bytes, name)` raises on.
detect_bytes_are_defined :: proc(name: string, bytes: string) -> bool {
	entry, class := charset_entry(name)
	if class != .Text || entry.kind != .Single_Byte {
		return false
	}
	for byte in transmute([]u8)bytes {
		if entry.decode[byte] == CHARSET_UNDEFINED {
			return false
		}
	}
	return true
}

// detect_write_single_byte writes `str(bytes, name)` for a single-byte code page
// into `buffer` — the codec's own strict decode, undefined bytes included — and
// returns the text as a view of it.
detect_write_single_byte :: proc(
	name: string,
	bytes: string,
	buffer: []u8,
) -> (text: string, ok: bool) {
	entry, class := charset_entry(name)
	if class != .Text || entry.kind != .Single_Byte {
		return "", false
	}
	used := 0
	for byte in transmute([]u8)bytes {
		code := entry.decode[byte]
		if code == CHARSET_UNDEFINED {
			return "", false
		}
		encoded, size := utf8.encode_rune(rune(code))
		if used + size > len(buffer) {
			return "", false
		}
		copy(buffer[used:used + size], encoded[:size])
		used += size
	}
	return string(buffer[:used]), true
}

// detect_utf8_is_valid is `str(bytes, "utf-8")` succeeding: CPython's own
// well-formedness, which `str_utf8_seq_len` answers.
detect_utf8_is_valid :: proc(bytes: string) -> bool {
	index := 0
	for index < len(bytes) {
		size := str_utf8_seq_len(bytes[index:])
		if size <= 0 {
			return false
		}
		index += size
	}
	return true
}

// detect_write_utf8_ignore writes `bytes.decode("utf-8", "ignore")` into
// `buffer`: the well-formed sequences copied through, an ill-formed maximal
// subpart dropped (the same span `charset_decode_utf8` writes U+FFFD for).
detect_write_utf8_ignore :: proc(bytes: string, buffer: []u8) -> (text: string, all_valid: bool) {
	if detect_utf8_is_valid(bytes) {
		if len(bytes) > len(buffer) {
			return "", false
		}
		copy(buffer[:len(bytes)], bytes)
		return string(buffer[:len(bytes)]), true
	}
	used := 0
	index := 0
	for index < len(bytes) {
		size := str_utf8_seq_len(bytes[index:])
		if size > 0 {
			if used + size <= len(buffer) {
				copy(buffer[used:used + size], bytes[index:index + size])
				used += size
			}
			index += size
			continue
		}
		failure := str_utf8_decode_failure(bytes[index:])
		span := failure.end - failure.start
		if span <= 0 {
			span = 1
		}
		index += span
	}
	return string(buffer[:used]), false
}

// detect_find is `haystack.find(needle, start, stop)`.
detect_find :: proc(haystack: string, needle: string, start, stop: int) -> (int, bool) {
	if len(needle) == 0 {
		return start, true
	}
	first := start
	if first < 0 {
		first = 0
	}
	last := stop
	if last > len(haystack) {
		last = len(haystack)
	}
	index := first
	for index + len(needle) <= last {
		if haystack[index:index + len(needle)] == needle {
			return index, true
		}
		index += 1
	}
	return 0, false
}
