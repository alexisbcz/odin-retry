// Package retry_tests holds the unit tests for retry. Run them with `odin test tests`.
package retry_tests

import retry ".."
import "core:math/rand"
import "core:mem"
import "core:testing"
import "core:time"

MS :: time.Millisecond

// Recorder is a fake clock that also keeps every sleep, in order.
Recorder :: struct {
	now:    time.Duration,
	sleeps: [dynamic]time.Duration,
}

recorder_init :: proc(r: ^Recorder, allocator := context.allocator) {
	r^ = {}
	r.sleeps = make([dynamic]time.Duration, allocator)
}

recorder_destroy :: proc(r: ^Recorder) {
	delete(r.sleeps)
	r^ = {}
}

recorder_clock :: proc(r: ^Recorder) -> retry.Clock {
	return retry.Clock{now = recorder_now, sleep = recorder_sleep, data = r}
}

recorder_now :: proc(data: rawptr) -> time.Duration {
	return (^Recorder)(data).now
}

recorder_sleep :: proc(data: rawptr, d: time.Duration) {
	r := (^Recorder)(data)
	r.now += d
	append(&r.sleeps, d)
}

// Leak_Check wraps a tracking allocator so a test can assert it freed everything.
Leak_Check :: struct {
	track: mem.Tracking_Allocator,
	t:     ^testing.T,
}

leak_check_begin :: proc(lc: ^Leak_Check, t: ^testing.T) -> mem.Allocator {
	lc.t = t
	mem.tracking_allocator_init(&lc.track, context.allocator)
	return mem.tracking_allocator(&lc.track)
}

leak_check_end :: proc(lc: ^Leak_Check) {
	testing.expectf(lc.t, len(lc.track.allocation_map) == 0, "leaked %d allocations", len(lc.track.allocation_map))
	testing.expectf(lc.t, len(lc.track.bad_free_array) == 0, "%d bad frees", len(lc.track.bad_free_array))
	mem.tracking_allocator_destroy(&lc.track)
}

// take collects up to len(out) delays and returns how many the Backoff produced.
take :: proc(b: ^retry.Backoff, out: []time.Duration) -> int {
	for i in 0 ..< len(out) {
		d, ok := retry.backoff_next(b)
		if !ok {
			return i
		}
		out[i] = d
	}
	return len(out)
}

expect_delays :: proc(t: ^testing.T, policy: retry.Policy, want: []time.Duration, loc := #caller_location) {
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, policy), nil, loc)
	got: [64]time.Duration
	n := take(&b, got[:len(want)])
	testing.expect_value(t, n, len(want), loc)
	for i in 0 ..< n {
		testing.expectf(t, got[i] == want[i], "delay %d: got %v, want %v", i, got[i], want[i], loc = loc)
	}
}

seeded :: proc(state: ^rand.Default_Random_State, seed: u64) -> rand.Generator {
	state^ = rand.create(seed)
	return rand.default_random_generator(state)
}

perr :: proc(e: retry.Policy_Error) -> retry.Error {
	return e
}

rerr :: proc(e: retry.Retry_Error) -> retry.Error {
	return e
}
