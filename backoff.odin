package retry

import "core:math/rand"
import "core:time"

// DECORRELATED_FACTOR is the growth bound of `.Decorrelated` jitter: each delay is at most this many times the previous one.
DECORRELATED_FACTOR :: 3

@(private = "file")
MAX_DURATION :: time.Duration(max(i64))

/*
Backoff produces the delays of a Policy one at a time.

Prepare it with backoff_init, call backoff_next after each failed attempt and
call backoff_reset to start over, for example after a success on a long-lived
connection. A Backoff owns no memory, so there's nothing to destroy.

A Backoff is safe to use from one thread at a time.
*/
Backoff :: struct {
	policy:      Policy,
	rng:         rand.Generator,
	clock:       Clock,
	// attempt is the number of delays backoff_next has returned since the last init or reset.
	attempt:     int,
	// stop is why backoff_next last returned false, or `.None` while it still returns delays.
	stop:        Retry_Error,
	start:       time.Duration,
	base:        time.Duration,
	previous:    time.Duration,
	initialized: bool,
}

/*
backoff_init prepares `b` to produce the delays of `policy`.

Inputs:
- b: the Backoff to prepare; any previous state is discarded.
- policy: the Policy to follow; it is copied.
- rng: draws jitter. The zero Generator means `context.random_generator` at
  the time of each draw. Pass a generator made with `rand.create` and
  `rand.default_random_generator` for repeatable delays. The Backoff keeps the
  generator, so its state must outlive `b`.
- clock: measures `max_elapsed`. The zero Clock is the system clock. The start
  time is read now and again on each backoff_reset.

Returns:
- err: a Policy_Error when `policy` is invalid; `b` is then left unusable and
  backoff_next returns false.
*/
backoff_init :: proc(b: ^Backoff, policy: Policy, rng: rand.Generator = {}, clock: Clock = {}) -> (err: Error) {
	b^ = {}
	if perr := policy_validate(policy); perr != .None {
		return perr
	}
	b.policy = policy
	b.rng = rng
	b.clock = clock
	b.initialized = true
	backoff_reset(b)
	return nil
}

/*
backoff_next returns the delay to wait before the next attempt.

Call it after each failed attempt. It returns `ok = false` when a limit has
been reached, and sets `b.stop` to `.Attempts_Exhausted` or
`.Elapsed_Exhausted`. Once it has returned false it keeps returning false until
backoff_reset. It also returns false for a Backoff that backoff_init never
prepared successfully.

Returns:
- delay: the wait before the next attempt; never negative and, unless the
  jitter is `.None`, never more than the computed delay.
- ok: false when no further attempt should run.
*/
backoff_next :: proc(b: ^Backoff) -> (delay: time.Duration, ok: bool) {
	if !b.initialized || b.stop != .None {
		return 0, false
	}
	p := &b.policy
	if p.max_attempts > 0 && b.attempt >= p.max_attempts - 1 {
		b.stop = .Attempts_Exhausted
		return 0, false
	}

	limit := p.max if p.max > 0 else MAX_DURATION
	switch p.jitter {
	case .None:
		delay = b.base
	case .Full:
		delay = random_between(b.rng, 0, b.base)
	case .Equal:
		half := b.base / 2
		delay = half + random_between(b.rng, 0, b.base - half)
	case .Decorrelated:
		hi := limit if b.previous > limit / DECORRELATED_FACTOR else b.previous * DECORRELATED_FACTOR
		if hi < p.initial {
			hi = p.initial
		}
		delay = random_between(b.rng, p.initial, hi)
		b.previous = delay
	}

	if p.max_elapsed > 0 {
		elapsed := clock_now(b.clock) - b.start
		if elapsed > p.max_elapsed || delay > p.max_elapsed - elapsed {
			b.stop = .Elapsed_Exhausted
			return 0, false
		}
	}

	b.base = grow(b.base, p.multiplier, p.increment, limit)
	b.attempt += 1
	return delay, true
}

/*
backoff_reset starts the delay sequence over from `initial`, clears the attempt
count and the stop reason, and reads the clock again as the new start of
`max_elapsed`. The random generator keeps its state, so jittered delays after a
reset differ from the first run.
*/
backoff_reset :: proc(b: ^Backoff) {
	if !b.initialized {
		return
	}
	b.attempt = 0
	b.stop = .None
	b.base = b.policy.initial
	if b.policy.max > 0 && b.base > b.policy.max {
		b.base = b.policy.max
	}
	b.previous = b.policy.initial
	b.start = clock_now(b.clock)
}

// init is a short name for backoff_init.
init :: proc {
	backoff_init,
}

// next is a short name for backoff_next.
next :: proc {
	backoff_next,
}

// reset is a short name for backoff_reset.
reset :: proc {
	backoff_reset,
}

// grow returns `base * multiplier + increment`, capped at `limit` without overflowing.
@(private = "file")
grow :: proc(base: time.Duration, multiplier: f64, increment: time.Duration, limit: time.Duration) -> time.Duration {
	if base >= limit {
		return limit
	}
	scaled := f64(base) * multiplier
	if scaled >= f64(limit) {
		return limit
	}
	next := time.Duration(scaled)
	if next < base {
		next = base
	}
	if increment >= limit - next {
		return limit
	}
	return next + increment
}

// random_between returns a uniform duration in `[lo, hi]`, both inclusive.
@(private = "file")
random_between :: proc(rng: rand.Generator, lo, hi: time.Duration) -> time.Duration {
	if hi <= lo {
		return lo
	}
	gen := rng if rng.procedure != nil else context.random_generator
	if hi == MAX_DURATION {
		return time.Duration(rand.int64_range(i64(lo), i64(hi), gen))
	}
	return time.Duration(rand.int64_range(i64(lo), i64(hi) + 1, gen))
}
