package retry

import "core:sync"
import "core:time"

// Breaker_State is the position of a Circuit_Breaker.
Breaker_State :: enum {
	// Closed lets every call through and counts consecutive failures.
	Closed,
	// Open rejects every call until `open_timeout` has passed since it opened.
	Open,
	// Half_Open lets a few trial calls through to probe whether the dependency has recovered.
	Half_Open,
}

// Breaker_Error lists the ways a Breaker_Config can be invalid. breaker_init returns it.
Breaker_Error :: enum {
	None,
	// failure_threshold is less than 1.
	Invalid_Failure_Threshold,
	// open_timeout is negative.
	Negative_Open_Timeout,
	// half_open_max is negative.
	Negative_Half_Open_Max,
	// success_threshold is negative.
	Negative_Success_Threshold,
}

// Breaker_State_Change_Proc is called each time a Circuit_Breaker moves from `from` to `to`. `user` is Breaker_Config.user.
Breaker_State_Change_Proc :: #type proc(user: rawptr, from, to: Breaker_State)

/*
Breaker_Config tunes a Circuit_Breaker. default_breaker_config fills in
reasonable values.
*/
Breaker_Config :: struct {
	// failure_threshold is the number of consecutive failures that opens a closed breaker. At least 1.
	failure_threshold: int,
	// open_timeout is how long an open breaker rejects calls before it lets trial calls through. Zero moves to half-open at once.
	open_timeout:      time.Duration,
	// half_open_max is how many trial calls may be in flight while half-open. Zero means 1.
	half_open_max:     int,
	// success_threshold is how many trial calls must succeed in a row to close the breaker again. Zero means 1.
	success_threshold: int,
	/*
	on_state_change, when set, is called on every transition. It runs while the
	breaker holds its lock, so it must not call back into the same breaker.
	*/
	on_state_change:   Breaker_State_Change_Proc,
	// user is passed unchanged to on_state_change.
	user:              rawptr,
}

// DEFAULT_FAILURE_THRESHOLD is the failure_threshold of default_breaker_config.
DEFAULT_FAILURE_THRESHOLD :: 5
// DEFAULT_OPEN_TIMEOUT is the open_timeout of default_breaker_config.
DEFAULT_OPEN_TIMEOUT :: 30 * time.Second

// default_breaker_config returns a config that opens after 5 consecutive failures and probes again after 30 seconds.
default_breaker_config :: proc() -> Breaker_Config {
	return Breaker_Config {
		failure_threshold = DEFAULT_FAILURE_THRESHOLD,
		open_timeout = DEFAULT_OPEN_TIMEOUT,
		half_open_max = 1,
		success_threshold = 1,
	}
}

// breaker_config_validate reports the first problem with `c`, or `.None`.
breaker_config_validate :: proc(c: Breaker_Config) -> Breaker_Error {
	switch {
	case c.failure_threshold < 1:
		return .Invalid_Failure_Threshold
	case c.open_timeout < 0:
		return .Negative_Open_Timeout
	case c.half_open_max < 0:
		return .Negative_Half_Open_Max
	case c.success_threshold < 0:
		return .Negative_Success_Threshold
	}
	return .None
}

/*
Circuit_Breaker stops calls to a failing dependency for a while, so that it can
recover and callers fail fast instead of piling up.

It starts closed. After `failure_threshold` consecutive failures it opens and
breaker_allow returns false. Once `open_timeout` has passed it turns half-open
and lets up to `half_open_max` trial calls through. A failed trial opens it
again; `success_threshold` successful trials in a row close it.

Prepare it with breaker_init. Before each call, ask breaker_allow; after each
allowed call, report the outcome with breaker_record_success or
breaker_record_failure. run does all of this for you when you set
Options.breaker.

A Circuit_Breaker owns no memory. It holds a mutex, so you can share one value
between threads, but you must not copy it after breaker_init.
*/
Circuit_Breaker :: struct {
	config:      Breaker_Config,
	clock:       Clock,
	mutex:       sync.Mutex,
	state:       Breaker_State,
	// failures counts consecutive failures while closed.
	failures:    int,
	// successes counts consecutive successful trials while half-open.
	successes:   int,
	// in_flight counts trial calls allowed while half-open and not yet recorded.
	in_flight:   int,
	opened_at:   time.Duration,
	// opened counts how many times the breaker has opened since breaker_init.
	opened:      int,
	initialized: bool,
}

/*
breaker_init prepares `cb` as a closed breaker.

Inputs:
- cb: the breaker to prepare; any previous state is discarded.
- config: the thresholds and timeout; it is copied.
- clock: measures `open_timeout`. The zero Clock is the system clock.

Returns:
- err: a Breaker_Error when `config` is invalid. `cb` is then left
  uninitialized, and an uninitialized breaker allows every call.
*/
breaker_init :: proc(cb: ^Circuit_Breaker, config: Breaker_Config, clock: Clock = {}) -> (err: Error) {
	cb^ = {}
	if berr := breaker_config_validate(config); berr != .None {
		return berr
	}
	cb.config = config
	if cb.config.half_open_max == 0 {
		cb.config.half_open_max = 1
	}
	if cb.config.success_threshold == 0 {
		cb.config.success_threshold = 1
	}
	cb.clock = clock
	cb.initialized = true
	return nil
}

