// Thin `foreign import` wrapper over libcurl: the transport backend.
//
// Why libcurl at all, and why not core:net or the Odin distribution's own
// `vendor:curl`: docs/ARCHITECTURE.md, "HTTP/TLS backend". The short version:
// core:net has no TLS, and `vendor:curl` pins its Linux link line to
// mbedtls/mbedx509/mbedcrypto, which does not match the OpenSSL-backed libcurl
// that distributions actually ship.
//
// This is the only file in the project that talks to C. It declares exactly the
// ABI surface the engine uses and nothing else.
//
// Constant provenance: curl 8.5.0 headers (curl/curl.h, curl/options.h, where
// options are declared as CURLOPT(<name>, <type>, <n>), the numeric value being
// <type base> + <n>). CURLOPT_*/CURLINFO_*/CURLE_* numbers are libcurl ABI:
// they are stable and curl only ever appends to them. tests/libcurl_test.odin
// re-checks every option number below against `curl_easy_option_by_name` at
// run time, so a typo cannot survive `make test`.
package http

import "core:c"

foreign import libcurl "system:curl"

CURL       :: rawptr
CURLcode   :: c.int
CURLoption :: c.int
CURLINFO   :: c.int

// Opaque `struct curl_slist`: the type behind CURLOPT_HTTPHEADER.
CURL_slist :: struct {}

// `struct curl_easyoption`, used only to verify our constants against libcurl.
CURL_easyoption :: struct {
	name:  cstring,
	id:    CURLoption,
	type:  c.int, // curl_easytype
	flags: c.uint,
}

// curl_write_callback / curl_read_callback. Returning anything but the number
// of bytes libcurl handed us aborts the transfer.
CURL_write_callback :: #type proc "c" (data: [^]u8, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t
CURL_read_callback :: #type proc "c" (data: [^]u8, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t

CURL_WRITEFUNC_ERROR :: c.size_t(0xFFFFFFFF)

// CURLcode values (curl 8.5.0, curl.h).
CURLE_OK :: CURLcode(0)
CURLE_UNSUPPORTED_PROTOCOL :: CURLcode(1)
CURLE_FAILED_INIT :: CURLcode(2)
CURLE_URL_MALFORMAT :: CURLcode(3)
CURLE_COULDNT_RESOLVE_PROXY :: CURLcode(5)
CURLE_COULDNT_RESOLVE_HOST :: CURLcode(6)
CURLE_COULDNT_CONNECT :: CURLcode(7)
CURLE_PARTIAL_FILE :: CURLcode(18)
CURLE_HTTP_RETURNED_ERROR :: CURLcode(22)
CURLE_WRITE_ERROR :: CURLcode(23)
CURLE_OUT_OF_MEMORY :: CURLcode(27)
CURLE_OPERATION_TIMEDOUT :: CURLcode(28)
CURLE_SSL_CONNECT_ERROR :: CURLcode(35)
CURLE_TOO_MANY_REDIRECTS :: CURLcode(47)
CURLE_UNKNOWN_OPTION :: CURLcode(48)
CURLE_GOT_NOTHING :: CURLcode(52)
CURLE_SEND_ERROR :: CURLcode(55)
CURLE_RECV_ERROR :: CURLcode(56)
CURLE_SSL_CERTPROBLEM :: CURLcode(58)
CURLE_PEER_FAILED_VERIFICATION :: CURLcode(60)
CURLE_SSL_CIPHER :: CURLcode(59)
CURLE_SSL_CACERT_BADFILE :: CURLcode(77)
CURLE_SSL_ISSUER_ERROR :: CURLcode(83)
CURLE_SSL_PINNEDPUBKEYNOTMATCH :: CURLcode(90)

// curl_global_init flags (curl.h).
CURL_GLOBAL_ALL :: c.long((1 << 0) | (1 << 1))
CURL_GLOBAL_DEFAULT :: CURL_GLOBAL_ALL

// CURLOPT tick types (curl.h: CURLOPTTYPE_*). The value of an option is its
// tick type plus the index in the CURLOPT list.
CURLOPTTYPE_LONG :: 0
CURLOPTTYPE_OBJECTPOINT :: 10000
CURLOPTTYPE_STRINGPOINT :: 10000
CURLOPTTYPE_SLISTPOINT :: 10000
CURLOPTTYPE_CBPOINT :: 10000
CURLOPTTYPE_FUNCTIONPOINT :: 20000

