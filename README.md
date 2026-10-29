# retry

[![CI](https://github.com/alexisbcz/odin-retry/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-retry/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Retry network and IO calls with constant, linear or exponential backoff and jitter, in the spirit of Go's `cenkalti/backoff`. You can inject the clock and the random generator, so tests run instantly and give the same result every time.

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

A `Policy` computes the delay before retry `n`, counting from 0, as `initial * multiplier^n + increment * n`. It caps that delay at `max` and then applies the jitter. A zero `max`, `max_attempts` or `max_elapsed` means no limit.

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

`max_attempts` counts every attempt, the first one included. `max_elapsed` stops before a delay that would end after that much time since the start, so a run never sleeps past its deadline.

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
| `run_typed(policy, op, user, on_retry, clock, rng)` | Retry with a typed user pointer | No | Not needed |
| `Options` | Clock, generator and `on_retry` callback for `run` | No | Not needed |
| `Clock`, `system_clock`, `clock_now`, `clock_sleep` | Injectable time source | No | Not needed |
| `Fake_Clock`, `fake_clock`, `fake_clock_advance` | Clock for tests that never blocks | No | Not needed |
| `Error` | Union of `Policy_Error` and `Retry_Error` | No | Not needed |

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
```

## Design notes

- The package never allocates, so there is nothing to free and no allocator parameter.
- Fallible procedures return `Error`. The library never panics on bad input: invalid policies, nil operations and unknown decisions all come back as error values.
- Delay arithmetic saturates at the cap, or at the largest `time.Duration` when there is no cap, instead of overflowing.
- The runner uses the name `run` because `do` is a keyword in Odin.
- The package keeps no global mutable state. A `Backoff` or `Fake_Clock` is safe to use from one thread at a time.

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
