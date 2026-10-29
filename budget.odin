package retry

import "core:time"

// Budget_Error lists the ways budget_init can fail.
Budget_Error :: enum {
	None,
	// The total passed to budget_init or budget_child is negative.
	Negative_Total,
}

/*
Budget is a timeout budget: a fixed amount of time that one logical request
may spend, across every attempt, every sleep and every nested call.

Create one with budget_init at the edge of a request, then hand it down. Ask
budget_timeout for the timeout of each attempt, so that a slow attempt can't
outlive the request, and pass it to run through Options.budget so that run
never sleeps past it. budget_child carves a smaller budget for a sub-call out
of what remains.

The zero Budget is unlimited: it never expires and budget_remaining reports
the largest `time.Duration`. A Budget owns no memory. It is safe to read from
several threads, because none of its procedures write to it after
budget_init.
*/
Budget :: struct {
	clock:   Clock,
	start:   time.Duration,
	total:   time.Duration,
	limited: bool,
}

/*
budget_init starts a budget of `total` from now.

Inputs:
- b: the Budget to start.
- total: how much time the budget allows. Zero gives a budget that is
  already spent.
- clock: the time source. The zero Clock is the system clock.

Returns:
- err: `.Negative_Total` when `total < 0`; `b` is then the unlimited zero Budget.
*/
budget_init :: proc(b: ^Budget, total: time.Duration, clock: Clock = {}) -> (err: Error) {
	b^ = {}
	if total < 0 {
		return Budget_Error.Negative_Total
	}
	b.clock = clock
	b.start = clock_now(clock)
	b.total = total
	b.limited = true
	return nil
}

// budget_elapsed returns the time spent since budget_init, or 0 for an unlimited Budget.
budget_elapsed :: proc(b: Budget) -> time.Duration {
	if !b.limited {
		return 0
	}
	return clock_now(b.clock) - b.start
}

// budget_remaining returns the time left, never negative. An unlimited Budget returns the largest `time.Duration`.
budget_remaining :: proc(b: Budget) -> time.Duration {
	if !b.limited {
		return MAX_DURATION
	}
	left := b.total - budget_elapsed(b)
	return left if left > 0 else 0
}

// budget_expired reports whether no time is left.
budget_expired :: proc(b: Budget) -> bool {
	return b.limited && budget_remaining(b) == 0
}

/*
budget_timeout returns the timeout to give one attempt: `per_attempt`, cut
down to what the budget has left. A `per_attempt` of 0 or less means "no
timeout of its own", so the result is the remaining budget.

A spent budget gives 0. Many APIs read a timeout of 0 as "no timeout", so
check budget_expired first, or let run do it through Options.budget.
*/
budget_timeout :: proc(b: Budget, per_attempt: time.Duration) -> time.Duration {
	left := budget_remaining(b)
	if per_attempt <= 0 || per_attempt > left {
		return left
	}
	return per_attempt
}

/*
budget_child returns a budget of `total` that starts now and never outlives
`parent`: its total is the smaller of `total` and what `parent` has left. A
child of an unlimited parent gets `total` exactly.

Returns:
- child: the new budget, sharing the parent's clock.
- err: `.Negative_Total` when `total < 0`.
*/
budget_child :: proc(parent: Budget, total: time.Duration) -> (child: Budget, err: Error) {
	if total < 0 {
		return {}, Budget_Error.Negative_Total
	}
	budget_init(&child, min(total, budget_remaining(parent)), parent.clock) or_return
	return child, nil
}
