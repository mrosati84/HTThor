// Byte-exact emulation of httpie's Pygments colouring.
//
// What this file is: a port of the *observable* part of Pygments' lexing and
// formatting, restricted to the token types and lexers httpie actually uses for
// HTTP output. httpie never prints its own escape sequences -- it hands a lexer
// and a formatter to `pygments.highlight()` and prints whatever comes back
// (httpie/output/formatters/colors.py:40-132), so "port httpie's colours" means
// "port Pygments' lexers plus its two terminal formatter loops, byte for byte".
//
// Ported from (all paths relative to the reference site-packages tree):
//   * pygments/lexer.py:218-281  Lexer._preprocess_lexer_input + get_tokens
//   * pygments/lexer.py:702-761  RegexLexer.get_tokens_unprocessed (incl. the
//                                Error/Whitespace fallback)
//   * pygments/lexers/data.py:446-698   JsonLexer.get_tokens_unprocessed
//   * pygments/lexers/html.py:195-234   XmlLexer
//   * httpie/output/lexers/json.py:11-31 EnhancedJsonLexer
//   * pygments/lexers/textfmts.py:116-200 HttpLexer
//   * httpie/output/lexers/http.py:25-97 SimplifiedHTTPLexer
//   * httpie/output/lexers/metadata.py:6-58 MetadataLexer
//   * httpie/output/lexers/common.py:1-12 `precise`
//   * pygments/lexers/special.py:21-38 TextLexer
//   * pygments/formatters/terminal.py:98-127 TerminalFormatter.format_unencoded
//   * pygments/formatters/terminal256.py:252-290 Terminal256Formatter.format_unencoded
//   * pygments/console.py:13-70  ansiformat / codes (the reset sequence)
//
// Ownership: every `lex_*` allocates exactly one string (the preprocessed input,
// `Lexed.storage`) plus the token array; the tokens' `text` fields are subslices
// of that storage. `lexed_destroy` releases both, using the allocator the caller
// passed in -- there is no `context.allocator` anywhere in this file.
//
// Not emulated (see docs/COLORIZE.md): the HTML/SVG body lexers (`text/html`,
// `application/xhtml+xml`) and the Unicode character classes `\s`/`\d`/`\w`
// (the ASCII subset is implemented).
package output

import "core:io"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

// Token_Kind is the closed set of Pygments token types httpie's HTTP lexers can
// emit, in the order the generated escape tables are indexed by. The names are
// the Odin spelling of `pygments.token.<...>`; gen_styles.py asserts that this
// enum and its own mapping stay in lock-step (see tools/ref-capture/gen_styles.py).
Token_Kind :: enum {
	Text,
	Whitespace,
	Error,
	Other,
	Keyword,
	Keyword_Constant,
	Keyword_Reserved,
	Operator,
	Number,
	Number_Integer,
	Number_Float,
	Number_Http_Info,
	Number_Http_Ok,
	Number_Http_Redirect,
	Number_Http_Client_Error,
	Number_Http_Server_Error,
	Number_Speed_Fast,
	Number_Speed_Avg,
	Number_Speed_Slow,
	Number_Speed_Very_Slow,
	Name_Attribute,
	Name_Builtin,
	Name_Decorator,
	Name_Entity,
	Name_Exception,
	Name_Function,
	Name_Function_HttpGet,
	Name_Function_HttpHead,
	Name_Function_HttpPost,
	Name_Function_HttpPut,
	Name_Function_HttpPatch,
	Name_Function_HttpDelete,
	Name_Namespace,
	Name_Tag,
	Literal,
	String,
	String_Double,
	Punctuation,
	Comment_Single,
	Comment_Multiline,
	Comment_Preproc,
	Generic_Error,
}

// Token is one Pygments `(tokentype, value)` pair. `text` borrows from the
// Lexed it came from and must not outlive it.
Token :: struct {
	kind: Token_Kind,
	text: string,
}

// Lex_Variant selects the HTTP head lexer httpie would pick
// (httpie/output/formatters/colors.py:64-73):
//
//	Pygments_Http      -- pygments HttpLexer, used for `--style=auto`
//	Simplified_Head    -- httpie SimplifiedHTTPLexer(precise=False), every other
//	                      style when the terminal reports 256 colours
//	Simplified_Precise -- httpie SimplifiedHTTPLexer(precise=True), pie styles
Lex_Variant :: enum {
	Pygments_Http,
	Simplified_Head,
	Simplified_Precise,
}

// Lexed is a lexer run: the owned, preprocessed input plus the token stream.
Lexed :: struct {
	storage: string,
	tokens:  [dynamic]Token,
}

// lexed_destroy releases everything a `lex_*` call allocated.
lexed_destroy :: proc(l: ^Lexed, allocator: mem.Allocator) {
	delete(l.storage, allocator)
	delete(l.tokens)
	l^ = {}
}

// Style_Escape is the (open, close) escape sequence pair Pygments' formatter
// would put around one token's text. Both empty means "no styling at all",
// which is what Pygments itself emits for a token with no style (it writes the
// value raw -- pygments/formatters/terminal256.py:285-286).
Style_Escape :: struct {
	prefix: string,
	reset:  string,
}

// Style is one `--style`'s escape tables, indexed by Token_Kind as int.
// `header` is used for HTTP head blocks *and* metadata, `body` for bodies:
// httpie builds a header formatter and a body formatter and only the pie styles
// make them differ (httpie/output/formatters/colors.py:115-132).
Style :: struct {
	name:   string,
	header: []Style_Escape,
	body:   []Style_Escape,
}

// STYLE_CHOICES is the exact, ordered `--style` choice list httpie advertises;
// it is generated from the reference (docs/parity-captures/err-unknown-style.err
// captures it in the same order). It is a variable, not a `::` constant, so that
// callers may index it with a run-time index (Odin forbids that for constants).
STYLE_CHOICES := GENERATED_STYLE_CHOICES

// DEFAULT_STYLE_NAME is httpie's DEFAULT_STYLE
// (httpie/output/formatters/colors.py:25, `AUTO_STYLE`).
DEFAULT_STYLE_NAME :: "auto"

// style_lookup resolves a `--style` name to its escape tables. Unknown names
// fall back to nothing: httpie never gets here because argparse rejects them
// first, and `get_style_class`'s Solarized256Style fallback is only reachable
// for a *valid* pygments style name the bundled list happens to miss.
style_lookup :: proc(name: string) -> (Style, bool) {
	for style in GENERATED_STYLES {
		if style.name == name {
			return style, true
		}
	}
	return {}, false
}

// render_tokens writes the byte stream Pygments' terminal formatter would write
// for `tokens` under `escapes`.
//
// Both formatter loops are line-oriented and reset the colour at every newline
// so that paging works (pygments/formatters/terminal.py:108-127,
// pygments/formatters/terminal256.py:252-290). They differ in two ways:
//
//   - TerminalFormatter splits the value with `splitlines(keepends=True)`,
//     strips the trailing '\n' with `rstrip('\n')` and appends '\n' when the
//     line had one; it emits the escapes even for an *empty* line, because
//     `ansiformat` always wraps `line.rstrip('\n')` (pygments/console.py:48-70).
//   - Terminal256Formatter splits on '\n' only, skips the escapes entirely when
//     the line is empty (`if line:` -- terminal256.py:266-276) and writes the
//     raw value when the token has no entry in the style at all.
//
// Which loop applies follows from the table itself: every TerminalFormatter
// escape starts with a colour code from `pygments.console.codes` and ends with
// the one literal reset that `ansiformat` appends unconditionally
// (pygments/console.py:15, :48-70), so a table whose coloured entries *all* end
// with "\x1b[39;49;00m" came from TerminalFormatter. The only way a
// Terminal256Formatter table could look the same is if every styled token of the
// style set foreground *and* background *and* a font attribute at once;
// gen_styles.py proves that none of the 56 generated tables does. A table with
// no colours at all is byte-identical under either loop, so the choice is moot
// there.
render_tokens :: proc(w: io.Writer, tokens: []Token, escapes: []Style_Escape) -> io.Error {
	terminal_formatter := escapes_are_terminal_formatter(escapes)

	for token in tokens {
		escape := escape_for(escapes, token.kind)
		if terminal_formatter {
			if err := render_token_splitlines(w, token.text, escape); err != .None {
				return err
			}
		} else {
			if err := render_token_split_newline(w, token.text, escape); err != .None {
				return err
			}
		}
	}
	return nil
}

// lex_text runs pygments' TextLexer (pygments/lexers/special.py:34-35): the
// whole (preprocessed) text as a single Text token.
lex_text :: proc(text: string, allocator: mem.Allocator) -> Lexed {
	storage := preprocess(text, allocator)
	tokens := make([dynamic]Token, 0, 1, allocator)
	append(&tokens, Token{kind = .Text, text = storage})
	return Lexed{storage = storage, tokens = tokens}
}

