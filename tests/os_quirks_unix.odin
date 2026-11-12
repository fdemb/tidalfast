#+build darwin, linux
package tidal_tests

import "core:sys/posix"
import "core:testing"

// The TZ variable sets the time zone that local_time uses.
CAN_SET_TIME_ZONE :: true

// A variable can be set to "" and stay set.
CAN_SET_EMPTY_ENV :: true

reset_time_zone :: proc() {
	posix.tzset()
}

// The runner's signal handler already keeps a test's thread on an assert
// until the runner stops it.
hold_on_assert :: proc(t: ^testing.T) {}
