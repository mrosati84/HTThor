// Tests for the XML half of the port: src/format/xml.odin (httpie's
// XMLFormatter over defusedxml/minidom) and the XmlLexer in
// src/output/colorize.odin.
//
// The expectations were produced by the reference (httpie 3.2.4), driving
// `XMLFormatter.format_body` with the reference's own defusedxml + pygments
// install. The coloured output itself is pinned by the colour corpus in
// tests/golden/colorize, which colorize_test.odin holds the port to.
package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:format"
import "src:http"
import "src:output"

// XML_SCENARIO_BODY is the compact body the formatter and the lexer are driven
// with: indenting it produces the nested element stream the token test expects.
XML_SCENARIO_BODY :: "<a><b>1</b><a>2</a></a>"

// XML_PRETTY_CASES are (body, expected) pairs: what httpie's XMLFormatter
// prints for a compact body. A body whose expected value equals its input is
// one the reference left alone (invalid or unsafe XML) or one that was already
// pretty -- the two are indistinguishable in the reference's output, which is
// why the test compares text.
XML_PRETTY_CASES :: []struct {
	body: string,
	want: string,
} {
	// The parity scenario's body.
	{
		XML_SCENARIO_BODY,
		"<a>\n  <b>1</b>\n  <a>2</a>\n</a>",
	},
	// minidom's element shapes: an empty element folds to `<a/>`, and a node
	// with any child at all is written one level per line.
	{"<a/>", "<a/>"},
	{"<a></a>", "<a/>"},
	{"<a>text</a>", "<a>text</a>"},
	{"<a>  <b/>  </a>", "<a>\n  <b/>\n</a>"},
	{"<a><b/><c/><d/></a>", "<a>\n  <b/>\n  <c/>\n  <d/>\n</a>"},
	{"<a><b>1</b>tail</a>", "<a>\n  <b>1</b>\n  tail\n</a>"},
	{"<a><b>1</b><c>2</c>mixed text</a>", "<a>\n  <b>1</b>\n  <c>2</c>\n  mixed text\n</a>"},
	// Attributes: document order, double quotes, attribute-value normalisation.
	{"<a x=\"1\" y='2'><b/></a>", "<a x=\"1\" y=\"2\">\n  <b/>\n</a>"},
	{"<a\n  x=\"1\"\n  y=\"2\">\n  <b/>\n</a>", "<a x=\"1\" y=\"2\">\n  <b/>\n</a>"},
	{"<a x=\"a\tb\"/>", "<a x=\"a b\"/>"},
	{"<a\txmlns:b=\"u\"/>", "<a xmlns:b=\"u\"/>"},
	{"<a xmlns:x=\"u\" x:y=\"1\" z=\"2\"/>", "<a xmlns:x=\"u\" x:y=\"1\" z=\"2\"/>"},
	// Character data and references: expat expands character references, and
	// minidom re-escapes on the way out.
	{"<a>&amp;b</a>", "<a>&amp;b</a>"},
	{"<a>a &lt; b &amp; c</a>", "<a>a &lt; b &amp; c</a>"},
	{"<a>&#65;&#x42;</a>", "<a>AB</a>"},
	{"<a>p &gt; q \"r\"</a>", "<a>p &gt; q &quot;r&quot;</a>"},
	{"<a y=\"p&amp;q&lt;r&quot;s&gt;t\"/>", "<a y=\"p&amp;q&lt;r&quot;s&gt;t\"/>"},
	{"<a>a]]&#62;b</a>", "<a>a]]&gt;b</a>"},
	// CRLF inside a document is normalised away; a character reference to CR is
	// not, and then httpie's splitlines turns it back into a newline.
	{"<a>\r\n<b/>\r\n</a>", "<a>\n  <b/>\n</a>"},
	{"<a>&#13;&#10;&#9;</a>", "<a>\n\t</a>"},
	{"<a>x\u2028y</a>", "<a>x\ny</a>"},
	// CDATA is written without indentation of its own, and an empty section
	// produces no node at all.
	{"<a><![CDATA[]]></a>", "<a/>"},
	{"<a><![CDATA[x]]></a>", "<a><![CDATA[x]]></a>"},
	{"<a><![CDATA[x]]>y</a>", "<a>\n<![CDATA[x]]>  y\n</a>"},
	{"<a><![CDATA[x]]><b/></a>", "<a>\n<![CDATA[x]]>  <b/>\n</a>"},
	// Comments and processing instructions.
	{"<a><!-- hi --><b/></a>", "<a>\n  <!-- hi -->\n  <b/>\n</a>"},
	{"<a><?pi   spaced  ?><b/></a>", "<a>\n  <?pi spaced  ?>\n  <b/>\n</a>"},
	{"<a><?pi?><b/></a>", "<a>\n  <?pi ?>\n  <b/>\n</a>"},
	{"<?pi x?><a><b/></a>", "<?pi x?>\n<a>\n  <b/>\n</a>"},
	{"<!--before--><a><b/></a>", "<!--before-->\n<a>\n  <b/>\n</a>"},
	{"<a><b/></a><!--after-->", "<a>\n  <b/>\n</a>\n<!--after-->"},
	// The declaration: minidom's own is dropped and the body's is put back.
	{"<?xml version=\"1.0\"?><a><b/></a>", "<?xml version=\"1.0\"?>\n<a>\n  <b/>\n</a>"},
	{
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?><a><b/></a>",
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>\n  <b/>\n</a>",
	},
	// `<?xml-stylesheet` is a PI to expat but a "declaration" to httpie's
	// parse_declaration, so the reference prints it twice -- faithfully.
	{
		"<?xml-stylesheet type=\"text/xsl\" href=\"x.xsl\"?><a><b/></a>",
		"<?xml-stylesheet type=\"text/xsl\" href=\"x.xsl\"?>\n" +
		"<?xml-stylesheet type=\"text/xsl\" href=\"x.xsl\"?>\n<a>\n  <b/>\n</a>",
	},
	// DOCTYPEs: kept, with minidom's own line breaks.
	{"<!DOCTYPE note><a><b/></a>", "<!DOCTYPE note>\n<a>\n  <b/>\n</a>"},
	{"<!DOCTYPE a SYSTEM \"x.dtd\"><a/>", "<!DOCTYPE a\n  SYSTEM 'x.dtd'>\n<a/>"},
	{"<!DOCTYPE a PUBLIC \"p\" \"s\"><a/>", "<!DOCTYPE a\n  PUBLIC 'p'\n  's'>\n<a/>"},
	{"<!DOCTYPE a [<!ELEMENT a EMPTY>]><a/>", "<!DOCTYPE a [<!ELEMENT a EMPTY>]>\n<a/>"},
	// Whitespace around the document goes away.
	{"  <a><b/></a>  ", "<a>\n  <b/>\n</a>"},
	// The declared encoding drives minidom's encoder round trip: a character
	// the encoding cannot represent becomes a numeric character reference.
	{
		"<?xml version=\"1.0\" encoding=\"ascii\"?><a>b\u20ac</a>",
		"<?xml version=\"1.0\" encoding=\"ascii\"?>\n<a>b&#8364;</a>",
	},
	{
		"<?xml version=\"1.0\" encoding=\"US-ASCII\"?><a><b>\u00e9\u20ac</b></a>",
		"<?xml version=\"1.0\" encoding=\"US-ASCII\"?>\n<a>\n  <b>&#233;&#8364;</b>\n</a>",
	},
	{
		"<?xml version=\"1.0\" encoding=\"iso-8859-1\"?><a>\u20ac</a>",
		"<?xml version=\"1.0\" encoding=\"iso-8859-1\"?>\n<a>&#8364;</a>",
	},
	// Everything below is left exactly as it arrived: expat rejects it, or
	// defusedxml forbids it.
	{"", ""},
	{"   ", "   "},
	{"<a>", "<a>"},
	{"<a><b></a>", "<a><b></a>"},
	{"not xml", "not xml"},
	{"<a>text</a>trailing", "<a>text</a>trailing"},
	{"<a></a><b></b>", "<a></a><b></b>"},
	{"< a><b/></a>", "< a><b/></a>"},
	{"<a>< b/></a>", "<a>< b/></a>"},
	{"<a/ >", "<a/ >"},
	{"<a x=\"1\" x=\"2\"/>", "<a x=\"1\" x=\"2\"/>"},
	{"<?xml version=\"1.0\"?>", "<?xml version=\"1.0\"?>"},
	{"<!--only comment-->", "<!--only comment-->"},
	{"<?pi\"x\"?><a/>", "<?pi\"x\"?><a/>"},
	{"<a><!--a--b--><b/></a>", "<a><!--a--b--><b/></a>"},
	{"<a>a]]>b</a>", "<a>a]]>b</a>"},
	{"<a>&#x110000;</a>", "<a>&#x110000;</a>"},
	{"<a>&#0;</a>", "<a>&#0;</a>"},
	{"<a>&;</a>", "<a>&;</a>"},
	{"<a>&unknown;</a>", "<a>&unknown;</a>"},
	{"<!DOCTYPE note [<!ENTITY x \"y\">]><a>&x;</a>", "<!DOCTYPE note [<!ENTITY x \"y\">]><a>&x;</a>"},
}

