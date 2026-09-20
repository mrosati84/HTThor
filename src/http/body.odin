// Body encodings: the bytes httpie puts on the wire for a request's data items
// (or for a raw body), and the Content-Type that goes with them.
//
// The exact bytes are the contract — docs/PARITY.md §3.4/§4.5 and the
// `post-json-*`, `post-form`, `post-multipart` captures:
//
//   JSON      {"name": "John", "age": 30}   Python's default separators,
//                                           ensure_ascii=True, insertion order,
//                                           duplicate keys kept
//   Form      name=John&lang=Python         quote_plus, safe=''
//   Multipart `--B\r\nContent-Disposition: form-data; name="f"…` per urllib3
//
// Everything allocated here comes from the Request's allocator and is released
// by request_destroy.
package http

import "core:math/rand"
import "core:mem"
import "core:os"
import "core:strings"

import "vendor:zlib"

// httpie's Accept depends on whether it is sending a JSON body
// (docs/PARITY.md §1.2: `application/json, */*;q=0.5` vs `*/*`).
JSON_ACCEPT :: "application/json, */*;q=0.5"
NON_JSON_ACCEPT :: "*/*"

JSON_CONTENT_TYPE :: "application/json"
FORM_CONTENT_TYPE :: "application/x-www-form-urlencoded; charset=utf-8"
// MULTIPART_MEDIA_TYPE is the type a multipart body announces when the command
// line supplied no Content-Type item — the `encoder.content_type` the reference
// falls back to (uploads.py:249) — and MULTIPART_BOUNDARY_PARAMETER is the
// parameter appended to it, and to a Content-Type the command line did supply
// (uploads.py:246-248). MULTIPART_CONTENT_TYPE is the two joined, for the raw
// body a multipart request type announces without a boundary value
// (session/context.odin's raw_content_type).
MULTIPART_MEDIA_TYPE :: "multipart/form-data"
MULTIPART_BOUNDARY_PARAMETER :: "; boundary="
MULTIPART_CONTENT_TYPE :: MULTIPART_MEDIA_TYPE + MULTIPART_BOUNDARY_PARAMETER

// body_encode_items renders `req.items` according to `req.body_kind` into
// `req.body` and sets `req.body_content_type`. The multipart kind also assigns
// the request's Content-Type header, because its value is built from the CLI's
// own Content-Type item rather than from the body alone (see
// body_encode_multipart).
body_encode_items :: proc(req: ^Request) -> Error {
	switch req.body_kind {
	case .JSON:
		return body_encode_json(req)
	case .Form:
		return body_encode_form(req)
	case .Multipart:
		return body_encode_multipart(req)
	case .Raw:
		// `--raw` and data items are mutually exclusive in httpie; a Request
		// carrying both is a caller bug, and the engine says so instead of
		// guessing which one wins (docs/PARITY.md §1.2, `err-raw-and-data`).
		return .Unsupported_Body
	}
	return .None
}

// body_set stores the encoded bytes and the Content-Type describing them. It
// always consumes `buffer`.
body_set :: proc(req: ^Request, buffer: ^Buffer, content_type: string) -> Error {
	if !clone_into(&req.body_content_type, content_type, req.allocator) {
		buffer_destroy(buffer)
		return .Out_Of_Memory
	}
	delete(req.body, req.allocator)
	req.body = buffer_owned(buffer)
	return .None
}

// body_compress is httpie's --compress (uploads.py:252-269): the body is
// replaced by its zlib-wrapped deflate stream when that stream is shorter, and
// unconditionally when --compress was given more than once (`always`,
// client.py:99-102). Compression also adds `Content-Encoding: deflate`; the
// Content-Length is derived from the new body by request_prepare.
//
// The decision is taken once per request: body_compressed keeps a second
// request_prepare from deflating an already-deflated body.
body_compress :: proc(req: ^Request) -> Error {
	if req.compress == 0 || req.body_compressed || len(req.body) == 0 {
		return .None
	}

	deflated, ok := deflate_bytes(req.body, req.allocator)
	if !ok {
		return .Out_Of_Memory
	}
	req.body_compressed = true

	// `is_economical = len(deflated_data) < len(body_bytes)`, and the stream is
	// only kept when `is_economical or always`.
	if len(deflated) >= len(req.body) && req.compress == 1 {
		delete(deflated, req.allocator)
		return .None
	}

	delete(req.body, req.allocator)
	req.body = deflated
	return request_add_header(req, "Content-Encoding", "deflate")
}

