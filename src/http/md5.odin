// MD5 (RFC 1321): the hash the Digest handshake needs and the only one the port
// computes itself.
//
// It exists because of *where* the handshake happens. requests computes the
// answer to a Digest challenge in Python (`requests.auth.HTTPDigestAuth`,
// via `hashlib`), and the port used to leave that to libcurl — which can only
// replay a request it can rewind, and a `--chunked` upload or a HEAD that
// carries bytes is not one of those (docs/PARITY.md §4.1, t_c182381a). Driving
// the handshake here means hashing here, so the package carries the one hash
// function the challenge's `algorithm` can name today: MD5, the fixture's
// (tests/parity/server.py, `/auth/digest`).
//
// The functions are package-private and allocation-free: a digest is written
// into a caller-owned array, which is what lets the answer be assembled on the
// stack (digest.odin).
package http

import "core:math/bits"

MD5_DIGEST_SIZE :: 16
MD5_HEX_SIZE :: MD5_DIGEST_SIZE * 2
MD5_BLOCK_SIZE :: 64

// MD5 is a streaming MD5 state. `length` counts the bytes fed in (the padding
// included), `filled` how much of `buffer` the next block starts with.
MD5 :: struct {
	state:  [4]u32,
	length: u64,
	buffer: [MD5_BLOCK_SIZE]u8,
	filled: int,
}

// MD5_SHIFTS is the per-round rotation amount, RFC 1321's `s` table.
@(private = "file")
MD5_SHIFTS := [64]u32{
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

// MD5_K is `floor(abs(sin(i + 1)) * 2**32)` for i in 0..<64, the sine table of
// the standard (RFC 1321 §3.4).
@(private = "file")
MD5_K := [64]u32{
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
	0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
	0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
	0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
	0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
	0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
	0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
	0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
	0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

md5_init :: proc(ctx: ^MD5) {
	ctx.state = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476}
	ctx.length = 0
	ctx.filled = 0
}

md5_update :: proc(ctx: ^MD5, data: []u8) {
	rest := data
	for len(rest) > 0 {
		take := min(MD5_BLOCK_SIZE - ctx.filled, len(rest))
		copy(ctx.buffer[ctx.filled:], rest[:take])
		ctx.filled += take
		ctx.length += u64(take)
		rest = rest[take:]
		if ctx.filled == MD5_BLOCK_SIZE {
			md5_block(ctx, ctx.buffer[:])
			ctx.filled = 0
		}
	}
}

// md5_final appends the padding and the little-endian bit length and writes the
// digest into `out`. The state is left unuseable: the caller has the answer.
md5_final :: proc(ctx: ^MD5, out: ^[MD5_DIGEST_SIZE]u8) {
	bit_length := ctx.length * 8

	padding: [MD5_BLOCK_SIZE]u8
	padding[0] = 0x80
	// Everything up to the 8 length bytes that close the last block: 56 bytes
	// into a block when there is room for them, a whole extra block when the
	// 0x80 alone did not leave room.
	pad_length := ctx.filled < 56 ? 56 - ctx.filled : 120 - ctx.filled
	md5_update(ctx, padding[:pad_length])

	length_bytes: [8]u8
	for i in 0 ..< 8 {
		length_bytes[i] = u8(bit_length >> u64(i * 8))
	}
	md5_update(ctx, length_bytes[:])

	for word in 0 ..< 4 {
		for byte in 0 ..< 4 {
			out[word * 4 + byte] = u8(ctx.state[word] >> u32(byte * 8))
		}
	}
}

@(private = "file")
md5_block :: proc(ctx: ^MD5, block: []u8) {
	message: [16]u32
	for i in 0 ..< 16 {
		message[i] = u32(block[i * 4]) |
		             u32(block[i * 4 + 1]) << 8 |
		             u32(block[i * 4 + 2]) << 16 |
		             u32(block[i * 4 + 3]) << 24
	}

	a := ctx.state[0]
	b := ctx.state[1]
	c := ctx.state[2]
	d := ctx.state[3]
	for i in 0 ..< 64 {
		f: u32
		g: int
		switch {
		case i < 16:
			f = (b & c) | (~b & d)
			g = i
		case i < 32:
			f = (d & b) | (~d & c)
			g = (5 * i + 1) % 16
		case i < 48:
			f = b ~ c ~ d
			g = (3 * i + 5) % 16
		case:
			f = c ~ (b | ~d)
			g = (7 * i) % 16
		}
		f += a + MD5_K[i] + message[g]
		a = d
		d = c
		c = b
		b += bits.rotate_left32(f, int(MD5_SHIFTS[i]))
	}
	ctx.state[0] += a
	ctx.state[1] += b
	ctx.state[2] += c
	ctx.state[3] += d
}

// md5_hex_join hashes the concatenation of `parts` and writes the digest's
// lowercase hex spelling, 32 characters, into `out` — the spelling every Digest
// field of the header is made of (`build_digest_header`'s `hash_utf8`, which is
// `hashlib.md5(...).hexdigest()`).
md5_hex_join :: proc(parts: []string, out: ^[MD5_DIGEST_SIZE * 2]u8) {
	ctx: MD5
	md5_init(&ctx)
	for part in parts {
		md5_update(&ctx, transmute([]u8)part)
	}
	digest: [MD5_DIGEST_SIZE]u8
	md5_final(&ctx, &digest)
	digits := "0123456789abcdef"
	for byte, i in digest {
		out[i * 2] = digits[byte >> 4]
		out[i * 2 + 1] = digits[byte & 0x0f]
	}
}
