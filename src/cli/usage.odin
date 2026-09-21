// The parser's failure surface: the exact stderr block httpie prints for a
// usage error.
//
// httpie builds it in two pieces (httpie/cli/argparser.py:575-613):
//
//   * `print_usage` renders `usage` + `:\n    ` + the usage line: the program
//     name, then — when argparse raised the error for one specific option —
//     that option's usage entry, then every positional argument;
//   * `error` renders a dedented template holding the message indented by four
//     spaces, a blank line, and the `for more information:` hint.
//
// Both go through a rich Console, so long lines are wrapped to the console's
// width — `$COLUMNS` when it holds digits, else rich's 80 (`console_width`
// below; rich/console.py:1005-1050) — and a console of width 0 renders neither
// of the two prints at all (`console_silent`). The wrap is rich's Text.wrap,
// that is `divide_line`: the break goes at the whitespace *before* the word
// that does not fit, which is why a wrapped line can end with a space, and a
// line that still overflows the width has that trailing whitespace cropped
// again by `Text.rstrip_end`. Both behaviours are visible in
// err-unknown-style.err and are reproduced here.
//
// The block ends with `\n\n`: rich's own newline plus the one httpie's
// SystemExit handler writes (httpie/core.py:91-96); the usage-error exit code
// is 1, not argparse's 2 (docs/PARITY.md §2 note 5, §5). On a zero-width
// console rich's half is gone with the rest of the block and the handler's
// newline is all that is left.
package cli

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import "src:rich"

// RICH_WIDTH is the console width rich falls back to when no other source
// answers (`rich.console.DEFAULT_WIDTH`; rich/console.py:1033-1034). It is the
// width every err-* capture shows, because the captures were taken with the
// harness's `COLUMNS=80` (tests/parity/driver.py, BASE_ENV).
RICH_WIDTH :: 80

// console_width is the width rich's Console would size itself to, which is what
// the usage block is wrapped at: `$COLUMNS` when it holds digits, otherwise
// RICH_WIDTH.
//
// rich's `Console.__init__` takes the digits of `$COLUMNS` into the console's own
// `_width` and `Console.size` prefers that over everything else
// (rich/console.py:685-694, :1005-1050) — the variable is read from the
// *environment*, so it applies to a piped stderr exactly as it does to a
// terminal, and the captured 80 columns are the harness's own `COLUMNS=80` and
// not a piped-stderr default. (`is_dumb_terminal` is the one case that ignores
// `$COLUMNS`, and only for a terminal rich considers dumb.)
//
// The gate is rich's, and it is `str.isdigit()`, *not* "an integer": a sign, a
// leading or trailing space, a `0x`/`0b` prefix or an underscore all leave the
// variable unread, so `$COLUMNS=1_0` is 80 columns and not 10, and `+80` is 80
// because it is the fallback and not because `int()` accepted it
// (`python_is_digit`, src/cli/python_digits.odin; docs/PARITY.md §3.1). The
// gate is Unicode-wide, because `str.isdigit()` is — `$COLUMNS=٠` (ARABIC-INDIC
// DIGIT ZERO) is the zero-width console of the paragraph below, `$COLUMNS=١٢`
// is twelve cells — and the width is what the digits it accepts *spell* in the
// reference interpreter's own Unicode database
// (src/cli/python_digits_generated.odin, `width_of_digits`; t_14a26d57).
//
// The *range* of the same gate is Python's too: `int()` is unbounded, so a
// digit string longer than this port's `int` can hold — a 19- or 20-digit
// `$COLUMNS` — is not an error and not a width the port may refuse: it names a
// console wider than any line this port can render, and every line comes out
// whole (`width_of_digits` clamps the value to `max(int)`, which no line
// reaches; t_3a12ca73).
//
// One shape `isdigit()` accepts spells no width at all: a character `int()`
// refuses — a superscript or subscript digit, which carries no decimal value —
// makes rich raise inside `Console.__init__` and kills the reference before the
// console exists. The port models that as the console it cannot build
// (`console_crash`): no width is read out of such a value, and every writer
// that would have printed a message prints the exception's own line instead
// (docs/PARITY.md §3.1, §8.20; t_14a26d57).
//
// The port does not ask the terminal for a size, so the sources rich consults
// before the fallback — a real tty and a dumb terminal — are not modelled: a run
// with no `$COLUMNS`, or one whose `$COLUMNS` names no width, gets RICH_WIDTH,
// the width the harness pins.
//
// A `$COLUMNS` of `0` (`00`, `000`, …) is a width rich takes literally, like
// every other one it accepts: it is the zero-width console `console_silent`
// describes, and nothing prints through it at all.
console_width :: proc(env: Env_Info) -> int {
	columns, found := env_get(env, "COLUMNS")
	if !found || !python_is_digit(columns) {
		return RICH_WIDTH
	}
	width, ok := width_of_digits(columns)
	if !ok {
		// A digit with no decimal value: rich's `int(columns)` raises here and
		// the console is never built, so no width is ever read out of this
		// value (`console_crash` is what the callers read). RICH_WIDTH keeps
		// this proc total.
		return RICH_WIDTH
	}
	return width
}