// deflate_bytes is CPython's `zlib.compressobj()` pipeline: a zlib stream
// (windowBits 15, the default compression level), the body through compress()
// and the trailer through flush() (Z_FINISH). libz is the same library
// CPython's own zlib links against, so the stream is byte-identical — for
// `{"a": "1"}` it is the 18 bytes
// `78 9c ab 56 4a 54 b2 52 50 32 54 aa 05 00 0d d8 02 6d` the reference sends
// (docs/PARITY.md §2 --compress, `post-compress-forced`).
deflate_bytes :: proc(data: []byte, allocator: mem.Allocator) -> (out: []byte, ok: bool) {
	stream: zlib.z_stream
	if zlib.deflateInit(&stream, zlib.DEFAULT_COMPRESSION) != zlib.OK {
		return nil, false
	}
	defer zlib.deflateEnd(&stream)

	// deflateBound is zlib's own upper bound for this input, so one buffer
	// holds the whole stream and neither call below can run out of room.
	capacity := int(zlib.deflateBound(&stream, zlib.uLong(len(data))))
	buffer, alloc_err := make([]byte, capacity, allocator)
	if alloc_err != nil {
		return nil, false
	}

	stream.next_in = raw_data(data)
	stream.avail_in = u32(len(data))
	stream.next_out = raw_data(buffer)
	stream.avail_out = u32(capacity)

	if zlib.deflate(&stream, zlib.NO_FLUSH) != zlib.OK {
		delete(buffer, allocator)
		return nil, false
	}
	if zlib.deflate(&stream, zlib.FINISH) != zlib.STREAM_END {
		delete(buffer, allocator)
		return nil, false
	}
	return buffer[:int(stream.total_out)], true
}

// body_encode_json serialises the items as one JSON object: `name=value` items
// are JSON strings, `name:=json` items are spliced in verbatim.
body_encode_json :: proc(req: ^Request) -> Error {
	for item in req.items {
		if item.kind == .File {
			// `name@file` needs --form/--multipart; the CLI rejects it in JSON
			// mode with httpie's own wording (docs/PARITY.md §3.5).
			return .Unsupported_Body
		}
	}

	buffer := buffer_make(req.allocator, 64)
	defer buffer_destroy(&buffer)

	if !buffer_append_string(&buffer, "{") {
		return .Out_Of_Memory
	}
	for item, i in req.items {
		if i > 0 && !buffer_append_string(&buffer, ", ") {
			return .Out_Of_Memory
		}
		if !json_escape_into(&buffer, item.name) || !buffer_append_string(&buffer, ": ") {
			return .Out_Of_Memory
		}
		switch item.kind {
		case .String:
			if !json_escape_into(&buffer, item.value) {
				return .Out_Of_Memory
			}
		case .Raw_JSON:
			if !buffer_append_string(&buffer, item.value) {
				return .Out_Of_Memory
			}
		case .File:
			return .Unsupported_Body
		}
	}
	if !buffer_append_string(&buffer, "}") {
		return .Out_Of_Memory
	}

	// buffer_owned takes the bytes out; the deferred destroy then frees the
	// (now empty) array and not the body.
	body := buffer_owned(&buffer)
	if !clone_into(&req.body_content_type, JSON_CONTENT_TYPE, req.allocator) {
		delete(body, req.allocator)
		return .Out_Of_Memory
	}
	delete(req.body, req.allocator)
	req.body = body
	return .None
}

