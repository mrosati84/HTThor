// Proxy selection.
//
// httpie goes through requests, which resolves proxies in this order:
//
//   1. `--proxy PROTOCOL:PROXY_URL` (the CLI picks the entry for the request's
//      scheme and the session copies it onto the Request);
//   2. the environment: `<scheme>_proxy` (lowercase first, then uppercase),
//      falling back to `all_proxy`/`ALL_PROXY`;
//   3. `no_proxy`/`NO_PROXY` disables the proxy again for the hosts it lists.
//
// The engine resolves the choice itself instead of letting libcurl do it,
// because libcurl's environment handling differs from requests' exactly where
// the parity harness would see it: it honours lowercase `http_proxy` only, it
// has its own no_proxy matcher, and it would also apply the environment when
// `--proxy` came from the command line. Setting CURLOPT_PROXY explicitly (to
// "" when there is no proxy) disables libcurl's own lookup, so there is one
// implementation of the rule here and it is testable.
package http

import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

// proxy_option_url returns the proxy URL of a `--proxy` entry. The flag's value
// grammar is `PROTOCOL:PROXY_URL` (docs/PARITY.md §2, definition.py:715-722:
// `KeyValueArgType(SEPARATOR_PROXY)` with `SEPARATOR_PROXY = ':'`), and the
// key/value split is the *first* colon — which is why `http:http://host:3128`
// is an HTTP proxy at `http://host:3128` and not a host called `http`. An entry
// with no colon at all is taken as the URL itself, so a caller that only has the
// URL can still set Request.proxy. The result borrows from `entry`.
proxy_option_url :: proc(entry: string) -> string {
	colon := strings.index(entry, ":")
	if colon < 0 {
		return entry
	}
	return entry[colon + 1:]
}

// proxy_entry_index is requests' select_proxy for the `--proxy` entries:
// client.py:302 turns the flags into `{key: value}`, so a repeated key keeps
// the *last* entry, and select_proxy looks for the request's scheme before
// falling back to `all`. -1 means "no entry applies"; the environment is next.
proxy_entry_index :: proc(req: ^Request, entries: []string) -> int {
	index := -1
	for entry, i in entries {
		if proxy_entry_key_is(entry, scheme_to_string(req.scheme)) {
			index = i
		}
	}
	if index >= 0 {
		return index
	}
	for entry, i in entries {
		if proxy_entry_key_is(entry, "all") {
			index = i
		}
	}
	return index
}

// proxy_entry_key_is reports whether `entry`'s `PROTOCOL` key is `key`.
proxy_entry_key_is :: proc(entry: string, key: string) -> bool {
	colon := strings.index(entry, ":")
	if colon <= 0 {
		return false
	}
	return strings.equal_fold(entry[:colon], key)
}

// proxy_url returns the proxy in the form libcurl wants. requests' rule is that
// a proxy without a scheme is an HTTP proxy, so the scheme is prepended here
// rather than left to libcurl's own guess. The caller owns the result.
proxy_url :: proc(proxy: string, allocator: mem.Allocator) -> (string, bool) {
	if proxy == "" {
		return "", false
	}
	if strings.contains(proxy, "://") {
		prepared, clone_err := strings.clone(proxy, allocator)
		return prepared, clone_err == .None
	}
	prepared, concat_err := strings.concatenate({"http://", proxy}, allocator)
	return prepared, concat_err == .None
}

// proxy_for resolves the proxy URL for `req`. `use` is false when the request
// must go direct (no proxy configured, or no_proxy matches the host).
//
// `scratch` is a caller-owned buffer the environment lookups write into
// (os.get_env_buf copies, it does not allocate): the returned proxy borrows
// from `req` or from `scratch`, so it lives until the caller reuses the buffer.
proxy_for :: proc(req: ^Request, scratch: []u8) -> (proxy: string, use: bool) {
	if no_proxy_matches(req.host, req.port, environment("no_proxy", "NO_PROXY", scratch)) {
		return "", false
	}

	proxy = req.proxy
	if proxy != "" {
		// The entry's `PROTOCOL:` mapping key is not part of the URL
		// (docs/PARITY.md §2, `--proxy PROTOCOL:PROXY_URL`).
		proxy = proxy_option_url(proxy)
	} else {
		switch req.scheme {
		case .HTTPS:
			proxy = environment("https_proxy", "HTTPS_PROXY", scratch)
			if proxy == "" {
				proxy = environment("all_proxy", "ALL_PROXY", scratch)
			}
		case .HTTP:
			proxy = environment("http_proxy", "HTTP_PROXY", scratch)
			if proxy == "" {
				proxy = environment("all_proxy", "ALL_PROXY", scratch)
			}
		}
	}
	return proxy, proxy != ""
}

// no_proxy_matches is requests' should_bypass_proxies: the list is split on
// commas with the spaces removed, and an entry matches when the hostname — or
// `host:port` — *ends with* it. That suffix rule is the reference behaviour
// ("example.com" therefore also matches "notexample.com"); it is replicated
// deliberately, not picked.
no_proxy_matches :: proc(host: string, port: int, list: string) -> bool {
	if list == "" || host == "" {
		return false
	}
	bare_host := host
	if strings.has_prefix(bare_host, "[") && strings.has_suffix(bare_host, "]") {
		// IPv6 literals keep their brackets in Request.host; the matcher works
		// on the bare address, the way urlparse does.
		bare_host = bare_host[1:len(bare_host) - 1]
	}

	rest := list
	for {
		entry, remainder, more := split_entry(rest)
		if entry_matches(bare_host, port, entry) {
			return true
		}
		if !more {
			break
		}
		rest = remainder
	}
	return false
}

entry_matches :: proc(host: string, port: int, entry: string) -> bool {
	if entry == "" {
		return false
	}
	if strings.has_suffix(host, entry) {
		return true
	}
	// "example.com:8080" only matches when the request uses that port.
	if colon := strings.last_index(entry, ":"); colon >= 0 && colon + 1 < len(entry) {
		if entry_port, ok := strconv.parse_int(entry[colon + 1:], 10); ok {
			return entry_port == port && strings.has_suffix(host, entry[:colon])
		}
	}
	return false
}

// split_entry pulls the next comma-separated no_proxy entry out of `list`,
// dropping the spaces requests strips before matching.
split_entry :: proc(list: string) -> (entry: string, remainder: string, more: bool) {
	comma := strings.index(list, ",")
	if comma < 0 {
		return strip_spaces(list), "", false
	}
	return strip_spaces(list[:comma]), list[comma + 1:], true
}

strip_spaces :: proc(s: string) -> string {
	result := s
	for len(result) > 0 && (result[0] == ' ' || result[0] == '\t') {
		result = result[1:]
	}
	for len(result) > 0 && (result[len(result) - 1] == ' ' || result[len(result) - 1] == '\t') {
		result = result[:len(result) - 1]
	}
	return result
}

// environment reads the lowercase name first and the uppercase one second,
// which is how requests' `get_proxy` resolves the names it uses. The value is
// copied into `scratch`, so nothing here allocates.
environment :: proc(lower: string, upper: string, scratch: []u8) -> string {
	if value := os.get_env(scratch, lower); value != "" {
		return value
	}
	return os.get_env(scratch, upper)
}
