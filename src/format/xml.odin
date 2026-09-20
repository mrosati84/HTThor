// XML pretty printing: httpie's XMLFormatter, byte for byte.
//
// What this file is: the XML half of the `format` group. httpie hands the body
// to `defusedxml.minidom.parseString`, re-renders the resulting DOM with
// `Document.toprettyxml()` and then post-processes the text
// (httpie/output/formatters/xml.py:11-72):
//
//	* the parse must succeed -- anything expat rejects, and anything
//	  defusedxml refuses (DTD entity declarations, external references), makes
//	  httpie leave the body exactly as it arrived;
//	* the rendering is minidom's own `writexml` chain, whose indentation rules
//	  (which nodes get a newline, which get their own line, when an element
//	  collapses to `<a/>`) are what the reference's bytes show;
//	* the post-processing drops every blank line -- that is how the whitespace
//	  text nodes minidom emits around child elements disappear again -- and
//	  removes the XML declaration minidom adds automatically, re-inserting the
//	  one the body declared, if it declared one.
//
// Everything is re-implemented here rather than delegated to a parser library:
// the observable output depends on minidom's exact whitespace handling and no
// XML library reproduces it.
//
// Ported from (paths relative to the reference site-packages tree):
//   * httpie/output/formatters/xml.py:11-72   parse_xml / parse_declaration /
//                                             pretty_xml / XMLFormatter
//   * defusedxml/minidom.py:40-59             parseString (the defusing defaults:
//                                             forbid_dtd=False, forbid_entities=True,
//                                             forbid_external=True)
//   * defusedxml/expatbuilder.py:18-107       which documents are refused
//   * CPython 3.11 xml/dom/expatbuilder.py:133-303  the DOM the parser builds
//                                             (text merging, CDATA handling)
//   * CPython 3.11 xml/dom/minidom.py:49-66, :296-301, :866-896, :1009, :1109,
//     :1204, :1216, :1349-1360, :1811-1823    toprettyxml / _write_data /
//                                             Element / ProcessingInstruction /
//                                             Text / Comment / CDATASection /
//                                             DocumentType / Document writexml
//
// Not emulated (documented in the module comment of docs/COLORIZE.md's
// companion, docs/PARITY.md §4.2, and in the card's completion notes):
// namespace *resolution* (prefixed names and xmlns attributes are preserved
// verbatim, which is what the reference prints for every document whose
// prefixes are declared), and the character-reference rewriting for declared
// encodings other than ascii / iso-8859-1 / utf-8.
//
// Ownership: every string this file allocates comes from the `allocator` the
// caller passes in and is released before the public call returns; the parser
// keeps the strings it rewrites in one list so that a mid-parse failure frees
// exactly as much as a success does. There is no `context.allocator` here.
package format

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// XML_DECLARATION_OPEN / XML_DECLARATION_CLOSE are httpie's constants
// (xml.py:9-10).
XML_DECLARATION_OPEN :: "<?xml"
XML_DECLARATION_CLOSE :: "?>"

// XML_UTF8 is httpie's UTF8 (httpie/encoding.py), the fallback encoding of
// `pretty_xml` when the document declares none.
XML_UTF8 :: "utf-8"

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

// xml_pretty_body is `XMLFormatter.format_body` (xml.py:47-72): the body
// prettified with `indent` spaces per level when it is well-formed, safe XML.
//
// `changed` is false when the body was left alone -- invalid XML (ExpatError),
// unsafe XML (DefusedXmlException) -- in which case the returned string is
// `body` itself and the caller must not release it.
xml_pretty_body :: proc(body: string, indent: int, allocator: mem.Allocator) -> (string, bool) {
	p := Xml_Parser {
		text      = body,
		allocator = allocator,
		ok        = true,
	}
	p.rewritten = make([dynamic]string, 0, 8, allocator)
	defer {
		for rewritten in p.rewritten {
			delete(rewritten, allocator)
		}
		delete(p.rewritten)
	}

	document := xml_parse_document(&p)
	defer xml_node_destroy(&document, allocator)
	if !p.ok {
		return body, false
	}

	text := xml_render(&document, xml_declaration(body), p.encoding, indent, allocator)
	return text, true
}

// xml_declaration is httpie's `parse_declaration` (xml.py:20-27): the body is
// stripped first, so a declaration is found wherever the leading whitespace
// ends; the result is a slice of `body`, empty when the body declares none.
xml_declaration :: proc(body: string) -> string {
	trimmed := xml_strip(body)
	if !strings.has_prefix(trimmed, XML_DECLARATION_OPEN) {
		return ""
	}
	end := strings.index(trimmed, XML_DECLARATION_CLOSE)
	if end < 0 {
		return ""
	}
	return trimmed[:end + len(XML_DECLARATION_CLOSE)]
}

// ---------------------------------------------------------------------------
// The DOM subset minidom's writer walks
// ---------------------------------------------------------------------------

@(private)
Xml_Node_Kind :: enum u8 {
	Document, // minidom.Document (only ever the tree's root here)
	Element,  // minidom.Element
	Text,     // minidom.Text
	Cdata,    // minidom.CDATASection
	Comment,  // minidom.Comment
	Pi,       // minidom.ProcessingInstruction
	Doctype,  // minidom.DocumentType
}