// body_encode_form serialises the items as an application/x-www-form-urlencoded
// body. httpie (through requests) encodes both names and values with
// quote_plus and no extra safe characters.
//
// requests encodes the pair's text first — `_encode_params` calls
// `.encode("utf-8")` on the name and then on the value (models.py:171-186) — so
// a byte that is not valid UTF-8 raises there, at its index in the name or in
// the value. The check runs per item, name before value, exactly as that loop
// does.
body_encode_form :: proc(req: ^Request) -> Error {
	for item in req.items {
		if item.kind == .File {
			// A file upload implies multipart (docs/PARITY.md §1.2).
			return .Unsupported_Body
		}
	}

	buffer := buffer_make(req.allocator, 64)
	for item, i in req.items {
		if i > 0 && !buffer_append_string(&buffer, "&") {
			buffer_destroy(&buffer)
			return .Out_Of_Memory
		}
		if err := request_encode_check(req, item.name, .Utf8); err != .None {
			buffer_destroy(&buffer)
			return err
		}
		if err := request_encode_check_lone(req, item.value, item.lone, .Utf8); err != .None {
			buffer_destroy(&buffer)
			return err
		}
		if !url_encode_into(&buffer, item.name) ||
		   !buffer_append_byte(&buffer, '=') ||
		   !url_encode_into(&buffer, item.value) {
			buffer_destroy(&buffer)
			return .Out_Of_Memory
		}
	}
	return body_set(req, &buffer, FORM_CONTENT_TYPE)
}

// body_encode_multipart serialises the items as multipart/form-data with the
// part framing urllib3 produces: a CRLF after the boundary line and after each
// part, `name="…"` escaped per format_multipart_header_param, and a
// `--boundary--\r\n` terminator.
//
// It also assigns the request's Content-Type, because that value is built from
// the CLI's own Content-Type item (multipart_content_type) and the reference
// assigns it into the header dict it has already merged the session and the
// items into — so it takes the place of whichever entry carried the name, if
// any (client.py:353-358).
body_encode_multipart :: proc(req: ^Request) -> Error {
	if err := multipart_boundary(req); err != .None {
		return err
	}

	buffer := buffer_make(req.allocator, 256)
	for item in req.items {
		part_err := Error.None
		switch item.kind {
		case .File:
			part_err = multipart_write_file_part(&buffer, req, item)
		case .String, .Raw_JSON:
			part_err = multipart_write_field_part(&buffer, req, item)
		}
		if part_err != .None {
			buffer_destroy(&buffer)
			return part_err
		}
	}

	if !buffer_append_string(&buffer, "--") ||
	   !buffer_append_string(&buffer, req.boundary) ||
	   !buffer_append_string(&buffer, "--\r\n") {
		buffer_destroy(&buffer)
		return .Out_Of_Memory
	}

	content_type, content_type_err := multipart_content_type(req)
	if content_type_err != .None {
		buffer_destroy(&buffer)
		return content_type_err
	}
	defer delete(content_type, req.allocator)

	if err := request_assign_header(req, "Content-Type", content_type); err != .None {
		buffer_destroy(&buffer)
		return err
	}
	return body_set(req, &buffer, content_type)
}

// multipart_content_type is the Content-Type the multipart branch assigns
// (uploads.py:230-249):
//
//   - the CLI's own Content-Type item (`args.headers.get('Content-Type')`),
//     stripped of its surrounding whitespace by the same argument-less
//     `str.strip()` every header value gets (header_value_strip; uploads.py:241
//     calls it on this one), with `; boundary=<value>`
//     appended unless the item already mentions a boundary — in which case the
//     item's value is kept verbatim, boundary included;
//   - the encoder's own `multipart/form-data; boundary=<value>` when the
//     command line carried no such item (or carried it without a value: an
//     empty string is falsy in the reference's test).
//
// The caller owns the result.
multipart_content_type :: proc(req: ^Request) -> (string, Error) {
	base := req.content_type_item
	if base == "" {
		return multipart_content_type_with_boundary(MULTIPART_MEDIA_TYPE, req)
	}
	trimmed := header_value_strip(base)
	if strings.contains(trimmed, "boundary=") {
		value, clone_err := strings.clone(trimmed, req.allocator)
		if clone_err != .None {
			return "", .Out_Of_Memory
		}
		return value, .None
	}
	return multipart_content_type_with_boundary(trimmed, req)
}

