package http

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Split_Text is a string that does not always come from argv in one piece:
// httpie's own URL rule builds the string it hands requests, out of a literal it
// prepends and the argv URL behind it (`_process_url`, cli/argparser.py:205-225
// — the paste shortcut, a URL that names no scheme, and the curl-style
// shorthand). `prefix` is that literal — "" wherever the argv URL is the whole
// string — and `text` the slice behind it. Joining the two needs an allocator,
// so it happens where the string is used, not here: `Target` itself allocates
// nothing (`split_text_join`).
Split_Text :: struct {
	prefix: string,
	text:   string,
}

// split_text_join spells the two pieces as one string. With an empty prefix
// there is nothing to join and the slice is returned borrowed; otherwise the
// caller owns the result (and "" means the allocation failed).
split_text_join :: proc(part: Split_Text, allocator: mem.Allocator) -> string {
	if part.prefix == "" {
		return part.text
	}
	buffer := buffer_make(allocator, len(part.prefix) + len(part.text))
	if !buffer_append_string(&buffer, part.prefix) || !buffer_append_string(&buffer, part.text) {
		buffer_destroy(&buffer)
		return ""
	}
	return string(buffer_owned(&buffer))
}

// split_text_clone_into takes an owned copy of `part` and stores it in `field`,
// releasing whatever `field` held before — the second join site, for the fields
// that keep the string rather than use it once. One allocation: the pieces are
// copied into the field's own buffer, never joined into a temporary the caller
// would then have to copy (and leak). False means the allocation failed, and
// `field` is unchanged then.
split_text_clone_into :: proc(field: ^string, part: Split_Text, allocator: mem.Allocator) -> bool {
	if part.prefix == "" {
		return clone_into(field, part.text, allocator)
	}
	joined := split_text_join(part, allocator)
	if joined == "" {
		return false
	}
	delete(field^, allocator)
	field^ = joined
	return true
}

// Target is the split of a user-supplied URL. Every string in it borrows from
// the input, so splitting allocates nothing and there is nothing to free; the
// Request keeps owned copies — and `url_host_normalize`, which applies the
// reference's host rule, is what produces the host the Request keeps.
Target :: struct {
	scheme:    Scheme,
	host:      string,
	port:      int,
	path:      string,
	query:     string, // without '?'; "" when absent
	// The credentials, without the '@'; empty when the URL spells none. Two
	// pieces only for the curl-style shorthand, whose literal is the
	// `localhost`/`localhost:` httpie's own rule synthesized: the reference
	// partitions the netloc with `rpartition('@')`, so the `@` it finds is in
	// the URL `_process_url` built and the synthesized text in front of it is
	// the *userinfo* — `:3000@example.org/x` authenticates as `localhost:3000`
	// (`docs/PARITY.md` §3.6).
	userinfo: Split_Text,
	// The authority after the userinfo, port included — the string urllib3's
	// `_HOST_PORT_RE` is matched against, and therefore what its "not a valid
	// host or port" message names. Two pieces only for the curl-style
	// shorthand, whose `localhost` httpie's own rule prepends.
	host_port: Split_Text,
	// The URL `_process_url` hands requests: the argv URL with a scheme in
	// front of it when it named none. The two messages that quote the whole URL
	// (`LocationParseError(url)`, and requests' "No host supplied") name this
	// string, not the argv one.
	url: Split_Text,
	// has_userinfo is `urlsplit(url).username is not None` for the URL the rule
	// left behind: the authority spelled an '@', whatever stood in front of it
	// — `http://@host/` carries the *empty* credentials `:` and not none
	// (cli/argparser.py:289-299, docs/PARITY.md §3.6).
	has_userinfo: bool,
	// other_scheme is true when the URL named a scheme `scheme_from_string`
	// does not know. requests still *prepares* such a URL when its text starts
	// with "http" (`httpx://…`), and refuses the rest outright — `unprepared`
	// says which (models.py:498-505), and `scheme_name` is the scheme as
	// spelled, for the message that quotes the URL requests held.
	other_scheme: bool,
	unprepared:   bool,
	scheme_name:  string,
}

// url_split applies httpie's URL rule (cli/argparser.py:205-225, _process_url),
// in order:
//
//   - `://host` is the paste shortcut and loses its `://` — `http ://pie.dev`
//     means `http://pie.dev`;
//   - a URL that names a scheme keeps it, and only http/https are known;
//   - a URL that names none gets `scheme_override` — the caller passes
//     `--default-scheme`, which itself defaults to `http` for the `http`
//     script and `https` for the `https` one;
//   - a schemeless URL of the curl style — `^:(?!:)(\d*)(/?.*)$`: one colon,
//     the port if any, then the rest — expands to `localhost` plus that port,
//     so `:3000/path` is `http://localhost:3000/path`. `(?!:)` keeps a second
//     colon out of the shorthand, which is why `::1/x` is not the localhost of
//     port `:1` but the schemeless `http://::1/x` — and why the rule refuses
//     `::1` rather than reading a port out of it.
//
// What the host rule *reads* out of the authority is `url_host_normalize`'s job:
// this split hands it on in `host_port` — two pieces for the shorthand, whose
// `localhost` httpie's own rule prepends — and keeps `host`/`port` as a best
// effort for the callers that want a host without the rule (the cookie jar, a
// redirect hop). Only the scheme, the userinfo, the path and the query are
// settled here; the port text is not looked at, precisely because a text the
// rule cannot read is an error the rule itself reports.
url_split :: proc(url: string, scheme_override: Maybe(Scheme)) -> (target: Target, err: Error) {
	// The paste shortcut goes first, and what is left is what `URL_SCHEME_RE`
	// is matched against (cli/argparser.py:206-209).
	text := url
	if strings.has_prefix(text, "://") {
		text = text[len("://"):]
	}

	target.scheme = .HTTP
	if scheme, ok := scheme_override.?; ok {
		target.scheme = scheme
	}

	// The URL `_process_url` leaves behind, which is what requests is handed and
	// what its two whole-URL messages name: the argv URL itself, unless the rule
	// had to build one (a scheme to prepend, or the shorthand's `localhost`).
	// A URL that names its scheme *keeps* it — only the split below drops it.
	url_text := text

	named_scheme := false
	if name, ok := url_scheme_of(text); ok {
		scheme, known := scheme_from_string(name)
		if !known {
			// A scheme the port's transport does not speak. requests still
			// prepares the URL when its *text* starts with "http" — the test is
			// `not url.lower().startswith("http")` over the whole URL
			// (models.py:498-505), which for a URL that spells `name://` is
			// `name.lower().startswith("http")` — and short-circuits every
			// other one: `httpx://…` is prepared (requoted, dot segments kept,
			// its host read by `parse_url`'s non-normalizable branch) and
			// `ftp://…` is not prepared at all, so `urlsplit` of the URL itself
			// is all that spells it. Both end in `get_adapter`'s refusal, which
			// is why neither is the split's own error (docs/PARITY.md §3.6,
			// §8 item 21).
			target.other_scheme = true
			target.unprepared = !url_text_starts_with_http(text)
			target.scheme_name = name
		}
		target.scheme = scheme
		text = text[len(name) + len("://"):]
		named_scheme = true
	}

	// The shorthand, and the digits it read back as the port: greedy from the
	// colon, so `:3000abc` hands the rule a port text of `3000abc` — a text the
	// rule refuses, not a port with something after it.
	shorthand := false
	port_digits := ""
	body := text
	if !named_scheme && strings.has_prefix(text, ":") && !strings.has_prefix(text, "::") {
		shorthand = true
		body = text[1:]
		end := 0
		for end < len(body) && body[end] >= '0' && body[end] <= '9' {
			end += 1
		}
		port_digits = body[:end]
	}

	// authority: everything up to the first '/', '?' or '#'.
	authority := body
	remainder := ""
	if end := strings.index_any(body, "/?#"); end >= 0 {
		authority = body[:end]
		remainder = body[end:]
	}

	has_userinfo := false
	if at := strings.last_index(authority, "@"); at >= 0 {
		// The '@' is the *last* one (`rpartition('@')`): the credentials are
		// everything in front of it and the authority what follows. Where they
		// do not come from argv, the branch below says so — the shorthand's
		// `localhost` prefix.
		target.userinfo = {prefix = "", text = authority[:at]}
		authority = authority[at + 1:]
		has_userinfo = true
	}

	// The strings httpie's own rule built, as literal-plus-slice: the URL
	// requests is handed, the authority `_HOST_PORT_RE` is matched against, and
	// — in the shorthand branch, where the reference's `rpartition('@')` reads
	// the `localhost:<port>` *it* synthesized as the credentials — the
	// userinfo (`Split_Text`).
	localhost := url_shorthand_prefix(target.scheme, port_digits != "")
	switch {
	case shorthand:
		target.url = {prefix = localhost, text = body}
		if has_userinfo {
			// Nothing the rule synthesized is a host here: the '@' behind it
			// makes `localhost:<port>` the userinfo, and the authority is the
			// text that follows.
			target.host_port = {prefix = "", text = authority}
			target.userinfo.prefix = port_digits == "" ? "localhost" : "localhost:"
		} else {
			target.host_port = {
				prefix = port_digits == "" ? "localhost" : "localhost:",
				text   = authority,
			}
		}
	case named_scheme:
		target.url = {prefix = "", text = url_text}
		target.host_port = {prefix = "", text = authority}
	case:
		target.url = {
			prefix = target.scheme == .HTTPS ? "https://" : "http://",
			text   = url_text,
		}
		target.host_port = {prefix = "", text = authority}
	}

	switch {
	case strings.has_prefix(authority, "["):
		// A bracketed host: `[::1]` or `[::1]:8080`. Whether the brackets hold
		// an address the rule accepts is its own business — this is the best
		// effort for callers that only ever see a URL the rule let through, and
		// `[::1]x` is left for the rule to refuse.
		if close := strings.index(authority, "]"); close >= 0 {
			target.host = authority[:close + 1]
			if tail := authority[close + 1:]; strings.has_prefix(tail, ":") {
				if port, ok := parse_port(tail[1:]); ok {
					target.port = port
				}
			}
		} else {
			target.host = authority
		}

	case shorthand:
		// The `localhost` the rule prepends; its port is the digits the
		// shorthand read, which `url_host_normalize` re-reads off the authority.
		// A shorthand that spelled a userinfo is the exception: its '@' puts the
		// synthesized `localhost:<port>` in the reference's *userinfo*, so those
		// digits are credentials there and not a port (docs/PARITY.md §3.6).
		target.host = "localhost"
		if !has_userinfo {
			if port, ok := parse_port(port_digits); ok {
				target.port = port
			}
		}

	case strings.index(authority, ":") >= 0:
		// A plain host cannot contain ':': the first one ends the host, and a
		// second one is text the rule refuses (`example.org::80`).
		colon := strings.index(authority, ":")
		target.host = authority[:colon]
		if port, ok := parse_port(authority[colon + 1:]); ok {
			target.port = port
		}

	case:
		target.host = authority
	}

	target.has_userinfo = has_userinfo
	return target, split_path(&target, remainder)
}