// lex_metadata runs httpie's MetadataLexer (httpie/output/lexers/metadata.py:33)
// with `precise` deciding whether the speed tokens are the precise
// Number.SPEED.* ones (pie styles) or plain Number.
lex_metadata :: proc(text: string, precise: bool, allocator: mem.Allocator) -> Lexed {
	storage := preprocess(text, allocator)
	tokens := make([dynamic]Token, allocator)
	metadata_tokens(storage, precise, &tokens)
	return Lexed{storage = storage, tokens = tokens}
}

// lex_headers runs the HTTP head lexer for `variant` (see Lex_Variant). All of
// them preprocess the input exactly like `pygments.Lexer.get_tokens` does.
lex_headers :: proc(text: string, variant: Lex_Variant, allocator: mem.Allocator) -> Lexed {
	storage := preprocess(text, allocator)
	tokens := make([dynamic]Token, allocator)
	switch variant {
	case .Pygments_Http:
		http_tokens(storage, &tokens, allocator)
	case .Simplified_Head:
		simplified_http_tokens(storage, false, &tokens)
	case .Simplified_Precise:
		simplified_http_tokens(storage, true, &tokens)
	}
	return Lexed{storage = storage, tokens = tokens}
}

// lex_json runs httpie's EnhancedJsonLexer (httpie/output/lexers/json.py:11),
// which is pygments' JsonLexer wrapped so that non-JSON data prefixed to a JSON
// body becomes an Error token instead of failing.
lex_json :: proc(text: string, allocator: mem.Allocator) -> Lexed {
	storage := preprocess(text, allocator)
	tokens := make([dynamic]Token, allocator)

	if prefix := json_prefix_length(storage); prefix > 0 {
		append(&tokens, Token{kind = .Error, text = storage[:prefix]})
		json_tokens(storage[prefix:], &tokens, allocator)
	} else {
		json_tokens(storage, &tokens, allocator)
	}
	return Lexed{storage = storage, tokens = tokens}
}

// lex_xml runs pygments' XmlLexer (pygments/lexers/html.py:195-234). httpie
// reaches it for every mime type pygments resolves to it -- application/xml,
// text/xml, image/svg+xml, application/rss+xml and application/atom+xml
// (html.py:206-207, colors.py:142-194). The second result is always true: the
// lexer has no way to fail, so XML bodies are always coloured.
lex_xml :: proc(text: string, allocator: mem.Allocator) -> (Lexed, bool) {
	storage := preprocess(text, allocator)
	tokens := make([dynamic]Token, allocator)
	xml_tokens(storage, &tokens)
	return Lexed{storage = storage, tokens = tokens}, true
}

// ---------------------------------------------------------------------------
// pygments XmlLexer (pygments/lexers/html.py:195-234)
// ---------------------------------------------------------------------------

// Xml_State is XmlLexer's three states, plus the "this rule does not change
// state" marker the rule tables use. RegexLexer keeps the states on a stack,
// but this lexer only ever pushes 'tag' from 'root' and 'attr' from 'tag', and
// pops one level, so a single state variable is equivalent
// (pygments/lexer.py:713-745).
@(private)
Xml_State :: enum u8 {
	Unchanged,
	Root,
	Tag,
	Attr,
}

// Xml_Rule is one `(regex, token, new_state)` entry of XmlLexer.tokens.
@(private)
Xml_Rule :: struct {
	match: proc(text: string, pos: int) -> int,
	kind:  Token_Kind,
	next:  Xml_State,
}

// xml_root_rules are the `root` state's nine rules, in order. The regex of each
// is the comment above its matcher proc.
@(private)
XML_ROOT_RULES := []Xml_Rule {
	{xml_rule_text_run, .Text, .Unchanged},             // `[^<&\s]+`
	{xml_rule_space_run, .Whitespace, .Unchanged},      // `[^<&\S]+`
	{xml_rule_entity, .Name_Entity, .Unchanged},        // `&\S*?;`
	{xml_rule_cdata, .Comment_Preproc, .Unchanged},     // `\<\!\[CDATA\[.*?\]\]\>`
	{xml_rule_comment, .Comment_Multiline, .Unchanged}, // `<!--.*?-->`
	{xml_rule_pi, .Comment_Preproc, .Unchanged},        // `<\?.*?\?>`
	{xml_rule_declaration, .Comment_Preproc, .Unchanged}, // `<![^>]*>`
	{xml_rule_open_tag, .Name_Tag, .Tag},               // `<\s*[\w:.-]+`, push 'tag'
	{xml_rule_close_tag, .Name_Tag, .Unchanged},        // `<\s*/\s*[\w:.-]+\s*>`
}

// xml_tag_rules are the `tag` state's three rules.
@(private)
XML_TAG_RULES := []Xml_Rule {
	{xml_rule_space_run, .Whitespace, .Unchanged},   // `\s+`
	{xml_rule_attribute, .Name_Attribute, .Attr},    // `[\w.:-]+\s*=`, push 'attr'
	{xml_rule_tag_end, .Name_Tag, .Root},            // `/?\s*>`, pop
}

// xml_attr_rules are the `attr` state's four rules; each of the value rules
// pops back to 'tag'.
@(private)
XML_ATTR_RULES := []Xml_Rule {
	{xml_rule_space_run, .Whitespace, .Unchanged},      // `\s+`
	{xml_rule_double_quoted, .String, .Tag},            // `".*?"`
	{xml_rule_single_quoted, .String, .Tag},            // `'.*?'`
	{xml_rule_unquoted, .String, .Tag},                 // `[^\s>]+`
}

@(private)
xml_state_rules :: proc(state: Xml_State) -> []Xml_Rule {
	switch state {
	case .Tag:
		return XML_TAG_RULES
	case .Attr:
		return XML_ATTR_RULES
	case .Root, .Unchanged:
		return XML_ROOT_RULES
	}
	return XML_ROOT_RULES
}

// xml_tokens ports XmlLexer.get_tokens_unprocessed. The rules of the current
// state are tried in the order the class body lists them, the first match wins,
// its state transition is applied, and a position no rule matches falls through
// to RegexLexer's fallback: a newline resets the state to 'root' and becomes
// Whitespace, anything else becomes one Error token.
@(private)
xml_tokens :: proc(text: string, tokens: ^[dynamic]Token) {
	state := Xml_State.Root
	pos := 0
	for pos < len(text) {
		start := pos
		kind: Token_Kind
		end := -1
		next := Xml_State.Unchanged

		for rule in xml_state_rules(state) {
			if matched := rule.match(text, pos); matched >= 0 {
				kind = rule.kind
				end = matched
				next = rule.next
				break
			}
		}

		if end >= 0 {
			if next != .Unchanged {
				state = next
			}
			pos = end
			append(tokens, Token{kind = kind, text = text[start:pos]})
			continue
		}

		// RegexLexer's fallback (pygments/lexer.py:746-753).
		if text[pos] == '\n' {
			state = .Root
			append(tokens, Token{kind = .Whitespace, text = text[pos:pos + 1]})
		} else {
			append(tokens, Token{kind = .Error, text = text[pos:pos + 1]})
		}
		pos += 1
	}
}

// xml_is_word_char is the ASCII subset of Python's `\w` (the Unicode one is
// documented as not emulated).
@(private)
xml_is_word_char :: proc(c: u8) -> bool {
	return is_alpha(c) || is_digit(c) || c == '_'
}

// xml_rule_is_name_char is `[\w:.-]`.
@(private)
xml_rule_is_name_char :: proc(c: u8) -> bool {
	return xml_is_word_char(c) || c == ':' || c == '.' || c == '-'
}

// xml_rule_text_run is `[^<&\s]+`.
@(private)
xml_rule_text_run :: proc(text: string, pos: int) -> int {
	i := pos
	for i < len(text) {
		c := text[i]
		if c == '<' || c == '&' || is_py_space(c) {
			break
		}
		i += 1
	}
	return i == pos ? -1 : i
}

// xml_rule_space_run is `[^<&\S]+` -- whitespace, and neither `<` nor `&` is
// whitespace, so the class is plain `\s`.
@(private)
xml_rule_space_run :: proc(text: string, pos: int) -> int {
	i := pos
	for i < len(text) && is_py_space(text[i]) {
		i += 1
	}
	return i == pos ? -1 : i
}

// xml_rule_entity is `&\S*?;` (lazy, so the first `;` wins).
@(private)
xml_rule_entity :: proc(text: string, pos: int) -> int {
	if pos >= len(text) || text[pos] != '&' {
		return -1
	}
	i := pos + 1
	for i < len(text) {
		if text[i] == ';' {
			return i + 1
		}
		if is_py_space(text[i]) {
			return -1
		}
		i += 1
	}
	return -1
}

