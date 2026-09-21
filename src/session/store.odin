// Session persistence: httpie's JSON session file (httpie/sessions.py,
// httpie/config.py:92-128, docs/PARITY.md §6.3).
//
// The file is the contract. `BaseConfigDict.save()` writes
// `json.dumps(self.post_process_data(self), indent=4, sort_keys=True,
// ensure_ascii=True)` plus one trailing newline, and the reference files
// captured in `tests/fixtures/sessions/` pin the bytes: sorted keys put
// `__meta__` first, then `auth`, `cookies`, `headers`.
//
// Ownership: a Session owns every string in it; `session_destroy` releases the
// lot with the allocator that built it (docs/ARCHITECTURE.md §4).
package session

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "src:cli"
import "src:format"
import "src:http"
import "src:output"

// SESSION_HTTPIE_VERSION is `__meta__.httpie`: the version that wrote the file.
// It is the port's own version, and docs/PARITY.md §7.10 records that this
// field legitimately changes with the tool version.
SESSION_HTTPIE_VERSION :: "3.2.4"

// The other two `__meta__` lines, from Session.about / Session.helpurl.
SESSION_ABOUT :: "HTTPie session file"
SESSION_HELP_URL :: "https://httpie.io/docs#sessions"

// SESSIONS_DIR_NAME is where a named session lives inside the config
// directory (sessions.py:29).
SESSIONS_DIR_NAME :: "sessions"

// SESSION_DIR_MODE is the mode of the directories `save()` creates
// (`mkdir(mode=0o700, parents=True, exist_ok=True)`, config.py:103-104) and
// SESSION_FILE_MODE the mode of the file itself.
//
// The file mode is a deliberate divergence from the reference: httpie writes
// the file 0644 under umask 022 and relies on the 0700 directory to contain it,
// while the file holds a plaintext credential (`"raw_auth": "alice:s3cr3t"`) and
// nothing else in it needs to be group- or world-readable. 0600 is what this
// port writes and re-asserts on save (session_save); do not "restore parity"
// by widening it back (docs/security-findings.md, SF-004).
SESSION_DIR_MODE :: os.Permissions{.Read_User, .Write_User, .Execute_User}
SESSION_FILE_MODE :: os.Permissions{.Read_User, .Write_User}

// Cookie is one entry of the jar: requests' cookie-jar shape, i.e.
// sessions.py:33-46's KEPT_COOKIE_OPTIONS plus the state that decides which
// requests it is sent with.
Cookie :: struct {
	name:  string, // owned
	value: string, // owned
	// domain is the cookie's scope; "" with explicit_none is a domainless
	// cookie from a legacy file, which is written back as `"domain": null`.
	domain: string, // owned
	path:   string, // owned; "/" when the Set-Cookie carried no Path
	secure: bool,
	// expires is the epoch second the cookie dies at; has_expires false is a
	// session cookie, which the file records as `null`.
	expires:     i64,
	has_expires: bool,
	// domain_specified is the Domain attribute's presence; without it the
	// cookie is host-only and only its own host gets it back (RFC 6265 §5.4).
	domain_specified: bool,
	explicit_none:    bool,
}

// Auth_Kind is which shape the file's `auth` object has
// (sessions.py:272-304). The two older shapes are still readable.
Auth_Kind :: enum {
	// Default is the constructor's `{"type": null, "username": null,
	// "password": null}`, which every file the reference has not authenticated
	// through carries (sessions.py:126-130).
	Default,
	// Legacy is a real `{"type", "username", "password"}` object.
	Legacy,
	// New is `{"type", "raw_auth"}`, what httpie 3.2 writes.
	New,
}

Auth :: struct {
	kind:         Auth_Kind,
	type:         string, // owned; "basic"/"bearer"/"digest"
	has_type:     bool,
	raw_auth:     string, // owned: new style `raw_auth`
	has_raw_auth: bool,
	username:     string, // owned: legacy shape
	has_username: bool,
	password:     string, // owned: legacy shape
	has_password: bool,
}

