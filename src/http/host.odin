package http

import "core:fmt"
import "core:mem"
import "core:strings"

import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// The URL's host. requests prepares a URL by handing the string to urllib3's
// `parse_url`, which splits the authority into a host and a port
// (`_HOST_PORT_RE`, util/url.py:70-75) and then normalizes the host
// (`_normalize_host`, util/url.py:361-422); requests then rejects a host that
// starts with `*` or `.` (`prepare_url`, models.py:526-532). The three things a
// normal host can come out as — lowercased, escape-folded, IDNA-encoded — are
// what `url_host_normalize` produces, and the ways the reference refuses one are
// `Host_Error` (urllib3's and requests' four, plus CPython's four bracket ones,
// which that function's `url_host_bracketed_netloc` raises for the authorities
// whose brackets sit in the userinfo — docs/PARITY.md §3.6, t_8a2dad4a).
//
// Everything here borrows the URL's string for its messages: the caller prints
// them before the options that own the URL are released.
// ---------------------------------------------------------------------------

// Host_Error_Kind names the failure, and with it the message httpie prints.
// Each one is an `InvalidURL` (requests wraps urllib3's `LocationParseError`),
// which httpie's `handle_generic_error` renders as `InvalidURL: <message>`
// (core.py:54-67).
Host_Error_Kind :: enum {
	None,
	// Invalid_Label is requests' own check: a host that starts with `*` or `.`
	// (`URL has an invalid label.`).
	Invalid_Label,
	// Invalid_Name is urllib3's `_idna_encode`: a non-ASCII label that
	// `idna.encode(label.lower(), strict=True, std3_rules=True)` rejects
	// (`Name '<label>' is not a valid IDNA label`).
	Invalid_Name,
	// Invalid_Character is `_normalize_host`'s first check, `[\x00-\x20\x7f]`
	// (`Host '<host>' contains invalid character '<char>'`). It is also what
	// the *authority* reports when `_HOST_PORT_RE` refused it — the same
	// message, with the host:port text in the host's place (util/url.py:525-534,
	// the pattern's own failure branch).
	Invalid_Character,
	// Invalid_Percent_Control is a `%XX` whose octet is a control character
	// (`Host '<host>' contains invalid percent-encoded control character
	// '<%XX>'`).
	Invalid_Percent_Control,
	// Invalid_Authority is a `host:port` that is neither a reg-name, an IPv4
	// address nor a bracketed IPv6 address, and a port text the pattern's own
	// port group does not accept (`'<host:port>' is not a valid host or port`).
	Invalid_Authority,
	// Invalid_Port is a port the pattern *does* accept and urllib3 then refuses,
	// `if not (0 <= port_int <= 65535): raise LocationParseError(url)`
	// (util/url.py:547-551). Its argument is the whole URL, not the host:port,
	// so the message is `Failed to parse: <the URL>`.
	Invalid_Port,
	// Invalid_No_Host is requests' own check on the host `parse_url` returned:
	// an authority with no host at all — `http:///x`, `http://@/x`,
	// `http://:80/x` — is falsy, and prepare_url refuses it before anything
	// else looks at the URL (`Invalid URL '<url>': No host supplied`,
	// models.py:521-522). It is not urllib3's, so it carries no
	// `Failed to parse:` prefix.
	Invalid_No_Host,
	// The four below are CPython's, not urllib3's: they are what
	// `_check_bracketed_netloc` and `urlsplit` raise while the reference
	// *parses the arguments* (urllib/parse.py:439-465, :510-516), so the
	// reference dies with an unhandled `ValueError` and a traceback whose
	// frames are not reproduced (§8.20) — the port prints the exception's own
	// wording, the last line of that traceback, through the same
	// `http: error:` line every other message takes.
	//
	// Invalid_IPv6_URL is `urlsplit`'s own check on the netloc: a '[' whose
	// ']' is missing, or the other way round (:512-514).
	Invalid_IPv6_URL,
	// Invalid_Bracketed_Host is `_check_bracketed_host`'s `ipaddress` refusal
	// (`'<what stands between the brackets>' does not appear to be an IPv4 or
	// IPv6 address`, :463). `text` names it — and it is the *host*, not
	// whatever the brackets hold, when the check is reached the way this card
	// measured (the `else` branch of `_check_bracketed_netloc`, :452-454).
	Invalid_Bracketed_Host,
	// Invalid_Bracketed_IPv4 is the branch under it: `ipaddress` *did* read the
	// host, and it read an IPv4 address (`An IPv4 address cannot be in
	// brackets`, :464-465).
	Invalid_Bracketed_IPv4,
	// Invalid_IPvFuture is the first branch of `_check_bracketed_host`: a host
	// starting with 'v' that is not `\Av[a-fA-F0-9]+\..+\Z`
	// (`IPvFuture address is invalid`, :459-461).
	Invalid_IPvFuture,
}

// Host_Error carries the parts of that message. `text` is the string the
// message names — the host for `_normalize_host`'s two messages, the host:port
// `_HOST_PORT_RE` was matched against for `Invalid_Authority`, and the URL for
// the two whole-URL ones — and `character` the offending character of the
// `contains invalid …` pair. Everything but `owned` borrows the URL's string,
// which outlives the message: the caller prints it before the options that own
// the URL are released.
//
// `url_prefix` is the one thing that is *not* a slice of the argv URL: httpie's
// own `_process_url` prepends the scheme (`http://`) to a URL that names none,
// and `localhost` (and the port back) to the curl-style shorthand, and the
// reference's two whole-URL messages quote the string it built. It is that
// literal, or "" when the URL names its scheme already.
//
// `owned` marks the one copy: `.Invalid_Name`'s label, which is a slice of the
// *folded* host and does not outlive the call (`host_error_destroy` releases
// it).
Host_Error :: struct {
	kind:       Host_Error_Kind,
	text:       string,
	character:  string,
	url_prefix: string,
	owned:      bool,
}

// host_error_destroy releases the copy `url_host_normalize` made for the error
// — the quoted label of an `.Invalid_Name` and nothing else. The caller calls
// it once it has rendered the message; the error is not usable afterwards.
host_error_destroy :: proc(err: ^Host_Error, allocator: mem.Allocator) {
	if err.owned && err.text != "" {
		delete(err.text, allocator)
	}
	err^ = {}
}

// host_error_message renders the exception the reference prints, through
// httpie's own convention (`f'{type(e).__name__}: {msg}'`, core.py:65). The
// message urllib3 raised is wrapped once more: its `LocationParseError` prefixes
// every argument with `Failed to parse: ` (exceptions.py:194-203) and requests
// re-raises it as `InvalidURL(*e.args)` (models.py:509-511), so the parts below
// are what reaches the log. requests' own two messages (`URL has an invalid
// label.`, `Invalid URL '<url>': No host supplied`) carry no such prefix. The
// caller owns the result.
host_error_message :: proc(err: ^Host_Error, allocator: mem.Allocator) -> string {
	switch err.kind {
	case .None:
		return strings.clone("", allocator) or_else ""
	case .Invalid_Label:
		return strings.clone("InvalidURL: URL has an invalid label.", allocator) or_else ""
	case .Invalid_Name:
		return fmt.aprintf(
			"InvalidURL: Failed to parse: Name '%s' is not a valid IDNA label",
			err.text,
			allocator = allocator,
		)
	case .Invalid_Percent_Control:
		{
			text := python_str_repr(err.text, allocator)
			defer delete(text, allocator)
			octet := python_str_repr(err.character, allocator)
			defer delete(octet, allocator)
			return fmt.aprintf(
				"InvalidURL: Failed to parse: Host %s contains invalid percent-encoded control character %s",
				text,
				octet,
				allocator = allocator,
			)
		}
	case .Invalid_Character:
		{
			text := python_str_repr(err.text, allocator)
			defer delete(text, allocator)
			character := python_str_repr(err.character, allocator)
			defer delete(character, allocator)
			return fmt.aprintf(
				"InvalidURL: Failed to parse: Host %s contains invalid character %s",
				text,
				character,
				allocator = allocator,
			)
		}
	case .Invalid_Authority:
		{
			text := python_str_repr(err.text, allocator)
			defer delete(text, allocator)
			return fmt.aprintf(
				"InvalidURL: Failed to parse: %s is not a valid host or port",
				text,
				allocator = allocator,
			)
		}
	case .Invalid_Port:
		{
			// `LocationParseError(url)`: the argument is a `str`, so the
			// message carries it as it is — no `repr`, no quotes
			// (util/url.py:547-551).
			url := host_error_url(err, allocator)
			defer delete(url, allocator)
			return fmt.aprintf(
				"InvalidURL: Failed to parse: %s",
				url,
				allocator = allocator,
			)
		}
	case .Invalid_No_Host:
		{
			url := host_error_url(err, allocator)
			defer delete(url, allocator)
			text := python_str_repr(url, allocator)
			defer delete(text, allocator)
			return fmt.aprintf(
				"InvalidURL: Invalid URL %s: No host supplied",
				text,
				allocator = allocator,
			)
		}
	case .Invalid_IPv6_URL:
		// The four CPython cases (see Host_Error_Kind): an exception the
		// reference does not catch, so the line is the exception's own wording
		// — `f'{type(e).__name__}: {msg}'`, the traceback's last line, with the
		// frames left out (§8.20) — and carries no `InvalidURL:` of httpie's.
		return strings.clone("ValueError: Invalid IPv6 URL", allocator) or_else ""
	case .Invalid_Bracketed_Host:
		{
			// `ipaddress.ip_address`'s own message quotes what it was handed.
			text := python_str_repr(err.text, allocator)
			defer delete(text, allocator)
			return fmt.aprintf(
				"ValueError: %s does not appear to be an IPv4 or IPv6 address",
				text,
				allocator = allocator,
			)
		}
	case .Invalid_Bracketed_IPv4:
		return strings.clone("ValueError: An IPv4 address cannot be in brackets", allocator) or_else ""
	case .Invalid_IPvFuture:
		return strings.clone("ValueError: IPvFuture address is invalid", allocator) or_else ""
	}
	return strings.clone("", allocator) or_else ""
}

// host_error_url is the URL the two whole-URL messages name: the slice the
// split read, with the literal httpie's `_process_url` prepends in front of it
// (`http://`, or `http://localhost:` for the curl-style shorthand). The caller
// owns the result.
@(private)
host_error_url :: proc(err: ^Host_Error, allocator: mem.Allocator) -> string {
	if err.url_prefix == "" {
		// M5 report: this clones the message the caller is already building, so
		// the copy's own failure only means the report could not be allocated —
		// the same shape as the parser's `clone("not enough memory")` idiom.
		return strings.clone(err.text, allocator) or_else ""
	}
	return fmt.aprintf("%s%s", err.url_prefix, err.text, allocator = allocator)
}

