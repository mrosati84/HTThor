// The cookie half of a session: the jar that travels in the session file, the
// `Set-Cookie` replies that feed it, and the `Cookie` header it turns into.
//
// httpie delegates all of this to `requests`' jar (httpie/sessions.py,
// http/cookiejar.py's DefaultCookiePolicy — httpie only overrides the "is this
// host secure" rule with its HTTPieCookiePolicy, cookies.py). The rules here
// are therefore RFC 6265's, which is what that jar implements: a host-only
// cookie goes back to its own host, a Domain cookie to that domain and its
// subdomains, a Path is a prefix rule, and an expired cookie is never sent.
package session

import "core:mem"
import "core:strings"
import "core:time"

import "src:http"

// ---------------------------------------------------------------------------
// The jar
// ---------------------------------------------------------------------------

// session_collect_cookies is requests' `extract_cookies_to_jar` for one
// exchange (requests/sessions.py:send) plus httpie's expired-cookie cleanup
// (client.py:120-139): every Set-Cookie of every hop updates the jar.
session_collect_cookies :: proc(session: ^Session, response: ^http.Response) {
	if response == nil {
		return
	}
	now := time.time_to_unix(time.now())
	for hop in response.history {
		collect_response_cookies(session, hop.headers, hop.url, now)
	}
	collect_response_cookies(session, response.headers, response.url, now)
}

@(private)
collect_response_cookies :: proc(
	session: ^Session,
	headers: []http.Header,
	url: string,
	now: i64,
) {
	target, split_err := http.url_split(url, nil)
	if split_err != .None {
		return
	}
	request_path := target.path
	if request_path == "" {
		request_path = "/"
	}
	for header in headers {
		if !strings.equal_fold(header.name, "Set-Cookie") {
			continue
		}
		session_store_set_cookie(session, header.value, target.host, request_path, now)
	}
}

// session_store_set_cookie is one `jar.set` after `make_cookies`: a cookie the
// policy rejects is dropped, an expired one deletes the stored cookie of the
// same name and path, and anything else replaces the cookie it shadows.
@(private)
session_store_set_cookie :: proc(
	session: ^Session,
	text: string,
	host: string,
	request_path: string,
	now: i64,
) {
	allocator := session.allocator
	cookie, usable := cookie_from_set_cookie(text, host, request_path, now, allocator)
	if !usable {
		// The reply expired the cookie: httpie removes the stored one by name
		// and path (client.py:139, utils.py:156-186).
		session_remove_cookie(session, cookie.name, cookie.path)
		cookie_destroy(&cookie, allocator)
		return
	}
	if cookie.name == "" || !cookie_domain_ok(&cookie, host) {
		cookie_destroy(&cookie, allocator)
		return
	}
	for &existing, index in session.cookies {
		if cookie_same_slot(&existing, &cookie) {
			cookie_destroy(&existing, allocator)
			session.cookies[index] = cookie
			return
		}
	}
	append_cookie(&session.cookies, cookie, allocator)
}

// session_remove_cookie drops the cookie with this name and path
// (`requests.cookies.remove_cookie_by_name`).
@(private)
session_remove_cookie :: proc(session: ^Session, name: string, path: string) {
	allocator := session.allocator
	index := 0
	for index < len(session.cookies) {
		cookie := &session.cookies[index]
		if strings.equal_fold(cookie.name, name) && cookie.path == path {
			cookie_destroy(cookie, allocator)
			ordered_remove(&session.cookies, index)
			continue
		}
		index += 1
	}
}

// cookie_same_slot reports whether two cookies occupy the jar's one slot for a
// name: the reference's jar is keyed by (domain, path, name).
@(private)
cookie_same_slot :: proc(a: ^Cookie, b: ^Cookie) -> bool {
	return strings.equal_fold(a.name, b.name) &&
	       strings.equal_fold(a.domain, b.domain) &&
	       a.path == b.path
}

