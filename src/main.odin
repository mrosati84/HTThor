package main

import "core:io"
import "core:os"

import "src:cli"
import "src:output"
import "src:session"

// main is the only place in the program that reads the runtime's default
// allocator. Everything below receives it as an explicit parameter, so no
// library proc here depends on `context.allocator` state (see
// docs/ARCHITECTURE.md, "Memory ownership").
//
// It is also the only place that exits: run returns an exit code and main hands
// it to os.exit, after the Context has been destroyed explicitly.
main :: proc() {
	allocator := context.allocator

	stdout := io.to_writer(os.to_stream(os.stdout))
	stderr := io.to_writer(os.to_stream(os.stderr))

	program_name := cli.program_name_of(os.args)

	options, parse_err, config_warning := cli.parse_args(os.args, allocator)

	// The malformed `config.json` warning, where the reference prints it:
	// `env.config` is read at the top of `raw_main`, before argparse runs, so
	// this line precedes --help, a usage block, --version and every message the
	// run produces (httpie/context.py:143-149; docs/PARITY.md §6.1).
	//
	// Nothing filters it: `log_error`'s branch is decided against `env.quiet`,
	// which is still argparse's 0 at that point, and its other branch is the
	// original stderr anyway — measured for `-q`, `-qq` and `-qqq`, with stdout
	// both a pipe and a tty.
	//
	// It does go through a rich console like every other `log_error` message
	// (httpie/context.py:170-182), so the console's width decides whether it
	// survives: at `$COLUMNS=0` the console is zero cells wide and the warning
	// is dropped (`output.Console`, `cli.console_silent`). The environment is
	// read here rather than taken from the parsed options, because this line
	// precedes the branch below and `parse_args` has already released the
	// partial options when it returns an error.
	if config_warning != "" {
		env := cli.env_info_from_process(allocator)
		console := output.Console {
			writer = stderr,
			width  = cli.console_width(env),
			crash  = cli.console_crash(env),
		}
		output.write_log_warning(console, program_name, config_warning)
		cli.env_info_destroy(&env, allocator)
		delete(config_warning, allocator)
		// The console this warning was about to go through is the one rich
		// cannot build: `$COLUMNS` is a digit its `int()` refuses, so the
		// reference dies inside `Console.__init__` and *nothing* else of the
		// run happens — no usage block, no request, nothing on stdout — with
		// the exception's own status. `write_log_crash` is what the writer
		// above wrote in place of the warning (docs/PARITY.md §3.1, §8.20).
		// The run still owns whatever the parse left behind, and main is the
		// only place that exits, so it releases it here: the partial Options
		// with their cloned environment when the parse succeeded, the error
		// when it did not (parse_args_with has already released the Options on
		// every error path).
		if output.console_fatal(console) {
			if parse_err.kind == .None {
				cli.options_destroy(&options)
			} else {
				cli.parse_error_destroy(&parse_err)
			}
			os.exit(int(cli.Exit_Code.Error))
		}
	}

	if parse_err.kind != .None {
		// parse_args has already released the partial options.
		//
		// Kind .Exception is the `--raw` body's utf-8 encode, the one failure
		// the reference raises *outside* its own error handling: it prints no
		// usage block, it dies with an unhandled traceback (docs/PARITY.md
		// §3.6, §8.20). The port prints the exception's own line in the shape
		// every UnicodeEncodeError httpie *does* catch gets — the `http: error:`
		// line, through the same writer the session's runtime failures use —
		// and exits 1. `parse_err.width` is the console the line goes through,
		// so a zero-width one prints nothing at all.
		if parse_err.kind == .Exception {
			console := output.Console {
				writer = stderr,
				width  = parse_err.width,
			}
			output.write_log_error(console, program_name, parse_err.message)
			cli.parse_error_destroy(&parse_err)
			os.exit(int(cli.Exit_Code.Error))
		}
		// The usage block is written whole and verbatim: usage lines, `error:`
		// line, tail — wrapped to the console width the parser read out of the
		// run's environment, which is what rich's own console would size itself
		// to (Parse_Error.width; src/cli/usage.odin's console_width). A
		// zero-width console renders none of it, and the block comes back as
		// the newline httpie's SystemExit handler writes.
		//
		// That console is built here the way rich builds the reference's
		// (`Console.__init__` out of the *environment*, rich/console.py:685-694),
		// and the environment is read again because the partial Options — and
		// with them the cloned one the parser worked from — have already been
		// released on this path. A `$COLUMNS` its `int()` refuses is the console
		// that cannot exist: the reference dies inside that constructor, before
		// the block is rendered, so the port prints the exception's own line and
		// ends the run with the same status instead of a block the reference
		// never printed (docs/PARITY.md §3.1, §8.20).
		env := cli.env_info_from_process(allocator)
		console := output.Console {
			writer = stderr,
			width  = parse_err.width,
			crash  = cli.console_crash(env),
		}
		if output.console_fatal(console) {
			output.write_log_crash(console, program_name)
			cli.env_info_destroy(&env, allocator)
			cli.parse_error_destroy(&parse_err)
			os.exit(int(cli.Exit_Code.Error))
		}
		cli.env_info_destroy(&env, allocator)
		text := cli.usage_error_text(program_name, parse_err.message, parse_err.width, allocator)
		io.write_string(stderr, text)
		delete(text, allocator)
		cli.parse_error_destroy(&parse_err)
		os.exit(int(cli.USAGE_EXIT_CODE))
	}

	// --help and --manual are argparse actions that print their text and exit
	// (cli/argparser.py:561-575 for the manual, the parser's own help action for
	// --help). They are handled here rather than in the session because their
	// text is the reference's recorded bytes — see
	// src/cli/help_text_generated.odin — and because they must not go through
	// the usage-error path above. The text is written to stdout, the exit code
	// is 0 and stderr stays empty; `--version` (which the session shares with
	// the message writers) is left to the session.
	//
	// The two print differently at a zero-width console. `--help` is argparse's
	// own action: it writes the help to stdout directly, whatever rich would
	// make of the width — measured at `$COLUMNS=0`, where it still prints the
	// whole 80-column text. `--manual` pages the *same* text through
	// `env.rich_console` (argparser.py:568-572), so a zero-width console
	// renders nothing and the run is silent (`cli.console_silent`). The rest of
	// the manual's width dependence — the text is a recorded 80-column
	// rendering here — is docs/PARITY.md §8 item 15.
	//
	// `meta_action` is the left-most of the three, because argparse exits at the
	// first one it meets while scanning argv: `http --help --version` prints the
	// help, `http --version --help` the version.
	switch options.meta_action {
	case .Help, .Manual:
		text := options.meta_action == .Help ? cli.HELP_TEXT : cli.MANUAL_TEXT
		if options.meta_action == .Manual {
			// `--manual` pages that text through `env.rich_console`, so it is
			// the console this run's `$COLUMNS` describes — and a value rich's
			// `int()` refuses is the console the reference dies building
			// (`argparser.py:568-572`; `cli.console_crash`, docs/PARITY.md §3.1,
			// §8.20). The run ends before the text reaches stdout, as it does
			// in the reference.
			console := output.Console {
				writer = stderr,
				width  = cli.console_width(options.env),
				crash  = cli.console_crash(options.env),
			}
			if output.console_fatal(console) {
				output.write_log_crash(console, program_name)
				cli.options_destroy(&options)
				os.exit(int(cli.Exit_Code.Error))
			}
			if cli.console_silent(console.width) {
				text = ""
			}
		}
		io.write_string(stdout, text)
		cli.options_destroy(&options)
		os.exit(int(cli.Exit_Code.Ok))
	case .None, .Version:
		// An ordinary invocation, or --version: the session's.
	}

	ctx := session.context_create(options, stdout, stderr)
	exit_code := session.run(&ctx)
	session.context_destroy(&ctx)

	os.exit(exit_code)
}