// url_host_normalize is the authority half of requests' `prepare_url`: it
// returns the host the reference would put in the Host header and in the URL,
// owned by `allocator` — or `.Invalid_URL`, with `err` filled in when it is not
// nil, and the port the authority spells in `port` (untouched when it spells
// none). `host_port` is that authority, in the two pieces httpie's own URL rule
// builds it from (`Split_Text`), `userinfo` the credentials in front of it —
// the two halves of the *netloc*, which is what CPython's own bracket check
// reads — and `url` is the URL `_process_url` handed requests, which the two
// messages that quote a whole URL name.
//
// The order is urllib3's and requests', with CPython's own bracket check run
// between the first and the second step (see `url_host_bracketed_netloc` for
// why it sits there and why nothing else of it is modelled):
//
//  1. the authority must match `_HOST_PORT_RE` — a reg-name, an IPv4 address or
//     a bracketed IPv6 address, then an optional port text — before anything
//     else looks at it (util/url.py:525-534). A failure is `[\x00-\x20\x7f]`
//     when the string has one, the "not a valid host or port" shape otherwise,
//     and both name the whole authority;
//  1b. a netloc whose brackets sit in the *userinfo* is refused by CPython
//     before urllib3's rule is ever reached — the one place the two sides
//     disagreed about the outcome (t_8a2dad4a);
//  2. the port that pattern read must be in range: `if not (0 <= port_int <=
//     65535): raise LocationParseError(url)` (util/url.py:542-547), whose
//     argument is the whole URL;
//  3. `_normalize_host` (util/url.py:361-422): `[\x00-\x20\x7f]` anywhere in
//     the host, the bracketed-IPv6 lowercasing, the IPv4 guard-rail, then the
//     `%XX` escapes and the IDNA step per label;
//  4. requests refuses a URL whose host is empty — `http:///x`, `http://@/x`,
//     `http://:80/x` — after its scheme check (models.py:519-520);
//  5. requests then refuses a host that starts with `*` or `.`
//     (models.py:526-532).
//
// `requote_fallback` is the other property of the URL this rule decides: requests
// hands the *whole* prepared URL to `requote_uri` (models.py:560), and when that
// call takes its `InvalidURL` branch every '%' of the string — the path's and the
// query's included — becomes a literal `%25` and no escape is unquoted. Only the
// netloc can make it take that branch (urllib3's `_encode_invalid_chars` leaves
// every component it touches with each '%' followed by two hex digits), and only
// the zone-id branch below writes a '%' that `unquote_unreserved` cannot read as
// an escape: this proc sets the flag for that host and leaves it false for every
// other one (kanban t_75b15cf5, docs/PARITY.md §3.6).
url_host_normalize :: proc(
	host_port: Split_Text,
	userinfo: Split_Text,
	url: Split_Text,
	allocator: mem.Allocator,
	err: ^Host_Error = nil,
	port: ^int = nil,
	requote_fallback: ^bool = nil,
) -> (string, Error) {
	if requote_fallback != nil {
		requote_fallback^ = false
	}
	// The authority as the pattern sees it. Only the curl-style shorthand makes
	// the splitter prepend a literal, and then this join is a copy the error can
	// take over when the render outlives the call (`Host_Error.owned`).
	authority := host_port.text
	joined := ""
	if host_port.prefix != "" {
		joined = split_text_join(host_port, allocator)
		if joined == "" {
			return "", .Out_Of_Memory
		}
		authority = joined
	}
	authority_taken := false
	defer if joined != "" && !authority_taken {
		delete(joined, allocator)
	}

	host, port_text, matched := url_host_port_match(authority)
	if !matched {
		// The authority never matched `_HOST_PORT_RE`, so urllib3 never reached
		// `_normalize_host`: the failure it reports is `[\x00-\x20\x7f]` when
		// the string has one, its shape otherwise (util/url.py:525-534).
		if index, found := url_host_invalid_char(authority); found && err != nil {
			err^ = {
				kind      = .Invalid_Character,
				text      = authority,
				character = authority[index:index + 1],
				owned     = joined != "",
			}
			authority_taken = joined != ""
		} else if err != nil {
			err^ = {kind = .Invalid_Authority, text = authority, owned = joined != ""}
			authority_taken = joined != ""
		}
		return "", .Invalid_URL
	}

	// CPython's own bracket check, on the shapes urllib3's pattern is happy
	// with: the reference runs it while the *arguments are parsed*
	// (`_process_auth`, cli/argparser.py:287) and urllib3's rule later, so the
	// two orders differ; running it here — after the match — is what keeps the
	// message the pattern's for every shape the pattern itself refuses
	// (t_17caa1d7) while the shapes it accepts are decided by the check.
	if bracket_err := url_host_bracketed_netloc(userinfo, authority, err); bracket_err != .None {
		return "", bracket_err
	}

	if port_text != "" {
		value, ok := url_host_port_value(port_text)
		if !ok {
			// Unreachable: the pattern only matches a port text this reads.
			return "", .Invalid_URL
		}
		if value > 65535 {
			// `LocationParseError(url)` — the whole URL, not the host:port
			// (util/url.py:542-547).
			if err != nil {
				err^ = {kind = .Invalid_Port, text = url.text, url_prefix = url.prefix}
			}
			return "", .Invalid_URL
		}
		if port != nil {
			port^ = value
		}
	}

	// The host the rest of the rule reads is a slice of the authority, which for
	// the shorthand is the join above: copy it once, so a message that names it
	// (or one of its labels) can outlive the call — the error takes the copy
	// when it does.
	host_owned := false
	host_taken := false
	if joined != "" {
		// The copy has a channel here: an allocation that fails is reported
		// rather than read as an empty host (http/owned.odin, `clone_or_oom`).
		host_copy, ok := clone_or_oom(host, allocator)
		if !ok {
			return "", .Out_Of_Memory
		}
		host = host_copy
		host_owned = true
	}
	defer if host_owned && !host_taken {
		delete(host, allocator)
	}

	if index, found := url_host_invalid_char(host); found {
		// `_normalize_host`'s own invalid-character message, which names the
		// *host* — where the pattern's failure above names the whole authority
		// (util/url.py:362-368).
		if err != nil {
			err^ = {
				kind      = .Invalid_Character,
				text      = host,
				character = host[index:index + 1],
				owned     = host_owned,
			}
			host_taken = host_owned
		}
		return "", .Invalid_URL
	}

	out := buffer_make(allocator, len(host) + 8)
	if strings.has_prefix(host, "[") {
		// A bracketed IPv6 host. `_normalize_host` lowercases it, and the RFC
		// 6874 zone-id spelling gets a branch of its own (util/url.py:369-390).
		percent := strings.index_byte(host, '%')
		if percent < 0 {
			// No zone id, so this is the `host.lower()` of that branch's last
			// line — and nothing follows it for requests to change: the bytes
			// are the brackets, the address's colons and its own digits and
			// letters, every one of them in requote's safe set below.
			if !url_host_ascii_lower_into(&out, host) {
				buffer_destroy(&out)
				return "", .Out_Of_Memory
			}
			return string(buffer_owned(&out)), .None
		}

		// The zone-id branch. The separator is `%25` — the RFC 6874 spelling —
		// or a bare `%`, and `_normalize_host` writes it back as *one* '%' in
		// front of the zone: `zone_id.startswith("%25") and zone_id != "%25"`
		// drops its three bytes, every other spelling drops its one
		// (util/url.py:378-384). The address in front of the separator is
		// lowercased (`host[:start].lower()`).
		//
		// The rest of the reference's step — the zone's own escapes,
		// uppercased by `_normalize_zone_id_percent_encoding` and then
		// percent-encoded by `_encode_invalid_chars(zone_id,
		// _UNRESERVED_CHARS)` — cannot see the zone that reaches this branch,
		// so it is written as it stands: the pattern's zone id is unreserved
		// characters and `%XX` escapes (`url_host_is_zone_id`), and a *second*
		// '%' in it, the only thing either step could act on, is refused by
		// CPython's `urlsplit` before urllib3 is ever reached (`_split_scope_id`
		// rejects a scope id carrying a '%', urllib/parse.py) — that is
		// t_17caa1d7's card, whose rows the probe still measures as DIFF.
		close := len(host) - 1 // the ']' url_host_port_match kept
		body := host[percent + 1:close]
		if len(body) > 2 && strings.has_prefix(body, "25") {
			body = body[2:]
		}
		if !url_host_ascii_lower_into(&out, host[:percent]) ||
		   !buffer_append_byte(&out, '%') ||
		   !buffer_append_string(&out, body) ||
		   !buffer_append_string(&out, host[close:]) {
			buffer_destroy(&out)
			return "", .Out_Of_Memory
		}

		// Then requests' `requote_uri`, which the prepared URL goes through
		// whole — netloc included (models.py:534-560). The separator's '%'
		// starts no escape for `unquote_unreserved`: the two characters
		// behind it are a zone's letters, so `int(h, 16)` raises, and the
		// except-branch quotes the netloc with '%' out of the safe set —
		// which is the `%25` on the wire. A separator whose two characters
		// *are* hexadecimal is read as the escape they spell instead, and an
		// unreserved octet is unquoted again (`[fe80::1%41]` → `[fe80::1A]`).
		//
		// The raise is not the netloc's business alone: it decides the branch
		// for the whole URL requests requotes, so the decision is made once,
		// here, and handed to the caller for the path and the query it also
		// carries (models.py:560; `http.Request.requote_fallback`).
		host_fallback := url_requote_is_invalid(string(out.data[:]))
		if requote_fallback != nil {
			requote_fallback^ = host_fallback
		}
		requoted := buffer_make(allocator, len(out.data) + 4)
		defer buffer_destroy(&requoted)
		if !url_requote_decided_into(&requoted, string(out.data[:]), host_fallback) {
			buffer_destroy(&out)
			return "", .Out_Of_Memory
		}
		buffer_destroy(&out)
		return string(buffer_owned(&requoted)), .None
	}
	if url_host_is_ipv4(host) {
		if !buffer_append_string(&out, host) {
			buffer_destroy(&out)
			return "", .Out_Of_Memory
		}
		return string(buffer_owned(&out)), .None
	}

	// The escapes are folded first. The labels are read from the folded host and
	// written to a second buffer, so an append that grows one never moves the
	// bytes the other is reading.
	folded := buffer_make(allocator, len(host))
	defer buffer_destroy(&folded)
	if strings.index_byte(host, '%') >= 0 {
		if url_host_fold_escapes_into(&folded, host, err, host_owned) != .None {
			buffer_destroy(&out)
			host_taken = host_owned && err != nil
			return "", .Invalid_URL
		}
	} else if !buffer_append_string(&folded, host) {
		buffer_destroy(&out)
		return "", .Out_Of_Memory
	}
	if label_err := url_host_labels_into(&out, string(folded.data[:]), allocator, err); label_err != .None {
		buffer_destroy(&out)
		return "", label_err
	}

	normalized := string(buffer_owned(&out))
	if normalized == "" {
		// requests' own check, after urllib3's port range and before its
		// invalid-label one: an authority that spells no host at all
		// (models.py:519-520).
		if err != nil {
			err^ = {kind = .Invalid_No_Host, text = url.text, url_prefix = url.prefix}
		}
		delete(normalized, allocator)
		return "", .Invalid_URL
	}
	if strings.has_prefix(normalized, "*") || strings.has_prefix(normalized, ".") {
		if err != nil {
			err^ = {kind = .Invalid_Label}
		}
		delete(normalized, allocator)
		return "", .Invalid_URL
	}
	return normalized, .None
}

