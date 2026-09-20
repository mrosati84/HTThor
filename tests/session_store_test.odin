// Session persistence: the bytes of the JSON session file and the cookie jar
// that travels in it (docs/PARITY.md §6.3).
//
// The file's byte contract is the reference's own `save()`:
// `json.dumps(..., indent=4, sort_keys=True, ensure_ascii=True)` plus one
// newline. The tests below compare oj's file with the file the *reference* wrote
// during the capture, kept in the tree at `tests/fixtures/sessions/`, so a
// formatting drift fails here rather than only in the parity harness.
//
// Cleanup is explicit rather than `defer`red: expect_no_leaks runs at the end of
// each body, and a deferred free would land after it.
package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "src:cli"
import "src:http"
import "src:output"
import "src:session"

// SESSION_CAPTURE_DIR is where the reference's own session files live
// (docs/PARITY.md §6.3): two captures copied out of the old reference-capture
// sandbox into the tree so the tests do not depend on it.
@(private)
SESSION_CAPTURE_DIR :: "tests/fixtures/sessions"

// ---------------------------------------------------------------------------
// The `session-write` scenario
// ---------------------------------------------------------------------------

// The file oj writes for `--session=cap1` must be the reference's file, byte
// for byte: same key order (sort_keys puts `__meta__` first), same four-space
// indentation, same trailing newline — and the same 0700 directory. The file
// mode is the port's own 0600 rather than the reference's 0644: a deliberate
// divergence, recorded at SESSION_FILE_MODE (store.odin) and in
// docs/security-findings.md SF-004.
@(test)
test_session_cap1_file_matches_the_reference_capture :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "cap1", allocator)

	// The `session-write` scenario, without the exchange: --offline still builds
	// the request the session records, and still writes the file
	// (client.py:136-140).
	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	argv := []string{
		"oj",
		"--session=cap1",
		"--offline",
		"-p", "hb",
		"--pretty=none",
		"POST", "http://127.0.0.1:8765/echo",
		"X-Session-Header:keepme",
		"a=1",
	}
	exit_code := run_session(t, argv, sandbox, &out, &err_out, allocator)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))
	testing.expectf(t, strings.to_string(err_out) == "", "stderr: %q", strings.to_string(err_out))

	written, written_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/127.0.0.1_8765/cap1.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(t, written_err == nil, "the session file was not written: %v", written_err)
	want, want_err := os.read_entire_file(
		fmt.aprintf("%s/cap1.json", SESSION_CAPTURE_DIR, allocator = context.temp_allocator),
		context.temp_allocator,
	)
	testing.expectf(
		t,
		want_err == nil,
		"%s/cap1.json is missing (the test runs from the repository root)",
		SESSION_CAPTURE_DIR,
	)
	if written_err == nil && want_err == nil {
		testing.expectf(
			t,
			string(written) == string(want),
			"the session file differs from the reference's:\n--- reference\n%s\n--- oj\n%s",
			string(want),
			string(written),
		)
	}

	// The reference's own directory mode (`mkdir(mode=0o700)`), and the port's
	// file mode: 0600, a deliberate divergence from the reference's 0644
	// (SESSION_FILE_MODE, store.odin; docs/security-findings.md SF-004).
	directory, directory_err := os.stat(
		fmt.aprintf(
			"%s/config/sessions/127.0.0.1_8765",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	if directory_err == nil {
		testing.expectf(
			t,
			directory.mode == os.Permissions{.Read_User, .Write_User, .Execute_User},
			"session directory mode is %v, want 0700",
			directory.mode,
		)
	}
	file, file_err := os.stat(
		fmt.aprintf(
			"%s/config/sessions/127.0.0.1_8765/cap1.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	if file_err == nil {
		testing.expectf(
			t,
			file.mode == os.Permissions{.Read_User, .Write_User},
			"session file mode is %v, want 0600",
			file.mode,
		)
	}

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// A session file an older build (or httpie) left at 0644 is tightened by the
// next save: the mode argument of `write_entire_file_from_bytes` only applies
// when the file is created, so session_save chmods afterwards (SF-004). Red
// with the constant alone, green with the chmod.
@(test)
test_session_save_tightens_an_existing_0644_file :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "tighten", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// The same offline write the cap1 case makes, with the file already there
	// and world-readable — the state a 3.2-era oj or httpie leaves behind.
	session_seed(t, sandbox, "cap1.json", "cap1.json")
	path := fmt.aprintf(
		"%s/config/sessions/127.0.0.1_8765/cap1.json",
		sandbox,
		allocator = context.temp_allocator,
	)
	testing.expectf(
		t,
		os.chmod(path, os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}) == nil,
		"cannot widen %s to 0644 for the test",
		path,
	)

	argv := []string{
		"oj",
		"--session=cap1",
		"--offline",
		"-p", "hb",
		"--pretty=none",
		"POST", "http://127.0.0.1:8765/echo",
		"a=1",
	}
	exit_code := run_session(t, argv, sandbox, &out, &err_out, allocator)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	file, file_err := os.stat(path, context.temp_allocator)
	testing.expectf(t, file_err == nil, "cannot stat the session file: %v", file_err)
	if file_err == nil {
		testing.expectf(
			t,
			file.mode == os.Permissions{.Read_User, .Write_User},
			"a 0644 session file must be tightened on save, mode is %v",
			file.mode,
		)
	}

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// Reading a session back
// ---------------------------------------------------------------------------

// `--session-read-only` is a read: the headers the file holds join the request
// (the rendered head carries the persisted `X-Session-Header`), and the file is
// left exactly as it was.
@(test)
test_session_read_only_reads_the_file_back :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "readonly", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	session_seed(t, sandbox, "cap1.json", "cap1.json")
	want, want_err := os.read_entire_file(
		fmt.aprintf("%s/cap1.json", SESSION_CAPTURE_DIR, allocator = context.temp_allocator),
		context.temp_allocator,
	)
	testing.expectf(t, want_err == nil, "%s/cap1.json is missing", SESSION_CAPTURE_DIR)
	if want_err != nil {
		session_teardown(sandbox, &out, &err_out, allocator)
		expect_no_leaks(t, &track)
		return
	}
	path := fmt.aprintf(
		"%s/config/sessions/127.0.0.1_8765/cap1.json",
		sandbox,
		allocator = context.temp_allocator,
	)

	argv := []string{
		"oj",
		"--session-read-only=cap1",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"POST", "http://127.0.0.1:8765/echo",
		"b=2",
	}
	exit_code := run_session(t, argv, sandbox, &out, &err_out, allocator)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	rendered := strings.to_string(out)
	testing.expectf(
		t,
		strings.contains(rendered, "\r\nX-Session-Header: keepme\r\n"),
		"the persisted header is not on the wire:\n%q",
		rendered,
	)

	// A read-only run leaves the file alone (client.py:137: it is written only
	// when the session is new).
	after, after_err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, after_err == nil, "the session file disappeared: %v", after_err)
	if after_err == nil {
		testing.expectf(
			t,
			string(after) == string(want),
			"--session-read-only rewrote the file:\n%s",
			string(after),
		)
	}

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// The other half of `is_new() or not session_read_only`: a read-only run whose
// file does not exist yet still creates it.
@(test)
test_session_read_only_creates_a_missing_file :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "readonly-new", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	argv := []string{
		"oj",
		"--session-read-only=never",
		"--offline",
		"-p", "h",
		"--pretty=none",
		"http://127.0.0.1:8765/json",
	}
	exit_code := run_session(t, argv, sandbox, &out, &err_out, allocator)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	_, read_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/127.0.0.1_8765/never.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(t, read_err == nil, "a read-only run over a missing file must create it")

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// The cookie jar
// ---------------------------------------------------------------------------

// The jar the fixture's `Set-Cookie: BODY=deterministic-cookie; Path=/; HttpOnly`
// leaves behind, as the file and as the next request's `Cookie` header. The bytes
// are the reference's `cap-cookie.json`; the header is the one the
// `session-cookie-replay` scenario sends.
@(test)
test_session_cookie_jar_replays_a_set_cookie :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "cookie", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// Start from the reference's own file: the headers it recorded for the
	// scenario are the ones the cookies must travel next to.
	session_seed(t, sandbox, "cap-cookie.json", "cap-cookie.json")

	argv := []string{
		"oj",
		"--session=cap-cookie",
		"--offline",
		"-p", "h",
		"--pretty=none",
		"http://127.0.0.1:8765/cookie",
	}
	options, parse_err := session_options(t, argv, sandbox, allocator)
	testing.expect_value(t, parse_err.kind, cli.Parse_Error_Kind.None)
	session_instance, opened := session.session_open(&options, output.Console{writer = strings.to_writer(&err_out), width = cli.RICH_WIDTH}, allocator)
	cli.options_destroy(&options)
	testing.expectf(t, opened, "the session could not be opened: %s", strings.to_string(err_out))
	if !opened {
		session_teardown(sandbox, &out, &err_out, allocator)
		expect_no_leaks(t, &track)
		return
	}
	testing.expectf(
		t,
		len(session_instance.headers) == 1,
		"the reference's file did not hand its headers over (%d stored)",
		len(session_instance.headers),
	)

	// The reply the fixture sends for /cookie.
	response := http.Response {
		status  = 200,
		headers = []http.Header{{name = "Set-Cookie", value = "BODY=deterministic-cookie; Path=/; HttpOnly"}},
		url     = "http://127.0.0.1:8765/cookie",
	}
	session.session_collect_cookies(&session_instance, &response)
	testing.expectf(
		t,
		len(session_instance.cookies) == 1,
		"the jar holds %d cookies",
		len(session_instance.cookies),
	)

	// The next request to the same host replays it.
	request, request_err := http.request_create(allocator, .POST, "http://127.0.0.1:8765/echo")
	testing.expect_value(t, request_err, http.Error.None)
	session.session_apply_cookies(&session_instance, &request)
	cookie, found := http.request_header_get(&request, "Cookie")
	testing.expectf(t, found, "no Cookie header was added")
	testing.expectf(t, cookie == "BODY=deterministic-cookie", "Cookie: %q", cookie)
	http.request_destroy(&request)

	// And the file is the reference's.
	testing.expectf(t, session.session_finish(&session_instance, &response), "the session file was not written")
	written, written_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/127.0.0.1_8765/cap-cookie.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(t, written_err == nil, "the session file was not written: %v", written_err)
	want, want_err := os.read_entire_file(
		fmt.aprintf("%s/cap-cookie.json", SESSION_CAPTURE_DIR, allocator = context.temp_allocator),
		context.temp_allocator,
	)
	testing.expectf(t, want_err == nil, "%s/cap-cookie.json is missing", SESSION_CAPTURE_DIR)
	if written_err == nil && want_err == nil {
		testing.expectf(
			t,
			string(written) == string(want),
			"the cookie file differs from the reference's:\n--- reference\n%s\n--- oj\n%s",
			string(want),
			string(written),
		)
	}

	session.session_destroy(&session_instance)
	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// session_cookie_value is the jar's policy in one call — the rule a followed
// hop's `Cookie` header is re-derived through (http.Cookie_Hook, SF-001) — so it
// is pinned directly here as well as on the wire.
@(test)
test_session_cookie_value_respects_domain_path_and_secure :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "cookie-value", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	argv := []string{
		"oj",
		"--session=cookie-value",
		"--offline",
		"-p", "h",
		"--pretty=none",
		"http://example.com/echo",
	}
	options, parse_err := session_options(t, argv, sandbox, allocator)
	testing.expect_value(t, parse_err.kind, cli.Parse_Error_Kind.None)
	session_instance, opened := session.session_open(&options, output.Console{writer = strings.to_writer(&err_out), width = cli.RICH_WIDTH}, allocator)
	cli.options_destroy(&options)
	testing.expectf(t, opened, "the session could not be opened: %s", strings.to_string(err_out))
	if !opened {
		session_teardown(sandbox, &out, &err_out, allocator)
		expect_no_leaks(t, &track)
		return
	}

	// One host-only Secure cookie under /private, one plain cookie under
	// /public, and one plain cookie for every path — the three together pin the
	// domain, the path and the Secure rule, and the longest-path-first order.
	// The host is a name, not a loopback address: `is_local_host` keeps a Secure
	// cookie travelling over plain http to localhost, which would hide the
	// Secure rule below.
	response := http.Response {
		status  = 200,
		headers = []http.Header {
			{name = "Set-Cookie", value = "SESS=JARSECRET; Path=/private; Secure"},
			{name = "Set-Cookie", value = "PLAIN=1; Path=/public"},
			{name = "Set-Cookie", value = "ROOT=1; Path=/"},
		},
		url = "http://example.com/echo",
	}
	session.session_collect_cookies(&session_instance, &response)
	testing.expectf(t, len(session_instance.cookies) == 3, "the jar holds %d cookies", len(session_instance.cookies))

	cases := [?]struct {
		what:   string,
		host:   string,
		path:   string,
		secure: bool,
		want:   string,
	}{
		{"the stored host, the Secure cookie's own path, https", "example.com", "/private", true, "SESS=JARSECRET; ROOT=1"},
		{"a path below the cookie's own is a match", "example.com", "/private/x", true, "SESS=JARSECRET; ROOT=1"},
		{"a Secure cookie over plain http", "example.com", "/private", false, "ROOT=1"},
		{"a path outside the cookie's own", "example.com", "/other", true, "ROOT=1"},
		{"the whole host", "example.com", "/", true, "ROOT=1"},
		{"the other cookie's path", "example.com", "/public", false, "PLAIN=1; ROOT=1"},
		{"another host", "other.example.com", "/private", true, ""},
		{"another host, any path", "other.example.com", "/", true, ""},
	}
	for test_case in cases {
		value := session.session_cookie_value(
			&session_instance,
			test_case.host,
			test_case.path,
			test_case.secure,
			allocator,
		)
		testing.expectf(t, value == test_case.want, "%s: got %q, want %q", test_case.what, value, test_case.want)
		delete(value, allocator)
	}

	session.session_destroy(&session_instance)
	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// A cookie that has already expired is not persisted, and one that expires in a
// later reply deletes the stored cookie (utils.get_expired_cookies).
@(test)
test_session_cookie_expiry_is_not_persisted :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "cookie-expiry", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	session_seed(t, sandbox, "cap-cookie.json", "gone.json")

	argv := []string{
		"oj",
		"--session=gone",
		"--offline",
		"-p", "h",
		"--pretty=none",
		"http://127.0.0.1:8765/cookie",
	}
	options, parse_err := session_options(t, argv, sandbox, allocator)
	testing.expect_value(t, parse_err.kind, cli.Parse_Error_Kind.None)

	session_instance, opened := session.session_open(&options, output.Console{writer = strings.to_writer(&err_out), width = cli.RICH_WIDTH}, allocator)
	cli.options_destroy(&options)
	testing.expectf(t, opened, "the session could not be opened")
	if !opened {
		session_teardown(sandbox, &out, &err_out, allocator)
		expect_no_leaks(t, &track)
		return
	}
	testing.expectf(
		t,
		len(session_instance.cookies) == 1,
		"the reference's cookie was not read back (%d in the jar)",
		len(session_instance.cookies),
	)

	// The reply that expires it: `remove_cookies` drops the stored entry, and the
	// file comes back without it.
	gone := http.Response {
		headers = []http.Header{{name = "Set-Cookie", value = "BODY=; Path=/; Max-Age=0"}},
		url     = "http://127.0.0.1:8765/cookie",
	}
	session.session_collect_cookies(&session_instance, &gone)
	testing.expectf(
		t,
		len(session_instance.cookies) == 0,
		"an expired cookie must delete the stored one, %d left",
		len(session_instance.cookies),
	)

	// A server-supplied expiry in the past is not stored either.
	past := http.Response {
		headers = []http.Header{{name = "Set-Cookie", value = "OLD=1; Path=/; Expires=Sun, 20 Sep 2020 04:52:00 GMT"}},
		url     = "http://127.0.0.1:8765/cookie",
	}
	session.session_collect_cookies(&session_instance, &past)
	testing.expectf(t, len(session_instance.cookies) == 0, "an expired Set-Cookie was stored")

	testing.expectf(t, session.session_finish(&session_instance, &gone), "the session file was not written")
	written, written_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/127.0.0.1_8765/gone.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	if testing.expectf(t, written_err == nil, "the session file is gone: %v", written_err) {
		testing.expectf(
			t,
			strings.contains(string(written), "\"cookies\": []"),
			"the expired cookie is still in the file:\n%s",
			string(written),
		)
		testing.expectf(
			t,
			strings.contains(string(written), "\"name\": \"Accept\""),
			"the headers were lost with the cookie:\n%s",
			string(written),
		)
	}

	session.session_destroy(&session_instance)
	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

// Both `auth` shapes are readable, and the legacy one authenticates the request
// that reads it (sessions.py:272-304).
@(test)
test_session_legacy_auth_is_applied :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "legacy-auth", allocator)

	legacy := `{
    "__meta__": {
        "httpie": "3.1.0"
    },
    "auth": {
        "password": "pass",
        "type": "basic",
        "username": "user"
    },
    "cookies": [],
    "headers": []
}
`
	seeded := fmt.aprintf(
		"%s/config/sessions/127.0.0.1_8765",
		sandbox,
		allocator = context.temp_allocator,
	)
	testing.expectf(
		t,
		os.make_directory_all(seeded, os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil,
		"cannot seed %s",
		seeded,
	)
	testing.expectf(
		t,
		os.write_entire_file_from_bytes(
			fmt.aprintf("%s/legacy.json", seeded, allocator = context.temp_allocator),
			transmute([]u8)legacy,
		) == nil,
		"cannot seed the legacy session file",
	)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	argv := []string{
		"oj",
		"--session=legacy",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"http://127.0.0.1:8765/json",
	}
	exit_code := run_session(t, argv, sandbox, &out, &err_out, allocator)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	rendered := strings.to_string(out)
	// `user:pass` base64 is `dXNlcjpwYXNz`.
	testing.expectf(
		t,
		strings.contains(rendered, "Authorization: Basic dXNlcjpwYXNz"),
		"the legacy credentials are not on the wire:\n%q",
		rendered,
	)

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// The path a named session lives at
// ---------------------------------------------------------------------------

// `<config>/sessions/<host>_<port>/<name>.json` is the URL's host:port with
// every `:` replaced by `_` (sessions.py:46-52, 92-121), so a URL with no port
// in it binds to the bare host — `example.org`, not the empty component. The
// port read `strings.replace_all`'s `was_allocation` as "did it work"
// (`or_else ""`), which collapsed that component and moved everything one
// directory up (`sessions//<name>.json`, which POSIX resolves to
// `sessions/<name>.json`): the file the reference wrote was never read back, and
// the port's own file landed where the reference never looks.
//
// The roads are the `session-host-dir-replay` and `session-host-dir-write`
// parity scenarios; this is the same thing without the harness.
@(test)
test_session_path_without_a_port_keeps_the_host_directory :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "host-dir", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// The reference's own file, at the reference's own directory for
	// `http://example.org/x`.
	session_seed_in_host_dir(t, sandbox, "example.org", "cap1.json", "cap-host.json")

	read_argv := []string{
		"oj",
		"--session-read-only=cap-host",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"GET", "http://example.org/x",
	}
	exit_code := run_session(t, read_argv, sandbox, &out, &err_out, allocator)
	testing.expectf(
		t,
		exit_code == int(cli.Exit_Code.Ok),
		"the read-only run exited %d: %s",
		exit_code,
		strings.to_string(err_out),
	)
	rendered := strings.to_string(out)
	testing.expectf(
		t,
		strings.contains(rendered, "X-Session-Header: keepme"),
		"the file at the URL's own directory was not read back:\n%q",
		rendered,
	)

	// A `--session=` run writes to that same directory...
	write_argv := []string{
		"oj",
		"--session=cap-host-new",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"GET", "http://example.org/x",
		"X-Note:keep",
	}
	exit_code = run_session(t, write_argv, sandbox, &out, &err_out, allocator)
	testing.expectf(
		t,
		exit_code == int(cli.Exit_Code.Ok),
		"the write run exited %d: %s",
		exit_code,
		strings.to_string(err_out),
	)
	written, written_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/example.org/cap-host-new.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(
		t,
		written_err == nil,
		"the session file was not written to the URL's directory: %v",
		written_err,
	)
	testing.expectf(
		t,
		written_err != nil || strings.contains(string(written), "X-Note"),
		"the written file does not hold the request's header:\n%s",
		string(written),
	)

	// ...and not one directory up, which is where the lost component put it.
	_, stray_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/cap-host-new.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(
		t,
		stray_err == .Not_Exist,
		"a session file landed one directory up as well (%v)",
		stray_err,
	)

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// The hostname that path is built *from* is `host or url_as_host(url)`
// (sessions.py:92-95). A `Host:` item leaves the CLI header dict's name falsy
// (the `None` an unset leaves), and a falsy `host` is no hostname at all: the
// reference *falls through* to the URL's own host. The port stopped at the item
// and answered `""`, which `session_location` turns into its `localhost`
// fallback — so a `Host:` run read and wrote `sessions/localhost/` where the
// reference uses `sessions/example.org/`.
//
// The roads are the `session-host-dir-host-item` and
// `session-host-dir-host-item-write(-replay)` parity scenarios.
@(test)
test_session_path_binds_a_falsy_host_item_to_the_url_host :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "falsy-host-item", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// The reference's own file, at the URL host's directory, for a run whose
	// argv carries an unset `Host:` item.
	session_seed_in_host_dir(t, sandbox, "example.org", "cap1.json", "cap-host-item.json")

	read_argv := []string{
		"oj",
		"--session-read-only=cap-host-item",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"GET", "http://example.org/x",
		"Host:",
	}
	exit_code := run_session(t, read_argv, sandbox, &out, &err_out, allocator)
	testing.expectf(
		t,
		exit_code == int(cli.Exit_Code.Ok),
		"the read-only run exited %d: %s",
		exit_code,
		strings.to_string(err_out),
	)
	rendered := strings.to_string(out)
	testing.expectf(
		t,
		strings.contains(rendered, "X-Session-Header: keepme"),
		"the falsy Host: item did not fall through to the URL host:\n%q",
		rendered,
	)

	// ...and a `--session=` run with the same item writes there too.
	write_argv := []string{
		"oj",
		"--session=cap-host-item-new",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"GET", "http://example.org/x",
		"Host:",
		"X-Note:keep",
	}
	exit_code = run_session(t, write_argv, sandbox, &out, &err_out, allocator)
	testing.expectf(
		t,
		exit_code == int(cli.Exit_Code.Ok),
		"the write run exited %d: %s",
		exit_code,
		strings.to_string(err_out),
	)
	written, written_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/example.org/cap-host-item-new.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(
		t,
		written_err == nil,
		"the session file was not written to the URL host's directory: %v",
		written_err,
	)
	testing.expectf(
		t,
		written_err != nil || strings.contains(string(written), "X-Note"),
		"the written file does not hold the request's header:\\n%s",
		string(written),
	)

	// ...and not in the `localhost` fallback, where the falsy item put it.
	_, stray_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/localhost/cap-host-item-new.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(
		t,
		stray_err == .Not_Exist,
		"the session file landed under the localhost fallback as well (%v)",
		stray_err,
	)

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// `url_as_host(url)` reads the URL the argparser's `_process_url` left behind,
// not argv (cli/argparser.py:205-225): a URL that named no scheme has the
// default one prepended to it before the session is bound, so `urlsplit` sees
// `http://example.org/x` and the host is `example.org`. The port read argv, and
// a scheme-less `example.org/x` has no authority for its own rule to find — so
// the session bound `localhost` and the reference's file was never read.
//
// The roads are the `session-host-dir-schemeless` and
// `session-host-dir-schemeless-write(-replay)` parity scenarios, plus
// `session-host-dir-default-scheme` for the scheme the rule prepends.
@(test)
test_session_path_binds_a_scheme_less_url_to_its_host :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	sandbox := session_sandbox(t, "scheme-less-url", allocator)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	session_seed_in_host_dir(t, sandbox, "example.org", "cap1.json", "cap-schemeless.json")

	read_argv := []string{
		"oj",
		"--session-read-only=cap-schemeless",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"GET", "example.org/x",
	}
	exit_code := run_session(t, read_argv, sandbox, &out, &err_out, allocator)
	testing.expectf(
		t,
		exit_code == int(cli.Exit_Code.Ok),
		"the read-only run exited %d: %s",
		exit_code,
		strings.to_string(err_out),
	)
	rendered := strings.to_string(out)
	testing.expectf(
		t,
		strings.contains(rendered, "X-Session-Header: keepme"),
		"the scheme-less URL did not read the URL host's directory:\n%q",
		rendered,
	)

	write_argv := []string{
		"oj",
		"--session=cap-schemeless-new",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"GET", "example.org/x",
		"X-Note:keep",
	}
	exit_code = run_session(t, write_argv, sandbox, &out, &err_out, allocator)
	testing.expectf(
		t,
		exit_code == int(cli.Exit_Code.Ok),
		"the write run exited %d: %s",
		exit_code,
		strings.to_string(err_out),
	)
	_, written_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/example.org/cap-schemeless-new.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(
		t,
		written_err == nil,
		"the session file was not written to the URL host's directory: %v",
		written_err,
	)
	_, stray_err := os.read_entire_file(
		fmt.aprintf(
			"%s/config/sessions/localhost/cap-schemeless-new.json",
			sandbox,
			allocator = context.temp_allocator,
		),
		context.temp_allocator,
	)
	testing.expectf(
		t,
		stray_err == .Not_Exist,
		"the session file landed under the localhost fallback as well (%v)",
		stray_err,
	)

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// run_session parses `argv` against `sandbox`'s config directory, runs the
// invocation and returns its exit code.
@(private)
run_session :: proc(
	t: ^testing.T,
	argv: []string,
	sandbox: string,
	out: ^strings.Builder,
	err_out: ^strings.Builder,
	allocator: mem.Allocator,
) -> int {
	options, parse_err := session_options(t, argv, sandbox, allocator)
	testing.expect_value(t, parse_err.kind, cli.Parse_Error_Kind.None)
	if parse_err.kind != .None {
		cli.parse_error_destroy(&parse_err)
		return -1
	}
	ctx := session.context_create(options, strings.to_writer(out), strings.to_writer(err_out))
	defer session.context_destroy(&ctx)
	return session.run(&ctx)
}

// session_options parses `argv` with an environment whose config directory is
// `sandbox`/config — the same shape the parity harness gives the reference.
@(private)
session_options :: proc(
	t: ^testing.T,
	argv: []string,
	sandbox: string,
	allocator: mem.Allocator,
) -> (
	cli.Options,
	cli.Parse_Error,
) {
	env := cli.env_info_from_strings(
		[]string{
			"TERM=xterm-256color",
			"COLUMNS=80",
			"LANG=C.UTF-8",
			fmt.aprintf("HTTPIE_CONFIG_DIR=%s/config", sandbox, allocator = context.temp_allocator),
			fmt.aprintf("HOME=%s/home", sandbox, allocator = context.temp_allocator),
		},
		true,
		false,
		false,
		allocator,
	)
	defer cli.env_info_destroy(&env, allocator)
	// The sandbox has a config *directory* but no `config.json` in it, so the
	// parser's config warning (parse_args_with's third, owned, result) is empty;
	// it is released here because the parser hands it over.
	options, err, config_warning := cli.parse_args_with(env, argv, allocator)
	delete(config_warning, allocator)
	return options, err
}

// session_sandbox makes a throwaway directory under $TMPDIR for one test; the
// caller frees it with session_teardown.
@(private)
session_sandbox :: proc(t: ^testing.T, name: string, allocator: mem.Allocator) -> string {
	base := "tmp"
	if tmp := os.get_env("TMPDIR", context.temp_allocator); tmp != "" {
		base = tmp
	}
	path := fmt.aprintf(
		"%s/oj-session-selftest-%s-%d",
		base,
		name,
		time.time_to_unix(time.now()),
		allocator = allocator,
	)
	if err := os.make_directory_all(path, os.Permissions{.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist {
		testing.expectf(t, false, "cannot create the sandbox %s: %v", path, err)
	}
	return path
}

// session_seed copies one of the reference's captured session files into the
// sandbox's config directory, as the session named `name`, at the directory the
// reference binds `http://127.0.0.1:8765/` to.
@(private)
session_seed :: proc(t: ^testing.T, sandbox: string, capture: string, name: string) {
	session_seed_in_host_dir(t, sandbox, "127.0.0.1_8765", capture, name)
}

// session_seed_in_host_dir copies a captured session file into
// `<config>/sessions/<host_dir>/`, the directory `session_hostname_to_dirname`
// builds from the URL (sessions.py:46-52).
@(private)
session_seed_in_host_dir :: proc(
	t: ^testing.T,
	sandbox: string,
	host_dir: string,
	capture: string,
	name: string,
) {
	directory := fmt.aprintf(
		"%s/config/sessions/%s",
		sandbox,
		host_dir,
		allocator = context.temp_allocator,
	)
	testing.expectf(
		t,
		os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil,
		"cannot create %s",
		directory,
	)
	data, data_err := os.read_entire_file(
		fmt.aprintf("%s/%s", SESSION_CAPTURE_DIR, capture, allocator = context.temp_allocator),
		context.temp_allocator,
	)
	testing.expectf(
		t,
		data_err == nil,
		"%s/%s is missing (the test runs from the repository root)",
		SESSION_CAPTURE_DIR,
		capture,
	)
	if data_err != nil {
		return
	}
	path := fmt.aprintf("%s/%s", directory, name, allocator = context.temp_allocator)
	testing.expectf(t, os.write_entire_file_from_bytes(path, data) == nil, "cannot seed %s", path)
}

// A pre-3.2 session file (an object `headers` store) is still read, and httpie
// tells the user how to upgrade it: the exact message of
// legacy/v3_2_0_session_header_format.py:8-19, on stderr, before the request.
@(test)
test_session_legacy_header_layout_warns :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	// Deferred, like every other case in this file: the tracker's own bookkeeping
	// map is allocated through the runner's allocator and is released here, after
	// expect_no_leaks has read it.  Without this line the *runner* reports the map
	// as a leak for this test (`[WARN] <18.31KiB/…> (…/…) ::
	// tests.test_session_legacy_header_layout_warns` + `+++ leak 18.31KiB`), even
	// though the test's own allocations balance — the reason it was the only case
	// in this file without it.
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	sandbox := session_sandbox(t, "legacy-warn", allocator)
	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// Seeded by hand: the reference wrote this file with httpie 2.x.
	session_seed_legacy(
		t,
		sandbox,
		"cap-legacy.json",
		`{"__meta__": {"httpie": "2.0.0"}, "headers": {"X-Legacy": "yes"}, ` +
		`"auth": {"type": null, "username": null, "password": null}}`,
	)

	argv := []string{
		"oj",
		"--session=cap-legacy",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"http://127.0.0.1:8765/json",
	}
	exit_code := run_session(t, argv, sandbox, &out, &err_out, allocator)

	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))
	// The old layout is still read: the stored header is in the request.
	testing.expectf(
		t,
		strings.contains(strings.to_string(out), "X-Legacy: yes\r\n"),
		"the legacy header was not used:\n%s",
		strings.to_string(out),
	)

	want := "\noj: warning: Outdated layout detected for the current session. Please consider updating it,\n" +
		"in order to use the latest features regarding the header layout.\n" +
		"\nFor fixing the current session:\n" +
		"\n    $ httpie cli sessions upgrade 127.0.0.1 cap-legacy\n" +
		"\nFor fixing all named sessions:\n" +
		"\n    $ httpie cli sessions upgrade-all\n" +
		"\nSee $INSERT_LINK for more information.\n\n\n"
	testing.expectf(
		t,
		strings.to_string(err_out) == want,
		"the legacy warning differs:\n%s",
		strings.to_string(err_out),
	)

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// session_seed_legacy writes `contents` into the sandbox's config directory as
// the session named `name`.
@(private)
session_seed_legacy :: proc(t: ^testing.T, sandbox: string, name: string, contents: string) {
	directory := fmt.aprintf(
		"%s/config/sessions/127.0.0.1_8765",
		sandbox,
		allocator = context.temp_allocator,
	)
	testing.expectf(
		t,
		os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil,
		"cannot create %s",
		directory,
	)
	path := fmt.aprintf("%s/%s", directory, name, allocator = context.temp_allocator)
	testing.expectf(
		t,
		os.write_entire_file_from_bytes(path, transmute([]u8)contents) == nil,
		"cannot seed %s",
		path,
	)
}

// session_teardown releases the sandbox and the two output builders every case
// in this file owns. It is called explicitly because expect_no_leaks runs at the
// end of each body, before any deferred free would have happened.
@(private)
session_teardown :: proc(
	sandbox: string,
	out: ^strings.Builder,
	err_out: ^strings.Builder,
	allocator: mem.Allocator,
) {
	strings.builder_destroy(out)
	strings.builder_destroy(err_out)
	os.remove_all(sandbox)
	delete(sandbox, allocator)
}
