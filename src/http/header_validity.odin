// requests' `check_header_validity`: the last rule of httpie's request
// preparation, and the one the port did not have.
//
// `requests` validates every header it prepares. `PreparedRequest.prepare` runs
// `prepare_url`, then `prepare_headers`, then the cookies, the body and the auth
// (requests/models.py:438-443), and `prepare_headers` calls
// `check_header_validity(header)` on every pair of the dict it was handed
// (models.py:563-572), before anything is rendered or sent. A header the CLI's
// items, the session or httpie's defaults produced can therefore end the run:
// httpie's own error handler prints the exception and exits 1 (core.py:54-65),
// it is not one of the `usage:` errors the argument parser raises.
//
//     requests/utils.py:1087-1119   check_header_validity, _validate_header_part
//     requests/_internal_utils.py:13-19
//         _VALID_HEADER_NAME_RE_STR  = "^[^:\s][^:\r\n]*\Z"
//         _VALID_HEADER_VALUE_RE_BYTE = "^\S[^\r\n]*\Z|^\Z"
//
// The **name** is validated as a `str`, the **value** as **bytes** — httpie's
// `finalize_headers` encodes every value with the default codec before requests
// ever sees it (client.py:203), which is also why the refusal prints a `b'…'`
// repr for a value and a `'…'` repr for a name. Three consequences the port
// records here:
//
//   * a *value* may carry any non-ASCII character: the byte-level `\S` accepts
//     every byte above 0x7f, so `X-Note: caf<U+00E9>` and `X-Note: <CJK>` are
//     headers requests sends (`nonascii-*`, `latin1-*` in
//     build/probe_header_validity.py). Non-ASCII in a *name* is a different
//     question, decided later by CPython's http.client — the ascii encode of
//     `putheader` (Header.str_value, src/http/python_str.odin, §3.6);
//   * the leading-whitespace half of the rule is only reachable for a *name*.
//     `finalize_headers` strips every *value* with Python's `str.strip()` before
//     this rule runs, and the ASCII whitespace its byte-level `\S` would refuse
//     is a subset of what the strip removes, so a finalized value cannot start
//     with one. The half the port implements for a value is the return
//     character one — the ASCII-whitespace test stays because it is the rule,
//     not because a request can reach it;
//   * `-p b` and `-p H` change nothing: the rule runs while the request is
//     prepared, whether or not either half of it is printed.
//
// The dict the rule walks is *not* httpie's repeated-name list. requests merges
// the request's headers into its own session's first
// (utils.py:merge_setting:294-341 → structures.py:CaseInsensitiveDict), and a
// case-insensitive dict collapses a repeated name to one entry: the *last*
// spelling, the *last* value, at the position the name first appeared. A run
// that repeats a name therefore validates its last value only — `X-Note: a\Nb`
// followed by `X-Note: ok` is sent as it stands, while the same pair the other
// way round is refused (`repeat-bad-then-ok`, `repeat-order-distinct` in
// build/probe_header_validity.py). That is what this walk reproduces: it visits
// each name once, in first-appearance order, with the last pair stored under
// it, and `check_header_validity`'s own order inside a pair — name first, then
// value — decides which half the message names.
package http

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// Invalid_Header_Part is which half of the header tuple the rule refused. The
// two halves have their own validator, their own repr in the message and their
// own word for it (`header name` / `header value`).
Invalid_Header_Part :: enum {
	Name,
	Value,
}

// request_invalid_header runs the rule over the request's finalized headers and
// answers the first pair it refuses: the offending text — a slice of the
// request's own list, which the caller owns for as long as the request lives —
// and which half of the tuple it is. `found` false means every header passed.
//
// The caller runs it where requests does: after the URL is prepared and before
// the body (src/session/context.odin, `build_request`), so a request that fails
// here sends nothing and prints nothing but the error. The list it walks is the
// one the strip of httpie's `finalize_headers` has already rewritten, in the
// order the session's headers and the items were merged.
request_invalid_header :: proc(req: ^Request) -> (text: string, part: Invalid_Header_Part, found: bool) {
	for index in 0 ..< len(req.headers) {
		if header_name_seen_before(req, index) {
			// The merged dict holds one entry per name: the first occurrence's
			// place, the last one's spelling and value.
			continue
		}
		last := index
		for later in index + 1 ..< len(req.headers) {
			if strings.equal_fold(req.headers[later].name, req.headers[index].name) {
				last = later
			}
		}
		// `check_header_validity` validates the name and then the value, so a
		// pair that fails both reports the name.
		if invalid_header_name(req.headers[last].name) {
			return req.headers[last].name, .Name, true
		}
		if invalid_header_value(req.headers[last].value) {
			return req.headers[last].value, .Value, true
		}
	}
	return "", .Name, false
}