// url_text_starts_with_http is requests' `url.lower().startswith("http")`
// (models.py:504), the test that decides whether `prepare_url` prepares a URL
// at all. The URL it is asked about always spells `name://`, so only the
// scheme's first four bytes can decide it; the fold is over ASCII, which is all
// a scheme name holds (`url_scheme_name_ok`).
@(private)
url_text_starts_with_http :: proc(text: string) -> bool {
	HTTP := "http"
	if len(text) < len(HTTP) {
		return false
	}
	for i in 0 ..< len(HTTP) {
		c := text[i]
		if c >= 'A' && c <= 'Z' {
			c = c - 'A' + 'a'
		}
		if c != HTTP[i] {
			return false
		}
	}
	return true
}

// url_shorthand_prefix is what `_process_url` writes in front of the curl-style
// shorthand's remainder: the synthesized `localhost` under the scheme the URL
// resolved to, carrying the ':' of the port when the shorthand spelled one
// (cli/argparser.py:216-223).
@(private)
url_shorthand_prefix :: proc(scheme: Scheme, with_port: bool) -> string {
	switch {
	case scheme == .HTTPS && with_port:
		return "https://localhost:"
	case scheme == .HTTPS:
		return "https://localhost"
	case with_port:
		return "http://localhost:"
	}
	return "http://localhost"
}

// split_path fills `path` and `query` from the path part of a URL (the part
// from the first '/' on, or the tail of the localhost shorthand), dropping a
// fragment. An empty path is "/", exactly as requests normalises it.
//
// The path keeps its '.' and '..' segments: `Target` borrows from the URL it was
// given, and removing them is a change of bytes. urllib3 does it inside
// `parse_url` (util/url.py:551-553) on the string it is about to encode, so the
// port does it where it takes the Request's owned copy of the path
// (`request_create` → `request_set_path`, which knows about `--path-as-is` too).
split_path :: proc(target: ^Target, remainder: string) -> Error {
	path := remainder
	if hash := strings.index(path, "#"); hash >= 0 {
		path = path[:hash]
	}
	if question := strings.index(path, "?"); question >= 0 {
		target.query = path[question + 1:]
		path = path[:question]
	}
	target.path = path != "" ? path : "/"
	return .None
}

// url_path_remove_dot_segments_into appends `path` with its '.' and '..'
// segments removed to `buffer` — urllib3's `_remove_path_dot_segments`
// (util/url.py:323-350), which `parse_url` applies to the path *before* it
// percent-encodes it (util/url.py:551-553). Both the request line the reference
// renders and the bytes it sends carry that reduced path, so `/a/./b` is
// `GET /a/b` and `/a/../b` is `GET /b` (docs/PARITY.md §3.6).
//
// It is a transliteration of the reference's function, which is total and quite
// short — four rules, in this order:
//
//   - '.' is the current directory and is dropped;
//   - every other segment is kept, '..' included, except that a '..' pops the
//     last kept segment when there is one (so a `..` above the root is
//     dropped, not kept);
//   - a path that starts with '/' and whose first kept segment is non-empty (or
//     which kept no segment at all) gets an empty segment in front, so the join
//     starts with '/' — `/../b` is `/b`, while `/a/../b` keeps the empty first
//     segment its own split produced;
//   - a path that ends in '/.' or '/..' gets a trailing empty segment, so the
//     join ends with a '/' (`/a/.` is `/a/`).
//
// An empty segment is *not* a dot segment and stays: `//a//b` is unchanged and
// `//../a` is `/a`. And because the removal happens before the encoding, a
// `%2e` in the URL is an ordinary segment here — only the requoting rule
// (`url_component_quote_into`, which the target is then built with) turns it
// into the '.' the request carries.
//
// False means an allocation failed; the buffer is then partly written and the
// caller discards it.
url_path_remove_dot_segments_into :: proc(buffer: ^Buffer, path: string) -> bool {
	// The kept segments, as slices of `path`. The join happens at the end, so a
	// '..' can drop the last one without disturbing the bytes before it.
	kept := make([dynamic]string, 0, 8, buffer.allocator)
	defer delete(kept)

	index := 0
	for index <= len(path) {
		end := index
		for end < len(path) && path[end] != '/' {
			end += 1
		}
		segment := path[index:end]
		index = end + 1

		if segment == "." {
			continue
		}
		if segment != ".." {
			if _, err := append(&kept, segment); err != .None {
				return false
			}
			continue
		}
		if len(kept) > 0 {
			pop(&kept)
		}
	}

	// The empty segments the reference's list surgery adds are separators of the
	// join and nothing else, so the loop below writes them as such: `offset` is
	// the one in front, `trailing` the one after the last kept segment.
	leading := strings.has_prefix(path, "/") && (len(kept) == 0 || kept[0] != "")
	offset := leading ? 1 : 0
	trailing := strings.has_suffix(path, "/.") || strings.has_suffix(path, "/..")
	total := offset + len(kept) + (trailing ? 1 : 0)

	for i in 0 ..< total {
		if i > 0 && !buffer_append_byte(buffer, '/') {
			return false
		}
		if i >= offset && i < offset + len(kept) {
			if !buffer_append_string(buffer, kept[i - offset]) {
				return false
			}
		}
	}
	return true
}

// url_join_reduced_path_into appends the path a *netloc-less* redirect target
// resolves to: CPython `urljoin`'s own resolution (urllib/parse.py:585-621),
// which `requests` applies to a Location before the hop goes out in
// (`url = urljoin(resp.url, requote_uri(url))`, sessions.py:237-243 — the
// `if not parsed.netloc:` branch, and this is that branch's path half).
//
// It is a *different rule* from `url_path_remove_dot_segments_into` above, and
// one hop runs both of them in order over different strings: that one reduces
// the path urllib3's `parse_url` hands on (the requested URL), this one
// resolves a target against the URL that answered. The difference is visible:
// urljoin builds its segment list from the base *and* the reference and drops
// the empty segments *between* them (urllib/parse.py:585-598) before the
// '.'/'..' loop runs (urllib/parse.py:600-618), so a `//` in the base is gone
// from a path-relative target's path, while a `//` in the reference survives
// the same reduction on its own (docs/PARITY.md §3.6).
//
// `base_path` is the base URL's path and `reference` the Location's, both with
// their query and fragment already cut off: urljoin only ever looks at the two
// paths, and everything from the reference's first '?' or '#' is put back
// untouched by `urlunparse` (urllib/parse.py:620-621).
//
// The three shapes urljoin distinguishes, in its own order:
//
//   - a root-relative reference (`/a/./b`) *ignores the base path* — "for
//     rfc3986, ignore all base path should the first character be root"
//     (urllib/parse.py:591, CPython's own comment) — and is reduced on its own;
//   - any other reference path is merged onto the base's directory
//     (`bpath.split('/')` with the last element dropped when it is not the
//     empty one a trailing '/' left, urllib/parse.py:585-589) and the middle
//     empty segments of that merge are filtered out (urllib/parse.py:598);
//   - then both go through the same loop: '.' is dropped, '..' pops the last
//     kept segment and is dropped itself when there is none, every other
//     segment — the empty ones included — is kept, and a reference that ends in
//     '.' or '..' gets the empty segment that spells the final
//     (urllib/parse.py:615-618). The join is guaranteed to start with '/' and an
//     empty one is '/', because `urlunparse` puts the path of an authority
//     there (urllib/parse.py:620).
//
// So `/a/../b` against `http://h/x/y` is `/b`, while a Location that carries a
// netloc keeps its dots entirely (`http://h/a/../b` stays `/a/../b`) — that is
// requests' other branch, not this function's (docs/PARITY.md §3.6).
//
// False means an allocation failed; the buffer is then partly written and the
// caller discards it.
url_join_reduced_path_into :: proc(buffer: ^Buffer, base_path: string, reference: string) -> bool {
	// urljoin's segment list, as slices of the two paths. `..` only ever pops
	// the *last* kept segment, so the list is what the loop below needs.
	segments := make([dynamic]string, 0, 8, buffer.allocator)
	defer delete(segments)

	if strings.has_prefix(reference, "/") {
		if !url_append_segments(&segments, reference) {
			return false
		}
	} else {
		if !url_append_segments(&segments, base_path) {
			return false
		}
		if len(segments) > 0 && segments[len(segments) - 1] != "" {
			pop(&segments)
		}
		if !url_append_segments(&segments, reference) {
			return false
		}
		// `segments[1:-1] = filter(None, segments[1:-1])`
		// (urllib/parse.py:598): the empty segments between the first and the
		// last go, and only in this branch — the merge is the one that can
		// leave them behind (`base_path` is `/re//dir/start`, so a merge onto
		// its directory holds the `//`'s empty segment, and the reference drops
		// it where the reduction alone would not).
		if len(segments) > 2 {
			write := 1
			for read in 1 ..< len(segments) - 1 {
				if segments[read] == "" {
					continue
				}
				segments[write] = segments[read]
				write += 1
			}
			segments[write] = segments[len(segments) - 1]
			resize(&segments, write + 1)
		}
	}

	kept := make([dynamic]string, 0, len(segments), buffer.allocator)
	defer delete(kept)

	for segment in segments {
		if segment == ".." {
			if len(kept) > 0 {
				pop(&kept)
			}
			continue
		}
		if segment == "." {
			continue
		}
		if _, err := append(&kept, segment); err != .None {
			return false
		}
	}

	// The empty segment a trailing '.' or '..' adds, which is the '/' the
	// reference's join ends with (`/a/.` is `/a/`).
	trailing := segments[len(segments) - 1] == "." || segments[len(segments) - 1] == ".."
	total := len(kept) + (trailing ? 1 : 0)

	// `'/'.join(resolved_path) or '/'`: the separators are written as such, so
	// the joined length is known before a byte is written and the two
	// normalizations are decided from it.
	length := 0
	for i in 0 ..< total {
		if i > 0 {
			length += 1
		}
		if i < len(kept) {
			length += len(kept[i])
		}
	}
	if length == 0 {
		return buffer_append_byte(buffer, '/')
	}
	if kept[0] != "" && kept[0][0] != '/' {
		if !buffer_append_byte(buffer, '/') {
			return false
		}
	}
	for i in 0 ..< total {
		if i > 0 && !buffer_append_byte(buffer, '/') {
			return false
		}
		if i < len(kept) && !buffer_append_string(buffer, kept[i]) {
			return false
		}
	}
	return true
}