// xml_rule_cdata is `\<\!\[CDATA\[.*?\]\]\>`; `.` is DOTALL, so the section may
// span lines.
@(private)
xml_rule_cdata :: proc(text: string, pos: int) -> int {
	if !strings.has_prefix(text[pos:], "<![CDATA[") {
		return -1
	}
	end := strings.index(text[pos:], "]]>")
	return end < 0 ? -1 : pos + end + len("]]>")
}

// xml_rule_comment is `<!--.*?-->`.
@(private)
xml_rule_comment :: proc(text: string, pos: int) -> int {
	if !strings.has_prefix(text[pos:], "<!--") {
		return -1
	}
	end := strings.index(text[pos:], "-->")
	return end < 0 ? -1 : pos + end + len("-->")
}

// xml_rule_pi is `<\?.*?\?>`.
@(private)
xml_rule_pi :: proc(text: string, pos: int) -> int {
	if !strings.has_prefix(text[pos:], "<?") {
		return -1
	}
	end := strings.index(text[pos:], "?>")
	return end < 0 ? -1 : pos + end + len("?>")
}

// xml_rule_declaration is `<![^>]*>`: a DOCTYPE or other declaration markup,
// which the lexer colours like any other Comment.Preproc.
@(private)
xml_rule_declaration :: proc(text: string, pos: int) -> int {
	if pos + 1 >= len(text) || text[pos] != '<' || text[pos + 1] != '!' {
		return -1
	}
	i := pos + 2
	for i < len(text) && text[i] != '>' {
		i += 1
	}
	return i >= len(text) ? -1 : i + 1
}

// xml_rule_open_tag is `<\s*[\w:.-]+`; the lexer only needs the tag *name* here,
// the rest of the tag is lexed in the 'tag' state.
@(private)
xml_rule_open_tag :: proc(text: string, pos: int) -> int {
	if pos >= len(text) || text[pos] != '<' {
		return -1
	}
	i := pos + 1
	for i < len(text) && is_py_space(text[i]) {
		i += 1
	}
	start := i
	for i < len(text) && xml_rule_is_name_char(text[i]) {
		i += 1
	}
	return i == start ? -1 : i
}

// xml_rule_close_tag is `<\s*/\s*[\w:.-]+\s*>`, the complete `</name>` form.
@(private)
xml_rule_close_tag :: proc(text: string, pos: int) -> int {
	if pos >= len(text) || text[pos] != '<' {
		return -1
	}
	i := pos + 1
	for i < len(text) && is_py_space(text[i]) {
		i += 1
	}
	if i >= len(text) || text[i] != '/' {
		return -1
	}
	i += 1
	for i < len(text) && is_py_space(text[i]) {
		i += 1
	}
	start := i
	for i < len(text) && xml_rule_is_name_char(text[i]) {
		i += 1
	}
	if i == start {
		return -1
	}
	for i < len(text) && is_py_space(text[i]) {
		i += 1
	}
	if i >= len(text) || text[i] != '>' {
		return -1
	}
	return i + 1
}

// xml_rule_attribute is `[\w.:-]+\s*=` in the 'tag' state.
@(private)
xml_rule_attribute :: proc(text: string, pos: int) -> int {
	i := pos
	for i < len(text) && xml_rule_is_name_char(text[i]) {
		i += 1
	}
	if i == pos {
		return -1
	}
	j := i
	for j < len(text) && is_py_space(text[j]) {
		j += 1
	}
	if j >= len(text) || text[j] != '=' {
		return -1
	}
	return j + 1
}

// xml_rule_tag_end is `/?\s*>` in the 'tag' state: `>` or `/>`, with any amount
// of whitespace in front of the `>`.
@(private)
xml_rule_tag_end :: proc(text: string, pos: int) -> int {
	i := pos
	if i < len(text) && text[i] == '/' {
		i += 1
	}
	j := i
	for j < len(text) && is_py_space(text[j]) {
		j += 1
	}
	if j >= len(text) || text[j] != '>' {
		return -1
	}
	return j + 1
}

// xml_rule_double_quoted / xml_rule_single_quoted are `".*?"` and `'.*?'` in
// the 'attr' state (DOTALL again, so a quoted value may hold newlines).
@(private)
xml_rule_double_quoted :: proc(text: string, pos: int) -> int {
	return xml_rule_quoted(text, pos, '"')
}

@(private)
xml_rule_single_quoted :: proc(text: string, pos: int) -> int {
	return xml_rule_quoted(text, pos, '\'')
}

@(private)
xml_rule_quoted :: proc(text: string, pos: int, quote: u8) -> int {
	if pos >= len(text) || text[pos] != quote {
		return -1
	}
	end := strings.index_byte(text[pos + 1:], quote)
	return end < 0 ? -1 : pos + 1 + end + 1
}

// xml_rule_unquoted is `[^\s>]+` in the 'attr' state.
@(private)
xml_rule_unquoted :: proc(text: string, pos: int) -> int {
	i := pos
	for i < len(text) && !is_py_space(text[i]) && text[i] != '>' {
		i += 1
	}
	return i == pos ? -1 : i
}

// ---------------------------------------------------------------------------
// Formatter emulation helpers
// ---------------------------------------------------------------------------

// TERMINAL_FORMATTER_RESET is the literal reset `pygments.console.ansiformat`
// appends to every coloured run (pygments/console.py:15, :69). It is also the
// discriminator render_tokens uses; see its doc comment.
TERMINAL_FORMATTER_RESET :: "\x1b[39;49;00m"

@(private)
escape_for :: proc(escapes: []Style_Escape, kind: Token_Kind) -> Style_Escape {
	index := int(kind)
	if index >= 0 && index < len(escapes) {
		return escapes[index]
	}
	return {}
}

@(private)
escapes_are_terminal_formatter :: proc(escapes: []Style_Escape) -> bool {
	coloured := 0
	with_terminal_reset := 0
	for escape in escapes {
		if escape.prefix == "" {
			continue
		}
		coloured += 1
		if escape.reset == TERMINAL_FORMATTER_RESET {
			with_terminal_reset += 1
		}
	}
	return coloured > 0 && coloured == with_terminal_reset
}

// render_token_splitlines is TerminalFormatter.format_unencoded's per-token
// loop (pygments/formatters/terminal.py:112-124): `value.splitlines(True)`,
// `line.rstrip('\n')` and a '\n' re-appended when the line had one.
@(private)
render_token_splitlines :: proc(w: io.Writer, text: string, escape: Style_Escape) -> io.Error {
	start := 0
	for {
		piece, had_newline, next := splitlines_next(text, start)
		if next < 0 {
			return nil
		}
		content := piece
		if had_newline {
			content = piece[:len(piece) - 1]
		}
		if err := write_escaped(w, content, escape, true); err != .None {
			return err
		}
		if had_newline {
			if err := write_raw(w, "\n"); err != .None {
				return err
			}
		}
		start = next
	}
}

// render_token_split_newline is Terminal256Formatter.format_unencoded's
// per-token loop (pygments/formatters/terminal256.py:256-286): the value is
// split on '\n' only, empty pieces get no escapes at all, and the piece after
// the last '\n' is written without a trailing newline.
@(private)
render_token_split_newline :: proc(w: io.Writer, text: string, escape: Style_Escape) -> io.Error {
	rest := text
	for {
		index := strings.index_byte(rest, '\n')
		piece := rest
		had_newline := false
		if index >= 0 {
			piece = rest[:index]
			rest = rest[index + 1:]
			had_newline = true
		} else {
			rest = ""
		}
		if piece != "" {
			if err := write_escaped(w, piece, escape, true); err != .None {
				return err
			}
		}
		if had_newline {
			if err := write_raw(w, "\n"); err != .None {
				return err
			}
			continue
		}
		break
	}
	return nil
}

// write_escaped writes `content` and, when the token has a style, wraps it in
// the pygments escape pair. `emit_empty` distinguishes the two formatter loops:
// TerminalFormatter wraps an empty line too, Terminal256Formatter does not.
@(private)
write_escaped :: proc(w: io.Writer, content: string, escape: Style_Escape, emit_empty: bool) -> io.Error {
	if escape.prefix == "" || (content == "" && !emit_empty) {
		return write_raw(w, content)
	}
	if err := write_raw(w, escape.prefix); err != .None {
		return err
	}
	if err := write_raw(w, content); err != .None {
		return err
	}
	return write_raw(w, escape.reset)
}