// Session is one persistent session: the JSON file at `path` plus the headers,
// cookies and credentials it carries between runs.
Session :: struct {
	allocator: mem.Allocator,

	// path is the file the session lives in; session_id is what httpie's
	// legacy warnings name the session by (the name, or the literal path for
	// an anonymous session); bound_host is `strip_port(hostname)`.
	path:       string, // owned
	session_id: string, // owned
	bound_host: string, // owned

	anonymous: bool,
	read_only: bool, // --session-read-only
	is_new:    bool, // the file did not exist when the session was opened

	// The legacy layout markers (the file's `headers`/`cookies` were objects
	// rather than lists): reading them works, but the user is told how to
	// upgrade the file, the way httpie's upgrade plugins do.
	legacy_headers:          bool,
	legacy_cookies_insecure: bool,

	headers: [dynamic]http.Header, // owned
	cookies: [dynamic]Cookie,      // owned
	auth:    Auth,
	// auth_given records that the command line carried credentials this run:
	// those are written in the new shape whatever the file held before
	// (client.py:77-81).
	auth_given: bool,
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

// session_open resolves and loads the session the options ask for. A file that
// cannot be understood is httpie's ConfigFileError: the message goes to `log`
// and the process must exit 1 (core.py:63-66). `log` is the run's message
// console (src/output/render.odin's Console): it carries the console's width,
// so these messages vanish with every other one at `$COLUMNS=0`.
session_open :: proc(
	options: ^cli.Options,
	log: output.Console,
	allocator: mem.Allocator,
) -> (
	session: Session,
	ok: bool,
) {
	session.allocator = allocator
	session.read_only = options.session == ""

	location, located := session_location(options, allocator)
	if !located {
		message := "ConfigFileError: unable to resolve the HTTPie config directory (is HOME set?)"
		output.write_log_error(log, options.program_name, message)
		session_destroy(&session)
		return session, false
	}
	session.path = location.path
	session.session_id = location.session_id
	session.bound_host = location.bound_host
	session.anonymous = location.anonymous

	if !session_load(&session, log, options) {
		session_destroy(&session)
		return session, false
	}
	return session, true
}

// session_destroy releases everything the session owns and zeroes it, so
// destroying twice is safe.
session_destroy :: proc(session: ^Session) {
	if session == nil {
		return
	}
	allocator := session.allocator
	delete(session.path, allocator)
	delete(session.session_id, allocator)
	delete(session.bound_host, allocator)
	for header in session.headers {
		delete(header.name, allocator)
		delete(header.value, allocator)
	}
	delete(session.headers)
	cookie_destroy_all(session.cookies[:], allocator)
	delete(session.cookies)
	auth_destroy(&session.auth, allocator)
	session^ = {}
}

// Session_Location is the path resolution of get_httpie_session
// (sessions.py:92-121).
@(private)
Session_Location :: struct {
	path:       string, // owned
	session_id: string, // owned
	bound_host: string, // owned
	anonymous:  bool,
}

// session_location turns the session name into a file: a name containing a path
// separator is the literal path ("anonymous session"), anything else lives at
// `$HTTPIE_CONFIG_DIR/sessions/<host>_<port>/<name>.json` with the `:` of the
// host:port replaced by `_`.
@(private)
session_location :: proc(
	options: ^cli.Options,
	allocator: mem.Allocator,
) -> (
	location: Session_Location,
	ok: bool,
) {
	name := options.session != "" ? options.session : options.session_read_only
	if name == "" {
		return location, false
	}

	// The host the session binds to. Only a non-empty result is owned — the
	// "localhost" fallback below is a literal, and so is the empty spelling —
	// and it has to outlive *this* statement, which is why the release is
	// registered at function scope (a `defer` inside the `if` would run as the
	// block ended, while `bound` is still read below).
	bound := session_bound_hostname(options, allocator)
	defer delete_bound_hostname(bound, allocator)
	hostname := bound
	if hostname == "" {
		// httpie's HACK/FIXME for URLs without a hostname.
		hostname = "localhost"
	}
	location.bound_host = clone_before_colon(hostname, allocator) or_else ""

	if strings.contains(name, "/") {
		location.anonymous = true
		location.path = expand_user_path(options, name, allocator) or_else ""
		location.session_id = strings.clone(location.path, allocator) or_else ""
		return location, location.path != ""
	}

	directory, has_directory := config_directory(options.env, allocator)
	if !has_directory {
		return location, false
	}
	defer delete(directory, allocator)

	host_dir := session_host_dir(hostname, allocator)
	defer delete(host_dir, allocator)
	location.path = fmt.aprintf(
		"%s/%s/%s/%s.json",
		directory,
		SESSIONS_DIR_NAME,
		host_dir,
		name,
		allocator = allocator,
	)
	location.session_id = strings.clone(name, allocator) or_else ""
	return location, true
}

// delete_bound_hostname releases a hostname `session_bound_hostname` handed
// back: only a non-empty result was cloned, and the empty spelling is a literal
// the caller must not free.
@(private)
delete_bound_hostname :: proc(hostname: string, allocator: mem.Allocator) {
	if hostname != "" {
		delete(hostname, allocator)
	}
}

// session_host_dir is `<host>_<port>`, the directory component
// `get_httpie_session` puts a named session in: the bound hostname with every
// `:` replaced by `_` (sessions.py:118, docs/PARITY.md §6.3).
//
// The result is *always* an allocation, which is what the caller's `defer
// delete` needs. `strings.replace_all` answers `(output, was_allocation)` and
// hands its input back untouched with `was_allocation = false` when there is no
// `:` to replace (core:strings' own doc: `xyzxyz` -> `xyzxyz false`) — so
// reading that bool as "did it work" with `or_else` collapses the whole host
// component of a default-port URL to `""`, and `example.org` becomes the path
// `sessions//<name>.json` (POSIX collapses the double slash, so the file lands
// one directory up, where the reference never looks). The borrowed spelling is
// cloned instead: `hostname` is never empty here (`session_location`'s
// "localhost" fallback), and a clone of it is the owned string the caller
// releases.
@(private)
session_host_dir :: proc(hostname: string, allocator: mem.Allocator) -> string {
	replaced, was_allocation := strings.replace_all(hostname, ":", "_", allocator)
	if was_allocation {
		return replaced
	}
	return strings.clone(hostname, allocator) or_else ""
}

// session_bound_hostname is httpie's `host or url_as_host(url)`: the Host
// header item when the command line carries one, else the URL's netloc with its
// userinfo stripped (sessions.py:92-95, utils.py:266-267). "" means "the URL
// has no hostname at all", which get_httpie_session turns into "localhost".
//
// The item's spelling is read through the item header dict's fold, which is
// what `args.headers.get('Host')` answers: `False` for a `Host:` the user
// unset — the `None` it left there is falsy, exactly like the empty value
// `Host;` leaves — and otherwise the *first* value the name accumulated (a
// `Host:` after a `Host:foo` dropped `foo`, so the name has no value at all).
// Both falsy cases fall through to the URL's own host: the fold's slot still
// *names* the header, but `host or url_as_host(url)` reads a falsy `host` as
// "no host was given" and answers the URL, so stopping at the item with `""`
// would bind the session — and with it the file's path — to `localhost`
// (t_f853a088). The fall-through is the loop's `break`, not a `return`.
@(private)
session_bound_hostname :: proc(options: ^cli.Options, allocator: mem.Allocator) -> string {
	fold := cli.header_fold(&options.item_set, allocator)
	defer cli.header_fold_destroy(&fold)
	for entry in fold.entries {
		if !strings.equal_fold(entry.name, "Host") {
			continue
		}
		// An unset, and an empty value, are both falsy for the reference and
		// carry no hostname at all, so the URL's own host is the answer.
		if entry.unset || len(entry.values) == 0 || entry.values[0].value == "" {
			break
		}
		return strings.clone(entry.values[0].value, allocator) or_else ""
	}

	return session_url_host(options, allocator)
}

// session_url_host is `url_as_host(url)` — `urlsplit(url).netloc.split('@')[-1]`
// (utils.py:266-267) — read over the URL the argparser's `_process_url` left
// behind rather than over argv (cli/argparser.py:205-225, client.py:50-57).
// That rule runs *before* the session is bound: a URL that named no scheme has
// the default one appended to it, the paste shortcut `://host` has its `://`
// dropped and the scheme appended, and the curl-style `:3000/x` is rebuilt as
// `<scheme>://localhost:3000/x` — so `urlsplit` never sees a schemeless string
// and reads the host out of the URL the rule built.
//
// The port's `url_split` is that same rule (`src/http/url.odin:99-122`), and
// its `host_port` is the authority `urlsplit` then reads as the netloc: it is
// where the URL's userinfo has already been dropped, where the shorthand's
// `localhost` is already prefixed, and where the authority already ends at the
// first `/`, `?` or `#`. The port must stay in the component — `url_as_host`
// answers the whole netloc, so the *joined* `prefix + text` is the host, not
// `url_split`'s separate `host`/`port`.
@(private)
session_url_host :: proc(options: ^cli.Options, allocator: mem.Allocator) -> string {
	target, split_err := http.url_split(options.url, options.default_scheme)
	if split_err != .None {
		return ""
	}
	joined := http.split_text_join(target.host_port, allocator)
	if joined == "" {
		return ""
	}
	// `split_text_join` allocates only when there is a prefix to join — the
	// shorthand's `localhost` — and that joined spelling is already the owned
	// string the caller releases; without one it is a slice of `options.url`
	// and the caller gets its own copy.
	if target.host_port.prefix != "" {
		return joined
	}
	return strings.clone(joined, allocator) or_else ""
}

// clone_before_colon is `strip_port`: everything before the first `:`.
@(private)
clone_before_colon :: proc(text: string, allocator: mem.Allocator) -> (result: string, ok: bool) {
	head := text
	if index := strings.index_byte(text, ':'); index >= 0 {
		head = text[:index]
	}
	if head == "" {
		return "", false
	}
	clone := strings.clone(head, allocator) or_else ""
	return clone, clone != ""
}

// expand_user_path is `os.path.expanduser`: `~` becomes $HOME, and a `~user`
// form that cannot be looked up is left alone.
@(private)
expand_user_path :: proc(
	options: ^cli.Options,
	name: string,
	allocator: mem.Allocator,
) -> (
	path: string,
	ok: bool,
) {
	if strings.has_prefix(name, "~") {
		if len(name) == 1 || name[1] == '/' {
			if home, found := cli.env_get(options.env, "HOME"); found && home != "" {
				path = strings.concatenate({home, name[1:]}, allocator) or_else ""
				return path, path != ""
			}
		}
	}
	path = strings.clone(name, allocator) or_else ""
	return path, path != ""
}

// config_directory is `get_default_config_dir` (config.py:20-58):
// $HTTPIE_CONFIG_DIR, else the legacy ~/.httpie when it already exists, else
// ($XDG_CONFIG_HOME or ~/.config)/httpie. The same resolution lives in
// src/cli/parse.odin, where it is private to that package; this card owns
// src/session only, so the twenty lines are repeated rather than exported.
@(private)
config_directory :: proc(
	env: cli.Env_Info,
	allocator: mem.Allocator,
) -> (
	directory: string,
	ok: bool,
) {
	if value, found := cli.env_get(env, "HTTPIE_CONFIG_DIR"); found && value != "" {
		directory = strings.clone(value, allocator) or_else ""
		return directory, directory != ""
	}
	home, has_home := cli.env_get(env, "HOME")
	if !has_home || home == "" {
		return "", false
	}
	legacy := strings.concatenate({home, "/.httpie"}, allocator) or_else ""
	if legacy != "" {
		if info, stat_err := os.stat(legacy, context.temp_allocator); stat_err == nil && info.type == .Directory {
			return legacy, true
		}
	}
	delete(legacy, allocator)
	if xdg, found := cli.env_get(env, "XDG_CONFIG_HOME"); found && xdg != "" {
		directory = strings.concatenate({xdg, "/httpie"}, allocator) or_else ""
		return directory, directory != ""
	}
	directory = strings.concatenate({home, "/.config/httpie"}, allocator) or_else ""
	return directory, directory != ""
}

// ---------------------------------------------------------------------------
// Reading the file
// ---------------------------------------------------------------------------

// session_load reads the file into the session. A missing file leaves the
// constructor's defaults in place and marks the session new; a file that is not
// JSON, or not a JSON object, is the reference's ConfigFileError.
@(private)
session_load :: proc(session: ^Session, log: output.Console, options: ^cli.Options) -> bool {
	allocator := session.allocator

	data, read_err := os.read_entire_file_from_path(session.path, allocator)
	if read_err != nil {
		if read_err == .Not_Exist {
			session.is_new = true
			return true
		}
		message := fmt.aprintf(
			"ConfigFileError: cannot read session file: %v [%s]",
			read_err,
			session.path,
			allocator = allocator,
		)
		defer delete(message, allocator)
		output.write_log_error(log, options.program_name, message)
		return false
	}
	defer delete(data, allocator)

	root, json_err := format.parse_json(string(data), allocator)
	if json_err.message != "" {
		message := fmt.aprintf(
			"ConfigFileError: invalid session file: %s [%s]",
			json_err.message,
			session.path,
			allocator = allocator,
		)
		format.json_error_destroy(&json_err)
		defer delete(message, allocator)
		output.write_log_error(log, options.program_name, message)
		return false
	}
	defer format.value_destroy(&root, allocator)

	data_object, is_object := root.(format.Object)
	if !is_object {
		message := fmt.aprintf(
			"ConfigFileError: invalid session file: the document is not an object [%s]",
			session.path,
			allocator = allocator,
		)
		defer delete(message, allocator)
		output.write_log_error(log, options.program_name, message)
		return false
	}

	if value, found := format.object_get(&data_object, "headers"); found {
		session_load_headers(session, value)
	}
	if value, found := format.object_get(&data_object, "cookies"); found {
		session_load_cookies(session, value)
	}
	if value, found := format.object_get(&data_object, "auth"); found {
		session_load_auth(session, value)
	}

	// A pre-3.1/pre-3.2 file is read as-is, but httpie's upgrade plugins tell
	// the user how to fix it (sessions.py:170-178). Only the first message is
	// shown: the cookies upgrade runs before the headers one and
	// `warn_legacy_usage` suppresses the rest of the run (sessions.py:310-322).
	if session.legacy_cookies_insecure {
		write_legacy_cookies_warning(session, log, options.program_name)
	} else if session.legacy_headers {
		write_legacy_headers_warning(session, log, options.program_name)
	}
	return true
}

// write_legacy_headers_warning is OLD_HEADER_STORE_WARNING
// (legacy/v3_2_0_session_header_format.py:8-19). `$INSERT_LINK` is a literal in
// the reference's output too: the session manager never substitutes it.
@(private)
write_legacy_headers_warning :: proc(session: ^Session, log: output.Console, program_name: string) {
	allocator := session.allocator
	message := strings.builder_make(allocator)
	strings.write_string(
		&message,
		"Outdated layout detected for the current session. Please consider updating it,\n" +
		"in order to use the latest features regarding the header layout.\n" +
		"\nFor fixing the current session:\n\n    $ httpie cli sessions upgrade ",
	)
	write_warning_target(&message, session)
	strings.write_string(&message, "\n")
	if !session.anonymous {
		strings.write_string(
			&message,
			"\nFor fixing all named sessions:\n\n    $ httpie cli sessions upgrade-all\n",
		)
	}
	strings.write_string(&message, "\nSee $INSERT_LINK for more information.")
	write_warning(session, log, program_name, &message)
}

// write_legacy_cookies_warning is INSECURE_COOKIE_JAR_WARNING
// (legacy/v3_1_0_session_cookie_format.py:8-34): the file's cookies have no
// domain, so any host the jar is used with would be sent them.
@(private)
write_legacy_cookies_warning :: proc(session: ^Session, log: output.Console, program_name: string) {
	allocator := session.allocator
	message := strings.builder_make(allocator)
	strings.write_string(
		&message,
		"Outdated layout detected for the current session. Please consider updating it,\n" +
		"in order to not get affected by potential security problems.\n" +
		"\nFor fixing the current session:\n\n" +
		"    With binding all cookies to the current host (secure):\n" +
		"        $ httpie cli sessions upgrade --bind-cookies ",
	)
	write_warning_target(&message, session)
	strings.write_string(
		&message,
		"\n\n    Without binding cookies (leaving them as is) (insecure):\n" +
		"        $ httpie cli sessions upgrade ",
	)
	write_warning_target(&message, session)
	strings.write_string(&message, "\n")
	if !session.anonymous {
		strings.write_string(
			&message,
			"\nFor fixing all named sessions:\n\n" +
			"    With binding all cookies to the current host (secure):\n" +
			"        $ httpie cli sessions upgrade-all --bind-cookies\n\n" +
			"    Without binding cookies (leaving them as is) (insecure):\n" +
			"        $ httpie cli sessions upgrade-all\n",
		)
	}
	strings.write_string(&message, "\nSee https://pie.co/docs/security for more information.")
	write_warning(session, log, program_name, &message)
}

// write_warning_target is the `{hostname} {session_id}` pair both upgrade
// commands are written with.
@(private)
write_warning_target :: proc(message: ^strings.Builder, session: ^Session) {
	strings.write_string(message, session.bound_host)
	strings.write_byte(message, ' ')
	strings.write_string(message, session.session_id)
}

@(private)
write_warning :: proc(
	session: ^Session,
	log: output.Console,
	program_name: string,
	message: ^strings.Builder,
) {
	text := strings.to_string(message^)
	output.write_log_warning(log, program_name, text)
	delete(text, session.allocator)
}

// session_load_headers reads `headers`, in either the file's list shape or the
// pre-3.2 object shape (legacy/v3_2_0_session_header_format.py).
@(private)
session_load_headers :: proc(session: ^Session, value: ^format.Value) {
	allocator := session.allocator
	#partial switch data in value^ {
	case format.Object:
		// The pre-3.2 layout: an object of name -> value. Reading it works,
		// the caller warns about it (legacy_headers).
		session.legacy_headers = true
		for member in data.members {
			// A value whose str carries an out-of-band surrogate is read as its
			// own bytes, exactly as it was before that representation existed
			// (format.string_parts).
			if !format.value_is_string(member.value) {
				continue
			}
			text, _ := format.string_parts(member.value)
			clone_header(&session.headers, member.key, text, allocator)
		}
	case []format.Value:
		for item in data {
			object, is_object := item.(format.Object)
			if !is_object {
				continue
			}
			name, has_name := json_string(&object, "name")
			header_value, has_value := json_string(&object, "value")
			if !has_name || !has_value {
				continue
			}
			clone_header(&session.headers, name, header_value, allocator)
		}
	}
}

