// Package sys is the little of the OS that shared code needs beyond
// core:os and core:sync: threads with a plain C entry point, the local
// time of day, the page size, read-only file mappings and the user's
// locale. Each OS has its own file. Code that is only for one OS stays in
// that OS's files of its own package.
package sys

// Thread_Proc is a thread's entry point, in the shape pthread_create takes.
Thread_Proc :: proc "c" (arg: rawptr) -> rawptr

// Local_Time is a moment in the user's time zone. month is 1 for January.
Local_Time :: struct {
	year, month, day:     int,
	hour, minute, second: int,
}
