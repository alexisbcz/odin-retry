# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-10-29

### Fixed

- `run` no longer gives up with `.Circuit_Open` when a failure opens the breaker but the next delay outlasts `open_timeout`. It now sleeps, and the next attempt runs as a half-open trial call. It still fails fast when the breaker would reject that attempt.

## [0.1.1] - 2026-10-29

### Fixed

- Fractional multipliers no longer stall or drift. `Backoff` grew each delay from the previous delay truncated to whole nanoseconds, so a 1-nanosecond delay with multiplier 1.5 stayed at 1 nanosecond forever and long sequences lost up to a nanosecond per step. It now grows the unrounded delay.
- The documented delay formula was wrong when both `multiplier` and `increment` are set. The docs now describe the real rule: each delay is the previous one times `multiplier`, plus `increment`.

### Changed

- The docs now warn that `.Decorrelated` with `initial = 0` always gives 0, that `budget_timeout` returns 0 for a spent budget, and that a shared breaker can count a late result as a trial result.

## [0.1.0] - 2026-10-29

### Added

- `Policy` with `initial`, `max`, `multiplier`, `increment`, `jitter`, `max_attempts` and `max_elapsed`.
- `constant`, `linear` and `exponential` presets, and `policy_validate`.
- `Jitter` modes `.None`, `.Full`, `.Equal` and `.Decorrelated`, following the AWS Architecture Blog.
- `Backoff` iterator with `backoff_init`, `backoff_next` and `backoff_reset`, plus the short names `init`, `next` and `reset`.
- `run` and `run_typed`, which retry an operation, stop early on `.Permanent` and call an optional `on_retry` callback.
- Injectable `Clock`, the never-blocking `Fake_Clock` for tests, and seedable jitter through `math/rand` generators.
- `classify`, `classify_except` and `classify_proc`, which turn error values into retry decisions.
- `Circuit_Breaker` with closed, open and half-open states, trial call limits, `breaker_trip`, `breaker_reset`, `breaker_retry_after` and an `on_state_change` callback.
- `Budget` timeout budgets with `budget_timeout` for per-attempt timeouts and `budget_child` for nested calls.
- `Options.breaker` and `Options.budget`, and matching `run_typed` parameters, so `run` fails fast on an open breaker and never sleeps past a budget.
- `Error` union of `Policy_Error`, `Retry_Error`, `Breaker_Error` and `Budget_Error`.
- `basic` and `resilient` examples.

[Unreleased]: https://github.com/alexisbcz/odin-retry/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/alexisbcz/odin-retry/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/alexisbcz/odin-retry/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexisbcz/odin-retry/releases/tag/v0.1.0
