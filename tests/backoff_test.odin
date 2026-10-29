package retry_tests

import retry ".."
import "core:math/rand"
import "core:testing"
import "core:time"

SAMPLES :: 10_000

@(test)
test_constant_sequence_is_exact :: proc(t: ^testing.T) {
	expect_delays(t, retry.constant(200 * MS, 0), {200 * MS, 200 * MS, 200 * MS, 200 * MS})
}

@(test)
test_linear_sequence_is_exact :: proc(t: ^testing.T) {
	expect_delays(t, retry.linear(100 * MS, 50 * MS, 0, 0), {100 * MS, 150 * MS, 200 * MS, 250 * MS, 300 * MS})
}

@(test)
test_exponential_sequence_is_exact :: proc(t: ^testing.T) {
	p := retry.exponential(initial = 100 * MS, max = 0, max_attempts = 0)
	p.jitter = .None
	expect_delays(t, p, {100 * MS, 200 * MS, 400 * MS, 800 * MS, 1600 * MS, 3200 * MS})
}

@(test)
test_exponential_fractional_multiplier :: proc(t: ^testing.T) {
	p := retry.exponential(initial = 1000 * MS, max = 0, multiplier = 1.5, max_attempts = 0)
	p.jitter = .None
	expect_delays(t, p, {1000 * MS, 1500 * MS, 2250 * MS, 3375 * MS})
}

@(test)
test_exponential_is_capped_at_max :: proc(t: ^testing.T) {
	p := retry.exponential(initial = 100 * MS, max = 500 * MS, max_attempts = 0)
	p.jitter = .None
	expect_delays(t, p, {100 * MS, 200 * MS, 400 * MS, 500 * MS, 500 * MS, 500 * MS})
}

@(test)
test_linear_is_capped_at_max :: proc(t: ^testing.T) {
	expect_delays(t, retry.linear(100 * MS, 100 * MS, 250 * MS, 0), {100 * MS, 200 * MS, 250 * MS, 250 * MS})
}

@(test)
test_multiplier_and_increment_combine :: proc(t: ^testing.T) {
	p := retry.Policy{initial = 10 * MS, multiplier = 2, increment = 5 * MS}
	expect_delays(t, p, {10 * MS, 25 * MS, 55 * MS, 115 * MS})
}

@(test)
test_initial_equal_to_max_stays_flat :: proc(t: ^testing.T) {
	p := retry.exponential(initial = time.Second, max = time.Second, max_attempts = 0)
	p.jitter = .None
	expect_delays(t, p, {time.Second, time.Second, time.Second})
}

@(test)
test_zero_initial_yields_zero_delays :: proc(t: ^testing.T) {
	p := retry.exponential(initial = 0, max_attempts = 0)
	p.jitter = .None
	expect_delays(t, p, {0, 0, 0})
}

@(test)
test_uncapped_growth_saturates_without_overflow :: proc(t: ^testing.T) {
	p := retry.exponential(initial = time.Second, max = 0, multiplier = 10, max_attempts = 0)
	p.jitter = .None
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p), nil)
	prev: time.Duration
	for i in 0 ..< 200 {
		d, ok := retry.backoff_next(&b)
		testing.expect(t, ok)
		testing.expectf(t, d >= prev, "delay %d went down: %v < %v", i, d, prev)
		prev = d
	}
	testing.expect_value(t, prev, time.Duration(max(i64)))
}

@(test)
test_uncapped_increment_saturates_without_overflow :: proc(t: ^testing.T) {
	p := retry.linear(0, time.Duration(max(i64) / 3), 0, 0)
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p), nil)
	prev: time.Duration
	for _ in 0 ..< 10 {
		d, ok := retry.backoff_next(&b)
		testing.expect(t, ok)
		testing.expect(t, d >= prev)
		prev = d
	}
	testing.expect_value(t, prev, time.Duration(max(i64)))
}

// jitter_policy is an exponential policy that hits its 1 s cap after a few steps.
jitter_policy :: proc(j: retry.Jitter) -> retry.Policy {
	p := retry.exponential(initial = 10 * MS, max = time.Second, max_attempts = 0)
	p.jitter = j
	return p
}

