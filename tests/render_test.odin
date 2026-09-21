// Terminal safety (backlog M2): the bytes of a reply are the server's, and a
// terminal obeys an ESC-led sequence instead of drawing it. These tests pin the
// substitution the port makes (output/sanitize_terminal_text) and the two sites
// it is wired into — the head and the body of a response rendered to a terminal
// — plus the two ways out of it: a non-tty destination keeps every byte, and
// HTTHOR_ALLOW_TERMINAL_ESCAPES turns the substitution off.
package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:http"
import "src:output"

// OSC 52 (a clipboard write), the CSI that clears the screen, a lone CR and a
// C1 CSI — the shapes the report reproduced byte for byte.
TERMINAL_INJECTION_HEAD :: "text/plain\x1b]52;c;Zm9v\x07"
TERMINAL_INJECTION_BODY :: "safe\x1b[2Joverwrite\rEVIL\u009b31m"

@(test)
test_terminal_sanitizer_replaces_control_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	cases := [?]struct {
		name:  string,
		input: string,
		want:  string,
	}{
		{"a clean string is returned untouched", "plain body\n", "plain body\n"},
		{"CRLF is a line ending", "a\r\nb", "a\r\nb"},
		{"a lone CR is not", "a\rb", "a\uFFFDb"},
		{"ESC loses its sequence", "\x1b[2J", "\uFFFD[2J"},
		{"so does OSC 52", "\x1b]52;c;Zm9v\x07", "\uFFFD]52;c;Zm9v\uFFFD"},
		{"BEL and DEL go", "a\x07b\x7Fc", "a\uFFFDb\uFFFDc"},
		{"tab and LF stay", "a\tb\nc", "a\tb\nc"},
		{"the 8-bit CSI of a latin-1 reply goes", "\u009b31m", "\uFFFD31m"},
		{"as does a byte that is not UTF-8", "caf\xe9", "caf\uFFFD"},
		{"a valid multi-byte character stays", "caf\u00e9 \U0001F600", "caf\u00e9 \U0001F600"},
	}

	for entry in cases {
		printed, owned := output.sanitize_terminal_bytes(
			transmute([]byte)entry.input,
			allocator,
		)
		testing.expectf(
			t,
			string(printed) == entry.want,
			"%s: got %q, want %q",
			entry.name,
			string(printed),
			entry.want,
		)
		if entry.input == entry.want {
			testing.expectf(t, !owned, "%s: a clean string must not be copied", entry.name)
		}
	}
}

@(test)
test_a_response_rendered_to_a_terminal_loses_its_control_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	// A terminal: the head's header value and the body's CSI both become
	// U+FFFD, and nothing ESC-led is left in the bytes that reach the writer.
	terminal := render_injected_response(t, allocator, true, false)
	testing.expectf(
		t,
		!strings.contains(terminal, "\x1b"),
		"a terminal must not receive an escape sequence: %q",
		terminal,
	)
	testing.expectf(t, strings.contains(terminal, "\uFFFD"), "no substitution: %q", terminal)

	// The escape hatch: HTTHOR_ALLOW_TERMINAL_ESCAPES=1 hands the reference's
	// raw bytes to the terminal.
	allowed := render_injected_response(t, allocator, true, true)
	testing.expectf(
		t,
		strings.contains(allowed, "\x1b]52;c;Zm9v"),
		"the opt-out must keep the server's bytes: %q",
		allowed,
	)

	// A pipe (or a file, or a download target): every byte is kept, because
	// there is no terminal to protect.
	piped := render_injected_response(t, allocator, false, false)
	testing.expectf(
		t,
		strings.contains(piped, "\x1b[2J"),
		"a non-tty destination keeps its bytes: %q",
		piped,
	)
}

// render_injected_response renders one response whose header and body both
// carry an OSC 52 / CSI, and returns what the writer got.
@(private)
render_injected_response :: proc(
	t: ^testing.T,
	allocator: mem.Allocator,
	stdout_is_tty: bool,
	allow_terminal_escapes: bool,
) -> string {
	style, found := output.style_lookup(output.DEFAULT_STYLE_NAME)
	testing.expect(t, found, "the default style must resolve")
	config := output.Write_Config {
		allocator              = allocator,
		style                  = style,
		variant                = .Pygments_Http,
		stdout_is_tty          = stdout_is_tty,
		allow_terminal_escapes = allow_terminal_escapes,
	}

	response := http.Response {
		allocator    = allocator,
		status       = 200,
		reason       = render_must_clone(t, "OK", allocator),
		http_version = render_must_clone(t, "HTTP/1.1", allocator),
	}
	response.headers = make([]http.Header, 1, allocator)
	response.headers[0] = {
		name  = render_must_clone(t, "X-Injected", allocator),
		value = render_must_clone(t, TERMINAL_INJECTION_HEAD, allocator),
	}
	response.body = make([]u8, len(TERMINAL_INJECTION_BODY), allocator)
	copy(response.body, TERMINAL_INJECTION_BODY)

	rendered := strings.builder_make(allocator)
	if err := output.write_response(
		strings.to_writer(&rendered),
		&response,
		output.Parts{head = true, body = true},
		0,
		&config,
	); err != .None {
		testing.expectf(t, false, "write_response failed: %v", err)
	}
	text := strings.to_string(rendered)
	strings.builder_destroy(&rendered)
	http.response_destroy(&response)
	return text
}

// render_must_clone is the two-value clone with the error checked.
@(private)
render_must_clone :: proc(t: ^testing.T, s: string, allocator: mem.Allocator) -> string {
	clone, err := strings.clone(s, allocator)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	return clone
}