@(private)
Xml_Attr :: struct {
	name:  string,
	value: string,
}

@(private)
Xml_Node :: struct {
	kind:     Xml_Node_Kind,
	name:     string, // Element tagName, PI target, DOCTYPE name
	data:     string, // Text/CDATA data, comment text, PI data
	attrs:    [dynamic]Xml_Attr,
	children: [dynamic]Xml_Node,

	// DocumentType only (`<!DOCTYPE name SYSTEM 'x'>`).
	public_id:       string,
	system_id:       string,
	internal_subset: string,
	has_subset:      bool,
}

// xml_node_destroy releases a node and everything below it. Node names and data
// point either into the body being parsed or into the parser's `rewritten`
// list, so only the child/attribute arrays are released here.
@(private)
xml_node_destroy :: proc(node: ^Xml_Node, allocator: mem.Allocator) {
	for &child in node.children {
		xml_node_destroy(&child, allocator)
	}
	delete(node.children)
	delete(node.attrs)
	node^ = {}
}

// ---------------------------------------------------------------------------
// Parser (defusedxml.minidom.parseString over CPython's namespace ExpatBuilder)
// ---------------------------------------------------------------------------

// Xml_Parser walks the body once. `ok` is the parse outcome: every helper
// leaves it false on the first violation of anything expat would reject, and
// the callers stop as soon as it is false.
@(private)
Xml_Parser :: struct {
	text:      string,
	pos:       int,
	allocator: mem.Allocator,
	ok:        bool,

	// encoding is the `encoding` pseudo-attribute of the XML declaration, ""
	// when the declaration does not carry one; it becomes the document's
	// `encoding` (expatbuilder.py:441-443) and so the encoding minidom writes
	// the declaration in.
	encoding: string,

	// rewritten holds every string the parser allocated (line-end
	// normalisation, entity/character-reference expansion) so that one loop
	// releases them whatever the outcome.
	rewritten: [dynamic]string,
}

@(private)
xml_fail :: proc(p: ^Xml_Parser) {
	p.ok = false
}

// xml_rewrite keeps an allocated string alive until the parse ends.
@(private)
xml_rewrite :: proc(p: ^Xml_Parser, s: string) -> string {
	append(&p.rewritten, s)
	return s
}

@(private)
xml_eof :: proc(p: ^Xml_Parser) -> bool {
	return p.pos >= len(p.text)
}

@(private)
xml_current :: proc(p: ^Xml_Parser) -> u8 {
	return p.text[p.pos]
}

@(private)
xml_starts_with :: proc(p: ^Xml_Parser, prefix: string) -> bool {
	return strings.has_prefix(p.text[p.pos:], prefix)
}

// xml_skip_space consumes XML's `S` production (#x20 | #x9 | #xD | #xA).
@(private)
xml_skip_space :: proc(p: ^Xml_Parser) {
	for p.pos < len(p.text) {
		switch p.text[p.pos] {
		case ' ', '\t', '\r', '\n':
			p.pos += 1
		case:
			return
		}
	}
}

// xml_is_space is the single-character form of the same production.
@(private)
xml_is_space :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '\r', '\n':
		return true
	}
	return false
}

// xml_is_name_start / xml_is_name_char approximate expat's NameStartChar and
// NameChar for the ASCII range; a byte above 0x7f is accepted, as every
// non-ASCII rune expat accepts in a name would be.
@(private)
xml_is_name_start :: proc(c: u8) -> bool {
	if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' {
		return true
	}
	return c == '_' || c == ':' || c >= 0x80
}

@(private)
xml_is_name_char :: proc(c: u8) -> bool {
	return xml_is_name_start(c) || c >= '0' && c <= '9' || c == '-' || c == '.'
}

@(private)
xml_read_name :: proc(p: ^Xml_Parser) -> string {
	if xml_eof(p) || !xml_is_name_start(xml_current(p)) {
		xml_fail(p)
		return ""
	}
	start := p.pos
	p.pos += 1
	for p.pos < len(p.text) && xml_is_name_char(p.text[p.pos]) {
		p.pos += 1
	}
	return p.text[start:p.pos]
}

// xml_normalize_line_ends applies XML's end-of-line handling (XML 1.0 §2.11):
// every `\r\n` and every lone `\r` becomes `\n` before anything else looks at
// the text. The result is a slice of `raw` unless a rewrite was needed, in
// which case it is a fresh allocation owned by the parser.
@(private)
xml_normalize_line_ends :: proc(p: ^Xml_Parser, raw: string) -> string {
	if strings.index_byte(raw, '\r') < 0 {
		return raw
	}
	b := strings.builder_make(p.allocator)
	defer strings.builder_destroy(&b)
	for i := 0; i < len(raw); i += 1 {
		if raw[i] != '\r' {
			strings.write_byte(&b, raw[i])
			continue
		}
		strings.write_byte(&b, '\n')
		if i + 1 < len(raw) && raw[i + 1] == '\n' {
			i += 1
		}
	}
	return xml_rewrite(p, strings.to_string(b))
}