// url_host_normalize_flat is `_normalize_host`'s **other** branch — the one a
// scheme urllib3 does not normalize takes (util/url.py:361-397):
//
//   - everything up to `if scheme in _NORMALIZABLE_SCHEMES:` is the same work
//     the rule above does: the pattern's authority read (`_HOST_PORT_RE`, whose
//     failures are `Host … contains invalid character …` and `… is not a valid
//     host or port`), the port range, CPython's bracket check and
//     `_normalize_host`'s own invalid-character test;
//   - and then the host comes back **as it was written**: no lowercasing, no
//     per-label IDNA, no IPv6 rewriting. `httpx://EXAMPLE.com:0009/echo` prints
//     `Host: EXAMPLE.com:9` — the port folded by `int()`, the case untouched
//     (requests/models.py:533-538, docs/PARITY.md §3.6, §8 item 21).
//
// What requests applies *after* urllib3 is not about the scheme and still runs
// (models.py:519-532): an empty host is `Invalid URL '<url>': No host supplied`,
// a host that is not ASCII is IDNA-encoded whole (`_get_idna_encoded_host`,
// `idna.encode(host, uts46=True)`, whose failure requests reports as its own
// `URL has an invalid label.`), and an ASCII host that starts with `*` or `.`
// is the same message.
//
// The non-ASCII branch is the per-label rule of the one above: `idna.encode`
// over the whole host and `_idna_encode` per label agree on every host the
// pattern accepts (the IDNA mapping is applied to each label alike), and the
// port already carries that rule — with its `Host … is not a valid IDNA label`
// wording kept for a label `idna` rejects, which is the message the *reference*
// prints only when the failure comes out of urllib3's own branch.
//
// `requote_fallback` is the whole URL's `requote_uri` decision, which the caller
// makes once (`http.Request.requote_fallback`, models.py:560): a host urllib3
// left alone is a host requests still requotes, so `httpx://h%zz/` is
// `httpx://h%25zz/` — and with no fallback the escapes of an unreserved octet go
// back to being that character (`httpx://h%41/` → `httpx://hA/`), while the rest
// of the host is quoted with `quote`'s safe set.
//
// The caller owns the result.
url_host_normalize_flat :: proc(
	host_port: Split_Text,
	userinfo: Split_Text,
	url: Split_Text,
	allocator: mem.Allocator,
	err: ^Host_Error = nil,
	port: ^int = nil,
	requote_fallback: bool = false,
) -> (string, Error) {
	authority := host_port.text
	joined := ""
	if host_port.prefix != "" {
		joined = split_text_join(host_port, allocator)
		if joined == "" {
			return "", .Out_Of_Memory
		}
		authority = joined
	}
	authority_taken := false
	defer if joined != "" && !authority_taken {
		delete(joined, allocator)
	}

	host, port_text, matched := url_host_port_match(authority)
	if !matched {
		if index, found := url_host_invalid_char(authority); found && err != nil {
			err^ = {
				kind      = .Invalid_Character,
				text      = authority,
				character = authority[index:index + 1],
				owned     = joined != "",
			}
			authority_taken = joined != ""
		} else if err != nil {
			err^ = {kind = .Invalid_Authority, text = authority, owned = joined != ""}
			authority_taken = joined != ""
		}
		return "", .Invalid_URL
	}
	if bracket_err := url_host_bracketed_netloc(userinfo, authority, err); bracket_err != .None {
		return "", bracket_err
	}
	if port_text != "" {
		value, ok := url_host_port_value(port_text)
		if !ok {
			return "", .Invalid_URL
		}
		if value > 65535 {
			if err != nil {
				err^ = {kind = .Invalid_Port, text = url.text, url_prefix = url.prefix}
			}
			return "", .Invalid_URL
		}
		if port != nil {
			port^ = value
		}
	}
	// The host the rest of the rule reads is a slice of the authority, and for
	// the shorthand that authority is the join above: copy it once, the way the
	// rule above does, so what the caller is handed never points into a string
	// this call frees.
	host_owned := false
	host_taken := false
	if joined != "" {
		// As above: a copy that cannot be made is a reported failure, not an
		// empty host.
		host_copy, ok := clone_or_oom(host, allocator)
		if !ok {
			return "", .Out_Of_Memory
		}
		host = host_copy
		host_owned = true
	}
	defer if host_owned && !host_taken {
		delete(host, allocator)
	}

	if index, found := url_host_invalid_char(host); found {
		if err != nil {
			err^ = {
				kind      = .Invalid_Character,
				text      = host,
				character = host[index:index + 1],
				owned     = host_owned,
			}
			host_taken = host_owned
		}
		return "", .Invalid_URL
	}
	if host == "" {
		if err != nil {
			err^ = {kind = .Invalid_No_Host, text = url.text, url_prefix = url.prefix}
		}
		return "", .Invalid_URL
	}

	// requests' own step, which does not depend on the scheme at all: a host
	// that is ASCII and does not start with `*` or '.' is the host — returned
	// as written, because urllib3 left it that way — and a host that is not
	// ASCII goes through `_get_idna_encoded_host` (`idna.encode(host,
	// uts46=True)`, models.py:519-532). A bracketed host is ASCII and starts
	// with '[', so it takes the first branch.
	out := buffer_make(allocator, len(host) + 8)
	defer buffer_destroy(&out)
	if url_host_is_ascii(host) {
		if strings.has_prefix(host, "*") || strings.has_prefix(host, ".") {
			if err != nil {
				err^ = {kind = .Invalid_Label}
			}
			return "", .Invalid_URL
		}
		if !url_requote_decided_into(&out, host, requote_fallback) {
			return "", .Out_Of_Memory
		}
		return string(buffer_owned(&out)), .None
	}
	if label_err := url_host_labels_into(&out, host, allocator, err); label_err != .None {
		// requests' own step reports *every* IDNA failure as its own message,
		// where urllib3's per-label rule reports `Name '…' is not a valid IDNA
		// label` (models.py:526-530): `httpx://h\xff/` ends in `InvalidURL: URL
		// has an invalid label.`, which is what the `.Invalid_Label` kind
		// renders. The per-label rule's copy of the label is released first.
		if err != nil {
			if err.owned {
				delete(err.text, allocator)
			}
			err^ = {kind = .Invalid_Label}
		}
		return "", label_err
	}
	return string(buffer_owned(&out)), .None
}

// url_host_labels_into normalizes one label at a time, the way `_idna_encode`
// does (`host.split(".")`, then a join with '.'), and writes the result.
@(private)
url_host_labels_into :: proc(
	out: ^Buffer,
	host: string,
	allocator: mem.Allocator,
	err: ^Host_Error,
) -> Error {
	start := 0
	for index := 0; index <= len(host); index += 1 {
		if index < len(host) && host[index] != '.' {
			continue
		}
		label := host[start:index]
		if url_host_is_ascii(label) {
			// An ASCII label never reaches idna: `_idna_encode` only calls it
			// for a label that is not ASCII (util/url.py:433-437).
			if !url_host_ascii_label_into(out, label) {
				return .Out_Of_Memory
			}
		} else {
			lowered := buffer_make(allocator, len(label))
			defer buffer_destroy(&lowered)
			previous := rune(0)
			for byte_index := 0; byte_index < len(label); {
				code, width := utf8.decode_rune_in_string(label[byte_index:])
				if width <= 0 {
					// A byte that is not UTF-8 is the lone surrogate CPython's
					// surrogateescape made of it — DISALLOWED, so the label
					// fails exactly as any other disallowed code point does.
					if err != nil {
						err^ = {kind = .Invalid_Name, text = label}
					}
					return .Invalid_URL
				}
				next := rune(0)
				if byte_index + width < len(label) {
					next, _ = utf8.decode_rune_in_string(label[byte_index + width:])
				}
				if !url_host_lower_into(&lowered, code, previous, next) {
					return .Out_Of_Memory
				}
				previous = code
				byte_index += width
			}
			// The message quotes the label as it came in; the encoding runs on
			// the lowercased form (util/url.py:433-446).
			label_err := url_host_idna_label_into(out, string(lowered.data[:]))
			if label_err != .None {
				if label_err == .Invalid_URL && err != nil {
					// The label is a slice of the *folded* host, which does not
					// outlive this call, and the message outlives it by a
					// render: the copy is what keeps the quoted bytes alive
					// (`host_error_destroy` releases it). A copy that cannot be
					// made is reported rather than quoted as nothing.
					text_copy, ok := clone_or_oom(label, allocator)
					if !ok {
						return .Out_Of_Memory
					}
					err^ = {
						kind  = .Invalid_Name,
						text  = text_copy,
						owned = true,
					}
				}
				return label_err
			}
		}
		if index < len(host) {
			if !buffer_append_byte(out, '.') {
				return .Out_Of_Memory
			}
		}
		start = index + 1
	}
	return .None
}