// url_append_segments appends CPython's `path.split('/')` of `path` to
// `segments`: an empty path is one empty segment and a trailing '/' produces a
// trailing empty one, exactly as `str.split` does. The two callers that build
// urljoin's list need the elements, where `url_path_remove_dot_segments_into`
// walks the same split by index because it never needs them as a list.
url_append_segments :: proc(segments: ^[dynamic]string, path: string) -> bool {
	start := 0
	for {
		end := start
		for end < len(path) && path[end] != '/' {
			end += 1
		}
		if _, err := append(segments, path[start:end]); err != .None {
			return false
		}
		if end >= len(path) {
			return true
		}
		start = end + 1
	}
}

// url_scheme_of reports whether `s` starts with `name://`, name being what
// URL_SCHEME_RE accepts: a letter followed by letters, digits, '.', '+' or '-'.
url_scheme_of :: proc(s: string) -> (name: string, ok: bool) {
	idx := strings.index(s, "://")
	if idx <= 0 {
		return "", false
	}
	name = s[:idx]
	if !url_scheme_name_ok(name) {
		return "", false
	}
	return name, true
}

// url_scheme_name_ok is the scheme test itself: an ASCII letter followed by the
// scheme characters — letters, digits, '.', '+' and '-' (CPython's
// `scheme_chars`, urllib/parse.py:82). `urlsplit` applies the same test to the
// text before a ':' to decide whether a string names a scheme at all
// (urllib/parse.py:503-509), which is the other caller.
url_scheme_name_ok :: proc(name: string) -> bool {
	if name == "" || !is_alpha(name[0]) {
		return false
	}
	for i in 1 ..< len(name) {
		c := name[i]
		if !(is_alpha(c) || is_digit(c) || c == '.' || c == '+' || c == '-') {
			return false
		}
	}
	return true
}

is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// parse_port reads the text after a ':' in the authority. An empty port is not
// a port — `http://localhost:/x` is legal and means the default one — and any
// number requests accepts is legal, 0 included (it means "unset" further down).
parse_port :: proc(s: string) -> (int, bool) {
	if s == "" {
		return 0, true
	}
	port, ok := strconv.parse_int(s, 10)
	if !ok || port < 0 || port > 65535 {
		return 0, false
	}
	return port, true
}

// ---------------------------------------------------------------------------
// The request-target's spelling: urllib3's `_encode_invalid_chars` and requests'
// `requote_uri`, in the order the reference applies them.
// ---------------------------------------------------------------------------

// Url_Component names the URL part that is being spelled. urllib3 picks the
// allowed-character set from it (`_PATH_CHARS`, `_QUERY_CHARS`,
// util/url.py:77-83), and the query is the only one that allows '?'.
Url_Component :: enum {
	Path,
	Query,
}

// url_component_quote_into writes the request-target spelling of one URL
// component — the path, or the query the URL itself carries (the `name==value`
// items are requests' other rule, `_encode_params`, and are not this one).
//
// Two library functions produce it, in this order:
//
//   - urllib3's `_encode_invalid_chars` (util/url.py:277-320). It percent-encodes
//     every byte of the component that is not an allowed character for that part
//     (`/a b` → `/a%20b`, `/héllo` → `/h%C3%A9llo`, `/a|b` → `/a%7Cb`), leaves an
//     already percent-encoded component's escapes alone, and uppercases their hex
//     (`%ff` → `%FF`); a '%' that does not start an escape, or a component only
//     partly percent-encoded, becomes `%25` (`a%zz` → `a%25zz`).
//   - requests' `requote_uri` (utils.py:680-723), which unquotes an escape whose
//     octet is an unreserved character (`%41` → `A`, `%7e` → `~`) and re-quotes
//     what is left with urllib3's safe set — a no-op on the first step's output,
//     because every character it can emit is in that set.
//
// The component is a byte string, so "a byte that is not valid UTF-8" is the lone
// surrogate CPython's surrogateescape made of it. `str_utf8_seq_len` walks the
// well-formed sequences, and the bytes outside one are written as the three bytes
// of U+DC80+byte — which is what `encode("utf-8", "surrogatepass")` leaves for
// them, so byte 0xff is `%ED%B3%BF` (docs/PARITY.md §3.6).
//
// `requote_uri`'s except-branch is the third case, and it is not this
// component's own. `unquote_unreserved` raises InvalidURL when the two
// characters behind a '%' are alphanumeric but not hexadecimal, and requote_uri
// then quotes the *raw* URL with `safe_without_percent` — so every '%' of it,
// the path's and the query's included, becomes `%25` and no escape is unquoted.
// The first step leaves every '%' of a component *it* wrote followed by two hex
// digits, so a path or a query can never make that window appear; the netloc
// can, because the zone-id branch of `_normalize_host` writes the RFC 6874
// separator back as a bare '%' (util/url.py:387, src/http/host.odin).
// `requote_fallback` is that decision, and it is a property of the *URL*, not
// of this component: `requote_uri` runs over the whole prepared URL
// (models.py:560), so the caller that normalized the netloc hands it in
// (`url_host_normalize`'s out-param, kept on the Request: `http.request_target`)
// — and the path, the URL's own query and the `name==value` items all honour
// the same one (docs/PARITY.md §3.6, kanban t_75b15cf5).
//
// The two halves are separate procs because a followed hop needs them apart: the
// URL requests resolved a Location to carries the requote alone
// (sessions.py:237-243), and the bytes that hop puts on the wire are the
// `_encode_invalid_chars` of that URL's path and query, applied at send time
// (`url_wire_url_into` below, docs/PARITY.md §3.6).
url_component_quote_into :: proc(
	buffer: ^Buffer,
	component: string,
	part: Url_Component,
	requote_fallback := false,
) -> bool {
	start := len(buffer.data)
	if !url_component_encode_into(buffer, component, part) {
		return false
	}
	if requote_fallback {
		url_quote_literal_percents_into(buffer, start)
	} else {
		url_unquote_unreserved(buffer, start)
	}
	return true
}