// console_crash is the `$COLUMNS` value rich's `Console.__init__` refuses:
// `str.isdigit()` accepts it and then `int(columns)` raises
// `ValueError: invalid literal for int() with base 10: '…'`, an unhandled
// exception that ends the reference's run *before* the console exists — so
// nothing is ever rendered through it, and the message httpie was about to
// print is gone whole (rich/console.py:685-694; docs/PARITY.md §3.1).
//
// The result is the value rich refused, the one its exception line quotes, and
// "" for every console rich can build — the zero-width ones included, because
// `0` is a width `int()` reads. The value is *borrowed* from `env`: it is the
// caller's to keep alive until `output.write_log_crash` has written the line.
console_crash :: proc(env: Env_Info) -> string {
	columns, found := env_get(env, "COLUMNS")
	if !found || !python_is_digit(columns) {
		return ""
	}
	if _, ok := width_of_digits(columns); ok {
		return ""
	}
	return columns
}

// width_of_digits is `int(columns)` for a digit run `python_is_digit` accepted.
// The one thing it cannot be is Python's `int()`: that one has no bound, while an
// `int` here does, and a 19- or 20-digit `$COLUMNS` (`10000000000000000000`,
// `18446744073709551616 + 5`) names a value no `int` can hold. Such a value is
// clamped to `max(int)` instead of being wrapped — `strconv.parse_int`
// accumulates into an `i64` and silently wraps, which would hand the rest of
// the port a *negative* width (a console that renders nothing) or a small
// positive one (`2^64 + 5` wraps to 5, a five-cell console). Neither is what
// the reference does: its `int()` reads the digits literally, so the console is
// that many cells wide. Every value the clamp replaces is above `max(int)`,
// i.e. above every line this port can hold, and any width above the longest
// line renders that line whole — so the clamp is not observable in the bytes,
// while the wrap was (t_3a12ca73).
//
// Leading zeros are not an overflow: `'0'*50 + '1'` is the width 1, and the
// accumulation below never leaves an `int` for it.
//
// The digits are not the ASCII ten. `int()` reads a character only when it
// carries a *decimal* value, so the value of a run is the number its digits
// spell in whatever script they are written in (`$COLUMNS=١٢` is 12,
// `$COLUMNS=٠` is 0) and a character without one — the superscripts and
// subscripts, which `str.isdigit()` accepts all the same — is not a width at
// all: that is the `ValueError` `console_crash` reports, and `ok` is false for
// it. The whole value is scanned either way, because the refusal belongs to one
// character and not to where the scan stopped.
@(private)
width_of_digits :: proc(columns: string) -> (width: int, ok: bool) {
	clamped := false
	for index := 0; index < len(columns); {
		code, size := utf8.decode_rune_in_string(columns[index:])
		if size <= 0 {
			return 0, false
		}
		digit, decimal := python_decimal_value(code)
		if !decimal {
			return 0, false
		}
		if !clamped {
			// `width * 10 + digit` would overflow: the remaining digits cannot
			// make the value fit again (it only grows), so stop at the bound.
			if width > (max(int) - digit) / 10 {
				clamped = true
				width = max(int)
			} else {
				width = width * 10 + digit
			}
		}
		index += size
	}
	return width, true
}

// console_silent reports whether a console `width` cells wide renders anything
// at all. rich's `Console.render` returns an empty segment list for any
// `max_width` below one cell — "No space to render anything"
// (rich/console.py:1312-1314) — so a console sized to 0 cells prints *nothing*:
// every message that goes through it is dropped, and what still reaches the
// stream is only what httpie writes around it (the newline its SystemExit
// handler writes, the header block a `--download` renders with its own writer,
// `--debug`'s own lines).
//
// `$COLUMNS=0` is that console. `Console.size` returns the `_width` the digits
// of `$COLUMNS` set, so the fallback that turns a width of zero into 80
// (`width = width or 80`) never runs for it; that one is reached only by a
// *terminal* that reports 0×0 (rich/console.py:685-694, :1005-1050). The width
// travels with the run's environment: `console_width` returns the 0, and every
// writer that models one of httpie's rich consoles drops its bytes when
// `console_silent` says so (docs/PARITY.md §3.1, §4.2; t_e0f7b7b3).
console_silent :: proc(width: int) -> bool {
	return width < 1
}

