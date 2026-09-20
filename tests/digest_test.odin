// The Digest handshake's own two halves, unit by unit:
//
//   * MD5, against RFC 1321's test suite and around the padding boundaries;
//   * the challenge parse, against the fixture's value and the shapes
//     `requests`' `parse_dict_header` reads;
//   * the answer, against the **reference's own bytes** — every expected header
//     below was produced by `requests.auth.HTTPDigestAuth.build_digest_header`
//     with the cnonce pinned, which is what makes it comparable at all
//     (build/t_c182381a_digest_vectors.py). The end-to-end half — two requests,
//     the challenge's body discarded, the answer on the wire where the
//     reference puts it — is in tests/http_engine_test.odin and the parity
//     rows (docs/PARITY.md §4.1).
package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:http"

@(test)
test_md5_matches_the_rfc1321_vectors :: proc(t: ^testing.T) {
	// RFC 1321's own test suite (appendix A.5).
	cases := [?]struct {
		input:    string,
		expected: string,
	}{
		{"", "d41d8cd98f00b204e9800998ecf8427e"},
		{"a", "0cc175b9c0f1b6a831c399e269772661"},
		{"abc", "900150983cd24fb0d6963f7d28e17f72"},
		{"message digest", "f96b697d7cb7938d525a2f31aaf161d0"},
		{"abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"},
		{"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
		 "d174ab98d277d9f5a5611c2c9f419d9f"},
		{"12345678901234567890123456789012345678901234567890123456789012345678901234567890",
		 "57edf4a22be3c955ac49da2e2107b67a"},
	}
	for vector in cases {
		hex: [http.MD5_HEX_SIZE]u8
		http.md5_hex_join({vector.input}, &hex)
		testing.expectf(t, string(hex[:]) == vector.expected, "%q: got %s, want %s",
		                vector.input, string(hex[:]), vector.expected)
	}
}

@(test)
test_md5_hashes_across_the_padding_boundaries :: proc(t: ^testing.T) {
	// The lengths the padding rule turns on — a message whose 0x80 still fits
	// in the block (55), one that lands exactly on the 8 length bytes (56), one
	// that needs a whole extra block (57), the block itself and one past it —
	// plus a multi-block input. Expected values from Python's `hashlib.md5`.
	cases := [?]struct {
		length:   int,
		expected: string,
	}{
		{55, "04364420e25c512fd958a70738aa8f72"},
		{56, "668a72d5ba17f08e62dabcafad6db14b"},
		{57, "693037871c4a9d3d8685018905cb530a"},
		{64, "c1bb4f81d892b2d57947682aeb252456"},
		{65, "1bc932052302d074bdec39795fe00cf6"},
		{1000, "398533d48111e9f664b1f64cb10c4b63"},
	}
	for vector in cases {
		input := make([]u8, vector.length, context.allocator)
		defer delete(input)
		for &byte in input {
			byte = 'x'
		}
		hex: [http.MD5_HEX_SIZE]u8
		http.md5_hex_join({string(input)}, &hex)
		testing.expectf(t, string(hex[:]) == vector.expected, "%d bytes: got %s, want %s",
		                vector.length, string(hex[:]), vector.expected)
	}

	// The two strings the answer is built out of, spelled the way requests
	// spells them (`f"{user}:{realm}:{pass}"` and `f"{method}:{path}"`).
	hex: [http.MD5_HEX_SIZE]u8
	http.md5_hex_join({"user", ":", "parity", ":", "pass"}, &hex)
	testing.expect_value(t, string(hex[:]), "56812fa18440daa57852294522591392")
	http.md5_hex_join({"GET", ":", "/auth/digest"}, &hex)
	testing.expect_value(t, string(hex[:]), "16fe6fddb0c7ea3fa80dfe00a5f9a7be")
}