// url_component_encode_into is urllib3's `_encode_invalid_chars`
// (util/url.py:277-320) alone — the first half `url_component_quote_into`
// composes with requests' requote.
//
// The component is a byte string, so "a byte that is not valid UTF-8" is the lone
// surrogate CPython's surrogateescape made of it. `str_utf8_seq_len` walks the
// well-formed sequences, and the bytes outside one are written as the three bytes
// of U+DC80+byte — which is what `encode("utf-8", "surrogatepass")` leaves for
// them, so byte 0xff is `%ED%B3%BF` (docs/PARITY.md §3.6).
url_component_encode_into :: proc(buffer: ^Buffer, component: string, part: Url_Component) -> bool {
	// urllib3's fast path (util/url.py:288-298): an ASCII component made of
	// allowed characters and carrying no '%' is returned as it is. A '%' is not
	// an allowed character, so this is the "no '%' and all allowed" test.
	ascii_allowed := true
	percents := 0
	escapes := 0
	for index := 0; index < len(component); {
		byte := component[index]
		if byte == '%' {
			// '%' is in neither allowed set, so its presence alone rules the
			// fast path out (util/url.py:293-297).
			percents += 1
			ascii_allowed = false
			if index + 2 < len(component) &&
			   url_is_hex_digit(component[index + 1]) && url_is_hex_digit(component[index + 2]) {
				escapes += 1
				index += 3
				continue
			}
		}
		if byte >= 0x80 || !url_component_char_allowed(byte, part) {
			ascii_allowed = false
		}
		index += 1
	}
	if ascii_allowed {
		return buffer_append_string(buffer, component)
	}

	// `is_percent_encoded` (util/url.py:300-308): the escapes the component
	// carries are compared with the '%' bytes it has. When every '%' starts an
	// escape the component is already percent-encoded and its '%' bytes are kept;
	// otherwise each of them is a literal and becomes `%25`. (Both counters are
	// zero only for a component whose bytes all took the pass-through branch
	// below, so the comparison cannot mislead there.)
	percent_encoded := escapes == percents

	for index := 0; index < len(component); {
		byte := component[index]
		if byte == '%' && index + 2 < len(component) &&
		   url_is_hex_digit(component[index + 1]) && url_is_hex_digit(component[index + 2]) {
			// A percent-escape. The normalization (util/url.py:303-305) rewrites
			// its hex uppercase *before* the byte loop runs, so the two digits are
			// uppercase in either branch — and a '%' followed by two hex digits is
			// a match start here exactly when the scan above counted it as one.
			high := url_hex_upper(component[index + 1])
			low := url_hex_upper(component[index + 2])
			if percent_encoded {
				// The escape survives as it is, hex uppercased (`%ff` → `%FF`).
				if !buffer_append_byte(buffer, '%') ||
				   !buffer_append_byte(buffer, high) || !buffer_append_byte(buffer, low) {
					return false
				}
			} else {
				// The '%' is a literal: it becomes `%25`, and the two hex digits
				// behind it are allowed characters that keep the uppercased
				// spelling the normalization gave them (`%4a` → `%254A`).
				if !buffer_append_string(buffer, "%25") ||
				   !buffer_append_byte(buffer, high) || !buffer_append_byte(buffer, low) {
					return false
				}
			}
			index += 3
			continue
		}
		width := str_utf8_seq_len(component[index:])
		if width <= 0 {
			// Not valid UTF-8: the byte is the lone surrogate U+DC80+byte, and
			// its UTF-8 form is percent-encoded byte by byte.
			for octet in url_surrogate_octets(byte) {
				if !url_append_percent_byte(buffer, octet) {
					return false
				}
			}
			index += 1
			continue
		}
		if width == 1 && url_component_char_allowed(byte, part) {
			if !buffer_append_byte(buffer, byte) {
				return false
			}
			index += 1
			continue
		}
		// A well-formed multi-byte character is not ASCII, so every one of its
		// bytes is encoded; so is an ASCII byte outside the allowed set.
		for offset in 0 ..< width {
			if !url_append_percent_byte(buffer, component[index + offset]) {
				return false
			}
		}
		index += width
	}
	return true
}

// url_component_char_allowed is urllib3's allowed set for one component
// (util/url.py:77-83): the unreserved characters, the sub-delimiters and ':',
// plus '@' and '/' for the path, plus '?' for the query. '%' is not in either
// set — whether it survives is the `is_percent_encoded` test above.
@(private)
url_component_char_allowed :: proc(byte: u8, part: Url_Component) -> bool {
	switch {
	case byte >= 'A' && byte <= 'Z', byte >= 'a' && byte <= 'z', byte >= '0' && byte <= '9',
	     byte == '.', byte == '_', byte == '-', byte == '~': // unreserved
		return true
	case byte == '!', byte == '$', byte == '&', byte == '\'', byte == '(', byte == ')',
	     byte == '*', byte == '+', byte == ',', byte == ';', byte == '=': // sub-delimiters
		return true
	case byte == ':', byte == '@', byte == '/':
		return true
	case part == .Query && byte == '?':
		return true
	}
	return false
}

// url_unreserved_char is requests' UNRESERVED_SET (utils.py:674-677): the
// characters requests' `unquote_unreserved` puts back — and only those.
@(private)
url_unreserved_char :: proc(byte: u8) -> bool {
	switch {
	case byte >= 'A' && byte <= 'Z', byte >= 'a' && byte <= 'z', byte >= '0' && byte <= '9':
		return true
	case byte == '-', byte == '.', byte == '_', byte == '~':
		return true
	}
	return false
}

// url_unquote_unreserved is requote_uri's first half (requests utils.py:680-701)
// applied in place to the component `url_component_quote_into` just wrote: an
// escape whose octet is an unreserved character becomes that character, every
// other escape stays `%XX`. The replacement never grows, so the pass compacts the
// buffer from `start` on and then shrinks it — it cannot fail. It is the half
// that runs when `unquote_unreserved` did *not* raise; the except-branch's
// `quote` is `url_quote_literal_percents_into` below.
@(private)
url_unquote_unreserved :: proc(buffer: ^Buffer, start: int) {
	data := buffer.data[start:]
	read, write := 0, 0
	for read < len(data) {
		if data[read] == '%' && read + 2 < len(data) {
			high, high_ok := url_hex_value(data[read + 1])
			low, low_ok := url_hex_value(data[read + 2])
			if high_ok && low_ok {
				octet := high << 4 | low
				if url_unreserved_char(octet) {
					data[write] = octet
					write += 1
					read += 3
					continue
				}
				data[write + 0] = '%'
				data[write + 1] = url_hex_upper(data[read + 1])
				data[write + 2] = url_hex_upper(data[read + 2])
				write += 3
				read += 3
				continue
			}
		}
		data[write] = data[read]
		write += 1
		read += 1
	}
	resize(&buffer.data, start + write)
}

// url_quote_literal_percents_into turns every '%' of `buffer[start:]` into
// `%25` — the other half of the composition `url_component_quote_into` uses in
// `requote_uri`'s except-branch: `quote(uri, safe_without_percent)`, applied to
// bytes that are already spelled (urllib3's `_encode_invalid_chars` output, or
// the `quote_plus` spelling of a `name==value` item, which is inside the string
// requests hands the requote). Nothing else of those bytes can change: every
// character either step can write is in `safe_without_percent`
// (`url_requote_safe`), so '%' is the only one CPython's `quote` sees.
//
// The pass grows the buffer by two bytes per '%', so it walks the bytes
// backwards from the end instead of compacting them forwards; it cannot fail.
url_quote_literal_percents_into :: proc(buffer: ^Buffer, start: int) {
	length := len(buffer.data)
	extra := 0
	for index := start; index < length; index += 1 {
		if buffer.data[index] == '%' {
			extra += 2
		}
	}
	if extra == 0 {
		return
	}
	resize(&buffer.data, length + extra)
	read := length - 1
	write := length + extra - 1
	for read >= start {
		if buffer.data[read] == '%' {
			buffer.data[write - 2] = '%'
			buffer.data[write - 1] = '2'
			buffer.data[write + 0] = '5'
			write -= 3
		} else {
			buffer.data[write] = buffer.data[read]
			write -= 1
		}
		read -= 1
	}
}

// ---------------------------------------------------------------------------
// The redirect target's spelling: requests' `requote_uri` alone.
// ---------------------------------------------------------------------------

// url_requote_into writes the redirect target's spelling of `location` into
// `buffer`: the Location a followed 3xx carried, requoted the way requests
// requotes it before the hop is sent. It is `requote_uri` *alone* — not the
// `_encode_invalid_chars` + requote composition `url_component_quote_into`
// implements for the first request's path and query — and it is applied to the
// whole URL string, in requests/sessions.py:237-243:
//
//   if not parsed.netloc:
//       url = urljoin(resp.url, requote_uri(url))
//   else:
//       url = requote_uri(url)
//
// So the port's hop loop calls this *before* `resolve_location`, which is the
// urljoin half. The calling site is the redirect loop in
// src/http/curl_transport.odin; the first request's own shortening is
// `request_target`'s and is untouched by this.
//
// `requote_uri` (requests utils.py:704-723) is two library functions:
//
//   - `unquote_unreserved` (utils.py:680-701). The URI is split on '%', and for
//     every '%' the two *characters* behind it are `h`: when `len(h) == 2` and
//     `h.isalnum()`, `int(h, 16)` is evaluated and `InvalidURL` is raised when it
//     fails. An escape that passes has the octet it spells put back when that
//     octet is unreserved (`%41` → `A`, `%7e` → `~`); every other escape —
//     `%20`, `%2F`, and `%c3%a9` with its lowercase hex — is left exactly as it
//     was. `int(h, 16)` succeeds for two ASCII hexadecimal digits and for two
//     Unicode decimal digits (`٣١`); anything else alphanumeric in the window
//     (`zz`, `g1`, `0x`, `é1`) makes it fail.
//   - CPython's `quote(.., safe="!#$%&'()*+,/:;=?@[]~")`: every byte outside
//     `_ALWAYS_SAFE` (`A-Za-z0-9_.-~`) plus that set becomes `%XX` uppercase.
//     '%' is in the set, so an escape — and a '%' that starts none — survives
//     as it is.
//
// The `InvalidURL` case is decided for the *whole string*: it aborts the unquote
// pass before it has run, and the except-branch then quotes the raw URI with
// `safe_without_percent` (the same set, '%' removed). One unreadable escape
// therefore makes every '%' of the Location a literal `%25` *and* leaves every
// otherwise-unquotable escape alone (`a%41%zz` → `a%2541%25zz`, not `aA%25zz`).
//
// A character the reference cannot reach here is not modelled: the Location it
// gets is the UTF-8 decode of the header's bytes (sessions.py:142-151), so a
// byte that is not valid UTF-8 raises `UnicodeDecodeError` inside requests
// before `requote_uri` runs (docs/PARITY.md §3.6, the str layer). A byte the
// port holds anyway is treated as the lone surrogate it is there: not
// alphanumeric, so it neither raises nor is unquoted.
url_requote_into :: proc(buffer: ^Buffer, uri: string) -> bool {
	return url_requote_decided_into(buffer, uri, url_requote_is_invalid(uri))
}

