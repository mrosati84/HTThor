// Auth: the Authorization header httpie puts on the wire.
//
//   basic   preemptive `Authorization: Basic base64(user:pass)` — the header is
//           built here, so `--offline -p H` shows it (capture
//           `offline-auth-basic`)
//   bearer  preemptive `Authorization: Bearer <token>` (capture
//           `offline-auth-bearer`)
//   digest  NO header: digest needs the server's challenge first, so libcurl
//           answers the 401 (capture `offline-auth-digest` shows no header in
//           --offline mode)
package http

import "core:encoding/base64"
import "core:strings"

// authorization_header builds the preemptive Authorization header. The second
// result is false when there is nothing to send: no credentials, or a scheme
// whose header can only be produced after a challenge (digest). The caller owns
// the returned string.
authorization_header :: proc(req: ^Request) -> (authorization: string, applicable: bool) {
	credentials := request_credentials(req)
	// There are credentials whenever `--auth` named some *or* the URL spelled a
	// userinfo at all: `http://@host/` is `urlsplit(url).username == ''`, which
	// httpie takes as the credentials `:` (cli/argparser.py:289-299,
	// `password or ''`), where a URL without an `@` leaves `username` None and
	// gets no header.
	if (credentials == "" && !req.userinfo_present) || req.auth_type == .Digest {
		return "", false
	}
	switch req.auth_type {
	case .Basic:
		return basic_authorization(req, credentials)
	case .Bearer:
		// httpie's bearer plugin sends the value of --auth as the token.
		if bearer, err := strings.concatenate({"Bearer ", credentials}, req.allocator); err == .None {
			return bearer, true
		}
		return "", false
	case .Digest:
		return "", false
	}
	return "", false
}

// basic_authorization is httpie's Basic scheme: base64("user:pass"). When the
// credentials carry no colon, httpie prompts for a password; the engine has no
// terminal, so it sends an empty one (documented in docs/ARCHITECTURE.md).
//
// The plugin encodes the credentials with the default codec *before* it
// base64-encodes them (plugins/builtin.py:31-34: `b64encode(credentials.encode())`),
// so a credential that is not valid UTF-8 raises there, with the offending
// character's index in the "user:pass" string. The check mirrors that: it sees
// the same string the reference encodes — the credentials with the ':' httpie
// appends to a passwordless pair included.
basic_authorization :: proc(req: ^Request, credentials: string) -> (string, bool) {
	// Note the scope of the defer: Odin runs a deferred statement when its
	// *block* ends, so a `defer` inside the `if` below would free the string
	// while `to_encode` still needed it.
	with_colon: string
	defer delete(with_colon, req.allocator)

	to_encode := credentials
	if !strings.contains(credentials, ":") {
		clone, concat_err := strings.concatenate({credentials, ":"}, req.allocator)
		if concat_err != .None {
			return "", false
		}
		with_colon = clone
		to_encode = with_colon
	}

	if err := request_encode_check(req, to_encode, .Utf8); err != .None {
		return "", false
	}

	encoded, encode_err := base64.encode(transmute([]u8)to_encode, allocator = req.allocator)
	if encode_err != .None {
		return "", false
	}
	defer delete(encoded, req.allocator)

	header, header_err := strings.concatenate({"Basic ", encoded}, req.allocator)
	if header_err != .None {
		return "", false
	}
	return header, true
}
