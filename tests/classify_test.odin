package retry_tests

import retry ".."
import "core:testing"

Net_Error :: enum {
	None,
	Timeout,
	Connection_Reset,
	Bad_Request,
	Not_Found,
}

TRANSIENT :: []Net_Error{.Timeout, .Connection_Reset}
FATAL :: []Net_Error{.Bad_Request, .Not_Found}

@(test)
test_classify_zero_value_is_success :: proc(t: ^testing.T) {
	testing.expect_value(t, retry.classify(Net_Error.None, TRANSIENT), retry.Retry_Decision.Success)
	testing.expect_value(t, retry.classify_except(Net_Error.None, FATAL), retry.Retry_Decision.Success)
}

@(test)
test_classify_listed_errors_retry :: proc(t: ^testing.T) {
	testing.expect_value(t, retry.classify(Net_Error.Timeout, TRANSIENT), retry.Retry_Decision.Retry)
	testing.expect_value(t, retry.classify(Net_Error.Connection_Reset, TRANSIENT), retry.Retry_Decision.Retry)
}

@(test)
test_classify_unlisted_errors_are_permanent :: proc(t: ^testing.T) {
	testing.expect_value(t, retry.classify(Net_Error.Bad_Request, TRANSIENT), retry.Retry_Decision.Permanent)
	testing.expect_value(t, retry.classify(Net_Error.Timeout, []Net_Error{}), retry.Retry_Decision.Permanent)
}

@(test)
test_classify_handles_values_outside_the_enum :: proc(t: ^testing.T) {
	testing.expect_value(t, retry.classify(Net_Error(42), TRANSIENT), retry.Retry_Decision.Permanent)
	testing.expect_value(t, retry.classify_except(Net_Error(42), FATAL), retry.Retry_Decision.Retry)
}

@(test)
test_classify_except_inverts_the_list :: proc(t: ^testing.T) {
	testing.expect_value(t, retry.classify_except(Net_Error.Timeout, FATAL), retry.Retry_Decision.Retry)
	testing.expect_value(t, retry.classify_except(Net_Error.Not_Found, FATAL), retry.Retry_Decision.Permanent)
	testing.expect_value(t, retry.classify_except(Net_Error.Not_Found, nil), retry.Retry_Decision.Retry)
}

is_transient_code :: proc(code: i32) -> bool {
	return code == 4 || code == 35
}

@(test)
test_classify_proc_uses_predicate :: proc(t: ^testing.T) {
	testing.expect_value(t, retry.classify_proc(i32(0), is_transient_code), retry.Retry_Decision.Success)
	testing.expect_value(t, retry.classify_proc(i32(35), is_transient_code), retry.Retry_Decision.Retry)
	testing.expect_value(t, retry.classify_proc(i32(2), is_transient_code), retry.Retry_Decision.Permanent)
}

@(test)
test_classify_proc_nil_predicate_is_permanent :: proc(t: ^testing.T) {
	pred: proc(code: i32) -> bool
	testing.expect_value(t, retry.classify_proc(i32(35), pred), retry.Retry_Decision.Permanent)
	testing.expect_value(t, retry.classify_proc(i32(0), pred), retry.Retry_Decision.Success)
}

@(test)
test_classify_works_with_strings :: proc(t: ^testing.T) {
	transient := []string{"EAGAIN", "ETIMEDOUT"}
	testing.expect_value(t, retry.classify("", transient), retry.Retry_Decision.Success)
	testing.expect_value(t, retry.classify("ETIMEDOUT", transient), retry.Retry_Decision.Retry)
	testing.expect_value(t, retry.classify("ENOENT", transient), retry.Retry_Decision.Permanent)
}
