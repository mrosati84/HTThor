// rich's emoji pass — the second of the two text transforms
// `rich.markup.render` applies to a printed string.
//
// httpie prints both of its rich consoles with `emoji` left at its default, so
// the pass runs over every *plain* piece of both:
//
//   * the usage-error block, `env.rich_error_console.print(dedent(...))`
//     (httpie/cli/argparser.py:602-612), whose string is markup as well — the
//     tags are parsed first and this pass then runs over the pieces that
//     survive (rich/markup.py:130, :157). src/cli/usage.odin applies both, in
//     that order, in `rich_markup_text`;
//   * the `http: error: …` line, `Environment.log_error`
//     (httpie/context.py:170-182), printed with `markup=False` — so no tag is
//     parsed there — and `emoji` unset, which is why the `:code:` half of the
//     rule is this one and the `[…]` half is not
//     (src/output/render.odin, `write_log_error`).
//
// `_emoji_replace` (rich/_emoji_replace.py) is, per plain piece:
//
//   * find, left to right, the leftmost match of
//     `:(\S*?)(?:(?:\-)(emoji|text))?:` — the name is the shortest non-empty
//     run of non-whitespace that lets the pattern finish, so `:a:b:` is the
//     code `a`, not `a:b`. The `\S` is Python's, not ASCII's: U+00A0, U+202F
//     and U+3000 end a name just as a space does;
//   * lower-case the name with `str.lower()` and look it up in
//     `rich._emoji_codes.EMOJI` (src/rich/emoji_generated.odin). A hit becomes
//     the table's value, plus U+FE0E for a `-text` suffix and U+FE0F for
//     `-emoji` and nothing when there is no suffix;
//   * a miss leaves the matched text exactly as it stands — and the scan
//     resumes *after* it, so `:a:b:c` is one failed code (`a:b` is not a name)
//     and not two.
//
// The lookup lower-cases the code, so the port needs the reference's
// `str.lower()` only as far as the table is reachable; `emoji_lower` below is
// that set, generated and proved by build/gen_emoji_table.py.
//
// Two things this file deliberately does not do. rich's own `emoji` parameter
// can be turned off per console (httpie never turns it off), and rich's
// `default_variant` (`emoji_variant=`) is not set by httpie's consoles either,
// so the suffixed form is the only way a selector is appended.
package rich

import "core:io"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// The pass
// ---------------------------------------------------------------------------

// emoji_replace returns `text` through rich's `_emoji_replace`, in a string the
// caller owns.
emoji_replace :: proc(text: string, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	emoji_scan({&b, emoji_write_builder}, text)
	return strings.to_string(b)
}

// emoji_write is the same pass writing straight into an `io.Writer`: the
// callers on the logging path (src/output/render.odin) hold no allocator, and
// the pass needs none — every byte it emits is either a slice of `text` or a
// string of the generated table.
emoji_write :: proc(w: io.Writer, text: string) -> io.Error {
	writer := w
	return emoji_scan({&writer, emoji_write_writer}, text)
}

// emoji_scan is `re.sub(do_replace, text)` without the regex: `position` is the
// start of the text not yet written, `at` the offset being tried as a code.
@(private)
emoji_scan :: proc(sink: Emoji_Sink, text: string) -> io.Error {
	position := 0
	at := 0
	for at < len(text) {
		if text[at] != ':' {
			at += 1
			continue
		}
		end, name, variant, ok := emoji_code_at(text, at)
		if !ok {
			// Not `:…:`, so this colon is ordinary text; the code might start
			// one byte later (`::smile:`).
			at += 1
			continue
		}
		if value, hit := emoji_value(name); hit {
			if err := sink.write(sink.handle, text[position:at]); err != .None {
				return err
			}
			if err := sink.write(sink.handle, value); err != .None {
				return err
			}
			if variant != "" {
				if err := sink.write(sink.handle, variant); err != .None {
					return err
				}
			}
			position = end
		}
		// A miss keeps the code as it stands: `position` stays where it is, so
		// the bytes of the failed code are written with the text around it, and
		// the scan resumes after the match — `:a:b:c` is one failed code
		// (`a:b`), not two.
		at = end
	}
	return sink.write(sink.handle, text[position:])
}

