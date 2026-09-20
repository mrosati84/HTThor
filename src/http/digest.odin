// HTTP Digest auth (RFC 2617), driven in the port because the reference
// computes the answer itself.
//
// requests' `HTTPDigestAuth` is an auth hook, not a rewind: it sends the
// request, and when the reply is a 4xx whose `WWW-Authenticate` mentions Digest
// it reads (and discards) that reply's body, copies the request, puts the
// computed `Authorization: Digest …` on the copy and sends *that* — the request
// is on the wire twice and no body is ever re-read from a stream
// (`handle_401` / `build_digest_header`, requests/auth.py). The port used to
// hand the same handshake to libcurl (CURLOPT_USERPWD + CURLOPT_HTTPAUTH), which
// can only retry a request it can rewind: a `--chunked` upload is
// `INFILESIZE_UNKNOWN` (a read callback with no seek back to the start), and a
// HEAD that carries bytes cannot be retried at all, because libcurl wants the
// challenge reply's body first and a HEAD reply has none. Measured on both
// roads: build/probe_digest_head.py, build/probe_libcurl_head.c (docs/PARITY.md
// §4.1, t_c182381a).
//
// What is mirrored, byte for byte where it shows:
//   * the challenge parse: requests' `handle_401` tests `"digest" in
//     s_auth.lower()`, removes the first `digest ` and runs
//     `parse_dict_header` over what is left;
//   * the answer (`build_digest_header`): HA1 = MD5(user:realm:pass),
//     HA2 = MD5(method:request-target),
//     response = MD5(HA1:nonce:nc:cnonce:auth:HA2) for qop=auth — with
//     nc=00000001 (the first challenge of a run is a new nonce, so requests'
//     `nonce_count` restarts at 1) and a 16-hex-digit cnonce;
//   * the header's field order and quoting, with `algorithm` spelled the way the
//     challenge spelled it;
//   * the road, not just the answer: the request goes out twice, the second time
//     with the header appended *after* the caller's own headers (measured on a
//     raw socket: build/probe_digest_head.py --wire).
//
// Two things are deliberately not mirrored. `build_digest_header` knows SHA,
// SHA-256 and SHA-512 as well; MD5 and MD5-sess are the algorithms the
// fixture's challenge names (tests/parity/server.py, `/auth/digest`), and a
// challenge that names another one takes the road requests reserves for a hash
// it does not know — no header, so the 401 that arrived is what the run renders.
// And `unquote_header_value`'s two `replace`s (`\\` and `\"`) do not run on the
// challenge fields: they are a realm, a nonce, a qop, an opaque and an algorithm
// name, and an *escaped* one is not something the port can carry without an
// allocation of its own (the fixture sends none).
package http

import "core:mem"
import "core:math/rand"
import "core:strings"

// Digest_Challenge is the server's challenge, parsed the way requests parses
// it. Every field borrows from the header value it was read out of.
Digest_Challenge :: struct {
	realm:     string,
	nonce:     string,
	qop:       string,
	opaque:    string,
	algorithm: string,
}

// digest_challenge_of reads the Digest challenge out of one hop's reply, if that
// reply carries a usable one.
digest_challenge_of :: proc(hop: ^Exchange) -> (challenge: Digest_Challenge, ok: bool) {
	value, has := hop_header_value(hop, "www-authenticate")
	if !has {
		return {}, false
	}
	return digest_challenge_parse(value)
}