// xml_normalize_attribute is attribute-value normalisation (XML 1.0 §3.3.3):
// after the end-of-line handling, a literal tab or newline in an attribute
// value is a space. Expat does this before the value reaches the DOM.
@(private)
xml_normalize_attribute :: proc(p: ^Xml_Parser, raw: string) -> string {
	normalized := xml_normalize_line_ends(p, raw)
	if strings.index_byte(normalized, '\t') < 0 && strings.index_byte(normalized, '\n') < 0 {
		return normalized
	}
	b := strings.builder_make(p.allocator)
	defer strings.builder_destroy(&b)
	for i := 0; i < len(normalized); i += 1 {
		switch normalized[i] {
		case '\t', '\n':
			strings.write_byte(&b, ' ')
		case:
			strings.write_byte(&b, normalized[i])
		}
	}
	return xml_rewrite(p, strings.to_string(b))
}

// xml_expand_reference writes one entity or character reference. Only the five
// predefined entities exist for a document without entity declarations, and
// declarations are exactly what defusedxml refuses -- so anything else is an
// expat "undefined entity" error and fails the parse.
@(private)
xml_expand_reference :: proc(p: ^Xml_Parser, name: string, b: ^strings.Builder) -> bool {
	switch name {
	case "amp":
		strings.write_byte(b, '&')
		return true
	case "lt":
		strings.write_byte(b, '<')
		return true
	case "gt":
		strings.write_byte(b, '>')
		return true
	case "quot":
		strings.write_byte(b, '"')
		return true
	case "apos":
		strings.write_byte(b, '\'')
		return true
	}
	if !strings.has_prefix(name, "#") {
		xml_fail(p)
		return false
	}
	digits := name[1:]
	value: rune
	ok: bool
	if strings.has_prefix(digits, "x") || strings.has_prefix(digits, "X") {
		value, ok = xml_parse_charref(digits[1:], 16)
	} else {
		value, ok = xml_parse_charref(digits, 10)
	}
	if !ok {
		xml_fail(p)
		return false
	}
	strings.write_rune(b, value)
	return true
}

// xml_parse_charref is expat's numeric character reference: decimal or
// hexadecimal digits, and a code point that is an XML character (0 and the
// surrogate range are not).
@(private)
xml_parse_charref :: proc(digits: string, base: int) -> (rune, bool) {
	if digits == "" {
		return 0, false
	}
	value := 0
	for i := 0; i < len(digits); i += 1 {
		c := digits[i]
		digit: int
		switch {
		case c >= '0' && c <= '9':
			digit = int(c - '0')
		case base == 16 && c >= 'a' && c <= 'f':
			digit = int(c - 'a') + 10
		case base == 16 && c >= 'A' && c <= 'F':
			digit = int(c - 'A') + 10
		case:
			return 0, false
		}
		value = value * base + digit
		if value > 0x10FFFF {
			return 0, false
		}
	}
	if value == 0 || value >= 0xD800 && value <= 0xDFFF {
		return 0, false
	}
	return rune(value), true
}

// xml_decode_refs is expat's entity/character-reference expansion inside text
// and attribute values. A bare `&` or an unknown reference fails the parse,
// which is how httpie ends up printing such a body verbatim.
@(private)
xml_decode_refs :: proc(p: ^Xml_Parser, raw: string) -> string {
	if strings.index_byte(raw, '&') < 0 {
		return raw
	}
	b := strings.builder_make(p.allocator)
	defer strings.builder_destroy(&b)
	i := 0
	for i < len(raw) {
		if raw[i] != '&' {
			strings.write_byte(&b, raw[i])
			i += 1
			continue
		}
		end := strings.index_byte(raw[i:], ';')
		if end < 0 {
			xml_fail(p)
			return ""
		}
		if !xml_expand_reference(p, raw[i + 1:i + end], &b) {
			return ""
		}
		i += end + 1
	}
	return xml_rewrite(p, strings.to_string(b))
}

// xml_parse_document is `DefusedExpatBuilderNS.parseString`: a document is an
// optional XML declaration, misc (whitespace, comments, processing
// instructions), an optional DOCTYPE, more misc, exactly one element, and
// trailing misc.
@(private)
xml_parse_document :: proc(p: ^Xml_Parser) -> Xml_Node {
	document := Xml_Node {
		kind = .Document,
	}
	document.children = make([dynamic]Xml_Node, 0, 4, p.allocator)

	// The declaration is only a declaration at the very start of the entity and
	// only when `xml` is followed by whitespace (a PI has a name after the `<?`).
	if strings.has_prefix(p.text, XML_DECLARATION_OPEN) &&
	   len(p.text) > len(XML_DECLARATION_OPEN) &&
	   xml_is_space(p.text[len(XML_DECLARATION_OPEN)]) {
		end := strings.index(p.text, XML_DECLARATION_CLOSE)
		if end < 0 {
			xml_fail(p)
			return document
		}
		p.encoding = xml_declared_encoding(p.text[len(XML_DECLARATION_OPEN):end])
		p.pos = end + len(XML_DECLARATION_CLOSE)
	}

	xml_parse_misc(p, &document)
	if p.ok && xml_starts_with(p, "<!DOCTYPE") {
		doctype := xml_parse_doctype(p)
		if p.ok {
			append(&document.children, doctype)
		}
	}
	xml_parse_misc(p, &document)

	if p.ok {
		if xml_eof(p) || xml_current(p) != '<' {
			xml_fail(p) // expat: "no element found" / junk before the root
		} else {
			root := xml_parse_element(p)
			if p.ok {
				append(&document.children, root)
			} else {
				xml_node_destroy(&root, p.allocator)
			}
		}
	}
	xml_parse_misc(p, &document)
	if p.ok && !xml_eof(p) {
		xml_fail(p) // junk after the document element
	}
	return document
}

