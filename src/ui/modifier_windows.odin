package ui

import "../platform"

// PRIMARY is the modifier of app shortcuts such as copy, undo and find:
// Command on macOS, Control elsewhere.
PRIMARY :: platform.Modifier.Control

// The text field moves and deletes by word with WORD held. Windows has no
// modifier for the line's ends, only Home and End, so LINE is the Windows
// key, which the desktop keeps for itself.
WORD :: platform.Modifier.Control
LINE :: platform.Modifier.Super

// macOS's Control-A and Control-E line moves and Control-click as a right
// click. Neither is a Windows convention: Control-A selects everything.
CONTROL_LINE_KEYS :: false
CONTROL_CLICK_IS_RIGHT :: false