@(private)
write_raw :: proc(w: io.Writer, s: string) -> io.Error {
	if len(s) == 0 {
		return nil
	}
	_, err := io.write_string(w, s)
	return err
}

// splitlines_next returns the next piece of Python's
// `str.splitlines(keepends=True)`, starting at `start`; `next` is -1 when the
// text is exhausted. The ASCII boundaries plus the Unicode ones Python also
// breaks on (\x85, U+2028, U+2029) are recognised. `had_newline` is whether the
// piece ended with '\n' -- that is what TerminalFormatter tests
// (`if line.endswith('\n')`), not whether it ended with any line boundary.
@(private)
splitlines_next :: proc(text: string, start: int) -> (piece: string, had_newline: bool, next: int) {
	if start >= len(text) {
		return "", false, -1
	}
	for i := start; i < len(text); {
		c := text[i]
		width := 0
		switch c {
		case '\n':
			width = 1
		case '\r':
			width = (i + 1 < len(text) && text[i + 1] == '\n') ? 2 : 1
		case '\v', '\f', '\x1c', '\x1d', '\x1e':
			width = 1
		case 0xc2:
			if i + 1 < len(text) && text[i + 1] == 0x85 {
				width = 2
			}
		case 0xe2:
			if i + 2 < len(text) && text[i + 1] == 0x80 &&
			   (text[i + 2] == 0xa8 || text[i + 2] == 0xa9) {
				width = 3
			}
		}
		if width > 0 {
			return text[start:i + width], c == '\n', i + width
		}
		i += 1
	}
	return text[start:], false, len(text)
}

// ---------------------------------------------------------------------------
// Lexer preprocessing (pygments/lexer.py:218-263)
// ---------------------------------------------------------------------------

// preprocess is `Lexer._preprocess_lexer_input` with the defaults every lexer
// httpie uses is constructed with: `stripnl=True`, `stripall=False`,
// `tabsize=0`, `ensurenl=True` and a `str` input, i.e.
//
//	text = text.replace('\r\n', '\n').replace('\r', '\n')
//	text = text.strip('\n')
//	if not text.endswith('\n'): text += '\n'
//
// The result is a fresh allocation owned by the caller.
@(private)
preprocess :: proc(text: string, allocator: mem.Allocator) -> string {
	normalized := strings.builder_make(allocator)
	defer strings.builder_destroy(&normalized)

	start := 0
	for i := 0; i < len(text); i += 1 {
		if text[i] != '\r' {
			continue
		}
		strings.write_string(&normalized, text[start:i])
		strings.write_byte(&normalized, '\n')
		if i + 1 < len(text) && text[i + 1] == '\n' {
			i += 1
		}
		start = i + 1
	}
	strings.write_string(&normalized, text[start:])

	stripped := strings.trim(strings.to_string(normalized), "\n")
	out := strings.builder_make(allocator)
	strings.write_string(&out, stripped)
	if !strings.has_suffix(stripped, "\n") {
		strings.write_byte(&out, '\n')
	}
	return strings.to_string(out)
}

// ---------------------------------------------------------------------------
// Character classes
// ---------------------------------------------------------------------------

// The Python regexes below use re's character classes. Python's `\s`/`\d`/`\w`
// are Unicode-aware for `str` patterns; the ASCII subset is implemented here and
// the difference is documented in docs/COLORIZE.md. Everything else -- the
// literal sets JsonLexer uses (`integers`, `floats`, `constants`, ...) -- is
// ASCII in pygments itself, so it is exact.

@(private)
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// is_py_space is Python's ASCII `\s`: space, tab, newline, carriage return,
// form feed, vertical tab.
@(private)
is_py_space :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', '\v', '\f':
		return true
	}
	return false
}

@(private)
contains_byte :: proc(set: string, c: u8) -> bool {
	return strings.index_byte(set, c) >= 0
}

// rune_in is Python's `character in <set of single characters>`: only ASCII
// characters can ever be members, so a rune above 0x7f is never in the set
// (truncating it to a byte, as an unguarded cast would, would be wrong).
@(private)
rune_in :: proc(set: string, c: rune) -> bool {
	return c <= 0x7f && contains_byte(set, u8(c))
}

// ---------------------------------------------------------------------------
// JsonLexer (pygments/lexers/data.py:446-698)
// ---------------------------------------------------------------------------

// The JsonLexer character sets, verbatim from the class body (data.py:459-467).
JSON_INTEGERS :: "-0123456789"
JSON_FLOATS :: ".eE+"
JSON_CONSTANTS :: "truefalsenull"
JSON_HEXADECIMALS :: "0123456789abcdefABCDEF"
JSON_PUNCTUATIONS :: "{}[],"
JSON_WHITESPACES :: " \n\r\t"

// JSON_QUEUED is JsonLexer's `queue`: a quoted string whose token type is only
// known once the character after it is seen (data.py:487-505).
@(private)
JSON_Queued :: struct {
	text: string,
	kind: Token_Kind,
}

// json_byte_range is `text[start:stop]` in *character* indices.
@(private)
json_byte_range :: proc(text: string, offsets: []int, start: int, stop: int) -> string {
	return text[offsets[start]:offsets[stop]]
}

// json_exhaust_queue is `yield from queue; queue.clear()`.
@(private)
json_exhaust_queue :: proc(tokens: ^[dynamic]Token, queue: ^[dynamic]JSON_Queued) {
	for item in queue {
		append(tokens, Token{kind = item.kind, text = item.text})
	}
	clear(queue)
}

// json_emit_or_queue appends to the queue instead of yielding when earlier
// tokens are still pending, so their order is preserved (data.py:539-542,
// :581-584, :595-598).
@(private)
json_emit_or_queue :: proc(
	tokens: ^[dynamic]Token,
	queue: ^[dynamic]JSON_Queued,
	kind: Token_Kind,
	value: string,
) {
	if len(queue) > 0 {
		append(queue, JSON_Queued{text = value, kind = kind})
	} else {
		append(tokens, Token{kind = kind, text = value})
	}
}