// session_apply_cookies adds the `Cookie` request header the jar produces for
// this request, unless the command line already set one
// (CookieJar.add_cookie_header: `if not request.has_header("Cookie")`).
session_apply_cookies :: proc(session: ^Session, request: ^http.Request) {
	if session == nil || len(session.cookies) == 0 {
		return
	}
	if _, found := http.request_header_get(request, "Cookie"); found {
		return
	}

	allocator := session.allocator
	request_path := request.path
	if request_path == "" {
		request_path = "/"
	}
	secure := request.scheme == .HTTPS
	now := time.time_to_unix(time.now())

	indices: [dynamic]int
	defer delete(indices)
	for &cookie, index in session.cookies {
		if cookie_applies(&cookie, request.host, request_path, secure, now) {
			append(&indices, index)
		}
	}
	if len(indices) == 0 {
		return
	}

	// http/cookiejar.py's `_cookie_attrs` sends the longest path first; the
	// sort is stable, so equally specific cookies keep the jar's order.
	for i in 1 ..< len(indices) {
		j := i
		for j > 0 && len(session.cookies[indices[j - 1]].path) < len(session.cookies[indices[j]].path) {
			indices[j - 1], indices[j] = indices[j], indices[j - 1]
			j -= 1
		}
	}

	builder := strings.builder_make(allocator)
	for index, position in indices {
		if position > 0 {
			strings.write_string(&builder, "; ")
		}
		cookie := &session.cookies[index]
		strings.write_string(&builder, cookie.name)
		if cookie.value != "" {
			strings.write_byte(&builder, '=')
			strings.write_string(&builder, cookie.value)
		}
	}
	// The builder's buffer is handed over as the string (json.odin:628-634 has
	// the same shape), so this is the one free site for it.
	value := strings.to_string(builder)
	defer delete(value, allocator)
	_ = http.request_add_header(request, "Cookie", value)
}

// cookie_applies is `CookiePolicy.return_ok` for one cookie: an expired or
// secure-on-http cookie stays in the jar but does not travel, and the domain
// and path have to match the request.
@(private)
cookie_applies :: proc(
	cookie: ^Cookie,
	host: string,
	request_path: string,
	secure: bool,
	now: i64,
) -> bool {
	if cookie.has_expires && cookie.expires <= now {
		return false
	}
	if cookie.secure && !secure && !is_local_host(host) {
		return false
	}
	return cookie_domain_ok(cookie, host) && cookie_path_ok(cookie.path, request_path)
}

// cookie_domain_ok is RFC 6265 §5.3's domain-match: a host-only cookie only
// goes back to the host that set it, a Domain cookie to that domain and its
// subdomains. A domainless cookie from a legacy file is sent everywhere, which
// is what requests does with the `""` domain it stores for those.
@(private)
cookie_domain_ok :: proc(cookie: ^Cookie, host: string) -> bool {
	if cookie.domain == "" {
		return true
	}
	host_lower := lowercased(host)
	domain := lowercased(cookie.domain)
	if strings.has_prefix(domain, ".") {
		domain = domain[1:]
	}
	if !cookie.domain_specified {
		return host_lower == domain
	}
	if host_lower == domain {
		return true
	}
	suffix := strings.concatenate({".", domain}, context.temp_allocator) or_else ""
	return suffix != "" && strings.has_suffix(host_lower, suffix)
}

// cookie_path_ok is `DefaultCookiePolicy.path_return_ok`: the cookie's path is
// a prefix of the request's, on a `/` boundary.
@(private)
cookie_path_ok :: proc(path: string, request_path: string) -> bool {
	if path == "" {
		return true
	}
	if request_path == path {
		return true
	}
	if !strings.has_prefix(request_path, path) {
		return false
	}
	if strings.has_suffix(path, "/") {
		return true
	}
	return len(request_path) > len(path) && request_path[len(path)] == '/'
}

// is_local_host is HTTPieCookiePolicy's Firefox-inspired localhost rule: a
// secure cookie is still sent to `localhost` over plain http.
@(private)
is_local_host :: proc(host: string) -> bool {
	lower := lowercased(host)
	return lower == "localhost" || strings.has_suffix(lower, ".localhost")
}

// lowercased is `str.lower()`; without an upper-case byte it borrows `text`,
// which is what the callers above want.
@(private)
lowercased :: proc(text: string) -> string {
	for index in 0 ..< len(text) {
		if text[index] >= 'A' && text[index] <= 'Z' {
			return strings.to_lower(text, context.temp_allocator) or_else text
		}
	}
	return text
}

// ---------------------------------------------------------------------------
// Reading `Set-Cookie`
// ---------------------------------------------------------------------------