// clone_header appends a header the session owns.
@(private)
clone_header :: proc(
	headers: ^[dynamic]http.Header,
	name: string,
	value: string,
	allocator: mem.Allocator,
) {
	header := http.Header {
		name  = strings.clone(name, allocator) or_else "",
		value = strings.clone(value, allocator) or_else "",
	}
	if _, err := append(headers, header); err != nil {
		delete(header.name, allocator)
		delete(header.value, allocator)
	}
}

// session_load_cookies reads `cookies`, in either the file's list shape or the
// pre-3.1 object shape (legacy/v3_1_0_session_cookie_format.py). A missing or
// null `domain` means a domainless cookie: the reference casts it to "" and
// remembers it with `_rest['is_explicit_none']` (sessions.py:145-155).
@(private)
session_load_cookies :: proc(session: ^Session, value: ^format.Value) {
	allocator := session.allocator
	#partial switch data in value^ {
	case format.Object:
		// The pre-3.1 layout. A domainless cookie in it is the security
		// problem the reference warns about (legacy/v3_1_0_session_cookie_format.py:48-62).
		for member in data.members {
			object, is_object := member.value.(format.Object)
			if !is_object {
				continue
			}
			cookie := cookie_from_json(&object, allocator)
			cookie.name = strings.clone(member.key, allocator) or_else cookie.name
			if cookie.domain == "" {
				session.legacy_cookies_insecure = true
			}
			append_cookie(&session.cookies, cookie, allocator)
		}
	case []format.Value:
		for item in data {
			object, is_object := item.(format.Object)
			if !is_object {
				continue
			}
			append_cookie(&session.cookies, cookie_from_json(&object, allocator), allocator)
		}
	}
}

