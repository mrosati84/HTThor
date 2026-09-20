// These tests are the reason src/http/libcurl.odin can hardcode option numbers
// with only a comment for provenance: libcurl is asked, at run time, which
// number belongs to each option name, and the answer is compared with the
// constant. A typo or a copy from the wrong curl release fails here.
package tests

import "core:c"
import "core:testing"

import "src:http"

check_option :: proc(t: ^testing.T, name: cstring, option: http.CURLoption) {
	found := http.curl_easy_option_by_name(name)
	testing.expectf(t, found != nil, "libcurl has no option named %s", string(name))
	if found == nil {
		return
	}
	testing.expectf(
		t,
		found.id == option,
		"%s: libcurl says %d, src/http/libcurl.odin says %d",
		string(name),
		found.id,
		option,
	)
}

counting_write_callback :: proc "c" (data: [^]u8, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	return size * nmemb
}

@(test)
test_option_constants_match_libcurl :: proc(t: ^testing.T) {
	check_option(t, "URL", http.CURLOPT_URL)
	check_option(t, "PROXY", http.CURLOPT_PROXY)
	check_option(t, "USERPWD", http.CURLOPT_USERPWD)
	check_option(t, "ERRORBUFFER", http.CURLOPT_ERRORBUFFER)
	check_option(t, "TIMEOUT", http.CURLOPT_TIMEOUT)
	check_option(t, "INFILESIZE", http.CURLOPT_INFILESIZE)
	check_option(t, "VERBOSE", http.CURLOPT_VERBOSE)
	check_option(t, "NOBODY", http.CURLOPT_NOBODY)
	check_option(t, "UPLOAD", http.CURLOPT_UPLOAD)
	check_option(t, "POST", http.CURLOPT_POST)
	check_option(t, "FOLLOWLOCATION", http.CURLOPT_FOLLOWLOCATION)
	check_option(t, "POSTFIELDSIZE", http.CURLOPT_POSTFIELDSIZE)
	check_option(t, "SSL_VERIFYPEER", http.CURLOPT_SSL_VERIFYPEER)
	check_option(t, "MAXREDIRS", http.CURLOPT_MAXREDIRS)
	check_option(t, "CONNECTTIMEOUT", http.CURLOPT_CONNECTTIMEOUT)
	check_option(t, "HTTPGET", http.CURLOPT_HTTPGET)
	check_option(t, "SSL_VERIFYHOST", http.CURLOPT_SSL_VERIFYHOST)
	check_option(t, "HTTP_VERSION", http.CURLOPT_HTTP_VERSION)
	check_option(t, "NOSIGNAL", http.CURLOPT_NOSIGNAL)
	check_option(t, "HTTPAUTH", http.CURLOPT_HTTPAUTH)
	check_option(t, "PATH_AS_IS", http.CURLOPT_PATH_AS_IS)
	check_option(t, "WRITEDATA", http.CURLOPT_WRITEDATA)
	check_option(t, "READDATA", http.CURLOPT_READDATA)
	check_option(t, "POSTFIELDS", http.CURLOPT_POSTFIELDS)
	check_option(t, "HTTPHEADER", http.CURLOPT_HTTPHEADER)
	check_option(t, "SSLCERT", http.CURLOPT_SSLCERT)
	check_option(t, "HEADERDATA", http.CURLOPT_HEADERDATA)
	check_option(t, "CUSTOMREQUEST", http.CURLOPT_CUSTOMREQUEST)
	check_option(t, "CAINFO", http.CURLOPT_CAINFO)
	check_option(t, "SSL_CIPHER_LIST", http.CURLOPT_SSL_CIPHER_LIST)
	check_option(t, "KEYPASSWD", http.CURLOPT_KEYPASSWD)
	check_option(t, "SSLKEY", http.CURLOPT_SSLKEY)
	check_option(t, "ACCEPT_ENCODING", http.CURLOPT_ACCEPT_ENCODING)
	check_option(t, "WRITEFUNCTION", http.CURLOPT_WRITEFUNCTION)
	check_option(t, "READFUNCTION", http.CURLOPT_READFUNCTION)
	check_option(t, "HEADERFUNCTION", http.CURLOPT_HEADERFUNCTION)

	// The info ids are not in the option table, so they are checked against the
	// two CURLINFO type bases instead (curl.h: STRING = 0x100000, LONG = 0x200000).
	testing.expect_value(t, c.int(http.CURLINFO_EFFECTIVE_URL), c.int(0x100001))
	testing.expect_value(t, c.int(http.CURLINFO_RESPONSE_CODE), c.int(0x200002))
}

