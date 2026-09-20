// The two Python predicates rich's `$COLUMNS` gate runs, over the tables the
// reference's own interpreter generated (src/cli/python_digits_generated.odin).
//
// rich sizes its console from the variable whenever the value passes
// `str.isdigit()` and then parses it with `int(columns)`
// (rich/console.py:685-694). Both are Unicode-wide and they are not the same
// predicate:
//
//   * `str.isdigit()` accepts every character with Unicode's *Digit* or
//     *Decimal* numeric type, so `$COLUMNS=٠` (ARABIC-INDIC DIGIT ZERO) is a
//     console zero cells wide and `$COLUMNS=١٢` is twelve cells (`python_is_digit`);
//   * `int()` is the narrower one — it reads a character only when it carries a
//     *decimal* value, and raises `ValueError: invalid literal for int() with
//     base 10: '…'` for anything else, which is what a superscript digit
//     (`$COLUMNS=²`) does to the reference before any console exists
//     (`python_decimal_value`; docs/PARITY.md §3.1, t_14a26d57).
//
// The value a digit run spells is `width_of_digits` (src/cli/usage.odin): it is
// the one place that has to fold these predicates into a console width, the
// fallback and the clamp included.
//
// The tables are the reference interpreter's Unicode database (14.0.0 to
// CPython 3.11.15), so a code point a later Unicode version assigned is not a
// digit here — the same reasoning src/http/python_str.odin's
// `str_is_printable` follows for the repr family.
package cli

import "core:unicode/utf8"

// python_is_digit answers CPython's `str.isdigit()` for a whole value: `False`
// for the empty string and for every value holding a character outside the
// digit set, `True` for a non-empty run of them.
//
// A byte that decodes to no rune — the environment's value need not be valid
// UTF-8 — is not a digit either, which is what Python's `surrogateescape`
// decoding of such a byte gives too (`'\udc80'.isdigit()` is `False`).
python_is_digit :: proc(value: string) -> bool {
	if value == "" {
		return false
	}
	for index := 0; index < len(value); {
		code, size := utf8.decode_rune_in_string(value[index:])
		if size <= 0 || !python_char_is_digit(code) {
			return false
		}
		index += size
	}
	return true
}

// python_char_is_digit answers `str.isdigit()` for one code point: the
// PYTHON_DIGIT_RANGES binary search. The *Digit* numeric type includes the `No`
// characters that are digits without a decimal value — the superscripts and
// subscripts — so this predicate is the wider of the two.
python_char_is_digit :: proc(code: rune) -> bool {
	ranges := PYTHON_DIGIT_RANGES[:]
	lo, hi := 0, len(ranges)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		span := ranges[mid]
		if code < span[0] {
			hi = mid
		} else if code > span[1] {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

// python_decimal_value is the half of `int()` this gate reaches:
// `unicodedata.decimal()` of one character — its value when it is a decimal
// digit (`result` true), and nothing when it is a digit with no decimal value,
// which is the `ValueError` `int()` raises for it.
//
// Only the digits matter here: `int()` also accepts surrounding whitespace, a
// sign and underscores between digits, but every one of those fails
// `str.isdigit()` first, so a value that reaches `width_of_digits` holds
// nothing else (rich/console.py:685-694).
//
// The data is PYTHON_DECIMAL_RANGES, whose every range carries the value of its
// first code point (`base`) and steps by one from there; the generator refuses
// to emit a range that does not.
python_decimal_value :: proc(code: rune) -> (value: int, decimal: bool) {
	ranges := PYTHON_DECIMAL_RANGES[:]
	lo, hi := 0, len(ranges)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		span := ranges[mid]
		if code < span[0] {
			hi = mid
		} else if code > span[1] {
			lo = mid + 1
		} else {
			return int(span[2]) + int(code - span[0]), true
		}
	}
	return 0, false
}
