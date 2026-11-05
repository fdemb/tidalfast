package app

// Windows has no SIGUSR1. The shell's snapshot test step calls
// snapshot_asked through app_take_snapshot instead.
snapshot_signal_start :: proc() {}

snapshot_signal_stop :: proc() {}

@(export)
app_take_snapshot :: proc "c" () {
	snapshot_asked()
}