// url_host_port_match is the `_HOST_PORT_RE.fullmatch` of urllib3's `parse_url`
// (util/url.py:70-75, matched at util/url.py:525-534): a reg-name, an IPv4
// address or a bracketed IPv6 address, then an optional port text. It returns
// the two groups the pattern would hold — the host and the port text — or
// `false`, which is where the pattern's two `LocationParseError`s come from and
// the only place either is built.
//
// The alternatives cannot disagree about where the host ends: neither a reg-name
// nor an IPv4 address holds a ':', and a bracketed address holds both of its
// brackets, so the host is everything before the first colon outside them. The
// pattern's IPv4 alternative (`_IPV4_PAT`, util/url.py:30) is the one part of it
// not carried here — every string it matches is digits and '.'s, which the
// reg-name alternative already accepts, so it cannot change the outcome. The
// IPv4 *shape* matters later, in `_normalize_host` (util/url.py:391-392).
@(private)
url_host_port_match :: proc(host_port: string) -> (host: string, port_text: string, ok: bool) {
	if strings.has_prefix(host_port, "[") {
		close := strings.index(host_port, "]")
		if close < 0 {
			return "", "", false
		}
		host = host_port[:close + 1]
		if !url_host_is_ipv6_addr_z(host) {
			return "", "", false
		}
		rest := host_port[close + 1:]
		if rest == "" {
			return host, "", true
		}
		if !strings.has_prefix(rest, ":") {
			return "", "", false
		}
		port_text = rest[1:]
		_, valid := url_host_port_value(port_text)
		return host, port_text, valid
	}

	host = host_port
	if colon := strings.index(host_port, ":"); colon >= 0 {
		host = host_port[:colon]
		port_text = host_port[colon + 1:]
		if strings.index(port_text, ":") >= 0 {
			// A second colon is a string no alternative of the pattern holds.
			return "", "", false
		}
	}
	if !url_host_is_reg_name(host) {
		return "", "", false
	}
	_, valid := url_host_port_value(port_text)
	return host, port_text, valid
}

// url_host_bracketed_netloc is CPython's `_check_bracketed_netloc`
// (urllib/parse.py:439-454) and the two lines of `urlsplit` that guard it
// (:512-516), modelled for the one case where they change the *outcome*: a
// netloc whose brackets sit in the userinfo. `userinfo` and `authority` are the
// netloc httpie's URL rule built, split where that rule splits it, and the
// function is called once `_HOST_PORT_RE` is happy with the authority — so
// every refusal here is one the reference reaches and the port's own rule
// would not (t_8a2dad4a).
//
// CPython partitions the userinfo off *first* — `netloc.rpartition('@')[2]`,
// :442 — and only then asks whether what is left holds a '['. When the netloc's
// brackets sit in the userinfo, `have_open_br` is therefore false and the
// `else` branch (:452-453) hands the *host* to `_check_bracketed_host`, which
// demands an IP literal (:458-465): a host that is not one dies with
// `ValueError: '<host>' does not appear to be an IPv4 or IPv6 address`, an IPv4
// address dies with `ValueError: An IPv4 address cannot be in brackets`, and a
// host starting with 'v' — the IPvFuture branch — either matches
// `\Av[a-fA-F0-9]+\..+\Z` and is *accepted* (`v1.x` is a valid IPvFuture
// address to CPython) or dies with `ValueError: IPvFuture address is invalid`.
// The reference dies with an unhandled `ValueError` and a traceback; the port
// refuses with the exception's own wording and no frames (§8.20), and the
// `url-host-bracket-cpython-userinfo-*` scenarios pin the half both sides own.
//
// Two halves of the check are deliberately *not* here:
//
//   - the `have_open_br` branch (:444-451) — the brackets are the host's. The
//     pattern's bracketed alternative has already read what is between them
//     (`url_host_is_ipv6_addr_z`), and every address it accepts is one
//     `ipaddress` reads — so the branch can only refuse what the rule refused
//     already, and running it here would only take the message away from the
//     rule (which is t_17caa1d7's decision: the port's line is the pattern's
//     wherever the pattern itself refuses). The 520-authority cross product
//     measures no row the other way (build/url-host-bracket-shapes.txt);
//   - `_check_bracketed_host`'s `ipaddress` grammar beyond the two questions
//     the `else` branch can ask. The hostname that branch partitions off
//     (`hostname_and_port.partition(':')`, :453) holds no ':' of its own, so it
//     can never be an IPv6 literal, and only the IPvFuture branch above and the
//     "is it an IPv4 address" question are left — the whole dotted-quad
//     grammar of `IPv4Address` is `url_host_is_ipaddress_ipv4` below.
//
// A URL's *argv* userinfo is what reaches this function, and a bracket in it is
// what makes the reference die, so the `text` the error carries is a slice of
// argv's own string — the same borrow every other `Host_Error` makes, and it
// outlives the render. (The literal httpie's rule may prepend to a userinfo is
// the curl-style shorthand's `localhost` / `localhost:`, and it holds no
// bracket.) The check is never run over a redirect hop: the reference calls
// `urlsplit` on the *arguments'* URL alone.
@(private)
url_host_bracketed_netloc :: proc(userinfo: Split_Text, authority: string, err: ^Host_Error) -> Error {
	open := strings.index_byte(userinfo.prefix, '[') >= 0 ||
		strings.index_byte(userinfo.text, '[') >= 0 ||
		strings.index_byte(authority, '[') >= 0
	close := strings.index_byte(userinfo.prefix, ']') >= 0 ||
		strings.index_byte(userinfo.text, ']') >= 0 ||
		strings.index_byte(authority, ']') >= 0
	if open != close {
		// `urlsplit` itself: a `[` with no `]` or the other way round, over the
		// whole netloc (`Invalid IPv6 URL`, :512-514). The authority is what
		// the pattern just accepted, so the half that is missing is the
		// userinfo's.
		if err != nil {
			err^ = {kind = .Invalid_IPv6_URL}
		}
		return .Invalid_URL
	}
	if !open {
		return .None
	}
	if strings.index_byte(authority, '[') >= 0 {
		// `have_open_br`: the brackets are the host's, which is the pattern's
		// business (see above).
		return .None
	}

	hostname := authority
	if colon := strings.index_byte(authority, ':'); colon >= 0 {
		hostname = authority[:colon]
	}
	if strings.has_prefix(hostname, "v") {
		if url_host_is_ipvfuture(hostname) {
			return .None
		}
		if err != nil {
			err^ = {kind = .Invalid_IPvFuture}
		}
		return .Invalid_URL
	}
	if url_host_is_ipaddress_ipv4(hostname) {
		if err != nil {
			err^ = {kind = .Invalid_Bracketed_IPv4}
		}
		return .Invalid_URL
	}
	if err != nil {
		err^ = {kind = .Invalid_Bracketed_Host, text = hostname}
	}
	return .Invalid_URL
}

// url_host_is_ipvfuture is `_check_bracketed_host`'s first branch: CPython's
// `re.match(r"\Av[a-fA-F0-9]+\..+\Z", hostname)` (urllib/parse.py:460) — a 'v',
// one or more hex digits, a '.', then at least one character that is not a
// newline (the pattern's `.` is the default one and `\Z` ends the string). A
// host this accepts is left alone wherever the check would otherwise refuse it,
// which is why `u[x]@v1.x` and `u[x]@v1.example.org` are accepted on both sides
// while `u[x]@v.x` is not.
@(private)
url_host_is_ipvfuture :: proc(hostname: string) -> bool {
	index := 1 // the 'v'
	digits := index
	for index < len(hostname) && url_is_hex_digit(hostname[index]) {
		index += 1
	}
	if index == digits || index >= len(hostname) || hostname[index] != '.' {
		return false
	}
	index += 1 // the '.'
	if index >= len(hostname) {
		return false
	}
	return strings.index_byte(hostname[index:], '\n') < 0
}

// url_host_is_ipaddress_ipv4 is `ipaddress.IPv4Address`: exactly four
// dot-separated decimal groups, each one to three digits with no leading zero
// and each at most 255 (`IPv4Address._ip_int_from_string` and `_parse_octet`,
// ipaddress.py:1152-1189). It is `_check_bracketed_host`'s second question —
// "did `ipaddress` read this as an IPv4 address" — and it is *not*
// `url_host_is_ipv4` above, which is urllib3's looser `_IPV4_RE`: `010.1.1.1`
// and `0x7f.1` match that one, and neither is an address `ipaddress` reads, so
// the reference refuses them with the "does not appear" message instead of
// "An IPv4 address cannot be in brackets".
@(private)
url_host_is_ipaddress_ipv4 :: proc(hostname: string) -> bool {
	groups := 0
	index := 0
	for {
		if index >= len(hostname) {
			return false // an empty group
		}
		start := index
		for index < len(hostname) && hostname[index] != '.' {
			if hostname[index] < '0' || hostname[index] > '9' {
				return false
			}
			index += 1
		}
		group := hostname[start:index]
		if len(group) > 3 || (len(group) > 1 && group[0] == '0') {
			return false
		}
		value := 0
		for digit in group {
			value = value * 10 + int(digit - '0')
		}
		if value > 255 {
			return false
		}
		groups += 1
		if index >= len(hostname) {
			break
		}
		index += 1 // the '.'
	}
	return groups == 4
}

// url_host_is_reg_name is the pattern's first alternative, urllib3's
// `_REG_NAME_PAT` (`(?:[^\[\]%:/?#]|%[a-fA-F0-9]{2})*`, util/url.py:59): a run
// of anything but the characters the other alternatives and the delimiters own,
// with `%XX` standing for one character each and a '%' that starts no escape
// ending the match.
@(private)
url_host_is_reg_name :: proc(text: string) -> bool {
	for index := 0; index < len(text); index += 1 {
		switch text[index] {
		case '[', ']', ':', '/', '?', '#':
			return false
		case '%':
			if index + 2 >= len(text) ||
			   !url_is_hex_digit(text[index + 1]) || !url_is_hex_digit(text[index + 2]) {
				return false
			}
			index += 2
		}
	}
	return true
}

// url_host_port_value is the pattern's second group —
// `(?::0*?(|0|[1-9][0-9]{0,4}))?` read from the end of the colon — as the value
// `int(port)` would then see (util/url.py:534-547). The lazy `0*?` swallows the
// leading zeros, so what is left must be five digits at most: `:0000080` is 80,
// `:0000000001` is 1 and `:123456` is no port text at all. An empty text is the
// `:` the pattern reads as no port (`if port == "": port = None`,
// util/url.py:537-538) and comes back as 0.
@(private)
url_host_port_value :: proc(port_text: string) -> (value: int, ok: bool) {
	first := -1
	for index := 0; index < len(port_text); index += 1 {
		byte := port_text[index]
		if byte < '0' || byte > '9' {
			return 0, false
		}
		if first < 0 && byte != '0' {
			first = index
		}
	}
	if first < 0 {
		// Empty, or nothing but zeros.
		return 0, true
	}
	if len(port_text) - first > 5 {
		return 0, false
	}
	for index := first; index < len(port_text); index += 1 {
		value = value * 10 + int(port_text[index] - '0')
	}
	return value, true
}