@(test)
test_digest_challenge_parse_reads_the_fixtures_challenge :: proc(t: ^testing.T) {
	// The value tests/parity/server.py's `/auth/digest` sends.
	value := `Digest realm="parity", qop="auth", nonce="deterministic-nonce-0001", opaque="deterministic-opaque", algorithm=MD5`
	challenge, ok := http.digest_challenge_parse(value)
	testing.expect(t, ok, "the fixture's challenge must parse")
	testing.expect_value(t, challenge.realm, "parity")
	testing.expect_value(t, challenge.nonce, "deterministic-nonce-0001")
	testing.expect_value(t, challenge.qop, "auth")
	testing.expect_value(t, challenge.opaque, "deterministic-opaque")
	testing.expect_value(t, challenge.algorithm, "MD5")

	// `handle_401` looks for `digest` anywhere in the value, case-insensitively,
	// and strips the first `digest ` it finds: the spelling of the scheme and
	// the whitespace around the pairs are not part of the challenge.
	spelled := [?]string{
		`digest realm="parity",nonce="n"`,
		`DIGEST realm="parity", nonce="n"`,
		`Digest   realm="parity",   nonce="n"   `,
	}
	for candidate in spelled {
		parsed, parsed_ok := http.digest_challenge_parse(candidate)
		testing.expectf(t, parsed_ok, "%s must parse", candidate)
		testing.expect_value(t, parsed.realm, "parity")
		testing.expect_value(t, parsed.nonce, "n")
	}

	// A quoted value may carry a comma, which is not a separator: the realm is
	// one field, comma and all (`parse_http_list`'s whole reason to exist).
	comma, comma_ok := http.digest_challenge_parse(`Digest realm="a,b", nonce="n", stale=true`)
	testing.expect(t, comma_ok, "a quoted comma must not split the value")
	testing.expect_value(t, comma.realm, "a,b")
	testing.expect_value(t, comma.nonce, "n")

	// A name that appears twice: the dict keeps the last one.
	twice, twice_ok := http.digest_challenge_parse(`Digest realm="one", realm="two", nonce="n"`)
	testing.expect(t, twice_ok, "a repeated field must still parse")
	testing.expect_value(t, twice.realm, "two")
}

@(test)
test_digest_challenge_parse_refuses_what_it_cannot_answer :: proc(t: ^testing.T) {
	// No Digest scheme at all.
	_, basic_ok := http.digest_challenge_parse(`Basic realm="parity"`)
	testing.expect(t, !basic_ok, "a Basic challenge is not a Digest one")

	// `digest` with no space after it is not the scheme `handle_401`'s regex
	// strips (and requests raises KeyError on the garbage that is left).
	_, bare_ok := http.digest_challenge_parse(`Digest`)
	testing.expect(t, !bare_ok, "a scheme token with no parameters is not a challenge")

	// A challenge without the two fields the answer is computed over.
	_, no_nonce := http.digest_challenge_parse(`Digest realm="parity", qop="auth"`)
	testing.expect(t, !no_nonce, "a challenge without a nonce cannot be answered")
	_, no_realm := http.digest_challenge_parse(`Digest nonce="n", qop="auth"`)
	testing.expect(t, !no_realm, "a challenge without a realm cannot be answered")
}

// The reference's own headers, from
// build/t_c182381a_digest_vectors.py: `build_digest_header` with the cnonce
// pinned to the value of the case (its sha1 mixes in `os.urandom`, which the
// script fixes). Every field, its order and its quoting are the reference's.
@(test)
test_digest_header_matches_the_references_bytes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cnonce: [16]u8
	copy(cnonce[:], "c31c39ea62a5d558")

	cases := [?]struct {
		challenge: string,
		method:    string,
		target:    string,
		expected:  string,
	}{
		{
			`Digest realm="parity", qop="auth", nonce="deterministic-nonce-0001", opaque="deterministic-opaque", algorithm=MD5`,
			"GET",
			"/auth/digest",
			`Digest username="user", realm="parity", nonce="deterministic-nonce-0001", uri="/auth/digest", response="a8c969fb8602a3f6892836e39be487ab", opaque="deterministic-opaque", algorithm="MD5", qop="auth", nc=00000001, cnonce="c31c39ea62a5d558"`,
		},
		{
			`Digest realm="parity", nonce="deterministic-nonce-0001"`,
			"GET",
			"/auth/digest",
			`Digest username="user", realm="parity", nonce="deterministic-nonce-0001", uri="/auth/digest", response="26b1bf0d7f50e7d88fcd34fbe8710308"`,
		},
		{
			// MD5-sess: HA1 is hashed again with the nonce and the cnonce, and
			// the header spells the algorithm the way the challenge did.
			`Digest realm="parity", qop="auth", nonce="deterministic-nonce-0001", algorithm="MD5-sess"`,
			"POST",
			"/auth/digest",
			`Digest username="user", realm="parity", nonce="deterministic-nonce-0001", uri="/auth/digest", response="f3122e0286c2c322be2be10a65817a9c", algorithm="MD5-sess", qop="auth", nc=00000001, cnonce="c31c39ea62a5d558"`,
		},
		{
			// No `algorithm` at all means MD5, and the query is part of the
			// target that is hashed.
			`Digest realm="parity", qop="auth", nonce="deterministic-nonce-0001", opaque="opaque"`,
			"HEAD",
			"/auth/digest?q=1",
			`Digest username="user", realm="parity", nonce="deterministic-nonce-0001", uri="/auth/digest?q=1", response="951fde7d03ec5c5800f04292f564c4ed", opaque="opaque", qop="auth", nc=00000001, cnonce="c31c39ea62a5d558"`,
		},
	}

	for vector in cases {
		challenge, parsed := http.digest_challenge_parse(vector.challenge)
		testing.expectf(t, parsed, "%s must parse", vector.challenge)
		if !parsed {
			continue
		}
		header, answered := http.digest_authorization(challenge, "user:pass", vector.method, vector.target, cnonce, allocator)
		testing.expectf(t, answered, "%s must be answerable", vector.challenge)
		testing.expectf(t, header == vector.expected, "%s:\n got %s\nwant %s",
		                vector.challenge, header, vector.expected)
		delete(header, allocator)
	}

	// The realm with a comma in it, whose cnonce is a different one: the nonce
	// it is mixed with is `n`.
	comma_challenge, comma_ok := http.digest_challenge_parse(`Digest realm="a,b", qop=auth, nonce="n", stale=true`)
	testing.expect(t, comma_ok, "the comma realm must parse")
	if comma_ok {
		comma_cnonce: [16]u8
		copy(comma_cnonce[:], "130d0b17a1d1f4e2")
		header, answered := http.digest_authorization(comma_challenge, "user:pass", "GET", "/x", comma_cnonce, allocator)
		testing.expect(t, answered, "an unquoted qop=auth must be answered")
		if answered {
			testing.expect_value(t, header,
			                    `Digest username="user", realm="a,b", nonce="n", uri="/x", response="5686ae3fc9e0c09c177db7f0d59ad545", qop="auth", nc=00000001, cnonce="130d0b17a1d1f4e2"`)
			delete(header, allocator)
		}
	}

	expect_no_leaks(t, &track)
}

