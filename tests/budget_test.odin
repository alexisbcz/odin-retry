package retry_tests

import retry ".."
import "core:testing"
import "core:time"

@(test)
test_budget_zero_value_is_unlimited :: proc(t: ^testing.T) {
	b: retry.Budget
	testing.expect(t, !retry.budget_expired(b))
	testing.expect_value(t, retry.budget_remaining(b), time.Duration(max(i64)))
	testing.expect_value(t, retry.budget_elapsed(b), 0)
	testing.expect_value(t, retry.budget_timeout(b, time.Second), time.Second)
}

@(test)
test_budget_counts_down_with_clock :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	fc.now = time.Hour // A non-zero origin proves the budget measures from init.
	b: retry.Budget
	testing.expect_value(t, retry.budget_init(&b, time.Second, retry.fake_clock(&fc)), nil)
	testing.expect_value(t, retry.budget_remaining(b), time.Second)
	retry.fake_clock_advance(&fc, 300 * MS)
	testing.expect_value(t, retry.budget_elapsed(b), 300 * MS)
	testing.expect_value(t, retry.budget_remaining(b), 700 * MS)
	testing.expect(t, !retry.budget_expired(b))
}

@(test)
test_budget_expires_and_never_goes_negative :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	b: retry.Budget
	_ = retry.budget_init(&b, time.Second, retry.fake_clock(&fc))
	retry.fake_clock_advance(&fc, time.Second)
	testing.expect(t, retry.budget_expired(b))
	retry.fake_clock_advance(&fc, time.Hour)
	testing.expect_value(t, retry.budget_remaining(b), 0)
	testing.expect_value(t, retry.budget_timeout(b, time.Second), 0)
}

@(test)
test_budget_zero_total_is_already_spent :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	b: retry.Budget
	testing.expect_value(t, retry.budget_init(&b, 0, retry.fake_clock(&fc)), nil)
	testing.expect(t, retry.budget_expired(b))
}

@(test)
test_budget_rejects_negative_total :: proc(t: ^testing.T) {
	b: retry.Budget
	err := retry.budget_init(&b, -time.Second)
	testing.expect_value(t, err, retry.Error(retry.Budget_Error.Negative_Total))
	testing.expect(t, !retry.budget_expired(b), "a failed init leaves the unlimited zero Budget")
}

@(test)
test_budget_timeout_takes_the_smaller_value :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	b: retry.Budget
	_ = retry.budget_init(&b, time.Second, retry.fake_clock(&fc))
	testing.expect_value(t, retry.budget_timeout(b, 200 * MS), 200 * MS)
	testing.expect_value(t, retry.budget_timeout(b, 5 * time.Second), time.Second)
	testing.expect_value(t, retry.budget_timeout(b, 0), time.Second)
	testing.expect_value(t, retry.budget_timeout(b, -MS), time.Second)
	retry.fake_clock_advance(&fc, 900 * MS)
	testing.expect_value(t, retry.budget_timeout(b, 200 * MS), 100 * MS)
}

@(test)
test_budget_child_never_outlives_parent :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	parent: retry.Budget
	_ = retry.budget_init(&parent, time.Second, retry.fake_clock(&fc))
	retry.fake_clock_advance(&fc, 600 * MS)
	child, err := retry.budget_child(parent, time.Second)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, retry.budget_remaining(child), 400 * MS)
	small, _ := retry.budget_child(parent, 100 * MS)
	testing.expect_value(t, retry.budget_remaining(small), 100 * MS)
}

@(test)
test_budget_child_of_unlimited_parent :: proc(t: ^testing.T) {
	fc: retry.Fake_Clock
	parent: retry.Budget
	parent.clock = retry.fake_clock(&fc)
	child, err := retry.budget_child(parent, 250 * MS)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, retry.budget_remaining(child), 250 * MS)
	retry.fake_clock_advance(&fc, 250 * MS)
	testing.expect(t, retry.budget_expired(child))
}

@(test)
test_budget_child_rejects_negative_total :: proc(t: ^testing.T) {
	parent: retry.Budget
	_, err := retry.budget_child(parent, -MS)
	testing.expect_value(t, err, retry.Error(retry.Budget_Error.Negative_Total))
}