@(test)
test_full_jitter_stays_within_bounds :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, jitter_policy(.Full), seeded(&state, 1)), nil)
	base := 10 * MS
	for i in 0 ..< SAMPLES {
		d, ok := retry.backoff_next(&b)
		testing.expect(t, ok)
		if d < 0 || d > base {
			testing.expectf(t, false, "sample %d: %v outside [0, %v]", i, d, base)
			return
		}
		base = min(base * 2, time.Second)
	}
}

@(test)
test_equal_jitter_stays_within_bounds :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, jitter_policy(.Equal), seeded(&state, 2)), nil)
	base := 10 * MS
	for i in 0 ..< SAMPLES {
		d, ok := retry.backoff_next(&b)
		testing.expect(t, ok)
		if d < base / 2 || d > base {
			testing.expectf(t, false, "sample %d: %v outside [%v, %v]", i, d, base / 2, base)
			return
		}
		base = min(base * 2, time.Second)
	}
}

@(test)
test_decorrelated_jitter_stays_within_bounds :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, jitter_policy(.Decorrelated), seeded(&state, 3)), nil)
	prev := 10 * MS
	for i in 0 ..< SAMPLES {
		d, ok := retry.backoff_next(&b)
		testing.expect(t, ok)
		hi := min(prev * retry.DECORRELATED_FACTOR, time.Second)
		if d < 10 * MS || d > hi {
			testing.expectf(t, false, "sample %d: %v outside [10ms, %v]", i, d, hi)
			return
		}
		prev = d
	}
}

@(test)
test_full_jitter_mean_is_about_half :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.Policy{initial = time.Second, multiplier = 1, jitter = .Full}, seeded(&state, 4)), nil)
	sum: f64
	for _ in 0 ..< SAMPLES {
		d, _ := retry.backoff_next(&b)
		sum += f64(d)
	}
	mean := sum / SAMPLES / f64(time.Second)
	testing.expectf(t, mean > 0.45 && mean < 0.55, "mean %v is far from 0.5", mean)
}

@(test)
test_equal_jitter_mean_is_about_three_quarters :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.Policy{initial = time.Second, multiplier = 1, jitter = .Equal}, seeded(&state, 5)), nil)
	sum: f64
	for _ in 0 ..< SAMPLES {
		d, _ := retry.backoff_next(&b)
		sum += f64(d)
	}
	mean := sum / SAMPLES / f64(time.Second)
	testing.expectf(t, mean > 0.70 && mean < 0.80, "mean %v is far from 0.75", mean)
}

@(test)
test_jitter_varies_between_samples :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.Policy{initial = time.Second, multiplier = 1, jitter = .Full}, seeded(&state, 6)), nil)
	first, _ := retry.backoff_next(&b)
	varied := false
	for _ in 0 ..< 100 {
		d, _ := retry.backoff_next(&b)
		if d != first {
			varied = true
			break
		}
	}
	testing.expect(t, varied, "full jitter returned the same delay 101 times")
}

@(test)
test_decorrelated_respects_cap :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	p := retry.Policy{initial = 400 * MS, max = 500 * MS, multiplier = 1, jitter = .Decorrelated}
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p, seeded(&state, 7)), nil)
	for _ in 0 ..< SAMPLES {
		d, _ := retry.backoff_next(&b)
		if d < 400 * MS || d > 500 * MS {
			testing.expectf(t, false, "%v outside [400ms, 500ms]", d)
			return
		}
	}
}

@(test)
test_decorrelated_with_initial_equal_max_is_flat :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	p := retry.Policy{initial = time.Second, max = time.Second, multiplier = 1, jitter = .Decorrelated}
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p, seeded(&state, 8)), nil)
	for _ in 0 ..< 100 {
		d, _ := retry.backoff_next(&b)
		testing.expect_value(t, d, time.Second)
	}
}

