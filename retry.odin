/*
Package retry runs fallible operations again with a delay between attempts.

It covers the three usual backoff shapes (constant, linear and exponential),
the four jitter modes from the AWS Architecture Blog post "Exponential Backoff
And Jitter" (none, full, equal and decorrelated), and the two usual limits: a
maximum number of attempts and a maximum elapsed time.

Around that core it adds the other usual resilience tools: classify and its
siblings turn error values into retry decisions, a Circuit_Breaker fails fast
while a dependency is down, and a Budget caps the total time of a request
across attempts and nested calls.

There are two ways to use it:

- run (or run_typed) calls an operation, sleeps between failed attempts and
  stops on success, on a permanent failure or when a limit is reached.
- Backoff is the iterator underneath. Call backoff_next after each failure to
  get the next delay, and drive the loop yourself, for example from an event
  loop that must not block.

Time comes from a Clock and randomness from a `math/rand` Generator, and you
can inject both. A Fake_Clock never really sleeps, so tests run instantly, and
a seeded generator makes jittered delays the same on every run.

The package never allocates and keeps no global state. A Backoff value is safe
to use from one thread at a time.

Example:
	import "core:time"
	import retry "shared:retry"

	fetch :: proc(user: rawptr, attempt: int) -> retry.Retry_Decision {
		// Return .Success, .Retry for a transient failure or .Permanent.
		return .Success
	}

	main :: proc() {
		policy := retry.exponential(initial = 100 * time.Millisecond, max = 5 * time.Second)
		attempts, err := retry.run(policy, fetch, nil)
		_, _ = attempts, err
	}
*/
package retry

import "core:math"
import "core:time"

// Jitter selects how a Backoff randomizes each delay.
Jitter :: enum {
	// None uses the computed delay as is.
	None,
	// Full picks a delay uniformly in `[0, d]`, where `d` is the computed delay.
	Full,
	// Equal keeps half of the computed delay and randomizes the other half: `[d/2, d]`.
	Equal,
	/*
	Decorrelated picks a delay uniformly in `[initial, previous * 3]`, capped at
	`max`. It ignores `multiplier` and `increment`, because the growth comes from
	the previous delay. With `initial = 0` every delay is 0, as in the AWS
	formula, so give it a positive `initial`.
	*/
	Decorrelated,
}

/*
Policy describes when to retry and how long to wait between attempts.

The computed delay before the first retry is `initial`. Each later one is the
previous computed delay times `multiplier`, plus `increment`, capped at `max`;
the result is then jittered. With `increment = 0` this is
`initial * multiplier^n` for retry `n` (counting from 0), and with
`multiplier = 1` it is `initial + increment * n`.
The presets constant, linear and exponential fill in a valid Policy; set
further fields on the result as needed.

A zero `max`, `max_attempts` or `max_elapsed` means no limit. A Policy with no
limit at all retries until the operation succeeds or fails permanently.
*/
Policy :: struct {
	// initial is the delay before the first retry. Must not be negative.
	initial:      time.Duration,
	// max caps every single delay, before jitter. Zero means no cap; otherwise it must be at least `initial`.
	max:          time.Duration,
	// multiplier scales the delay after each retry. Must be finite and at least 1.
	multiplier:   f64,
	// increment is added to the delay after each retry, for linear backoff. Must not be negative.
	increment:    time.Duration,
	// jitter selects how each delay is randomized.
	jitter:       Jitter,
	// max_attempts is the total number of attempts, the first one included. Zero means no limit.
	max_attempts: int,
	// max_elapsed stops retrying when the next delay would end after this much time since the start. Zero means no limit.
	max_elapsed:  time.Duration,
}

// Policy_Error lists the ways a Policy can be invalid. policy_validate returns it.
Policy_Error :: enum {
	None,
	Negative_Initial,
	Negative_Max,
	Max_Below_Initial,
	Invalid_Multiplier,
	Negative_Increment,
	Invalid_Jitter,
	Negative_Max_Attempts,
	Negative_Max_Elapsed,
}