// Emoji_Sink is where the pass writes: a `strings.Builder` for the string form,
// an `io.Writer` for the streaming one. Two procs rather than one over an
// interface so neither caller allocates for the other's shape.
@(private)
Emoji_Sink :: struct {
	handle: rawptr,
	write:  proc(handle: rawptr, text: string) -> io.Error,
}

@(private)
emoji_write_builder :: proc(handle: rawptr, text: string) -> io.Error {
	strings.write_string(cast(^strings.Builder)handle, text)
	return .None
}

@(private)
emoji_write_writer :: proc(handle: rawptr, text: string) -> io.Error {
	_, err := io.write_string((cast(^io.Writer)handle)^, text)
	return err
}

// ---------------------------------------------------------------------------
// `RE_EMOJI` tried at one offset
// ---------------------------------------------------------------------------

// emoji_code_at matches `:(\S*?)(?:(?:\-)(emoji|text))?:` at the `:` at `at`
// and reports where the match ends, the name (without the suffix) and the
// variation selector the suffix appends.
//
// The name group is *lazy*, so for every length the bare `:` is tried before
// the `-emoji`/`-text` alternatives — and the alternatives in the order
// `(emoji|text)` lists them. A name may be empty (`::` matches, and is a miss);
// it may not hold a whitespace character, which is where the run stops.
@(private)
emoji_code_at :: proc(
	text: string,
	at: int,
) -> (
	end: int,
	name: string,
	variant: string,
	ok: bool,
) {
	separator := at + 1
	for {
		if separator < len(text) && text[separator] == ':' {
			return separator + 1, text[at + 1:separator], "", true
		}
		if separator < len(text) && text[separator] == '-' {
			// `\-(emoji|text)`, the alternation's order: 7 bytes for `-emoji:`,
			// 6 for `-text:`, and each needs its own bound — a code that ends the
			// piece is not too short for the 6-byte one.
			if separator + 7 <= len(text) && text[separator + 1:separator + 6] == "emoji" && text[separator + 6] == ':' {
				return separator + 7, text[at + 1:separator], VARIANT_EMOJI, true
			}
			if separator + 6 <= len(text) && text[separator + 1:separator + 5] == "text" &&
			   text[separator + 5] == ':' {
				return separator + 6, text[at + 1:separator], VARIANT_TEXT, true
			}
		}
		if separator >= len(text) {
			return 0, "", "", false
		}
		if emoji_is_space_at(text, separator) {
			return 0, "", "", false
		}
		separator += 1
	}
}

// VARIANT_TEXT and VARIANT_EMOJI are `variants = {"text": "\ufe0e", "emoji":
// "\ufe0f"}` (rich/_emoji_replace.py:18), appended after the value when the code
// carries that suffix.
VARIANT_TEXT :: "\xef\xb8\x8e"
VARIANT_EMOJI :: "\xef\xb8\x8f"