// multipart_content_type_with_boundary appends the boundary parameter to
// `media_type`.
multipart_content_type_with_boundary :: proc(media_type: string, req: ^Request) -> (string, Error) {
	value, concat_err := strings.concatenate({media_type, MULTIPART_BOUNDARY_PARAMETER, req.boundary}, req.allocator)
	if concat_err != .None {
		return "", .Out_Of_Memory
	}
	return value, .None
}

// multipart_write_field_part writes one `name=value` part.
multipart_write_field_part :: proc(buffer: ^Buffer, req: ^Request, item: Data_Item) -> Error {
	if !multipart_write_boundary(buffer, req) ||
	   !multipart_write_disposition(buffer, item.name, "", req.allocator) {
		return .Out_Of_Memory
	}
	// The part's own head ends where requests' RequestField.render_headers ends:
	// one CRLF closes the Content-Disposition line, one closes the head.
	if !buffer_append_string(buffer, "\r\n") {
		return .Out_Of_Memory
	}
	// A scalar `name:=json` keeps its JSON spelling verbatim; the CLI rejects
	// non-scalar JSON for --form/--multipart before it gets here.
	if !buffer_append_string(buffer, item.value) || !buffer_append_string(buffer, "\r\n") {
		return .Out_Of_Memory
	}
	return .None
}

// multipart_write_file_part writes one `name@file` upload part: the file's
// bytes, the Content-Type the CLI gave the item, and the filename
// part-parameter. An empty type means the CLI guessed nothing, and then the
// part carries no Content-Type line at all: `requests_toolbelt` hands the
// field's type to `RequestField.make_multipart(content_type=None)` and
// `render_headers` skips a falsy header value, so the line is simply absent
// (urllib3/fields.py:326-339, docs/PARITY.md §3.1). Guessing does not happen
// here — `http` does not import `cli`, and the reference guesses in its CLI
// (requestitems.py:153-161).
multipart_write_file_part :: proc(buffer: ^Buffer, req: ^Request, item: Data_Item) -> Error {
	contents, read_err := os.read_entire_file_from_path(item.value, req.allocator)
	if read_err != nil {
		return .File_Read_Failed
	}
	// Function-scoped on purpose: `defer` runs when its *block* ends, so the
	// tempting `if len(contents) > 0 { defer delete(...) }` would free the
	// bytes before they are appended below. Deleting an empty slice is a no-op.
	defer delete(contents, req.allocator)

	filename := item.filename
	if filename == "" {
		filename = filename_of(item.value)
	}
	mime := item.mime

	if !multipart_write_boundary(buffer, req) ||
	   !multipart_write_disposition(buffer, item.name, filename, req.allocator) {
		return .Out_Of_Memory
	}
	if mime != "" &&
	   (!buffer_append_string(buffer, "Content-Type: ") ||
	    !buffer_append_string(buffer, mime) ||
	    !buffer_append_string(buffer, "\r\n")) {
		return .Out_Of_Memory
	}
	if !buffer_append_string(buffer, "\r\n") || !buffer_append(buffer, contents) ||
	   !buffer_append_string(buffer, "\r\n") {
		return .Out_Of_Memory
	}
	return .None
}

multipart_write_boundary :: proc(buffer: ^Buffer, req: ^Request) -> bool {
	return buffer_append_string(buffer, "--") &&
	       buffer_append_string(buffer, req.boundary) &&
	       buffer_append_string(buffer, "\r\n")
}

// multipart_write_disposition writes the Content-Disposition line. The name and
// the filename go through urllib3's escaping (CR, LF and `"` become %0D, %0A
// and %22) so a value can never end the header early.
multipart_write_disposition :: proc(
	buffer: ^Buffer,
	name: string,
	filename: string,
	allocator: mem.Allocator,
) -> bool {
	escaped_name := multipart_escape_param(name, allocator)
	defer delete(escaped_name, allocator)

	if !buffer_append_string(buffer, "Content-Disposition: form-data; name=\"") ||
	   !buffer_append_string(buffer, escaped_name) ||
	   !buffer_append_string(buffer, "\"") {
		return false
	}
	if filename != "" {
		escaped_filename := multipart_escape_param(filename, allocator)
		defer delete(escaped_filename, allocator)
		if !buffer_append_string(buffer, "; filename=\"") ||
		   !buffer_append_string(buffer, escaped_filename) ||
		   !buffer_append_string(buffer, "\"") {
			return false
		}
	}
	return buffer_append_string(buffer, "\r\n")
}

