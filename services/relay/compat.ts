// Documented exception: calendar/desired date is 2026-10-20, but installed
// workerd 1.20261006.1 rejects any date after 2026-10-13 with ERR_RUNTIME_FAILURE.
export const COMPATIBILITY_DATE = "2026-10-13";

// Not date-default: must be explicit for Request.signal disconnect propagation.
export const COMPATIBILITY_FLAGS = ["enable_request_signal"] as const;