// STYLE_NAMES is `get_available_styles()` (httpie/output/ui/rich_theme.py):
// pygments' style names plus httpie's bundled `auto`, `solarized` and the three
// pie styles, sorted by Python's byte-wise string order. The order matters: it
// is the order the `--style` choice list is printed in.
STYLE_NAMES := [?]string{
	"abap",
	"algol",
	"algol_nu",
	"arduino",
	"auto",
	"autumn",
	"borland",
	"bw",
	"coffee",
	"colorful",
	"default",
	"dracula",
	"emacs",
	"friendly",
	"friendly_grayscale",
	"fruity",
	"github-dark",
	"gruvbox-dark",
	"gruvbox-light",
	"igor",
	"inkpot",
	"lightbulb",
	"lilypond",
	"lovelace",
	"manni",
	"material",
	"monokai",
	"murphy",
	"native",
	"night-owl",
	"nord",
	"nord-darker",
	"one-dark",
	"paraiso-dark",
	"paraiso-light",
	"pastie",
	"perldoc",
	"pie",
	"pie-dark",
	"pie-light",
	"rainbow_dash",
	"rrt",
	"sas",
	"solarized",
	"solarized-dark",
	"solarized-light",
	"staroffice",
	"stata-dark",
	"stata-light",
	"tango",
	"trac",
	"vim",
	"vs",
	"xcode",
	"zenburn",
}

// PRETTY_CHOICES is `sorted(PRETTY_MAP.keys())`.
PRETTY_CHOICES := [?]string{"all", "colors", "format", "none"}

// SSL_VERSION_CHOICES is `sorted(AVAILABLE_SSL_VERSION_ARG_MAPPING)`, the
// LibreSSL-safe subset of OpenSSL's protocol names.
SSL_VERSION_CHOICES := [?]string{"ssl2.3", "tls1", "tls1.1", "tls1.2"}

// AUTH_TYPE_CHOICES_SORTED is what `', '.join(map(repr, action.choices))`
// produces for `--auth-type` (the action iterates its choices sorted).
AUTH_TYPE_CHOICES_SORTED := [?]string{"basic", "bearer", "digest"}

// ---------------------------------------------------------------------------
// Choice membership
// ---------------------------------------------------------------------------