// invalid_header_message renders the exception httpie prints for a refused
// header: `handle_generic_error` writes `f'{type(e).__name__}: {msg}'` through
// `env.log_error` (core.py:54-65, context.py:170-182), and the exception's own
// message is requests' (`_validate_header_part`, utils.py:1114-1119). The
// caller owns the result.
invalid_header_message :: proc(
	text: string,
	part: Invalid_Header_Part,
	allocator: mem.Allocator,
) -> string {
	repr := part == .Name ? python_str_repr(text, allocator) : python_bytes_repr(text, allocator)
	defer delete(repr, allocator)
	kind := part == .Name ? "name" : "value"
	return fmt.aprintf(
		"InvalidHeader: Invalid leading whitespace, reserved character(s), or return " +
		"character(s) in header %s: %s",
		kind,
		repr,
		allocator = allocator,
	)
}

// ---------------------------------------------------------------------------
// The wire's own check: CPython's `http.client.putheader`
// ---------------------------------------------------------------------------
//
// The rule above runs while the request is *prepared*; this one runs while the
// head is *written*, on every header line, and it is why a request that rule
// passed can still end the run: `prepare_headers` validates the merged dict,
// i.e. the *last* value of each repeated name (§3.1), while `putheader`
// validates every value it writes.
//
//     CPython 3.11.15 Lib/http/client.py:144-145
//         _is_legal_header_name    = re.compile(rb"[^:\s][^:\r\n]*").fullmatch
//         _is_illegal_header_value = re.compile(rb"\n(?![ \t])|\r(?![ \t\n])").search
//     Lib/http/client.py:1281-1305        putheader
//     urllib3/connection.py:276-289       the same two patterns, copied for
//         interpreters below 3.11.16 (this host is 3.11.15) and used by
//         `_tunnel`'s CONNECT headers; a request's own lines go through
//         CPython's `putheader` — `urllib3.connection._HTTPConnection.putheader`
//         (connection.py:477-487) only forwards to `super()`
//
// `putheader` encodes the *name* ascii first, then validates it; a value it
// still holds as a `str` is encoded latin-1 and validated as those bytes, a
// value that is already bytes is validated as it stands. httpie's
// `finalize_headers` encoded every value (client.py:203), so the values that
// arrive here are bytes — except the bearer token its auth plugin assigns after
// the headers were finalized, which is the one `str` — and the exception names
// those bytes, with the same `b'…'` repr the rule above uses
// (python_bytes_repr): `ValueError: Invalid header value b'a\nb'`. httpie's
// handler prints that as `http: error: ValueError: …` and exits 1 (core.py:54-65).
//
// **What can reach it, given that `check_header_validity` ran first.** A value
// the rule above validated carries no `\r` or `\n` at all, so this check can
// only refuse the value of a repeated name that the merged dict did *not* hold —
// its first occurrence. Its two lookahead exceptions are the legal obs-folds
// (`\n` or `\r` followed by a space or a tab; the `\r` half also allows a
// following `\n`), which is why `header-valid-value-fold-live` sends a folded
// value while `\n` + `b` is refused. A **name** cannot be refused here at all:
// the name that reaches `putheader` has already passed requests'
// `^[^:\s][^:\r\n]*\Z` (as a str — a superset of this byte pattern's first
// character class, whose `\s` is the *bytes* one and therefore narrower) and
// `request_encode_check(…, .Ascii)`, which is the ascii encode `putheader`
// performs before the match. The name half is implemented all the same: it is
// half of one rule, and a caller that reached the wire without the prepare-time
// check would need it. `build/probe_wire_header.py` is the measurement —
// reference and port, 31 shapes including the ones neither can refuse.

// Wire_Header_Error is the `ValueError` CPython's `http.client` raises while the
// request head is written. `text` is the offending name or value *as the bytes
// `putheader` validated them* (latin-1 for the one value httpie still holds as a
// str), and the request owns it — request_destroy releases it. `part` decides
// the message's word and its repr, exactly as it does for the rule above.
Wire_Header_Error :: struct {
	failed: bool,
	part:   Invalid_Header_Part,
	text:   string,
}

