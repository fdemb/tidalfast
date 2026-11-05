#+build darwin, linux
package tidal_tests

import "core:sys/posix"

// The TZ variable sets the time zone that local_time uses.
CAN_SET_TIME_ZONE :: true

// A variable can be set to "" and stay set.
CAN_SET_EMPTY_ENV :: true

reset_time_zone :: proc() {
	posix.tzset()
}
