# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- `Policy` with `initial`, `max`, `multiplier`, `increment`, `jitter`, `max_attempts` and `max_elapsed`.
- `constant`, `linear` and `exponential` presets, and `policy_validate`.
- `Jitter` modes `.None`, `.Full`, `.Equal` and `.Decorrelated`, following the AWS Architecture Blog.
- `Backoff` iterator with `backoff_init`, `backoff_next` and `backoff_reset`, plus the short names `init`, `next` and `reset`.
- `run` and `run_typed`, which retry an operation, stop early on `.Permanent` and call an optional `on_retry` callback.
- Injectable `Clock`, the never-blocking `Fake_Clock` for tests, and seedable jitter through `math/rand` generators.
- `Error` union of `Policy_Error` and `Retry_Error`.

[Unreleased]: https://github.com/alexisbcz/odin-retry/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-retry/releases/tag/v0.1.0