// wire_header_refusal runs the rule over one header line as the transport is
// about to write it: `name` is the header's name (already proven ascii by
// request_encode_check, which is the encode `putheader` performs first) and
// `value` is the bytes it would put on the wire — the request's own bytes for a
// value requests encoded, the latin-1 encoding of it for the one httpie still
// holds as a `str`. The name is examined first, the way `putheader` does it, and
// the answer borrows from the arguments: the caller clones what it reports (the
// transport's `value` may be a temporary of its own loop).
wire_header_refusal :: proc(
	name: string,
	value: string,
) -> (
	text: string,
	part: Invalid_Header_Part,
	found: bool,
) {
	if wire_header_name_illegal(name) {
		return name, .Name, true
	}
	if wire_header_value_illegal(value) {
		return value, .Value, true
	}
	return "", .Name, false
}

// wire_header_refuse records one refusal on the request and answers the error
// the transport returns. The text is cloned: the transport's own copy (the
// latin-1 encoding of a `str` value) is a temporary of the header loop, while
// the message is printed by the session, after the send has failed.
wire_header_refuse :: proc(req: ^Request, text: string, part: Invalid_Header_Part) -> Error {
	if !clone_into(&req.wire_error.text, text, req.allocator) {
		return .Out_Of_Memory
	}
	req.wire_error.failed = true
	req.wire_error.part = part
	return .Wire_Header_Refused
}

// wire_header_message renders the exception httpie prints for it, through the
// same handler the other rule's message goes through. The caller owns the
// result.
wire_header_message :: proc(err: ^Wire_Header_Error, allocator: mem.Allocator) -> string {
	repr := python_bytes_repr(err.text, allocator)
	defer delete(repr, allocator)
	kind := err.part == .Name ? "name" : "value"
	return fmt.aprintf("ValueError: Invalid header %s %s", kind, repr, allocator = allocator)
}

// wire_header_name_illegal is the `[^:\s][^:\r\n]*` fullmatch. `\s` is the
// *bytes* pattern's — `[ \t\n\r\f\v]` and nothing else — so a byte above 0x7f is
// not whitespace to it; the string is the ascii-encoded name, and the caller has
// already refused a name that is not ascii.
@(private = "file")
wire_header_name_illegal :: proc(name: string) -> bool {
	if len(name) == 0 {
		return true
	}
	switch name[0] {
	case ':', 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20:
		return true
	}
	for index in 1 ..< len(name) {
		switch name[index] {
		case ':', '\r', '\n':
			return true
		}
	}
	return false
}

// wire_header_value_illegal is the `\n(?![ \t])|\r(?![ \t\n])` search: a line
// feed that is not followed by a space or a tab — the end of the value
// included, where the lookahead has nothing to match — or a carriage return
// followed by neither one of those nor by a line feed. A CR before a LF is legal
// *at the CR*; the LF after it is then examined on its own, which is what
// refuses `a\r\nb`.
@(private = "file")
wire_header_value_illegal :: proc(value: string) -> bool {
	for index in 0 ..< len(value) {
		switch value[index] {
		case '\n':
			if index + 1 >= len(value) {
				return true
			}
			next := value[index + 1]
			if next != ' ' && next != '\t' {
				return true
			}
		case '\r':
			if index + 1 >= len(value) {
				return true
			}
			switch value[index + 1] {
			case ' ', '\t', '\n':
			case:
				return true
			}
		}
	}
	return false
}

// header_name_seen_before answers whether an earlier header of the list carries
// the same name: the names are matched case-insensitively, the way requests'
// `CaseInsensitiveDict` keys and httpie's own `HTTPHeadersDict` do.
@(private = "file")
header_name_seen_before :: proc(req: ^Request, index: int) -> bool {
	for earlier in 0 ..< index {
		if strings.equal_fold(req.headers[earlier].name, req.headers[index].name) {
			return true
		}
	}
	return false
}

