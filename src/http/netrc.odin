// Credentials from the user's netrc file.
//
// requests resolves these itself whenever the caller set no auth at all:
// `Session.prepare_request` does
//
//   if self.trust_env and not auth and not self.auth:
//       auth = get_netrc_auth(url)
//
// (sessions.py:530-539), so `http http://host/` picks up `~/.netrc` without any
// flag, and httpie's `--ignore-netrc` defeats it by handing requests a no-op
// auth object (argparser.py:352-355, utils.py:125-130).
//
// The file requests reads is `$NETRC` when that is set and otherwise the first
// of `~/.netrc`, `~/_netrc` that exists (requests.utils.get_netrc_auth), the
// machine it looks up is the URL's host without its port, and a `default` entry
// matches any host.
//
// The session is what decides *when* this applies (no --auth, no
// --ignore-netrc); this file only knows how to read one.
package http

import "core:mem"
import "core:os"
import "core:strings"

// Netrc_Match is one entry that could answer the lookup: the host's own entry,
// or the `default` one.
@(private)
Netrc_Match :: struct {
	login:    string,
	password: string,
	found:    bool,
}

// netrc_credentials returns the `login:password` pair requests would use for
// `host`, or found = false when the user has no netrc file, the file names no
// entry for the host, or the file cannot be read. The caller owns the result.
netrc_credentials :: proc(host: string, allocator: mem.Allocator) -> (credentials: string, found: bool) {
	if host == "" {
		return "", false
	}
	path, have_path := netrc_path(allocator)
	if !have_path {
		return "", false
	}
	defer delete(path, allocator)

	contents, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		return "", false
	}
	defer delete(contents, allocator)

	login, password, matched := netrc_lookup(string(contents), host)
	if !matched {
		return "", false
	}
	joined, concat_err := strings.concatenate({login, ":", password}, allocator)
	if concat_err != .None {
		return "", false
	}
	return joined, true
}

// netrc_path is the first existing candidate: `$NETRC` on its own when that is
// set (requests does not fall back to the home directory then), else
// `~/.netrc`, else `~/_netrc`. The caller owns the result.
@(private)
netrc_path :: proc(allocator: mem.Allocator) -> (path: string, ok: bool) {
	netrc_env: [ENV_SCRATCH_SIZE]u8
	if explicit := os.get_env(netrc_env[:], "NETRC"); explicit != "" {
		if !os.exists(explicit) {
			return "", false
		}
		clone, clone_err := strings.clone(explicit, allocator)
		return clone, clone_err == .None
	}

	home_env: [ENV_SCRATCH_SIZE]u8
	home := os.get_env(home_env[:], "HOME")
	if home == "" {
		return "", false
	}
	for suffix in ([?]string {"/.netrc", "/_netrc"}) {
		joined, concat_err := strings.concatenate({home, suffix}, allocator)
		if concat_err != .None {
			return "", false
		}
		if os.exists(joined) {
			return joined, true
		}
		delete(joined, allocator)
	}
	return "", false
}

// netrc_lookup finds `host`'s credentials in a netrc file's text. netrc's
// grammar is a token stream: `machine NAME` opens an entry, `login`,
// `password` and `account` set its fields in any order, `default` opens the
// entry that matches every host, and `macdef NAME` introduces a macro whose body
// runs to the next blank line and is skipped (CPython's netrc.py:100-160, which
// requests relies on). The returned strings borrow from `contents`.
@(private)
netrc_lookup :: proc(contents: string, host: string) -> (login: string, password: string, found: bool) {
	exact: Netrc_Match
	fallback: Netrc_Match

	machine, entry_login, entry_account, entry_password := "", "", "", ""
	macro := false

	rest := contents
	for len(rest) > 0 {
		line := rest
		if newline := strings.index_byte(rest, '\n'); newline >= 0 {
			line = rest[:newline]
			rest = rest[newline + 1:]
		} else {
			rest = ""
		}
		if comment := strings.index_byte(line, '#'); comment >= 0 {
			// netrc's lexer drops the rest of the line at a `#`.
			line = line[:comment]
		}
		if strings.trim_space(line) == "" {
			macro = false
			continue
		}
		if macro {
			continue
		}

		fields := line
		for {
			field, remainder, more := netrc_field(fields)
			if !more {
				break
			}
			fields = remainder
			switch {
			case field == "machine":
				netrc_close_entry(machine, entry_login, entry_account, entry_password, host, &exact, &fallback)
				machine, entry_login, entry_account, entry_password = "", "", "", ""
				if value, next, has := netrc_field(fields); has {
					machine = value
					fields = next
				}
			case field == "default":
				netrc_close_entry(machine, entry_login, entry_account, entry_password, host, &exact, &fallback)
				machine, entry_login, entry_account, entry_password = "default", "", "", ""
			case field == "login":
				if value, next, has := netrc_field(fields); has {
					entry_login = value
					fields = next
				}
			case field == "password":
				if value, next, has := netrc_field(fields); has {
					entry_password = value
					fields = next
				}
			case field == "account":
				if value, next, has := netrc_field(fields); has {
					entry_account = value
					fields = next
				}
			case field == "macdef":
				if _, next, has := netrc_field(fields); has {
					fields = next
				}
				macro = true
			}
		}
	}
	netrc_close_entry(machine, entry_login, entry_account, entry_password, host, &exact, &fallback)

	if exact.found {
		return exact.login, exact.password, true
	}
	if fallback.found {
		return fallback.login, fallback.password, true
	}
	return "", "", false
}

// netrc_close_entry records an entry that has just ended. requests returns
// `(login or account, password)` for it (sessions.py:363-368), and prefers the
// host's own entry over `default` — which is why both are kept and the exact one
// wins at the end.
@(private)
netrc_close_entry :: proc(
	machine: string,
	login: string,
	account: string,
	password: string,
	host: string,
	exact: ^Netrc_Match,
	fallback: ^Netrc_Match,
) {
	if machine == "" {
		return
	}
	user := login
	if user == "" {
		user = account
	}
	if user == "" {
		return
	}
	if machine == "default" {
		fallback^ = {login = user, password = password, found = true}
		return
	}
	if machine == host {
		exact^ = {login = user, password = password, found = true}
	}
}

// netrc_field pulls the next whitespace-separated field out of `line`, the way
// netrc's lexer splits on spaces, tabs and form feeds. `more` is false when
// there is nothing left. The result borrows from `line`.
@(private)
netrc_field :: proc(line: string) -> (field: string, rest: string, more: bool) {
	trimmed := strings.trim_left(line, " \t\f\r")
	if trimmed == "" {
		return "", "", false
	}
	end := len(trimmed)
	for i in 0 ..< len(trimmed) {
		c := trimmed[i]
		if c == ' ' || c == '	' || c == '\f' || c == '\r' {
			end = i
			break
		}
	}
	return trimmed[:end], trimmed[end:], true
}