// CURLOPT_* (curl 8.5.0, curl.h).
CURLOPT_TIMEOUT :: CURLoption(13)
CURLOPT_INFILESIZE :: CURLoption(14)
CURLOPT_VERBOSE :: CURLoption(41)
CURLOPT_NOBODY :: CURLoption(44)
CURLOPT_UPLOAD :: CURLoption(46)
CURLOPT_POST :: CURLoption(47)
CURLOPT_FOLLOWLOCATION :: CURLoption(52)
CURLOPT_POSTFIELDSIZE :: CURLoption(60)
CURLOPT_SSL_VERIFYPEER :: CURLoption(64)
CURLOPT_MAXREDIRS :: CURLoption(68)
CURLOPT_CONNECTTIMEOUT :: CURLoption(78)
CURLOPT_HTTPGET :: CURLoption(80)
CURLOPT_SSL_VERIFYHOST :: CURLoption(81)
CURLOPT_HTTP_VERSION :: CURLoption(84)
CURLOPT_NOSIGNAL :: CURLoption(99)
CURLOPT_HTTPAUTH :: CURLoption(107)
// The target the port hands libcurl is final — it removed the dot segments
// where the reference does (url_path_remove_dot_segments_into for the requested
// URL, url_join_reduced_path_into for a redirect target), so libcurl's own pass
// must not run over it. The number is the ABI's; build/probe_curlopt_ids.py
// reads it back out of the system libcurl through curl_easy_option_by_name.
CURLOPT_PATH_AS_IS :: CURLoption(234)
CURLOPT_WRITEDATA :: CURLoption(10001)
CURLOPT_URL :: CURLoption(10002)
CURLOPT_PROXY :: CURLoption(10004)
CURLOPT_USERPWD :: CURLoption(10005)
CURLOPT_READDATA :: CURLoption(10009)
CURLOPT_ERRORBUFFER :: CURLoption(10010)
CURLOPT_POSTFIELDS :: CURLoption(10015)
CURLOPT_HTTPHEADER :: CURLoption(10023)
CURLOPT_SSLCERT :: CURLoption(10025)
CURLOPT_HEADERDATA :: CURLoption(10029)
CURLOPT_CUSTOMREQUEST :: CURLoption(10036)
CURLOPT_CAINFO :: CURLoption(10065)
// `--ciphers`: the option is CURLOPTTYPE_STRINGPOINT + 83, verified against
// libcurl 8.5.0 with curl_easy_option_by_name — the same run-time check
// tests/libcurl_test.odin makes.
CURLOPT_SSL_CIPHER_LIST :: CURLoption(10083)
CURLOPT_SSLKEY :: CURLoption(10087)
CURLOPT_ACCEPT_ENCODING :: CURLoption(10102)
CURLOPT_KEYPASSWD :: CURLoption(10026)
CURLOPT_WRITEFUNCTION :: CURLoption(20011)
CURLOPT_READFUNCTION :: CURLoption(20012)
CURLOPT_HEADERFUNCTION :: CURLoption(20079)

// CURLINFO_* (curl.h; CURLINFO_STRING = 0x100000, CURLINFO_LONG = 0x200000).
CURLINFO_EFFECTIVE_URL :: CURLINFO(0x100001)
CURLINFO_RESPONSE_CODE :: CURLINFO(0x200002)

// CURLAUTH_* (curl.h). CURLAUTH_BASIC is the default and is set explicitly:
// without it, libcurl may answer a challenge with a scheme the caller did not
// ask for.
CURLAUTH_BASIC :: c.long(1 << 0)
CURLAUTH_DIGEST :: c.long(1 << 1)
CURLAUTH_BEARER :: c.long(1 << 6)

// curl_http_version (curl.h): httpie speaks HTTP/1.1 and nothing else, so the
// engine pins the version instead of letting libcurl negotiate h2/h3 (which
// would also change the status line the parser sees).
CURL_HTTP_VERSION_1_1 :: c.long(2)

// The libcurl entry points the engine needs, named exactly as in C (with
// `@(default_calling_convention="c")` supplying the ABI). Keeping the C names
// means a call site can be diffed against curl's own man pages.
@(default_calling_convention = "c")
foreign libcurl {
	curl_global_init         :: proc(flags: c.long) -> CURLcode ---
	curl_global_cleanup      :: proc() ---
	curl_version             :: proc() -> cstring ---

	curl_easy_init           :: proc() -> CURL ---
	curl_easy_cleanup        :: proc(handle: CURL) ---
	curl_easy_reset          :: proc(handle: CURL) ---
	curl_easy_setopt         :: proc(handle: CURL, option: CURLoption, #c_vararg args: ..any) -> CURLcode ---
	curl_easy_getinfo        :: proc(handle: CURL, info: CURLINFO, #c_vararg args: ..any) -> CURLcode ---
	curl_easy_perform        :: proc(handle: CURL) -> CURLcode ---
	curl_easy_strerror       :: proc(code: CURLcode) -> cstring ---
	curl_easy_option_by_name :: proc(name: cstring) -> ^CURL_easyoption ---
	curl_easy_escape         :: proc(handle: CURL, string: cstring, length: c.int) -> cstring ---
	curl_easy_unescape       :: proc(handle: CURL, string: cstring, length: c.int, outlength: ^c.int) -> cstring ---

	curl_slist_append        :: proc(list: ^CURL_slist, s: cstring) -> ^CURL_slist ---
	curl_slist_free_all      :: proc(list: ^CURL_slist) ---

	curl_free                :: proc(ptr: rawptr) ---
}

// setopt takes a `long` option value. The helpers below exist because
// curl_easy_setopt is variadic C: the option/value pairing cannot be checked by
// the Odin compiler, so the casts live in one place instead of at every call
// site.
setopt_long :: proc(handle: CURL, option: CURLoption, value: c.long) -> CURLcode {
	return curl_easy_setopt(handle, option, value)
}

setopt_string :: proc(handle: CURL, option: CURLoption, value: cstring) -> CURLcode {
	return curl_easy_setopt(handle, option, value)
}

setopt_ptr :: proc(handle: CURL, option: CURLoption, value: rawptr) -> CURLcode {
	return curl_easy_setopt(handle, option, value)
}

setopt_write_callback :: proc(handle: CURL, option: CURLoption, callback: CURL_write_callback) -> CURLcode {
	return curl_easy_setopt(handle, option, callback)
}

setopt_header_callback :: proc(handle: CURL, option: CURLoption, callback: CURL_write_callback) -> CURLcode {
	return curl_easy_setopt(handle, option, callback)
}

setopt_read_callback :: proc(handle: CURL, option: CURLoption, callback: CURL_read_callback) -> CURLcode {
	return curl_easy_setopt(handle, option, callback)
}