@(test)
test_easy_handle_accepts_every_option_the_engine_sets :: proc(t: ^testing.T) {
	code := http.curl_global_init(http.CURL_GLOBAL_DEFAULT)
	testing.expect_value(t, code, http.CURLE_OK)
	defer http.curl_global_cleanup()

	handle := http.curl_easy_init()
	testing.expect(t, handle != nil, "curl_easy_init returned nil")
	if handle == nil {
		return
	}
	defer http.curl_easy_cleanup(handle)

	checks := [?]struct {
		name: string,
		code: http.CURLcode,
	}{
		{"URL", http.setopt_string(handle, http.CURLOPT_URL, "http://127.0.0.1:1/")},
		{"CUSTOMREQUEST", http.setopt_string(handle, http.CURLOPT_CUSTOMREQUEST, "GET")},
		{"WRITEFUNCTION", http.setopt_write_callback(handle, http.CURLOPT_WRITEFUNCTION, counting_write_callback)},
		{"HEADERFUNCTION", http.setopt_header_callback(handle, http.CURLOPT_HEADERFUNCTION, counting_write_callback)},
		{"WRITEDATA", http.setopt_ptr(handle, http.CURLOPT_WRITEDATA, nil)},
		{"FOLLOWLOCATION", http.setopt_long(handle, http.CURLOPT_FOLLOWLOCATION, 1)},
		{"MAXREDIRS", http.setopt_long(handle, http.CURLOPT_MAXREDIRS, 5)},
		{"TIMEOUT", http.setopt_long(handle, http.CURLOPT_TIMEOUT, 1)},
		{"CONNECTTIMEOUT", http.setopt_long(handle, http.CURLOPT_CONNECTTIMEOUT, 1)},
		{"SSL_VERIFYPEER", http.setopt_long(handle, http.CURLOPT_SSL_VERIFYPEER, 1)},
		{"SSL_VERIFYHOST", http.setopt_long(handle, http.CURLOPT_SSL_VERIFYHOST, 2)},
		{"ACCEPT_ENCODING", http.setopt_string(handle, http.CURLOPT_ACCEPT_ENCODING, "")},
		{"NOSIGNAL", http.setopt_long(handle, http.CURLOPT_NOSIGNAL, 1)},
		{"NOBODY", http.setopt_long(handle, http.CURLOPT_NOBODY, 0)},
	}
	for check in checks {
		testing.expectf(
			t,
			check.code == http.CURLE_OK,
			"setting %s failed: %s",
			check.name,
			string(http.curl_easy_strerror(check.code)),
		)
	}

	// 200 (the default) means "do not enforce"), 3 maps to CURLAUTH_ANYSAFE.
	testing.expect_value(t, http.setopt_long(handle, http.CURLOPT_HTTPAUTH, http.CURLAUTH_BASIC), http.CURLE_OK)

	version := http.curl_version()
	testing.expect(t, version != nil, "curl_version returned nil")
	if version != nil {
		testing.expectf(t, len(string(version)) > 0, "unexpected version string: %q", string(version))
	}

	// Reset must leave the handle usable for the next transfer.
	http.curl_easy_reset(handle)
	testing.expect_value(
		t,
		http.setopt_string(handle, http.CURLOPT_URL, "http://127.0.0.1:1/"),
		http.CURLE_OK,
	)
}

// A real transfer, on loopback, against a port nothing listens on: the wrapper
// must reach the network stack and map libcurl's failure to its own vocabulary.
// The engine task (t_3d62ca31) replaces this with an echo-server round trip.
@(test)
test_perform_reports_connection_refused :: proc(t: ^testing.T) {
	code := http.curl_global_init(http.CURL_GLOBAL_DEFAULT)
	testing.expect_value(t, code, http.CURLE_OK)
	defer http.curl_global_cleanup()

	handle := http.curl_easy_init()
	testing.expect(t, handle != nil, "curl_easy_init returned nil")
	if handle == nil {
		return
	}
	defer http.curl_easy_cleanup(handle)

	testing.expect_value(t, http.setopt_string(handle, http.CURLOPT_URL, "http://127.0.0.1:1/"), http.CURLE_OK)
	testing.expect_value(t, http.setopt_long(handle, http.CURLOPT_TIMEOUT, 2), http.CURLE_OK)
	testing.expect_value(t, http.setopt_long(handle, http.CURLOPT_NOSIGNAL, 1), http.CURLE_OK)

	perform_code := http.curl_easy_perform(handle)
	testing.expectf(
		t,
		perform_code == http.CURLE_COULDNT_CONNECT,
		"expected CURLE_COULDNT_CONNECT (%d), got %d (%s)",
		http.CURLE_COULDNT_CONNECT,
		perform_code,
		string(http.curl_easy_strerror(perform_code)),
	)
}