// json_tokens ports JsonLexer.get_tokens_unprocessed. The control flow, the
// queue and the "fall through so the new character can be evaluated" comments
// are preserved one-to-one; the only translation is that Python iterates
// *characters* while Odin slices *bytes*, so a rune -> byte offset table is
// built up front.
//
// The three scratch buffers take `allocator` explicitly: they are the only
// allocations in this file that are not a token array, and main.odin's rule
// (README.md, "Memory ownership") is that every site names its allocator
// instead of reaching for the implicit context one.
@(private)
json_tokens :: proc(text: string, tokens: ^[dynamic]Token, allocator: mem.Allocator) {
	offsets := make([dynamic]int, 0, len(text) + 1, allocator)
	defer delete(offsets)
	runes := make([dynamic]rune, 0, len(text), allocator)
	defer delete(runes)

	for i := 0; i < len(text); {
		append(&offsets, i)
		r, size := utf8.decode_rune_in_string(text[i:])
		if size <= 0 {
			r, size = utf8.RUNE_ERROR, 1
		}
		append(&runes, r)
		i += size
	}
	append(&offsets, len(text))

	in_string := false
	in_escape := false
	in_unicode_escape := 0
	in_whitespace := false
	in_constant := false
	in_number := false
	in_float := false
	in_punctuation := false
	in_comment_single := false
	in_comment_multiline := false
	expecting_second_comment_opener := false
	expecting_second_comment_closer := false

	start := 0
	queue := make([dynamic]JSON_Queued, 0, 8, allocator)
	defer delete(queue)

	for stop := 0; stop < len(runes); stop += 1 {
		character := runes[stop]

		if in_string {
			// data.py:508-533
			if in_unicode_escape > 0 {
				if rune_in(JSON_HEXADECIMALS, character) {
					in_unicode_escape -= 1
					if in_unicode_escape == 0 {
						in_escape = false
					}
				} else {
					in_unicode_escape = 0
					in_escape = false
				}
			} else if in_escape {
				if character == 'u' {
					in_unicode_escape = 4
				} else {
					in_escape = false
				}
			} else if character == '\\' {
				in_escape = true
			} else if character == '"' {
				append(&queue, JSON_Queued {
					text = json_byte_range(text, offsets[:], start, stop + 1),
					kind = .String_Double,
				})
				in_string = false
				in_escape = false
				in_unicode_escape = 0
			}
			continue
		} else if in_whitespace {
			if rune_in(JSON_WHITESPACES, character) {
				continue
			}
			json_emit_or_queue(tokens, &queue, .Whitespace, json_byte_range(text, offsets[:], start, stop))
			in_whitespace = false
			// Fall through so the new character can be evaluated.
		} else if in_constant {
			if rune_in(JSON_CONSTANTS, character) {
				continue
			}
			append(tokens, Token {
				kind = .Keyword_Constant,
				text = json_byte_range(text, offsets[:], start, stop),
			})
			in_constant = false
		} else if in_number {
			if rune_in(JSON_INTEGERS, character) {
				continue
			} else if rune_in(JSON_FLOATS, character) {
				in_float = true
				continue
			}
			append(tokens, Token {
				kind = in_float ? .Number_Float : .Number_Integer,
				text = json_byte_range(text, offsets[:], start, stop),
			})
			in_number = false
			in_float = false
		} else if in_punctuation {
			if rune_in(JSON_PUNCTUATIONS, character) {
				continue
			}
			append(tokens, Token {
				kind = .Punctuation,
				text = json_byte_range(text, offsets[:], start, stop),
			})
			in_punctuation = false
		} else if in_comment_single {
			if character != '\n' {
				continue
			}
			json_emit_or_queue(tokens, &queue, .Comment_Single, json_byte_range(text, offsets[:], start, stop))
			in_comment_single = false
		} else if in_comment_multiline {
			if character == '*' {
				expecting_second_comment_closer = true
			} else if expecting_second_comment_closer {
				expecting_second_comment_closer = false
				if character == '/' {
					json_emit_or_queue(
						tokens,
						&queue,
						.Comment_Multiline,
						json_byte_range(text, offsets[:], start, stop + 1),
					)
					in_comment_multiline = false
				}
			}
			continue
		} else if expecting_second_comment_opener {
			expecting_second_comment_opener = false
			if character == '/' {
				in_comment_single = true
				continue
			} else if character == '*' {
				in_comment_multiline = true
				continue
			}
			json_exhaust_queue(tokens, &queue)
			append(tokens, Token {
				kind = .Error,
				text = json_byte_range(text, offsets[:], start, stop),
			})
		}

		start = stop

		if character == '"' {
			in_string = true
		} else if rune_in(JSON_WHITESPACES, character) {
			in_whitespace = true
		} else if character == 'f' || character == 'n' || character == 't' {
			// The first letters of true|false|null (data.py:628).
			json_exhaust_queue(tokens, &queue)
			in_constant = true
		} else if rune_in(JSON_INTEGERS, character) {
			json_exhaust_queue(tokens, &queue)
			in_number = true
		} else if character == ':' {
			// data.py:642-659: a quoted string in front of a ':' was an object
			// key after all, so it becomes Name.Tag.
			for item in queue {
				append(tokens, Token {
					kind = item.kind == .String_Double ? .Name_Tag : item.kind,
					text = item.text,
				})
			}
			clear(&queue)
			in_punctuation = true
		} else if rune_in(JSON_PUNCTUATIONS, character) {
			json_exhaust_queue(tokens, &queue)
			in_punctuation = true
		} else if character == '/' {
			expecting_second_comment_opener = true
		} else {
			json_exhaust_queue(tokens, &queue)
			// `yield start, Error, character` -- exactly this character.
			append(tokens, Token {
				kind = .Error,
				text = json_byte_range(text, offsets[:], stop, stop + 1),
			})
		}
	}

	// Yield any remaining text (data.py:679-698).
	json_exhaust_queue(tokens, &queue)
	if in_string {
		append(tokens, Token{kind = .Error, text = text[offsets[start]:]})
	} else if in_float {
		append(tokens, Token{kind = .Number_Float, text = text[offsets[start]:]})
	} else if in_number {
		append(tokens, Token{kind = .Number_Integer, text = text[offsets[start]:]})
	} else if in_constant {
		append(tokens, Token{kind = .Keyword_Constant, text = text[offsets[start]:]})
	} else if in_whitespace {
		append(tokens, Token{kind = .Whitespace, text = text[offsets[start]:]})
	} else if in_punctuation {
		append(tokens, Token{kind = .Punctuation, text = text[offsets[start]:]})
	} else if in_comment_single {
		append(tokens, Token{kind = .Comment_Single, text = text[offsets[start]:]})
	} else if in_comment_multiline {
		append(tokens, Token{kind = .Error, text = text[offsets[start]:]})
	} else if expecting_second_comment_opener {
		append(tokens, Token{kind = .Error, text = text[offsets[start]:]})
	}
}

// ---------------------------------------------------------------------------
// EnhancedJsonLexer (httpie/output/lexers/json.py:11-31)
// ---------------------------------------------------------------------------

// json_starts_value is the second group of the EnhancedJsonLexer prefix rule,
// `(?:[{\["]|true|false|null)`, matched with re.IGNORECASE.
@(private)
json_starts_value :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	switch s[0] {
	case '{', '[', '"':
		return true
	}
	for word in ([]string{"true", "false", "null"}) {
		if len(s) >= len(word) && strings.equal_fold(s[:len(word)], word) {
			return true
		}
	}
	return false
}

