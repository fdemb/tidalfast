// Now Playing and media commands on Windows, through the System Media
// Transport Controls: the media overlay that shows with the volume, the
// lock screen, and the media keys while another window has the focus.
// Main thread only.
#pragma once

#include <windows.h>

#include "platform.h"

// The message a button pressed in the controls posts to the window, from a
// thread of Windows' own: wParam is a Media_Command, and lParam the
// position in milliseconds for MEDIA_SEEK.
#define WM_SMTC (WM_APP + 1)

// smtc_set is Shell.set_now_playing for window. The first track sets the
// controls up.
void smtc_set(HWND window, const Now_Playing *np);
// smtc_close takes the app out of the controls.
void smtc_close(void);