// digest_challenge_parse mirrors `handle_401`'s two steps: the scheme is looked
// for anywhere in the value, case-insensitively (`"digest" in s_auth.lower()`),
// the first `digest ` is dropped, and what is left is parsed as a list of
// `name=value` pairs (`parse_dict_header`).
//
// A challenge without a `realm` or a `nonce` is not one the port can answer.
// requests raises `KeyError` there (`chal["realm"]`), which the port cannot
// reproduce as a traceback; refusing the challenge leaves the reply the hop
// actually received as the answer, which is the honest half of that difference.
digest_challenge_parse :: proc(value: string) -> (challenge: Digest_Challenge, ok: bool) {
	rest, has_scheme := digest_strip_scheme(value)
	if !has_scheme {
		return {}, false
	}

	realm, has_realm := digest_field(rest, "realm")
	nonce, has_nonce := digest_field(rest, "nonce")
	if !has_realm || !has_nonce {
		return {}, false
	}
	qop, _ := digest_field(rest, "qop")
	opaque, _ := digest_field(rest, "opaque")
	algorithm, _ := digest_field(rest, "algorithm")
	return Digest_Challenge {
		realm = realm,
		nonce = nonce,
		qop = qop,
		opaque = opaque,
		algorithm = algorithm,
	}, true
}

// digest_strip_scheme drops the first `digest ` (case-insensitively) from
// `value` and reports whether the value mentioned Digest at all — `handle_401`'s
// `"digest" in s_auth.lower()` test and its `pat.sub("", s_auth, count=1)`. A
// value that spells `digest` with no space after it has no challenge to strip.
//
// The text before the scheme is not carried into the parse. requests re-splits
// the concatenation as one list, which can only matter for a header carrying a
// second scheme's parameters — and there its own parse is garbage, since
// `parse_dict_header` is handed `Basic realm="x", realm="y"` and reads the last
// `realm` it finds.
@(private = "file")
digest_strip_scheme :: proc(value: string) -> (rest: string, ok: bool) {
	if len(value) < len("digest ") {
		return "", false
	}
	for index in 0 ..= len(value) - len("digest ") {
		if !strings.equal_fold(value[index:index + len("digest")], "digest") ||
		   value[index + len("digest")] != ' ' {
			continue
		}
		return value[index + len("digest ") :], true
	}
	return "", false
}

// digest_field reads one `name=value` item out of a parsed list, the way a
// Python dict built by `parse_dict_header` behaves: the *last* occurrence of a
// name wins, an item without an `=` carries no value at all, and a value quoted
// end to end loses its quotes.
@(private = "file")
digest_field :: proc(value: string, name: string) -> (field: string, found: bool) {
	rest := value
	for len(rest) > 0 {
		item, consumed, ok := digest_next_item(rest)
		if !ok {
			break
		}
		rest = rest[consumed:]
		equals := strings.index_byte(item, '=')
		if equals < 0 || item[:equals] != name {
			continue
		}
		raw := item[equals + 1:]
		if len(raw) >= 2 && raw[0] == '"' && raw[len(raw) - 1] == '"' {
			raw = raw[1:len(raw) - 1]
		}
		field = raw
		found = true
	}
	return field, found
}

// digest_next_item is one item of CPython's `parse_http_list`
// (Lib/urllib/request.py), which `_parse_list_header` is: the next
// comma-separated item, a comma inside a quoted string (and a quote inside one)
// not a separator, backslashes and the quotes they escape outside the
// boundaries of the item, and the item stripped of surrounding whitespace.
// `consumed` is how much of `rest` the item took, its comma included.
@(private = "file")
digest_next_item :: proc(rest: string) -> (item: string, consumed: int, ok: bool) {
	if rest == "" {
		return "", 0, false
	}
	quote := false
	escape := false
	for index in 0 ..< len(rest) {
		char := rest[index]
		if escape {
			escape = false
			continue
		}
		if quote {
			if char == '\\' {
				escape = true
			} else if char == '"' {
				quote = false
			}
			continue
		}
		if char == ',' {
			return strings.trim_space(rest[:index]), index + 1, true
		}
		if char == '"' {
			quote = true
		}
	}
	return strings.trim_space(rest), len(rest), true
}