// url_requote_decided_into is `url_requote_into` with the `InvalidURL` decision
// already made — the caller that needs to know it anyway (the zone-id branch of
// `url_host_normalize`, which hands it on to the path and the query the prepared
// URL carries) does not scan the string twice, and the one decision is what every
// byte of the prepared URL then honours.
url_requote_decided_into :: proc(buffer: ^Buffer, uri: string, fallback: bool) -> bool {
	index := 0
	for index < len(uri) {
		byte := uri[index]
		if byte == '%' && !fallback {
			if value, ok := url_requote_escape_value(uri, index); ok && url_unreserved_char(value) {
				// The escape spells an unreserved character: it goes back to
				// being that character (`%41` → `A`), which is always a safe
				// character too, so it needs no further quoting.
				if !buffer_append_byte(buffer, value) {
					return false
				}
				index += 3
				continue
			}
		}
		if url_requote_safe(byte, fallback) {
			if !buffer_append_byte(buffer, byte) {
				return false
			}
		} else if !url_append_percent_byte(buffer, byte) {
			return false
		}
		index += 1
	}
	return true
}

// url_unquoted_into writes one component of `requote_uri`'s *input*: requests'
// `unquote_unreserved` alone, with CPython's `quote` left out — the spelling the
// string has at the moment `quote` is handed it, which is what a position CPython
// reports for a character it cannot encode is counted in (the `.Other_Scheme`
// branch of `request_other_scheme_url`, and `request_check_other_scheme_url`).
//
// An escape that spells an unreserved octet goes back to being that character
// (`%41` → `A`) and every other byte — an escape that stays, a '%' that starts
// none, any other byte of the component — is written as it is. That is the whole
// difference from `url_requote_decided_into`, which writes the second half of the
// same composition: the two agree byte for byte on every position, and the split
// is the reference's own (`quote(unquote_unreserved(uri), safe=…)`).
//
// The `InvalidURL` case is the caller's decision, as it is for the requote:
// `fallback` true means `unquote_unreserved` raised, so the string `quote` is
// handed is the *raw* one and `url_requote_decided_into`'s caller wrote every '%'
// as `%25` — this half then writes the raw bytes.
//
// False means an allocation failed. The caller owns `buffer`.
url_unquoted_into :: proc(buffer: ^Buffer, uri: string, fallback: bool) -> bool {
	index := 0
	for index < len(uri) {
		byte := uri[index]
		if byte == '%' && !fallback {
			if value, ok := url_requote_escape_value(uri, index); ok && url_unreserved_char(value) {
				if !buffer_append_byte(buffer, value) {
					return false
				}
				index += 3
				continue
			}
		}
		if !buffer_append_byte(buffer, byte) {
			return false
		}
		index += 1
	}
	return true
}

// url_wire_url_into writes the URL a followed hop's request is *sent* with: the
// origin as it stands plus the request target urllib3 spells at send time.
//
// `HTTPConnectionPool.urlopen` re-encodes the target it is handed
// (connectionpool.py:713-717):
//
//   if url.startswith("/"):
//       url = to_str(_encode_target(url))
//
// and `_encode_target` (util/url.py:453-467) is `_encode_invalid_chars` of the
// path with `_PATH_CHARS`, then of the query with `_QUERY_CHARS` — the same
// first half `url_component_quote_into` uses, with no requote after it. That is
// the whole difference between the two spellings of a hop: requests resolved the
// Location with `requote_uri` alone (so `%c3%a9` stays lowercase, a raw '%' stays
// a raw '%' and `[` stays a bracket in the URL the history renders), and the
// connection then encodes the path and the query for the wire, which uppercases
// the escape, makes every '%' that starts none a `%25`, and encodes the brackets
// (docs/PARITY.md §3.6).
//
// The target is the path plus the query and nothing else: requests sends
// `request.path_url` (models.py:113-129, adapters.py:592), which gives an empty
// path a `/` and leaves the fragment out.
url_wire_url_into :: proc(buffer: ^Buffer, url: string) -> bool {
	// The origin ends at the first '/', '?' or '#' — the authority split
	// `url_location_parse` makes, plus the two a Location can put there
	// (`http://host?q=1`).
	origin := url
	rest := "/"
	scheme_end := strings.index(url, "://")
	authority_start := scheme_end >= 0 ? scheme_end + 3 : 0
	if cut := strings.index_any(url[authority_start:], "/?#"); cut >= 0 {
		origin = url[:authority_start + cut]
		rest = url[authority_start + cut:]
	}
	if !buffer_append_string(buffer, origin) {
		return false
	}

	target := rest
	if fragment := strings.index_byte(target, '#'); fragment >= 0 {
		target = target[:fragment]
	}
	path := target
	query := ""
	has_query := false
	if mark := strings.index_byte(target, '?'); mark >= 0 {
		path = target[:mark]
		query = target[mark + 1:]
		has_query = true
	}
	// `path_url` guarantees the leading '/', and `_encode_target` requires it.
	if path == "" {
		if !buffer_append_byte(buffer, '/') {
			return false
		}
	} else if !url_component_encode_into(buffer, path, .Path) {
		return false
	}
	if has_query {
		if !buffer_append_byte(buffer, '?') || !url_component_encode_into(buffer, query, .Query) {
			return false
		}
	}
	return true
}

// url_requote_is_invalid is `unquote_unreserved`'s `InvalidURL` test over the
// whole string: a '%' whose two following characters are both alphanumeric can
// only be read as a hexadecimal number when both of them are ASCII hexadecimal
// digits — and when a window is all alphanumeric but not readable, the escape
// pass raises for the *whole* URI.
//
// The one place this is coarser than the reference: `int(h, 16)` also reads
// Unicode decimal digits, so a window of two of them does not raise there. The
// port treats every non-ASCII alphanumeric character as unreadable; the
// divergence is observable only in a Location that carries such a window *and*
// another escape, and docs/PARITY.md §3.6 records it.
url_requote_is_invalid :: proc(uri: string) -> bool {
	for index := 0; index < len(uri); index += 1 {
		if uri[index] != '%' {
			continue
		}
		first, first_ok := url_requote_char(uri[index + 1:])
		if !first_ok {
			continue
		}
		second, second_ok := url_requote_char(uri[index + 1 + first.width:])
		if !second_ok || !url_requote_char_alnum(first) || !url_requote_char_alnum(second) {
			continue
		}
		if first.width != 1 || second.width != 1 ||
		   !url_is_hex_digit(first.byte) || !url_is_hex_digit(second.byte) {
			return true
		}
	}
	return false
}

// url_requote_escape_value reads the escape starting at `uri[percent]` when it
// is two ASCII hexadecimal digits, and returns the byte it spells.
@(private)
url_requote_escape_value :: proc(uri: string, percent: int) -> (value: u8, ok: bool) {
	if percent + 2 >= len(uri) {
		return 0, false
	}
	high, high_ok := url_hex_value(uri[percent + 1])
	low, low_ok := url_hex_value(uri[percent + 2])
	if !high_ok || !low_ok {
		return 0, false
	}
	return high << 4 | low, true
}

// url_requote_safe is the safe set CPython's `quote` is called with: requests'
// `safe_with_percent` (utils.py:714) plus `_ALWAYS_SAFE` (urllib/parse.py),
// which that set does not carry — and `safe_without_percent`, the same set
// without '%', in the `InvalidURL` branch (utils.py:722-723).
@(private)
url_requote_safe :: proc(byte: u8, fallback: bool) -> bool {
	switch {
	case byte >= 'A' && byte <= 'Z', byte >= 'a' && byte <= 'z', byte >= '0' && byte <= '9',
	     byte == '_', byte == '.', byte == '-', byte == '~': // _ALWAYS_SAFE
		return true
	case byte == '!', byte == '#', byte == '$', byte == '&', byte == '\'', byte == '(',
	     byte == ')', byte == '*', byte == '+', byte == ',', byte == '/', byte == ':',
	     byte == ';', byte == '=', byte == '?', byte == '@', byte == '[', byte == ']':
		return true
	case byte == '%':
		return !fallback
	}
	return false
}

// Url_Requote_Char is one *character* of a URL string the way the reference's
// Python sees it: the code point of a well-formed UTF-8 sequence, or — for a
// byte that is not one — the lone surrogate `surrogateescape` makes of it.
@(private)
Url_Requote_Char :: struct {
	byte:  u8,
	code:  rune,
	width: int,
}

@(private)
url_requote_char :: proc(s: string) -> (char: Url_Requote_Char, ok: bool) {
	if s == "" {
		return {}, false
	}
	width := str_utf8_seq_len(s)
	if width <= 0 {
		return {byte = s[0], code = rune(0xdc00) + rune(s[0]), width = 1}, true
	}
	code, _ := utf8.decode_rune_in_string(s)
	return {byte = s[0], code = code, width = width}, true
}

