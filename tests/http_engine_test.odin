// The engine's acceptance tests: real sockets, a real server, and the bytes
// that actually reach it.
//
// The server below is deliberately dumb — it records the raw bytes of every
// request it receives and answers with the next canned reply (or a short 200) —
// so what these tests assert is the *wire*, not the engine's own idea of what it
// sent. The body encodings are the parity contract (docs/PARITY.md §3.4).
//
// The helpers are local to this file (and prefixed `engine_`) so it also builds
// and runs on its own: `odin test tests/http_engine_test.odin`.
package tests

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "src:http"
import "src:output"

// ---------------------------------------------------------------------------
// A one-thread loopback HTTP server
// ---------------------------------------------------------------------------

ENGINE_READ_CHUNK :: 4096

// ENGINE_OK_REPLY answers any request with no canned reply queued.
ENGINE_OK_REPLY :: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"

Engine_Server :: struct {
	backing:  mem.Allocator,
	listener: net.TCP_Socket,
	worker:   ^thread.Thread,
	port:     int,
	// address is the loopback address the listener is bound to; the worker is
	// woken by dialing it on destroy, so the address and not just the port has
	// to be remembered (a cross-host case binds 127.0.0.2).
	address: net.IP4_Address,
	bound:   bool,

	mutex:     sync.Mutex,
	requests:  [dynamic]string,       // raw bytes of every request, in arrival order
	replies:   [dynamic]string,       // canned replies, consumed in order
	hold_open: [dynamic]net.TCP_Socket, // connections left hanging on purpose
	silent:    int,                   // how many connections to accept and not answer
	stop:      bool,
}

// engine_server_start binds 127.0.0.1:0 and starts serving. The listener is
// bound before the thread runs, so `port` is valid as soon as this returns.
engine_server_start :: proc(backing: mem.Allocator) -> (server: ^Engine_Server, ok: bool) {
	return engine_server_start_on(backing, net.IP4_Address { 127, 0, 0, 1 })
}

// engine_server_start_on is engine_server_start on another loopback address:
// the cookie cases need a sink that is a different *host* from the redirecting
// origin (another port keeps cookies, by design).
engine_server_start_on :: proc(backing: mem.Allocator, address: net.IP4_Address) -> (server: ^Engine_Server, ok: bool) {
	server = new(Engine_Server, backing)
	server.backing = backing
	server.requests = make([dynamic]string, 0, 4, backing)
	server.replies = make([dynamic]string, 0, 4, backing)
	server.hold_open = make([dynamic]net.TCP_Socket, 0, 2, backing)
	server.address = address

	endpoint := net.Endpoint {
		address = net.Address(address),
		port    = 0,
	}
	listener, listen_err := net.listen_tcp(endpoint)
	if listen_err != nil {
		engine_server_destroy(server)
		return nil, false
	}
	server.listener = listener
	server.bound = true

	bound, info_err := net.bound_endpoint(listener)
	if info_err != .None {
		engine_server_destroy(server)
		return nil, false
	}
	server.port = bound.port

	// `thread.create_and_start_with_data` starts the thread before returning, so
	// the server is already accepting when this function returns.
	server.worker = thread.create_and_start_with_data(rawptr(server), engine_server_worker)
	if server.worker == nil {
		engine_server_destroy(server)
		return nil, false
	}
	return server, true
}

engine_server_destroy :: proc(server: ^Engine_Server) {
	if server == nil {
		return
	}

	if server.worker != nil {
		sync.mutex_lock(&server.mutex)
		server.stop = true
		sync.mutex_unlock(&server.mutex)
		// The worker is blocked in accept(); one throwaway connection makes it
		// return, see `stop`, and leave. Joining before closing the listener
		// keeps the worker away from a socket this thread is freeing.
		if wake, dial_err := net.dial_tcp_from_address_and_port(
			net.Address(server.address),
			server.port,
		); dial_err == nil {
			net.close(wake)
		}
		thread.join(server.worker)
		thread.destroy(server.worker)
	}

	if server.bound {
		net.close(server.listener)
	}
	for socket in server.hold_open {
		net.close(socket)
	}
	delete(server.hold_open)
	for request in server.requests {
		delete(request, server.backing)
	}
	delete(server.requests)
	for reply in server.replies {
		delete(reply, server.backing)
	}
	delete(server.replies)
	free(server, server.backing)
}

engine_server_worker :: proc(data: rawptr) {
	server := (^Engine_Server)(data)
	for {
		client, _, accept_err := net.accept_tcp(server.listener)
		if accept_err != .None {
			return
		}

		sync.mutex_lock(&server.mutex)
		stopping := server.stop
		silent := server.silent > 0
		if silent {
			server.silent -= 1
		}
		sync.mutex_unlock(&server.mutex)

		if stopping {
			net.close(client)
			return
		}

		request, read_ok := engine_read_request(client, server.backing)
		if !read_ok {
			net.close(client)
			continue
		}

		reply := ""
		from_queue := false
		sync.mutex_lock(&server.mutex)
		append(&server.requests, request)
		if len(server.replies) > 0 {
			reply = server.replies[0]
			from_queue = true
			copy(server.replies[:], server.replies[1:])
			resize(&server.replies, len(server.replies) - 1)
		}
		sync.mutex_unlock(&server.mutex)

		if silent {
			// The timeout scenario: hold the connection open and never answer.
			sync.mutex_lock(&server.mutex)
			append(&server.hold_open, client)
			sync.mutex_unlock(&server.mutex)
			continue
		}
		if reply == "" {
			reply = ENGINE_OK_REPLY
		}
		net.send_tcp(client, transmute([]u8)reply)
		if from_queue {
			// The queue handed its reference to this request. Whether it was
			// the fallback or not is what decides that, not what the bytes
			// happen to say: queuing a reply identical to `ENGINE_OK_REPLY` is
			// a reply like any other.
			delete(reply, server.backing)
		}
		net.close(client)
	}
}

// engine_read_request reads one request — head and body — and hands the raw
// bytes to the caller, who frees them with `backing`.
engine_read_request :: proc(client: net.TCP_Socket, backing: mem.Allocator) -> (raw: string, ok: bool) {
	buffer := make([dynamic]u8, 0, ENGINE_READ_CHUNK, backing)
	head_end := -1
	for head_end < 0 {
		chunk: [ENGINE_READ_CHUNK]u8
		read, recv_err := net.recv_tcp(client, chunk[:])
		if recv_err != .None || read <= 0 {
			delete(buffer)
			return "", false
		}
		append(&buffer, ..chunk[:read])
		head_end = engine_head_end(buffer[:])
	}

	content_length := engine_content_length(string(buffer[:head_end]))
	for len(buffer) < head_end + content_length {
		chunk: [ENGINE_READ_CHUNK]u8
		read, recv_err := net.recv_tcp(client, chunk[:])
		if recv_err != .None || read <= 0 {
			delete(buffer)
			return "", false
		}
		append(&buffer, ..chunk[:read])
	}

	// A chunked upload announces no length: the only thing that says its body
	// is over is the terminating chunk, and a test that asks what a retry sent
	// (`0\r\n\r\n` and nothing else) needs the bytes that follow the framing —
	// not whatever happened to arrive alongside the head. The wait is bounded so
	// a request that never terminates fails the test instead of hanging it.
	if engine_is_chunked(string(buffer[:head_end])) {
		net.set_option(client, .Receive_Timeout, 5 * time.Second)
		for !engine_chunked_body_complete(buffer[:]) {
			chunk: [ENGINE_READ_CHUNK]u8
			read, recv_err := net.recv_tcp(client, chunk[:])
			if recv_err != .None || read <= 0 {
				break
			}
			append(&buffer, ..chunk[:read])
		}
	}
	return string(buffer[:]), true
}

// engine_is_chunked reports whether the head frames the body as chunks.
engine_is_chunked :: proc(head: string) -> bool {
	value, has := engine_header_of(head, "Transfer-Encoding")
	return has && strings.equal_fold(strings.trim_space(value), "chunked")
}

// engine_chunked_body_complete reports whether the bytes past the head end with
// the terminating chunk.
engine_chunked_body_complete :: proc(data: []u8) -> bool {
	head_end := engine_head_end(data)
	if head_end < 0 {
		return false
	}
	return strings.has_suffix(string(data[head_end:]), "0\r\n\r\n")
}

// engine_head_end is the index just past the head's CRLF CRLF, or -1.
engine_head_end :: proc(data: []u8) -> int {
	if len(data) < 4 {
		return -1
	}
	for i in 0 ..< len(data) - 3 {
		if data[i] == '\r' && data[i + 1] == '\n' && data[i + 2] == '\r' && data[i + 3] == '\n' {
			return i + 4
		}
	}
	return -1
}

// engine_content_length reads the request's Content-Length, 0 when absent.
engine_content_length :: proc(head: string) -> int {
	rest := head
	for {
		line := rest
		line_end := strings.index(rest, "\r\n")
		if line_end >= 0 {
			line = rest[:line_end]
			rest = rest[line_end + 2:]
		} else {
			rest = ""
		}
		if colon := strings.index(line, ":"); colon > 0 {
			if strings.equal_fold(line[:colon], "content-length") {
				if value, parsed := strconv.parse_int(strings.trim_space(line[colon + 1:]), 10); parsed {
					return value
				}
			}
		}
		if line_end < 0 {
			return 0
		}
	}
}

// ---------------------------------------------------------------------------
// Test-side helpers
// ---------------------------------------------------------------------------

engine_url :: proc(server: ^Engine_Server, path: string, allocator: mem.Allocator) -> string {
	return fmt.aprintf("http://127.0.0.1:%d%s", server.port, path, allocator = allocator)
}