// digest_answer_for is the answer to the challenge the hop just received, when
// the hop's reply is one requests would answer: a 4xx whose `WWW-Authenticate`
// the port can compute an answer for (`handle_401`'s
// `if not 400 <= r.status_code < 500`, its `"digest"` test, and
// `build_digest_header`'s refusal of an algorithm it has no hash for).
//
// The verb and the target are the hop's *wire* ones — the request line the
// server sees — because that is the pair the server hashes when it validates the
// answer: `method` is what `apply_hop` puts on the wire (the caller's spelling
// of it), and the target is the path and query of the URL the connection is
// pointed at.
digest_answer_for :: proc(
	hop: Hop,
	exchange: ^Exchange,
	credentials: string,
	allocator: mem.Allocator,
) -> (answer: string, ok: bool) {
	if exchange.status < 400 || exchange.status >= 500 {
		return "", false
	}
	challenge, has_challenge := digest_challenge_of(exchange)
	if !has_challenge {
		return "", false
	}
	method := hop.method_raw
	if method == "" {
		method = method_to_string(hop.method)
	}
	return digest_authorization(
		challenge,
		credentials,
		method,
		digest_request_target(hop.wire_url),
		digest_cnonce(),
		allocator,
	)
}

// digest_authorization computes the header value `build_digest_header` computes,
// in the same field order and with the same quoting, and returns the caller's
// copy of it.
//
// `cnonce` is the client's own nonce, 16 hex characters; the caller generates it
// (digest_cnonce) because it is what makes the answer different on every run.
// Taking it as an argument is also what lets the tests pin the rest of the
// header against the reference's own bytes (tests/digest_test.odin).
digest_authorization :: proc(
	challenge: Digest_Challenge,
	credentials: string,
	method: string,
	target: string,
	cnonce: [16]u8,
	allocator: mem.Allocator,
) -> (value: string, ok: bool) {
	// `algorithm` is optional and `alg` is the upper-cased spelling requests
	// switches on: an absent one means MD5 (`_algorithm = "MD5"`), and only the
	// two MD5 spellings have a hash here.
	algorithm := challenge.algorithm
	if algorithm == "" {
		algorithm = "MD5"
	}
	if !strings.equal_fold(algorithm, "MD5") && !strings.equal_fold(algorithm, "MD5-SESS") {
		return "", false
	}
	sess := strings.equal_fold(algorithm, "MD5-SESS")

	// httpie hands the plugin the `user:pass` split at the first colon
	// (`parse_auth`, httpie/cli/argtypes.py:168-191); a value with no colon has
	// the empty password, which is what `AuthCredentials(auth, None)` turns into
	// when the password is prompted for.
	username := credentials
	password := ""
	if colon := strings.index_byte(credentials, ':'); colon >= 0 {
		username = credentials[:colon]
		password = credentials[colon + 1:]
	}

	ha1: [MD5_HEX_SIZE]u8
	md5_hex_join({username, ":", challenge.realm, ":", password}, &ha1)
	ha2: [MD5_HEX_SIZE]u8
	md5_hex_join({method, ":", target}, &ha2)

	// The client's nonce and the count of requests made with the server's:
	// `nonce_count` restarts at 1 because the nonce of a fresh challenge is not
	// the one already answered for, and `f"{1:08x}"` is what goes in the header.
	nc := "00000001"
	// The parameter is an array — a value, so not addressable — and the header
	// is built out of slices of it.
	client_nonce := cnonce

	if sess {
		sess_ha1: [MD5_HEX_SIZE]u8
		md5_hex_join({string(ha1[:]), ":", challenge.nonce, ":", string(client_nonce[:])}, &sess_ha1)
		ha1 = sess_ha1
	}

	response: [MD5_HEX_SIZE]u8
	switch {
	case challenge.qop == "":
		// No qop at all: RFC 2069's answer, `KD(HA1, f"{nonce}:{HA2}")`.
		md5_hex_join({string(ha1[:]), ":", challenge.nonce, ":", string(ha2[:])}, &response)
	case digest_qop_is_auth(challenge.qop):
		md5_hex_join(
			{string(ha1[:]), ":", challenge.nonce, ":", nc, ":", string(client_nonce[:]), ":auth:", string(ha2[:])},
			&response,
		)
	case:
		// qop that is not `auth` — `auth-int` above all: requests has no
		// `entdig` and returns None, so no request is authenticated.
		return "", false
	}

	buffer := buffer_make(allocator, 192)
	appended := buffer_append_string(&buffer, `Digest username="`) &&
	            buffer_append_string(&buffer, username) &&
	            buffer_append_string(&buffer, `", realm="`) &&
	            buffer_append_string(&buffer, challenge.realm) &&
	            buffer_append_string(&buffer, `", nonce="`) &&
	            buffer_append_string(&buffer, challenge.nonce) &&
	            buffer_append_string(&buffer, `", uri="`) &&
	            buffer_append_string(&buffer, target) &&
	            buffer_append_string(&buffer, `", response="`) &&
	            buffer_append_string(&buffer, string(response[:])) &&
	            buffer_append_byte(&buffer, '"')
	if challenge.opaque != "" {
		appended = appended &&
		           buffer_append_string(&buffer, `, opaque="`) &&
		           buffer_append_string(&buffer, challenge.opaque) &&
		           buffer_append_byte(&buffer, '"')
	}
	if challenge.algorithm != "" {
		appended = appended &&
		           buffer_append_string(&buffer, `, algorithm="`) &&
		           buffer_append_string(&buffer, challenge.algorithm) &&
		           buffer_append_byte(&buffer, '"')
	}
	if challenge.qop != "" {
		appended = appended &&
		           buffer_append_string(&buffer, `, qop="auth", nc=`) &&
		           buffer_append_string(&buffer, nc) &&
		           buffer_append_string(&buffer, `, cnonce="`) &&
		           buffer_append_string(&buffer, string(client_nonce[:])) &&
		           buffer_append_byte(&buffer, '"')
	}
	if !appended {
		buffer_destroy(&buffer)
		return "", false
	}
	return string(buffer_owned(&buffer)), true
}

