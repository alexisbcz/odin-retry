package retry

import "core:time"

// Clock_Now_Proc returns a monotonic time since an arbitrary, fixed origin. `data` is the Clock's user pointer.
Clock_Now_Proc :: #type proc(data: rawptr) -> time.Duration

// Clock_Sleep_Proc blocks for `d`, or pretends to. `data` is the Clock's user pointer.
Clock_Sleep_Proc :: #type proc(data: rawptr, d: time.Duration)

/*
Clock is an injectable source of time. The zero value is the system clock: a
monotonic tick counter and `time.sleep`. Each nil procedure falls back to its
system version on its own.
*/
Clock :: struct {
	now:   Clock_Now_Proc,
	sleep: Clock_Sleep_Proc,
	data:  rawptr,
}

// system_clock returns the Clock backed by the monotonic tick counter and `time.sleep`.
system_clock :: proc() -> Clock {
	return Clock{now = system_now, sleep = system_sleep}
}

// clock_now reads `clock`, using the system clock when `clock.now` is nil.
clock_now :: proc(clock: Clock) -> time.Duration {
	if clock.now == nil {
		return system_now(nil)
	}
	return clock.now(clock.data)
}

// clock_sleep sleeps for `d` on `clock`, using `time.sleep` when `clock.sleep` is nil. It returns at once when `d <= 0`.
clock_sleep :: proc(clock: Clock, d: time.Duration) {
	if d <= 0 {
		return
	}
	if clock.sleep == nil {
		system_sleep(nil, d)
		return
	}
	clock.sleep(clock.data, d)
}

@(private = "file")
system_now :: proc(_: rawptr) -> time.Duration {
	return time.tick_diff(time.Tick{}, time.tick_now())
}

@(private = "file")
system_sleep :: proc(_: rawptr, d: time.Duration) {
	time.sleep(d)
}

/*
Fake_Clock is a clock that never blocks. Sleeping on it moves its time forward
at once and records the sleep, so tests that retry with long delays finish
instantly. Its zero value reads as 0.

A Fake_Clock is safe to use from one thread at a time.
*/
Fake_Clock :: struct {
	// now is the current fake time.
	now:    time.Duration,
	// sleeps counts the calls to sleep with a positive duration.
	sleeps: int,
	// slept is the sum of every duration slept.
	slept:  time.Duration,
}

/*
fake_clock returns a Clock that reads and advances `f`.

The Clock keeps the pointer `f`, so `f` must outlive every Backoff and run
call that uses the Clock.
*/
fake_clock :: proc(f: ^Fake_Clock) -> Clock {
	return Clock{now = fake_now, sleep = fake_sleep, data = f}
}

// fake_clock_advance moves `f` forward by `d` without counting it as a sleep, for example to simulate a slow operation.
fake_clock_advance :: proc(f: ^Fake_Clock, d: time.Duration) {
	f.now += d
}

@(private = "file")
fake_now :: proc(data: rawptr) -> time.Duration {
	return (^Fake_Clock)(data).now
}

@(private = "file")
fake_sleep :: proc(data: rawptr, d: time.Duration) {
	f := (^Fake_Clock)(data)
	f.now += d
	f.sleeps += 1
	f.slept += d
}
