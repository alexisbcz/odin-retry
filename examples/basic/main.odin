// Example basic retries a flaky operation with exponential backoff. Run it with `odin run examples/basic`.
package main

import retry "../.."
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:time"

// Download stands in for a network call that fails twice, then succeeds.
Download :: struct {
	failures_left: int,
	bytes:         int,
}

download :: proc(d: ^Download, attempt: int) -> retry.Retry_Decision {
	if d.failures_left > 0 {
		d.failures_left -= 1
		fmt.printfln("attempt %d: connection reset", attempt)
		return .Retry
	}
	d.bytes = 1024
	fmt.printfln("attempt %d: ok", attempt)
	return .Success
}

log_retry :: proc(d: ^Download, attempt: int, delay: time.Duration) {
	fmt.printfln("  waiting %v before attempt %d", delay, attempt + 1)
}

main :: proc() {
	policy := retry.exponential(initial = 50 * time.Millisecond, max = time.Second, max_attempts = 4)

	// A fixed seed makes the jittered delays the same on every run.
	state := rand.create(7)
	rng := rand.default_random_generator(&state)

	d := Download{failures_left = 2}
	attempts, err := retry.run_typed(policy, download, &d, log_retry, rng = rng)
	if err != nil {
		fmt.eprintln("download failed:", err)
		os.exit(1)
	}
	fmt.printfln("downloaded %d bytes in %d attempts", d.bytes, attempts)

	// The iterator gives the delays without sleeping, for your own loop.
	b: retry.Backoff
	plain := retry.linear(100 * time.Millisecond, 100 * time.Millisecond, max_attempts = 4)
	if init_err := retry.backoff_init(&b, plain); init_err != nil {
		fmt.eprintln("bad policy:", init_err)
		os.exit(1)
	}
	for {
		delay, ok := retry.backoff_next(&b)
		if !ok {
			break
		}
		fmt.println("linear delay:", delay)
	}
	fmt.println("stopped because:", b.stop)
}
