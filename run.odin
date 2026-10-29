package retry

import "core:math/rand"
import "core:time"

// Retry_Decision is what an operation tells run after each attempt.
Retry_Decision :: enum {
	// Success stops retrying; run returns `nil`.
	Success,
	// Retry marks a transient failure; run waits and tries again if the policy allows.
	Retry,
	// Permanent marks a failure that retrying can't fix; run stops at once.
	Permanent,
}

// Operation is one attempt of the work to retry. `attempt` counts from 1. `user` is the pointer passed to run.
Operation :: #type proc(user: rawptr, attempt: int) -> (retryable: Retry_Decision)

// On_Retry_Proc is called after attempt `attempt` failed, just before run sleeps for `delay`.
On_Retry_Proc :: #type proc(user: rawptr, attempt: int, delay: time.Duration)

/*
Options holds the optional parts of a run. Its zero value uses the system
clock, `context.random_generator` and no callback.
*/
Options :: struct {
	// clock measures `max_elapsed` and performs the sleeps. Use fake_clock in tests.
	clock:    Clock,
	// rng draws jitter. Seed one with `rand.create` for repeatable delays.
	rng:      rand.Generator,
	// on_retry, when set, is called before each sleep with the same `user` pointer as the operation.
	on_retry: On_Retry_Proc,
	/*
	breaker, when set, is asked before each attempt and told the outcome after
	it. `.Retry` and an invalid decision count as failures; `.Success` and
	`.Permanent` count as successes, because the dependency answered. The
	breaker must outlive the call.
	*/
	breaker:  ^Circuit_Breaker,
	// budget, when set, stops the run once it is spent and before any sleep that would spend it. It must outlive the call.
	budget:   ^Budget,
}

/*
run calls `op` until it succeeds, fails permanently or `policy` runs out of
attempts or time, sleeping on `options.clock` between attempts.

Inputs:
- policy: when to retry and how long to wait.
- op: the operation; it receives `user` and the attempt number, from 1.
- user: passed unchanged to `op` and `options.on_retry`; may be nil.
- options: clock, random generator and callback.

Returns:
- attempts: how many times `op` ran.
- err: `nil` on success. Otherwise a Policy_Error for an invalid policy, or a
  Retry_Error: `.Permanent_Failure`, `.Attempts_Exhausted`,
  `.Elapsed_Exhausted`, `.Circuit_Open`, `.Budget_Exhausted`,
  `.Invalid_Decision` or `.Nil_Operation`.

Example:
	Counter :: struct {
		calls: int,
	}

	flaky :: proc(user: rawptr, attempt: int) -> retry.Retry_Decision {
		c := (^Counter)(user)
		c.calls += 1
		return .Success if attempt == 3 else .Retry
	}

	c: Counter
	attempts, err := retry.run(retry.constant(10 * time.Millisecond), flaky, &c)
	// attempts == 3, err == nil
*/
run :: proc(policy: Policy, op: Operation, user: rawptr, options := Options{}) -> (attempts: int, err: Error) {
	if op == nil {
		return 0, .Nil_Operation
	}
	return run_loop(policy, op, user, options.clock, options.rng, options.on_retry, options.breaker, options.budget)
}

/*
run_typed is run with a typed user pointer, so `op` needs no cast. The
optional parameters match the fields of Options.

Example:
	Job :: struct {
		calls: int,
	}

	work :: proc(job: ^Job, attempt: int) -> retry.Retry_Decision {
		job.calls += 1
		return .Success
	}

	job: Job
	attempts, err := retry.run_typed(retry.exponential(), work, &job)
*/
run_typed :: proc(
	policy: Policy,
	op: proc(user: ^$T, attempt: int) -> Retry_Decision,
	user: ^T,
	on_retry: proc(user: ^T, attempt: int, delay: time.Duration) = nil,
	clock: Clock = {},
	rng: rand.Generator = {},
	breaker: ^Circuit_Breaker = nil,
	budget: ^Budget = nil,
) -> (
	attempts: int,
	err: Error,
) {
	if op == nil {
		return 0, .Nil_Operation
	}
	return run_loop(policy, op, user, clock, rng, on_retry, breaker, budget)
}

// run_loop holds the retry loop shared by run and run_typed.
@(private = "file")
run_loop :: proc(
	policy: Policy,
	op: $Op,
	user: $U,
	clock: Clock,
	rng: rand.Generator,
	on_retry: $Cb,
	breaker: ^Circuit_Breaker,
	budget: ^Budget,
) -> (
	attempts: int,
	err: Error,
) {
	b: Backoff
	backoff_init(&b, policy, rng, clock) or_return

	for {
		if budget != nil && budget_expired(budget^) {
			return attempts, .Budget_Exhausted
		}
		if breaker != nil && !breaker_allow(breaker) {
			return attempts, .Circuit_Open
		}

		attempts += 1
		decision := op(user, attempts)
		switch decision {
		case .Success:
			if breaker != nil {
				breaker_record_success(breaker)
			}
			return attempts, nil
		case .Permanent:
			if breaker != nil {
				breaker_record_success(breaker)
			}
			return attempts, .Permanent_Failure
		case .Retry:
			if breaker != nil {
				breaker_record_failure(breaker)
				// Fail fast: sleeping only to be rejected would waste the delay.
				if breaker_state(breaker) == .Open {
					return attempts, .Circuit_Open
				}
			}
		case:
			if breaker != nil {
				breaker_record_failure(breaker)
			}
			return attempts, .Invalid_Decision
		}

		delay, ok := backoff_next(&b)
		if !ok {
			return attempts, b.stop
		}
		if budget != nil && delay >= budget_remaining(budget^) {
			return attempts, .Budget_Exhausted
		}
		if on_retry != nil {
			on_retry(user, attempts, delay)
		}
		clock_sleep(clock, delay)
	}
}
