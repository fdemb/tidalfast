package tidal_tests

// local_time asks Windows for the system's time zone, which only an
// administrator can change, so TZ doesn't reach it.
CAN_SET_TIME_ZONE :: false

// SetEnvironmentVariableW with "" deletes the variable.
CAN_SET_EMPTY_ENV :: false

reset_time_zone :: proc() {}