// url_host_is_ipv6_addr_z is the pattern's third alternative,
// `_IPV6_ADDRZ_PAT` (util/url.py:56-58): '[' + `_IPV6_PAT` + an optional RFC 6874
// zone id + ']'.
@(private)
url_host_is_ipv6_addr_z :: proc(bracketed: string) -> bool {
	if len(bracketed) < 2 || bracketed[0] != '[' || bracketed[len(bracketed) - 1] != ']' {
		return false
	}
	inner := bracketed[1:len(bracketed) - 1]
	address := inner
	zone := ""
	if percent := strings.index_byte(inner, '%'); percent >= 0 {
		address = inner[:percent]
		zone = inner[percent:]
	}
	if !url_host_is_ipv6(address) {
		return false
	}
	if zone != "" && !url_host_is_zone_id(zone) {
		return false
	}
	return true
}

// url_host_is_zone_id is `_ZONE_ID_PAT` (`(?:%25|%)(?:[UNRESERVED]|%[a-fA-F0-9]{2})+`,
// util/url.py:57) from its '%': at least one unreserved character or `%XX`
// escape behind it. `%25eth0` is the escaped spelling of an RFC 4007 scope and
// `%eth0` the bare one — the pattern's two prefixes spell the same language, the
// '2' and '5' of `%25` being unreserved characters either way.
@(private)
url_host_is_zone_id :: proc(zone: string) -> bool {
	index := 1
	for index < len(zone) {
		if zone[index] != '%' {
			if !url_unreserved_char(zone[index]) {
				return false
			}
			index += 1
			continue
		}
		if index + 2 >= len(zone) ||
		   !url_is_hex_digit(zone[index + 1]) || !url_is_hex_digit(zone[index + 2]) {
			return false
		}
		index += 3
	}
	return index > 1
}

// url_host_is_ipv6 is `_IPV6_PAT` (util/url.py:34-53): the nine-way RFC 3986
// alternation of `h16` groups — `[0-9A-Fa-f]{1,4}` — around an optional `::`,
// with an `ls32` tail of two `h16` groups or an IPv4 address on the variations
// that end in one.
//
// The nine are walked as an NFA over byte positions, so every split the regex
// engine would try is tried here too: each position is a bit of `mask` ("the
// first i bytes match") and each step moves the bits on. No address that could
// match is longer than 45 bytes — `(?:h16:){6}` plus a 15-byte IPv4 `ls32`, the
// longest variation — so the u64 holds every position with room to spare.
@(private)
url_host_is_ipv6 :: proc(address: string) -> bool {
	if len(address) >= 64 {
		return false
	}
	length := len(address)
	start: u64 = 1 // position 0

	// Variation 1, `(?:h16:){6}ls32`, the one with no `::`.
	end := url_host_ls32_positions(url_host_hex_colon_repeat(start, address, 6), address)

	// Variations 2-9 all have a `::`: an optional run of `h16` groups in front
	// of it (up to `max_left`, the last of them without a ':' of its own) and a
	// tail of `h16` groups behind it, ending in `ls32` on all but the last two.
	after := url_host_after_double_colon(address, 0) // variation 2
	end |= url_host_ls32_positions(url_host_hex_colon_repeat(after, address, 5), address)
	after = url_host_after_double_colon(address, 1) // variation 3
	end |= url_host_ls32_positions(url_host_hex_colon_repeat(after, address, 4), address)
	after = url_host_after_double_colon(address, 2) // variation 4
	end |= url_host_ls32_positions(url_host_hex_colon_repeat(after, address, 3), address)
	after = url_host_after_double_colon(address, 3) // variation 5
	end |= url_host_ls32_positions(url_host_hex_colon_repeat(after, address, 2), address)
	after = url_host_after_double_colon(address, 4) // variation 6
	end |= url_host_ls32_positions(url_host_hex_colon_repeat(after, address, 1), address)
	after = url_host_after_double_colon(address, 5) // variation 7
	end |= url_host_ls32_positions(after, address)
	after = url_host_after_double_colon(address, 6) // variation 8
	end |= url_host_hex_positions(after, address)
	end |= url_host_after_double_colon(address, 7) // variation 9

	return end & (u64(1) << uint(length)) != 0
}

// url_host_after_double_colon is `(?:(?:h16:){0,max-1}h16)?::` — up to `max`
// `h16` groups, all but the last followed by ':', then the two colons — as the
// positions the address can be at once that prefix is consumed.
@(private)
url_host_after_double_colon :: proc(address: string, max_groups: int) -> u64 {
	start: u64 = 1
	out := url_host_literal_positions(start, address, "::")
	groups := start
	for count := 1; count <= max_groups; count += 1 {
		if count == 1 {
			groups = url_host_hex_positions(start, address)
		} else {
			groups = url_host_hex_positions(url_host_literal_positions(groups, address, ":"), address)
		}
		out |= url_host_literal_positions(groups, address, "::")
	}
	return out
}

// url_host_ls32_positions is `ls32`, `(?:h16:h16|ipv4)` (util/url.py:32).
@(private)
url_host_ls32_positions :: proc(mask: u64, address: string) -> u64 {
	pair := url_host_hex_positions(mask, address)
	pair = url_host_literal_positions(pair, address, ":")
	pair = url_host_hex_positions(pair, address)
	return pair | url_host_ipv4_positions(mask, address)
}

// url_host_ipv4_positions is `_IPV4_PAT`, `(?:[0-9]{1,3}.){3}[0-9]{1,3}`
// (util/url.py:30) — the dotted-quad `ls32` writes, not the liberal `_IPV4_RE`
// the host rule reads later.
@(private)
url_host_ipv4_positions :: proc(mask: u64, address: string) -> u64 {
	positions := mask
	for group := 0; group < 4; group += 1 {
		next: u64 = 0
		for index := 0; index < len(address); index += 1 {
			if positions & (u64(1) << uint(index)) == 0 {
				continue
			}
			for width := 1; width <= 3 && index + width <= len(address); width += 1 {
				byte := address[index + width - 1]
				if byte < '0' || byte > '9' {
					break
				}
				next |= u64(1) << uint(index + width)
			}
		}
		positions = next
		if group < 3 {
			positions = url_host_literal_positions(positions, address, ".")
		}
	}
	return positions
}

// url_host_hex_positions moves every position on by one `h16` group —
// `[0-9A-Fa-f]{1,4}` — trying each of the four lengths.
@(private)
url_host_hex_positions :: proc(mask: u64, address: string) -> u64 {
	out: u64 = 0
	for index := 0; index < len(address); index += 1 {
		if mask & (u64(1) << uint(index)) == 0 {
			continue
		}
		for width := 1; width <= 4 && index + width <= len(address); width += 1 {
			if !url_is_hex_digit(address[index + width - 1]) {
				break
			}
			out |= u64(1) << uint(index + width)
		}
	}
	return out
}

// url_host_hex_colon_repeat is `(?:h16:){count}`: `count` `h16` groups, each
// with its own colon.
@(private)
url_host_hex_colon_repeat :: proc(mask: u64, address: string, count: int) -> u64 {
	positions := mask
	for _ in 0 ..< count {
		positions = url_host_hex_positions(positions, address)
		positions = url_host_literal_positions(positions, address, ":")
	}
	return positions
}

// url_host_literal_positions moves every position on by `literal`.
@(private)
url_host_literal_positions :: proc(mask: u64, address: string, literal: string) -> u64 {
	out: u64 = 0
	for index := 0; index + len(literal) <= len(address); index += 1 {
		if mask & (u64(1) << uint(index)) == 0 {
			continue
		}
		if address[index:index + len(literal)] == literal {
			out |= u64(1) << uint(index + len(literal))
		}
	}
	return out
}

// url_host_invalid_char is `_HOST_INVALID_CHAR_RE.search` (`[\x00-\x20\x7f]`,
// util/url.py:20): the position of the first one, and whether there is one.
@(private)
url_host_invalid_char :: proc(text: string) -> (index: int, found: bool) {
	for position := 0; position < len(text); position += 1 {
		if text[position] <= 0x20 || text[position] == 0x7f {
			return position, true
		}
	}
	return 0, false
}

// url_host_is_ipv4 is urllib3's `_IPV4_RE.match` (util/url.py:62-64): one to
// four dot-separated groups, each either decimal or `0x`-prefixed hexadecimal.
// A host that matches is *not* lowercased, unquoted or IDNA-encoded — which is
// what makes the test worth carrying: `0X7F.1` keeps its capitals.
@(private)
url_host_is_ipv4 :: proc(host: string) -> bool {
	groups := 0
	index := 0
	for index <= len(host) {
		end := index
		for end < len(host) && host[end] != '.' {
			end += 1
		}
		if !url_host_is_ipv4_group(host[index:end]) {
			return false
		}
		groups += 1
		if end == len(host) {
			break
		}
		index = end + 1
	}
	return groups >= 1 && groups <= 4
}

@(private)
url_host_is_ipv4_group :: proc(group: string) -> bool {
	if len(group) == 0 {
		return false
	}
	hex := len(group) > 2 && group[0] == '0' && (group[1] == 'x' || group[1] == 'X')
	for index := hex ? 2 : 0; index < len(group); index += 1 {
		if !is_digit(group[index]) && !(hex && url_is_hex_digit(group[index])) {
			return false
		}
	}
	return true
}