// engine_scratch_dir is the directory the engine tests write their fixtures to.
// Like the other suites it honours $TMPDIR and falls back to ./tmp — the
// scratch directory .gitignore reserves — so a runner with no TMPDIR set still
// has somewhere to write. The directory is created because the fixtures are
// written straight into it.
@(private)
engine_scratch_dir :: proc(t: ^testing.T) -> string {
	base := "tmp"
	if tmp := os.get_env("TMPDIR", context.temp_allocator); tmp != "" {
		base = tmp
	}
	if err := os.make_directory_all(base, os.Permissions{.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist {
		testing.expectf(t, false, "cannot create the scratch directory %s: %v", base, err)
	}
	return base
}

// engine_queue_reply queues the canned reply for the next request.
engine_queue_reply :: proc(server: ^Engine_Server, reply: string) {
	clone, clone_err := strings.clone(reply, server.backing)
	if clone_err != .None {
		return
	}
	sync.mutex_lock(&server.mutex)
	defer sync.mutex_unlock(&server.mutex)
	append(&server.replies, clone)
}

// engine_silence_next makes the server accept the next request and never answer
// it, which is how the timeout test keeps libcurl waiting.
engine_silence_next :: proc(server: ^Engine_Server) {
	sync.mutex_lock(&server.mutex)
	defer sync.mutex_unlock(&server.mutex)
	server.silent += 1
}

// engine_request_clone returns the raw bytes of the index-th request the server
// saw. The caller owns the result.
engine_request_clone :: proc(server: ^Engine_Server, index: int, allocator: mem.Allocator) -> (string, bool) {
	sync.mutex_lock(&server.mutex)
	defer sync.mutex_unlock(&server.mutex)
	if index >= len(server.requests) {
		return "", false
	}
	clone, clone_err := strings.clone(server.requests[index], allocator)
	return clone, clone_err == .None
}

// engine_request_line is the request line of a raw request.
engine_request_line :: proc(raw: string) -> string {
	if line_end := strings.index(raw, "\r\n"); line_end >= 0 {
		return raw[:line_end]
	}
	return raw
}

// engine_head_of is everything before the head's terminating CRLF CRLF.
engine_head_of :: proc(raw: string) -> string {
	if index := strings.index(raw, "\r\n\r\n"); index >= 0 {
		return raw[:index]
	}
	return raw
}

// engine_head_without_connection returns `head` with its `Connection` line
// removed, written into `buffer`. libcurl writes a caller-supplied `Connection`
// header last, whatever position the request list gave it (measured against
// libcurl 8.22.0: a six-header list keeps every other line's order and moves
// only `Connection` to the end), so the wire position of that one line is the
// library's, not the port's. The tests compare the heads without it and assert
// the line's value separately, which keeps every other line's order under test.
// Returns "" if `buffer` is too small.
@(private)
engine_head_without_connection :: proc(head: string, buffer: []u8) -> string {
	written := 0
	rest := head
	first := true
	for len(rest) > 0 {
		line := rest
		if line_end := strings.index(rest, "\r\n"); line_end >= 0 {
			line = rest[:line_end]
			rest = rest[line_end + 2:]
		} else {
			rest = ""
		}
		if colon := strings.index(line, ":"); colon > 0 {
			if strings.equal_fold(line[:colon], "Connection") {
				continue
			}
		}
		if !first {
			if written + 2 > len(buffer) {
				return ""
			}
			buffer[written] = '\r'
			buffer[written + 1] = '\n'
			written += 2
		}
		if written + len(line) > len(buffer) {
			return ""
		}
		copy(buffer[written:], transmute([]u8)line)
		written += len(line)
		first = false
	}
	return string(buffer[:written])
}

// engine_body_of is everything after the head.
engine_body_of :: proc(raw: string) -> string {
	if index := strings.index(raw, "\r\n\r\n"); index >= 0 {
		return raw[index + 4:]
	}
	return ""
}

// engine_expect_body checks the body of a raw request and says how it differs
// when it does — two bodies that render alike can still be two bodies (`%v`
// hides the byte that makes a difference, `%q` and the lengths do not).
engine_expect_body :: proc(t: ^testing.T, raw: string, expected: string) {
	body := engine_body_of(raw)
	testing.expectf(t, body == expected, "the body must be %q (%d bytes), the wire carried %q (%d bytes)",
	                expected, len(expected), body, len(body))
}

// engine_header_of looks a header up in a raw request or response head,
// case-insensitively, the way a server does.
engine_header_of :: proc(raw: string, name: string) -> (string, bool) {
	head := engine_head_of(raw)
	rest := head
	first := true
	for {
		line := rest
		line_end := strings.index(rest, "\r\n")
		if line_end >= 0 {
			line = rest[:line_end]
			rest = rest[line_end + 2:]
		} else {
			rest = ""
		}
		if !first {
			if colon := strings.index(line, ":"); colon > 0 {
				if strings.equal_fold(line[:colon], name) {
					return strings.trim_space(line[colon + 1:]), true
				}
			}
		}
		first = false
		if line_end < 0 {
			return "", false
		}
	}
}

// engine_send prepares the request and performs it, failing the test if the
// preparation step does.
engine_send :: proc(t: ^testing.T, request: ^http.Request, response: ^http.Response) -> http.Error {
	prepare_err := http.request_prepare(request)
	testing.expectf(t, prepare_err == .None, "request_prepare: %v", prepare_err)
	response^ = {}
	return http.send(request, response)
}

// engine_no_leaks is expect_no_leaks without the shared-helper dependency.
engine_no_leaks :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) {
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "leaked %d bytes allocated at %v", entry.size, entry.location)
	}
	testing.expectf(t, len(track.bad_free_array) == 0, "%d mismatched frees", len(track.bad_free_array))
}

// ---------------------------------------------------------------------------
// Body bytes
// ---------------------------------------------------------------------------

@(test)
test_engine_sends_the_json_body_bytes :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)

	// What the session puts on the Request before the engine sees it.
	testing.expect_value(t, http.request_add_header(&request, "User-Agent", http.USER_AGENT), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Accept-Encoding", http.ACCEPT_ENCODING), http.Error.None)

	items := []http.Data_Item {
		{kind = .String, name = "name", value = "John"},
		{kind = .String, name = "unicode", value = "héllo"},
		{kind = .Raw_JSON, name = "raw", value = "42"},
	}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)

	response: http.Response
	send_err := engine_send(t, &request, &response)
	testing.expect_value(t, send_err, http.Error.None)

	// The reply the engine buffered.
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, response.reason, "OK")
	testing.expect_value(t, string(response.body), "ok")
	bytes_received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(bytes_received) > 0, "the server must have seen the request")

	// The body is the contract: exactly the bytes httpie puts on the wire.
	expected_body := "{\"name\": \"John\", \"unicode\": \"h\\u00e9llo\", \"raw\": 42}"
	testing.expect_value(t, engine_request_line(bytes_received), "POST /echo HTTP/1.1")
	testing.expect_value(t, engine_body_of(bytes_received), expected_body)

	content_type, has_type := engine_header_of(bytes_received, "Content-Type")
	testing.expect(t, has_type, "Content-Type must reach the server")
	testing.expect_value(t, content_type, "application/json")

	content_length, has_length := engine_header_of(bytes_received, "Content-Length")
	testing.expect(t, has_length, "Content-Length must reach the server")
	length_value, parsed := strconv.parse_int(content_length, 10)
	testing.expect(t, parsed, "Content-Length must be a number")
	testing.expect_value(t, length_value, len(expected_body))

	user_agent, has_agent := engine_header_of(bytes_received, "User-Agent")
	testing.expect(t, has_agent, "User-Agent must reach the server")
	testing.expect_value(t, user_agent, http.USER_AGENT)

	// The reply's own head is parsed too.
	testing.expect_value(t, response.http_version, "HTTP/1.1")
	_, has_reply_length := engine_header_of("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", "Content-Length")
	testing.expect(t, has_reply_length, "the reply head must parse")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(bytes_received, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_sends_the_form_body_bytes :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.body_kind = .Form

	// The reference's own encoding (docs/PARITY.md: space is `+`, `/ + ? &` are
	// percent-encoded, `~ . - _` are left alone).
	items := []http.Data_Item {
		{kind = .String, name = "a b", value = "c/d+e?f&g"},
		{kind = .String, name = "h", value = "x~y.z-w_1"},
	}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)

	response: http.Response
	send_err := engine_send(t, &request, &response)
	testing.expect_value(t, send_err, http.Error.None)

	bytes_received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(bytes_received) > 0, "the server must have seen the request")
	testing.expect_value(t, engine_request_line(bytes_received), "POST /echo HTTP/1.1")
	testing.expect_value(t, engine_body_of(bytes_received), "a+b=c%2Fd%2Be%3Ff%26g&h=x~y.z-w_1")

	content_type, has_type := engine_header_of(bytes_received, "Content-Type")
	testing.expect(t, has_type, "Content-Type must reach the server")
	// requests spells the form body's charset out; the reference capture
	// post-form.out shows exactly this header.
	testing.expect_value(t, content_type, "application/x-www-form-urlencoded; charset=utf-8")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(bytes_received, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_sends_the_raw_body_bytes :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .PUT, url, nil)
	testing.expect_value(t, create_err, http.Error.None)

	// --raw: the bytes go out untouched, including the ones that are not text.
	raw := []byte{'{', '"', 'a', '"', ':', ' ', '1', '}'}
	testing.expect_value(t, http.request_set_raw_body(&request, raw, "application/json"), http.Error.None)

	response: http.Response
	send_err := engine_send(t, &request, &response)
	testing.expect_value(t, send_err, http.Error.None)

	bytes_received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(bytes_received) > 0, "the server must have seen the request")
	testing.expect_value(t, engine_request_line(bytes_received), "PUT /echo HTTP/1.1")
	testing.expect_value(t, engine_body_of(bytes_received), "{\"a\": 1}")

	content_type, has_type := engine_header_of(bytes_received, "Content-Type")
	testing.expect(t, has_type, "Content-Type must reach the server")
	testing.expect_value(t, content_type, "application/json")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(bytes_received, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_sends_the_multipart_body_bytes :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The upload: a file in the temp directory, whose leaf name the engine has
	// to infer as the multipart filename.
	temp_dir := engine_scratch_dir(t)
	upload_path := fmt.aprintf("%s/htthor_engine_upload.txt", temp_dir, allocator = allocator)
	upload_contents := "upload payload\n"
	write_err := os.write_entire_file(upload_path, transmute([]u8)upload_contents)
	testing.expect(t, write_err == nil, "the upload fixture must be written")

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.body_kind = .Multipart

	items := []http.Data_Item {
		{kind = .String, name = "name", value = "John"},
		{kind = .File, name = "file", value = upload_path},
	}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)

	response: http.Response
	send_err := engine_send(t, &request, &response)
	testing.expect_value(t, send_err, http.Error.None)

	bytes_received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(bytes_received) > 0, "the server must have seen the request")
	testing.expect_value(t, engine_request_line(bytes_received), "POST /echo HTTP/1.1")

	content_type, has_type := engine_header_of(bytes_received, "Content-Type")
	testing.expect(t, has_type, "Content-Type must reach the server")
	testing.expect(
		t,
		strings.has_prefix(content_type, "multipart/form-data; boundary="),
		"multipart bodies announce their boundary",
	)

	// The boundary is random by design (docs/PARITY.md §7), so the expectation
	// is rebuilt from the one the engine actually used. The file item carries no
	// Content-Type (the CLI is the layer that guesses one, and this request was
	// built without it), and an empty type means no `Content-Type` line in the
	// part at all — the reference's `RequestField.render_headers` skips a falsy
	// header value.
	boundary := ""
	if separator := strings.index(content_type, "boundary="); separator >= 0 {
		boundary = content_type[separator + len("boundary="):]
	}
	expected_body := fmt.aprintf(
		"--%s\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nJohn\r\n" +
		"--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"htthor_engine_upload.txt\"\r\n" +
		"\r\n%s\r\n--%s--\r\n",
		boundary, boundary, upload_contents, boundary,
		allocator = allocator,
	)
	testing.expect_value(t, engine_body_of(bytes_received), expected_body)

	content_length, has_length := engine_header_of(bytes_received, "Content-Length")
	testing.expect(t, has_length, "Content-Length must reach the server")
	length_value, parsed := strconv.parse_int(content_length, 10)
	testing.expect(t, parsed, "Content-Length must be a number")
	testing.expect_value(t, length_value, len(expected_body))

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(expected_body, allocator)
	delete(url, allocator)
	delete(bytes_received, allocator)
	delete(upload_path, allocator)
	os.remove(upload_path)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// --chunked and --compress: the framing header's position and the body bytes
// ---------------------------------------------------------------------------

// engine_request_head_defaults is what the session hands the renderer: the Host
// the URL implies, and nothing else — the head's lines and their order come from
// the request's header list, which the session ordered by provenance.
engine_request_head_defaults :: proc(host: string) -> output.Request_Head_Defaults {
	return output.Request_Head_Defaults {
		host = host,
	}
}

// The provenance of the requests below, as client.py's request dict builds it
// for a JSON-bodied request: make_default_headers' own
// `[User-Agent, Accept, Content-Type]`, plus httpie's own Transfer-Encoding when
// the request is an `--offline --chunked` one (client.py:347-350).
ENGINE_JSON_BODY_OWN := [?]string{"User-Agent", "Accept", "Content-Type"}
ENGINE_JSON_CHUNKED_OWN := [?]string{"User-Agent", "Accept", "Content-Type", "Transfer-Encoding"}

