package retry_tests

import retry ".."
import "core:fmt"
import "core:math/rand"
import "core:testing"
import "core:time"

// Script makes an operation fail with `.Retry` until `succeed_on`, or return `.Permanent` on `permanent_on`.
Script :: struct {
	calls:        int,
	succeed_on:   int,
	permanent_on: int,
	clock:        ^retry.Fake_Clock,
	work:         time.Duration,
	retries:      [8]struct {
		attempt: int,
		delay:   time.Duration,
	},
	notified:     int,
}

scripted :: proc(user: rawptr, attempt: int) -> retry.Retry_Decision {
	s := (^Script)(user)
	s.calls += 1
	if s.clock != nil {
		retry.fake_clock_advance(s.clock, s.work)
	}
	if s.permanent_on > 0 && attempt == s.permanent_on {
		return .Permanent
	}
	if s.succeed_on > 0 && attempt >= s.succeed_on {
		return .Success
	}
	return .Retry
}

notify :: proc(user: rawptr, attempt: int, delay: time.Duration) {
	s := (^Script)(user)
	if s.notified < len(s.retries) {
		s.retries[s.notified] = {attempt, delay}
	}
	s.notified += 1
}

@(test)
test_run_succeeds_first_time_without_sleeping :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	s := Script{succeed_on = 1}
	attempts, err := retry.run(retry.constant(time.Second), scripted, &s, {clock = retry.fake_clock(&fc)})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, attempts, 1)
	testing.expect_value(t, fc.sleeps, 0)
}

@(test)
test_run_sleeps_exact_exponential_sequence :: proc(t: ^testing.T) {
	lc: Leak_Check
	context.allocator = leak_check_begin(&lc, t)
	defer leak_check_end(&lc)

	rec: Recorder
	recorder_init(&rec)
	defer recorder_destroy(&rec)

	p := retry.exponential(initial = 100 * MS, max = 1000 * MS, max_attempts = 0)
	p.jitter = .None
	s := Script{succeed_on = 7}
	attempts, err := retry.run(p, scripted, &s, {clock = recorder_clock(&rec)})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, attempts, 7)
	want := []time.Duration{100 * MS, 200 * MS, 400 * MS, 800 * MS, 1000 * MS, 1000 * MS}
	testing.expect_value(t, len(rec.sleeps), len(want))
	for d, i in want {
		testing.expectf(t, rec.sleeps[i] == d, "sleep %d: got %v, want %v", i, rec.sleeps[i], d)
	}
	testing.expect_value(t, rec.now, 3500 * MS)
}

@(test)
test_run_sleeps_exact_linear_sequence :: proc(t: ^testing.T) {
	lc: Leak_Check
	context.allocator = leak_check_begin(&lc, t)
	defer leak_check_end(&lc)

	rec: Recorder
	recorder_init(&rec)
	defer recorder_destroy(&rec)

	s := Script{}
	attempts, err := retry.run(retry.linear(10 * MS, 10 * MS, 0, 4), scripted, &s, {clock = recorder_clock(&rec)})
	testing.expect_value(t, err, rerr(.Attempts_Exhausted))
	testing.expect_value(t, attempts, 4)
	testing.expect_value(t, len(rec.sleeps), 3)
	testing.expect_value(t, rec.sleeps[0], 10 * MS)
	testing.expect_value(t, rec.sleeps[1], 20 * MS)
	testing.expect_value(t, rec.sleeps[2], 30 * MS)
}

@(test)
test_run_reports_attempts_exhausted :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	s := Script{}
	attempts, err := retry.run(retry.constant(MS, 3), scripted, &s, {clock = retry.fake_clock(&fc)})
	testing.expect_value(t, err, rerr(.Attempts_Exhausted))
	testing.expect_value(t, attempts, 3)
	testing.expect_value(t, s.calls, 3)
	testing.expect_value(t, fc.sleeps, 2)
}