// emoji_is_space_at is Python's `str.isspace` at one byte offset: `\S` is the
// Unicode class, not `[^ \t\n]`, so U+00A0 and U+3000 end a name too. The offset
// may sit inside a multi-byte character — neither a continuation byte nor an
// invalid one is whitespace, and a real whitespace character is only ever met
// at its own first byte.
@(private)
emoji_is_space_at :: proc(text: string, at: int) -> bool {
	byte := text[at]
	if byte < 0x80 {
		switch byte {
		case ' ', '\t', '\n', '\r', 0x0b, 0x0c:
			return true
		case 0x1c ..= 0x1f:
			// Python's `str.isspace` counts the four file separators as space.
			return true
		}
		return false
	}
	code, _ := utf8.decode_rune_in_string(text[at:])
	switch code {
	case 0x85, 0xa0, 0x1680, 0x2000 ..= 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000:
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// The lookup
// ---------------------------------------------------------------------------

// emoji_value is `EMOJI.__getitem__(name.lower())`: the name is lower-cased and
// looked up in the generated table, and a name the table cannot hold is a miss
// before any of that runs.
//
// `emoji_name_max_runes` and the buffer are the reason a code that is longer
// than every key — `:8000:` of a URL, say — costs nothing: `str.lower()` maps
// one code point to one code point here (build/gen_emoji_table.py proves it), so
// a name with more code points than the longest key cannot become one, and one
// that fits cannot lower to more bytes than it arrived with.
@(private)
emoji_value :: proc(name: string) -> (value: string, ok: bool) {
	runes := utf8.rune_count_in_string(name)
	if runes > emoji_name_max_runes {
		return "", false
	}
	lowered: [emoji_name_max_runes * 4]u8
	length := 0
	rest := name
	for len(rest) > 0 {
		code, width := utf8.decode_rune_in_string(rest)
		code = emoji_lower(code)
		written, size := utf8.encode_rune(code)
		for i in 0 ..< size {
			lowered[length + i] = written[i]
		}
		length += size
		rest = rest[width:]
	}
	return emoji_table_lookup(string(lowered[:length]))
}

// emoji_lower is `str.lower()` for the code points a hit can turn on: the 34
// pairs of the generated table (ASCII `A`..`Z`, the uppercase forms of the
// non-ASCII letters the keys carry, and the two code points Python folds onto
// one of them: U+212A -> `k`, U+212B -> `å`). Every other code point lowers to
// something no key contains, so it is returned as it stands — which can only
// end in a miss.
@(private)
emoji_lower :: proc(code: rune) -> rune {
	low, high := 0, len(emoji_lower_map) - 1
	for low <= high {
		middle := (low + high) / 2
		switch {
		case emoji_lower_map[middle].upper < code:
			low = middle + 1
		case emoji_lower_map[middle].upper > code:
			high = middle - 1
		case:
			return emoji_lower_map[middle].lower
		}
	}
	return code
}

// emoji_table_lookup binary-searches `emoji_entries`, which the generator sorts
// by name. UTF-8 keeps code point order, so the byte order `strings.compare`
// sees is the order Python's `sorted()` wrote the entries in.
@(private)
emoji_table_lookup :: proc(name: string) -> (value: string, ok: bool) {
	low, high := 0, len(emoji_entries) - 1
	for low <= high {
		middle := (low + high) / 2
		switch strings.compare(emoji_entries[middle].name, name) {
		case -1:
			low = middle + 1
		case 1:
			high = middle - 1
		case:
			return emoji_entries[middle].value, true
		}
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Cell width
// ---------------------------------------------------------------------------

// cell_width is rich's `get_character_cell_size` (`rich/cells.py`), which is
// what the 80-cell wrap measures with — and the emoji pass runs *before* the
// wrap, so a value that is two cells wide moves the break:
//
//   * a control character is no cells at all (`0x7f <= code < 0xa0` included,
//     which is the range Python's `unicodedata` calls `Cc`);
//   * a code point of the generated `emoji_width_ranges` is the width rich's
//     Unicode table gives it — every code point an emoji value introduces, and
//     the two variation selectors, is in there, because those are the only wide
//     characters this port can print *by itself*;
//   * everything else is one cell, which is rich's answer for ASCII and the
//     port's standing approximation for the rest (docs/PARITY.md §8.18(h)).
cell_width :: proc(code: rune) -> int {
	if code < 32 || (code >= 0x7f && code < 0xa0) {
		return 0
	}
	low, high := 0, len(emoji_width_ranges) - 1
	for low <= high {
		middle := (low + high) / 2
		switch {
		case emoji_width_ranges[middle].last < code:
			low = middle + 1
		case emoji_width_ranges[middle].first > code:
			high = middle - 1
		case:
			return emoji_width_ranges[middle].cells
		}
	}
	return 1
}