@(test)
test_same_seed_gives_same_sequence :: proc(t: ^testing.T) {
	s1, s2: rand.Default_Random_State
	a, b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&a, jitter_policy(.Full), seeded(&s1, 99)), nil)
	testing.expect_value(t, retry.backoff_init(&b, jitter_policy(.Full), seeded(&s2, 99)), nil)
	for _ in 0 ..< 1000 {
		x, _ := retry.backoff_next(&a)
		y, _ := retry.backoff_next(&b)
		if x != y {
			testing.expectf(t, false, "%v != %v with the same seed", x, y)
			return
		}
	}
}

@(test)
test_different_seeds_give_different_sequences :: proc(t: ^testing.T) {
	s1, s2: rand.Default_Random_State
	a, b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&a, jitter_policy(.Decorrelated), seeded(&s1, 1)), nil)
	testing.expect_value(t, retry.backoff_init(&b, jitter_policy(.Decorrelated), seeded(&s2, 2)), nil)
	same := 0
	for _ in 0 ..< 100 {
		x, _ := retry.backoff_next(&a)
		y, _ := retry.backoff_next(&b)
		if x == y {
			same += 1
		}
	}
	testing.expectf(t, same < 100, "two seeds produced identical sequences")
}

@(test)
test_zero_generator_uses_context_generator :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	context.random_generator = seeded(&state, 11)
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.Policy{initial = time.Second, multiplier = 1, jitter = .Full}), nil)
	for _ in 0 ..< 1000 {
		d, ok := retry.backoff_next(&b)
		testing.expect(t, ok)
		testing.expect(t, d >= 0 && d <= time.Second)
	}
}

@(test)
test_max_attempts_limits_delay_count :: proc(t: ^testing.T) {
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.constant(MS, 4)), nil)
	out: [10]time.Duration
	testing.expect_value(t, take(&b, out[:]), 3)
	testing.expect_value(t, b.stop, retry.Retry_Error.Attempts_Exhausted)
}

@(test)
test_max_attempts_one_yields_no_delay :: proc(t: ^testing.T) {
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.constant(MS, 1)), nil)
	_, ok := retry.backoff_next(&b)
	testing.expect(t, !ok)
	testing.expect_value(t, b.attempt, 0)
}

@(test)
test_zero_max_attempts_is_unlimited :: proc(t: ^testing.T) {
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.constant(MS, 0)), nil)
	out: [1000]time.Duration
	testing.expect_value(t, take(&b, out[:]), 1000)
	testing.expect_value(t, b.stop, retry.Retry_Error.None)
}

@(test)
test_next_stays_false_after_exhaustion :: proc(t: ^testing.T) {
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.constant(MS, 2)), nil)
	_, ok := retry.backoff_next(&b)
	testing.expect(t, ok)
	for _ in 0 ..< 5 {
		_, ok = retry.backoff_next(&b)
		testing.expect(t, !ok)
	}
}

@(test)
test_max_elapsed_stops_before_overshoot :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	clock := retry.fake_clock(&fc)
	p := retry.constant(300 * MS, 0)
	p.max_elapsed = time.Second
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p, {}, clock), nil)
	n := 0
	for {
		d, ok := retry.backoff_next(&b)
		if !ok {
			break
		}
		retry.clock_sleep(clock, d)
		n += 1
	}
	// 300 + 300 + 300 = 900 ms; a fourth delay would end at 1.2 s.
	testing.expect_value(t, n, 3)
	testing.expect_value(t, fc.now, 900 * MS)
	testing.expect_value(t, b.stop, retry.Retry_Error.Elapsed_Exhausted)
}

@(test)
test_max_elapsed_allows_exact_boundary :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	p := retry.constant(500 * MS, 0)
	p.max_elapsed = time.Second
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p, {}, retry.fake_clock(&fc)), nil)
	d, ok := retry.backoff_next(&b)
	testing.expect(t, ok)
	fc.now += d
	d, ok = retry.backoff_next(&b)
	testing.expect(t, ok, "a delay ending exactly at max_elapsed is allowed")
	fc.now += d
	_, ok = retry.backoff_next(&b)
	testing.expect(t, !ok)
}

@(test)
test_max_elapsed_counts_time_spent_outside_sleeps :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	p := retry.constant(100 * MS, 0)
	p.max_elapsed = time.Second
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p, {}, retry.fake_clock(&fc)), nil)
	retry.fake_clock_advance(&fc, 950 * MS)
	_, ok := retry.backoff_next(&b)
	testing.expect(t, !ok)
	testing.expect_value(t, fc.sleeps, 0)
}