// url_requote_char_alnum is Python's `str.isalnum` for one character: the
// letters, and everything `isdecimal`/`isdigit`/`isnumeric` accept — which is
// `unicode.is_number` here (both the ASCII and the non-ASCII branch answer the
// same way for the ASCII range).
@(private)
url_requote_char_alnum :: proc(char: Url_Requote_Char) -> bool {
	if char.width == 1 {
		return is_alpha(char.byte) || is_digit(char.byte)
	}
	return unicode.is_letter(char.code) || unicode.is_number(char.code)
}

// url_append_percent_byte writes one byte as `%XX`, uppercase — the spelling both
// `_encode_invalid_chars` and CPython's `quote` use.
@(private)
url_append_percent_byte :: proc(buffer: ^Buffer, byte: u8) -> bool {
	digits := "0123456789ABCDEF"
	return buffer_append_byte(buffer, '%') &&
	       buffer_append_byte(buffer, digits[byte >> 4]) &&
	       buffer_append_byte(buffer, digits[byte & 0x0f])
}

// url_surrogate_octets is the UTF-8 form of the lone surrogate a byte became:
// U+DC80+byte, the three bytes `encode("utf-8", "surrogatepass")` writes for it.
// 0xff is ED B3 BF.
@(private)
url_surrogate_octets :: proc(byte: u8) -> [3]u8 {
	code := u32(0xdc00) + u32(byte)
	return {
		0xe0 | u8(code >> 12),
		0x80 | u8((code >> 6) & 0x3f),
		0x80 | u8(code & 0x3f),
	}
}

@(private)
url_is_hex_digit :: proc(byte: u8) -> bool {
	_, ok := url_hex_value(byte)
	return ok
}

@(private)
url_hex_value :: proc(byte: u8) -> (u8, bool) {
	switch {
	case byte >= '0' && byte <= '9':
		return byte - '0', true
	case byte >= 'a' && byte <= 'f':
		return byte - 'a' + 10, true
	case byte >= 'A' && byte <= 'F':
		return byte - 'A' + 10, true
	}
	return 0, false
}

@(private)
url_hex_upper :: proc(byte: u8) -> u8 {
	if byte >= 'a' && byte <= 'f' {
		return byte - 'a' + 'A'
	}
	return byte
}

// ---------------------------------------------------------------------------
// Where a Location points: CPython's urlparse/urlunparse and urljoin
// ---------------------------------------------------------------------------

// Url_Location is a redirect target split the way CPython's `urlparse` splits
// it (urllib/parse.py:374-402) — which is what requests does to a Location
// twice: once for `parsed = urlparse(url)` / `url = parsed.geturl()`, and again
// inside `urljoin`. Every field borrows from the string that was parsed, the
// scheme included: `urlparse` lowercases it, so the port writes it lowercased
// where the URL is spelled out (`url_location_unparse_into`) and compares it
// folded, rather than owning a lowered copy.
Url_Location :: struct {
	scheme:   string, // as written; the rule lowercases it when it is spelled
	netloc:   string,
	path:     string,
	params:   string, // without ';'; "" when absent
	query:    string, // without '?'; "" when absent
	fragment: string, // without '#'; "" when absent
}

// url_carries_unsafe_byte reports whether `text` holds one of the three bytes
// `urlsplit` deletes from a URL before it parses anything — tab, CR and LF
// (`_UNSAFE_URL_BYTES_TO_REMOVE`, urllib/parse.py:92). `url_location_parse`,
// which is what removes them, asks first so that a URL holding none of them is
// parsed where it lies: no copy, no allocation.
@(private)
url_carries_unsafe_byte :: proc(text: string) -> bool {
	return strings.index_any(text, "\t\r\n") >= 0
}

// url_location_parse is `urlparse` (which is `urlsplit` plus the params split of
// the path, urllib/parse.py:397) over a Location or a base URL:
//
//   - the three bytes CPython deletes from the *whole* URL before it looks for
//     anything — tab, CR and LF (`_UNSAFE_URL_BYTES_TO_REMOVE`,
//     urllib/parse.py:92, removed by the loop at :497-500, which runs right
//     after the lstrip below) — are gone before the ':'-scheme scan: a Location
//     of `/a<TAB>b` is the path `/ab`, and the port used to keep the byte and
//     let the requote spell it `%09` instead (docs/PARITY.md §8 item 23,
//     build/probe_no_adapter_target.py). They are the one thing here that can
//     need room of its own, which is what `scratch` is for;
//   - the scheme is the text before a ':' that passes `url_scheme_name_ok`, and
//     `urlsplit` **lowercases** it (urllib/parse.py:509) — that is what makes
//     `HTTP://host/x` an absolute URL with the scheme `http`;
//   - the netloc is the text after a leading `//` up to the first '/', '?' or
//     '#';
//   - the fragment is cut off first and the query after it, both with the first
//     of their delimiter (urllib/parse.py:517-520), so `a#b?c` has the fragment
//     `b?c` and no query;
//   - and the params are split off the path — a ';' after the last '/', or the
//     first ';' when the path has no '/' at all (`_splitparams`,
//     urllib/parse.py:404-411). This happens for every Location, because the
//     empty scheme is in `uses_params` too.
//
// The split is not cosmetic: `urljoin`'s "no path" branch tests `path` *and*
// `params`, and `urlunparse` puts the params back directly behind the path.
//
// `scratch` is the caller's buffer for the copy that deletion needs. A URL
// holding none of the three bytes — every URL but the ones that rule exists for
// — writes nothing to it and allocates nothing, so the ordinary parse costs no
// more than it did. When one is there, the filtered copy is appended to
// `scratch` and the fields borrow *that*, so the caller must keep `scratch`
// alive and unappended-to for as long as they are used, and destroy it
// afterwards; it has to be empty on entry, because the parse appends rather
// than clears. False means the append failed, and the result means nothing
// then.
url_location_parse :: proc(location: string, scratch: ^Buffer) -> (parsed: Url_Location, ok: bool) {
	rest := location

	// `urlsplit` removes the C0 control and space characters from the front
	// before it looks for anything (`url = url.lstrip(_WHATWG_C0_CONTROL_OR_SPACE)`,
	// urllib/parse.py:492-494), so a Location whose first byte is one of them —
	// a form feed or a vertical tab, say, which the header parse does not trim
	// — loses it here, in the parse that `geturl` and `urljoin` both make.
	for len(rest) > 0 && rest[0] <= 0x20 {
		rest = rest[1:]
	}

	// ...and then deletes the three `_UNSAFE_URL_BYTES_TO_REMOVE` bytes from
	// what is left, wherever they sit — the authority, the path, the query and
	// the fragment alike (urllib/parse.py:497-500, immediately after the
	// lstrip above). That is the one step of `urlsplit` that cannot be done by
	// moving the ends of a slice, hence the copy.
	if url_carries_unsafe_byte(rest) {
		if !url_unsafe_bytes_strip_into(scratch, rest) {
			return {}, false
		}
		rest = string(scratch.data[:])
	}

	if colon := strings.index_byte(rest, ':'); colon > 0 && url_scheme_name_ok(rest[:colon]) {
		parsed.scheme = rest[:colon]
		rest = rest[colon + 1:]
	}
	if strings.has_prefix(rest, "//") {
		rest = rest[2:]
		end := len(rest)
		if cut := strings.index_any(rest, "/?#"); cut >= 0 {
			end = cut
		}
		parsed.netloc = rest[:end]
		rest = rest[end:]
	}
	if hash := strings.index_byte(rest, '#'); hash >= 0 {
		parsed.fragment = rest[hash + 1:]
		rest = rest[:hash]
	}
	if mark := strings.index_byte(rest, '?'); mark >= 0 {
		parsed.query = rest[mark + 1:]
		rest = rest[:mark]
	}
	parsed.path = rest
	if url_location_scheme_uses_params(parsed.scheme) {
		// `urlparse` splits the params only for a scheme that uses them
		// (`if scheme in uses_params and ';' in url`, urllib/parse.py:397),
		// so a scheme's own ';' stays in the path.
		parsed.path, parsed.params = url_location_split_params(rest)
	}
	return parsed, true
}

// url_location_scheme_uses_params is urllib's `uses_params` (urllib/parse.py:
// 64-67): the schemes whose paths are split at a ';' into a path and its params
// — which is why `E:}l;` keeps its ';' (that scheme's paths have no params)
// while `}l;` against a base of the same scheme does not. The empty scheme is in
// the list, so a Location that names no scheme is always split.
url_location_scheme_uses_params :: proc(scheme: string) -> bool {
	URL_SCHEMES_USING_PARAMS :: []string {
		"",
		"ftp",
		"hdl",
		"prospero",
		"http",
		"imap",
		"https",
		"shttp",
		"rtsp",
		"rtsps",
		"rtspu",
		"sip",
		"sips",
		"mms",
		"sftp",
		"tel",
	}
	for candidate in URL_SCHEMES_USING_PARAMS {
		if strings.equal_fold(candidate, scheme) {
			return true
		}
	}
	return false
}