// append_cookie takes ownership of `cookie`, except on failure.
@(private)
append_cookie :: proc(
	cookies: ^[dynamic]Cookie,
	cookie: Cookie,
	allocator: mem.Allocator,
) {
	if _, err := append(cookies, cookie); err != nil {
		owned := cookie
		cookie_destroy(&owned, allocator)
	}
}

// cookie_from_json materialises one cookie the way `Session._add_cookies` does.
@(private)
cookie_from_json :: proc(object: ^format.Object, allocator: mem.Allocator) -> Cookie {
	cookie: Cookie
	cookie.name = json_string_or(object, "name", allocator)
	cookie.value = json_string_or(object, "value", allocator)
	cookie.path = json_string_or(object, "path", allocator)
	if cookie.path == "" {
		cookie.path = strings.clone("/", allocator) or_else ""
	}
	cookie.secure, _ = json_bool(object, "secure")
	switch domain_value, found := format.object_get(object, "domain"); {
	case !found:
	case json_null(domain_value^):
		// domain == None: requests needs a string, so the reference stores ""
		// and flags it (sessions.py:148-154).
		cookie.explicit_none = true
	case:
		if !format.value_is_string(domain_value^) {
			break
		}
		text, _ := format.string_parts(domain_value^)
		cookie.domain = strings.clone(text, allocator) or_else ""
	}
	if expires_value, found := format.object_get(object, "expires"); found {
		if seconds, is_number := json_number(expires_value^); is_number {
			cookie.expires = i64(seconds)
			cookie.has_expires = true
		}
	}
	cookie.domain_specified = cookie.domain != ""
	return cookie
}

