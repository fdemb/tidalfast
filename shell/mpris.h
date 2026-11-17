// Now Playing and media commands on Linux, through MPRIS
// (org.mpris.MediaPlayer2) on the D-Bus session bus. A desktop's media
// keys, its media widget and tools like playerctl talk to the app through
// it. Main thread only.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "platform.h"

// mpris_init takes the procedure the commands go to, which gets a
// Media_Command and, for MEDIA_SEEK, the position in seconds.
void mpris_init(void (*command)(uint32_t command, double position));
// mpris_start connects to the session bus and takes the name
// org.mpris.MediaPlayer2.tidalfast, or one with .instance<pid> after it
// when another instance has that. It doesn't wait for the bus's answers.
// While connected it does nothing, and after a failed or lost connection
// it tries again once 10 s have passed.
void mpris_start(void);
// mpris_set is Shell.set_now_playing. It starts MPRIS if nothing has.
void mpris_set(const Now_Playing *np);
// The socket to poll, and what for, or -1 while not connected.
int mpris_fd(short *events);
// mpris_dispatch reads and answers what came, and sends what waits, after
// a poll said the socket is ready.
void mpris_dispatch(short revents);
// mpris_close disconnects and deletes the artwork's file.
void mpris_close(void);
// The bus name the app took, or NULL before it has one.
const char *mpris_name(void);