// url_host_fold_escapes_into is `_normalize_host_percent_encoding`
// (util/url.py:404-418) over the whole host: a `%XX` whose octet is a control
// character is a `LocationParseError` naming the host and the escape, one whose
// octet is an unreserved character becomes that character, and any other escape
// stays `%XX` with its hex uppercased.
//
// `host_owned` says the host is the caller's own copy (the curl-style
// shorthand's joined authority does not outlive the call): the error takes it
// over when it names it, so the render after the call still has the string.
@(private)
url_host_fold_escapes_into :: proc(
	buffer: ^Buffer,
	host: string,
	err: ^Host_Error,
	host_owned: bool,
) -> Error {
	for index := 0; index < len(host); {
		if host[index] == '%' {
			// The authority check has already ruled out a '%' that starts no
			// escape.
			high, _ := url_hex_value(host[index + 1])
			low, _ := url_hex_value(host[index + 2])
			octet := high << 4 | low
			if octet < 0x20 || octet == 0x7f {
				if err != nil {
					err^ = {
						kind      = .Invalid_Percent_Control,
						text      = host,
						character = host[index:index + 3],
						owned     = host_owned,
					}
				}
				return .Invalid_URL
			}
			if url_unreserved_char(octet) {
				if !buffer_append_byte(buffer, octet) {
					return .Out_Of_Memory
				}
			} else if !buffer_append_byte(buffer, '%') ||
			   !buffer_append_byte(buffer, url_hex_upper(host[index + 1])) ||
			   !buffer_append_byte(buffer, url_hex_upper(host[index + 2])) {
				return .Out_Of_Memory
			}
			index += 3
			continue
		}
		if !buffer_append_byte(buffer, host[index]) {
			return .Out_Of_Memory
		}
		index += 1
	}
	return .None
}

// url_host_is_ascii is `str.isascii()`: every byte below 0x80. The host is the
// argv bytes, so this is the same test CPython makes on the decoded string.
@(private)
url_host_is_ascii :: proc(text: string) -> bool {
	for index := 0; index < len(text); index += 1 {
		if text[index] >= 0x80 {
			return false
		}
	}
	return true
}

// url_host_ascii_label_into writes the spelling `_idna_encode` gives an ASCII
// label: `name.lower()` with every `%XX` escape uppercased again, which is the
// `_PERCENT_RE.sub` of util/url.py:449-451. The escapes are the ones the folding
// above left behind, so they are well formed.
@(private)
url_host_ascii_label_into :: proc(buffer: ^Buffer, label: string) -> bool {
	for index := 0; index < len(label); {
		if label[index] == '%' {
			if !buffer_append_byte(buffer, '%') ||
			   !buffer_append_byte(buffer, url_hex_upper(label[index + 1])) ||
			   !buffer_append_byte(buffer, url_hex_upper(label[index + 2])) {
				return false
			}
			index += 3
			continue
		}
		if !buffer_append_byte(buffer, url_ascii_lower(label[index])) {
			return false
		}
		index += 1
	}
	return true
}

// ---------------------------------------------------------------------------
// IDNA: `idna.encode(label.lower(), strict=True, std3_rules=True)`, the call
// urllib3's `_idna_encode` makes for a non-ASCII label (util/url.py:432-451).
// ---------------------------------------------------------------------------

// The port models `idna.core.alabel` (core.py:524-556): `check_label`, then the
// branch the label it is handed takes — punycode with the `xn--` prefix for a
// non-ASCII one, the label itself for an ASCII one. `check_label`
// (core.py:442-521) is, in order: the length limits, the NFC test, the hyphen
// rules, the no-leading-combiner rule, one class lookup per code point — with
// the CONTEXTJ/CONTEXTO contextual rule behind the lookup — and the Bidi Rule.
// The class lookup and the label checks are the generated tables
// (src/http/idna_generated.odin, build/gen_idna_tables.py); the lowercasing the
// caller applies first is CPython's `str.lower()` (`url_host_lower_into`).
//
// The label the reference checks is the *lowercased* one: urllib3 hands idna
// `name.lower()`, and `alabel`'s ASCII branch runs `ulabel`, whose non-`xn--`
// path calls `check_label` on the same lowercased bytes — so both branches run
// the checks below over the string `url_host_labels_into` lowered.
url_host_idna_label_into :: proc(buffer: ^Buffer, label: string) -> Error {
	// One decode of the label: every rule below reads code points (and their
	// neighbours), not the bytes.
	codes: [idna_max_label_codes]rune
	count := 0
	for index := 0; index < len(label); {
		code, width := utf8.decode_rune_in_string(label[index:])
		if width <= 0 {
			// A byte that is not UTF-8 is the lone surrogate CPython's
			// surrogateescape made of it — DISALLOWED, so the label fails
			// exactly as any other disallowed code point does.
			return .Invalid_URL
		}
		if count == idna_max_label_codes {
			// More code points than `_max_input_length` (1024): refused
			// whatever they are, so the rest of the label is not decoded.
			return .Invalid_URL
		}
		codes[count] = code
		count += 1
		index += width
	}
	if count == 0 {
		// `check_label` refuses an empty label first (core.py:464-465). An
		// empty label is ASCII, so the caller never brings one here.
		return .Invalid_URL
	}
	if count > idna_max_input_length {
		return .Invalid_URL
	}
	if count > 254 {
		// `valid_string_length(label, trailing_dot=True)`: the 253-octet domain
		// limit plus the dot a trailing one adds (core.py:156-167, :467-469).
		return .Invalid_URL
	}
	if !idna_label_is_nfc(codes[:count]) {
		// `check_nfc` (core.py:427-440): a label that is not its own
		// Normalization Form C is refused.
		return .Invalid_URL
	}
	// `check_hyphen_ok` (core.py:309-325): a label may not carry hyphens in both
	// the third and fourth positions, nor start or end with one.
	if (count >= 4 && codes[2] == '-' && codes[3] == '-') ||
	   codes[0] == '-' || codes[count - 1] == '-' {
		return .Invalid_URL
	}
	// `check_initial_combiner` (core.py:288-307): a label may not begin with a
	// Mark (`unicodedata.category(c)[0] == "M"`).
	if idna_is_mark(codes[0]) {
		return .Invalid_URL
	}
	// The class lookup (core.py:481-518): a code point in one of the three
	// classes is accepted — a CONTEXTJ or CONTEXTO one only where its own
	// contextual rule allows it — and any other is DISALLOWED or UNASSIGNED.
	for index := 0; index < count; index += 1 {
		code := codes[index]
		switch {
		case idna_code_point_pvalid(code):
		case idna_code_point_contextj(code):
			if !idna_valid_contextj(codes[:count], index) {
				return .Invalid_URL
			}
		case idna_code_point_contexto(code):
			if !idna_valid_contexto(codes[:count], index) {
				return .Invalid_URL
			}
		case:
			return .Invalid_URL
		}
	}
	if !idna_label_bidi_ok(codes[:count]) {
		// `check_bidi`: the RFC 5893 Bidi Rule, applied to a label that
		// carries a right-to-left character (`check_ltr` is false in
		// `check_label`'s call).
		return .Invalid_URL
	}

	// `alabel` picks its branch on the label it is handed. Lowercasing is this
	// routine's caller's step, so the label here is the lowercased one: a
	// mapping that lands on ASCII (KELVIN SIGN → `k`) takes the ASCII branch,
	// which returns the label itself — no `xn--`, no punycode — after the same
	// checks and the same 63-octet limit (core.py:536-547).
	if url_host_is_ascii(label) {
		if len(label) > 63 || !buffer_append_string(buffer, label) {
			return len(label) > 63 ? .Invalid_URL : .Out_Of_Memory
		}
		return .None
	}

	// The non-ASCII branch: `xn--` plus the punycode encoding, against the same
	// 63-octet limit (core.py:549-556).
	start := len(buffer.data)
	if !buffer_append_string(buffer, "xn--") {
		return .Out_Of_Memory
	}
	if !url_host_punycode_into(buffer, label) {
		return .Out_Of_Memory
	}
	if len(buffer.data) - start > 63 {
		return .Invalid_URL
	}
	return .None
}

// url_host_lower_into writes `str.lower()` for one code point of the label,
// which is the step urllib3's `_idna_encode` runs before idna sees the label:
//
//   - the mapping is per code point (`idna_lower_map`), measured from the
//     reference's own CPython, so a mapping Odin's `core:unicode.to_lower` does
//     not carry (Cherokee U+13A0 → U+AB70, KELVIN U+212A → `k`) is the same
//     here;
//   - the one code point whose lowercase is *two* code points is an expansion
//     (U+0130 → `i` + U+0307, `idna_lower_expansions`);
//   - a capital sigma depends on its context: `str.lower()` writes the final
//     form (U+03C2) when the code point before it is Cased and the one after it
//     is not (`Objects/unicodeobject.c`, `case_operation`). `previous` and
//     `next` are the *unlowered* neighbours — 0 when there is none — and the
//     Cased set is `idna_cased_ranges`, measured through that same rule.
@(private)
url_host_lower_into :: proc(buffer: ^Buffer, code, previous, next: rune) -> bool {
	for entry in idna_lower_expansions {
		if rune(entry[0]) != code {
			continue
		}
		if !url_append_rune(buffer, rune(entry[1])) {
			return false
		}
		return entry[2] == 0 || url_append_rune(buffer, rune(entry[2]))
	}
	if code == 0x03a3 && idna_is_cased(previous) && !idna_is_cased(next) {
		return url_append_rune(buffer, 0x03c2)
	}
	if mapped := idna_pair_lookup(idna_lower_map[:], u32(code)); mapped != 0 {
		return url_append_rune(buffer, rune(mapped))
	}
	return url_append_rune(buffer, code)
}

// url_host_punycode_into writes CPython's `str.encode("punycode")` for `label`
// — RFC 3492 §6.3 with the RFC's sample parameters (`base` 36, `tmin` 1,
// `tmax` 26, `skew` 38, `damp` 700, `initial_bias` 72; CPython's
// `Modules/punycode.c`), which is the encoding `idna.core._punycode` asks for.
// The basic code points come out as they are, then '-', then the extended ones.
@(private)
url_host_punycode_into :: proc(buffer: ^Buffer, label: string) -> bool {
	basic := 0
	total := 0
	for index := 0; index < len(label); {
		code, width := utf8.decode_rune_in_string(label[index:])
		if width <= 0 {
			return false
		}
		total += 1
		if code < 0x80 {
			basic += 1
			if !buffer_append_byte(buffer, u8(code)) {
				return false
			}
		}
		index += width
	}
	if basic > 0 && !buffer_append_byte(buffer, '-') {
		return false
	}

	handled := basic
	n := u32(128)
	delta := u64(0)
	bias := u64(72)
	for handled < total {
		// The smallest code point of the label that is >= n.
		next := u32(0x110000)
		for index := 0; index < len(label); {
			code, width := utf8.decode_rune_in_string(label[index:])
			if width <= 0 {
				return false
			}
			value := u32(code)
			if value >= n && value < next {
				next = value
			}
			index += width
		}
		delta += u64(next - n) * u64(handled + 1)
		n = next
		for index := 0; index < len(label); {
			code, width := utf8.decode_rune_in_string(label[index:])
			if width <= 0 {
				return false
			}
			value := u32(code)
			switch {
			case value < n:
				delta += 1
			case value == n:
				q := delta
				k := u64(36)
				for {
					t: u64
					switch {
					case k <= bias:
						t = 1
					case k >= bias + 26:
						t = 26
					case:
						t = k - bias
					}
					if q < t {
						break
					}
					if !buffer_append_byte(buffer, url_punycode_digit(u8(t + (q - t) % (36 - t)))) {
						return false
					}
					q = (q - t) / (36 - t)
					k += 36
				}
				if !buffer_append_byte(buffer, url_punycode_digit(u8(q))) {
					return false
				}
				bias = url_punycode_adapt(delta, u64(handled + 1), handled == basic)
				delta = 0
				handled += 1
			}
			index += width
		}
		delta += 1
		n += 1
	}
	return true
}