// xml_declared_encoding pulls the `encoding` pseudo-attribute out of an XML
// declaration, the way expat's XmlDeclHandler reports it
// (expatbuilder.py:441-443).
@(private)
xml_declared_encoding :: proc(declaration: string) -> string {
	rest := declaration
	for {
		index := strings.index(rest, "encoding")
		if index < 0 {
			return ""
		}
		rest = rest[index + len("encoding"):]
		rest = strings.trim_left_space(rest)
		if !strings.has_prefix(rest, "=") {
			continue
		}
		rest = strings.trim_left_space(rest[1:])
		if len(rest) < 2 {
			return ""
		}
		quote := rest[0]
		if quote != '"' && quote != '\'' {
			return ""
		}
		end := strings.index_byte(rest[1:], quote)
		if end < 0 {
			return ""
		}
		return rest[1:1 + end]
	}
}

// xml_parse_misc consumes whitespace, comments and processing instructions,
// appending the comment/PI nodes to `parent` (expatbuilder.py:268-272, :329-333).
@(private)
xml_parse_misc :: proc(p: ^Xml_Parser, parent: ^Xml_Node) {
	for p.ok {
		xml_skip_space(p)
		if xml_eof(p) {
			return
		}
		if xml_starts_with(p, "<!--") {
			comment := xml_parse_comment(p)
			if p.ok {
				append(&parent.children, comment)
			}
			continue
		}
		if xml_starts_with(p, "<?") {
			pi := xml_parse_pi(p)
			if p.ok {
				append(&parent.children, pi)
			}
			continue
		}
		return
	}
}

// xml_parse_comment is expat's comment handling: `<!--` up to the first `-->`,
// with `--` forbidden inside (expat rejects it, and minidom's
// Comment.writexml would raise rather than print it).
@(private)
xml_parse_comment :: proc(p: ^Xml_Parser) -> Xml_Node {
	node := Xml_Node {
		kind = .Comment,
	}
	p.pos += len("<!--")
	start := p.pos
	end := strings.index(p.text[p.pos:], "-->")
	if end < 0 {
		xml_fail(p)
		return node
	}
	data := p.text[start:start + end]
	if strings.index(data, "--") >= 0 || strings.has_suffix(data, "-") {
		xml_fail(p)
		return node
	}
	p.pos = start + end + len("-->")
	node.data = xml_decode_refs(p, xml_normalize_line_ends(p, data))
	return node
}

// xml_parse_pi is `<?target data?>`; a `target` of exactly `xml` is the
// declaration and never reaches here (it is only recognised at position 0).
@(private)
xml_parse_pi :: proc(p: ^Xml_Parser) -> Xml_Node {
	node := Xml_Node {
		kind = .Pi,
	}
	p.pos += len("<?")
	node.name = xml_read_name(p)
	if !p.ok {
		return node
	}
	start := p.pos
	end := strings.index(p.text[p.pos:], "?>")
	if end < 0 {
		xml_fail(p)
		return node
	}
	raw := p.text[start:start + end]
	p.pos = start + end + len("?>")

	// expat reports the target and the data separately: the whitespace that
	// separates them is consumed, everything after it -- including trailing
	// whitespace -- is data. A PI with no data at all (`<?pi?>`) is valid; a
	// non-whitespace character right after the target is not.
	if raw != "" {
		if !xml_is_space(raw[0]) {
			xml_fail(p)
			return node
		}
		trimmed := 0
		for trimmed < len(raw) && xml_is_space(raw[trimmed]) {
			trimmed += 1
		}
		raw = raw[trimmed:]
	}
	node.data = xml_decode_refs(p, xml_normalize_line_ends(p, raw))
	return node
}