@(test)
test_xml_pretty_body_matches_reference :: proc(t: ^testing.T) {
	for entry, index in XML_PRETTY_CASES {
		got, _ := format.xml_pretty_body(entry.body, 2, context.temp_allocator)
		if got == entry.want {
			continue
		}
		testing.expectf(
			t,
			false,
			"case %d: %q\n  want %q\n  got  %q (first difference at byte %d)",
			index,
			entry.body,
			entry.want,
			got,
			xml_first_difference(entry.want, got),
		)
	}
}

// test_xml_pretty_body_reports_passthrough pins the ownership contract on the
// two ways a body can come back: untouched and unallocated (the caller keeps
// using the wire bytes), or freshly rendered -- which the reference does even
// when the text happens to be identical.
@(test)
test_xml_pretty_body_reports_passthrough :: proc(t: ^testing.T) {
	passthrough := [?]string {
		"",
		"   ",
		"<a>",
		"<a><b></a>",
		"not xml",
		"<a>text</a>trailing",
		"<a></a><b></b>",
		"< a><b/></a>",
		"<a/ >",
		"<a x=\"1\" x=\"2\"/>",
		"<?xml version=\"1.0\"?>",
		"<!--only comment-->",
		"<a>a]]>b</a>",
		"<a>&#x110000;</a>",
		"<a>&#0;</a>",
		"<a>&unknown;</a>",
		"<!DOCTYPE note [<!ENTITY x \"y\">]><a>&x;</a>",
	}
	for body in passthrough {
		got, changed := format.xml_pretty_body(body, 2, context.temp_allocator)
		testing.expectf(t, !changed, "%q: reported as formatted", body)
		testing.expectf(t, got == body, "%q: text changed to %q", body, got)
	}

	identity := [?]string {
		"<a/>",
		"<a>text</a>",
		"<a><![CDATA[x]]></a>",
		"<a xmlns:x=\"u\" x:y=\"1\" z=\"2\"/>",
	}
	for body in identity {
		got, changed := format.xml_pretty_body(body, 2, context.temp_allocator)
		testing.expectf(t, changed, "%q: a successful parse must report a rewrite", body)
		testing.expectf(t, got == body, "%q: text changed to %q", body, got)
	}
}