// multipart_escape_param is urllib3's format_multipart_header_param. Byte-wise
// on purpose: the translation is a byte translation, not a rune one.
multipart_escape_param :: proc(value: string, allocator: mem.Allocator) -> string {
	buffer := buffer_make(allocator, len(value) + 8)
	for index in 0 ..< len(value) {
		switch value[index] {
		case '\n':
			buffer_append_string(&buffer, "%0A")
		case '\r':
			buffer_append_string(&buffer, "%0D")
		case '"':
			buffer_append_string(&buffer, "%22")
		case:
			buffer_append_byte(&buffer, value[index])
		}
	}
	return string(buffer_owned(&buffer))
}

// multipart_boundary keeps the caller's --boundary, or generates the 32 hex
// digits requests uses (uuid4().hex), and leaves it in req.boundary.
multipart_boundary :: proc(req: ^Request) -> Error {
	if req.boundary != "" {
		return .None
	}
	buffer := buffer_make(req.allocator, 32)
	for _ in 0 ..< 2 {
		value := rand.uint64()
		for shift in 0 ..< 8 {
			if !buffer_append_hex(&buffer, u8(value >> u64(shift * 8))) {
				buffer_destroy(&buffer)
				return .Out_Of_Memory
			}
		}
	}
	req.boundary = string(buffer_owned(&buffer))
	return .None
}

// filename_of is the multipart filename httpie infers: the leaf of the path,
// with both separators understood (a Windows-style path arrives as one argv
// item). The result borrows from `path`.
filename_of :: proc(path: string) -> string {
	leaf := path
	if index := strings.last_index_any(leaf, "/\\"); index >= 0 {
		leaf = leaf[index + 1:]
	}
	return leaf
}

// json_escape_into writes `s` as a JSON string, quotes included, with Python's
// json.dumps(ensure_ascii=True) spelling: lowercase \uXXXX escapes for
// everything outside printable ASCII, surrogate pairs above the BMP, and
// `\udcXX` for bytes that are not valid UTF-8 (Python's surrogateescape).
json_escape_into :: proc(buffer: ^Buffer, s: string) -> bool {
	if !buffer_append_string(buffer, "\"") {
		return false
	}

	i := 0
	for i < len(s) {
		byte := s[i]
		switch {
		case byte == '"':
			if !buffer_append_string(buffer, "\\\"") {
				return false
			}
			i += 1
		case byte == '\\':
			if !buffer_append_string(buffer, "\\\\") {
				return false
			}
			i += 1
		case byte == '\n':
			if !buffer_append_string(buffer, "\\n") {
				return false
			}
			i += 1
		case byte == '\r':
			if !buffer_append_string(buffer, "\\r") {
				return false
			}
			i += 1
		case byte == '\t':
			if !buffer_append_string(buffer, "\\t") {
				return false
			}
			i += 1
		case byte == '\x08':
			if !buffer_append_string(buffer, "\\b") {
				return false
			}
			i += 1
		case byte == '\x0c':
			if !buffer_append_string(buffer, "\\f") {
				return false
			}
			i += 1
		case byte < 0x20:
			if !write_u16_escape(buffer, u16(byte)) {
				return false
			}
			i += 1
		case byte < 0x80:
			if !buffer_append_byte(buffer, byte) {
				return false
			}
			i += 1
		case:
			codepoint, size := decode_utf8(s[i:])
			if size == 0 {
				// Not valid UTF-8: escape the single byte the way Python's
				// surrogateescape does, so no raw byte escapes the encoder.
				if !write_u16_escape(buffer, u16(0xdc00) | u16(byte)) {
					return false
				}
				i += 1
			} else {
				if !write_codepoint_escape(buffer, codepoint) {
					return false
				}
				i += size
			}
		}
	}

	return buffer_append_string(buffer, "\"")
}