// cookie_from_set_cookie parses one `Set-Cookie` line into the jar's shape for
// a reply that arrived at `host`/`request_path` (RFC 6265 §5.2 + §5.3).
// `usable` is false for a cookie the reply expired, which the caller turns into
// a deletion.
@(private)
cookie_from_set_cookie :: proc(
	text: string,
	host: string,
	request_path: string,
	now: i64,
	allocator: mem.Allocator,
) -> (
	cookie: Cookie,
	usable: bool,
) {
	cookie.path = strings.clone("/", allocator) or_else ""
	cookie.domain = strings.clone(lowercased(host), allocator) or_else ""
	usable = true

	pair, attributes := split_once(text, ";")
	name, value := split_once(pair, "=")
	cookie.name = strings.clone(strings.trim_space(name), allocator) or_else ""
	cookie.value = strings.clone(unquoted(strings.trim_space(value)), allocator) or_else ""

	path_attribute := ""
	domain_attribute := ""
	max_age: i64 = 0
	has_max_age := false
	expires: i64 = 0
	has_expires := false

	for attribute in split_semicolons(attributes) {
		key, attribute_value := split_once(attribute, "=")
		key = strings.trim_space(key)
		attribute_value = strings.trim_space(attribute_value)
		switch {
		case strings.equal_fold(key, "path"):
			path_attribute = attribute_value
		case strings.equal_fold(key, "domain"):
			domain_attribute = attribute_value
		case strings.equal_fold(key, "secure"):
			cookie.secure = true
		case strings.equal_fold(key, "expires"):
			if seconds, ok := parse_http_date(attribute_value); ok {
				expires = seconds
				has_expires = true
			}
		case strings.equal_fold(key, "max-age"):
			if seconds, ok := parse_int(attribute_value); ok {
				max_age = seconds
				has_max_age = true
			}
		}
	}

	if domain_attribute != "" {
		delete(cookie.domain, allocator)
		cookie.domain = strings.clone(lowercased(domain_attribute), allocator) or_else ""
		cookie.domain_specified = true
	}
	if path_attribute != "" {
		delete(cookie.path, allocator)
		cookie.path = strings.clone(path_attribute, allocator) or_else ""
	} else {
		delete(cookie.path, allocator)
		cookie.path = strings.clone(default_cookie_path(request_path), allocator) or_else "/"
	}

	// A Max-Age overrides Expires (RFC 6265 §5.3 step 3).
	if has_max_age {
		if max_age <= 0 {
			return cookie, false
		}
		cookie.expires = now + max_age
		cookie.has_expires = true
	} else if has_expires {
		if expires <= now {
			return cookie, false
		}
		cookie.expires = expires
		cookie.has_expires = true
	}
	return cookie, true
}

// default_cookie_path is the RFC 6265 §5.1.4 default-path algorithm.
@(private)
default_cookie_path :: proc(request_path: string) -> string {
	if request_path == "" {
		return "/"
	}
	// The last `/` that is not the leading one ends the default path.
	index := strings.last_index_byte(request_path, '/')
	if index <= 0 {
		return "/"
	}
	return request_path[:index]
}

// split_once splits on the first occurrence of `separator`; the tail is empty
// when the separator is absent.
@(private)
split_once :: proc(text: string, separator: string) -> (head: string, tail: string) {
	index := strings.index(text, separator)
	if index < 0 {
		return text, ""
	}
	return text[:index], text[index + len(separator):]
}

// split_semicolons splits a Set-Cookie attribute list on `;`.
@(private)
split_semicolons :: proc(text: string) -> []string {
	parts := strings.split(text, ";", context.temp_allocator) or_else nil
	return parts
}

// unquoted strips one pair of surrounding double quotes, as cookiejar's
// `_unquote` does for a Netscape cookie value.
@(private)
unquoted :: proc(value: string) -> string {
	if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' {
		return value[1:len(value) - 1]
	}
	return value
}

// parse_http_date is `http.cookiejar.http2time` for the date formats
// Set-Cookie uses: the RFC 1123 form every modern server sends
// ("Sun, 20 Sep 2026 04:52:00 GMT"), plus the RFC 850 form. Only the UTC
// (`GMT`) reading matters here: that is the only zone the cookie spec allows.
@(private)
parse_http_date :: proc(text: string) -> (seconds: i64, ok: bool) {
	day, month, year: i64
	hour, minute, second: i64

	fields, fields_err := strings.fields(text, context.temp_allocator)
	if fields_err != nil || len(fields) < 5 {
		return 0, false
	}

	// Drop the weekday: RFC 1123 and RFC 850 carry it first (`Sun,`/`Sunday,`).
	index := 0
	if !is_digits(fields[0]) {
		index = 1
	}
	if len(fields) - index < 4 {
		return 0, false
	}

	if strings.contains(fields[index], "-") {
		// RFC 850: `06-Nov-94 08:49:37 GMT`.
		day_text, rest := split_once(fields[index], "-")
		month_text, year_text := split_once(rest, "-")
		day, ok = parse_int(day_text)
		if !ok {
			return 0, false
		}
		month, ok = month_number(month_text)
		if !ok {
			return 0, false
		}
		year, ok = parse_int(year_text)
		if !ok {
			return 0, false
		}
		if year < 100 {
			year += year < 70 ? 2000 : 1900
		}
		index += 1
	} else {
		// RFC 1123: `20 Sep 2026 04:52:00 GMT`.
		day, ok = parse_int(fields[index])
		if !ok {
			return 0, false
		}
		index += 1
		month, ok = month_number(fields[index])
		if !ok {
			return 0, false
		}
		index += 1
		year, ok = parse_int(fields[index])
		if !ok {
			return 0, false
		}
		index += 1
	}
	if index >= len(fields) {
		return 0, false
	}
	hour, minute, second, ok = parse_clock(fields[index])
	if !ok {
		return 0, false
	}
	total := days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
	return total, true
}

