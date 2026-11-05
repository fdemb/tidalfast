#+build linux, darwin
package app

import "core:sys/posix"

// SIGUSR1 from anywhere asks for a snapshot. SA_RESTART, so the signal
// doesn't cut short a read or a request on another thread.
snapshot_signal_start :: proc() {
	act := posix.sigaction_t{sa_handler = snapshot_signal, sa_flags = {.RESTART}}
	posix.sigaction(.SIGUSR1, &act, nil)
}

snapshot_signal_stop :: proc() {
	act := posix.sigaction_t{sa_handler = auto_cast posix.SIG_IGN}
	posix.sigaction(.SIGUSR1, &act, nil)
}

@(private = "file")
snapshot_signal :: proc "c" (_: posix.Signal) {
	err := posix.get_errno()
	snapshot_asked()
	posix.set_errno(err)
}
