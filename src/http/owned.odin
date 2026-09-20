// Allocator-explicit container helpers.
//
// Why these exist: `append` on a *plain* slice (and on a nil slice) allocates
// through `context.allocator`, which docs/ARCHITECTURE.md §4 forbids anywhere
// under src/ — the allocator is read once, in main, and passed down. `[dynamic]T`
// keeps its own allocator, so the places that can use one do; the Request's
// frozen `[]Header` / `[]Query_Param` / `[]Data_Item` fields cannot, so growing
// them goes through slice_push.
package http

import "core:mem"
import "core:strconv"
import "core:strings"

// slice_push appends `value` to `list`, growing it by one element with
// `allocator`. It returns false (leaving `list` unchanged) when the allocation
// fails.
//
// Why one element at a time: an Odin *slice* carries no capacity, so there is
// no way to see whether the current backing store has spare room, and the
// Request/Response shapes (`[]Header`, `[]Query_Param`, `[]Data_Item`) are
// frozen by docs/ARCHITECTURE.md §7. The lists that grow this way are the
// per-request header, query, item and redirect-hop lists — tens of entries,
// never bulk data — so the quadratic copy cost is bounded and irrelevant here.
// Bulk bytes go through Buffer, which is a [dynamic]u8 and grows amortised.
slice_push :: proc(list: ^[]$E, value: E, allocator: mem.Allocator) -> bool {
	grown, err := make([]E, len(list^) + 1, allocator)
	if err != .None {
		return false
	}
	copy(grown, list^)
	grown[len(grown) - 1] = value
	if len(list^) > 0 {
		delete(list^, allocator)
	}
	list^ = grown
	return true
}

// clone_into takes an owned copy of `value` and stores it in `field`, releasing
// whatever `field` held before. False means the allocation failed.
clone_into :: proc(field: ^string, value: string, allocator: mem.Allocator) -> bool {
	clone, err := strings.clone(value, allocator)
	if err != nil {
		return false
	}
	delete(field^, allocator)
	field^ = clone
	return true
}

// Buffer is a growable byte buffer whose memory has an explicit owner: a
// [dynamic]u8 carries its allocator, so appends never reach for the runtime's.
Buffer :: struct {
	allocator: mem.Allocator,
	data:      [dynamic]u8,
}

buffer_make :: proc(allocator: mem.Allocator, capacity := 0) -> Buffer {
	return Buffer {
		allocator = allocator,
		data      = make([dynamic]u8, 0, capacity, allocator),
	}
}

buffer_append :: proc(buffer: ^Buffer, bytes: []byte) -> bool {
	if len(bytes) == 0 {
		return true
	}
	_, err := append(&buffer.data, ..bytes)
	return err == .None
}

buffer_append_string :: proc(buffer: ^Buffer, s: string) -> bool {
	if len(s) == 0 {
		return true
	}
	// `append` on a [dynamic]u8 has a string form; it copies the bytes and uses
	// the array's own allocator.
	_, err := append(&buffer.data, s)
	return err == .None
}

buffer_append_byte :: proc(buffer: ^Buffer, byte: u8) -> bool {
	_, err := append(&buffer.data, byte)
	return err == .None
}

// buffer_append_int writes a base-10 integer.
buffer_append_int :: proc(buffer: ^Buffer, value: int) -> bool {
	number: [24]u8
	return buffer_append_string(buffer, strconv.write_int(number[:], i64(value), 10))
}

// buffer_drop removes the first `count` bytes from `buffer`, keeping the rest.
// The bytes are moved rather than reallocated: a header block is a few hundred
// bytes and stays in its buffer.
buffer_drop :: proc(buffer: ^Buffer, count: int) {
	if count <= 0 {
		return
	}
	remaining := len(buffer.data) - count
	if remaining < 0 {
		remaining = 0
	}
	for i in 0 ..< remaining {
		buffer.data[i] = buffer.data[count + i]
	}
	// Shrinking cannot fail, so the result is dropped on purpose.
	resize(&buffer.data, remaining)
}

// buffer_clear empties the buffer but keeps its allocation, so a reused buffer
// does not reallocate.
buffer_clear :: proc(buffer: ^Buffer) {
	resize(&buffer.data, 0)
}

// buffer_owned hands the bytes to the caller, who frees them with plain
// `delete(body, buffer.allocator)`. The buffer is *dead* afterwards: its data
// slot is nil, and destroying it is a no-op.
buffer_owned :: proc(buffer: ^Buffer) -> []byte {
	bytes := buffer.data[:]
	buffer.data = nil
	return bytes
}

buffer_destroy :: proc(buffer: ^Buffer) {
	delete(buffer.data)
	buffer^ = {}
}
