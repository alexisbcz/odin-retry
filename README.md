# retry

[![CI](https://github.com/alexisbcz/odin-retry/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-retry/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Retry and resilience for Odin: constant, linear or exponential backoff with full, equal or decorrelated jitter, limits on attempts and elapsed time, retryable error classification, a circuit breaker and timeout budgets. It covers the ground of Go's `cenkalti/backoff` and `sony/gobreaker`. You can inject the clock and the random generator, so tests run instantly and give the same result every time.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-retry libs/retry
```

```odin
import "libs/retry"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-retry ~/odin-shared/retry
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:retry"
```

## Quick start

An operation returns `.Success`, `.Retry` for a transient failure, or `.Permanent` for a failure that retrying can't fix. `run_typed` calls it until it succeeds or the policy gives up, and sleeps between attempts.

```odin
package main

import "core:fmt"
import "core:time"
import "shared:retry"

Download :: struct {
	failures_left: int,
}

download :: proc(d: ^Download, attempt: int) -> retry.Retry_Decision {
	if d.failures_left > 0 {
		d.failures_left -= 1
		return .Retry
	}
	return .Success
}

main :: proc() {
	policy := retry.exponential(initial = 50 * time.Millisecond, max = time.Second, max_attempts = 4)
	d := Download{failures_left = 2}
	attempts, err := retry.run_typed(policy, download, &d)
	if err != nil {
		fmt.eprintln("download failed:", err)
		return
	}
	fmt.println("succeeded after", attempts, "attempts")
}
```

## Policies

A `Policy` waits `initial` before the first retry. Each later delay is the previous one times `multiplier`, plus `increment`. It caps that delay at `max` and then applies the jitter. With `increment = 0` the delay before retry `n`, counting from 0, is `initial * multiplier^n`, and with `multiplier = 1` it is `initial + increment * n`. A zero `max`, `max_attempts` or `max_elapsed` means no limit.

| Preset | Delays without jitter | Default jitter |
| --- | --- | --- |
| `constant(delay, max_attempts)` | `d, d, d, …` | `.None` |
| `linear(initial, increment, max, max_attempts)` | `i, i + s, i + 2s, …` | `.None` |
| `exponential(initial, max, multiplier, max_attempts)` | `i, i·m, i·m², …` | `.Full` |

The jitter modes follow the AWS Architecture Blog post "Exponential Backoff And Jitter". Here `d` is the capped delay:

| Jitter | Delay |
| --- | --- |
| `.None` | `d` |
| `.Full` | uniform in `[0, d]` |
| `.Equal` | uniform in `[d/2, d]` |
| `.Decorrelated` | uniform in `[initial, previous * 3]`, capped at `max` |

`.Decorrelated` needs a positive `initial`: with `initial = 0` every delay is 0.

`max_attempts` counts every attempt, the first one included. `max_elapsed` stops before a delay that would end after that much time since the start, so a run never sleeps past its deadline.

## Classifying errors

Most operations return an error value, not a decision. The `classify` helpers map the zero value to `.Success` and sort every other value into `.Retry` or `.Permanent`:

```odin
Fetch_Error :: enum {
	None,
	Timeout,
	Unavailable,
	Not_Found,
}

TRANSIENT :: []Fetch_Error{.Timeout, .Unavailable}

FATAL :: []Fetch_Error{.Not_Found}

is_transient_errno :: proc(code: i32) -> bool {
	return code == 4 || code == 35 // EINTR or EAGAIN on macOS
}

main :: proc() {
	fmt.println(retry.classify(Fetch_Error.Timeout, TRANSIENT))    // Retry
	fmt.println(retry.classify(Fetch_Error.Not_Found, TRANSIENT))  // Permanent
	fmt.println(retry.classify_except(Fetch_Error.Timeout, FATAL)) // Retry
	fmt.println(retry.classify_proc(i32(35), is_transient_errno))  // Retry
}
```

## Circuit breaker

A `Circuit_Breaker` stops calling a dependency that keeps failing, so callers fail fast and the dependency gets time to recover.

| State | Calls | Moves to |
| --- | --- | --- |
| `.Closed` | All allowed | `.Open` after `failure_threshold` consecutive failures |
| `.Open` | All rejected | `.Half_Open` once `open_timeout` has passed |
| `.Half_Open` | Up to `half_open_max` trial calls | `.Closed` after `success_threshold` successes, `.Open` on any failure |

Set `Options.breaker`, or the `breaker` parameter of `run_typed`, and `run` asks the breaker before each attempt and reports each outcome. It returns `.Circuit_Open` as soon as the breaker rejects a call, or as soon as a failure opens the breaker and the next delay ends before the breaker would let a trial call through. When the delay outlasts `open_timeout`, `run` sleeps and makes the next attempt a trial call. A `.Permanent` result counts as a success for the breaker, because the dependency answered.

```odin
config := retry.default_breaker_config()
config.failure_threshold = 3
config.open_timeout = 5 * time.Second

cb: retry.Circuit_Breaker
if err := retry.breaker_init(&cb, config); err != nil {
	return
}
attempts, err := retry.run_typed(policy, fetch, &service, breaker = &cb)
if err == retry.Error(retry.Retry_Error.Circuit_Open) {
	fmt.println("service down, retry in", retry.breaker_retry_after(&cb))
}
```

Outside `run`, call `breaker_allow` before each call and `breaker_record_success` or `breaker_record_failure` after it. `breaker_trip` opens the breaker by hand, `breaker_reset` closes it, and `on_state_change` reports every transition. A breaker holds a mutex, so threads can share it.

## Timeout budgets

A `Budget` caps the total time one request may spend, across attempts, sleeps and nested calls. Give each attempt `budget_timeout(budget, per_attempt)` as its timeout, and pass the budget to `run` so that it never sleeps past the end:

```odin
budget: retry.Budget
_ = retry.budget_init(&budget, 2 * time.Second)

// Inside the operation: at most 200 ms, less when the budget runs low.
timeout := retry.budget_timeout(budget, 200 * time.Millisecond)

attempts, err := retry.run_typed(policy, fetch, &service, budget = &budget)
// err is .Budget_Exhausted when the time ran out.
```

`budget_child(parent, total)` gives a sub-call its own budget that never outlives the parent. The zero `Budget` has no limit.

## Driving the loop yourself

`Backoff` is the iterator behind `run`. Use it when you can't block, for example in an event loop:

```odin
b: retry.Backoff
if err := retry.backoff_init(&b, retry.linear(100 * time.Millisecond, 100 * time.Millisecond, max_attempts = 4)); err != nil {
	return
}
for {
	delay, ok := retry.backoff_next(&b)
	if !ok {
		break // b.stop says why: .Attempts_Exhausted or .Elapsed_Exhausted
	}
	fmt.println("linear delay:", delay)
}
```

Call `backoff_reset` to start over, for example after a long-lived connection comes back. The short names `init`, `next` and `reset` do the same thing.

## Testing code that retries

Pass a `Fake_Clock` and a seeded generator. Sleeping on a fake clock moves its time forward at once and records the sleep.

```odin
fc: retry.Fake_Clock
state := rand.create(42)
attempts, err := retry.run(policy, op, user, {
	clock = retry.fake_clock(&fc),
	rng   = rand.default_random_generator(&state),
})
// fc.sleeps and fc.slept now hold the number and total of the delays.
```

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `Policy`, `Jitter` | Describe delays and limits | No | Not needed |
| `constant`, `linear`, `exponential` | Build a valid `Policy` | No | Not needed |
| `policy_validate(p)` | Report the first invalid field | No | Not needed |
| `Backoff` | Iterator over the delays of a policy | No | Not needed |
| `backoff_init(b, policy, rng, clock)` | Prepare a `Backoff` | No | Not needed |
| `backoff_next(b)` | Return `(delay, ok)` for the next retry | No | Not needed |
| `backoff_reset(b)` | Start the sequence and the elapsed window over | No | Not needed |
| `run(policy, op, user, options)` | Retry an `Operation` with a `rawptr` user value | No | Not needed |
| `run_typed(policy, op, user, on_retry, clock, rng, breaker, budget)` | Retry with a typed user pointer | No | Not needed |
| `Options` | Clock, generator, `on_retry` callback, breaker and budget for `run` | No | Not needed |
| `Clock`, `system_clock`, `clock_now`, `clock_sleep` | Injectable time source | No | Not needed |
| `Fake_Clock`, `fake_clock`, `fake_clock_advance` | Clock for tests that never blocks | No | Not needed |
| `classify`, `classify_except`, `classify_proc` | Map an error value to a `Retry_Decision` | No | Not needed |
| `Circuit_Breaker`, `Breaker_Config`, `default_breaker_config` | Fail fast while a dependency is down | No | Not needed |
| `breaker_init`, `breaker_allow`, `breaker_record_success`, `breaker_record_failure` | Drive a breaker by hand | No | Not needed |
| `breaker_state`, `breaker_retry_after`, `breaker_trip`, `breaker_reset` | Inspect or force the breaker state | No | Not needed |
| `Budget`, `budget_init`, `budget_child` | Cap the total time of a request | No | Not needed |
| `budget_remaining`, `budget_elapsed`, `budget_expired`, `budget_timeout` | Read what is left of a budget | No | Not needed |
| `Error` | Union of `Policy_Error`, `Retry_Error`, `Breaker_Error` and `Budget_Error` | No | Not needed |

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic      # exponential backoff and the Backoff iterator
odin run examples/resilient  # classification, circuit breaker and budget
```

## Design notes

- The package never allocates, so there is nothing to free and no allocator parameter.
- Fallible procedures return `Error`. The library never panics on bad input: invalid policies, nil operations and unknown decisions all come back as error values.
- Delay arithmetic saturates at the cap, or at the largest `time.Duration` when there is no cap, instead of overflowing.
- The runner uses the name `run` because `do` is a keyword in Odin.
- The package keeps no global mutable state. A `Backoff`, `Budget` or `Fake_Clock` is safe to use from one thread at a time. A `Circuit_Breaker` locks an internal mutex, so threads can share it, but don't copy it after `breaker_init`.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