// Retry_Error lists the ways run and run_typed can end without success.
Retry_Error :: enum {
	None,
	// The operation passed to run was nil.
	Nil_Operation,
	// The operation returned `.Permanent`.
	Permanent_Failure,
	// The operation kept failing until `max_attempts` attempts had run.
	Attempts_Exhausted,
	// The next delay would have ended after `max_elapsed`.
	Elapsed_Exhausted,
	// The operation returned a value outside the Retry_Decision enum.
	Invalid_Decision,
	// The circuit breaker in Options.breaker rejected the attempt.
	Circuit_Open,
	// The Budget in Options.budget ran out, or the next delay would have used it up.
	Budget_Exhausted,
}

/*
Error is the result of every fallible procedure in this package. `nil` means
success. Compare it against a variant, for example
`err == retry.Error(retry.Retry_Error.Attempts_Exhausted)`, or use a type switch.
*/
Error :: union #shared_nil {
	Policy_Error,
	Retry_Error,
	Breaker_Error,
	Budget_Error,
}

// DEFAULT_INITIAL is the first delay used by the exponential preset.
DEFAULT_INITIAL :: 100 * time.Millisecond
// DEFAULT_MAX is the delay cap used by the exponential preset.
DEFAULT_MAX :: 10 * time.Second
// DEFAULT_MULTIPLIER is the growth factor used by the exponential preset.
DEFAULT_MULTIPLIER :: 2.0
// DEFAULT_MAX_ATTEMPTS is the attempt limit used by every preset.
DEFAULT_MAX_ATTEMPTS :: 5

/*
constant returns a Policy that waits `delay` before every retry, without jitter.

Inputs:
- delay: the wait between attempts.
- max_attempts: the total number of attempts, the first one included; 0 means no limit.
*/
constant :: proc(delay: time.Duration, max_attempts := DEFAULT_MAX_ATTEMPTS) -> Policy {
	return Policy{initial = delay, multiplier = 1, max_attempts = max_attempts}
}

/*
linear returns a Policy whose delay starts at `initial` and grows by `increment`
after each retry, without jitter.

Inputs:
- initial: the delay before the first retry.
- increment: added to the delay after each retry.
- max: the delay cap; 0 means no cap.
- max_attempts: the total number of attempts, the first one included; 0 means no limit.
*/
linear :: proc(
	initial: time.Duration,
	increment: time.Duration,
	max: time.Duration = 0,
	max_attempts := DEFAULT_MAX_ATTEMPTS,
) -> Policy {
	return Policy {
		initial = initial,
		max = max,
		multiplier = 1,
		increment = increment,
		max_attempts = max_attempts,
	}
}

/*
exponential returns a Policy whose delay starts at `initial` and is multiplied
by `multiplier` after each retry, capped at `max`, with full jitter. Set
`jitter = .None` on the result for exact, repeatable delays.

Inputs:
- initial: the delay before the first retry.
- max: the delay cap; 0 means no cap.
- multiplier: the growth factor; at least 1.
- max_attempts: the total number of attempts, the first one included; 0 means no limit.
*/
exponential :: proc(
	initial: time.Duration = DEFAULT_INITIAL,
	max: time.Duration = DEFAULT_MAX,
	multiplier: f64 = DEFAULT_MULTIPLIER,
	max_attempts := DEFAULT_MAX_ATTEMPTS,
) -> Policy {
	return Policy {
		initial = initial,
		max = max,
		multiplier = multiplier,
		jitter = .Full,
		max_attempts = max_attempts,
	}
}

/*
policy_validate reports the first problem with `p`, or `.None`.

backoff_init, run and run_typed call it, so you only need it to check a
Policy loaded from configuration before you use it.
*/
policy_validate :: proc(p: Policy) -> Policy_Error {
	switch {
	case p.initial < 0:
		return .Negative_Initial
	case p.max < 0:
		return .Negative_Max
	case p.max > 0 && p.max < p.initial:
		return .Max_Below_Initial
	case math.is_nan(p.multiplier) || math.is_inf(p.multiplier) || p.multiplier < 1:
		return .Invalid_Multiplier
	case p.increment < 0:
		return .Negative_Increment
	case p.jitter < min(Jitter) || p.jitter > max(Jitter):
		return .Invalid_Jitter
	case p.max_attempts < 0:
		return .Negative_Max_Attempts
	case p.max_elapsed < 0:
		return .Negative_Max_Elapsed
	}
	return .None
}
