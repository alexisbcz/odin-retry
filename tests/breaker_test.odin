package retry_tests

import retry ".."
import "core:fmt"
import "core:testing"
import "core:time"

// Transitions records the state changes a breaker reports.
Transitions :: struct {
	count: int,
	from:  [8]retry.Breaker_State,
	to:    [8]retry.Breaker_State,
}

on_change :: proc(user: rawptr, from, to: retry.Breaker_State) {
	tr := (^Transitions)(user)
	if tr.count < len(tr.from) {
		tr.from[tr.count] = from
		tr.to[tr.count] = to
	}
	tr.count += 1
}

breaker_config :: proc(threshold: int, timeout: time.Duration) -> retry.Breaker_Config {
	c := retry.default_breaker_config()
	c.failure_threshold = threshold
	c.open_timeout = timeout
	return c
}

// fail_n records `n` allowed failures.
fail_n :: proc(cb: ^retry.Circuit_Breaker, n: int) {
	for _ in 0 ..< n {
		if retry.breaker_allow(cb) {
			retry.breaker_record_failure(cb)
		}
	}
}

@(test)
test_breaker_default_config_is_valid :: proc(t: ^testing.T) {
	c := retry.default_breaker_config()
	testing.expect_value(t, retry.breaker_config_validate(c), retry.Breaker_Error.None)
	testing.expect_value(t, c.failure_threshold, retry.DEFAULT_FAILURE_THRESHOLD)
	testing.expect_value(t, c.open_timeout, retry.DEFAULT_OPEN_TIMEOUT)
}

@(test)
test_breaker_rejects_invalid_config :: proc(t: ^testing.T) {
	cb: retry.Circuit_Breaker
	cases := []struct {
		config: retry.Breaker_Config,
		want:   retry.Breaker_Error,
	} {
		{{failure_threshold = 0}, .Invalid_Failure_Threshold},
		{{failure_threshold = -3}, .Invalid_Failure_Threshold},
		{{failure_threshold = 1, open_timeout = -MS}, .Negative_Open_Timeout},
		{{failure_threshold = 1, half_open_max = -1}, .Negative_Half_Open_Max},
		{{failure_threshold = 1, success_threshold = -1}, .Negative_Success_Threshold},
	}
	for c, i in cases {
		err := retry.breaker_init(&cb, c.config)
		testing.expectf(t, err == retry.Error(c.want), "case %d: got %v, want %v", i, err, c.want)
	}
}

@(test)
test_breaker_uninitialized_allows_everything :: proc(t: ^testing.T) {
	cb: retry.Circuit_Breaker
	for _ in 0 ..< 100 {
		testing.expect(t, retry.breaker_allow(&cb))
		retry.breaker_record_failure(&cb)
	}
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Closed)
	testing.expect_value(t, retry.breaker_retry_after(&cb), 0)
}

@(test)
test_breaker_invalid_init_leaves_breaker_permissive :: proc(t: ^testing.T) {
	cb: retry.Circuit_Breaker
	testing.expect(t, retry.breaker_init(&cb, {}) != nil)
	fail_n(&cb, 10)
	testing.expect(t, retry.breaker_allow(&cb))
}

@(test)
test_breaker_starts_closed :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	testing.expect_value(t, retry.breaker_init(&cb, breaker_config(3, time.Second), retry.fake_clock(&fc)), nil)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Closed)
	testing.expect(t, retry.breaker_allow(&cb))
}

@(test)
test_breaker_opens_after_threshold_consecutive_failures :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(3, time.Second), retry.fake_clock(&fc))
	fail_n(&cb, 2)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Closed)
	fail_n(&cb, 1)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Open)
	testing.expect(t, !retry.breaker_allow(&cb))
	testing.expect_value(t, cb.opened, 1)
}

@(test)
test_breaker_success_resets_failure_count :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(3, time.Second), retry.fake_clock(&fc))
	fail_n(&cb, 2)
	testing.expect(t, retry.breaker_allow(&cb))
	retry.breaker_record_success(&cb)
	fail_n(&cb, 2)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Closed)
}

@(test)
test_breaker_half_opens_after_timeout :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(1, time.Second), retry.fake_clock(&fc))
	fail_n(&cb, 1)
	retry.fake_clock_advance(&fc, time.Second - MS)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Open)
	retry.fake_clock_advance(&fc, MS)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Half_Open)
}

@(test)
test_breaker_retry_after_counts_down :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(1, 10 * time.Second), retry.fake_clock(&fc))
	testing.expect_value(t, retry.breaker_retry_after(&cb), 0)
	fail_n(&cb, 1)
	testing.expect_value(t, retry.breaker_retry_after(&cb), 10 * time.Second)
	retry.fake_clock_advance(&fc, 4 * time.Second)
	testing.expect_value(t, retry.breaker_retry_after(&cb), 6 * time.Second)
	retry.fake_clock_advance(&fc, 6 * time.Second)
	testing.expect_value(t, retry.breaker_retry_after(&cb), 0)
}