@(private)
is_digits :: proc(text: string) -> bool {
	if text == "" {
		return false
	}
	for index in 0 ..< len(text) {
		if text[index] < '0' || text[index] > '9' {
			return false
		}
	}
	return true
}

@(private)
parse_clock :: proc(text: string) -> (hour, minute, second: i64, ok: bool) {
	head, rest := split_once(text, ":")
	minute_text, second_text := split_once(rest, ":")
	if minute_text == "" || second_text == "" {
		return 0, 0, 0, false
	}
	hour, ok = parse_int(head)
	if !ok {
		return 0, 0, 0, false
	}
	minute, ok = parse_int(minute_text)
	if !ok {
		return 0, 0, 0, false
	}
	second, ok = parse_int(second_text)
	return hour, minute, second, ok
}

@(private)
month_number :: proc(name: string) -> (month: i64, ok: bool) {
	months := [?]string{
		"Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
	}
	if len(name) < 3 {
		return 0, false
	}
	for month_name, index in months {
		if strings.equal_fold(name[:3], month_name) {
			return i64(index + 1), true
		}
	}
	return 0, false
}

// days_from_civil is the days-since-epoch half of Howard Hinnant's
// civil-date algorithm, for a proleptic Gregorian date.
@(private)
days_from_civil :: proc(year, month, day: i64) -> i64 {
	y := year
	if month <= 2 {
		y -= 1
	}
	era := (y >= 0 ? y : y - 399) / 400
	year_of_era := y - era * 400
	day_of_year := (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
	day_of_era := year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
	return era * 146097 + day_of_era - 719468
}

// ---------------------------------------------------------------------------
// Reading cookies out of a request
// ---------------------------------------------------------------------------

// session_store_request_cookies is the `Cookie:` branch of
// `Session._compute_new_headers` (sessions.py:222-232): a Cookie header the
// command line set moves into the jar instead of into the stored headers.
// httpie parses it with `http.cookies.SimpleCookie`, so it is a list of
// `name=value` pairs, with any `Path`/`Domain` attribute applying to the pair
// it follows.
@(private)
session_store_request_cookies :: proc(session: ^Session, text: string, host: string) {
	allocator := session.allocator
	current: ^Cookie = nil

	for chunk in split_semicolons(text) {
		attribute := strings.trim_space(chunk)
		if attribute == "" {
			continue
		}
		key, value := split_once(attribute, "=")
		key = strings.trim_space(key)
		value = strings.trim_space(value)
		switch {
		case strings.equal_fold(key, "path"):
			if current != nil {
				delete(current.path, allocator)
				current.path = strings.clone(value != "" ? value : "/", allocator) or_else "/"
			}
			continue
		case strings.equal_fold(key, "domain"):
			if current != nil {
				delete(current.domain, allocator)
				current.domain = strings.clone(lowercased(value), allocator) or_else ""
				current.domain_specified = current.domain != ""
			}
			continue
		case strings.equal_fold(key, "secure"):
			if current != nil {
				current.secure = true
			}
			continue
		case strings.equal_fold(key, "expires"), strings.equal_fold(key, "max-age"),
		     strings.equal_fold(key, "httponly"), strings.equal_fold(key, "samesite"):
			// The jar keeps only what the session file records; the rest of the
			// attributes are dropped.
			continue
		}
		if key == "" {
			continue
		}
		cookie := Cookie {
			name   = strings.clone(key, allocator) or_else "",
			value  = strings.clone(unquoted(value), allocator) or_else "",
			path   = strings.clone("/", allocator) or_else "",
			domain = strings.clone(lowercased(host), allocator) or_else "",
		}
		if cookie.name == "" {
			cookie_destroy(&cookie, allocator)
			continue
		}
		replaced := false
		for &existing, index in session.cookies {
			if cookie_same_slot(&existing, &cookie) {
				cookie_destroy(&existing, allocator)
				session.cookies[index] = cookie
				replaced = true
				current = &session.cookies[index]
				break
			}
		}
		if !replaced {
			if _, err := append(&session.cookies, cookie); err != nil {
				cookie_destroy(&cookie, allocator)
				current = nil
				continue
			}
			current = &session.cookies[len(session.cookies) - 1]
		}
	}
}

// ---------------------------------------------------------------------------
// Ownership
// ---------------------------------------------------------------------------

cookie_destroy :: proc(cookie: ^Cookie, allocator: mem.Allocator) {
	delete(cookie.name, allocator)
	delete(cookie.value, allocator)
	delete(cookie.domain, allocator)
	delete(cookie.path, allocator)
	cookie^ = {}
}

cookie_destroy_all :: proc(cookies: []Cookie, allocator: mem.Allocator) {
	for &cookie in cookies {
		cookie_destroy(&cookie, allocator)
	}
}