/*
breaker_allow reports whether a call may go ahead now.

While half-open, a true result reserves one of the `half_open_max` trial
slots, so every allowed call must be followed by exactly one
breaker_record_success or breaker_record_failure.
*/
breaker_allow :: proc(cb: ^Circuit_Breaker) -> bool {
	if !cb.initialized {
		return true
	}
	sync.mutex_guard(&cb.mutex)
	refresh(cb)
	switch cb.state {
	case .Closed:
		return true
	case .Open:
		return false
	case .Half_Open:
		if cb.in_flight >= cb.config.half_open_max {
			return false
		}
		cb.in_flight += 1
		return true
	}
	return false
}

/*
breaker_record_success reports that an allowed call succeeded. A closed breaker
forgets its failure count; a half-open one moves closer to closing.
*/
breaker_record_success :: proc(cb: ^Circuit_Breaker) {
	if !cb.initialized {
		return
	}
	sync.mutex_guard(&cb.mutex)
	switch cb.state {
	case .Closed:
		cb.failures = 0
	case .Open:
	// A late result from before the breaker opened; ignore it.
	case .Half_Open:
		release_trial(cb)
		cb.successes += 1
		if cb.successes >= cb.config.success_threshold {
			transition(cb, .Closed)
		}
	}
}

/*
breaker_record_failure reports that an allowed call failed in a way that says
the dependency is unhealthy. A closed breaker opens on reaching
`failure_threshold`; a half-open one opens at once.
*/
breaker_record_failure :: proc(cb: ^Circuit_Breaker) {
	if !cb.initialized {
		return
	}
	sync.mutex_guard(&cb.mutex)
	switch cb.state {
	case .Closed:
		cb.failures += 1
		if cb.failures >= cb.config.failure_threshold {
			transition(cb, .Open)
		}
	case .Open:
	// A late result from before the breaker opened; ignore it.
	case .Half_Open:
		release_trial(cb)
		transition(cb, .Open)
	}
}

/*
breaker_state returns the current state. An open breaker whose `open_timeout`
has passed reports, and becomes, `.Half_Open`. An uninitialized breaker reports
`.Closed`.
*/
breaker_state :: proc(cb: ^Circuit_Breaker) -> Breaker_State {
	if !cb.initialized {
		return .Closed
	}
	sync.mutex_guard(&cb.mutex)
	refresh(cb)
	return cb.state
}

/*
breaker_retry_after returns how long an open breaker keeps rejecting calls, or
0 when it isn't open. Use it to fill a `Retry-After` header or to schedule the
next probe.
*/
breaker_retry_after :: proc(cb: ^Circuit_Breaker) -> time.Duration {
	if !cb.initialized {
		return 0
	}
	sync.mutex_guard(&cb.mutex)
	refresh(cb)
	if cb.state != .Open {
		return 0
	}
	return cb.config.open_timeout - (clock_now(cb.clock) - cb.opened_at)
}

/*
breaker_trip opens the breaker at once, whatever its state, for example when a
health check fails. The `open_timeout` starts now.
*/
breaker_trip :: proc(cb: ^Circuit_Breaker) {
	if !cb.initialized {
		return
	}
	sync.mutex_guard(&cb.mutex)
	transition(cb, .Open)
}

// breaker_reset closes the breaker and clears its counters, keeping its config, clock and open count.
breaker_reset :: proc(cb: ^Circuit_Breaker) {
	if !cb.initialized {
		return
	}
	sync.mutex_guard(&cb.mutex)
	transition(cb, .Closed)
}

// refresh moves an open breaker to half-open once its timeout has passed. The caller holds the lock.
@(private = "file")
refresh :: proc(cb: ^Circuit_Breaker) {
	if cb.state == .Open && clock_now(cb.clock) - cb.opened_at >= cb.config.open_timeout {
		transition(cb, .Half_Open)
	}
}

@(private = "file")
release_trial :: proc(cb: ^Circuit_Breaker) {
	if cb.in_flight > 0 {
		cb.in_flight -= 1
	}
}

// transition enters `to`, clears the counters and calls the callback when the state changes. The caller holds the lock.
@(private = "file")
transition :: proc(cb: ^Circuit_Breaker, to: Breaker_State) {
	from := cb.state
	cb.state = to
	cb.failures = 0
	cb.successes = 0
	cb.in_flight = 0
	if to == .Open {
		cb.opened_at = clock_now(cb.clock)
		if from != .Open {
			cb.opened += 1
		}
	}
	if from != to && cb.config.on_state_change != nil {
		cb.config.on_state_change(cb.config.user, from, to)
	}
}