// invalid_header_name is the str validator, `^[^:\s][^:\r\n]*\Z`: a name is
// refused when it is empty (the first class needs one character), when its
// first character is whitespace, when it carries a `:` **anywhere** — the
// pattern refuses the colon in both classes, not only as the leading character
// — or when it carries a carriage return or a line feed anywhere. `\s` here is
// Python's whitespace, the same set the value strip uses (header_value_rune).
//
// The interior colon is reachable, which the port used to claim it was not:
// `\:` is an `Escaped` token to the item grammar (`httpie/cli/argtypes.py:110-130`
// — the escapable set is the union of every item separator's characters, `:`,
// `;`, `@` and `=`, `httpie/cli/constants.py:15-71`), so the separator scan
// skips it and the *next* separator is the one that splits the item.
// `a\:b:v` is therefore the header name `a:b` with the value `v`, and requests
// refuses it (build/probe_header_validity.py: `name-interior-colon-*`); a name
// that is only `:` reaches the same test (`\::v`), and so does the probe cell
// that found it, `\\:k` (`\\\:k:\\\:v`, build/probe_item_backslash_pairs.py).
//
// The first character is read as a *character*, not a byte: `\s` is the str
// pattern's, so U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F,
// U+3000 and U+0085 are whitespace to it too, and a name starting with one is
// refused (build/probe_header_validity.py: name-nbsp, name-ideographic-space,
// name-nel, name-file-separator, name-line-separator; the whole set, plus three
// characters that are *not* whitespace, is measured once in
// build/probe_header_name_whitespace.py).
@(private = "file")
invalid_header_name :: proc(name: string) -> bool {
	if len(name) == 0 {
		return true
	}
	// Both `[^:\s]` and `[^:\r\n]*` exclude the colon, so one test covers the
	// leading and the interior case alike.
	if strings.contains_rune(name, ':') {
		return true
	}
	is_space, _ := header_value_rune(name)
	if is_space {
		return true
	}
	return header_text_carries_return(name)
}

// invalid_header_value is the bytes validator, `^\S[^\r\n]*\Z|^\Z`: the empty
// value passes, a carriage return or a line feed anywhere refuses it, and a
// first byte that is ASCII whitespace refuses it too. `\s` is the *bytes*
// pattern's — `[ \t\n\r\f\v]` and nothing else — so no byte above 0x7f is
// whitespace here, unlike in the name's pattern: a non-ASCII value is a value
// requests accepts.
//
// The value is UTF-8 text in the port (there is no separate decoded copy —
// src/http/python_str.odin), and none of the ASCII whitespace bytes can start a
// *finalized* value, so the first-byte test is unreachable; it is written out
// because it is half of the rule and because a caller that ran the check before
// the strip would need it.
@(private = "file")
invalid_header_value :: proc(value: string) -> bool {
	if len(value) == 0 {
		return false
	}
	switch value[0] {
	case 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20:
		return true
	}
	return header_text_carries_return(value)
}

// header_text_carries_return answers the `[^\r\n]*` of both patterns. A byte
// test is enough: neither 0x0d nor 0x0a can appear inside a multi-byte UTF-8
// sequence, so the byte and character answers are the same.
@(private = "file")
header_text_carries_return :: proc(text: string) -> bool {
	return strings.contains_rune(text, '\r') || strings.contains_rune(text, '\n')
}

// python_bytes_repr renders a header value the way CPython's `bytes.__repr__`
// does, quotes included: the value reaches requests as bytes and both reprs end
// up inside the exception's message (`b'line one\nline two'`).
//
// The rules are `Objects/bytesobject.c:bytes_repr`: `'` unless the value
// carries a single quote and no double one, in which case the delimiter is `"`
// and that is the one escaped; `\\`, the delimiter, `\t`, `\n` and `\r` are the
// backslash escapes; every byte from 0x20 to 0x7e is itself; everything else —
// the C0 controls and *every* byte above 0x7f, which is why a value with a
// non-ASCII character shows its UTF-8 bytes — is `\xNN`, in lower case.
@(private = "file")
python_bytes_repr :: proc(s: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	quote := byte('\'')
	if strings.contains_rune(s, '\'') && !strings.contains_rune(s, '"') {
		quote = '"'
	}
	strings.write_string(&builder, "b")
	strings.write_byte(&builder, quote)
	for index in 0 ..< len(s) {
		c := s[index]
		switch {
		case c == quote || c == '\\':
			strings.write_byte(&builder, '\\')
			strings.write_byte(&builder, c)
		case c == '\t':
			strings.write_string(&builder, "\\t")
		case c == '\n':
			strings.write_string(&builder, "\\n")
		case c == '\r':
			strings.write_string(&builder, "\\r")
		case c >= 0x20 && c < 0x7f:
			strings.write_byte(&builder, c)
		case:
			fmt.sbprintf(&builder, "\\x%02x", c)
		}
	}
	strings.write_byte(&builder, quote)
	return strings.to_string(builder)
}