// session_load_auth reads the `auth` object. Both shapes are accepted: the new
// `{"type", "raw_auth"}` and the legacy `{"type", "username", "password"}`
// (sessions.py:272-304).
@(private)
session_load_auth :: proc(session: ^Session, value: ^format.Value) {
	allocator := session.allocator
	object, is_object := value^.(format.Object)
	if !is_object {
		return
	}
	auth: Auth
	if raw, found := json_string(&object, "raw_auth"); found {
		auth.kind = .New
		auth.raw_auth = strings.clone(raw, allocator) or_else ""
		auth.has_raw_auth = true
	} else {
		auth.kind = .Legacy
		if username, has_username := json_string(&object, "username"); has_username {
			auth.username = strings.clone(username, allocator) or_else ""
			auth.has_username = true
		}
		if password, has_password := json_string(&object, "password"); has_password {
			auth.password = strings.clone(password, allocator) or_else ""
			auth.has_password = true
		}
	}
	if auth_type, has_type := json_string(&object, "type"); has_type {
		auth.type = strings.clone(auth_type, allocator) or_else ""
		auth.has_type = true
	}
	if !auth.has_type && !auth.has_raw_auth && !auth.has_username && !auth.has_password {
		auth.kind = .Default
	}
	auth_destroy(&session.auth, allocator)
	session.auth = auth
}

@(private)
auth_destroy :: proc(auth: ^Auth, allocator: mem.Allocator) {
	delete(auth.type, allocator)
	delete(auth.raw_auth, allocator)
	delete(auth.username, allocator)
	delete(auth.password, allocator)
	auth^ = {}
}

// ---------------------------------------------------------------------------
// Writing the file
// ---------------------------------------------------------------------------

// session_finish is the tail of httpie's client (client.py:136-140): the file
// is written back unless the run is `--session-read-only` and the file already
// existed. `response` may be nil (the `--offline` path), in which case the jar
// is the one that was loaded.
session_finish :: proc(session: ^Session, response: ^http.Response) -> bool {
	if session == nil {
		return true
	}
	if response != nil {
		session_collect_cookies(session, response)
	}
	if session.read_only && !session.is_new {
		return true
	}
	return session_save(session)
}

