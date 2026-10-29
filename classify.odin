package retry

/*
classify turns an error value into a Retry_Decision with an allow list: the
zero value of `E` is `.Success`, a value in `retryable` is `.Retry`, and any
other value is `.Permanent`.

Use it when only a few errors are known to be transient, for example
timeouts and connection resets, and everything else is a bug or a bad
request.

Example:
	Net_Error :: enum {
		None,
		Timeout,
		Connection_Reset,
		Bad_Request,
	}

	TRANSIENT :: []Net_Error{.Timeout, .Connection_Reset}

	retry.classify(Net_Error.Timeout, TRANSIENT)     // .Retry
	retry.classify(Net_Error.Bad_Request, TRANSIENT) // .Permanent
	retry.classify(Net_Error.None, TRANSIENT)        // .Success
*/
classify :: proc(err: $E, retryable: []E) -> Retry_Decision {
	if err == {} {
		return .Success
	}
	for r in retryable {
		if err == r {
			return .Retry
		}
	}
	return .Permanent
}

/*
classify_except turns an error value into a Retry_Decision with a deny list:
the zero value of `E` is `.Success`, a value in `permanent` is `.Permanent`,
and any other value is `.Retry`.

Use it when most errors are transient and only a few, such as "not found" or
"permission denied", can never succeed.
*/
classify_except :: proc(err: $E, permanent: []E) -> Retry_Decision {
	if err == {} {
		return .Success
	}
	for p in permanent {
		if err == p {
			return .Permanent
		}
	}
	return .Retry
}

/*
classify_proc turns an error value into a Retry_Decision with a predicate: the
zero value of `E` is `.Success`, a value for which `is_retryable` returns true
is `.Retry`, and any other value is `.Permanent`. A nil predicate treats every
error as permanent.

Use it for error types you can't list, such as raw error codes where 0
means success:

Example:
	EINTR :: 4
	EAGAIN :: 35

	is_transient_errno :: proc(code: i32) -> bool {
		return code == EINTR || code == EAGAIN
	}

	retry.classify_proc(i32(EAGAIN), is_transient_errno) // .Retry
	retry.classify_proc(i32(2), is_transient_errno)      // .Permanent
*/
classify_proc :: proc(err: $E, is_retryable: proc(err: E) -> bool) -> Retry_Decision {
	if err == {} {
		return .Success
	}
	if is_retryable != nil && is_retryable(err) {
		return .Retry
	}
	return .Permanent
}