// test_xml_lexer_matches_pygments pins the XmlLexer port: the token stream it
// produces for the prettified scenario body, and the bytes the auto style
// renders from it.
@(test)
test_xml_lexer_matches_pygments :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	pretty, _ := format.xml_pretty_body(XML_SCENARIO_BODY, 2, context.temp_allocator)

	// Lexer.get_tokens appends a newline when the text lacks one
	// (pygments/lexer.py:218-263); that is the trailing Whitespace token.
	want_tokens := [?]struct {
		kind: output.Token_Kind,
		text: string,
	} {
		{.Name_Tag, "<a"},
		{.Name_Tag, ">"},
		{.Whitespace, "\n  "},
		{.Name_Tag, "<b"},
		{.Name_Tag, ">"},
		{.Text, "1"},
		{.Name_Tag, "</b>"},
		{.Whitespace, "\n  "},
		{.Name_Tag, "<a"},
		{.Name_Tag, ">"},
		{.Text, "2"},
		{.Name_Tag, "</a>"},
		{.Whitespace, "\n"},
		{.Name_Tag, "</a>"},
		{.Whitespace, "\n"},
	}

	lexed, ok := output.lex_xml(pretty, context.temp_allocator)
	defer output.lexed_destroy(&lexed, context.temp_allocator)
	testing.expectf(t, ok, "lex_xml refused the body")
	testing.expectf(
		t,
		len(lexed.tokens) == len(want_tokens),
		"lexer produced %d tokens, want %d",
		len(lexed.tokens),
		len(want_tokens),
	)
	for token, index in lexed.tokens {
		if index >= len(want_tokens) {
			break
		}
		if token.kind == want_tokens[index].kind && token.text == want_tokens[index].text {
			continue
		}
		testing.expectf(
			t,
			false,
			"token %d: want (%v, %q), got (%v, %q)",
			index,
			want_tokens[index].kind,
			want_tokens[index].text,
			token.kind,
			token.text,
		)
	}

	// The coloured bytes themselves are pinned by the colour corpus in
	// tests/golden/colorize (see colorize_test.odin); here we only exercise the
	// render path so a style or lexer failure is still caught.
	style, found := output.style_lookup(output.DEFAULT_STYLE_NAME)
	testing.expectf(t, found, "the default style %q is missing", output.DEFAULT_STYLE_NAME)
	rendered := strings.builder_make(context.temp_allocator)
	if err := output.render_tokens(strings.to_writer(&rendered), lexed.tokens[:], style.body); err != .None {
		testing.expectf(t, false, "render_tokens failed: %v", err)
	}
}