// url_punycode_digit is the RFC's `digit` for the lowercase alphabet CPython
// emits: 0-25 are `a`-`z`, 26-35 are `0`-`9`.
@(private)
url_punycode_digit :: proc(value: u8) -> u8 {
	if value < 26 {
		return 'a' + value
	}
	return '0' + (value - 26)
}

// url_punycode_adapt is the RFC's `adapt` (delta, numpoints, firsttime).
@(private)
url_punycode_adapt :: proc(delta, numpoints: u64, first: bool) -> u64 {
	adapted := first ? delta / 700 : delta / 2
	adapted += adapted / numpoints
	k := u64(0)
	for adapted > ((36 - 1) * 26) / 2 {
		adapted /= 36 - 1
		k += 36
	}
	return k + (36 - 1 + 1) * adapted / (adapted + 38)
}

// url_ascii_lower is CPython's `str.lower()` for one ASCII byte, which is what
// the ASCII half of `_idna_encode` amounts to.
@(private)
url_ascii_lower :: proc(byte: u8) -> u8 {
	if byte >= 'A' && byte <= 'Z' {
		return byte - 'A' + 'a'
	}
	return byte
}

// url_host_ascii_lower_into writes `str.lower()` for the bytes of `text`. The
// one caller is the bracketed host's `host.lower()` (`_normalize_host`'s
// IPv6 branch, util/url.py:375-390): a host that reached the pattern's
// bracketed alternative is ASCII, so the byte-for-byte `A-Z` → `a-z` is the
// whole of CPython's mapping there.
@(private)
url_host_ascii_lower_into :: proc(buffer: ^Buffer, text: string) -> bool {
	for index := 0; index < len(text); index += 1 {
		if !buffer_append_byte(buffer, url_ascii_lower(text[index])) {
			return false
		}
	}
	return true
}

// url_append_rune writes the UTF-8 form of one code point.
@(private)
url_append_rune :: proc(buffer: ^Buffer, code: rune) -> bool {
	bytes, width := utf8.encode_rune(code)
	for index := 0; index < width; index += 1 {
		if !buffer_append_byte(buffer, bytes[index]) {
			return false
		}
	}
	return true
}

// `check_label` refuses a label longer than this (core.py:15, :458) and refuses
// one longer than 254 code points outright (the 253-octet domain limit plus a
// trailing dot).
@(private)
idna_max_input_length :: 1024

// One more rune than `_max_input_length`: enough to notice a label that is too
// long without decoding the whole of it.
@(private)
idna_max_label_codes :: idna_max_input_length + 1

// The rune buffer `check_nfc`'s normalization needs. A label of at most
// `_max_input_length` code points decomposes to at most four times that many
// (UAX #15 bounds a canonical decomposition at four code points, and
// build/gen_idna_tables.py asserts it of the reference's own data).
@(private)
idna_nfc_scratch_size :: 4 * idna_max_input_length + 4

// `_virama_combining_class` (core.py:12): the combining class a character
// before a joiner has to have for the joiner to be allowed.
@(private)
idna_virama_class :: 9

// idna_code_point_pvalid reports whether `code` is in the PVALID class, which
// `check_label` accepts without looking at its context.
@(private)
idna_code_point_pvalid :: proc(code: rune) -> bool {
	return idna_range_contains(idna_pvalid_ranges[:], u32(code))
}

// idna_code_point_contextj reports whether `code` is in the CONTEXTJ class —
// the two joiners, U+200C and U+200D — whose rule is `valid_contextj`.
@(private)
idna_code_point_contextj :: proc(code: rune) -> bool {
	return idna_range_contains(idna_contextj_ranges[:], u32(code))
}

// idna_code_point_contexto reports whether `code` is in the CONTEXTO class,
// whose rule is `valid_contexto`.
@(private)
idna_code_point_contexto :: proc(code: rune) -> bool {
	return idna_range_contains(idna_contexto_ranges[:], u32(code))
}

// idna_is_mark reports whether `code`'s Unicode general category is a Mark,
// which is `check_initial_combiner`'s test on the first character of a label.
@(private)
idna_is_mark :: proc(code: rune) -> bool {
	return idna_range_contains(idna_mark_ranges[:], u32(code))
}

// idna_is_cased is the derived `Cased` property, which `str.lower()`'s
// final-sigma rule reads: a code point in one of these ranges is Cased.
@(private)
idna_is_cased :: proc(code: rune) -> bool {
	return idna_range_contains(idna_cased_ranges[:], u32(code))
}

// idna_pair_lookup is the binary search over one of the {code point, value}
// tables, which are sorted by the first element; 0 means "no entry".
@(private)
idna_pair_lookup :: proc(pairs: [][2]u32, code: u32) -> u32 {
	low := 0
	high := len(pairs) - 1
	for low <= high {
		middle := low + (high - low) / 2
		entry := pairs[middle]
		switch {
		case code < entry[0]:
			high = middle - 1
		case code > entry[0]:
			low = middle + 1
		case:
			return entry[1]
		}
	}
	return 0
}

// idna_range_contains is the binary search over a sorted inclusive range table.
@(private)
idna_range_contains :: proc(ranges: [][2]u32, code: u32) -> bool {
	low := 0
	high := len(ranges) - 1
	for low <= high {
		middle := low + (high - low) / 2
		entry := ranges[middle]
		switch {
		case code < entry[0]:
			high = middle - 1
		case code > entry[1]:
			low = middle + 1
		case:
			return true
		}
	}
	return false
}

