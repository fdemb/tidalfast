package ui

import "../platform"

// PRIMARY is the modifier of app shortcuts such as copy, undo and find:
// Command on macOS, Control elsewhere.
PRIMARY :: platform.Modifier.Super

// The text field moves and deletes by word with WORD held and to the line's
// ends with LINE.
WORD :: platform.Modifier.Alt
LINE :: platform.Modifier.Super

// Control-A and Control-E go to the line's ends, and Control-click is a
// right click, as everywhere on macOS.
CONTROL_LINE_KEYS :: true
CONTROL_CLICK_IS_RIGHT :: true
