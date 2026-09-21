// The allocator-explicit string helpers (backlog M5). `clone_or_oom` is the
// (value, bool) shape the sweep uses wherever a caller can report a failure: a
// copy that could not be made must arrive as a *failure*, never as the empty
// string, because "" is a legitimate HTTP value (a header with no value, a
// cookie with no path, an option at its default).
package tests

import "core:mem"
import "core:testing"

import "src:http"

// owned_failing_alloc refuses every request — the only way to watch a call site
// whose clone cannot be made. Its `allocator_data` is the caller's own counter,
// so the number of requests it saw can be asserted without shared state (the
// runner threads the tests).
@(private)
owned_failing_alloc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	if allocator_data != nil {
		requests := cast(^int)allocator_data
		requests^ += 1
	}
	return nil, .Out_Of_Memory
}

// owned_failing_allocator is that procedure as a mem.Allocator, counting its
// requests through `requests`.
@(private)
owned_failing_allocator :: proc(requests: ^int) -> mem.Allocator {
	return mem.Allocator{procedure = owned_failing_alloc, data = requests}
}

@(test)
test_clone_or_oom_takes_an_owned_copy :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// `source` is a local so that a clone that borrowed it would be visible: the
	// helper's whole point is that the result outlives the argument.
	source := "X-Test: value"
	clone, ok := http.clone_or_oom(source, allocator)
	testing.expect(t, ok, "the copy had to be made")
	testing.expect_value(t, clone, source)
	testing.expect(t, raw_data(clone) != raw_data(source), "the clone is its own memory")

	delete(clone, allocator)
	expect_no_leaks(t, &track)
}

@(test)
test_clone_or_oom_reports_a_failed_copy :: proc(t: ^testing.T) {
	// A refused allocation is false — not an empty value a request would then
	// carry as if the user had asked for it.
	requests := 0
	clone, ok := http.clone_or_oom("X-Test: value", owned_failing_allocator(&requests))
	testing.expect(t, !ok, "a refused allocation is not a value")
	testing.expect_value(t, clone, "")
	testing.expect(t, raw_data(clone) == nil, "a failed copy must not allocate")
	testing.expect(t, requests > 0, "the copy had to reach the allocator")
}

@(test)
test_clone_or_oom_of_an_empty_value_is_a_success :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	clone, ok := http.clone_or_oom("", allocator)
	testing.expect(t, ok, "an empty value is not a failed copy")
	testing.expect_value(t, clone, "")

	// The empty string needs no memory, so it succeeds even for an allocator
	// that refuses everything — and never asks it: a converted call site
	// holding an unset option must not report out-of-memory for it.
	requests := 0
	clone, ok = http.clone_or_oom("", owned_failing_allocator(&requests))
	testing.expect(t, ok, "an empty value is not a failed copy")
	testing.expect_value(t, clone, "")
	testing.expect_value(t, requests, 0)
	expect_no_leaks(t, &track)
}