// xml_parse_doctype is `<!DOCTYPE name (SYSTEM|PUBLIC ...)? [subset]?>`.
// defusedxml refuses two things here, and both make httpie print the body
// verbatim: any `<!ENTITY ...>` declaration (EntitiesForbidden,
// expatbuilder.py:32-35) and any external reference it would have to resolve.
@(private)
xml_parse_doctype :: proc(p: ^Xml_Parser) -> Xml_Node {
	node := Xml_Node {
		kind = .Doctype,
	}
	node.internal_subset = ""
	p.pos += len("<!DOCTYPE")
	xml_skip_space(p)
	node.name = xml_read_name(p)
	if !p.ok {
		return node
	}
	xml_skip_space(p)

	if xml_starts_with(p, "PUBLIC") || xml_starts_with(p, "SYSTEM") {
		// `PUBLIC "pub" "sys"` or `SYSTEM "sys" -- minidom prints the system id
		// alone when there is no public id (minidom.py:1740-1747).
		public := xml_starts_with(p, "PUBLIC")
		p.pos += public ? len("PUBLIC") : len("SYSTEM")
		xml_skip_space(p)
		if public {
			node.public_id, p.ok = xml_parse_literal(p)
			if !p.ok {
				return node
			}
			xml_skip_space(p)
		}
		node.system_id, p.ok = xml_parse_literal(p)
		if !p.ok {
			return node
		}
		xml_skip_space(p)
	}

	if !xml_eof(p) && xml_current(p) == '[' {
		p.pos += 1
		start := p.pos
		end := xml_find_subset_end(p.text, p.pos)
		if end < 0 {
			xml_fail(p)
			return node
		}
		subset := p.text[start:end]
		if xml_subset_declares_entity(subset) {
			xml_fail(p) // EntitiesForbidden
			return node
		}
		node.internal_subset = xml_normalize_line_ends(p, subset)
		node.has_subset = true
		p.pos = end + 1
		xml_skip_space(p)
	}

	if xml_eof(p) || xml_current(p) != '>' {
		xml_fail(p)
		return node
	}
	p.pos += 1
	return node
}

// xml_parse_literal reads a quoted SystemLiteral/PubidLiteral.
@(private)
xml_parse_literal :: proc(p: ^Xml_Parser) -> (string, bool) {
	if xml_eof(p) {
		return "", false
	}
	quote := xml_current(p)
	if quote != '"' && quote != '\'' {
		return "", false
	}
	p.pos += 1
	start := p.pos
	end := strings.index_byte(p.text[p.pos:], quote)
	if end < 0 {
		return "", false
	}
	p.pos = start + end + 1
	return p.text[start:p.pos - 1], true
}

// xml_find_subset_end returns the index of the `]` closing an internal subset,
// skipping quoted literals and comments (a `]` inside one does not end it).
@(private)
xml_find_subset_end :: proc(text: string, start: int) -> int {
	i := start
	for i < len(text) {
		switch text[i] {
		case '"', '\'':
			quote := text[i]
			i += 1
			for i < len(text) && text[i] != quote {
				i += 1
			}
			i += 1
		case ']':
			return i
		case '<':
			if strings.has_prefix(text[i:], "<!--") {
				end := strings.index(text[i:], "-->")
				if end < 0 {
					return -1
				}
				i += end + len("-->")
				continue
			}
			i += 1
		case:
			i += 1
		}
	}
	return -1
}

// xml_subset_declares_entity reports whether an internal subset declares an
// entity -- the one thing in it defusedxml refuses. Comments and quoted
// literals are skipped so that only a real `<!ENTITY` counts.
@(private)
xml_subset_declares_entity :: proc(subset: string) -> bool {
	i := 0
	for i < len(subset) {
		switch subset[i] {
		case '"', '\'':
			quote := subset[i]
			i += 1
			for i < len(subset) && subset[i] != quote {
				i += 1
			}
			i += 1
		case '!':
			if strings.has_prefix(subset[i:], "!ENTITY") {
				return true
			}
			i += 1
		case '<':
			if strings.has_prefix(subset[i:], "<!--") {
				end := strings.index(subset[i:], "-->")
				if end < 0 {
					return false
				}
				i += end + len("-->")
				continue
			}
			i += 1
		case:
			i += 1
		}
	}
	return false
}

// xml_parse_element is expat's element handling: the start tag with its
// attributes, then mixed content until the matching end tag.
@(private)
xml_parse_element :: proc(p: ^Xml_Parser) -> Xml_Node {
	node := Xml_Node {
		kind = .Element,
	}
	node.children = make([dynamic]Xml_Node, 0, 4, p.allocator)

	if xml_eof(p) || xml_current(p) != '<' {
		xml_fail(p)
		return node
	}
	p.pos += 1
	node.name = xml_read_name(p)
	if !p.ok {
		return node
	}

	for {
		xml_skip_space(p)
		if xml_eof(p) {
			xml_fail(p)
			return node
		}
		if xml_current(p) == '>' {
			p.pos += 1
			break
		}
		if xml_current(p) == '/' {
			if p.pos + 1 < len(p.text) && p.text[p.pos + 1] == '>' {
				p.pos += 2
				return node // `<name/>`: no children at all
			}
			xml_fail(p)
			return node
		}
		attr := xml_parse_attribute(p)
		if !p.ok {
			return node
		}
		// Duplicate attribute names are an expat error ("duplicate attribute").
		for existing in node.attrs {
			if existing.name == attr.name {
				xml_fail(p)
				return node
			}
		}
		append(&node.attrs, attr)
	}

	for {
		if xml_eof(p) {
			xml_fail(p) // "no element found" / unclosed start tag
			return node
		}
		if xml_current(p) == '<' {
			if xml_starts_with(p, "</") {
				p.pos += len("</")
				close_name := xml_read_name(p)
				if !p.ok {
					return node
				}
				if close_name != node.name {
					xml_fail(p) // mismatched end tag
					return node
				}
				xml_skip_space(p)
				if xml_eof(p) || xml_current(p) != '>' {
					xml_fail(p)
					return node
				}
				p.pos += 1
				return node
			}
			if xml_starts_with(p, "<!--") {
				comment := xml_parse_comment(p)
				if !p.ok {
					return node
				}
				append(&node.children, comment)
				continue
			}
			if xml_starts_with(p, "<![CDATA[") {
				cdata := xml_parse_cdata(p)
				if !p.ok {
					return node
				}
				// expat only reports non-empty CDATA sections
				// (expatbuilder.py:274-292).
				if cdata.data != "" {
					xml_append_cdata(&node, cdata)
				}
				continue
			}
			if xml_starts_with(p, "<?") {
				pi := xml_parse_pi(p)
				if !p.ok {
					return node
				}
				append(&node.children, pi)
				continue
			}
			if xml_starts_with(p, "<!") {
				xml_fail(p) // a DOCTYPE (or `<![`) inside content
				return node
			}
			child := xml_parse_element(p)
			if !p.ok {
				xml_node_destroy(&child, p.allocator)
				return node
			}
			append(&node.children, child)
			continue
		}

		start := p.pos
		for p.pos < len(p.text) && p.text[p.pos] != '<' {
			p.pos += 1
		}
		raw := p.text[start:p.pos]
		if raw == "" {
			xml_fail(p)
			return node
		}
		// The literal `]]>` may not appear in content (XML 1.0 §2.4); expat
		// rejects it, and it is the *raw* text that is checked -- `]]&#62;`
		// is legal and produces the same three characters after expansion.
		if strings.contains(raw, "]]>") {
			xml_fail(p)
			return node
		}
		xml_append_text(&node, xml_decode_refs(p, xml_normalize_line_ends(p, raw)), p)
		if !p.ok {
			return node
		}
	}
}