@(test)
test_run_stops_early_on_permanent_failure :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	s := Script{permanent_on = 2}
	attempts, err := retry.run(retry.constant(MS, 10), scripted, &s, {clock = retry.fake_clock(&fc)})
	testing.expect_value(t, err, rerr(.Permanent_Failure))
	testing.expect_value(t, attempts, 2)
	testing.expect_value(t, fc.sleeps, 1)
}

@(test)
test_run_permanent_on_first_attempt_never_sleeps :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	s := Script{permanent_on = 1}
	attempts, err := retry.run(retry.constant(time.Hour, 0), scripted, &s, {clock = retry.fake_clock(&fc)})
	testing.expect_value(t, err, rerr(.Permanent_Failure))
	testing.expect_value(t, attempts, 1)
	testing.expect_value(t, fc.sleeps, 0)
}

@(test)
test_run_reports_elapsed_exhausted :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	p := retry.constant(200 * MS, 0)
	p.max_elapsed = time.Second
	s := Script{clock = &fc, work = 100 * MS}
	attempts, err := retry.run(p, scripted, &s, {clock = retry.fake_clock(&fc)})
	testing.expect_value(t, err, rerr(.Elapsed_Exhausted))
	// Each round costs 100 ms of work plus 200 ms of sleep.
	testing.expect_value(t, attempts, 4)
	testing.expect(t, fc.now <= time.Second, "run must never sleep past max_elapsed")
}

@(test)
test_run_calls_on_retry_with_attempt_and_delay :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	s := Script{succeed_on = 4}
	attempts, err := retry.run(retry.linear(MS, MS, 0, 0), scripted, &s, {clock = retry.fake_clock(&fc), on_retry = notify})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, attempts, 4)
	testing.expect_value(t, s.notified, 3)
	for i in 0 ..< 3 {
		testing.expect_value(t, s.retries[i].attempt, i + 1)
		testing.expect_value(t, s.retries[i].delay, time.Duration(i + 1) * MS)
	}
}

@(test)
test_run_on_retry_not_called_on_permanent_failure :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	s := Script{permanent_on = 1}
	_, _ = retry.run(retry.constant(MS), scripted, &s, {clock = retry.fake_clock(&fc), on_retry = notify})
	testing.expect_value(t, s.notified, 0)
}

@(test)
test_run_rejects_nil_operation :: proc(t: ^testing.T) {
	attempts, err := retry.run(retry.constant(MS), nil, nil)
	testing.expect_value(t, err, rerr(.Nil_Operation))
	testing.expect_value(t, attempts, 0)
}

@(test)
test_run_rejects_invalid_policy_before_calling :: proc(t: ^testing.T) {
	s := Script{succeed_on = 1}
	attempts, err := retry.run(retry.Policy{}, scripted, &s)
	testing.expect_value(t, err, perr(.Invalid_Multiplier))
	testing.expect_value(t, attempts, 0)
	testing.expect_value(t, s.calls, 0)
}

bogus :: proc(user: rawptr, attempt: int) -> retry.Retry_Decision {
	return retry.Retry_Decision(99)
}

@(test)
test_run_rejects_unknown_decision :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	attempts, err := retry.run(retry.constant(MS), bogus, nil, {clock = retry.fake_clock(&fc)})
	testing.expect_value(t, err, rerr(.Invalid_Decision))
	testing.expect_value(t, attempts, 1)
	testing.expect_value(t, fc.sleeps, 0)
}

@(test)
test_run_with_seed_is_repeatable :: proc(t: ^testing.T) {
	lc: Leak_Check
	context.allocator = leak_check_begin(&lc, t)
	defer leak_check_end(&lc)

	a, b: Recorder
	recorder_init(&a)
	defer recorder_destroy(&a)
	recorder_init(&b)
	defer recorder_destroy(&b)

	p := retry.exponential(max_attempts = 8)
	s1, s2: rand.Default_Random_State
	sa, sb := Script{}, Script{}
	_, _ = retry.run(p, scripted, &sa, {clock = recorder_clock(&a), rng = seeded(&s1, 2024)})
	_, _ = retry.run(p, scripted, &sb, {clock = recorder_clock(&b), rng = seeded(&s2, 2024)})
	testing.expect_value(t, len(a.sleeps), 7)
	testing.expect_value(t, len(b.sleeps), 7)
	for i in 0 ..< min(len(a.sleeps), len(b.sleeps)) {
		testing.expect_value(t, a.sleeps[i], b.sleeps[i])
	}
}