// url_location_split_params is CPython's `_splitparams` (urllib/parse.py:404-411):
// the ';' the params start at is the one after the *last* '/', or the first ';'
// of a path that has no '/' — so `a;b/c` has no params at all (its ';' is
// before the last '/') while `a;b` is the path `a` with the params `b`.
url_location_split_params :: proc(path: string) -> (head: string, params: string) {
	index := -1
	if slash := strings.last_index_byte(path, '/'); slash >= 0 {
		if semi := strings.index_byte(path[slash:], ';'); semi >= 0 {
			index = slash + semi
		}
	} else {
		index = strings.index_byte(path, ';')
	}
	if index < 0 {
		return path, ""
	}
	return path[:index], path[index + 1:]
}

// url_location_scheme_uses_netloc is urllib's `uses_netloc` (urllib/parse.py:
// 58-62 — the list CPython 3.11 carries): the schemes whose `urlunsplit` writes
// the `//` authority *even when there is no netloc*. It is what decides the
// spelling of a target that names a scheme of its own and no authority:
// `http:/echo` comes out as `http:///echo`, while `c:54-F` stays `c:54-F`. The
// comparison is folded because `urlsplit` lowercases the scheme before this
// test. The empty scheme is in CPython's list, for `urljoin`'s internal
// `urlunparse` — `urlunsplit` itself tests `scheme and scheme in uses_netloc`,
// so a target that names no scheme never writes an authority off this list.
url_location_scheme_uses_netloc :: proc(scheme: string) -> bool {
	URL_SCHEMES_USING_NETLOC :: []string {
		"",
		"ftp",
		"http",
		"gopher",
		"nntp",
		"telnet",
		"imap",
		"wais",
		"file",
		"mms",
		"https",
		"shttp",
		"snews",
		"prospero",
		"rtsp",
		"rtsps",
		"rtspu",
		"rsync",
		"svn",
		"svn+ssh",
		"sftp",
		"nfs",
		"git",
		"git+ssh",
		"ws",
		"wss",
	}
	for candidate in URL_SCHEMES_USING_NETLOC {
		if strings.equal_fold(candidate, scheme) {
			return true
		}
	}
	return false
}

// url_location_unparse_into writes the URL those components spell —
// `urlunparse`/`urlunsplit` (urllib/parse.py:525-553), which is the
// `parsed.geturl()` step of requests' redirect loop and the last step of
// `urljoin`:
//
//   - the authority is written when there is a netloc, when the scheme is one
//     that uses one (http and https are) or when the path itself starts with
//     `//`; a path that does not start with '/' gets one *inside* the
//     authority, and the test is made over the path **and its params**;
//   - the query and the fragment are written only when they are not empty,
//     which is why a `?` or a `#` with nothing behind it disappears:
//     `Location: /echo?` is the URL `/echo`.
url_location_unparse_into :: proc(buffer: ^Buffer, parsed: Url_Location) -> bool {
	// `urlunsplit`'s own test is `netloc or (scheme and scheme in uses_netloc)
	// or url[:2] == '//'`: the scheme has to be *named* for the authority its
	// list entry asks for, so a target with no scheme and no netloc is written
	// as the path it is.
	authority := parsed.netloc != "" ||
	             (parsed.scheme != "" && url_location_scheme_uses_netloc(parsed.scheme)) ||
	             strings.has_prefix(parsed.path, "//")
	if parsed.scheme != "" {
		// `urlsplit` folds the scheme with `str.lower()` and `geturl` writes
		// the folded one (urllib/parse.py:509): the scheme holds ASCII
		// characters only, so a byte-wise fold agrees.
		if !url_location_write_scheme_into(buffer, parsed.scheme) {
			return false
		}
	}
	if authority {
		if !buffer_append_string(buffer, "//") || !buffer_append_string(buffer, parsed.netloc) {
			return false
		}
		if parsed.path != "" || parsed.params != "" {
			first := parsed.path != "" ? parsed.path[0] : u8(';')
			if first != '/' && !buffer_append_byte(buffer, '/') {
				return false
			}
		}
	}
	if !buffer_append_string(buffer, parsed.path) {
		return false
	}
	if parsed.params != "" &&
	   (!buffer_append_byte(buffer, ';') || !buffer_append_string(buffer, parsed.params)) {
		return false
	}
	if parsed.query != "" &&
	   (!buffer_append_byte(buffer, '?') || !buffer_append_string(buffer, parsed.query)) {
		return false
	}
	if parsed.fragment != "" &&
	   (!buffer_append_byte(buffer, '#') || !buffer_append_string(buffer, parsed.fragment)) {
		return false
	}
	return true
}

// url_location_normalize_into writes the URL requests holds after the first two
// steps of its Location pipeline (sessions.py:224-235, inside
// `resolve_redirects`):
//
//   if url.startswith("//"):     # RFC 1808 §4, a scheme-relative reference
//       url = ":".join([to_native_string(urlparse(resp.url).scheme), url])
//   parsed = urlparse(url)
//   url = parsed.geturl()        # "normalize url case"
//
// `base` supplies the scheme for the first step and nothing else. The order of
// the two steps is load-bearing: the scheme-relative test is made on the bytes
// the header carried, *before* `urlparse` strips the C0 control and space
// characters off the front (urllib/parse.py:492-494), so `\x0c//host/x` is not
// the scheme-relative reference `//host/x` is.
//
// `geturl` is what the second step contributes, and it is not only the scheme's
// case: the authority is written for a scheme in `uses_netloc`, and a path that
// does not start with '/' gains one there — which is what makes `http:echo` the
// *root-relative* target `http:///echo`, while `c:54-F` (a scheme that uses no
// authority) stays `c:54-F`.
//
// False means an allocation failed; the buffer is then partly written.
url_location_normalize_into :: proc(buffer: ^Buffer, base: string, location: string) -> bool {
	// The two parses below are the same procedure over two different strings —
	// the Location as the header carried it and the base requests held — and a
	// URL carrying one of the three bytes `urlsplit` deletes is exactly the
	// case each of them may need a copy for, so each gets its own buffer; both
	// are empty (and allocate nothing) for every other URL, and both have to
	// outlive the unparse at the end.
	location_scratch := buffer_make(buffer.allocator)
	defer buffer_destroy(&location_scratch)
	base_scratch := buffer_make(buffer.allocator)
	defer buffer_destroy(&base_scratch)

	parsed, parsed_ok := url_location_parse(location, &location_scratch)
	if !parsed_ok {
		return false
	}
	if strings.has_prefix(location, "//") {
		base_parsed, base_ok := url_location_parse(base, &base_scratch)
		if !base_ok {
			return false
		}
		if base_parsed.scheme == "" {
			// `":".join(["", url])` is `://…`, which `urlparse` reads as a path
			// with no scheme at all; the caller always hands a prepared URL,
			// which has one, so this is unreachable.
			return url_location_unparse_into(buffer, parsed)
		}
		parsed.scheme = base_parsed.scheme
	}
	return url_location_unparse_into(buffer, parsed)
}