// session_save writes the file the way `BaseConfigDict.save()` does, creating
// the session directory (0700) first.
@(private)
session_save :: proc(session: ^Session) -> bool {
	allocator := session.allocator

	if parent := parent_directory(session.path, allocator); parent != "" {
		defer delete(parent, allocator)
		if err := os.make_directory_all(parent, SESSION_DIR_MODE); err != nil && err != .Exist {
			return false
		}
	}

	text := session_json(session, allocator)
	defer delete(text, allocator)
	write_err := os.write_entire_file_from_bytes(
		session.path,
		transmute([]u8)text,
		SESSION_FILE_MODE,
	)
	if write_err != nil {
		return false
	}
	// The mode `write_entire_file_from_bytes` was given only applies when the
	// file is *created*, so a session an older build (or httpie) wrote keeps its
	// 0644 until this line: SESSION_FILE_MODE is re-asserted on every save. The
	// failure is not fatal — the data is written and the hardening is
	// best-effort (the file is contained by its 0700 directory either way).
	_ = os.chmod(session.path, SESSION_FILE_MODE)
	return true
}

// parent_directory is `path.parent` for a path with at least one separator.
@(private)
parent_directory :: proc(path: string, allocator: mem.Allocator) -> string {
	index := strings.last_index_byte(path, '/')
	if index <= 0 {
		return ""
	}
	return strings.clone(path[:index], allocator) or_else ""
}

// session_json renders the session exactly as
// `json.dumps(..., indent=4, sort_keys=True, ensure_ascii=True)` plus the
// trailing newline does (config.py:110-128). The keys are written in the order
// sort_keys produces — `__meta__` < `auth` < `cookies` < `headers`, and sorted
// inside each object — and tests/session_store_test.odin pins the bytes against
// the reference's own capture.
session_json :: proc(session: ^Session, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)

	strings.write_string(&builder, "{\n")

	// __meta__
	strings.write_string(&builder, "    \"__meta__\": {\n")
	strings.write_string(&builder, "        \"about\": ")
	write_json_string(&builder, SESSION_ABOUT)
	strings.write_string(&builder, ",\n        \"help\": ")
	write_json_string(&builder, SESSION_HELP_URL)
	strings.write_string(&builder, ",\n        \"httpie\": ")
	write_json_string(&builder, SESSION_HTTPIE_VERSION)
	strings.write_string(&builder, "\n    },\n")

	// auth
	strings.write_string(&builder, "    \"auth\": {")
	write_auth(&builder, &session.auth)
	strings.write_string(&builder, "\n    },\n")

	// cookies
	strings.write_string(&builder, "    \"cookies\": ")
	if len(session.cookies) == 0 {
		strings.write_string(&builder, "[],\n")
	} else {
		strings.write_string(&builder, "[\n")
		for cookie, index in session.cookies {
			strings.write_string(&builder, "        {\n")
			strings.write_string(&builder, "            \"domain\": ")
			if cookie.explicit_none && cookie.domain == "" {
				strings.write_string(&builder, "null")
			} else {
				write_json_string(&builder, cookie.domain)
			}
			strings.write_string(&builder, ",\n            \"expires\": ")
			if cookie.has_expires {
				fmt.sbprintf(&builder, "%d", cookie.expires)
			} else {
				strings.write_string(&builder, "null")
			}
			strings.write_string(&builder, ",\n            \"name\": ")
			write_json_string(&builder, cookie.name)
			strings.write_string(&builder, ",\n            \"path\": ")
			write_json_string(&builder, cookie.path)
			strings.write_string(&builder, ",\n            \"secure\": ")
			strings.write_string(&builder, cookie.secure ? "true" : "false")
			strings.write_string(&builder, ",\n            \"value\": ")
			write_json_string(&builder, cookie.value)
			strings.write_string(&builder, "\n        }")
			strings.write_string(&builder, index + 1 < len(session.cookies) ? ",\n" : "\n")
		}
		strings.write_string(&builder, "    ],\n")
	}

	// headers
	strings.write_string(&builder, "    \"headers\": ")
	if len(session.headers) == 0 {
		strings.write_string(&builder, "[]\n")
	} else {
		strings.write_string(&builder, "[\n")
		for header, index in session.headers {
			strings.write_string(&builder, "        {\n            \"name\": ")
			write_json_string(&builder, header.name)
			strings.write_string(&builder, ",\n            \"value\": ")
			write_json_string(&builder, header.value)
			strings.write_string(&builder, "\n        }")
			strings.write_string(&builder, index + 1 < len(session.headers) ? ",\n" : "\n")
		}
		strings.write_string(&builder, "    ]\n")
	}

	strings.write_string(&builder, "}\n")
	return strings.to_string(builder)
}

// write_auth writes the body of the `auth` object, in one of the three shapes.
@(private)
write_auth :: proc(builder: ^strings.Builder, auth: ^Auth) {
	switch auth.kind {
	case .New:
		strings.write_string(builder, "\n        \"raw_auth\": ")
		if auth.has_raw_auth {
			write_json_string(builder, auth.raw_auth)
		} else {
			strings.write_string(builder, "null")
		}
		strings.write_string(builder, ",\n        \"type\": ")
		if auth.has_type {
			write_json_string(builder, auth.type)
		} else {
			strings.write_string(builder, "null")
		}
	case .Legacy:
		strings.write_string(builder, "\n        \"password\": ")
		write_json_nullable_string(builder, auth.password, auth.has_password)
		strings.write_string(builder, ",\n        \"type\": ")
		write_json_nullable_string(builder, auth.type, auth.has_type)
		strings.write_string(builder, ",\n        \"username\": ")
		write_json_nullable_string(builder, auth.username, auth.has_username)
	case .Default:
		strings.write_string(builder, "\n        \"password\": null,\n        \"type\": null,")
		strings.write_string(builder, "\n        \"username\": null")
	}
}

@(private)
write_json_nullable_string :: proc(builder: ^strings.Builder, value: string, present: bool) {
	if !present {
		strings.write_string(builder, "null")
		return
	}
	write_json_string(builder, value)
}

