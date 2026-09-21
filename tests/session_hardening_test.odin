// The session file's mode (backlog M4): `raw_auth` is plaintext in it, and the
// 0600 the port saves with only reaches a file the port *writes*. A file that
// was already on disk — httpie writes 0644 under a 022 umask — is read for the
// whole run, and a `--session-read-only` run never rewrites it, so the load path
// reports it and tightens it. This is a deliberate divergence from the
// reference, which has no such check (README, "Status and limitations").
package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import "src:cli"
import "src:session"

// SHARED_FILE_MODE is 0644: what httpie's own session files are left at.
@(private)
SHARED_FILE_MODE :: os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}

@(test)
test_session_file_mode_is_tightened_on_load :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	sandbox := session_sandbox(t, "mode-warn", allocator)
	out, err_out: strings.Builder
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)

	// `<config>/sessions/<host_dir>/<name>.json`, seeded at 0644 — the mode
	// httpie itself writes, and the one the port refuses to read silently.
	session_seed_legacy(t, sandbox, "cap-mode.json", `{"headers": {}}`)
	path := fmt.aprintf(
		"%s/config/sessions/127.0.0.1_8765/cap-mode.json",
		sandbox,
		allocator = context.temp_allocator,
	)
	testing.expectf(t, os.chmod(path, SHARED_FILE_MODE) == nil, "cannot widen %s", path)
	expect_mode(t, path, SHARED_FILE_MODE, "the seeded file must start group-readable")

	argv := []string{
		"htthor",
		"--session=cap-mode",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"http://127.0.0.1:8765/json",
	}
	exit_code := run_session(t, argv, sandbox, &out, &err_out, allocator)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	warning := strings.to_string(err_out)
	testing.expectf(
		t,
		strings.contains(warning, "is readable by other users"),
		"the mode warning is missing:\n%s",
		warning,
	)
	testing.expectf(
		t,
		strings.contains(warning, "tightened to 0600"),
		"the tightening is not reported:\n%s",
		warning,
	)
	expect_mode(t, path, session.SESSION_FILE_MODE, "the mode must be tightened")

	// The other half: `--session-read-only` is a promise not to touch the file,
	// so the file is reported and left exactly as it was.
	testing.expectf(t, os.chmod(path, SHARED_FILE_MODE) == nil, "cannot widen %s again", path)
	strings.builder_destroy(&out)
	strings.builder_destroy(&err_out)
	strings.builder_init(&out, allocator)
	strings.builder_init(&err_out, allocator)
	read_only_argv := []string{
		"htthor",
		// `--session-read-only=NAME` is the reference's spelling: it *names* the
		// session to open without writing (cli/definition.py), hence the value.
		"--session-read-only=cap-mode",
		"--offline",
		"-p", "H",
		"--pretty=none",
		"http://127.0.0.1:8765/json",
	}
	exit_code = run_session(t, read_only_argv, sandbox, &out, &err_out, allocator)
	testing.expect_value(t, exit_code, int(cli.Exit_Code.Ok))

	read_only_warning := strings.to_string(err_out)
	testing.expectf(
		t,
		strings.contains(read_only_warning, "left as it is under --session-read-only"),
		"the read-only warning is missing:\n%s",
		read_only_warning,
	)
	expect_mode(t, path, SHARED_FILE_MODE, "--session-read-only must not chmod the file")

	session_teardown(sandbox, &out, &err_out, allocator)
	expect_no_leaks(t, &track)
}

// expect_mode is the stat-and-compare an assertion about the file's mode needs.
// The File_Info's fullpath comes from the temp allocator, which the runner
// releases with the rest of this test's scratch memory.
@(private)
expect_mode :: proc(t: ^testing.T, path: string, want: os.Permissions, what: string) {
	info, stat_err := os.stat(path, context.temp_allocator)
	testing.expectf(t, stat_err == nil, "%s: cannot stat %s: %v", what, path, stat_err)
	if stat_err != nil {
		return
	}
	testing.expectf(t, info.mode == want, "%s: mode is %v, want %v", what, info.mode, want)
}