// xml_parse_attribute reads `name = "value"` with any amount of whitespace
// around the `=`.
@(private)
xml_parse_attribute :: proc(p: ^Xml_Parser) -> Xml_Attr {
	attr := Xml_Attr{}
	attr.name = xml_read_name(p)
	if !p.ok {
		return attr
	}
	xml_skip_space(p)
	if xml_eof(p) || xml_current(p) != '=' {
		xml_fail(p)
		return attr
	}
	p.pos += 1
	xml_skip_space(p)
	if xml_eof(p) {
		xml_fail(p)
		return attr
	}
	quote := xml_current(p)
	if quote != '"' && quote != '\'' {
		xml_fail(p)
		return attr
	}
	p.pos += 1
	start := p.pos
	for p.pos < len(p.text) && p.text[p.pos] != quote {
		if p.text[p.pos] == '<' {
			xml_fail(p) // `<` is not allowed in an attribute value
			return attr
		}
		p.pos += 1
	}
	if xml_eof(p) {
		xml_fail(p)
		return attr
	}
	raw := p.text[start:p.pos]
	p.pos += 1
	attr.value = xml_decode_refs(p, xml_normalize_attribute(p, raw))
	return attr
}

// xml_parse_cdata reads `<![CDATA[ ... ]]>`; `.` is DOTALL in the lexer sense
// here too, so the section may span lines.
@(private)
xml_parse_cdata :: proc(p: ^Xml_Parser) -> Xml_Node {
	node := Xml_Node {
		kind = .Cdata,
	}
	p.pos += len("<![CDATA[")
	start := p.pos
	end := strings.index(p.text[p.pos:], "]]>")
	if end < 0 {
		xml_fail(p)
		return node
	}
	// Line ends are normalised inside a CDATA section as well: the XML
	// processor normalises them before parsing (XML 1.0 §2.11).
	node.data = xml_normalize_line_ends(p, p.text[start:start + end])
	p.pos = start + end + len("]]>")
	return node
}

// xml_append_text mirrors expatbuilder.py:294-303: because expat is told to
// buffer text, a chunk of character data that follows another text node is
// appended to it rather than becoming a node of its own.
@(private)
xml_append_text :: proc(node: ^Xml_Node, data: string, p: ^Xml_Parser) {
	if data == "" {
		return
	}
	if len(node.children) > 0 && node.children[len(node.children) - 1].kind == .Text {
		last := &node.children[len(node.children) - 1]
		merged := strings.concatenate({last.data, data}, p.allocator)
		// `last.data` may be a slice of the body or of the parser's list; only
		// the replacement is registered for release.
		last.data = xml_rewrite(p, merged)
		return
	}
	append(&node.children, Xml_Node{kind = .Text, data = data})
}

// xml_append_cdata mirrors expatbuilder.py:276-282: consecutive CDATA chunks of
// one section share a node; two separate sections do not.
@(private)
xml_append_cdata :: proc(node: ^Xml_Node, cdata: Xml_Node) {
	if len(node.children) > 0 && node.children[len(node.children) - 1].kind == .Cdata {
		return
	}
	append(&node.children, cdata)
}

// ---------------------------------------------------------------------------
// Writer (minidom's writexml chain + pretty_xml's post-processing)
// ---------------------------------------------------------------------------