@(test)
test_run_never_really_sleeps_with_fake_clock :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	s := Script{succeed_on = 10}
	start := time.tick_now()
	attempts, err := retry.run(retry.constant(time.Hour, 0), scripted, &s, {clock = retry.fake_clock(&fc)})
	wall := time.tick_since(start)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, attempts, 10)
	testing.expect_value(t, fc.slept, 9 * time.Hour)
	testing.expectf(t, wall < time.Second, "nine one-hour sleeps took %v of wall time", wall)
}

Job :: struct {
	calls:    int,
	notified: int,
	last:     time.Duration,
}

job_op :: proc(job: ^Job, attempt: int) -> retry.Retry_Decision {
	job.calls += 1
	return .Success if attempt == 3 else .Retry
}

job_notify :: proc(job: ^Job, attempt: int, delay: time.Duration) {
	job.notified += 1
	job.last = delay
}

@(test)
test_run_typed_passes_typed_pointer :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	job: Job
	attempts, err := retry.run_typed(retry.linear(MS, MS, 0, 0), job_op, &job, job_notify, retry.fake_clock(&fc))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, attempts, 3)
	testing.expect_value(t, job.calls, 3)
	testing.expect_value(t, job.notified, 2)
	testing.expect_value(t, job.last, 2 * MS)
	testing.expect_value(t, fc.slept, 3 * MS)
}

@(test)
test_run_typed_rejects_nil_operation :: proc(t: ^testing.T) {
	job: Job
	op: proc(job: ^Job, attempt: int) -> retry.Retry_Decision
	attempts, err := retry.run_typed(retry.constant(MS), op, &job)
	testing.expect_value(t, err, rerr(.Nil_Operation))
	testing.expect_value(t, attempts, 0)
}

@(test)
test_fake_clock_records_sleeps :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	clock := retry.fake_clock(&fc)
	retry.clock_sleep(clock, 2 * MS)
	retry.clock_sleep(clock, 0)
	retry.clock_sleep(clock, -MS)
	retry.clock_sleep(clock, 3 * MS)
	testing.expect_value(t, fc.sleeps, 2)
	testing.expect_value(t, fc.slept, 5 * MS)
	testing.expect_value(t, retry.clock_now(clock), 5 * MS)
}

@(test)
test_fake_clock_advance_is_not_a_sleep :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	retry.fake_clock_advance(&fc, time.Minute)
	testing.expect_value(t, fc.now, time.Minute)
	testing.expect_value(t, fc.sleeps, 0)
	testing.expect_value(t, fc.slept, 0)
}

@(test)
test_system_clock_is_monotonic :: proc(t: ^testing.T) {
	a := retry.clock_now({})
	b := retry.clock_now(retry.system_clock())
	testing.expect(t, a > 0)
	testing.expect(t, b >= a)
}

@(test)
test_system_clock_skips_non_positive_sleeps :: proc(t: ^testing.T) {
	start := time.tick_now()
	retry.clock_sleep({}, 0)
	retry.clock_sleep({}, -time.Hour)
	testing.expect(t, time.tick_since(start) < time.Second)
}

@(test)
test_errors_print_as_messages :: proc(t: ^testing.T) {
	s := fmt.tprint(rerr(.Attempts_Exhausted))
	testing.expect_value(t, s, "Attempts_Exhausted")
	s = fmt.tprint(perr(.Max_Below_Initial))
	testing.expect_value(t, s, "Max_Below_Initial")
}