// digest_qop_is_auth is requests' `qop == "auth" or "auth" in qop.split(",")`:
// the whole value, or one of its comma-separated elements, spelled `auth`. The
// test is case-sensitive and the split does not strip.
@(private = "file")
digest_qop_is_auth :: proc(qop: string) -> bool {
	rest := qop
	for {
		comma := strings.index_byte(rest, ',')
		element := comma >= 0 ? rest[:comma] : rest
		if element == "auth" {
			return true
		}
		if comma < 0 {
			return false
		}
		rest = rest[comma + 1:]
	}
}

// digest_request_target is the request target the answer is computed over: the
// path and the query, which is requests' `urlparse(url).path or "/"` plus
// `f"?{query}"`, read off the URL the connection is pointed at so the server's
// own view of the target is the one hashed. The fragment is never sent and is
// not part of it.
@(private = "file")
digest_request_target :: proc(url: string) -> string {
	rest := url
	if scheme_end := strings.index(rest, "://"); scheme_end >= 0 {
		rest = rest[scheme_end + len("://"):]
	}
	slash := strings.index_byte(rest, '/')
	target := slash >= 0 ? rest[slash:] : "/"
	if hash := strings.index_byte(target, '#'); hash >= 0 {
		target = target[:hash]
	}
	return target
}

// digest_cnonce is the 16 lowercase hex characters requests' cnonce is
// (`sha1(...).hexdigest()[:16]`, built out of the nonce count, the nonce, the
// time and `os.urandom(8)`). The value is random on both roads: it is the
// client's own nonce, and all the server does with it is feed it back into the
// response hash both sides compute.
@(private = "file")
digest_cnonce :: proc() -> [16]u8 {
	cnonce: [16]u8
	digits := "0123456789abcdef"
	value := rand.uint64()
	for index in 0 ..< 16 {
		cnonce[index] = digits[(value >> u64((15 - index) * 4)) & 0x0f]
	}
	return cnonce
}