// xml_render is `pretty_xml` (xml.py:29-45): minidom's `toprettyxml` output,
// blank lines removed, and the automatic declaration replaced by `declaration`
// when the body declared one. The result is allocated from `allocator`.
@(private)
xml_render :: proc(
	document: ^Xml_Node,
	declaration: string,
	document_encoding: string,
	indent: int,
	allocator: mem.Allocator,
) -> string {
	encoding := document_encoding == "" ? XML_UTF8 : document_encoding

	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	// Document.writexml (minidom.py:1811-1823) writes the declaration line
	// itself, then hands every child `addindent` as the per-level indent.
	fmt.sbprintf(&b, "<?xml version=\"1.0\" encoding=\"%s\"?>\n", encoding)
	for &child in document.children {
		xml_write_node(&b, &child, 0, indent, "\n")
	}
	raw := strings.to_string(b)

	// httpie renders through `io.TextIOWrapper(..., encoding=<document
	// encoding>, errors="xmlcharrefreplace")` and decodes the bytes back
	// (minidom.py:49-66): characters the encoding cannot represent come out as
	// numeric character references.
	text, encoded := xml_transcode_charrefs(raw, encoding, allocator)
	defer if encoded {
		delete(text, allocator)
	}

	lines := make([dynamic]string, 0, 16, allocator)
	defer delete(lines)
	xml_split_lines(text, &lines)

	// python: `[line for line in body.splitlines() if line.strip()]`
	// (xml.py:32-33), then the declaration swap (xml.py:36-40).
	result := strings.builder_make(allocator)
	written := 0
	for line in lines {
		if xml_line_is_blank(line) {
			continue
		}
		if written == 0 && xml_is_declaration_line(line) {
			// minidom always adds a declaration; httpie removes it and puts
			// the body's own back when there was one.
			if declaration != "" {
				strings.write_string(&result, declaration)
				written += 1
			}
			continue
		}
		if written > 0 {
			strings.write_byte(&result, '\n')
		}
		strings.write_string(&result, line)
		written += 1
	}

	out := strings.clone(strings.to_string(result), allocator) or_else ""
	strings.builder_destroy(&result)
	return out
}

// xml_write_node is the shared shape of every minidom `writexml` this port
// reaches. `depth` is the number of `indent`-wide levels to emit; a node the
// parent renders inline is called with depth 0 and an empty `newl`.
@(private)
xml_write_node :: proc(b: ^strings.Builder, node: ^Xml_Node, depth: int, indent: int, newl: string) {
	switch node.kind {
	case .Document:
		// Never reached: `xml_render` iterates the document's children itself
		// (Document.writexml, minidom.py:1822-1823).
	case .Element:
		// minidom.py:866-896
		xml_write_indent(b, depth, indent)
		strings.write_byte(b, '<')
		strings.write_string(b, node.name)
		for attr in node.attrs {
			strings.write_byte(b, ' ')
			strings.write_string(b, attr.name)
			strings.write_string(b, "=\"")
			xml_write_escaped(b, attr.value)
			strings.write_byte(b, '"')
		}
		if len(node.children) == 0 {
			strings.write_string(b, "/>")
			strings.write_string(b, newl)
			return
		}
		strings.write_byte(b, '>')
		child := &node.children[0]
		if len(node.children) == 1 && (child.kind == .Text || child.kind == .Cdata) {
			// `self.childNodes[0].writexml(writer, '', '', '')`
			xml_write_node(b, child, 0, indent, "")
		} else {
			strings.write_string(b, "\n")
			for &each in node.children {
				xml_write_node(b, &each, depth + 1, indent, "\n")
			}
			xml_write_indent(b, depth, indent)
		}
		strings.write_string(b, "</")
		strings.write_string(b, node.name)
		strings.write_byte(b, '>')
		strings.write_string(b, newl)

	case .Text:
		// minidom.py:1109-1110
		xml_write_indent(b, depth, indent)
		xml_write_escaped(b, node.data)
		strings.write_string(b, newl)

	case .Cdata:
		// minidom.py:1216-1219 -- no indent, no newline of its own.
		strings.write_string(b, "<![CDATA[")
		strings.write_string(b, node.data)
		strings.write_string(b, "]]>")

	case .Comment:
		// minidom.py:1204-1207
		xml_write_indent(b, depth, indent)
		strings.write_string(b, "<!--")
		strings.write_string(b, node.data)
		strings.write_string(b, "-->")
		strings.write_string(b, newl)

	case .Pi:
		// minidom.py:1009-1010
		xml_write_indent(b, depth, indent)
		strings.write_string(b, "<?")
		strings.write_string(b, node.name)
		strings.write_byte(b, ' ')
		strings.write_string(b, node.data)
		strings.write_string(b, "?>")
		strings.write_string(b, newl)

	case .Doctype:
		// minidom.py:1349-1360 -- the writer ignores `indent` entirely.
		strings.write_string(b, "<!DOCTYPE ")
		strings.write_string(b, node.name)
		if node.public_id != "" {
			fmt.sbprintf(b, "\n  PUBLIC '%s'\n  '%s'", node.public_id, node.system_id)
		} else if node.system_id != "" {
			fmt.sbprintf(b, "\n  SYSTEM '%s'", node.system_id)
		}
		if node.has_subset {
			strings.write_string(b, " [")
			strings.write_string(b, node.internal_subset)
			strings.write_string(b, "]")
		}
		strings.write_byte(b, '>')
		strings.write_string(b, newl)
	}
}