// write_json_string writes one string the way `json.dumps(..., ensure_ascii=True)`
// does: the two escapes json shares with every JSON writer, the six short
// control escapes, `\u00xx` for the rest of them, and `\uXXXX` (a surrogate
// pair above the BMP) for everything that is not ASCII. DEL and the other
// printable ASCII bytes are written verbatim, as Python does.
@(private)
write_json_string :: proc(builder: ^strings.Builder, value: string) {
	strings.write_byte(builder, '"')
	for index := 0; index < len(value); {
		char := value[index]
		switch char {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case 8:
			strings.write_string(builder, "\\b")
		case 12:
			strings.write_string(builder, "\\f")
		case:
			if char < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", uint(char))
			} else if char < 0x80 {
				strings.write_byte(builder, char)
			} else {
				rune_value, size := utf8.decode_rune(value[index:])
				if size == 0 {
					rune_value, size = utf8.RUNE_ERROR, 1
				}
				if rune_value > 0xffff {
					rest := rune_value - 0x10000
					fmt.sbprintf(
						builder,
						"\\u%04x\\u%04x",
						uint(0xd800 + (rest >> 10)),
						uint(0xdc00 + (rest & 0x3ff)),
					)
				} else {
					fmt.sbprintf(builder, "\\u%04x", uint(rune_value))
				}
				index += size
				continue
			}
		}
		index += 1
	}
	strings.write_byte(builder, '"')
}

// ---------------------------------------------------------------------------
// Small JSON readers
// ---------------------------------------------------------------------------

@(private)
json_string :: proc(object: ^format.Object, key: string) -> (string, bool) {
	value, found := format.object_get(object, key)
	if !found {
		return "", false
	}
	// A string that carries an out-of-band surrogate answers with its own
	// bytes, the value the reader had before that representation existed.
	if !format.value_is_string(value^) {
		return "", false
	}
	text, _ := format.string_parts(value^)
	return text, true
}

@(private)
json_string_or :: proc(object: ^format.Object, key: string, allocator: mem.Allocator) -> string {
	text, found := json_string(object, key)
	if !found {
		return ""
	}
	return strings.clone(text, allocator) or_else ""
}

@(private)
json_bool :: proc(object: ^format.Object, key: string) -> (bool, bool) {
	value, found := format.object_get(object, key)
	if !found {
		return false, false
	}
	result, is_bool := value^.(bool)
	return result, is_bool
}

@(private)
json_number :: proc(value: format.Value) -> (f64, bool) {
	#partial switch number in value {
	case i64:
		return f64(number), true
	case f64:
		return number, true
	}
	return 0, false
}

@(private)
json_null :: proc(value: format.Value) -> bool {
	_, is_null := value.(format.Null)
	return is_null
}

// ---------------------------------------------------------------------------
// The request side: what the session contributes and what it records
// ---------------------------------------------------------------------------

// session_merge_headers is httpie's `base_headers` (client.py:48-63): the
// session's headers join the request before the item headers do, so they beat
// httpie's own defaults (Accept, User-Agent, ...) and lose to a `Header:value`
// argument on the command line.
session_merge_headers :: proc(session: ^Session, request: ^http.Request) -> bool {
	allocator := request.allocator
	for header in session.headers {
		// One name, one value: a session file can carry the same name twice,
		// and requests collapses those to the last value while it prepares the
		// request. Collapsing here keeps the wire bytes the same.
		if index := header_index(request.headers[:], header.name); index >= 0 {
			replacement := strings.clone(header.value, allocator) or_else ""
			delete(request.headers[index].value, allocator)
			request.headers[index].value = replacement
			continue
		}
		if err := http.request_add_header(request, header.name, header.value); err != .None {
			return false
		}
	}
	return true
}

// session_record_headers is `Session.update_headers` (sessions.py:200-256): the
// request's own headers become the file's header list — minus the per-request
// ones (Content-*, If-*), the User-Agent httpie generated, a Cookie header
// (whose cookies went into the jar) and any header an item unset — plus the
// session's previous headers for names the request no longer carries.
session_record_headers :: proc(
	session: ^Session,
	options: ^cli.Options,
	request: ^http.Request,
) -> bool {
	allocator := session.allocator
	previous := session.headers

	new_headers: [dynamic]http.Header

	// The automatic Accept is httpie's, added before the session's and the
	// items' headers (client.py:263-278, make_default_headers); a request that
	// carries an Accept of its own keeps that one. The header a body-less
	// request gets is requests' session default, which is not stored.
	if _, found := http.request_header_get(request, "Accept"); !found && request.json_accept {
		header := http.Header {
			name  = strings.clone("Accept", allocator) or_else "",
			value = strings.clone(http.JSON_ACCEPT, allocator) or_else "",
		}
		if _, err := append(&new_headers, header); err != nil {
			delete(header.name, allocator)
			delete(header.value, allocator)
			free_headers(&new_headers, allocator)
			return false
		}
	}

	for header in request.headers {
		if !session_stores_header(header.name, header.value, request.offline) {
			continue
		}
		stored := http.Header {
			name  = strings.clone(header.name, allocator) or_else "",
			value = strings.clone(header.value, allocator) or_else "",
		}
		if _, err := append(&new_headers, stored); err != nil {
			delete(stored.name, allocator)
			delete(stored.value, allocator)
			free_headers(&new_headers, allocator)
			return false
		}
	}

	// "New headers will take priority over the existing ones" (sessions.py): a
	// stored header the request does not carry is kept as it was.
	for header in previous {
		if header_index(new_headers[:], header.name) >= 0 {
			delete(header.name, allocator)
			delete(header.value, allocator)
			continue
		}
		if _, err := append(&new_headers, header); err != nil {
			delete(header.name, allocator)
			delete(header.value, allocator)
			free_headers(&new_headers, allocator)
			return false
		}
	}
	// Only the old backing array is released here: its strings were either
	// moved into `new_headers` or freed above.
	delete(previous)
	session.headers = new_headers
	return true
}