@(test)
test_reset_restarts_sequence :: proc(t: ^testing.T) {
	p := retry.exponential(initial = 100 * MS, max = 0, max_attempts = 0)
	p.jitter = .None
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p), nil)
	out: [3]time.Duration
	take(&b, out[:])
	testing.expect_value(t, out[2], 400 * MS)
	retry.backoff_reset(&b)
	testing.expect_value(t, b.attempt, 0)
	d, _ := retry.backoff_next(&b)
	testing.expect_value(t, d, 100 * MS)
}

@(test)
test_reset_clears_exhaustion :: proc(t: ^testing.T) {
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, retry.constant(MS, 2)), nil)
	out: [5]time.Duration
	testing.expect_value(t, take(&b, out[:]), 1)
	retry.backoff_reset(&b)
	testing.expect_value(t, b.stop, retry.Retry_Error.None)
	testing.expect_value(t, take(&b, out[:]), 1)
}

@(test)
test_reset_restarts_elapsed_window :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	p := retry.constant(400 * MS, 0)
	p.max_elapsed = time.Second
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p, {}, retry.fake_clock(&fc)), nil)
	fc.now = 900 * MS
	_, ok := retry.backoff_next(&b)
	testing.expect(t, !ok)
	retry.backoff_reset(&b)
	_, ok = retry.backoff_next(&b)
	testing.expect(t, ok, "reset must read the clock as the new start")
}

@(test)
test_reset_restarts_decorrelated_state :: proc(t: ^testing.T) {
	state: rand.Default_Random_State
	p := retry.Policy{initial = 10 * MS, max = time.Hour, multiplier = 1, jitter = .Decorrelated}
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p, seeded(&state, 12)), nil)
	out: [50]time.Duration
	take(&b, out[:])
	retry.backoff_reset(&b)
	d, _ := retry.backoff_next(&b)
	testing.expectf(t, d >= 10 * MS && d <= 30 * MS, "first delay after reset %v outside [10ms, 30ms]", d)
}

@(test)
test_zero_backoff_is_inert :: proc(t: ^testing.T) {
	b: retry.Backoff
	retry.backoff_reset(&b)
	_, ok := retry.backoff_next(&b)
	testing.expect(t, !ok, "a zero Backoff must not yield delays")
}

@(test)
test_short_aliases_match_long_names :: proc(t: ^testing.T) {
	b: retry.Backoff
	testing.expect_value(t, retry.init(&b, retry.linear(MS, MS, 0, 0)), nil)
	d, ok := retry.next(&b)
	testing.expect(t, ok)
	testing.expect_value(t, d, MS)
	d, _ = retry.next(&b)
	testing.expect_value(t, d, 2 * MS)
	retry.reset(&b)
	d, _ = retry.next(&b)
	testing.expect_value(t, d, MS)
}

@(test)
test_tiny_initial_still_grows :: proc(t: ^testing.T) {
	// 1 ns * 1.5 truncates back to 1 ns; the delay must still grow over time.
	p := retry.Policy{initial = 1, multiplier = 1.5}
	expect_delays(t, p, {1, 1, 2, 3, 5, 7, 11, 17})
}

@(test)
test_long_fractional_sequence_does_not_drift :: proc(t: ^testing.T) {
	// 100 ms * 1.5^15 = 43_789_389_038.0859375 ns. Truncating at every step
	// used to lose a nanosecond per step and compound the error.
	p := retry.Policy{initial = 100 * MS, multiplier = 1.5}
	b: retry.Backoff
	testing.expect_value(t, retry.backoff_init(&b, p), nil)
	got: [16]time.Duration
	testing.expect_value(t, take(&b, got[:]), 16)
	testing.expect_value(t, got[15], time.Duration(43_789_389_038))
}

@(test)
test_fractional_growth_respects_cap :: proc(t: ^testing.T) {
	p := retry.Policy{initial = 1, multiplier = 1.5, max = 4}
	expect_delays(t, p, {1, 1, 2, 3, 4, 4, 4})
}
