// Example resilient combines error classification, a circuit breaker and a timeout budget. Run it with `odin run examples/resilient`.
package main

import retry "../.."
import "core:fmt"
import "core:math/rand"
import "core:time"

Fetch_Error :: enum {
	None,
	Timeout,
	Unavailable,
	Not_Found,
}

TRANSIENT :: []Fetch_Error{.Timeout, .Unavailable}

// Service stands in for a remote dependency that is down for a while.
Service :: struct {
	clock:   ^retry.Fake_Clock,
	down:    bool,
	calls:   int,
	budget:  ^retry.Budget,
	missing: bool,
}

fetch :: proc(s: ^Service, attempt: int) -> retry.Retry_Decision {
	s.calls += 1
	// Each attempt gets at most 200 ms, and less when the budget runs low.
	timeout := retry.budget_timeout(s.budget^, 200 * time.Millisecond)
	err: Fetch_Error
	switch {
	case s.missing:
		err = .Not_Found
	case s.down:
		retry.fake_clock_advance(s.clock, timeout)
		err = .Timeout
	case:
		retry.fake_clock_advance(s.clock, 20 * time.Millisecond)
	}
	fmt.printfln("  attempt %d (timeout %v): %v", attempt, timeout, err)
	return retry.classify(err, TRANSIENT)
}

on_change :: proc(_: rawptr, from, to: retry.Breaker_State) {
	fmt.printfln("  breaker: %v -> %v", from, to)
}

request :: proc(name: string, s: ^Service, cb: ^retry.Circuit_Breaker, fc: ^retry.Fake_Clock) {
	budget: retry.Budget
	_ = retry.budget_init(&budget, 2 * time.Second, retry.fake_clock(fc))
	s.budget = &budget

	policy := retry.exponential(initial = 100 * time.Millisecond, max = time.Second, max_attempts = 4)
	policy.jitter = .Equal

	// A fixed seed keeps the jittered delays the same on every run.
	state := rand.create(1)
	rng := rand.default_random_generator(&state)

	fmt.printfln("%s:", name)
	attempts, err := retry.run_typed(
		policy,
		fetch,
		s,
		clock = retry.fake_clock(fc),
		rng = rng,
		breaker = cb,
		budget = &budget,
	)
	if err != nil {
		fmt.printfln("  failed after %d attempts: %v (retry after %v)", attempts, err, retry.breaker_retry_after(cb))
		return
	}
	fmt.printfln("  ok after %d attempts", attempts)
}

main :: proc() {
	// A fake clock keeps the example instant and its output stable.
	fc: retry.Fake_Clock

	config := retry.default_breaker_config()
	config.failure_threshold = 3
	config.open_timeout = 5 * time.Second
	config.on_state_change = on_change

	cb: retry.Circuit_Breaker
	if err := retry.breaker_init(&cb, config, retry.fake_clock(&fc)); err != nil {
		fmt.eprintln("bad breaker config:", err)
		return
	}

	s := Service{clock = &fc, down = true}
	request("request 1, service down", &s, &cb, &fc)
	request("request 2, breaker open", &s, &cb, &fc)

	s.down = false
	retry.fake_clock_advance(&fc, 5 * time.Second)
	request("request 3, service back", &s, &cb, &fc)

	s.missing = true
	request("request 4, missing resource", &s, &cb, &fc)
	fmt.println("total calls to the service:", s.calls)
}