// json_prefix_length returns the length of the leading non-JSON data the
// EnhancedJsonLexer's first rule would turn into an Error token, or 0 when the
// whole input is JSON (the second rule, `(.+)`, matches).
//
// The rule is `([^{\["]+)((?:[{\["]|true|false|null).+)` with DOTALL, matched at
// position 0. `[^{\["]+` is greedy and both `.` and the star run across newlines
// under DOTALL, so the regex takes the *longest* prefix whose remainder starts
// with a JSON value and has at least one more character after it.
@(private)
json_prefix_length :: proc(text: string) -> int {
	if len(text) < 2 {
		return 0
	}
	run_end := len(text)
	for i := 0; i < len(text); i += 1 {
		if text[i] == '{' || text[i] == '[' || text[i] == '"' {
			run_end = i
			break
		}
	}
	limit := min(run_end, len(text) - 2)
	for i := limit; i >= 1; i -= 1 {
		if json_starts_value(text[i:]) {
			return i
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// pygments HttpLexer (pygments/lexers/textfmts.py:116-200)
// ---------------------------------------------------------------------------

@(private)
HTTP_Match :: struct {
	group_start: [9]int,
	group_end:   [9]int,
	end:         int,
}

// http_match_terminator matches `(\r?\n|\Z)` at `pos`; `\Z` is Python's
// end-of-string anchor.
@(private)
http_match_terminator :: proc(text: string, pos: int) -> (int, bool) {
	if pos >= len(text) {
		return pos, true
	}
	if text[pos] == '\n' {
		return pos + 1, true
	}
	if text[pos] == '\r' && pos + 1 < len(text) && text[pos + 1] == '\n' {
		return pos + 2, true
	}
	return pos, false
}

// http_match_version matches `(1\.[01]|2(?:\.0)?|3)`, the HTTP versions the
// pygments HttpLexer accepts.
@(private)
http_match_version :: proc(text: string, pos: int) -> (int, bool) {
	if pos + 3 <= len(text) && text[pos] == '1' && text[pos + 1] == '.' &&
	   (text[pos + 2] == '0' || text[pos + 2] == '1') {
		return pos + 3, true
	}
	if pos + 3 <= len(text) && text[pos] == '2' && text[pos + 1] == '.' && text[pos + 2] == '0' {
		return pos + 3, true
	}
	if pos < len(text) && (text[pos] == '2' || text[pos] == '3') {
		return pos + 1, true
	}
	return pos, false
}

// http_match_request_line is the root rule
// `([a-zA-Z][-_a-zA-Z]+)( +)([^ ]+)( +)(HTTP)(/)(1\.[01]|2(?:\.0)?|3)(\r?\n|\Z)`
// (textfmts.py:79-83).
@(private)
http_match_request_line :: proc(text: string, pos: int, m: ^HTTP_Match) -> bool {
	if pos >= len(text) || !is_alpha(text[pos]) {
		return false
	}
	i := pos + 1
	j := i
	for j < len(text) && (is_alpha(text[j]) || text[j] == '-' || text[j] == '_') {
		j += 1
	}
	if j == i {
		return false
	}
	m.group_start[1], m.group_end[1] = pos, j

	k := j
	for k < len(text) && text[k] == ' ' {
		k += 1
	}
	if k == j {
		return false
	}
	m.group_start[2], m.group_end[2] = j, k

	l := k
	for l < len(text) && text[l] != ' ' {
		l += 1
	}
	if l == k {
		return false
	}
	m.group_start[3], m.group_end[3] = k, l

	n := l
	for n < len(text) && text[n] == ' ' {
		n += 1
	}
	if n == l {
		return false
	}
	m.group_start[4], m.group_end[4] = l, n

	if n + 5 > len(text) || text[n] != 'H' || text[n + 1] != 'T' || text[n + 2] != 'T' ||
	   text[n + 3] != 'P' || text[n + 4] != '/' {
		return false
	}
	m.group_start[5], m.group_end[5] = n, n + 4
	m.group_start[6], m.group_end[6] = n + 4, n + 5

	version_end, version_ok := http_match_version(text, n + 5)
	if !version_ok {
		return false
	}
	m.group_start[7], m.group_end[7] = n + 5, version_end

	end, terminator_ok := http_match_terminator(text, version_end)
	if !terminator_ok {
		return false
	}
	m.group_start[8], m.group_end[8] = version_end, end
	m.end = end
	return true
}

// http_match_status_line is the root rule
// `(HTTP)(/)(1\.[01]|2(?:\.0)?|3)( +)(\d{3})(?:( +)([^\r\n]*))?(\r?\n|\Z)`
// (textfmts.py:84-87).
@(private)
http_match_status_line :: proc(text: string, pos: int, m: ^HTTP_Match) -> bool {
	if pos + 5 > len(text) || text[pos] != 'H' || text[pos + 1] != 'T' || text[pos + 2] != 'T' ||
	   text[pos + 3] != 'P' || text[pos + 4] != '/' {
		return false
	}
	m.group_start[1], m.group_end[1] = pos, pos + 4
	m.group_start[2], m.group_end[2] = pos + 4, pos + 5

	version_end, version_ok := http_match_version(text, pos + 5)
	if !version_ok {
		return false
	}
	m.group_start[3], m.group_end[3] = pos + 5, version_end

	i := version_end
	j := i
	for j < len(text) && text[j] == ' ' {
		j += 1
	}
	if j == i {
		return false
	}
	m.group_start[4], m.group_end[4] = i, j

	if j + 3 > len(text) || !is_digit(text[j]) || !is_digit(text[j + 1]) || !is_digit(text[j + 2]) {
		return false
	}
	m.group_start[5], m.group_end[5] = j, j + 3

	// (?:( +)([^\r\n]*))?
	k := j + 3
	spaces_end := k
	for spaces_end < len(text) && text[spaces_end] == ' ' {
		spaces_end += 1
	}
	reason_end := spaces_end
	for reason_end < len(text) && text[reason_end] != '\r' && text[reason_end] != '\n' {
		reason_end += 1
	}
	m.group_start[6], m.group_end[6] = k, spaces_end
	m.group_start[7], m.group_end[7] = spaces_end, reason_end

	end, terminator_ok := http_match_terminator(text, reason_end)
	if !terminator_ok {
		return false
	}
	m.group_start[8], m.group_end[8] = reason_end, end
	m.end = end
	return true
}

// http_match_header is the `headers` rule
// `([^\s:]+)( *)(:)( *)([^\r\n]*)(\r?\n|\Z)` (textfmts.py:90).
@(private)
http_match_header :: proc(text: string, pos: int, m: ^HTTP_Match) -> bool {
	i := pos
	for i < len(text) && !is_py_space(text[i]) && text[i] != ':' {
		i += 1
	}
	if i == pos {
		return false
	}
	m.group_start[1], m.group_end[1] = pos, i

	j := i
	for j < len(text) && text[j] == ' ' {
		j += 1
	}
	m.group_start[2], m.group_end[2] = i, j

	if j >= len(text) || text[j] != ':' {
		return false
	}
	m.group_start[3], m.group_end[3] = j, j + 1

	k := j + 1
	l := k
	for l < len(text) && text[l] == ' ' {
		l += 1
	}
	m.group_start[4], m.group_end[4] = k, l

	value_end := l
	for value_end < len(text) && text[value_end] != '\r' && text[value_end] != '\n' {
		value_end += 1
	}
	m.group_start[5], m.group_end[5] = l, value_end

	end, terminator_ok := http_match_terminator(text, value_end)
	if !terminator_ok {
		return false
	}
	m.group_start[6], m.group_end[6] = value_end, end
	m.end = end
	return true
}

// http_match_continuation is the `headers` rule
// `([\t ]+)([^\r\n]+)(\r?\n|\Z)` (textfmts.py:91).
@(private)
http_match_continuation :: proc(text: string, pos: int, m: ^HTTP_Match) -> bool {
	i := pos
	for i < len(text) && (text[i] == '\t' || text[i] == ' ') {
		i += 1
	}
	if i == pos {
		return false
	}
	m.group_start[1], m.group_end[1] = pos, i

	value_end := i
	for value_end < len(text) && text[value_end] != '\r' && text[value_end] != '\n' {
		value_end += 1
	}
	if value_end == i {
		return false
	}
	m.group_start[2], m.group_end[2] = i, value_end

	end, terminator_ok := http_match_terminator(text, value_end)
	if !terminator_ok {
		return false
	}
	m.group_start[3], m.group_end[3] = value_end, end
	m.end = end
	return true
}

// http_tokens ports pygments' HttpLexer: `root` -> `headers` -> `content`
// (textfmts.py:77-97) plus RegexLexer's unmatched-character fallback
// (pygments/lexer.py:737-761). `content_type` is the state the
// `header_callback` keeps (textfmts.py:34-39) and `content_callback` consumes
// (textfmts.py:52-75): only the JSON mime types pygments resolves to JsonLexer
// are recognised here.
@(private)
http_tokens :: proc(text: string, tokens: ^[dynamic]Token, allocator: mem.Allocator) {
	HTTP_State :: enum {
		Root,
		Headers,
		Content,
	}

	state := HTTP_State.Root
	content_type := ""
	match: HTTP_Match
	pos := 0

	for pos < len(text) {
		matched := false
		switch state {
		case .Root:
			if http_match_request_line(text, pos, &match) {
				// bygroups(Name.Function, Text, Name.Namespace, Text,
				//          Keyword.Reserved, Operator, Number, Text)
				http_emit_group(tokens, &match, 1, .Name_Function, text)
				http_emit_group(tokens, &match, 2, .Text, text)
				http_emit_group(tokens, &match, 3, .Name_Namespace, text)
				http_emit_group(tokens, &match, 4, .Text, text)
				http_emit_group(tokens, &match, 5, .Keyword_Reserved, text)
				http_emit_group(tokens, &match, 6, .Operator, text)
				http_emit_group(tokens, &match, 7, .Number, text)
				http_emit_group(tokens, &match, 8, .Text, text)
				matched = true
			} else if http_match_status_line(text, pos, &match) {
				// bygroups(Keyword.Reserved, Operator, Number, Text, Number,
				//          Text, Name.Exception, Text)
				http_emit_group(tokens, &match, 1, .Keyword_Reserved, text)
				http_emit_group(tokens, &match, 2, .Operator, text)
				http_emit_group(tokens, &match, 3, .Number, text)
				http_emit_group(tokens, &match, 4, .Text, text)
				http_emit_group(tokens, &match, 5, .Number, text)
				http_emit_group(tokens, &match, 6, .Text, text)
				http_emit_group(tokens, &match, 7, .Name_Exception, text)
				http_emit_group(tokens, &match, 8, .Text, text)
				matched = true
			}
			if matched {
				state = .Headers
			}
		case .Headers:
			if http_match_header(text, pos, &match) {
				name := http_group(text, &match, 1)
				if strings.equal_fold(name, "content-type") {
					value := strings.trim_space(http_group(text, &match, 5))
					if index := strings.index_byte(value, ';'); index >= 0 {
						value = strings.trim_space(value[:index])
					}
					content_type = value
				}
				// header_callback yields all six groups unconditionally
				// (textfmts.py:40-45), so empty groups do become empty tokens.
				append(tokens, Token{kind = .Name_Attribute, text = name})
				append(tokens, Token{kind = .Text, text = http_group(text, &match, 2)})
				append(tokens, Token{kind = .Operator, text = http_group(text, &match, 3)})
				append(tokens, Token{kind = .Text, text = http_group(text, &match, 4)})
				append(tokens, Token{kind = .Literal, text = http_group(text, &match, 5)})
				append(tokens, Token{kind = .Text, text = http_group(text, &match, 6)})
				matched = true
			} else if http_match_continuation(text, pos, &match) {
				// continuous_header_callback (textfmts.py:47-50)
				append(tokens, Token{kind = .Text, text = http_group(text, &match, 1)})
				append(tokens, Token{kind = .Literal, text = http_group(text, &match, 2)})
				append(tokens, Token{kind = .Text, text = http_group(text, &match, 3)})
				matched = true
			} else if text[pos] == '\n' || (text[pos] == '\r' && pos + 1 < len(text) && text[pos + 1] == '\n') {
				// (`\r?\n`, Text, 'content')
				width := text[pos] == '\r' ? 2 : 1
				append(tokens, Token{kind = .Text, text = text[pos:pos + width]})
				pos += width
				state = .Content
				continue
			}
		case .Content:
			// ('.+', content_callback) -- DOTALL, so it eats the whole rest.
			content := text[pos:]
			if content != "" {
				http_content_tokens(content, content_type, tokens, allocator)
				pos = len(text)
				continue
			}
		}

		if matched {
			pos = match.end
			continue
		}

		// RegexLexer's fallback (pygments/lexer.py:746-753): at a newline the
		// state stack is reset to 'root' and a Whitespace token is produced,
		// otherwise one Error token per unmatched character.
		if text[pos] == '\n' {
			state = .Root
			append(tokens, Token{kind = .Whitespace, text = text[pos:pos + 1]})
		} else {
			append(tokens, Token{kind = .Error, text = text[pos:pos + 1]})
		}
		pos += 1
	}
}

// http_content_tokens is `HttpLexer.content_callback` (textfmts.py:52-75): the
// body after the blank line is re-lexed with the lexer pygments resolves for
// the Content-Type the head declared, or emitted as plain Text.
@(private)
http_content_tokens :: proc(
	content: string,
	content_type: string,
	tokens: ^[dynamic]Token,
	allocator: mem.Allocator,
) {
	if content_type != "" {
		for mime in JSON_LEXER_MIMETYPES {
			if content_type == mime {
				// get_lexer_for_mimetype resolves application/json to
				// pygments' JsonLexer, *not* to httpie's EnhancedJsonLexer.
				json_tokens(content, tokens, allocator)
				return
			}
		}
	}
	append(tokens, Token{kind = .Text, text = content})
}

// JSON_LEXER_MIMETYPES are the mime types pygments' JsonLexer advertises
// (pygments/lexers/data.py:452).
JSON_LEXER_MIMETYPES :: []string {
	"application/json",
	"application/json-object",
	"application/x-ndjson",
	"application/jsonl",
	"application/json-seq",
}

@(private)
http_group :: proc(text: string, m: ^HTTP_Match, group: int) -> string {
	return text[m.group_start[group]:m.group_end[group]]
}

// http_emit_group mirrors pygments' `bygroups`: a token type is only yielded
// for a *non-empty* group (pygments/lexer.py:74-77).
@(private)
http_emit_group :: proc(tokens: ^[dynamic]Token, m: ^HTTP_Match, group: int, kind: Token_Kind, text: string) {
	value := http_group(text, m, group)
	if value != "" {
		append(tokens, Token{kind = kind, text = value})
	}
}

// ---------------------------------------------------------------------------
// httpie SimplifiedHTTPLexer (httpie/output/lexers/http.py:54-97)
// ---------------------------------------------------------------------------

// RESPONSE_METHODS is httpie's RESPONSE_TYPES (http.py:15-22).
RESPONSE_METHODS :: []struct {
	name: string,
	kind: Token_Kind,
} {
	{"GET", .Name_Function_HttpGet},
	{"HEAD", .Name_Function_HttpHead},
	{"POST", .Name_Function_HttpPost},
	{"PUT", .Name_Function_HttpPut},
	{"PATCH", .Name_Function_HttpPatch},
	{"DELETE", .Name_Function_HttpDelete},
}

// STATUS_KINDS is httpie's STATUS_TYPES (http.py:7-13), keyed by the first
// digit of the status code.
@(private)
status_kind :: proc(digit: u8) -> (Token_Kind, bool) {
	switch digit {
	case '1':
		return .Number_Http_Info, true
	case '2':
		return .Number_Http_Ok, true
	case '3':
		return .Number_Http_Redirect, true
	case '4':
		return .Number_Http_Client_Error, true
	case '5':
		return .Number_Http_Server_Error, true
	}
	return .Number, false
}

// simplified_http_tokens ports httpie's SimplifiedHTTPLexer. Its three root
// rules are matched in order at each position, `.` never crosses a newline
// (RegexLexer's default flags are re.MULTILINE only, and MULTILINE does not
// change `.`), and unmatched characters fall through to RegexLexer's fallback --
// which is where every newline of a header block ends up, as a Whitespace token.
@(private)
simplified_http_tokens :: proc(text: string, precise: bool, tokens: ^[dynamic]Token) {
	pos := 0
	for pos < len(text) {
		// ([A-Z]+)( +)([^ ]+)( +)(HTTP)(/)(\d+\.\d+)   (http.py:69-78)
		if end, ok := simplified_match_request_line(text, pos, precise, tokens); ok {
			pos = end
			continue
		}
		// (HTTP)(/)(\d+\.\d+)( +)(.+)                (http.py:80-87)
		if end, ok := simplified_match_status_line(text, pos, precise, tokens); ok {
			pos = end
			continue
		}
		// (.*?)( *)(:)( *)(.+)                       (http.py:89-95)
		if end, ok := simplified_match_header(text, pos, tokens); ok {
			pos = end
			continue
		}
		// RegexLexer fallback (pygments/lexer.py:746-753).
		if text[pos] == '\n' {
			append(tokens, Token{kind = .Whitespace, text = text[pos:pos + 1]})
		} else {
			append(tokens, Token{kind = .Error, text = text[pos:pos + 1]})
		}
		pos += 1
	}
}

@(private)
simplified_match_request_line :: proc(text: string, pos: int, precise: bool, tokens: ^[dynamic]Token) -> (int, bool) {
	i := pos
	for i < len(text) && text[i] >= 'A' && text[i] <= 'Z' {
		i += 1
	}
	if i == pos {
		return pos, false
	}
	method := text[pos:i]

	j := i
	for j < len(text) && text[j] == ' ' {
		j += 1
	}
	if j == i {
		return pos, false
	}

	k := j
	for k < len(text) && text[k] != ' ' {
		k += 1
	}
	if k == j {
		return pos, false
	}

	l := k
	for l < len(text) && text[l] == ' ' {
		l += 1
	}
	if l == k {
		return pos, false
	}

	if l + 5 > len(text) || text[l] != 'H' || text[l + 1] != 'T' || text[l + 2] != 'T' ||
	   text[l + 3] != 'P' || text[l + 4] != '/' {
		return pos, false
	}
	version_end, version_ok := simplified_match_version(text, l + 5)
	if !version_ok {
		return pos, false
	}

	// request_method (http.py:45-51): the method token type, precise or not.
	method_kind := Token_Kind.Name_Function
	if precise {
		for entry in RESPONSE_METHODS {
			if entry.name == method {
				method_kind = entry.kind
				break
			}
		}
	}
	append(tokens, Token{kind = method_kind, text = method})
	append(tokens, Token{kind = .Text, text = text[i:j]})
	append(tokens, Token{kind = .Name_Namespace, text = text[j:k]})
	append(tokens, Token{kind = .Text, text = text[k:l]})
	append(tokens, Token{kind = .Keyword_Reserved, text = text[l:l + 4]})
	append(tokens, Token{kind = .Operator, text = text[l + 4:l + 5]})
	append(tokens, Token{kind = .Number, text = text[l + 5:version_end]})
	return version_end, true
}

// simplified_match_version matches `(\d+\.\d+)` (http.py:69, :80).
@(private)
simplified_match_version :: proc(text: string, pos: int) -> (int, bool) {
	i := pos
	for i < len(text) && is_digit(text[i]) {
		i += 1
	}
	if i == pos || i >= len(text) || text[i] != '.' {
		return pos, false
	}
	i += 1
	digits := i
	for i < len(text) && is_digit(text[i]) {
		i += 1
	}
	if i == digits {
		return pos, false
	}
	return i, true
}

@(private)
simplified_match_status_line :: proc(text: string, pos: int, precise: bool, tokens: ^[dynamic]Token) -> (int, bool) {
	if pos + 5 > len(text) || text[pos] != 'H' || text[pos + 1] != 'T' || text[pos + 2] != 'T' ||
	   text[pos + 3] != 'P' || text[pos + 4] != '/' {
		return pos, false
	}
	version_end, version_ok := simplified_match_version(text, pos + 5)
	if !version_ok {
		return pos, false
	}
	i := version_end
	j := i
	for j < len(text) && text[j] == ' ' {
		j += 1
	}
	if j == i {
		return pos, false
	}
	if j >= len(text) {
		return pos, false
	}
	// `(.+)` is greedy but never crosses a newline.
	reason_end := j
	for reason_end < len(text) && text[reason_end] != '\n' {
		reason_end += 1
	}
	if reason_end == j {
		return pos, false
	}

	append(tokens, Token{kind = .Keyword_Reserved, text = text[pos:pos + 4]})
	append(tokens, Token{kind = .Operator, text = text[pos + 4:pos + 5]})
	append(tokens, Token{kind = .Number, text = text[pos + 5:version_end]})
	append(tokens, Token{kind = .Text, text = text[i:j]})

	// http_response_type (http.py:25-42): RE_STATUS_LINE = (\d{3})( +)?(.+)?
	// applied to the reason group, then bygroups(status_type, Text, status_type).
	// When RE_STATUS_LINE does not match, http_response_type returns without
	// yielding anything -- but the rule itself still matches and still consumes
	// the line (the outer bygroups only skips *that group's* tokens).
	rest := text[j:reason_end]
	if len(rest) < 3 || !is_digit(rest[0]) || !is_digit(rest[1]) || !is_digit(rest[2]) {
		return reason_end, true
	}
	kind := Token_Kind.Number
	if precise {
		if precise_kind, ok := status_kind(rest[0]); ok {
			kind = precise_kind
		}
	}
	// `( +)?` is greedy but can also match nothing, so the trailing spaces all
	// belong to the Text group and an empty reason yields no token at all.
	spaces_end := 3
	for spaces_end < len(rest) && rest[spaces_end] == ' ' {
		spaces_end += 1
	}
	append(tokens, Token{kind = kind, text = rest[:3]})
	if spaces_end > 3 {
		append(tokens, Token{kind = .Text, text = rest[3:spaces_end]})
	}
	if spaces_end < len(rest) {
		append(tokens, Token{kind = kind, text = rest[spaces_end:]})
	}
	return reason_end, true
}

// simplified_match_header is `(.*?)( *)(:)( *)(.+)` (http.py:89-95): the lazy
// first group stops at the first colon, `( *)` is greedy, and `(.+)` needs at
// least one character on the same line.
@(private)
simplified_match_header :: proc(text: string, pos: int, tokens: ^[dynamic]Token) -> (int, bool) {
	line_end := pos
	for line_end < len(text) && text[line_end] != '\n' {
		line_end += 1
	}
	colon := -1
	for i := pos; i < line_end; i += 1 {
		if text[i] == ':' {
			colon = i
			break
		}
	}
	if colon < 0 {
		return pos, false
	}
	name_end := colon
	for name_end > pos && text[name_end - 1] == ' ' {
		name_end -= 1
	}
	value_start := colon + 1
	for value_start < line_end && text[value_start] == ' ' {
		value_start += 1
	}
	if value_start == line_end {
		// The greedy `( *)` gave everything to the Text group and `(.+)` found
		// nothing, so the regex backtracks: the last character -- a space --
		// becomes the value. With no character at all after the colon the whole
		// rule fails.
		if line_end - 1 <= colon {
			return pos, false
		}
		value_start = line_end - 1
	}

	// bygroups(Name.Attribute, Text, Operator, Text, String) -- empty groups
	// produce no token.
	if name_end > pos {
		append(tokens, Token{kind = .Name_Attribute, text = text[pos:name_end]})
	}
	if colon > name_end {
		append(tokens, Token{kind = .Text, text = text[name_end:colon]})
	}
	append(tokens, Token{kind = .Operator, text = text[colon:colon + 1]})
	if value_start > colon + 1 {
		append(tokens, Token{kind = .Text, text = text[colon + 1:value_start]})
	}
	append(tokens, Token{kind = .String, text = text[value_start:line_end]})
	return line_end, true
}

// ---------------------------------------------------------------------------
// httpie MetadataLexer (httpie/output/lexers/metadata.py:33-58)
// ---------------------------------------------------------------------------

// ELAPSED_TIME_LABEL is httpie's ELAPSED_TIME_LABEL (httpie/models.py:20).
ELAPSED_TIME_LABEL :: "Elapsed time"

// SPEED_LIMITS is httpie's SPEED_TOKENS dict (metadata.py:6-10), in insertion
// order; the first limit the value is <= wins, anything larger than the last is
// VERY_SLOW.
@(private)
SPEED_LIMITS :: []struct {
	limit: f64,
	kind:  Token_Kind,
} {
	{0.45, .Number_Speed_Fast},
	{1.00, .Number_Speed_Avg},
	{2.50, .Number_Speed_Slow},
}

// metadata_speed_kind is `speed_based_token` (metadata.py:13-30) followed by
// `precise` (common.py:1-12).
@(private)
metadata_speed_kind :: proc(text: string, precise: bool) -> Token_Kind {
	value, parsed := strconv.parse_f64(text)
	if !parsed {
		// `except ValueError: return pygments.token.Number` (metadata.py:16-17).
		return .Number
	}
	kind := Token_Kind.Number_Speed_Very_Slow
	for entry in SPEED_LIMITS {
		if value <= entry.limit {
			kind = entry.kind
			break
		}
	}
	if !precise {
		return .Number
	}
	return kind
}

// metadata_tokens ports MetadataLexer's two rules (metadata.py:36-58).
@(private)
metadata_tokens :: proc(text: string, precise: bool, tokens: ^[dynamic]Token) {
	pos := 0
	for pos < len(text) {
		if end, ok := metadata_match_elapsed(text, pos, precise, tokens); ok {
			pos = end
			continue
		}
		if end, ok := metadata_match_item(text, pos, tokens); ok {
			pos = end
			continue
		}
		// RegexLexer fallback (pygments/lexer.py:746-753).
		if text[pos] == '\n' {
			append(tokens, Token{kind = .Whitespace, text = text[pos:pos + 1]})
		} else {
			append(tokens, Token{kind = .Error, text = text[pos:pos + 1]})
		}
		pos += 1
	}
}

// metadata_match_elapsed is
// `({ELAPSED_TIME_LABEL})( *)(:)( *)(\d+\.\d+)(s)` (metadata.py:39).
@(private)
metadata_match_elapsed :: proc(text: string, pos: int, precise: bool, tokens: ^[dynamic]Token) -> (int, bool) {
	if !strings.has_prefix(text[pos:], ELAPSED_TIME_LABEL) {
		return pos, false
	}
	label_end := pos + len(ELAPSED_TIME_LABEL)

	i := label_end
	for i < len(text) && text[i] == ' ' {
		i += 1
	}
	if i >= len(text) || text[i] != ':' {
		return pos, false
	}
	colon := i
	j := colon + 1
	for j < len(text) && text[j] == ' ' {
		j += 1
	}
	digit_start := j
	for j < len(text) && is_digit(text[j]) {
		j += 1
	}
	if j == digit_start || j >= len(text) || text[j] != '.' {
		return pos, false
	}
	j += 1
	fraction_start := j
	for j < len(text) && is_digit(text[j]) {
		j += 1
	}
	if j == fraction_start || j >= len(text) || text[j] != 's' {
		return pos, false
	}

	// bygroups(Name.Decorator, Text, Operator, Text, speed_based_token,
	//          Name.Builtin): empty groups yield nothing.
	if label_end > pos {
		append(tokens, Token{kind = .Name_Decorator, text = text[pos:label_end]})
	}
	if colon > label_end {
		append(tokens, Token{kind = .Text, text = text[label_end:colon]})
	}
	append(tokens, Token{kind = .Operator, text = text[colon:colon + 1]})
	if digit_start > colon + 1 {
		append(tokens, Token{kind = .Text, text = text[colon + 1:digit_start]})
	}
	append(tokens, Token {
		kind = metadata_speed_kind(text[digit_start:j], precise),
		text = text[digit_start:j],
	})
	append(tokens, Token{kind = .Name_Builtin, text = text[j:j + 1]})
	return j + 1, true
}

// metadata_match_item is the generic `(.*?)( *)(:)( *)(.+)` rule
// (metadata.py:49-56); it is also what a non-elapsed first line falls through
// to.
@(private)
metadata_match_item :: proc(text: string, pos: int, tokens: ^[dynamic]Token) -> (int, bool) {
	line_end := pos
	for line_end < len(text) && text[line_end] != '\n' {
		line_end += 1
	}
	colon := -1
	for i := pos; i < line_end; i += 1 {
		if text[i] == ':' {
			colon = i
			break
		}
	}
	if colon < 0 {
		return pos, false
	}
	name_end := colon
	for name_end > pos && text[name_end - 1] == ' ' {
		name_end -= 1
	}
	value_start := colon + 1
	for value_start < line_end && text[value_start] == ' ' {
		value_start += 1
	}
	if value_start == line_end {
		// Greedy `( *)` backtracking: one character must remain for `(.+)`.
		if line_end - 1 <= colon {
			return pos, false
		}
		value_start = line_end - 1
	}
	if name_end > pos {
		append(tokens, Token{kind = .Name_Decorator, text = text[pos:name_end]})
	}
	if colon > name_end {
		append(tokens, Token{kind = .Text, text = text[name_end:colon]})
	}
	append(tokens, Token{kind = .Operator, text = text[colon:colon + 1]})
	if value_start > colon + 1 {
		append(tokens, Token{kind = .Text, text = text[colon + 1:value_start]})
	}
	append(tokens, Token{kind = .Text, text = text[value_start:line_end]})
	return line_end, true
}
