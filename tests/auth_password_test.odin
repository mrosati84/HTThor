// `--auth user`, with no password (backlog M4). The reference prompts for one
// (getpass; only the URL's own userinfo falls back to `password or ''`), and the
// port has no terminal layer to prompt with: the password comes from
// $HTTHOR_AUTH_PASSWORD instead, and a run that has none stops before anything
// goes on the wire rather than sending `user:` with an empty password.
//
// `-A bearer` is the carve-out: the reference's bearer plugin passes the value
// through unparsed (no user:pass split, no prompt), so it needs no password.
package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:cli"
import "src:session"

@(test)
test_a_missing_password_comes_from_the_environment :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	url := engine_url(server, "/echo", allocator)

	options, err := auth_password_options(
		[]string{"htthor", "--auth", "alice", "--pretty=none", "-p", "H", url},
		[]string{"HTTHOR_AUTH_PASSWORD=s3cr3t"},
		allocator,
	)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)
	ctx := session.context_create(
		options,
		strings.to_writer(&out),
		strings.to_writer(&err_out),
	)
	exit_code := session.run(&ctx)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))
	testing.expectf(
		t,
		strings.to_string(err_out) == "",
		"a run with a password reports nothing on stderr:\n%s",
		strings.to_string(err_out),
	)

	raw := engine_request_clone(server, 0, allocator) or_else ""
	authorization, has_authorization := engine_header_of(raw, "Authorization")
	testing.expect(t, has_authorization, "the credentials must be preemptive")
	// ENGINE_AUTHORIZATION is `Basic alice:s3cr3t`: the value from the
	// environment, not `alice:` with nothing after it.
	testing.expect_value(t, authorization, ENGINE_AUTHORIZATION)
	testing.expectf(
		t,
		!strings.contains(raw, "s3cr3t"),
		"the password must not appear in the request line or the headers:\n%s",
		raw,
	)

	session.context_destroy(&ctx)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	delete(raw, allocator)
	delete(url, allocator)
	engine_server_destroy(server)
	expect_no_leaks(t, &track)
}

@(test)
test_a_missing_password_without_the_environment_stops_the_run :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	url := engine_url(server, "/echo", allocator)

	options, err := auth_password_options(
		[]string{"htthor", "--auth", "alice", "--pretty=none", "-p", "H", url},
		nil,
		allocator,
	)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)
	ctx := session.context_create(
		options,
		strings.to_writer(&out),
		strings.to_writer(&err_out),
	)
	exit_code := session.run(&ctx)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Error))

	message := strings.to_string(err_out)
	testing.expectf(
		t,
		strings.contains(message, "no password for 'alice'"),
		"the missing password must be reported:\n%s",
		message,
	)
	testing.expectf(
		t,
		strings.contains(message, cli.AUTH_PASSWORD_ENV),
		"the message must name the variable to set:\n%s",
		message,
	)
	// Nothing was sent: the run stopped while the request was being built.
	_, request_sent := engine_request_clone(server, 0, context.temp_allocator)
	testing.expect(t, !request_sent, "no request may reach the server without a password")

	session.context_destroy(&ctx)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	delete(url, allocator)
	engine_server_destroy(server)
	expect_no_leaks(t, &track)
}

@(test)
test_a_bearer_value_is_not_a_username :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	url := engine_url(server, "/echo", allocator)

	options, err := auth_password_options(
		[]string{"htthor", "--auth", "tok", "--auth-type", "bearer", "-p", "H", url},
		nil,
		allocator,
	)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)
	ctx := session.context_create(
		options,
		strings.to_writer(&out),
		strings.to_writer(&err_out),
	)
	exit_code := session.run(&ctx)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	raw := engine_request_clone(server, 0, allocator) or_else ""
	authorization, has_authorization := engine_header_of(raw, "Authorization")
	testing.expect(t, has_authorization, "the bearer token must be sent")
	testing.expectf(
		t,
		authorization == "Bearer tok",
		"the bearer value is passed through unparsed, got %q",
		authorization,
	)

	session.context_destroy(&ctx)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	delete(raw, allocator)
	delete(url, allocator)
	engine_server_destroy(server)
	expect_no_leaks(t, &track)
}

// auth_password_options parses argv against the same deterministic environment
// the other CLI tests use, plus whatever the case needs to add — here, the
// password variable. The parser returns the config warning owned.
@(private)
auth_password_options :: proc(
	argv: []string,
	environment: []string,
	allocator: mem.Allocator,
) -> (
	cli.Options,
	cli.Parse_Error,
) {
	entries := make([dynamic]string, 0, 3 + len(environment), allocator)
	defer delete(entries)
	append(&entries, "TERM=xterm-256color", "COLUMNS=80", "LANG=C.UTF-8")
	for entry in environment {
		append(&entries, entry)
	}
	env := cli.env_info_from_strings(entries[:], true, false, false, allocator)
	defer cli.env_info_destroy(&env, allocator)
	options, err, config_warning := cli.parse_args_with(env, argv, allocator)
	delete(config_warning, allocator)
	return options, err
}