@(test)
test_digest_header_refuses_what_requests_refuses :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cnonce: [16]u8
	copy(cnonce[:], "c31c39ea62a5d558")

	// `qop=auth-int` has no `entdig` in requests either: `build_digest_header`
	// answers None, and the port answers nothing.
	auth_int, parsed := http.digest_challenge_parse(`Digest realm="parity", qop="auth-int", nonce="n"`)
	testing.expect(t, parsed, "the auth-int challenge parses")
	if parsed {
		_, answered := http.digest_authorization(auth_int, "user:pass", "GET", "/x", cnonce, allocator)
		testing.expect(t, !answered, "auth-int has no answer here")
	}

	// An algorithm with no hash behind it: requests has SHA-256, the port does
	// not (docs/PARITY.md §4.1) and refuses the challenge instead of answering
	// it wrongly.
	sha, sha_ok := http.digest_challenge_parse(`Digest realm="parity", qop="auth", nonce="n", algorithm=SHA-256`)
	testing.expect(t, sha_ok, "the SHA-256 challenge parses")
	if sha_ok {
		_, answered := http.digest_authorization(sha, "user:pass", "GET", "/x", cnonce, allocator)
		testing.expect(t, !answered, "SHA-256 is not a hash the port computes")
	}

	expect_no_leaks(t, &track)
}

@(test)
test_digest_answer_for_hashes_the_wire_target :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The verb and the target of the *wire* request are the pair the server
	// hashes, so both come off the hop: the caller's spelling of the verb
	// (`method_raw`) and the path plus query of the URL the connection is
	// pointed at. The scheme, the authority and any fragment are not part of
	// it.
	exchange := http.Exchange {
		status = 401,
		headers = []http.Header {
			{name = "WWW-Authenticate", value = `Digest realm="parity", qop="auth", nonce="n"`},
		},
	}
	hop := http.Hop {
		method     = .GET,
		method_raw = "GET",
		url        = "http://127.0.0.1:9/auth/digest?q=1",
		wire_url   = "http://127.0.0.1:9/auth/digest?q=1",
	}

	answer, answered := http.digest_answer_for(hop, &exchange, "user:pass", allocator)
	testing.expect(t, answered, "a 401 with a Digest challenge must be answered")
	if answered {
		testing.expectf(t, strings.contains(answer, `uri="/auth/digest?q=1"`),
		                "the query must be in the target: %s", answer)
		delete(answer, allocator)
	}

	// A 200, a 4xx with no challenge, and a 5xx are all the caller's reply.
	ok_reply := http.Exchange {
		status = 200,
	}
	_, answered_ok := http.digest_answer_for(hop, &ok_reply, "user:pass", allocator)
	testing.expect(t, !answered_ok, "a 200 is not a challenge")
	no_challenge := http.Exchange {
		status  = 403,
		headers = []http.Header{{name = "Content-Type", value = "text/plain"}},
	}
	_, answered_none := http.digest_answer_for(hop, &no_challenge, "user:pass", allocator)
	testing.expect(t, !answered_none, "a 4xx without a Digest challenge is not one")
	failure := http.Exchange {
		status  = 503,
		headers = []http.Header{{name = "WWW-Authenticate", value = `Digest realm="parity", nonce="n"`}},
	}
	_, answered_failure := http.digest_answer_for(hop, &failure, "user:pass", allocator)
	testing.expect(t, !answered_failure, "`handle_401` only answers a 4xx")

	expect_no_leaks(t, &track)
}
