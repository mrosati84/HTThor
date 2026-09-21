// `--version` (backlog M9): the reference's line stays first and verbatim — it is
// the release the port matches byte for byte — and the port's own release follows
// it, so a bug report can name the revision it came from. The revision itself is
// injected by the Makefile (`-define:PORT_REVISION=...`) and is empty in a test
// binary, which is the second shape asserted here.
package tests

import "core:mem"
import "core:strings"
import "core:testing"

import "src:cli"
import "src:output"
import "src:session"

@(test)
test_version_names_the_port_release :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	options, err := parse_cli_plain([]string{"htthor", "--version"}, allocator)
	testing.expect_value(t, err.kind, cli.Parse_Error_Kind.None)

	ctx := session.context_create(options, strings.to_writer(&out), strings.to_writer(&err_out))
	exit_code := session.run(&ctx)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	version := strings.to_string(out)
	testing.expectf(
		t,
		strings.has_prefix(version, output.VERSION + "\n"),
		"--version must print the reference's line first: %q",
		version,
	)
	testing.expectf(
		t,
		strings.contains(version, "htthor " + output.PORT_VERSION),
		"--version must name the port's own release: %q",
		version,
	)

	session.context_destroy(&ctx)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	expect_no_leaks(t, &track)
}