// test_format_body_ownership guards the ownership contract this card tightened
// in src/output/render.odin: a body that a formatter rewrites to the *same*
// bytes as the wire body is still a fresh allocation, and the writer must
// release it. Without the flag (format_body used to compare text against the
// input) that allocation leaked.
@(test)
test_format_body_ownership :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	style, _ := output.style_lookup(output.DEFAULT_STYLE_NAME)
	config := output.Write_Config {
		allocator      = allocator,
		pretty_format  = true,
		pretty_colors  = true,
		style          = style,
		variant        = .Pygments_Http,
		json_format    = true,
		json_sort_keys = true,
		xml_format     = true,
		xml_indent     = 2,
	}

	cases := [?]struct {
		mime: string,
		body: string,
		why:  string,
	} {
		{"application/json", "{}", "JSONFormatter renders \"{}\" unchanged"},
		{"application/xml", "<a/>", "XMLFormatter renders \"<a/>\" unchanged"},
		{"application/xml", "<a><b>1</b></a>", "the formatter rewrites the body"},
		{"text/plain", "hello", "no formatter applies"},
	}

	for entry in cases {
		response := http.Response {
			allocator    = allocator,
			status       = 200,
			reason       = xml_must_clone(t, "OK", allocator),
			http_version = xml_must_clone(t, "HTTP/1.1", allocator),
		}
		response.headers = make([]http.Header, 1, allocator)
		response.headers[0] = {
			name  = xml_must_clone(t, "Content-Type", allocator),
			value = xml_must_clone(t, entry.mime, allocator),
		}
		response.body = make([]u8, len(entry.body), allocator)
		copy(response.body, entry.body)

		rendered := strings.builder_make(allocator)
		if err := output.write_response(
			strings.to_writer(&rendered),
			&response,
			output.Parts{body = true},
			0,
			&config,
		); err != .None {
			testing.expectf(t, false, "%s: write_response failed: %v", entry.why, err)
		}
		strings.builder_destroy(&rendered)
		http.response_destroy(&response)
		expect_no_leaks(t, &track)
	}
}

// xml_first_difference is the index of the first mismatching byte, or the
// length of the shorter value when one is a prefix of the other.
@(private)
xml_first_difference :: proc(a: string, b: string) -> int {
	limit := min(len(a), len(b))
	for i := 0; i < limit; i += 1 {
		if a[i] != b[i] {
			return i
		}
	}
	return limit
}

// xml_must_clone is the two-value clone with the error checked: a test that
// cannot allocate has nothing useful to continue with.
@(private)
xml_must_clone :: proc(t: ^testing.T, s: string, allocator: mem.Allocator) -> string {
	clone, err := strings.clone(s, allocator)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	return clone
}
