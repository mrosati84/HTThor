// The reporting shapes the M5 sweep introduced: when a copy cannot be made it
// arrives as a failure — never as the empty string, which is a legitimate HTTP
// value — and whatever was cloned before it is released on the way out
// (docs/rating/HTThor-remediation-backlog.md, M5).
package tests

import "core:mem"
import "core:testing"

import "src:cli"
import "src:format"

// Owned_Budget is a backing allocator plus the number of requests it will still
// serve: past that it refuses. It is how a call site that clones several values
// in a row is made to fail on the *second* one, which is the case a
// release-what-you-cloned path exists for.
@(private)
Owned_Budget :: struct {
	backing: mem.Allocator,
	left:    int,
	taken:   int,
}

@(private)
owned_budget_alloc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	budget := cast(^Owned_Budget)allocator_data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		if budget.left <= 0 {
			return nil, .Out_Of_Memory
		}
		budget.left -= 1
		budget.taken += 1
	}
	return budget.backing.procedure(
		budget.backing.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		location,
	)
}

@(test)
test_env_info_clone_releases_a_failed_copy :: proc(t: ^testing.T) {
	backing := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, backing, backing)
	defer mem.tracking_allocator_destroy(&track)

	env := cli.Env_Info {
		vars = []cli.Env_Var{{name = "A", value = "1"}, {name = "B", value = "2"}},
	}
	// The array and the first pair fit; the second pair is the copy that fails.
	budget := Owned_Budget {
		backing = mem.tracking_allocator(&track),
		left    = 3,
	}
	cloned, ok := cli.env_info_clone(env, mem.Allocator{procedure = owned_budget_alloc, data = &budget})

	testing.expect(t, !ok, "a refused copy is not a value")
	testing.expect_value(t, len(cloned.vars), 0)
	testing.expect_value(t, budget.taken, 3)
	// The budget's requests have to reach the tracker itself, or the leak check
	// below would pass on an empty map.
	testing.expect(t, track.total_allocation_count >= 3, "the copies had to be tracked")
	// The array and the pair cloned before the refusal have to be gone: an
	// Env_Info that leaked them would leak once per parse.
	expect_no_leaks(t, &track)
}

@(test)
test_value_to_form_string_reports_a_failed_copy :: proc(t: ^testing.T) {
	// `-f a:=True` sends the spelling the reference prints, so the printable
	// copy is a value the request carries.
	boolean: format.Value = true
	printed, ok := format.value_to_form_string(boolean, context.allocator)
	testing.expect(t, ok, "the printable copy had to be made")
	text, _ := format.string_parts(printed)
	testing.expect_value(t, text, "True")
	format.value_destroy(&printed, context.allocator)

	// A refusal is reported instead: an empty form value is legitimate, so
	// absorbing it would send a different request.
	requests := 0
	refused, refused_ok := format.value_to_form_string(boolean, owned_failing_allocator(&requests))
	testing.expect(t, !refused_ok, "a refused copy is not a value")
	testing.expect(t, !format.value_is_string(refused), "a failed copy must not answer a string value")
	testing.expect(t, requests > 0, "the copy had to reach the allocator")
}
