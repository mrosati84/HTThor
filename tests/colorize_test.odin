// Golden-corpus test for the Pygments colour emulation in src/output/colorize.odin.
//
// httpie's coloured output *is* whatever Pygments writes, so the honest test is a
// byte comparison against the vendored golden corpus in tests/golden/colorize
// (recorded from the reference's Pygments output). The corpus is plain test data:
// the generator that produced it is not part of this tree.
//
// `odin test tests` must be run from the repository root: the golden directory
// is addressed relative to the working directory, like the Makefile's targets.
package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import "src:output"

COLORIZE_GOLDEN_DIR :: "tests/golden/colorize"

// Longest escaped byte run quoted in a failure message.
MESSAGE_QUOTE_LIMIT :: 240

// Bytes of context quoted before the first mismatching byte.
MESSAGE_CONTEXT_BEFORE :: 40

@(test)
test_colorize_goldens :: proc(t: ^testing.T) {
	manifest_path := strings.concatenate({COLORIZE_GOLDEN_DIR, "/manifest.tsv"}, context.temp_allocator)
	manifest, read_err := os.read_entire_file_from_path(manifest_path, context.temp_allocator)
	if read_err != nil {
		testing.expectf(
			t,
			false,
			"cannot read %s: %v\n(the vendored corpus is missing; run `odin test tests` from the repository root)",
			manifest_path,
			read_err,
		)
		return
	}

	declared_total := -1
	seen_styles := make(map[string]bool, 64, context.temp_allocator)
	cases := 0
	mismatches := 0

	for line in strings.split_lines(string(manifest), context.temp_allocator) {
		if len(line) == 0 {
			continue
		}
		if line[0] == '#' {
			// `# cases\t<N>` is the corpus size the generator claims.
			fields := strings.split(line, "\t", context.temp_allocator)
			if len(fields) == 2 && strings.trim_space(fields[0]) == "# cases" {
				if value, ok := parse_decimal_int(fields[1]); ok {
					declared_total = value
				}
			}
			continue
		}

		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) != 6 {
			testing.expectf(t, false, "malformed manifest line: %q", line)
			continue
		}
		name, lexer_name, part, style_name := fields[0], fields[1], fields[2], fields[3]

		style, found := output.style_lookup(style_name)
		if !found {
			testing.expectf(t, false, "%s: unknown style %q", name, style_name)
			continue
		}
		seen_styles[style_name] = true

		input_path := strings.concatenate({COLORIZE_GOLDEN_DIR, "/", fields[4]}, context.temp_allocator)
		input, input_err := os.read_entire_file_from_path(input_path, context.temp_allocator)
		if input_err != nil {
			testing.expectf(t, false, "%s: cannot read %s: %v", name, input_path, input_err)
			continue
		}
		expected_path := strings.concatenate({COLORIZE_GOLDEN_DIR, "/", fields[5]}, context.temp_allocator)
		expected, expected_err := os.read_entire_file_from_path(expected_path, context.temp_allocator)
		if expected_err != nil {
			testing.expectf(t, false, "%s: cannot read %s: %v", name, expected_path, expected_err)
			continue
		}

		lexed, lexed_ok := golden_lex(lexer_name, string(input), context.temp_allocator)
		if !lexed_ok {
			testing.expectf(t, false, "%s: unknown lexer %q", name, lexer_name)
			continue
		}

		escapes := style.header
		if part == "body" {
			escapes = style.body
		}

		rendered := strings.builder_make(context.temp_allocator)
		if err := output.render_tokens(strings.to_writer(&rendered), lexed.tokens[:], escapes); err != .None {
			testing.expectf(t, false, "%s: render_tokens failed: %v", name, err)
			continue
		}
		got := strings.to_string(rendered)
		if part == "head" {
			// httpie's format_headers/format_metadata end with str.strip()
			// (httpie/output/formatters/colors.py:81-103).
			got = strings.trim_space(got)
		}

		cases += 1
		if got == string(expected) {
			continue
		}
		mismatches += 1
		at := first_difference(string(expected), got)
		window := max(0, at - MESSAGE_CONTEXT_BEFORE)
		testing.expectf(
			t,
			false,
			"%s (style=%s, lexer=%s, part=%s): byte mismatch at %d of %d\n  want from %d: %s\n  got  from %d: %s",
			name,
			style_name,
			lexer_name,
			part,
			at,
			len(expected),
			window,
			quote_bytes(window_from(string(expected), at), context.temp_allocator),
			window,
			quote_bytes(window_from(got, at), context.temp_allocator),
		)
	}

	testing.expectf(
		t,
		declared_total < 0 || cases == declared_total,
		"manifest declares %d cases but %d were exercised",
		declared_total,
		cases,
	)
	testing.expectf(t, mismatches == 0, "%d of %d colour cases did not match the reference bytes", mismatches, cases)
	testing.expectf(t, cases > 0, "no colour cases were exercised")
	// Every advertised --style must be covered by at least one case.
	for style in output.STYLE_CHOICES {
		testing.expectf(t, seen_styles[style], "style %q has no golden case", style)
	}
	fmt.printf("colorize goldens: %d cases, %d mismatches\n", cases, mismatches)
}