// python_str_repr renders a string the way CPython's `str.__repr__` does,
// quotes included (`'X-No\nte'`, `'\xa0X-Note'`). The delimiter follows the
// same rule as the bytes repr's.
//
// A printable character is itself, with `\\`, the delimiter, `\t`, `\n` and
// `\r` escaped and every other character below 0x80 — the C0 controls and DEL —
// as `\xNN`. Above 0x7f the port escapes the code points Python's repr escapes
// for the reason the string in hand can carry one here: Python's whitespace (the
// leading character of a name this rule refuses is exactly that set, see
// invalid_header_name — `'\xa0X-Note'`, `'\u3000X-Note'`, and the whitespace of
// a *host*, which the exception message quotes), each as `\xNN` or `\uNNNN` by
// its code point, and a byte that is not valid UTF-8 as the lone surrogate
// CPython's surrogateescape decode made of it (`\udcXX`). Everything else above
// 0x7f is copied: Python keeps a printable code point — the `é` of an item, a CJK
// name — literal, and this copy escapes Python's *whitespace* and no other
// non-printable code point, because a whitespace character is the only
// non-printable one a string it renders can carry. The category table that tells
// a printable code point from a format or unassigned one does exist in the tree
// now (`src/http/unicode_printable_generated.odin`, the item grammar's predicate
// at §3.6); the set the strings *here* can carry is the whitespace one
// (build/probe_header_c1.py) and the host shapes of the same question measure the
// same on both sides (build/probe_repr_nonprintable_host.py), so widening this
// copy changes no message a probe or a scenario reaches (docs/PARITY.md
// §8.18(b)).
//
// The item grammar keeps its own copy for its own messages
// (src/cli/items.odin:python_repr, which cannot call into this package's
// spelling). Both walk a sequence the same way, escape the same C0 controls and
// DEL below 0x80 (t_b7f70eee) and copy the same printable characters; they part
// company above 0x7f, where that copy asks the shared predicate about the code
// point — a non-printable one is `\xNN`, `\uNNNN` or `\UNNNNNNNN` by its width,
// as CPython spells it (t_6c1a3d89) — and this one asks only whether it is
// whitespace. Every shape of that difference lands on a string no message of this
// package carries, which is why the two copies agree wherever both are reachable
// (build/probe_header_c1.py).
@(private = "package")
python_str_repr :: proc(s: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	quote := byte('\'')
	if strings.contains_rune(s, '\'') && !strings.contains_rune(s, '"') {
		quote = '"'
	}
	strings.write_byte(&builder, quote)
	index := 0
	for index < len(s) {
		c := s[index]
		switch {
		case c == quote || c == '\\':
			strings.write_byte(&builder, '\\')
			strings.write_byte(&builder, c)
		case c == '\t':
			strings.write_string(&builder, "\\t")
		case c == '\n':
			strings.write_string(&builder, "\\n")
		case c == '\r':
			strings.write_string(&builder, "\\r")
		case c >= 0x20 && c < 0x7f:
			strings.write_byte(&builder, c)
		case c < 0x80:
			fmt.sbprintf(&builder, "\\x%02x", c)
		case:
			width := str_utf8_seq_len(s[index:])
			if width <= 0 {
				// Not a well-formed sequence: CPython's argv decode made the
				// byte the lone surrogate U+DC80+byte, and repr spells it
				// `\udcXX`.
				fmt.sbprintf(&builder, "\\u%04x", int(0xdc00) + int(c))
				index += 1
				continue
			}
			is_space, _ := header_value_rune(s[index:])
			if !is_space {
				strings.write_string(&builder, s[index:index + width])
				index += width
				continue
			}
			code, _ := utf8.decode_rune_in_string(s[index:])
			if code < 0x100 {
				fmt.sbprintf(&builder, "\\x%02x", code)
			} else {
				fmt.sbprintf(&builder, "\\u%04x", code)
			}
			index += width
			continue
		}
		index += 1
	}
	strings.write_byte(&builder, quote)
	return strings.to_string(builder)
}