style_is_valid :: proc(name: string) -> bool {
	for candidate in STYLE_NAMES {
		if candidate == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Usage line
// ---------------------------------------------------------------------------

// POSITIONAL_USAGE is the positional part of every usage line: METHOD is
// `nargs='?'` (`[NAME]`), URL is a single argument, REQUEST_ITEM is
// `nargs='*'` (`[NAME ...]`).
POSITIONAL_USAGE :: "[METHOD] URL [REQUEST_ITEM ...]"

// usage_option_entry maps the name argparse puts into an ArgumentError message
// (`'/'.join(action.option_strings)`) to the entry the usage line shows for
// that action. The two differ in two ways: the usage entry sorts the aliases by
// length (shortest first) and appends the action's choice list in braces.
//
// The names are literal because that is how they appear in the reference's
// messages: `argument --style/-s: invalid choice: 'nope' (choose from …)`.
usage_option_entry :: proc(name: string) -> (entry: string, ok: bool) {
	switch name {
	case "--json/-j":             return "-j/--json", true
	case "--form/-f":             return "-f/--form", true
	case "--multipart":           return "--multipart", true
	case "--boundary":            return "--boundary", true
	case "--raw":                 return "--raw", true
	case "--compress/-x":         return "-x/--compress", true
	case "--pretty":              return "--pretty {all, colors, format, none}", true
	case "--style/-s":            return "-s/--style {abap, algol, algol_nu, arduino, auto, autumn, borland, bw, coffee, colorful, default, dracula, emacs, friendly, friendly_grayscale, fruity, github-dark, gruvbox-dark, gruvbox-light, igor, inkpot, lightbulb, lilypond, lovelace, manni, material, monokai, murphy, native, night-owl, nord, nord-darker, one-dark, paraiso-dark, paraiso-light, pastie, perldoc, pie, pie-dark, pie-light, rainbow_dash, rrt, sas, solarized, solarized-dark, solarized-light, staroffice, stata-dark, stata-light, tango, trac, vim, vs, xcode, zenburn}", true
	case "--no-unsorted":         return "--no-unsorted", true
	case "--no-sorted":           return "--no-sorted", true
	case "--unsorted":            return "--unsorted", true
	case "--sorted":              return "--sorted", true
	case "--response-charset":    return "--response-charset", true
	case "--response-mime":       return "--response-mime", true
	case "--format-options":      return "--format-options", true
	case "--print/-p":            return "-p/--print", true
	case "--headers/-h":          return "-h/--headers", true
	case "--meta/-m":             return "-m/--meta", true
	case "--body/-b":             return "-b/--body", true
	case "--verbose/-v":          return "-v/--verbose", true
	case "--all":                 return "--all", true
	case "--history-print/-P":    return "-P/--history-print", true
	case "--stream/-S":           return "-S/--stream", true
	case "--output/-o":           return "-o/--output", true
	case "--download/-d":         return "-d/--download", true
	case "--continue/-c":         return "-c/--continue", true
	case "--quiet/-q":            return "-q/--quiet", true
	case "--session":             return "--session", true
	case "--session-read-only":   return "--session-read-only", true
	case "--auth/-a":             return "-a/--auth", true
	case "--auth-type/-A":        return "-A/--auth-type {basic, digest, bearer}", true
	case "--ignore-netrc":        return "--ignore-netrc", true
	case "--offline":             return "--offline", true
	case "--proxy":               return "--proxy", true
	case "--follow/-F":           return "-F/--follow", true
	case "--max-redirects":       return "--max-redirects", true
	case "--max-headers":         return "--max-headers", true
	case "--timeout":             return "--timeout", true
	case "--check-status":        return "--check-status", true
	case "--path-as-is":          return "--path-as-is", true
	case "--chunked":             return "--chunked", true
	case "--verify":              return "--verify", true
	case "--ssl":                 return "--ssl {ssl2.3, tls1, tls1.1, tls1.2}", true
	case "--ciphers":             return "--ciphers", true
	case "--cert":                return "--cert", true
	case "--cert-key":            return "--cert-key", true
	case "--cert-key-pass":       return "--cert-key-pass", true
	case "--ignore-stdin/-I":     return "-I/--ignore-stdin", true
	case "--help":                return "--help", true
	case "--manual":              return "--manual", true
	case "--version":             return "--version", true
	case "--traceback":           return "--traceback", true
	case "--default-scheme":      return "--default-scheme", true
	case "--debug":               return "--debug", true
	}
	return "", false
}

// usage_line_text renders `PROGRAM [OPTION] [METHOD] URL [REQUEST_ITEM ...]`.
// `whitelist_entry` is the usage entry of the option argparse blamed, or "" for
// the errors httpie raises itself (--print=z, an invalid session name, the
// body-source conflicts): those keep the plain positional-only line.
usage_line_text :: proc(
	program_name: string,
	whitelist_entry: string,
	allocator: mem.Allocator,
) -> string {
	if whitelist_entry == "" {
		return strings.concatenate({program_name, " ", POSITIONAL_USAGE}, allocator)
	}
	return strings.concatenate({program_name, " ", whitelist_entry, " ", POSITIONAL_USAGE}, allocator)
}

// ---------------------------------------------------------------------------
// The block
// ---------------------------------------------------------------------------

// usage_error_text renders the complete stderr block for a usage error:
//
//	usage:
//	    http [METHOD] URL [REQUEST_ITEM ...]
//
//	error:
//	    <message, through rich's markup pass, wrapped at `width` cells>
//
//	for more information:
//	    run 'http --help' or visit https://httpie.io/docs/cli
//
// followed by the reference's trailing `\n\n`. main.odin writes exactly these
// bytes to stderr and exits 1.
//
// `width` is the console width rich would use — `console_width` on the run's
// environment: `$COLUMNS` when it holds digits and RICH_WIDTH otherwise. Every
// line of the block is wrapped to it: the usage line, the message and the fixed
// hint.
//
// A zero-width console (`console_silent`) renders neither of the two Texts — no
// line, and not even the newline rich's own `print` ends them with — so the
// only byte that reaches stderr is the newline httpie's SystemExit handler
// writes (httpie/core.py:91-96).
//
// `program_name` is the name the binary was invoked as (`http` for every
// capture); httpie's Console prints `spec.program`, which is the literal
// `http`, and its `--help` hint uses `parser.prog`, the same string.
//
// The option that argparse blamed is recovered from the message itself: every
// error argparse raises for a specific action starts with `argument NAME: `,
// which is exactly what is needed to splice that action into the usage line
// (httpie/cli/argparser.py:575-596). That recovery reads the message *before*
// the markup pass — the prefix is what argparse wrote, not what rich prints.
usage_error_text :: proc(
	program_name, message: string,
	width: int,
	allocator: mem.Allocator,
) -> string {
	if console_silent(width) {
		return strings.clone("\n", allocator)
	}
	b := strings.builder_make(allocator)

	whitelist_entry := ""
	if entry, ok := blamed_option_entry(message); ok {
		whitelist_entry = entry
	}

	usage_line := usage_line_text(program_name, whitelist_entry, allocator)
	defer delete(usage_line, allocator)
	// The message is text rich has to render first: both of its passes are in
	// `rich_markup_text`, and both move the cell count the wrap below measures —
	// the tags because they are gone from the bytes, the emoji codes because the
	// character they become is up to two cells wide.
	printed_message := rich_markup_text(message, allocator)
	defer delete(printed_message, allocator)
	message_line := strings.concatenate({"    ", printed_message}, allocator)
	defer delete(message_line, allocator)
	hint_line := strings.concatenate(
		{"    run '", program_name, " --help' or visit https://httpie.io/docs/cli"},
		allocator,
	)
	defer delete(hint_line, allocator)

	line_width := width

	// Each of httpie's two `print` calls is ONE rich Text, and rich wraps each
	// Text as a whole (`Text.wrap` splits it into lines and runs `divide_line`
	// over every one of them) — so the `usage:`/`error:`/`for more information:`
	// labels are wrapped with the text they introduce, and a console narrower
	// than a label folds that label too. The two blocks below are those texts:
	// the first is `usage` + ':\n    ' + the usage line, the second the dedented
	// template (a leading blank line, `error:`, the message, a blank line,
	// `for more information:`, the hint) — the styles the reference's template
	// carries are only a `render` concern, and this console writes none.
	usage_block := strings.concatenate({"usage:\n    ", usage_line}, allocator)
	defer delete(usage_block, allocator)
	write_wrapped(&b, usage_block, line_width, allocator)
	strings.write_string(&b, "\n")

	error_block := strings.concatenate(
		{"\nerror:\n", message_line, "\n\nfor more information:\n", hint_line},
		allocator,
	)
	defer delete(error_block, allocator)
	write_wrapped(&b, error_block, line_width, allocator)
	strings.write_string(&b, "\n")

	// rich's `print` ends the block; httpie's SystemExit handler adds one more
	// newline (httpie/core.py:93).
	strings.write_string(&b, "\n")
	return strings.to_string(b)
}

// blamed_option_entry recovers the action name from an argparse message
// (`argument <NAME>: <body>`) and returns its usage entry.
@(private)
blamed_option_entry :: proc(message: string) -> (entry: string, ok: bool) {
	prefix :: "argument "
	if !strings.has_prefix(message, prefix) {
		return "", false
	}
	rest := message[len(prefix):]
	colon := strings.index(rest, ": ")
	if colon < 0 {
		return "", false
	}
	return usage_option_entry(rest[:colon])
}

// ---------------------------------------------------------------------------
// rich's markup pass over the message
// ---------------------------------------------------------------------------

// rich_markup_text is the *plain text* rich prints for a markup string:
// `rich.markup.render(markup)` with the spans dropped. That is the whole of what
// reaches stderr when the console is not a terminal — every capture pipes stderr,
// and rich writes an escape only to a terminal (httpie's console is also built
// with `no_color` when the run resolved zero colors). httpie splices the error
// message into such a markup string and prints the whole template through its
// rich console (httpie/cli/argparser.py:598-612), so any `[...]` a message
// carries is a style tag to the reference, not text.
//
// The template's own tags (`[bold]error[/bold]`, the `for more information`
// pair) are all closed before the message and the fixed tail holds no `[`, so
// parsing the template is parsing the message: this proc is applied to the
// message alone. It runs *before* the 80-cell wrap, because rich wraps the
// Text `render` returned — a message with a tag in it can break at a different
// cell than the same message spelled without one.
//
// The rules are rich 15.0.0's (rich/markup.py `render`, `_parse`, RE_TAGS):
//
//   * a tag is `[`, one of `[a-z#/@]`, anything but a `[`, then the first `]`
//     after it. Its text is dropped: a known style (`[b]`, `[bold]`), an
//     unknown one (`[nope]`), a colour (`[#ff0000]`), a `[link=…]`/`[@click=…]`
//     and a closing tag (`[/bold]`) all disappear the same way, since the style
//     is only looked up later and an unknown name resolves to "none";
//   * `[BOLD]` is *not* a tag (the character after the `[` must be lower case),
//     and neither is a `[` that meets no `]` before the next one
//     (`[a[b]` strips the second bracket group and keeps the first);
//   * backslashes in front of a tag escape it: each *pair* is printed as itself
//     and an odd remainder makes the tag literal text — `\[b]` prints `[b]`
//     and `\\[b]` prints `\` and eats the tag;
//   * a backslash in front of a bracket that opens no tag is dropped with it
//     (`x\[y` prints `x[y`). rich does this per plain piece
//     (`plain_text.replace("\\[", "[")`, markup.py:156), not on the assembled
//     text, which is why the escaped tag above keeps its bracket even when the
//     escape printed a backslash of its own;
//   * everything else — an unknown tag's text included — is text.
//
// Two things this deliberately does not do. A closing tag with nothing open
// (`note=@[/bold]nope.txt`) makes rich raise MarkupError inside `print`, so the
// reference dies with a Python traceback naming the interpreter's own paths;
// the port prints the block as text instead. That case cannot be a scenario
// (its bytes are environment-dependent) and is measured in
// build/probe_usage_markup.py, not asserted (docs/PARITY.md §8.18(e)). And the
// emoji pass below is rich's second transform rather than a rule of this one —
// it runs over the same pieces, after this pass, through
// `rich.emoji_replace` (src/rich/emoji.odin).
rich_markup_text :: proc(markup: string, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)

	// `position` is where the plain text still to be written starts, `at` the
	// offset being tried as a tag start: rich's regex finds the leftmost match,
	// so a failed attempt moves one byte on.
	position := 0
	at := 0
	for at < len(markup) {
		backslashes, open, end, ok := markup_tag_at(markup, at)
		if !ok {
			at += 1
			continue
		}
		write_markup_plain(&b, markup[position:at], allocator)
		if backslashes > 0 {
			// `backslashes // 2` of them are printed as themselves...
			for _ in 0 ..< backslashes / 2 {
				strings.write_byte(&b, '\\')
			}
			if backslashes % 2 == 1 {
				// ...and the odd one turns the tag into literal text: rich
				// yields that text as its own plain piece (`_parse` yields
				// `full_text[len(escapes):]`), so the bracket below is written
				// as it stands rather than through the `\[` rule. A tag body
				// holds no `[`, so that rule could not fire on it anyway — but
				// the emoji pass runs over it, as it does over every piece.
				emoji := rich.emoji_replace(markup[open:end], allocator)
				strings.write_string(&b, emoji)
				delete(emoji, allocator)
			}
		}
		position = end
		at = end
	}
	write_markup_plain(&b, markup[position:], allocator)
	return strings.to_string(b)
}

// markup_tag_at is RE_TAGS tried at one offset: it consumes the backslashes the
// tag carries, then the bracket group, and reports the offsets of the `[` and of
// the byte after the `]` (`open`/`end`), so the caller can both drop the tag and
// print it as text when an odd backslash escaped it.
@(private)
markup_tag_at :: proc(text: string, at: int) -> (backslashes, open, end: int, ok: bool) {
	i := at
	for i < len(text) && text[i] == '\\' {
		i += 1
	}
	backslashes = i - at
	if i + 1 >= len(text) || text[i] != '[' {
		return 0, 0, 0, false
	}
	// `[a-z#/@]`: the character after the bracket decides whether this is a tag
	// at all, which is why `[BOLD]` and `[]` are text.
	switch text[i + 1] {
	case 'a' ..= 'z', '#', '@', '/':
	case:
		return 0, 0, 0, false
	}
	// `[^[]*?]`: the tag ends at the first `]` and never crosses a `[`.
	j := i + 2
	for j < len(text) && text[j] != '[' && text[j] != ']' {
		j += 1
	}
	if j >= len(text) || text[j] != ']' {
		return 0, 0, 0, false
	}
	return backslashes, i, j + 1, true
}

// write_markup_plain writes one piece of rich's *plain* text through both of the
// transforms `render` applies to a plain piece, in rich's order
// (rich/markup.py:155-157):
//
//   * `plain_text.replace("\\[", "[")` — a backslash immediately in front of a
//     bracket that opens no tag is that bracket's escape and goes away — and
//     then
//   * the emoji pass (`rich/_emoji_replace.py`), which is per piece and not per
//     message: a code split by a tag (`:smi[b]le:`) is not a code to the
//     reference either, because the two halves are separate pieces by the time
//     the lookup runs.
@(private)
write_markup_plain :: proc(b: ^strings.Builder, text: string, allocator: mem.Allocator) {
	unescaped := strings.builder_make(allocator)
	i := 0
	for i < len(text) {
		if text[i] == '\\' && i + 1 < len(text) && text[i + 1] == '[' {
			strings.write_byte(&unescaped, '[')
			i += 2
			continue
		}
		strings.write_byte(&unescaped, text[i])
		i += 1
	}
	piece := strings.to_string(unescaped)
	emoji := rich.emoji_replace(piece, allocator)
	strings.write_string(b, emoji)
	delete(emoji, allocator)
	delete(piece, allocator)
}

// ---------------------------------------------------------------------------
// rich's wrapper
// ---------------------------------------------------------------------------

// write_wrapped writes every line of `text`, wrapped at `width` cells by rich's
// Text.wrap. Lines are separated by a single '\n' and no trailing newline is
// written.
@(private)
write_wrapped :: proc(b: ^strings.Builder, text: string, width: int, allocator: mem.Allocator) {
	start := 0
	first := true
	for {
		newline := strings.index_byte(text[start:], '\n')
		line: string
		at_end := false
		if newline < 0 {
			line = text[start:]
			at_end = true
		} else {
			line = text[start:start + newline]
		}
		if !first {
			strings.write_byte(b, '\n')
		}
		first = false
		write_wrapped_line(b, line, width, allocator)
		if at_end {
			break
		}
		start += newline + 1
	}
}

// write_wrapped_line is one line through rich's divide_line + Text.rstrip_end.
@(private)
write_wrapped_line :: proc(b: ^strings.Builder, line: string, width: int, allocator: mem.Allocator) {
	breaks := make([dynamic]int, 0, 8, allocator)
	defer delete(breaks)
	divide_line(line, width, &breaks)

	previous := 0
	for i in 0 ..= len(breaks) {
		end := len(line)
		if i < len(breaks) {
			end = breaks[i]
		}
		segment := line[previous:end]
		// Text.rstrip_end crops only the whitespace that pushes the segment
		// past `width`, and only by as much as it overflows.
		segment = rstrip_end(segment, width)
		// Text.truncate(overflow="fold") then crops what is left.
		if cells := cell_len(segment); cells > width {
			segment = slice_cells(segment, width)
		}
		strings.write_string(b, segment)
		if i < len(breaks) {
			strings.write_byte(b, '\n')
		}
		previous = end
	}
}

// divide_line is rich/_wrap.py's divide_line: offsets in `text` to break at so
// every line fits `width` cells. `words` are the matches of `\s*\S+\s*`, and a
// word is measured without its trailing whitespace but counted with it, so a
// break can leave the whitespace that preceded the word on the line above.
@(private)
divide_line :: proc(text: string, width: int, breaks: ^[dynamic]int) {
	cell_offset := 0
	position := 0
	for position < len(text) {
		after_leading := position
		for after_leading < len(text) && is_space(text[after_leading]) {
			after_leading += 1
		}
		word_end := after_leading
		for word_end < len(text) && !is_space(text[word_end]) {
			word_end += 1
		}
		if word_end == after_leading {
			// The rest of the line is whitespace: `\s*\S+\s*` cannot match, so
			// the word iterator stops here and the tail is never split off.
			return
		}
		trailing := word_end
		for trailing < len(text) && is_space(text[trailing]) {
			trailing += 1
		}

		word := text[position:trailing]
		word_length := cell_len(trim_right_space(word))

		if width - cell_offset >= word_length {
			cell_offset += cell_len(word)
		} else if word_length > width {
			// The word does not fit on a line of its own either, so rich folds
			// it (overflow="fold"): one break per `width`-cell piece, and the
			// last piece's width becomes the running offset.
			offset := 0
			for {
				piece := slice_cells(word[offset:], width)
				if len(piece) == 0 {
					break
				}
				at := position + offset
				if at != 0 {
					append(breaks, at)
				}
				if cell_len(word[offset:]) <= width {
					cell_offset = cell_len(piece)
					break
				}
				offset += len(piece)
			}
		} else if cell_offset != 0 && position != 0 {
			append(breaks, position)
			cell_offset = cell_len(word)
		}
		position = trailing
	}
}

// rstrip_end is Text.rstrip_end: when a segment is `width` cells or less it is
// untouched; otherwise up to `excess` cells of its trailing whitespace go away.
@(private)
rstrip_end :: proc(text: string, width: int) -> string {
	cells := cell_len(text)
	if cells <= width {
		return text
	}
	excess := cells - width
	whitespace := 0
	for whitespace < len(text) && is_space(text[len(text) - 1 - whitespace]) {
		whitespace += 1
	}
	return slice_cells(text, cells - min(whitespace, excess))
}

// ---------------------------------------------------------------------------
// Cell arithmetic (rich measures in terminal cells, not bytes)
// ---------------------------------------------------------------------------

// cell_len is rich's cell_len: the width of `text` in terminal cells, and the
// measure the 80-cell wrap breaks on. It is ASCII plus U+2019 (httpie's
// typographic apostrophe in the --response-mime message), the characters an
// emoji code puts there, and whatever the message borrowed from argv.
@(private)
cell_len :: proc(text: string) -> int {
	cells := 0
	for i := 0; i < len(text); {
		width, size := rune_cell_len(text[i:])
		cells += width
		i += size
	}
	return cells
}

// rune_cell_len is rich's `get_character_cell_size` for the rune `text` starts
// with: zero for a control character, the width of rich's Unicode table where
// the port knows it (src/rich/emoji.odin's `cell_width`, which covers every code
// point the emoji pass can introduce), one otherwise. It also reports how many
// bytes that rune took, which is what lets the callers walk the string.
@(private)
rune_cell_len :: proc(text: string) -> (width: int, size: int) {
	if text == "" {
		return 0, 0
	}
	code, rune_size := utf8.decode_rune_in_string(text)
	return rich.cell_width(code), rune_size
}

// slice_cells returns the prefix of `text` that is `cells` terminal cells wide.
@(private)
slice_cells :: proc(text: string, cells: int) -> string {
	remaining := cells
	for i := 0; i < len(text); {
		width, size := rune_cell_len(text[i:])
		if remaining < width {
			return text[:i]
		}
		remaining -= width
		i += size
	}
	return text
}

@(private)
is_space :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', '\v', '\f':
		return true
	}
	return false
}