@(private)
xml_write_indent :: proc(b: ^strings.Builder, depth: int, indent: int) {
	for _ in 0 ..< depth * indent {
		strings.write_byte(b, ' ')
	}
}

// xml_write_escaped is minidom's `_write_data` (minidom.py:296-301). Note that
// it escapes `>` and `"` as well as `&` and `<`, in text just as in an
// attribute value, and writes nothing at all for empty data.
@(private)
xml_write_escaped :: proc(b: ^strings.Builder, data: string) {
	for i := 0; i < len(data); i += 1 {
		switch data[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case:
			strings.write_byte(b, data[i])
		}
	}
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

// xml_transcode_charrefs is the TextIOWrapper round trip of `toprettyxml`
// (minidom.py:49-66) for the encodings whose representable set is fixed: a
// character the declared encoding cannot represent becomes `&#<code>;`
// (`errors="xmlcharrefreplace"`). utf-8 can represent everything, so it is an
// identity; any other declared encoding is treated as utf-8.
@(private)
xml_transcode_charrefs :: proc(text: string, encoding: string, allocator: mem.Allocator) -> (string, bool) {
	limit := xml_encoding_limit(encoding)
	if limit >= utf8.MAX_RUNE {
		return text, false
	}
	needs_rewrite := false
	for i := 0; i < len(text); {
		r, width := utf8.decode_rune_in_string(text[i:])
		if r == utf8.RUNE_ERROR && width <= 0 {
			width = 1
		}
		if r > limit {
			needs_rewrite = true
			break
		}
		i += width
	}
	if !needs_rewrite {
		return text, false
	}

	b := strings.builder_make(allocator)
	for i := 0; i < len(text); {
		r, width := utf8.decode_rune_in_string(text[i:])
		if r == utf8.RUNE_ERROR && width <= 0 {
			width = 1
			r = utf8.RUNE_ERROR
		}
		if r > limit || i + width <= i {
			fmt.sbprintf(&b, "&#%d;", r)
		} else {
			strings.write_string(&b, text[i:i + width])
		}
		i += width
	}
	return strings.to_string(b), true
}

// xml_encoding_limit is the highest code point the declared encoding can
// represent, for the encodings httpie's output can realistically declare.
// Python's codec lookup is case-insensitive and ignores '-' and '_'; an
// encoding this table does not know is treated as utf-8.
@(private)
xml_encoding_limit :: proc(encoding: string) -> rune {
	buf: [32]u8
	count := 0
	for i := 0; i < len(encoding) && count < len(buf); i += 1 {
		c := encoding[i]
		if c == '-' || c == '_' || c == ' ' {
			continue
		}
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		buf[count] = c
		count += 1
	}

	switch string(buf[:count]) {
	case "", "utf8", "u8", "cp65001", "utf":
		return utf8.MAX_RUNE
	case "ascii", "usascii", "646", "ansix341968":
		return 0x7f
	case "latin1", "latin", "iso88591", "8859", "l1", "cp819", "csisolatin1",
	     "iso8859", "isoir100":
		return 0xff
	}
	return utf8.MAX_RUNE
}

// xml_split_lines is Python's `str.splitlines()`: a break after `\n`, `\r\n`,
// `\r`, and the other boundaries `str.splitlines` accepts. Joining the pieces
// with '\n' -- which `pretty_xml` then does -- normalises those boundaries to a
// newline, so a U+2028 inside a text node does become a line break.
@(private)
xml_split_lines :: proc(text: string, lines: ^[dynamic]string) {
	start := 0
	i := 0
	for i < len(text) {
		width := 0
		switch text[i] {
		case '\n', '\v', '\f', '\x1c', '\x1d', '\x1e':
			width = 1
		case '\r':
			width = (i + 1 < len(text) && text[i + 1] == '\n') ? 2 : 1
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
		if width == 0 {
			i += 1
			continue
		}
		append(lines, text[start:i])
		i += width
		start = i
	}
	if start < len(text) {
		append(lines, text[start:])
	}
}

// xml_line_is_blank is Python's `not line.strip()`.
@(private)
xml_line_is_blank :: proc(line: string) -> bool {
	i := 0
	for i < len(line) {
		c := line[i]
		switch c {
		case ' ', '\t', '\n', '\r', '\v', '\f':
			i += 1
		case 0xc2:
			if i + 1 < len(line) && line[i + 1] == 0x85 {
				i += 2
			} else {
				return false
			}
		case:
			return false
		}
	}
	return true
}

// xml_is_declaration_line is `parse_declaration` applied to one rendered line.
@(private)
xml_is_declaration_line :: proc(line: string) -> bool {
	if !strings.has_prefix(line, XML_DECLARATION_OPEN) {
		return false
	}
	return strings.index(line, XML_DECLARATION_CLOSE) >= 0
}

// xml_strip is Python's `str.strip()` for the characters XML output can carry.
@(private)
xml_strip :: proc(value: string) -> string {
	start := 0
	for start < len(value) && xml_is_space(value[start]) {
		start += 1
	}
	end := len(value)
	for end > start && xml_is_space(value[end - 1]) {
		end -= 1
	}
	return value[start:end]
}