@(test)
test_breaker_half_open_limits_trial_calls :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	c := breaker_config(1, time.Second)
	c.half_open_max = 2
	c.success_threshold = 5
	_ = retry.breaker_init(&cb, c, retry.fake_clock(&fc))
	fail_n(&cb, 1)
	retry.fake_clock_advance(&fc, time.Second)
	testing.expect(t, retry.breaker_allow(&cb))
	testing.expect(t, retry.breaker_allow(&cb))
	testing.expect(t, !retry.breaker_allow(&cb), "a third trial must wait")
	retry.breaker_record_success(&cb)
	testing.expect(t, retry.breaker_allow(&cb), "a recorded trial frees its slot")
}

@(test)
test_breaker_half_open_success_closes :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(1, time.Second), retry.fake_clock(&fc))
	fail_n(&cb, 1)
	retry.fake_clock_advance(&fc, time.Second)
	testing.expect(t, retry.breaker_allow(&cb))
	retry.breaker_record_success(&cb)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Closed)
}

@(test)
test_breaker_half_open_needs_success_threshold :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	c := breaker_config(1, time.Second)
	c.success_threshold = 3
	_ = retry.breaker_init(&cb, c, retry.fake_clock(&fc))
	fail_n(&cb, 1)
	retry.fake_clock_advance(&fc, time.Second)
	for i in 0 ..< 3 {
		testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Half_Open)
		testing.expectf(t, retry.breaker_allow(&cb), "trial %d", i)
		retry.breaker_record_success(&cb)
	}
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Closed)
}

@(test)
test_breaker_half_open_failure_reopens_and_restarts_timeout :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(1, time.Second), retry.fake_clock(&fc))
	fail_n(&cb, 1)
	retry.fake_clock_advance(&fc, 5 * time.Second)
	testing.expect(t, retry.breaker_allow(&cb))
	retry.breaker_record_failure(&cb)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Open)
	testing.expect_value(t, retry.breaker_retry_after(&cb), time.Second)
	testing.expect_value(t, cb.opened, 2)
}

@(test)
test_breaker_ignores_late_results_while_open :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(1, time.Second), retry.fake_clock(&fc))
	fail_n(&cb, 1)
	retry.breaker_record_success(&cb)
	retry.breaker_record_failure(&cb)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Open)
	testing.expect_value(t, retry.breaker_retry_after(&cb), time.Second)
	testing.expect_value(t, cb.opened, 1)
}

@(test)
test_breaker_zero_timeout_half_opens_immediately :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(1, 0), retry.fake_clock(&fc))
	fail_n(&cb, 1)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Half_Open)
}

@(test)
test_breaker_trip_and_reset :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	_ = retry.breaker_init(&cb, breaker_config(5, time.Minute), retry.fake_clock(&fc))
	retry.breaker_trip(&cb)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Open)
	testing.expect(t, !retry.breaker_allow(&cb))
	retry.breaker_reset(&cb)
	testing.expect_value(t, retry.breaker_state(&cb), retry.Breaker_State.Closed)
	testing.expect(t, retry.breaker_allow(&cb))
	testing.expect_value(t, cb.opened, 1)
}

@(test)
test_breaker_reports_every_transition :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	cb: retry.Circuit_Breaker
	tr: Transitions
	c := breaker_config(2, time.Second)
	c.on_state_change = on_change
	c.user = &tr
	_ = retry.breaker_init(&cb, c, retry.fake_clock(&fc))
	fail_n(&cb, 2)
	retry.fake_clock_advance(&fc, time.Second)
	testing.expect(t, retry.breaker_allow(&cb))
	retry.breaker_record_success(&cb)
	testing.expect_value(t, tr.count, 3)
	testing.expect_value(t, tr.from[0], retry.Breaker_State.Closed)
	testing.expect_value(t, tr.to[0], retry.Breaker_State.Open)
	testing.expect_value(t, tr.from[1], retry.Breaker_State.Open)
	testing.expect_value(t, tr.to[1], retry.Breaker_State.Half_Open)
	testing.expect_value(t, tr.from[2], retry.Breaker_State.Half_Open)
	testing.expect_value(t, tr.to[2], retry.Breaker_State.Closed)
}

@(test)
test_breaker_reset_on_closed_does_not_notify :: proc(t: ^testing.T) {
	cb: retry.Circuit_Breaker
	tr: Transitions
	c := breaker_config(2, time.Second)
	c.on_state_change = on_change
	c.user = &tr
	_ = retry.breaker_init(&cb, c)
	retry.breaker_reset(&cb)
	testing.expect_value(t, tr.count, 0)
}

@(test)
test_breaker_states_print_as_names :: proc(t: ^testing.T) {
	testing.expect_value(t, fmt.tprint(retry.Breaker_State.Half_Open), "Half_Open")
	testing.expect_value(t, fmt.tprint(retry.Error(retry.Breaker_Error.Negative_Open_Timeout)), "Negative_Open_Timeout")
}
