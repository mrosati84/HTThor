// Shared test helpers. The tests build their subjects on a tracking allocator
// so that the ownership rules in docs/ARCHITECTURE.md are enforced, not just
// documented: every test that allocates ends by asserting a zero balance.
package tests

import "core:mem"
import "core:testing"

import "src:cli"

// parse_cli parses argv against a deterministic environment: a terminal on
// stdin, no inherited variables, and `stdout_is_tty` deciding the rest. Without
// the tty on stdin the CLI would mistake the test runner's own stdin for a
// request body (httpie reads a piped stdin, and `key=value` items mixed with it
// are a usage error — see argparser's _ensure_one_data_source); the tty on
// stdout turns colour on and picks the tty default `--print` set, which the
// tests that assert on rendered bytes do not want.
parse_cli :: proc(argv: []string, allocator: mem.Allocator) -> (cli.Options, cli.Parse_Error) {
	return parse_cli_with(argv, true, allocator)
}

// parse_cli_plain is the same with a pipe on stdout, which is what the tests
// that assert on rendered bytes want: no colour, and the non-tty `--print`
// default.
parse_cli_plain :: proc(argv: []string, allocator: mem.Allocator) -> (cli.Options, cli.Parse_Error) {
	return parse_cli_with(argv, false, allocator)
}

@(private)
parse_cli_with :: proc(
	argv: []string,
	stdout_is_tty: bool,
	allocator: mem.Allocator,
) -> (
	cli.Options,
	cli.Parse_Error,
) {
	env := cli.env_info_from_strings(
		[]string{"TERM=xterm-256color", "COLUMNS=80", "LANG=C.UTF-8"},
		true,
		stdout_is_tty,
		false,
		allocator,
	)
	defer cli.env_info_destroy(&env, allocator)
	// The test environments have no config file to read, so the parser's config
	// warning is always empty here (parse_args_with's third result); it is freed
	// all the same because the parser returns it owned.
	options, err, config_warning := cli.parse_args_with(env, argv, allocator)
	delete(config_warning, allocator)
	return options, err
}

expect_no_leaks :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) {
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "leaked %d bytes allocated at %v", entry.size, entry.location)
	}
	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"%d allocations were never freed",
		len(track.allocation_map),
	)
	testing.expectf(
		t,
		len(track.bad_free_array) == 0,
		"%d frees did not match an allocation",
		len(track.bad_free_array),
	)
}
