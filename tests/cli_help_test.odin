// The help surface.
//
// `--help` and `--manual` print text the port does not compose: it is embedded
// verbatim in src/cli/help_text_generated.odin. These tests cover the shape of
// that text (the two renderings differ, both start with the usage block) and the
// ordering of the mutually exclusive meta actions.
package tests

import "core:mem"
import "core:testing"

import "src:cli"

// The two renderings are not interchangeable: the manual wraps differently from
// the help, so a port that printed one for both would still look plausible in a
// spot check.
@(test)
test_help_and_manual_are_different_texts :: proc(t: ^testing.T) {
	testing.expect(
		t,
		cli.HELP_TEXT != cli.MANUAL_TEXT,
		"--manual must not be served the --help text (docs/PARITY.md §8 item 14)",
	)
	// httpie's parser is built with `prog='http'` (cli/definition.py), so the
	// text does not follow argv[0] the way its error messages do.
	testing.expect(
		t,
		len(cli.HELP_TEXT) > 6 && cli.HELP_TEXT[:6] == "usage:",
		"both texts start with the usage block httpie's argparse prints",
	)
}

// test_meta_action_is_the_left_most_of_the_three covers the ordering the
// reference's actions impose: argparse fires `--help`, `--manual` and
// `--version` while it scans argv, so the first one met decides
// (`http --help --version` prints the help, `http --version --help` the
// version). The port parses the whole command line and records that first
// action instead.
@(test)
test_meta_action_is_the_left_most_of_the_three :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	cases := []struct {
		argv: []string,
		want: cli.Meta_Action,
	}{
		{[]string{"oj", "example.com"}, cli.Meta_Action.None},
		{[]string{"oj", "--help"}, cli.Meta_Action.Help},
		{[]string{"oj", "--manual"}, cli.Meta_Action.Manual},
		{[]string{"oj", "--version"}, cli.Meta_Action.Version},
		{[]string{"oj", "--help", "--version"}, cli.Meta_Action.Help},
		{[]string{"oj", "--version", "--help"}, cli.Meta_Action.Version},
		{[]string{"oj", "--manual", "--help"}, cli.Meta_Action.Manual},
		{[]string{"oj", "--help", "--manual"}, cli.Meta_Action.Help},
	}
	for entry in cases {
		options, err := parse_cli(entry.argv, allocator)
		testing.expectf(
			t,
			err.kind == .None,
			"%v: unexpected parse error: %s",
			entry.argv,
			err.message,
		)
		testing.expectf(
			t,
			options.meta_action == entry.want,
			"%v: meta_action %v, want %v",
			entry.argv,
			options.meta_action,
			entry.want,
		)
		cli.options_destroy(&options)
		cli.parse_error_destroy(&err)
	}
	expect_no_leaks(t, &track)
}

// A usage error still wins when the flag that fails comes first: argparse never
// reaches the help action, so the reference prints its usage block to stderr
// and exits 1 (scenario err-unknown-style).
@(test)
test_meta_action_does_not_swallow_a_usage_error :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	_, err := parse_cli([]string{"oj", "--style=nope", "--help"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.Usage)
	cli.parse_error_destroy(&err)
	expect_no_leaks(t, &track)
}

// The size assertions below fail loudly if the embedded text is regenerated
// with a different length than the generated header documents.
@(test)
test_help_text_sizes_are_the_documented_ones :: proc(t: ^testing.T) {
	// 15179 bytes for `http --help`, 15190 for `http --manual`.
	testing.expect_value(t, len(cli.HELP_TEXT), 15179)
	testing.expect_value(t, len(cli.MANUAL_TEXT), 15190)
}