// idna_triple_lookup is the binary search over one of the {key, ...} tables
// (sorted by the first column); the entry, and whether there is one.
@(private)
idna_triple_lookup :: proc(entries: [][3]u32, key: u32) -> (entry: [3]u32, found: bool) {
	low := 0
	high := len(entries) - 1
	for low <= high {
		middle := low + (high - low) / 2
		candidate := entries[middle]
		switch {
		case key < candidate[0]:
			high = middle - 1
		case key > candidate[0]:
			low = middle + 1
		case:
			return candidate, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// The three label-context rules of `check_label`: `check_nfc`, the
// CONTEXTJ/CONTEXTO contexts and the Bidi Rule. Each one is a refusal in the
// reference, so the port refuses the label where the reference does — the
// message is the same `Name '<label>' is not a valid IDNA label`
// (`_idna_encode` maps every `idna.IDNAError` onto it, util/url.py:441-447).
// ---------------------------------------------------------------------------

// idna_label_is_nfc is `check_nfc`: `unicodedata.normalize("NFC", label)` must
// be the label itself (core.py:427-440). This runs the Unicode algorithm (UAX
// #15 §4) — canonical decomposition, canonical ordering, canonical composition
// — and compares the result with the code points it started from.
@(private)
idna_label_is_nfc :: proc(codes: []rune) -> bool {
	decomposed: [idna_nfc_scratch_size]rune
	count := 0
	for code in codes {
		if !idna_decompose_into(code, &decomposed, &count) {
			// Unreachable: the caller has already refused a label longer than
			// `_max_input_length`, and a decomposition is at most four code
			// points per code point.
			return false
		}
	}

	// Canonical ordering: each run of non-starters behind a starter is stable
	// -sorted by combining class (UAX #15 §4, "Canonical Ordering").
	for index := 1; index < count; index += 1 {
		class := idna_combining_class(decomposed[index])
		if class == 0 {
			continue
		}
		position := index
		for position > 0 && idna_combining_class(decomposed[position - 1]) > class {
			decomposed[position - 1], decomposed[position] =
				decomposed[position], decomposed[position - 1]
			position -= 1
		}
	}

	// Canonical composition, in place: a composite replaces its starter, so the
	// result is never longer than the decomposition and the read position is
	// never behind the write one.
	written := 0
	for read := 0; read < count; read += 1 {
		code := decomposed[read]
		class := idna_combining_class(code)
		if written > 0 {
			// The last starter written, and whether anything between it and
			// `code` blocks the composition: a character blocks when its class
			// is zero or at least `code`'s (UAX #15 §4, R2).
			starter := written - 1
			for starter >= 0 && idna_combining_class(decomposed[starter]) != 0 {
				starter -= 1
			}
			if starter >= 0 {
				blocked := false
				for index := starter + 1; index < written; index += 1 {
					between := idna_combining_class(decomposed[index])
					if between == 0 || between >= class {
						blocked = true
						break
					}
				}
				if !blocked {
					if composite := idna_compose_pair(decomposed[starter], code); composite != 0 {
						decomposed[starter] = composite
						continue
					}
				}
			}
		}
		decomposed[written] = code
		written += 1
	}

	if written != len(codes) {
		return false
	}
	for index := 0; index < written; index += 1 {
		if decomposed[index] != codes[index] {
			return false
		}
	}
	return true
}

// idna_decompose_into appends the full canonical decomposition of `code` to
// `out`, and reports whether it fitted. The table carries the mappings
// UnicodeData.txt spells out (one or two code points each, recursed into
// here); the Hangul syllables are not in it because their decomposition is
// arithmetic.
@(private)
idna_decompose_into :: proc(
	code: rune,
	out: ^[idna_nfc_scratch_size]rune,
	count: ^int,
) -> bool {
	// UAX #15 §10: `SBASE`, `LBASE`, `VBASE`, `TBASE` and `NCOUNT` = the 588
	// syllables a leading consonant and a vowel spell.
	if 0xAC00 <= code && code < 0xAC00 + 11172 {
		syllable := u32(code) - 0xAC00
		return idna_append_rune(out, count, rune(0x1100 + syllable / 588)) &&
			idna_append_rune(out, count, rune(0x1161 + (syllable % 588) / 28)) &&
			(syllable % 28 == 0 ||
				idna_append_rune(out, count, rune(0x11A7 + syllable % 28)))
	}
	if entry, found := idna_triple_lookup(idna_decompose_pairs[:], u32(code)); found {
		return idna_decompose_into(rune(entry[1]), out, count) &&
			(entry[2] == 0 || idna_decompose_into(rune(entry[2]), out, count))
	}
	return idna_append_rune(out, count, code)
}

@(private)
idna_append_rune :: proc(
	out: ^[idna_nfc_scratch_size]rune,
	count: ^int,
	code: rune,
) -> bool {
	if count^ >= len(out) {
		return false
	}
	out[count^] = code
	count^ += 1
	return true
}

// idna_compose_pair is the composition step's pair lookup: the Hangul pairs
// compose arithmetically (UAX #15 §10) and the generated table carries the
// rest; 0 means the pair does not compose.
@(private)
idna_compose_pair :: proc(first, second: rune) -> rune {
	// A leading consonant and a vowel spell a syllable, and a trailing
	// consonant spelled on that syllable extends it.
	if 0x1100 <= first && first < 0x1100 + 19 && 0x1161 <= second && second < 0x1161 + 21 {
		return rune(0xAC00 + ((u32(first) - 0x1100) * 21 + (u32(second) - 0x1161)) * 28)
	}
	if 0xAC00 <= first && first < 0xAC00 + 11172 &&
	   (u32(first) - 0xAC00) % 28 == 0 && 0x11A7 < second && second < 0x11A7 + 28 {
		return rune(u32(first) + (u32(second) - 0x11A7))
	}
	return idna_compose_lookup(first, second)
}

// idna_compose_lookup is the binary search of the primary composites, which are
// sorted by their first two columns (the pair).
@(private)
idna_compose_lookup :: proc(first, second: rune) -> rune {
	low := 0
	high := len(idna_compose_pairs) - 1
	for low <= high {
		middle := low + (high - low) / 2
		entry := idna_compose_pairs[middle]
		switch {
		case u32(first) < entry[0]:
			high = middle - 1
		case u32(first) > entry[0]:
			low = middle + 1
		case u32(second) < entry[1]:
			high = middle - 1
		case u32(second) > entry[1]:
			low = middle + 1
		case:
			return rune(entry[2])
		}
	}
	return 0
}

// idna_combining_class is `unicodedata.combining`: a code point in no run is a
// starter (class 0).
@(private)
idna_combining_class :: proc(code: rune) -> u32 {
	low := 0
	high := len(idna_ccc_runs) - 1
	for low <= high {
		middle := low + (high - low) / 2
		entry := idna_ccc_runs[middle]
		switch {
		case u32(code) < entry[0]:
			high = middle - 1
		case u32(code) > entry[1]:
			low = middle + 1
		case:
			return entry[2]
		}
	}
	return 0
}

// Idna_Joining_Type names `_joining_type`'s types (core.py:30-34), which is
// `idnadata.joining_types`; `None` is a code point in none of the four, which
// the ZWNJ rule treats as a joiner that stops the walk.
Idna_Joining_Type :: enum {
	None,
	L,
	D,
	R,
	T,
}

// idna_joining_type is `_joining_type`: the first of the four tables that
// carries the code point (the reference's own order).
@(private)
idna_joining_type :: proc(code: rune) -> Idna_Joining_Type {
	switch {
	case idna_range_contains(idna_joining_l_ranges[:], u32(code)):
		return .L
	case idna_range_contains(idna_joining_d_ranges[:], u32(code)):
		return .D
	case idna_range_contains(idna_joining_r_ranges[:], u32(code)):
		return .R
	case idna_range_contains(idna_joining_t_ranges[:], u32(code)):
		return .T
	}
	return .None
}

@(private)
idna_is_script_greek :: proc(code: rune) -> bool {
	return idna_range_contains(idna_script_greek_ranges[:], u32(code))
}

@(private)
idna_is_script_hebrew :: proc(code: rune) -> bool {
	return idna_range_contains(idna_script_hebrew_ranges[:], u32(code))
}

@(private)
idna_is_script_hiragana :: proc(code: rune) -> bool {
	return idna_range_contains(idna_script_hiragana_ranges[:], u32(code))
}

@(private)
idna_is_script_katakana :: proc(code: rune) -> bool {
	return idna_range_contains(idna_script_katakana_ranges[:], u32(code))
}

@(private)
idna_is_script_han :: proc(code: rune) -> bool {
	return idna_range_contains(idna_script_han_ranges[:], u32(code))
}

// idna_valid_contextj is `valid_contextj` (core.py:339-...): the rule behind a
// ZWNJ (U+200C) or a ZWJ (U+200D) in the label. Anything else is not a CONTEXTJ
// code point, so the reference's own answer for it is "not allowed".
@(private)
idna_valid_contextj :: proc(codes: []rune, position: int) -> bool {
	code := codes[position]
	if code == 0x200C {
		// A ZWNJ after a virama is allowed ...
		if position > 0 && idna_combining_class(codes[position - 1]) == idna_virama_class {
			return true
		}
		// ... and so is one that splits a joining sequence: the walk left skips
		// the transparent characters and the first one that is not has to join
		// to the left, the walk right one that joins to the right.
		left := false
		for index := position - 1; index >= 0; index -= 1 {
			joining := idna_joining_type(codes[index])
			if joining == .T {
				continue
			}
			if joining == .L || joining == .D {
				left = true
			}
			break
		}
		if !left {
			return false
		}
		right := false
		for index := position + 1; index < len(codes); index += 1 {
			joining := idna_joining_type(codes[index])
			if joining == .T {
				continue
			}
			if joining == .R || joining == .D {
				right = true
			}
			break
		}
		return right
	}
	if code == 0x200D {
		// A ZWJ is allowed after a virama, and nowhere else.
		return position > 0 && idna_combining_class(codes[position - 1]) == idna_virama_class
	}
	return false
}

// idna_valid_contexto is `valid_contexto` (core.py:...): the rule behind a
// CONTEXTO code point — the MIDDLE DOT, the Greek lower numeral sign, the
// Hebrew punctuation, the Katakana middle dot and the Arabic-Indic digit sets.
// A CONTEXTO code point the reference does not name in that function is
// refused, which is what the final `false` is.
@(private)
idna_valid_contexto :: proc(codes: []rune, position: int) -> bool {
	code := codes[position]
	count := len(codes)
	switch code {
	case 0x00B7:
		// MIDDLE DOT: an `l` on both sides of it.
		return position > 0 && position < count - 1 &&
			codes[position - 1] == 'l' && codes[position + 1] == 'l'
	case 0x0375:
		// GREEK LOWER NUMERAL SIGN: the character after it is Greek.
		if position < count - 1 && count > 1 {
			return idna_is_script_greek(codes[position + 1])
		}
		return false
	case 0x05F3, 0x05F4:
		// HEBREW PUNCTUATION: the character before it is Hebrew.
		if position > 0 {
			return idna_is_script_hebrew(codes[position - 1])
		}
		return false
	case 0x30FB:
		// KATAKANA MIDDLE DOT: some character of the label is Hiragana,
		// Katakana or Han.
		for other in codes {
			if other == 0x30FB {
				continue
			}
			if idna_is_script_hiragana(other) || idna_is_script_katakana(other) ||
			   idna_is_script_han(other) {
				return true
			}
		}
		return false
	}
	// The two Arabic-Indic digit sets may not be mixed, whichever of the two a
	// code point belongs to.
	if code >= 0x0660 && code <= 0x0669 {
		for other in codes {
			if other >= 0x06F0 && other <= 0x06F9 {
				return false
			}
		}
		return true
	}
	if code >= 0x06F0 && code <= 0x06F9 {
		for other in codes {
			if other >= 0x0660 && other <= 0x0669 {
				return false
			}
		}
		return true
	}
	return false
}

// idna_bidi_class is `unicodedata.bidirectional` for the code points a label
// can carry (the generated table covers exactly those, because `check_bidi`
// runs after the per-code-point class lookup). `Other` is the answer for a code
// point no run carries — a class the rule never allows.
@(private)
idna_bidi_class :: proc(code: rune) -> Idna_Bidi {
	low := 0
	high := len(idna_bidi_ranges) - 1
	for low <= high {
		middle := low + (high - low) / 2
		entry := idna_bidi_ranges[middle]
		switch {
		case u32(code) < entry[0]:
			high = middle - 1
		case u32(code) > entry[1]:
			low = middle + 1
		case:
			return Idna_Bidi(entry[2])
		}
	}
	return .Other
}

// idna_label_bidi_ok is `check_bidi` (core.py:171-...): RFC 5893's Bidi Rule,
// applied by `check_label` with `check_ltr=False`, so a label with no
// right-to-left character passes it.
@(private)
idna_label_bidi_ok :: proc(codes: []rune) -> bool {
	// A code point with no directionality at all is refused outright, before
	// the rule even asks whether the label is right-to-left.
	rtl_label := false
	for code in codes {
		class := idna_bidi_class(code)
		if class == .Unknown {
			return false
		}
		if class == .R || class == .AL || class == .AN {
			rtl_label = true
		}
	}
	if !rtl_label {
		return true
	}

	// Rule 1: the first character is `L`, `R` or `AL`.
	right_to_left: bool
	#partial switch idna_bidi_class(codes[0]) {
	case .R, .AL:
		right_to_left = true
	case .L:
		right_to_left = false
	case:
		return false
	}

	// Rules 3 and 6: the last character that is not a non-spacing mark decides
	// the direction the label ends in; the flag below is that one's verdict.
	valid_ending := false
	numbers: Idna_Bidi = .Other
	for code in codes {
		class := idna_bidi_class(code)
		if right_to_left {
			// Rule 2: every character is one the rule allows in an RTL label.
			#partial switch class {
			case .R, .AL, .AN, .EN, .ES, .CS, .ET, .ON, .BN, .NSM:
			case:
				return false
			}
			#partial switch class {
			case .R, .AL, .EN, .AN:
				valid_ending = true
			case .NSM:
				// A non-spacing mark leaves the flag alone.
			case:
				valid_ending = false
			}
			// Rule 4: the two numeric types may not be mixed.
			#partial switch class {
			case .AN, .EN:
				if numbers == .Other {
					numbers = class
				} else if numbers != class {
					return false
				}
			}
		} else {
			// Rule 5: every character is one the rule allows in an LTR label.
			#partial switch class {
			case .L, .EN, .ES, .CS, .ET, .ON, .BN, .NSM:
			case:
				return false
			}
			#partial switch class {
			case .L, .EN:
				valid_ending = true
			case .NSM:
			case:
				valid_ending = false
			}
		}
	}
	return valid_ending
}