// trim_right_space is Python's str.rstrip() with no argument.
@(private)
trim_right_space :: proc(text: string) -> string {
	end := len(text)
	for end > 0 && is_space(text[end - 1]) {
		end -= 1
	}
	return text[:end]
}

// ---------------------------------------------------------------------------
// Value-error messages (httpie's argparse wording)
// ---------------------------------------------------------------------------

// invalid_choice_message is argparse's `_check_value` message for an action
// with choices. `choices_repr` is the pre-rendered `', '.join(map(repr, …))`
// of the choice list.
invalid_choice_message :: proc(action_name, value, choices_repr: string, allocator: mem.Allocator) -> string {
	repr := python_repr(value, allocator)
	defer delete(repr, allocator)
	return strings.concatenate(
		{"argument ", action_name, ": invalid choice: ", repr, " (choose from ", choices_repr, ")"},
		allocator,
	)
}

// style_choices_repr renders `--style`'s choice list the way the reference's
// error message does: `repr()` of each name, with the three pie styles rendered
// as the enum members they are (`<PieStyle.UNIVERSAL: 'pie'>`).
style_choices_repr :: proc(allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	for name, i in STYLE_NAMES {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		switch name {
		case "pie":
			strings.write_string(&b, "<PieStyle.UNIVERSAL: 'pie'>")
		case "pie-dark":
			strings.write_string(&b, "<PieStyle.DARK: 'pie-dark'>")
		case "pie-light":
			strings.write_string(&b, "<PieStyle.LIGHT: 'pie-light'>")
		case:
			repr := python_repr(name, allocator)
			strings.write_string(&b, repr)
			delete(repr, allocator)
		}
	}
	return strings.to_string(b)
}

// choices_repr renders `', '.join(map(repr, choices))` for a list of plain
// strings.
choices_repr :: proc(choices: []string, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	for name, i in choices {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		repr := python_repr(name, allocator)
		strings.write_string(&b, repr)
		delete(repr, allocator)
	}
	return strings.to_string(b)
}