@(test)
test_engine_puts_the_derived_chunked_header_after_connection :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.chunked = true
	request.json_accept = true

	// The headers the session adds, in the order it adds them: their order here
	// is not the contract, the renderer's is.
	testing.expect_value(t, http.request_add_header(&request, "User-Agent", http.USER_AGENT), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Accept-Encoding", http.ACCEPT_ENCODING), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Connection", "keep-alive"), http.Error.None)

	items := []http.Data_Item{{kind = .String, name = "a", value = "1"}}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)

	testing.expect_value(t, http.request_prepare(&request), http.Error.None)
	// requests derives the framing header for an online chunked upload, and
	// that provenance is what places it in the head: it is not one of the
	// request dict's own names.
	testing.expect(t, request.transfer_encoding_derived, "an online --chunked upload derives its Transfer-Encoding")

	testing.expect(
		t,
		output.order_request_headers(&request, ENGINE_JSON_BODY_OWN[:], allocator),
		"the request's headers must be ordered",
	)

	response: http.Response
	testing.expect_value(t, http.send(&request, &response), http.Error.None)

	// A chunked request announces no Content-Length, so the server's reader
	// stops at the head's blank line: only the head is asserted.
	received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(received) > 0, "the server must have seen the request")

	expected_head := fmt.aprintf(
		"POST /echo HTTP/1.1\r\n" +
		"Host: 127.0.0.1:%d\r\n" +
		"Accept-Encoding: gzip, deflate\r\n" +
		"Transfer-Encoding: chunked\r\n" +
		"User-Agent: HTTPie/3.2.4\r\n" +
		"Accept: application/json, */*;q=0.5\r\n" +
		"Content-Type: application/json",
		server.port,
		allocator = allocator,
	)
	head_scratch: [4096]u8
	testing.expect_value(t, engine_head_without_connection(engine_head_of(received), head_scratch[:]), expected_head)
	connection, has_connection := engine_header_of(received, "Connection")
	testing.expect(t, has_connection, "Connection must reach the server")
	testing.expect_value(t, connection, "keep-alive")

	transfer_encoding, has_encoding := engine_header_of(received, "Transfer-Encoding")
	testing.expect(t, has_encoding, "Transfer-Encoding must reach the server")
	testing.expect_value(t, transfer_encoding, "chunked")
	_, has_length := engine_header_of(received, "Content-Length")
	testing.expect(t, !has_length, "a chunked upload must not announce a Content-Length")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(received, allocator)
	delete(expected_head, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// A HEAD is the one verb whose *request* can carry bytes and whose *reply* never
// does — and the one shape libcurl cannot be asked for both halves of, because
// the switch for "this reply has no body" (`CURLOPT_NOBODY`) takes the request
// body with it. The port sends the body like any other hop's and cuts the
// transfer at the end of the reply head instead (docs/PARITY.md §4.1,
// t_46638a3e), and these two tests are the two halves of that decision: the
// framing line reaches the server (`Transfer-Encoding: chunked`, no
// `Content-Length`) and the reply's body is *not* read, even though this
// server's canned reply carries one — which is what http.client does with a
// HEAD (`self.length = 0` at CPython 3.11.15 Lib/http/client.py:381-385, `read`
// answers b'' at :462-469).
//
// The head is all the dumb server below records for a chunked request (its
// reader stops at the blank line, there being no `Content-Length` to follow);
// the terminating chunk is asserted by the parity scenarios against the
// fixture's `/echo` and by `build/probe_chunked_no_items.py`'s HEAD rows, whose
// server reads the chunks it is sent.
@(test)
test_engine_frames_a_chunked_head_and_reads_no_reply_body :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .HEAD, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.chunked = true
	request.json_accept = true

	items := []http.Data_Item {{kind = .String, name = "foo", value = "bar"}}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)

	response: http.Response
	send_err := engine_send(t, &request, &response)
	// The cut at the end of the reply head is not a failure: the run ends as
	// the reference's does.
	testing.expect_value(t, send_err, http.Error.None)

	received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(received) > 0, "the server must have seen the request")
	testing.expect_value(t, engine_request_line(received), "HEAD /echo HTTP/1.1")

	transfer_encoding, has_encoding := engine_header_of(received, "Transfer-Encoding")
	testing.expect(t, has_encoding, "the framing line must reach the server")
	testing.expect_value(t, transfer_encoding, "chunked")
	_, has_length := engine_header_of(received, "Content-Length")
	testing.expect(t, !has_length, "a chunked HEAD must not announce a Content-Length")

	// The reply is its head: 2 bytes of body went out from the server and none
	// of them are the response's.
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body), "")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(received, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// The same HEAD with *no* items: the only byte of its chunked body is the
// terminating chunk, and the framing line is still its own. This is the shape
// the port sent unframed before t_46638a3e (`Transfer-Encoding` rendered and
// nothing on the wire), and the reason `--chunked` cannot be a test on the body
// bytes: httpie hands requests a `ChunkedUploadStream` whatever the items are.
@(test)
test_engine_frames_a_body_less_chunked_head :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .HEAD, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.chunked = true

	response: http.Response
	send_err := engine_send(t, &request, &response)
	testing.expect_value(t, send_err, http.Error.None)

	received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(received) > 0, "the server must have seen the request")
	testing.expect_value(t, engine_request_line(received), "HEAD /echo HTTP/1.1")

	transfer_encoding, has_encoding := engine_header_of(received, "Transfer-Encoding")
	testing.expect(t, has_encoding, "a body-less chunked HEAD is an upload too")
	testing.expect_value(t, transfer_encoding, "chunked")
	_, has_length := engine_header_of(received, "Content-Length")
	testing.expect(t, !has_length, "a chunked HEAD must not announce a Content-Length")
	testing.expect_value(t, string(response.body), "")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(received, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// The header lines of a request that never had a body. The caller's items are
// written as they stand — including `Content-Type`, `Content-Length` and
// `Accept-Encoding` — because requests sends the first request of a chain
// unchanged: the purge of those three names is `resolve_redirects`' rule for a
// hop that followed a 301/302/303 (sessions.py:249-258), not a rule about a
// body-less request (docs/PARITY.md §8.18(c)).
//
// `Accept-Encoding` is the second half of it: the session's own default is an
// entry in the same list (that is how it keeps its place, right after `Host`),
// so a caller's item replaces that entry and moves where the item put it, while
// `CURLOPT_ACCEPT_ENCODING` still asks libcurl for the decoding. The exact head
// below is also the assertion that libcurl adds no `Accept-Encoding` of its own
// beside the caller's.
@(test)
test_engine_writes_the_callers_headers_on_a_bodyless_request :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)

	// The list the session ordered: its own defaults, then the caller's items.
	testing.expect_value(t, http.request_add_header(&request, "Accept", "*/*"), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Connection", "keep-alive"), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "User-Agent", http.USER_AGENT), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Accept-Encoding", "foo"), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Content-Type", "foo"), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Content-Length", "0"), http.Error.None)
	testing.expect_value(t, http.request_prepare(&request), http.Error.None)

	response: http.Response
	testing.expect_value(t, http.send(&request, &response), http.Error.None)

	received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(received) > 0, "the server must have seen the request")

	expected_head := fmt.aprintf(
		"GET /echo HTTP/1.1\r\n" +
		"Host: 127.0.0.1:%d\r\n" +
		"Accept: */*\r\n" +
		"User-Agent: HTTPie/3.2.4\r\n" +
		"Accept-Encoding: foo\r\n" +
		"Content-Type: foo\r\n" +
		"Content-Length: 0",
		server.port,
		allocator = allocator,
	)
	head_scratch: [4096]u8
	testing.expect_value(t, engine_head_without_connection(engine_head_of(received), head_scratch[:]), expected_head)
	connection, has_connection := engine_header_of(received, "Connection")
	testing.expect(t, has_connection, "Connection must reach the server")
	testing.expect_value(t, connection, "keep-alive")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(received, allocator)
	delete(expected_head, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// The same provenance rule decides the offline shape: with --offline httpie
// puts Transfer-Encoding into its own header set (client.py:296-299), so it
// lands after Content-Type instead of after Connection. --offline opens no
// socket, so this one asserts the rendered head rather than the wire.
@(test)
test_engine_keeps_an_offline_chunked_header_last :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	request, create_err := http.request_create(allocator, .POST, "http://127.0.0.1:8765/echo", nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.offline = true
	request.chunked = true
	request.json_accept = true

	testing.expect_value(t, http.request_add_header(&request, "User-Agent", http.USER_AGENT), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Accept-Encoding", http.ACCEPT_ENCODING), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Connection", "keep-alive"), http.Error.None)

	items := []http.Data_Item{{kind = .String, name = "a", value = "1"}}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)
	testing.expect_value(t, http.request_prepare(&request), http.Error.None)

	// httpie's own Transfer-Encoding for `--offline --chunked` is part of the
	// request dict, so it is one of the request's own names here
	// (client.py:347-350).
	testing.expect(
		t,
		!request.transfer_encoding_derived,
		"an offline --chunked upload carries httpie's own Transfer-Encoding",
	)

	host, host_err := strings.clone("127.0.0.1:8765", allocator)
	testing.expect_value(t, host_err, mem.Allocator_Error.None)
	defaults := engine_request_head_defaults(host)
	testing.expect(
		t,
		output.order_request_headers(&request, ENGINE_JSON_CHUNKED_OWN[:], allocator),
		"the request's headers must be ordered",
	)

	head := output.build_request_head(&request, "/echo", defaults, allocator)
	expected := "POST /echo HTTP/1.1\r\n" +
	            "Accept-Encoding: gzip, deflate\r\n" +
	            "Connection: keep-alive\r\n" +
	            "Content-Length: 10\r\n" +
	            "User-Agent: HTTPie/3.2.4\r\n" +
	            "Accept: application/json, */*;q=0.5\r\n" +
	            "Content-Type: application/json\r\n" +
	            "Transfer-Encoding: chunked\r\n" +
	            "Host: 127.0.0.1:8765"
	testing.expect_value(t, head, expected)

	http.request_destroy(&request)
	delete(host, allocator)
	delete(head, allocator)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_sends_the_forced_deflate_body :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	// `-xx`: --compress twice, which forces the deflate stream even though it
	// is longer than the body it replaces.
	request.compress = 2
	request.json_accept = true

	testing.expect_value(t, http.request_add_header(&request, "User-Agent", http.USER_AGENT), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Accept-Encoding", http.ACCEPT_ENCODING), http.Error.None)
	testing.expect_value(t, http.request_add_header(&request, "Connection", "keep-alive"), http.Error.None)

	items := []http.Data_Item{{kind = .String, name = "a", value = "1"}}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)

	testing.expect_value(t, http.request_prepare(&request), http.Error.None)

	testing.expect(
		t,
		output.order_request_headers(&request, ENGINE_JSON_BODY_OWN[:], allocator),
		"the request's headers must be ordered",
	)

	response: http.Response
	testing.expect_value(t, http.send(&request, &response), http.Error.None)

	received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(received) > 0, "the server must have seen the request")

	// The bytes CPython's `zlib.compressobj()` produces for `{"a": "1"}` —
	// captured from the reference (docs/PARITY.md §2 --compress) and pinned
	// here so a different libz or a different zlib parameter cannot slip in.
	expected_body := [18]u8 {
		0x78, 0x9c, 0xab, 0x56, 0x4a, 0x54, 0xb2, 0x52,
		0x50, 0x32, 0x54, 0xaa, 0x05, 0x00, 0x0d, 0xd8,
		0x02, 0x6d,
	}
	testing.expect_value(t, engine_body_of(received), string(expected_body[:]))

	content_encoding, has_encoding := engine_header_of(received, "Content-Encoding")
	testing.expect(t, has_encoding, "Content-Encoding must reach the server")
	testing.expect_value(t, content_encoding, "deflate")

	content_length, has_length := engine_header_of(received, "Content-Length")
	testing.expect(t, has_length, "the compressed length must be announced")
	length_value, parsed := strconv.parse_int(content_length, 10)
	testing.expect(t, parsed, "Content-Length must be a number")
	testing.expect_value(t, length_value, len(expected_body))

	// The header the compression adds sits after Content-Type, and the whole
	// head is the reference's.
	expected_head := fmt.aprintf(
		"POST /echo HTTP/1.1\r\n" +
		"Host: 127.0.0.1:%d\r\n" +
		"Accept-Encoding: gzip, deflate\r\n" +
		"Content-Length: 18\r\n" +
		"User-Agent: HTTPie/3.2.4\r\n" +
		"Accept: application/json, */*;q=0.5\r\n" +
		"Content-Type: application/json\r\n" +
		"Content-Encoding: deflate",
		server.port,
		allocator = allocator,
	)
	head_scratch: [4096]u8
	testing.expect_value(t, engine_head_without_connection(engine_head_of(received), head_scratch[:]), expected_head)
	connection, has_connection := engine_header_of(received, "Connection")
	testing.expect(t, has_connection, "Connection must reach the server")
	testing.expect_value(t, connection, "keep-alive")
	delete(expected_head, allocator)

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(received, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// Redirects
// ---------------------------------------------------------------------------

@(test)
test_engine_follows_a_303_and_rewrites_post_to_get :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	engine_queue_reply(server, "HTTP/1.1 303 See Other\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5
	testing.expect_value(
		t,
		http.request_add_items(&request, []http.Data_Item{{kind = .String, name = "a", value = "1"}}),
		http.Error.None,
	)

	response: http.Response
	send_err := engine_send(t, &request, &response)
	testing.expect_value(t, send_err, http.Error.None)

	// The final reply is the follow-up, and the whole exchange is history: the
	// hops that led to it plus the final one, whose request the renderer needs
	// to print every message of the chain.
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body), "ok")
	testing.expect_value(t, len(response.history), 2)
	if len(response.history) == 2 {
		testing.expect_value(t, response.history[0].status, 303)
		testing.expect_value(t, response.history[0].method, http.Method.POST)
		testing.expect(t, strings.has_suffix(response.history[0].url, "/first"), "the hop keeps its own URL")
		testing.expect_value(t, response.history[1].method, http.Method.GET)
		testing.expect(t, strings.has_suffix(response.history[1].url, "/next"), "the final hop is the rewritten one")
	}
	testing.expect(t, strings.has_suffix(response.url, "/next"), "the response URL is the final one")

	first := engine_request_clone(server, 0, allocator) or_else ""
	second := engine_request_clone(server, 1, allocator) or_else ""
	testing.expect_value(t, engine_request_line(first), "POST /first HTTP/1.1")
	// httpie's rule: a 303 turns anything but HEAD into a GET, body and all.
	testing.expect_value(t, engine_request_line(second), "GET /next HTTP/1.1")
	testing.expect_value(t, engine_body_of(second), "")
	_, has_length := engine_header_of(second, "Content-Length")
	testing.expect(t, !has_length, "the rewritten GET must not carry the POST body's length")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(first, allocator)
	delete(second, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_follows_a_307_and_keeps_the_method :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	engine_queue_reply(server, "HTTP/1.1 307 Temporary Redirect\r\nLocation: /keep\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5
	testing.expect_value(
		t,
		http.request_add_items(&request, []http.Data_Item{{kind = .String, name = "a", value = "1"}}),
		http.Error.None,
	)

	response: http.Response
	send_err := engine_send(t, &request, &response)
	testing.expect_value(t, send_err, http.Error.None)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, len(response.history), 2)
	if len(response.history) == 2 {
		testing.expect_value(t, response.history[0].status, 307)
		testing.expect_value(t, response.history[1].method, http.Method.POST)
	}

	second := engine_request_clone(server, 1, allocator) or_else ""
	// 307 preserves the method *and* the body.
	testing.expect_value(t, engine_request_line(second), "POST /keep HTTP/1.1")
	testing.expect_value(t, engine_body_of(second), "{\"a\": \"1\"}")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(second, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_answers_a_3xx_outside_redirect_stati :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// A 304 is not one of `REDIRECT_STATI`'s five, and requests follows a
	// response only when `resp.is_redirect` holds — a `Location` *and* one of
	// the five (models.py:875-879) — so the reference *answers* this reply and
	// never asks for `/next`. The engine followed any 3xx, so both hops went out
	// here (docs/PARITY.md §8 item 19).
	engine_queue_reply(server, "HTTP/1.1 304 Not Modified\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)

	// The 304 is the answer: no hop followed it, so the chain the renderer sees
	// is the final hop alone and the effective URL is the one that was asked for.
	testing.expect_value(t, response.status, 304)
	testing.expect_value(t, len(response.history), 1)
	testing.expect(t, strings.has_suffix(response.url, "/first"),
	               "the reply stays the hop that was asked for")

	// The wire is the assertion that matters: a second request would be the
	// followed hop, and the server saw none.
	second, has_second := engine_request_clone(server, 1, allocator)
	testing.expect(t, !has_second, "a 3xx outside the five must not be followed")
	if has_second {
		delete(second, allocator)
	}

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_streams_the_body_of_an_answered_3xx :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// The other half of the same rule: a 305 with a `Location` is answered, so
	// its body is the reply's and reaches a caller-supplied writer exactly like a
	// 200's. While every 3xx was a redirect hop the engine discarded it, which
	// for `send_to` meant the bytes were buffered and then dropped — the caller's
	// file stayed empty (docs/PARITY.md §8 item 19).
	engine_queue_reply(server, "HTTP/1.1 305 Use Proxy\r\nLocation: /next\r\nContent-Type: text/plain\r\nContent-Length: 14\r\nConnection: close\r\n\r\nredirect body\n")

	temp_dir := engine_scratch_dir(t)
	download_path := fmt.aprintf("%s/htthor_engine_answered_3xx.txt", temp_dir, allocator = allocator)

	file, open_err := os.open(download_path, os.O_CREATE | os.O_WRONLY | os.O_TRUNC, os.Permissions_Default_File)
	testing.expect(t, open_err == nil, "the writer must open")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5

	response: http.Response
	testing.expect_value(t, http.send_to(&request, &response, os.to_writer(file)), http.Error.None)
	testing.expect_value(t, response.status, 305)
	testing.expect_value(t, len(response.history), 1)
	testing.expect_value(t, len(response.body), 0) // the body went to the writer

	os.close(file)
	contents, read_err := os.read_entire_file_from_path(download_path, allocator)
	testing.expect(t, read_err == nil, "the written file must be readable")
	testing.expect_value(t, string(contents), "redirect body\n")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(contents, allocator)
	delete(url, allocator)
	delete(download_path, allocator)
	os.remove(download_path)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_streams_the_body_of_a_redirect_status_without_a_location :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// The status half alone does not make a redirect: `is_redirect` wants the
	// `Location` too, and `resolve_redirects`' `while url:` ends on the empty
	// target, so a 302 *without* the header is answered by the reference. The
	// body of that reply is the caller's exactly like a 200's, which the status
	// line on its own cannot know — the parser settles it at the end of the head
	// (docs/PARITY.md §8 item 19).
	engine_queue_reply(server, "HTTP/1.1 302 Found\r\nContent-Type: text/plain\r\nContent-Length: 14\r\nConnection: close\r\n\r\nredirect body\n")

	temp_dir := engine_scratch_dir(t)
	download_path := fmt.aprintf("%s/htthor_engine_302_no_location.txt", temp_dir, allocator = allocator)

	file, open_err := os.open(download_path, os.O_CREATE | os.O_WRONLY | os.O_TRUNC, os.Permissions_Default_File)
	testing.expect(t, open_err == nil, "the writer must open")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5

	response: http.Response
	testing.expect_value(t, http.send_to(&request, &response, os.to_writer(file)), http.Error.None)
	testing.expect_value(t, response.status, 302)
	testing.expect_value(t, len(response.history), 1)
	testing.expect_value(t, len(response.body), 0) // the body went to the writer

	os.close(file)
	contents, read_err := os.read_entire_file_from_path(download_path, allocator)
	testing.expect(t, read_err == nil, "the written file must be readable")
	testing.expect_value(t, string(contents), "redirect body\n")

	second, has_second := engine_request_clone(server, 1, allocator)
	testing.expect(t, !has_second, "a 302 without a Location must not be followed")
	if has_second {
		delete(second, allocator)
	}

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(contents, allocator)
	delete(url, allocator)
	delete(download_path, allocator)
	os.remove(download_path)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// The rewrite itself, verb by verb: the 301 is the status whose rewrite is a
// POST's alone, the 302 is the one HEAD survives, and every other verb a
// followed 301/302 answers comes out a GET with the body purged
// (`redirect_method`, requests' `rebuild_method`, sessions.py:370-392).

@(test)
test_engine_rewrites_a_301_post_to_get :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// `if method == 'POST': method = 'GET'` — and *only* a POST
	// (sessions.py:373-376, the 301 branch of `rebuild_method`).
	engine_queue_reply(server, "HTTP/1.1 301 Moved Permanently\r\nLocation: /moved\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5
	testing.expect_value(
		t,
		http.request_add_items(&request, []http.Data_Item{{kind = .String, name = "a", value = "1"}}),
		http.Error.None,
	)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, len(response.history), 2)
	if len(response.history) == 2 {
		testing.expect_value(t, response.history[0].status, 301)
		testing.expect_value(t, response.history[1].method, http.Method.GET)
	}

	first := engine_request_clone(server, 0, allocator) or_else ""
	second := engine_request_clone(server, 1, allocator) or_else ""
	testing.expect_value(t, engine_request_line(first), "POST /first HTTP/1.1")
	testing.expect_value(t, engine_request_line(second), "GET /moved HTTP/1.1")
	// The purge travels with the rewrite: the body and the two headers that
	// described it are gone (`resolve_redirects`, sessions.py:249-258).
	testing.expect_value(t, engine_body_of(second), "")
	_, has_length := engine_header_of(second, "Content-Length")
	testing.expect(t, !has_length, "a purged GET must not announce a length")
	_, has_type := engine_header_of(second, "Content-Type")
	testing.expect(t, !has_type, "a purged GET must not carry the body's Content-Type")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(first, allocator)
	delete(second, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_keeps_a_puts_method_across_a_301 :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// The other half of the same branch: a PUT on a 301 keeps its method, and
	// only its body and the three body headers are purged (sessions.py:1807-1817
	// of `resolve_redirects`, which rewrites nothing here).
	engine_queue_reply(server, "HTTP/1.1 301 Moved Permanently\r\nLocation: /moved\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .PUT, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5
	testing.expect_value(
		t,
		http.request_add_items(&request, []http.Data_Item{{kind = .String, name = "a", value = "1"}}),
		http.Error.None,
	)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, len(response.history), 2)
	if len(response.history) == 2 {
		testing.expect_value(t, response.history[1].method, http.Method.PUT)
	}

	second := engine_request_clone(server, 1, allocator) or_else ""
	testing.expect_value(t, engine_request_line(second), "PUT /moved HTTP/1.1")
	testing.expect_value(t, engine_body_of(second), "")
	// `body_to_chunks` recommends the framing line for a body-less verb
	// outside urllib3's `_METHODS_NOT_EXPECTING_BODY`, and `_send_request`
	// writes it ahead of the head's own lines (util/request.py:57, :251-256;
	// connection.py:543-560) — a PUT is outside that set, so the purged hop
	// still announces a zero length.
	length, has_length := engine_header_of(second, "Content-Length")
	testing.expectf(t, has_length, "a purged PUT must still announce its framing")
	testing.expect_value(t, length, "0")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(second, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_rewrites_a_302_for_a_non_head_verb :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// A 302 is the 303's rule: everything but HEAD becomes a GET — the case
	// that separated the 302 from the 301 (sessions.py:378-381).
	engine_queue_reply(server, "HTTP/1.1 302 Found\r\nLocation: /moved\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .PUT, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5
	testing.expect_value(
		t,
		http.request_add_items(&request, []http.Data_Item{{kind = .String, name = "a", value = "1"}}),
		http.Error.None,
	)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, len(response.history), 2)
	if len(response.history) == 2 {
		testing.expect_value(t, response.history[1].method, http.Method.GET)
	}

	second := engine_request_clone(server, 1, allocator) or_else ""
	testing.expect_value(t, engine_request_line(second), "GET /moved HTTP/1.1")
	testing.expect_value(t, engine_body_of(second), "")
	// A GET is one of the six verbs urllib3 expects no body for, so the purge
	// writes no framing line for it (util/request.py:57).
	_, has_length := engine_header_of(second, "Content-Length")
	testing.expect(t, !has_length, "the rewritten GET must not announce a length")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(second, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// A HEAD is the single verb the 302 keeps, and the hop it keeps is also the one
// libcurl cannot be asked for both halves of: CURLOPT_NOBODY would take the
// request body with it, so the switch is only set for a HEAD whose request
// carries no byte at all, and the rest are cut at the end of the reply head
// (see `Transfer.head_reply_only`). This is the bodyless case on the wire.
@(test)
test_engine_keeps_head_across_a_redirect :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	engine_queue_reply(server, "HTTP/1.1 302 Found\r\nLocation: /moved\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .HEAD, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)
	testing.expect_value(t, response.status, 200)
	// The reply to a HEAD is its head: no body bytes, and the Content-Length
	// the server announced is not read as one (CPython 3.11.15
	// Lib/http/client.py:381-385, :462-469).
	testing.expect_value(t, string(response.body), "")
	testing.expect_value(t, len(response.history), 2)
	if len(response.history) == 2 {
		testing.expect_value(t, response.history[1].method, http.Method.HEAD)
	}

	first := engine_request_clone(server, 0, allocator) or_else ""
	second := engine_request_clone(server, 1, allocator) or_else ""
	testing.expect_value(t, engine_request_line(first), "HEAD /first HTTP/1.1")
	testing.expect_value(t, engine_request_line(second), "HEAD /moved HTTP/1.1")
	// HEAD is in `_METHODS_NOT_EXPECTING_BODY`, so the purge writes it no
	// framing line either (util/request.py:57).
	_, has_length := engine_header_of(second, "Content-Length")
	testing.expect(t, !has_length, "a purged HEAD must not announce a length")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(first, allocator)
	delete(second, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// The three ways the redirect question itself answers "no", each of which used
// to be a `break` inside the loop: a target with no adapter (requests refuses
// it in `Session.get_adapter`), a Location the utf-8 codec rejects (requests
// decodes it in `get_redirect_target`), and an empty one (`while url:` ends).

@(test)
test_engine_refuses_a_redirect_target_without_an_adapter :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// httpie mounts `http://` and `https://` and nothing else, so a Location
	// with any other scheme matches no adapter: requests raises
	// `InvalidSchema` before anything connects (sessions.py:870-881).
	engine_queue_reply(server, "HTTP/1.1 302 Found\r\nLocation: ftp://127.0.0.1:1/landing\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.No_Connection_Adapter)
	// A failed send leaves the reply zeroed; the chain it made is published on
	// the *request*, and it ends with the refused target — httpie printed that
	// request before the send that refused it (`yield prepared_request`,
	// client.py:105). The hop in flight is the 302 request itself, and like
	// every hop whose follow was cut short it joins as a request-only entry:
	// the refusal is decided before the completed hop is recorded
	// (follow_abort_refused).
	testing.expect_value(t, response.status, 0)
	testing.expect_value(t, len(response.history), 0)
	testing.expect_value(t, len(request.follow_history), 2)
	if len(request.follow_history) == 2 {
		testing.expect_value(t, request.follow_history[0].status, 0)
		testing.expect(t, strings.has_suffix(request.follow_history[0].url, "/first"),
		               "the hop in flight is the request that was answered")
		testing.expect_value(t, request.follow_history[1].method, http.Method.GET)
		testing.expect_value(t, request.follow_history[1].url, "ftp://127.0.0.1:1/landing")
	}
	// The message requests prints quotes the URL it held, and the error owns
	// it (request_destroy releases it).
	testing.expect(t, request.adapter_error.failed, "the refusal must name its URL")
	testing.expect_value(t, request.adapter_error.url, "ftp://127.0.0.1:1/landing")

	// Nothing was asked of libcurl for the refused target.
	second, has_second := engine_request_clone(server, 1, allocator)
	testing.expect(t, !has_second, "a target with no adapter must not be sent")
	if has_second {
		delete(second, allocator)
	}

	http.request_destroy(&request)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_refuses_a_location_the_codec_rejects :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// `to_native_string(location, "utf8")` — the header's bytes are handed to
	// the codec before the hop is made, and `\xff` is not a utf-8 start byte
	// (sessions.py:142-151; the port holds the header as the bytes it arrived
	// in, §3.6, so the codec is a check and not a conversion).
	engine_queue_reply(server, "HTTP/1.1 302 Found\r\nLocation: /\xffbad\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.Redirect_Location_Not_Utf8)
	testing.expect_value(t, response.status, 0)
	// The session prints the codec's own message from the request.
	testing.expect(t, request.location_error.failed, "the refused Location must be recorded")
	testing.expect_value(t, len(request.follow_history), 1)

	second, has_second := engine_request_clone(server, 1, allocator)
	testing.expect(t, !has_second, "a Location the codec refuses must not be followed")
	if has_second {
		delete(second, allocator)
	}

	http.request_destroy(&request)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_answers_a_redirect_whose_location_is_empty :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// `while url:` — an empty target is falsy, so the chain stops on the 3xx
	// and the reply is the caller's (sessions.py:204).
	engine_queue_reply(server, "HTTP/1.1 302 Found\r\nLocation: \r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 5

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)
	testing.expect_value(t, response.status, 302)
	testing.expect_value(t, len(response.history), 1)
	testing.expect(t, strings.has_suffix(response.url, "/first"),
	               "the reply stays the hop that was asked for")

	second, has_second := engine_request_clone(server, 1, allocator)
	testing.expect(t, !has_second, "an empty Location must not be followed")
	if has_second {
		delete(second, allocator)
	}

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

@(test)
test_engine_sends_the_basic_and_bearer_authorization_headers :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)

	basic, basic_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, basic_err, http.Error.None)
	testing.expect_value(t, http.request_set_auth(&basic, "user:pass", .Basic), http.Error.None)
	basic_response: http.Response
	testing.expect_value(t, engine_send(t, &basic, &basic_response), http.Error.None)
	basic_bytes := engine_request_clone(server, 0, allocator) or_else ""
	authorization, has_authorization := engine_header_of(basic_bytes, "Authorization")
	testing.expect(t, has_authorization, "basic auth must be preemptive")
	testing.expect_value(t, authorization, "Basic dXNlcjpwYXNz")

	// The credentials in the URL are the fallback: request_create splits the
	// userinfo out of the URL and the engine turns it into the same header.
	userinfo_url := fmt.aprintf("http://user:pass@127.0.0.1:%d/echo", server.port, allocator = allocator)
	from_url, url_err := http.request_create(allocator, .GET, userinfo_url, nil)
	testing.expect_value(t, url_err, http.Error.None)
	testing.expect_value(t, from_url.userinfo, "user:pass")
	from_url_response: http.Response
	testing.expect_value(t, engine_send(t, &from_url, &from_url_response), http.Error.None)
	from_url_bytes := engine_request_clone(server, 1, allocator) or_else ""
	from_url_header, has_from_url := engine_header_of(from_url_bytes, "Authorization")
	testing.expect(t, has_from_url, "the URL's userinfo must be used as a fallback")
	testing.expect_value(t, from_url_header, "Basic dXNlcjpwYXNz")
	testing.expect(t, !strings.contains(from_url_bytes, "user:pass@"), "the userinfo must not go out in the URL")

	bearer, bearer_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, bearer_err, http.Error.None)
	testing.expect_value(t, http.request_set_auth(&bearer, "tok", .Bearer), http.Error.None)
	bearer_response: http.Response
	testing.expect_value(t, engine_send(t, &bearer, &bearer_response), http.Error.None)
	bearer_bytes := engine_request_clone(server, 2, allocator) or_else ""
	bearer_header, has_bearer := engine_header_of(bearer_bytes, "Authorization")
	testing.expect(t, has_bearer, "bearer auth must be preemptive")
	testing.expect_value(t, bearer_header, "Bearer tok")

	// Digest is the opposite case: the header can only be built after the
	// server's challenge, so the first request must go out bare and libcurl
	// answers the 401 (its own handshake, which this server never sends).
	digest, digest_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, digest_err, http.Error.None)
	testing.expect_value(t, http.request_set_auth(&digest, "user:pass", .Digest), http.Error.None)
	digest_response: http.Response
	testing.expect_value(t, engine_send(t, &digest, &digest_response), http.Error.None)
	digest_bytes := engine_request_clone(server, 3, allocator) or_else ""
	_, has_digest := engine_header_of(digest_bytes, "Authorization")
	testing.expect(t, !has_digest, "digest auth must wait for the challenge")

	http.response_destroy(&basic_response)
	http.response_destroy(&from_url_response)
	http.response_destroy(&bearer_response)
	http.response_destroy(&digest_response)
	http.request_destroy(&basic)
	http.request_destroy(&from_url)
	http.request_destroy(&bearer)
	http.request_destroy(&digest)
	delete(url, allocator)
	delete(userinfo_url, allocator)
	delete(basic_bytes, allocator)
	delete(from_url_bytes, allocator)
	delete(bearer_bytes, allocator)
	delete(digest_bytes, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// Typed errors and decoding
// ---------------------------------------------------------------------------

@(test)
test_engine_reports_connection_and_resolution_failures :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// A port that nothing listens on: bind one, learn its number, close it.
	vacant, listen_err := net.listen_tcp(net.Endpoint {
		address = net.Address(net.IP4_Address { 127, 0, 0, 1 }),
		port    = 0,
	})
	testing.expect(t, listen_err == nil, "a listener must be creatable")
	bound, info_err := net.bound_endpoint(vacant)
	testing.expect_value(t, info_err, net.Socket_Info_Error.None)
	net.close(vacant)

	refused_url := fmt.aprintf("http://127.0.0.1:%d/", bound.port, allocator = allocator)
	refused, refused_err := http.request_create(allocator, .GET, refused_url, nil)
	testing.expect_value(t, refused_err, http.Error.None)
	refused_response: http.Response
	testing.expect_value(t, engine_send(t, &refused, &refused_response), http.Error.Connection_Failed)
	testing.expect_value(t, refused_response.status, 0)

	// A name that cannot resolve (`.invalid` is reserved for exactly this).
	dns_url := strings.clone("http://htthor-does-not-resolve.invalid/", allocator)
	dns, dns_err := http.request_create(allocator, .GET, dns_url, nil)
	testing.expect_value(t, dns_err, http.Error.None)
	dns_response: http.Response
	testing.expect_value(t, engine_send(t, &dns, &dns_response), http.Error.DNS_Failure)

	testing.expect_value(t, len(track.bad_free_array), 0)
	http.request_destroy(&refused)
	http.request_destroy(&dns)
	delete(refused_url, allocator)
	delete(dns_url, allocator)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_reports_a_timeout :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	engine_silence_next(server)

	url := engine_url(server, "/slow", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.timeout_s = 1

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.Timeout)

	http.request_destroy(&request)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_decodes_chunked_and_compressed_bodies :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	// Chunked framing is the transport's problem, not the caller's.
	engine_queue_reply(server, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
	// gzip("hello gzip"), fixed bytes so the fixture is deterministic.
	gzip_body := [30]u8 {
		0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03,
		0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x48, 0xaf, 0xca, 0x2c,
		0x00, 0x00, 0x19, 0x6a, 0xd2, 0xdf, 0x0a, 0x00, 0x00, 0x00,
	}
	gzip_reply, gzip_err := strings.concatenate(
		{
			"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 30\r\nConnection: close\r\n\r\n",
			string(gzip_body[:]),
		},
		allocator,
	)
	testing.expect_value(t, gzip_err, mem.Allocator_Error.None)
	engine_queue_reply(server, gzip_reply)

	url := engine_url(server, "/encoded", allocator)

	chunked, chunked_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, chunked_err, http.Error.None)
	chunked_response: http.Response
	testing.expect_value(t, engine_send(t, &chunked, &chunked_response), http.Error.None)
	testing.expect_value(t, string(chunked_response.body), "hello world")

	compressed, compressed_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, compressed_err, http.Error.None)
	compressed_response: http.Response
	testing.expect_value(t, engine_send(t, &compressed, &compressed_response), http.Error.None)
	testing.expect_value(t, string(compressed_response.body), "hello gzip")

	http.response_destroy(&chunked_response)
	http.response_destroy(&compressed_response)
	http.request_destroy(&chunked)
	http.request_destroy(&compressed)
	delete(url, allocator)
	delete(gzip_reply, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_streams_the_body_to_a_caller_writer :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	temp_dir := engine_scratch_dir(t)
	download_path := fmt.aprintf("%s/htthor_engine_download.txt", temp_dir, allocator = allocator)

	file, open_err := os.open(download_path, os.O_CREATE | os.O_WRONLY | os.O_TRUNC, os.Permissions_Default_File)
	testing.expect(t, open_err == nil, "the download sink must open")

	url := engine_url(server, "/download", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	testing.expect_value(t, http.request_prepare(&request), http.Error.None)

	response: http.Response
	testing.expect_value(t, http.send_to(&request, &response, os.to_writer(file)), http.Error.None)
	testing.expect_value(t, len(response.body), 0) // the body went to the file

	os.close(file)
	contents, read_err := os.read_entire_file_from_path(download_path, allocator)
	testing.expect(t, read_err == nil, "the download must be readable")
	testing.expect_value(t, string(contents), "ok")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(contents, allocator)
	delete(url, allocator)
	delete(download_path, allocator)
	os.remove(download_path)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// Transport options: --proxy, --max-headers, .netrc, Digest
// ---------------------------------------------------------------------------

@(test)
test_engine_uses_the_proxy_entry_and_drops_proxy_connection :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The same one-thread server doubles as the proxy: it records the bytes it
	// received, which is where the proxied request line shows up.
	server, started := engine_server_start(backing)
	testing.expect(t, started, "the proxy server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	// `--proxy` arrives in the reference's own grammar — `PROTOCOL:PROXY_URL`
	// (docs/PARITY.md §2) — with the session having picked the entry for the
	// request's scheme. The Request only *borrows* it (docs/ARCHITECTURE.md §4:
	// cli.Options owns the entries and options_destroy frees them), so this
	// test, which has no Options, owns its own string and frees it below.
	proxy := fmt.aprintf("http:http://127.0.0.1:%d", server.port, allocator = allocator)
	request.proxy = proxy

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)
	testing.expect_value(t, response.status, 200)

	bytes_received := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect(t, len(bytes_received) > 0, "the proxy must have seen the request")

	// A proxied request asks for the absolute URI ...
	expected_line := fmt.aprintf("GET %s HTTP/1.1", url, allocator = allocator)
	testing.expect_value(t, engine_request_line(bytes_received), expected_line)
	// ... and carries no `Proxy-Connection` of libcurl's making.
	_, has_proxy_connection := engine_header_of(bytes_received, "Proxy-Connection")
	testing.expect(t, !has_proxy_connection, "libcurl's Proxy-Connection must be suppressed")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(proxy, allocator)
	delete(url, allocator)
	delete(expected_line, allocator)
	delete(bytes_received, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_sends_a_user_supplied_host_header :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the loopback server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	// A `Host:` request item. libcurl derives one from the URL unless the
	// caller supplies it, and the transport used to drop it from the header
	// list — so the request rendered correctly and the server still saw the
	// URL's host. The value is what this asserts.
	testing.expect_value(t, http.request_add_header(&request, "Host", "example.org"), http.Error.None)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)
	testing.expect_value(t, response.status, 200)

	received := engine_request_clone(server, 0, allocator) or_else ""
	host, has_host := engine_header_of(received, "Host")
	testing.expect(t, has_host, "the request must carry a Host header")
	testing.expect_value(t, host, "example.org")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	delete(received, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_refuses_a_head_past_max_headers :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	// The head is four lines: three headers and the blank line that ends it —
	// and http.client counts the blank line (client.py:218-234), so a limit of
	// three refuses this reply while a limit of four accepts it.
	reply := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
	engine_queue_reply(server, reply)
	engine_queue_reply(server, reply)

	url := engine_url(server, "/json", allocator)

	refused, refused_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, refused_err, http.Error.None)
	refused.max_headers = 3
	refused_response: http.Response
	testing.expect_value(t, engine_send(t, &refused, &refused_response), http.Error.Max_Headers_Exceeded)
	// Nothing of the refused reply is handed to the caller.
	testing.expect_value(t, refused_response.status, 0)
	testing.expect_value(t, len(refused_response.body), 0)

	accepted, accepted_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, accepted_err, http.Error.None)
	accepted.max_headers = 4
	accepted_response: http.Response
	testing.expect_value(t, engine_send(t, &accepted, &accepted_response), http.Error.None)
	testing.expect_value(t, accepted_response.status, 200)
	testing.expect_value(t, string(accepted_response.body), "ok")

	http.response_destroy(&refused_response)
	http.response_destroy(&accepted_response)
	http.request_destroy(&refused)
	http.request_destroy(&accepted)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_keeps_each_response_header_separate :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	// The fixture's /cookie reply: Content-Type, Set-Cookie, Content-Length. A
	// Set-Cookie that swallowed its own line ending would reach the renderer as
	// one header, so the engine has to hand over two.
	cookie :: "BODY=deterministic-cookie; Path=/; HttpOnly"
	engine_queue_reply(server,
		"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" +
		"Set-Cookie: BODY=deterministic-cookie; Path=/; HttpOnly\r\n" +
		"Content-Length: 4\r\nConnection: close\r\n\r\nset\n")

	url := engine_url(server, "/cookie", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)
	testing.expect_value(t, len(response.headers), 4)
	testing.expect_value(t, response.headers[0].name, "Content-Type")
	testing.expect_value(t, response.headers[0].value, "text/plain")
	testing.expect_value(t, response.headers[1].name, "Set-Cookie")
	testing.expect_value(t, response.headers[1].value, cookie)
	testing.expect_value(t, response.headers[2].name, "Content-Length")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_reads_netrc_credentials :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	temp_dir := engine_scratch_dir(t)
	netrc_path := fmt.aprintf("%s/htthor_engine_netrc", temp_dir, allocator = allocator)
	written := os.write_entire_file_from_string(
		netrc_path,
		"# htthor engine test\n" +
		"machine 127.0.0.1\n" +
		"  login user\n" +
		"  password pass\n" +
		"\n" +
		"machine other.example login nobody password nothing\n",
	)
	testing.expect(t, written == nil, "the netrc fixture must be writable")

	// requests reads $NETRC in preference to ~/.netrc, so pointing the variable
	// at the fixture keeps the test independent of the runner's home directory.
	os.set_env("NETRC", netrc_path)
	defer os.unset_env("NETRC")

	credentials, found := http.netrc_credentials("127.0.0.1", allocator)
	testing.expect(t, found, "the 127.0.0.1 entry must be found")
	testing.expect_value(t, credentials, "user:pass")
	delete(credentials, allocator)

	_, unknown_found := http.netrc_credentials("not-in-the-file.example", allocator)
	testing.expect(t, !unknown_found, "a host with no entry must not authenticate")

	// The credentials the session would apply reach the wire as the preemptive
	// Basic header the reference sends (requests resolves netrc itself).
	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")

	url := engine_url(server, "/echo", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	from_netrc, netrc_found := http.netrc_credentials(request.host, allocator)
	testing.expect(t, netrc_found, "the request's host must have an entry")
	testing.expect_value(t, http.request_set_auth(&request, from_netrc, .Basic), http.Error.None)
	delete(from_netrc, allocator)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)

	bytes_received := engine_request_clone(server, 0, allocator) or_else ""
	authorization, has_authorization := engine_header_of(bytes_received, "Authorization")
	testing.expect(t, has_authorization, "netrc credentials must authenticate the request")
	testing.expect_value(t, authorization, "Basic dXNlcjpwYXNz")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(bytes_received, allocator)
	delete(url, allocator)
	delete(netrc_path, allocator)
	os.remove(netrc_path)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_answers_a_digest_challenge :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the challenge server must start")

	challenge, challenge_err := strings.concatenate({
		"HTTP/1.1 401 Unauthorized\r\n",
		"Content-Type: text/plain\r\n",
		"WWW-Authenticate: Digest realm=\"parity\", qop=\"auth\", ",
		"nonce=\"deterministic-nonce-0001\", opaque=\"deterministic-opaque\", algorithm=MD5\r\n",
		"Content-Length: 0\r\n",
		"Connection: close\r\n\r\n",
	}, allocator)
	testing.expect_value(t, challenge_err, mem.Allocator_Error.None)
	accepted := strings.clone(
		"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 14\r\nConnection: close\r\n\r\nauthenticated\n",
		allocator,
	) or_else ""
	engine_queue_reply(server, challenge)
	engine_queue_reply(server, accepted)

	url := engine_url(server, "/auth/digest", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	testing.expect_value(t, http.request_set_auth(&request, "user:pass", .Digest), http.Error.None)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)

	// The 401 is not the reply: the challenge was answered and its response is
	// what the caller receives — one head, one body, not the two the server sent.
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, response.reason, "OK")
	testing.expect_value(t, string(response.body), "authenticated\n")
	// Content-Type, Content-Length and the fixture's own Connection header — the
	// challenge's own head is not in there.
	testing.expect_value(t, len(response.headers), 3)
	testing.expect_value(t, response.headers[0].name, "Content-Type")
	testing.expect_value(t, response.headers[1].name, "Content-Length")

	// The first request goes out bare; the second carries the RFC 2617 answer.
	testing.expect_value(t, len(server.requests), 2)
	first := engine_request_clone(server, 0, allocator) or_else ""
	_, first_has_authorization := engine_header_of(first, "Authorization")
	testing.expect(t, !first_has_authorization, "digest must wait for the challenge")
	second := engine_request_clone(server, 1, allocator) or_else ""
	authorization, second_has_authorization := engine_header_of(second, "Authorization")
	testing.expect(t, second_has_authorization, "the challenge must be answered")
	testing.expect(t, strings.has_prefix(authorization, "Digest "), "the answer must be a Digest header")
	testing.expect(t, strings.contains(authorization, "nonce=\"deterministic-nonce-0001\""),
		"the answer must use the server's nonce")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(first, allocator)
	delete(second, allocator)
	delete(challenge, allocator)
	delete(accepted, allocator)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// The other two shapes a Digest answer has to survive: an upload whose stream
// the first send spends, and a HEAD whose reply *is* its head.
//
// Both are hop ends the port takes mid-transfer (`Transfer.head_reply_only`):
// the chunked upload's body is a stream that cannot be replayed, and a HEAD
// reply has no body to read. Neither is a failure — the challenge is in the
// head that arrived either way, and the second send carries the answer.

// ENGINE_DIGEST_CHALLENGE_REPLY is the fixture's own 401, byte for byte
// (tests/parity/server.py's `/auth/digest`), body included: the reference reads
// that body and throws it away (`r.content` in `handle_401`), and so does the
// port.
ENGINE_DIGEST_CHALLENGE_REPLY ::
	"HTTP/1.1 401 Unauthorized\r\n" +
	"Content-Type: text/plain\r\n" +
	"WWW-Authenticate: Digest realm=\"parity\", qop=\"auth\", nonce=\"deterministic-nonce-0001\", opaque=\"deterministic-opaque\", algorithm=MD5\r\n" +
	"Content-Length: 7\r\n" +
	"Connection: close\r\n" +
	"\r\n" +
	"denied\n"

// A HEAD's challenge: the same 401 with no body, because a reply to a HEAD has
// none — the `Content-Length` it announces is the length the body would have
// had. A reader that waits for those bytes waits forever, which is what this
// port used to do (docs/PARITY.md §4.1).
ENGINE_DIGEST_CHALLENGE_HEAD_REPLY ::
	"HTTP/1.1 401 Unauthorized\r\n" +
	"Content-Type: text/plain\r\n" +
	"WWW-Authenticate: Digest realm=\"parity\", qop=\"auth\", nonce=\"deterministic-nonce-0001\", opaque=\"deterministic-opaque\", algorithm=MD5\r\n" +
	"Content-Length: 7\r\n" +
	"Connection: close\r\n" +
	"\r\n"

// The authenticated reply to a HEAD, likewise body-less.
ENGINE_HEAD_OK_REPLY ::
	"HTTP/1.1 200 OK\r\n" +
	"Content-Type: text/plain\r\n" +
	"Content-Length: 14\r\n" +
	"Connection: close\r\n" +
	"\r\n"

@(test)
test_engine_answers_a_digest_challenge_on_a_chunked_upload :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the challenge server must start")

	engine_queue_reply(server, ENGINE_DIGEST_CHALLENGE_REPLY)
	engine_queue_reply(server, ENGINE_OK_REPLY)

	url := engine_url(server, "/auth/digest", allocator)
	request, create_err := http.request_create(allocator, .POST, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.chunked = true
	items := []http.Data_Item {{kind = .String, name = "foo", value = "bar"}}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)
	testing.expect_value(t, http.request_set_auth(&request, "user:pass", .Digest), http.Error.None)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)

	// The challenge is not the reply: the caller receives the authenticated
	// one, and the challenge's body is nowhere in it.
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body), "ok")

	testing.expect_value(t, len(server.requests), 2)
	first := engine_request_clone(server, 0, allocator) or_else ""
	_, first_has_authorization := engine_header_of(first, "Authorization")
	testing.expect(t, !first_has_authorization, "digest must wait for the challenge")
	testing.expect(t, strings.contains(engine_body_of(first), `{"foo": "bar"}`),
		"the first send carries the whole upload")
	testing.expect(t, strings.has_suffix(engine_body_of(first), "0\r\n\r\n"),
		"and its framing ends it")

	// The upload is spent: the second send puts the header on and no body. The
	// bytes are the framing and the terminating chunk alone, which is what the
	// reference's own retry sends (build/probe_digest_head.py --wire).
	second := engine_request_clone(server, 1, allocator) or_else ""
	authorization, second_has_authorization := engine_header_of(second, "Authorization")
	testing.expect(t, second_has_authorization, "the challenge must be answered")
	engine_digest_answer_matches(t, authorization, "POST", "/auth/digest")
	engine_expect_body(t, second, "0\r\n\r\n")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(first, allocator)
	delete(second, allocator)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

@(test)
test_engine_answers_a_digest_challenge_for_a_head_with_a_body :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the challenge server must start")

	engine_queue_reply(server, ENGINE_DIGEST_CHALLENGE_HEAD_REPLY)
	engine_queue_reply(server, ENGINE_HEAD_OK_REPLY)

	url := engine_url(server, "/auth/digest", allocator)
	request, create_err := http.request_create(allocator, .HEAD, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.json_accept = true
	items := []http.Data_Item {{kind = .String, name = "foo", value = "bar"}}
	testing.expect_value(t, http.request_add_items(&request, items), http.Error.None)
	testing.expect_value(t, http.request_set_auth(&request, "user:pass", .Digest), http.Error.None)

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.None)

	// The reply is its head — and it is the *200*'s head, not the 401's.
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body), "")

	testing.expect_value(t, len(server.requests), 2)
	first := engine_request_clone(server, 0, allocator) or_else ""
	testing.expect_value(t, engine_request_line(first), "HEAD /auth/digest HTTP/1.1")
	_, first_has_authorization := engine_header_of(first, "Authorization")
	testing.expect(t, !first_has_authorization, "digest must wait for the challenge")
	engine_expect_body(t, first, "{\"foo\": \"bar\"}")

	// The body is re-sendable here (its length is known), so the retry is the
	// whole request again with the answer on it — what requests' second
	// `send()` does with the same prepared request.
	second := engine_request_clone(server, 1, allocator) or_else ""
	authorization, second_has_authorization := engine_header_of(second, "Authorization")
	testing.expect(t, second_has_authorization, "the challenge must be answered")
	engine_digest_answer_matches(t, authorization, "HEAD", "/auth/digest")
	engine_expect_body(t, second, "{\"foo\": \"bar\"}")

	http.response_destroy(&response)
	http.request_destroy(&request)
	delete(first, allocator)
	delete(second, allocator)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// engine_digest_quoted reads a `name="value"` field out of a Digest header,
// `prefix` carrying the `="`; "" when the field is not there.
engine_digest_quoted :: proc(header: string, prefix: string) -> string {
	at := strings.index(header, prefix)
	if at < 0 {
		return ""
	}
	rest := header[at + len(prefix):]
	if end := strings.index(rest, "\""); end >= 0 {
		return rest[:end]
	}
	return ""
}

// engine_digest_bare reads an unquoted field the same way: from `prefix` to the
// next comma (`nc=00000001` is the one).
engine_digest_bare :: proc(header: string, prefix: string) -> string {
	at := strings.index(header, prefix)
	if at < 0 {
		return ""
	}
	rest := header[at + len(prefix):]
	if end := strings.index(rest, ","); end >= 0 {
		return strings.trim_space(rest[:end])
	}
	return strings.trim_space(rest)
}

// engine_digest_answer_matches recomputes the `response` field the way the
// reference's server does (tests/parity/server.py's `digest_ok`) and checks the
// fields it is computed over against the challenge the server sent. A header
// with a plausible-looking hash in it is not an answer; this is what makes the
// second send's bytes the ones the challenge asks for.
engine_digest_answer_matches :: proc(t: ^testing.T, header: string, method: string, target: string) {
	username := engine_digest_quoted(header, `username="`)
	realm := engine_digest_quoted(header, `realm="`)
	nonce := engine_digest_quoted(header, `nonce="`)
	uri := engine_digest_quoted(header, `uri="`)
	response := engine_digest_quoted(header, `response="`)
	cnonce := engine_digest_quoted(header, `cnonce="`)
	nc := engine_digest_bare(header, ", nc=")

	testing.expect_value(t, username, "user")
	testing.expect_value(t, realm, "parity")
	testing.expect_value(t, nonce, "deterministic-nonce-0001")
	testing.expect_value(t, uri, target)
	testing.expect_value(t, nc, "00000001")
	testing.expect_value(t, len(cnonce), 16)

	ha1, ha2, expected: [http.MD5_HEX_SIZE]u8
	http.md5_hex_join({username, ":", realm, ":", "pass"}, &ha1)
	http.md5_hex_join({method, ":", uri}, &ha2)
	http.md5_hex_join({string(ha1[:]), ":", nonce, ":", nc, ":", cnonce, ":auth:", string(ha2[:])}, &expected)
	testing.expectf(t, response == string(expected[:]),
	                "%s %s: the response must be the one the challenge's parameters produce: %s ≠ %s",
	                method, uri, response, string(expected[:]))
}

// A chain stopped by `--max-redirects` is the other half of `follow_abort`'s
// ownership rule: the abort happens *after* every hop it made has been pushed
// into `transfer.history`, so unlike the refused-connection and resolution
// failures the request-only entry does not sit alone — the entries before it
// own a status, a reason and their headers as well as a URL. Whichever shape
// the chain died in, the chain is published on the *request*
// (`Request.follow_history`, types.odin) and freed by `request_destroy`, never
// left on a reply `send` documented as zeroed on failure; `engine_no_leaks`
// below is the assertion that this whole class of entries is released, the
// 27/35-byte one of the timeout and resolution tests included.
@(test)
test_engine_aborts_a_chain_at_the_redirect_limit :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	server, started := engine_server_start(backing)
	testing.expect(t, started, "the echo server must start")
	// Two hops, then the limit: httpie counts responses, not followed
	// redirects (client.py:120-127), so `max_redirects = 2` lets `/first` and
	// `/next` go out and refuses the third request — `/again` is never made.
	engine_queue_reply(server, "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
	engine_queue_reply(server, "HTTP/1.1 302 Found\r\nLocation: /again\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

	url := engine_url(server, "/first", allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	testing.expect_value(t, create_err, http.Error.None)
	request.follow_redirects = true
	request.max_redirects = 2

	response: http.Response
	testing.expect_value(t, engine_send(t, &request, &response), http.Error.Too_Many_Redirects)

	// A failed `send` leaves the reply zeroed — the contract the transport used
	// to break by handing the aborting chain back through `res.history`.
	testing.expect_value(t, response.status, 0)
	testing.expect_value(t, len(response.history), 0)

	// The two requests the chain made, in order: the hop that completed (with
	// the 302 that made it a hop) and the one that was in flight when the limit
	// stopped the chain (request-only, so no reply to describe).
	testing.expect_value(t, len(request.follow_history), 2)
	if len(request.follow_history) == 2 {
		testing.expect_value(t, request.follow_history[0].method, http.Method.GET)
		testing.expect(t, strings.has_suffix(request.follow_history[0].url, "/first"),
		               "the completed hop keeps its own URL")
		testing.expect_value(t, request.follow_history[0].status, 302)
		testing.expect_value(t, request.follow_history[1].method, http.Method.GET)
		testing.expect(t, strings.has_suffix(request.follow_history[1].url, "/next"),
		               "the in-flight hop is the one the limit caught")
		testing.expect_value(t, request.follow_history[1].status, 0)
	}

	// The limit is a limit: the third request was never sent.
	second, has_second := engine_request_clone(server, 1, allocator)
	testing.expect(t, has_second, "the chain's second hop must have gone out")
	if has_second {
		testing.expect_value(t, engine_request_line(second), "GET /next HTTP/1.1")
		delete(second, allocator)
	}
	third, has_third := engine_request_clone(server, 2, allocator)
	testing.expect(t, !has_third, "the refused hop must not be sent")
	if has_third {
		delete(third, allocator)
	}

	http.request_destroy(&request)
	delete(url, allocator)
	engine_server_destroy(server)
	engine_no_leaks(t, &track)
}

// ---------------------------------------------------------------------------
// Cookies on a followed redirect (SF-001)
// ---------------------------------------------------------------------------

// ENGINE_COOKIE_SECRET is the value the stub jar hands a hop it accepts.
ENGINE_COOKIE_SECRET :: "sess=JARSECRET"

// engine_cookie_hook_state is the stub jar's policy for one case: `prefix` is
// the URL prefix the cookie was stored for (a host-only cookie goes back to its
// own host alone) and `path_ok` is the path rule's answer for the target.
engine_cookie_hook_state :: struct {
	prefix:  string,
	path_ok: bool,
}

// engine_cookie_hook_value is a stub http.Cookie_Hook.value: it answers the way
// the session's jar would — the secret for a URL it accepts, "" for one whose
// host or path the policy rejects — so the cases below can tell a re-derived
// header from a replayed one.
engine_cookie_hook_value :: proc(data: rawptr, url: string, allocator: mem.Allocator) -> string {
	state := (^engine_cookie_hook_state)(data)
	if !state.path_ok || !strings.has_prefix(url, state.prefix) {
		return ""
	}
	return strings.clone(ENGINE_COOKIE_SECRET, allocator) or_else ""
}

// engine_redirect_reply is a 302 whose Location is `target`, owned by the caller.
engine_redirect_reply :: proc(target: string, allocator: mem.Allocator) -> string {
	return fmt.aprintf(
		"HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
		target,
		allocator = allocator,
	)
}

// engine_cookie_redirect runs one followed exchange from `origin`: `reply` is
// the origin's canned answer (whose Location names the sink), `cookie_header`
// is the `Cookie:` item the request carries ("" for none) and `hook` the jar
// the request carries (the zero value for none). Reports false when the
// exchange did not complete, in which case the caller asserts nothing.
engine_cookie_redirect :: proc(
	t: ^testing.T,
	origin: ^Engine_Server,
	reply: string,
	cookie_header: string,
	hook: http.Cookie_Hook,
	allocator: mem.Allocator,
) -> bool {
	engine_queue_reply(origin, reply)
	url := engine_url(origin, "/first", allocator)
	defer delete(url, allocator)
	request, create_err := http.request_create(allocator, .GET, url, nil)
	if create_err != .None {
		testing.expectf(t, false, "request_create: %v", create_err)
		return false
	}
	defer http.request_destroy(&request)
	request.follow_redirects = true
	request.max_redirects = 5
	request.cookie_hook = hook
	if cookie_header != "" {
		testing.expect_value(t, http.request_add_header(&request, "Cookie", cookie_header), http.Error.None)
	}

	response: http.Response
	defer http.response_destroy(&response)
	send_err := engine_send(t, &request, &response)
	if send_err != .None {
		testing.expectf(t, false, "the followed exchange failed: %v", send_err)
		return false
	}
	return true
}

// engine_cookie_of is the `Cookie` header of the index-th request a server
// captured, and whether that line is there at all. The clone it reads through
// is released here.
engine_cookie_of :: proc(server: ^Engine_Server, index: int, allocator: mem.Allocator) -> (value: string, found: bool) {
	raw, ok := engine_request_clone(server, index, allocator)
	if !ok {
		return "", false
	}
	defer delete(raw, allocator)
	return engine_header_of(raw, "Cookie")
}

// SF-001: the `Cookie` header a request is built with belongs to the *first*
// URL. requests pops it on every followed redirect and re-derives it from the
// merged jar for the new URL (sessions.py:235-243), so a cross-host hop carries
// no cookie, a same-host/other-port hop carries the jar's, and the first URL's
// header is never replayed. Every assertion below is on the bytes a listener
// actually captured.
@(test)
test_engine_rebuilds_the_cookie_header_on_a_redirect :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The redirecting origin, a sink on another *host* (127.0.0.2), and a
	// second listener on the origin's own host but another port: a port change
	// keeps cookies, by design, so only a host change may drop them.
	origin, origin_started := engine_server_start(backing)
	testing.expect(t, origin_started, "the origin server must start")
	sink, sink_started := engine_server_start_on(backing, net.IP4_Address { 127, 0, 0, 2 })
	testing.expect(t, sink_started, "the cross-host sink must start")
	neighbour, neighbour_started := engine_server_start(backing)
	testing.expect(t, neighbour_started, "the same-host listener must start")

	if origin_started && sink_started && neighbour_started {
		cross_host := fmt.aprintf("http://127.0.0.2:%d/landing", sink.port, allocator = allocator)
		same_host := engine_url(neighbour, "/landing", allocator)
		defer delete(cross_host, allocator)
		defer delete(same_host, allocator)

		// Case 1: no jar in the run, a `Cookie:` item on the request. The
		// followed hop must not see it; the first hop must still carry it
		// unchanged.
		reply := engine_redirect_reply(cross_host, allocator)
		if engine_cookie_redirect(t, origin, reply, "item=1", {}, allocator) {
			value, has_cookie := engine_cookie_of(origin, 0, allocator)
			testing.expectf(t, has_cookie && value == "item=1", "hop 1 must carry the item's Cookie, got %q", value)
			_, hop2_cookie := engine_cookie_of(sink, 0, allocator)
			testing.expect(t, !hop2_cookie, "a cross-host hop must not carry the first URL's Cookie")
		}
		delete(reply, allocator)

		state := engine_cookie_hook_state {
			prefix  = "http://127.0.0.1:",
			path_ok = true,
		}
		hook := http.Cookie_Hook {
			data  = rawptr(&state),
			value = engine_cookie_hook_value,
		}

		// Case 2: the same cross-host 302, with a jar stub that accepts the
		// origin's host only. The hop is the other host, so the stub answers ""
		// and no line goes out.
		reply = engine_redirect_reply(cross_host, allocator)
		if engine_cookie_redirect(t, origin, reply, "item=1", hook, allocator) {
			_, hop2_cookie := engine_cookie_of(sink, 1, allocator)
			testing.expect(t, !hop2_cookie, "the jar refused this host: no Cookie line may go out")
		}
		delete(reply, allocator)

		// Case 3: the same stub, a 302 to the same host on another port. The
		// stub accepts it, so the hop carries the jar's value — and not the
		// first URL's item.
		reply = engine_redirect_reply(same_host, allocator)
		if engine_cookie_redirect(t, origin, reply, "item=1", hook, allocator) {
			value, has_cookie := engine_cookie_of(neighbour, 0, allocator)
			testing.expectf(
				t,
				has_cookie && value == ENGINE_COOKIE_SECRET,
				"a same-host hop must carry the jar's Cookie, got %q",
				value,
			)
		}
		delete(reply, allocator)

		// Case 4: the stub rejects the path (what a `Path` rule outside the
		// target answers). The hop gets no line at all.
		state.path_ok = false
		reply = engine_redirect_reply(same_host, allocator)
		if engine_cookie_redirect(t, origin, reply, "item=1", hook, allocator) {
			_, hop2_cookie := engine_cookie_of(neighbour, 1, allocator)
			testing.expect(t, !hop2_cookie, "the jar's path rule rejected the hop: no Cookie line may go out")
		}
		delete(reply, allocator)
	}

	engine_server_destroy(neighbour)
	engine_server_destroy(sink)
	engine_server_destroy(origin)
	engine_no_leaks(t, &track)
}

// ENGINE_AUTHORIZATION is `Basic alice:s3cr3t`, the credential line the SF-002
// cases put on the request.
ENGINE_AUTHORIZATION :: "Basic YWxpY2U6czNjcjN0"

// SF-002: `Authorization` follows a redirect that stays on the origin and is
// dropped when the origin changes (requests' should_strip_auth, sessions.py:
// 128-158). Part (a) is the request-relative Location that stays on the origin;
// part (b) is the same host on another port, where the second listener's bytes
// are the only witness — and the case a fail-open rewrite would leak through.
@(test)
test_engine_keeps_and_strips_authorization_across_a_redirect :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	origin, origin_started := engine_server_start(backing)
	testing.expect(t, origin_started, "the origin server must start")
	other, other_started := engine_server_start(backing)
	testing.expect(t, other_started, "the other-origin listener must start")

	if origin_started && other_started {
		start_url := engine_url(origin, "/start", allocator)
		defer delete(start_url, allocator)

		// (a) `Location: /next` is the same origin, so the credentials stay.
		engine_queue_reply(origin, "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		request, create_err := http.request_create(allocator, .GET, start_url, nil)
		testing.expect_value(t, create_err, http.Error.None)
		if create_err == .None {
			request.follow_redirects = true
			request.max_redirects = 5
			testing.expect_value(
				t,
				http.request_add_header(&request, "Authorization", ENGINE_AUTHORIZATION),
				http.Error.None,
			)
			response: http.Response
			if engine_send(t, &request, &response) == .None {
				second := engine_request_clone(origin, 1, allocator) or_else ""
				value, has_authorization := engine_header_of(second, "Authorization")
				testing.expectf(
					t,
					has_authorization && value == ENGINE_AUTHORIZATION,
					"a same-origin hop must keep Authorization, got %q",
					value,
				)
				delete(second, allocator)
			}
			http.response_destroy(&response)
			http.request_destroy(&request)
		}

		// (b) an absolute Location on another port is another origin, so the
		// credentials do not go out.
		target := engine_url(other, "/landing", allocator)
		reply := engine_redirect_reply(target, allocator)
		delete(target, allocator)
		engine_queue_reply(origin, reply)
		delete(reply, allocator)

		request_b, create_err_b := http.request_create(allocator, .GET, start_url, nil)
		testing.expect_value(t, create_err_b, http.Error.None)
		if create_err_b == .None {
			request_b.follow_redirects = true
			request_b.max_redirects = 5
			testing.expect_value(
				t,
				http.request_add_header(&request_b, "Authorization", ENGINE_AUTHORIZATION),
				http.Error.None,
			)
			response_b: http.Response
			if engine_send(t, &request_b, &response_b) == .None {
				landing := engine_request_clone(other, 0, allocator) or_else ""
				_, has_authorization := engine_header_of(landing, "Authorization")
				testing.expect(t, !has_authorization, "an origin-changing hop must not carry Authorization")
				delete(landing, allocator)
			}
			http.response_destroy(&response_b)
			http.request_destroy(&request_b)
		}
	}

	engine_server_destroy(other)
	engine_server_destroy(origin)
	engine_no_leaks(t, &track)
}