// golden_lex runs the lexer named by the manifest, which is the same selection
// httpie makes in httpie/output/formatters/colors.py:64-79.
@(private)
golden_lex :: proc(name: string, text: string, allocator: mem.Allocator) -> (output.Lexed, bool) {
	switch name {
	case "json":
		return output.lex_json(text, allocator), true
	case "text":
		return output.lex_text(text, allocator), true
	case "headers_pygments":
		return output.lex_headers(text, output.Lex_Variant.Pygments_Http, allocator), true
	case "headers_simplified":
		return output.lex_headers(text, output.Lex_Variant.Simplified_Head, allocator), true
	case "headers_simplified_precise":
		return output.lex_headers(text, output.Lex_Variant.Simplified_Precise, allocator), true
	case "metadata":
		return output.lex_metadata(text, false, allocator), true
	case "metadata_precise":
		return output.lex_metadata(text, true, allocator), true
	}
	return {}, false
}

// first_difference is the index of the first mismatching byte, or the length of
// the shorter value when one is a prefix of the other.
@(private)
first_difference :: proc(a: string, b: string) -> int {
	limit := min(len(a), len(b))
	for i := 0; i < limit; i += 1 {
		if a[i] != b[i] {
			return i
		}
	}
	return limit
}

// window_from is the tail of s to quote in a failure message: a little context
// before the first difference, so the diff is visible even in a long body.
@(private)
window_from :: proc(s: string, at: int) -> string {
	start := max(0, at - MESSAGE_CONTEXT_BEFORE)
	if start >= len(s) {
		return ""
	}
	return s[start:]
}

// quote_bytes renders bytes the way a terminal escape dump reads: ESC as \x1b,
// control bytes as \xNN, everything else verbatim, truncated so one mismatch
// does not print a whole response body.
@(private)
quote_bytes :: proc(s: string, allocator: mem.Allocator) -> string {
	hex := "0123456789abcdef"
	builder := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if i == MESSAGE_QUOTE_LIMIT {
			fmt.wprintf(strings.to_writer(&builder), "... (%d bytes total)", len(s))
			break
		}
		switch c {
		case '\x1b':
			strings.write_string(&builder, "\\x1b")
		case '\n':
			strings.write_string(&builder, "\\n")
		case '\r':
			strings.write_string(&builder, "\\r")
		case '\\':
			strings.write_string(&builder, "\\\\")
		case:
			if c < 0x20 || c == 0x7f {
				strings.write_string(&builder, "\\x")
				strings.write_byte(&builder, hex[c >> 4])
				strings.write_byte(&builder, hex[c & 0xf])
			} else {
				strings.write_byte(&builder, c)
			}
		}
	}
	return strings.to_string(builder)
}

@(private)
parse_decimal_int :: proc(s: string) -> (value: int, ok: bool) {
	text := strings.trim_space(s)
	if text == "" {
		return 0, false
	}
	for i := 0; i < len(text); i += 1 {
		if text[i] < '0' || text[i] > '9' {
			return 0, false
		}
		value = value * 10 + int(text[i] - '0')
	}
	return value, true
}