// free_headers releases a header list the session built but is not going to
// keep.
@(private)
free_headers :: proc(headers: ^[dynamic]http.Header, allocator: mem.Allocator) {
	for header in headers {
		delete(header.name, allocator)
		delete(header.value, allocator)
	}
	delete(headers^)
	headers^ = nil
}

// session_stores_header is the filter of `_compute_new_headers`
// (sessions.py:200-241).
//
// The one value it never sees is an unset: an item spelled `Name:` dropped the
// name from the request dict before this runs (`finalize_headers` skips the
// `None`, client.py:190-209), so the request carries no such header and the
// session keeps the value it already had. urllib3's three skippable names are
// the exception the reference records: their `None` became the SKIP_HEADER
// sentinel, which `_compute_new_headers` does *not* skip — it only skips
// `None` — so the sentinel is written to the file and, on a replay, behaves
// like the unset it came from (docs/PARITY.md §3.1).
@(private)
session_stores_header :: proc(name: string, value: string, offline: bool) -> bool {
	if strings.equal_fold(name, "Cookie") {
		// Its cookies go into the jar instead (sessions.py:222-232).
		return false
	}
	if strings.equal_fold(name, "User-Agent") && strings.has_prefix(value, "HTTPie/") {
		return false
	}
	for prefix in SESSION_IGNORED_HEADER_PREFIXES {
		if has_prefix_fold(name, prefix) {
			return false
		}
	}
	if strings.equal_fold(name, "Transfer-Encoding") && !offline {
		// httpie only sets the header itself for --offline; online, requests
		// adds it while preparing, and only what httpie set is stored
		// (client.py:305-309).
		return false
	}
	return true
}

// SESSION_IGNORED_HEADER_PREFIXES is sessions.py:35-37.
SESSION_IGNORED_HEADER_PREFIXES :: [?]string{"Content-", "If-"}

// has_prefix_fold is `name.lower().startswith(prefix.lower())`.
@(private)
has_prefix_fold :: proc(text: string, prefix: string) -> bool {
	if len(text) < len(prefix) {
		return false
	}
	return strings.equal_fold(text[:len(prefix)], prefix)
}

// header_index finds a header by name, case-insensitively.
@(private)
header_index :: proc(headers: []http.Header, name: string) -> int {
	for header, index in headers {
		if strings.equal_fold(header.name, name) {
			return index
		}
	}
	return -1
}

// session_record_auth stores the credentials the command line carried, in the
// new `{"type", "raw_auth"}` shape (client.py:77-81). Credentials httpie
// resolves from the URL or from .netrc are not stored: the reference writes the
// parser's own object there, and no captured session holds one.
session_record_auth :: proc(session: ^Session, options: ^cli.Options) -> bool {
	if options.auth == "" {
		return true
	}
	allocator := session.allocator
	auth := Auth {
		kind         = .New,
		type         = strings.clone(auth_type_name(options.auth_type), allocator) or_else "",
		has_type     = true,
		raw_auth     = strings.clone(options.auth, allocator) or_else "",
		has_raw_auth = true,
	}
	auth_destroy(&session.auth, allocator)
	session.auth = auth
	session.auth_given = true
	return true
}

// auth_type_name is the plugin's `auth_type` string, which is the name the
// session file records and `get_auth_plugin` looks up again (sessions.py:278).
@(private)
auth_type_name :: proc(auth_type: cli.Auth_Type) -> string {
	switch auth_type {
	case .Bearer:
		return "bearer"
	case .Digest:
		return "digest"
	case .Basic:
		return "basic"
	}
	return "basic"
}

// session_has_auth is `if httpie_session.auth:` (client.py:83): a stored `auth`
// the plugin registry knows about.
session_has_auth :: proc(session: ^Session) -> bool {
	if session == nil || !session.auth.has_type || session.auth.type == "" {
		return false
	}
	switch {
	case strings.equal_fold(session.auth.type, "basic"),
	     strings.equal_fold(session.auth.type, "bearer"),
	     strings.equal_fold(session.auth.type, "digest"):
		return true
	}
	return false
}

// session_auth_credentials is httpie's `plugin.get_auth(**credentials)`: the
// new shape carries "user:pass" (or the bearer token) in `raw_auth`, the legacy
// shape a username and a password. The caller owns the returned string.
session_auth_credentials :: proc(
	session: ^Session,
	allocator: mem.Allocator,
) -> (
	credentials: string,
	auth_type: http.Auth_Type,
	ok: bool,
) {
	switch {
	case strings.equal_fold(session.auth.type, "bearer"):
		auth_type = .Bearer
	case strings.equal_fold(session.auth.type, "digest"):
		auth_type = .Digest
	case strings.equal_fold(session.auth.type, "basic"):
		auth_type = .Basic
	case:
		return "", .Basic, false
	}

	if session.auth.kind == .New || session.auth.has_raw_auth {
		if !session.auth.has_raw_auth {
			return "", auth_type, false
		}
		credentials = strings.clone(session.auth.raw_auth, allocator) or_else ""
		return credentials, auth_type, credentials != ""
	}

	username := session.auth.username
	password := session.auth.password
	if !session.auth.has_username {
		return "", auth_type, false
	}
	if !session.auth.has_password {
		// A username with no password is the `http://user@host/` shape: the
		// empty password is what requests sends.
		password = ""
	}
	credentials = strings.concatenate({username, ":", password}, allocator) or_else ""
	return credentials, auth_type, true
}

// json_parse_int is Python's `int(text)` for the shapes a header value can
// carry: an optional sign and decimal digits.
@(private)
parse_int :: proc(text: string) -> (i64, bool) {
	value, ok := strconv.parse_i64(text)
	return value, ok
}