// write_codepoint_escape writes \uXXXX, or the surrogate pair for a codepoint
// above the basic multilingual plane.
write_codepoint_escape :: proc(buffer: ^Buffer, codepoint: u32) -> bool {
	if codepoint < 0x10000 {
		return write_u16_escape(buffer, u16(codepoint))
	}
	adjusted := codepoint - 0x10000
	high := u16(0xd800) + u16(adjusted >> 10)
	low := u16(0xdc00) + u16(adjusted & 0x3ff)
	return write_u16_escape(buffer, high) && write_u16_escape(buffer, low)
}

write_u16_escape :: proc(buffer: ^Buffer, value: u16) -> bool {
	return buffer_append_string(buffer, "\\u") &&
	       buffer_append_hex(buffer, u8(value >> 8)) &&
	       buffer_append_hex(buffer, u8(value & 0xff))
}

// buffer_append_hex writes one byte as two lowercase hex digits, Python's
// json.dumps spelling.
buffer_append_hex :: proc(buffer: ^Buffer, byte: u8) -> bool {
	digits := "0123456789abcdef"
	return buffer_append_byte(buffer, digits[byte >> 4]) &&
	       buffer_append_byte(buffer, digits[byte & 0xf])
}

// decode_utf8 decodes one codepoint. A size of 0 means the input is not valid
// UTF-8 at this position.
decode_utf8 :: proc(s: string) -> (codepoint: u32, size: int) {
	first := s[0]
	switch {
	case first < 0x80:
		return u32(first), 1
	case first & 0xe0 == 0xc0:
		if len(s) < 2 || s[1] & 0xc0 != 0x80 {
			return 0, 0
		}
		value := u32(first & 0x1f) << 6 | u32(s[1] & 0x3f)
		if value < 0x80 {
			return 0, 0 // overlong encoding
		}
		return value, 2
	case first & 0xf0 == 0xe0:
		if len(s) < 3 || s[1] & 0xc0 != 0x80 || s[2] & 0xc0 != 0x80 {
			return 0, 0
		}
		value := u32(first & 0x0f) << 12 | u32(s[1] & 0x3f) << 6 | u32(s[2] & 0x3f)
		if value < 0x800 {
			return 0, 0
		}
		return value, 3
	case first & 0xf8 == 0xf0:
		if len(s) < 4 || s[1] & 0xc0 != 0x80 || s[2] & 0xc0 != 0x80 || s[3] & 0xc0 != 0x80 {
			return 0, 0
		}
		value := u32(first & 0x07) << 18 | u32(s[1] & 0x3f) << 12 | u32(s[2] & 0x3f) << 6 | u32(s[3] & 0x3f)
		if value < 0x10000 || value > 0x10ffff {
			return 0, 0
		}
		return value, 4
	}
	return 0, 0
}

// url_encode_into writes Python's quote_plus spelling of `s`: everything
// outside `A-Za-z0-9_.-~` is percent-encoded with uppercase hex, and a space
// becomes `+`. Byte-wise on purpose: quote_plus escapes bytes, not codepoints.
url_encode_into :: proc(buffer: ^Buffer, s: string) -> bool {
	digits := "0123456789ABCDEF"
	for index in 0 ..< len(s) {
		byte := s[index]
		switch {
		case byte >= 'A' && byte <= 'Z',
		     byte >= 'a' && byte <= 'z',
		     byte >= '0' && byte <= '9',
		     byte == '_', byte == '.', byte == '-', byte == '~':
			if !buffer_append_byte(buffer, byte) {
				return false
			}
		case byte == ' ':
			if !buffer_append_byte(buffer, '+') {
				return false
			}
		case:
			if !buffer_append_byte(buffer, '%') ||
			   !buffer_append_byte(buffer, digits[byte >> 4]) ||
			   !buffer_append_byte(buffer, digits[byte & 0xf]) {
				return false
			}
		}
	}
	return true
}