// url_location_resolve_into writes the URL a followed redirect's Location
// resolves to against `base` — the prepared URL of the request that answered
// (`hop.url`): requests' whole pipeline for a Location, end to end
// (sessions.py:224-243, inside `resolve_redirects`):
//
//   if url.startswith("//"):          # RFC 1808 §4, a scheme-relative reference
//       url = ":".join([urlparse(resp.url).scheme, url])
//   parsed = urlparse(url)
//   url = parsed.geturl()             # "normalize url case"
//   if not parsed.netloc:
//       url = urljoin(resp.url, requote_uri(url))
//   else:
//       url = requote_uri(url)
//
// `location` is the Location as the header carried it. The steps are not
// interchangeable — each one decides what the next sees:
//
//   * `url_location_normalize_into` is the first two (the scheme-relative step
//     on the raw bytes, then `urlparse` + `geturl`);
//   * then the requote runs over that spelled-out form (`url_requote_into`,
//     t_1f33ebdc's rule) — never over the raw bytes, because `urlsplit` strips
//     the C0 control and space characters off the front and `geturl` spells out
//     the authority and the case, so `Location: \x0c/echo` is `/echo` and not
//     `%0C/echo`, and `HTTP://host/x` is already `http://host/x` here;
//   * and the netloc of *that* parse decides between the two branches — the
//     authority's presence, not the scheme's spelling, is what makes a target
//     absolute;
//   * the join half is `url_join_reduced_path_into`'s: a root-relative target
//     replaces the base's path, a path-relative one merges onto the base's
//     directory, and both are then reduced. A target with **no path and no
//     params** is urljoin's third branch — the base's path and query are kept
//     whole and only the query is replaced (urllib/parse.py:577-583), which is
//     the query-only Location, and a target that names another scheme is
//     returned as it stands (urljoin's own first guard, urllib/parse.py:569).
//
// What comes out is the *prepared* URL: the one requests holds in
// `prepared_request.url` and the one httpie renders (`urlsplit` of it,
// models.py:141-147). The bytes on the wire are that URL's path and query
// encoded once more, by urllib3 at send time — `url_wire_url_into` builds that
// form (the caller's next step).
//
// False means an allocation failed; the buffer is then partly written and the
// caller discards it.
url_location_resolve_into :: proc(buffer: ^Buffer, base: string, location: string) -> bool {
	// The base is a URL the run already resolved and the target below is the
	// requoted form, so neither can carry one of the three bytes `urlsplit`
	// deletes — but both go through the same parse, which removes them wherever
	// they are, and both need the buffer that removal would take. Empty, so
	// neither allocates anything.
	base_scratch := buffer_make(buffer.allocator)
	defer buffer_destroy(&base_scratch)
	target_scratch := buffer_make(buffer.allocator)
	defer buffer_destroy(&target_scratch)

	base_parsed, base_ok := url_location_parse(base, &base_scratch)
	if !base_ok {
		return false
	}

	// Steps 1-3, into a scratch: the scheme-relative step, `urlparse`/`geturl`,
	// and the requote over that form.
	normalized := buffer_make(buffer.allocator, len(location) + 16)
	defer buffer_destroy(&normalized)
	if !url_location_normalize_into(&normalized, base, location) {
		return false
	}
	requoted := buffer_make(buffer.allocator, len(normalized.data[:]) + 16)
	defer buffer_destroy(&requoted)
	if !url_requote_into(&requoted, string(normalized.data[:])) {
		return false
	}
	target := string(requoted.data[:])
	parsed, parsed_ok := url_location_parse(target, &target_scratch)
	if !parsed_ok {
		return false
	}

	// Steps 4-5. The two branches that need no join: a target with an
	// authority is the URL as it stands (`requote_uri(url)`), and a target
	// that names another scheme is urljoin's own first guard
	// (`if scheme != bscheme or scheme not in uses_relative: return url`,
	// urllib/parse.py:569-570). The port speaks http and https only, both of
	// which are in `uses_relative`, so the second half of that test cannot be
	// reached here.
	if parsed.netloc != "" ||
	   (parsed.scheme != "" && !strings.equal_fold(parsed.scheme, base_parsed.scheme)) {
		return buffer_append_string(buffer, target)
	}
	if base_parsed.netloc == "" {
		// A base that is not an absolute URL has nothing to join against; the
		// caller hands the request's own prepared URL, so this is unreachable.
		return buffer_append_string(buffer, target)
	}

	if parsed.path == "" && parsed.params == "" {
		// The base's path (and params) are kept whole and only the query is
		// replaced — by the target's when it has one, by the base's when it
		// has not (`if not query: query = bquery`).
		joined := Url_Location {
			scheme   = base_parsed.scheme,
			netloc   = base_parsed.netloc,
			path     = base_parsed.path,
			params   = base_parsed.params,
			query    = parsed.query != "" ? parsed.query : base_parsed.query,
			fragment = parsed.fragment,
		}
		return url_location_unparse_into(buffer, joined)
	}

	// urljoin parses the reference with the base's scheme as the *default*
	// (`urlparse(url, bscheme, …)`, urllib/parse.py:564-567), so a target that
	// names none is resolved with the base's.
	scheme := parsed.scheme != "" ? parsed.scheme : base_parsed.scheme
	if scheme != "" && !url_location_write_scheme_into(buffer, scheme) {
		return false
	}
	if !buffer_append_string(buffer, "//") || !buffer_append_string(buffer, base_parsed.netloc) {
		return false
	}
	if !url_join_reduced_path_into(buffer, base_parsed.path, parsed.path) {
		return false
	}
	if parsed.params != "" &&
	   (!buffer_append_byte(buffer, ';') || !buffer_append_string(buffer, parsed.params)) {
		return false
	}
	if parsed.query != "" &&
	   (!buffer_append_byte(buffer, '?') || !buffer_append_string(buffer, parsed.query)) {
		return false
	}
	if parsed.fragment != "" &&
	   (!buffer_append_byte(buffer, '#') || !buffer_append_string(buffer, parsed.fragment)) {
		return false
	}
	return true
}

// url_location_write_scheme_into writes `scheme` folded to lower case and the
// ':' that ends it: `urlsplit` lowercases the scheme (urllib/parse.py:509) and
// `urlunsplit` writes the lowercased one, which is what makes `HTTP://host/x`
// come out as `http://host/x`. A scheme holds ASCII characters only
// (`url_scheme_name_ok`), so a byte-wise fold agrees with `str.lower()`.
@(private)
url_location_write_scheme_into :: proc(buffer: ^Buffer, scheme: string) -> bool {
	for i in 0 ..< len(scheme) {
		c := scheme[i]
		if c >= 'A' && c <= 'Z' {
			c = c - 'A' + 'a'
		}
		if !buffer_append_byte(buffer, c) {
			return false
		}
	}
	return buffer_append_byte(buffer, ':')
}

// Refused_Target is what httpie's model reads out of a URL requests has no
// adapter for. Nothing is sent with such a URL — `Session.get_adapter` refuses
// it before the connection is looked up — but the request *is* printed, because
// httpie prints each request before it sends it (`yield prepared_request`,
// client.py:105), and the only thing that spelled it is `urlsplit` of the URL
// requests held (models.py:137-151):
//
//   - the request line's target is that split's path and query, **as spelled**:
//     no `prepare_url` runs over this URL (requests short-circuits anything that
//     is not http/https, models.py:500-505), so nothing requotes or reduces it a
//     second time, and a path that names none is `/` (`url.path or '/'`,
//     models.py:143);
//   - `Host` is the same split's netloc minus its userinfo
//     (`url.netloc.split('@')[-1]`, models.py:150-151) — the text as written, an
//     explicit or padded port included, and **empty** rather than absent when
//     the URL spells no authority at all (`file:///etc/hostname`).
Refused_Target :: struct {
	path:  string, // borrowed from the URL; always at least "/"
	query: string, // without '?'; "" when absent
	host:  string, // the netloc without its userinfo, as spelled; "" when none
	// userinfo is the other half of that netloc — everything in front of the
	// last '@', as spelled, "" when the URL spells none. httpie derives the
	// `Authorization` header from it (`urlsplit(url).username`, whose `@` with
	// nothing in front of it is the empty credentials), so the argv form of a
	// refused URL needs it beside the split's other two pieces.
	userinfo:     string,
	has_userinfo: bool,
}

// url_refused_target applies that read to one refused target. Every field
// borrows `url` — or, for a URL that carries one of the three bytes `urlsplit`
// deletes, the copy `url_location_parse` writes into `scratch`, which is the
// caller's then and has to outlive the target. The split is
// `url_location_parse`, which is `urlsplit` (urllib/parse.py:491-520) —
// deliberately not `url_split`, whose rule is httpie's *argv* rule and refuses
// a scheme the port does not speak, which is exactly the kind of URL this
// renders. False means that copy could not be made, and nothing is written
// then; the URL requests never prepared (the argv half) is the one that can
// carry such a byte, since a resolved target has been requoted already.
url_refused_target :: proc(url: string, scratch: ^Buffer) -> (target: Refused_Target, ok: bool) {
	parsed, parsed_ok := url_location_parse(url, scratch)
	if !parsed_ok {
		return {}, false
	}
	target = Refused_Target {
		path  = parsed.path != "" ? parsed.path : "/",
		query = parsed.query,
	}
	// `rpartition('@')`: the *last* '@' is the one that separates the userinfo,
	// whatever the credentials themselves contain.
	if at := strings.last_index(parsed.netloc, "@"); at >= 0 {
		target.host = parsed.netloc[at + 1:]
		target.userinfo = parsed.netloc[:at]
		target.has_userinfo = true
	} else {
		target.host = parsed.netloc
	}
	return target, true
}

// url_unsafe_bytes_strip_into appends `text` without the three bytes CPython's
// `urlsplit` deletes before it parses anything — tab, CR and LF
// (`_UNSAFE_URL_BYTES_TO_REMOVE`, urllib/parse.py:497-500). They are removed
// from the *whole* URL, authority and path alike, so `ftp://a<TAB>b.com/x` has
// the netloc `ab.com` and `/a<TAB>b` is the path `/ab`; the URL the message
// quotes keeps them, because the removal is `urlsplit`'s and the message quotes
// the string requests held (`url_refused_target` is that split, and the argv
// URL requests never prepared is the *first* place this rule shows —
// docs/PARITY.md §3.6, §8 items 21 and 23).
//
// False means an allocation failed; the buffer is then partly written. The
// caller owns `buffer`.
url_unsafe_bytes_strip_into :: proc(buffer: ^Buffer, text: string) -> bool {
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '	' || c == '\r' || c == '\n' {
			continue
		}
		if !buffer_append_byte(buffer, c) {
			return false
		}
	}
	return true
}

// url_path_as_is_into writes the URL httpie's `--path-as-is` leaves in
// `prepared_request.url` when requests never prepared the URL: `ensure_path_as_is`
// (client.py:94-98, :377-400) parses the argv URL and the *prepared* one and
// writes the argv URL's path into the prepared one, and for a URL that was not
// prepared at all both arguments are the same string — so the result is exactly
// `urlparse(url).geturl()`: the scheme lowercased, an authority spelled out for
// a scheme in `uses_netloc` even when it is empty (`ftp:/echo` → `ftp:///echo`),
// and a path that does not start with '/' given one. The tab/CR/LF removal is
// `urlsplit`'s, so `ftp://h/a<TAB>b` becomes `ftp://h/ab` *in the URL itself*
// (docs/PARITY.md §3.6).
//
// False means an allocation failed; the buffer is then partly written.
url_path_as_is_into :: proc(buffer: ^Buffer, url: string) -> bool {
	stripped := buffer_make(buffer.allocator, len(url))
	defer buffer_destroy(&stripped)
	if !url_unsafe_bytes_strip_into(&stripped, url) {
		return false
	}
	// The bytes are out of `stripped` already, so this parse has nothing of its
	// own to remove and its buffer stays empty.
	scratch := buffer_make(buffer.allocator)
	defer buffer_destroy(&scratch)
	parsed, parsed_ok := url_location_parse(string(stripped.data[:]), &scratch)
	if !parsed_ok {
		return false
	}
	return url_location_unparse_into(buffer, parsed)
}
