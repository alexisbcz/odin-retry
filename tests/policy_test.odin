package retry_tests

import retry ".."
import "core:math"
import "core:testing"
import "core:time"

@(test)
test_constant_preset_fields :: proc(t: ^testing.T) {
	p := retry.constant(250 * MS, 3)
	testing.expect_value(t, p.initial, 250 * MS)
	testing.expect_value(t, p.multiplier, 1.0)
	testing.expect_value(t, p.increment, 0)
	testing.expect_value(t, p.jitter, retry.Jitter.None)
	testing.expect_value(t, p.max_attempts, 3)
}

@(test)
test_linear_preset_fields :: proc(t: ^testing.T) {
	p := retry.linear(100 * MS, 50 * MS, time.Second)
	testing.expect_value(t, p.initial, 100 * MS)
	testing.expect_value(t, p.increment, 50 * MS)
	testing.expect_value(t, p.max, time.Second)
	testing.expect_value(t, p.multiplier, 1.0)
	testing.expect_value(t, p.max_attempts, retry.DEFAULT_MAX_ATTEMPTS)
}

@(test)
test_exponential_preset_defaults :: proc(t: ^testing.T) {
	p := retry.exponential()
	testing.expect_value(t, p.initial, retry.DEFAULT_INITIAL)
	testing.expect_value(t, p.max, retry.DEFAULT_MAX)
	testing.expect_value(t, p.multiplier, retry.DEFAULT_MULTIPLIER)
	testing.expect_value(t, p.jitter, retry.Jitter.Full)
	testing.expect_value(t, p.max_attempts, retry.DEFAULT_MAX_ATTEMPTS)
	testing.expect_value(t, p.max_elapsed, 0)
}

@(test)
test_presets_are_valid :: proc(t: ^testing.T) {
	testing.expect_value(t, retry.policy_validate(retry.constant(MS)), retry.Policy_Error.None)
	testing.expect_value(t, retry.policy_validate(retry.linear(MS, MS)), retry.Policy_Error.None)
	testing.expect_value(t, retry.policy_validate(retry.exponential()), retry.Policy_Error.None)
}

@(test)
test_validate_accepts_zero_initial_and_no_limits :: proc(t: ^testing.T) {
	p := retry.Policy{multiplier = 1}
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.None)
}

@(test)
test_validate_accepts_no_cap_above_initial :: proc(t: ^testing.T) {
	p := retry.Policy{initial = time.Hour, multiplier = 3}
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.None)
}

@(test)
test_validate_rejects_negative_initial :: proc(t: ^testing.T) {
	p := retry.constant(-MS)
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Negative_Initial)
}

@(test)
test_validate_rejects_negative_max :: proc(t: ^testing.T) {
	p := retry.exponential(max = -time.Second)
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Negative_Max)
}

@(test)
test_validate_rejects_max_below_initial :: proc(t: ^testing.T) {
	p := retry.exponential(initial = time.Second, max = 500 * MS)
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Max_Below_Initial)
}

@(test)
test_validate_rejects_multiplier_below_one :: proc(t: ^testing.T) {
	p := retry.exponential(multiplier = 0.5)
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Invalid_Multiplier)
}

@(test)
test_validate_rejects_zero_policy :: proc(t: ^testing.T) {
	testing.expect_value(t, retry.policy_validate(retry.Policy{}), retry.Policy_Error.Invalid_Multiplier)
}

@(test)
test_validate_rejects_nan_multiplier :: proc(t: ^testing.T) {
	p := retry.exponential(multiplier = math.nan_f64())
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Invalid_Multiplier)
}

@(test)
test_validate_rejects_infinite_multiplier :: proc(t: ^testing.T) {
	p := retry.exponential(multiplier = math.inf_f64(1))
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Invalid_Multiplier)
}

@(test)
test_validate_rejects_negative_increment :: proc(t: ^testing.T) {
	p := retry.linear(MS, -MS)
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Negative_Increment)
}

@(test)
test_validate_rejects_out_of_range_jitter :: proc(t: ^testing.T) {
	p := retry.exponential()
	p.jitter = retry.Jitter(42)
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Invalid_Jitter)
}

@(test)
test_validate_rejects_negative_max_attempts :: proc(t: ^testing.T) {
	p := retry.constant(MS, -1)
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Negative_Max_Attempts)
}

@(test)
test_validate_rejects_negative_max_elapsed :: proc(t: ^testing.T) {
	p := retry.constant(MS)
	p.max_elapsed = -time.Second
	testing.expect_value(t, retry.policy_validate(p), retry.Policy_Error.Negative_Max_Elapsed)
}

@(test)
test_init_rejects_invalid_policy :: proc(t: ^testing.T) {
	b: retry.Backoff
	err := retry.backoff_init(&b, retry.constant(-MS))
	testing.expect_value(t, err, perr(.Negative_Initial))
	_, ok := retry.backoff_next(&b)
	testing.expect(t, !ok, "an unprepared Backoff must not yield delays")
}
