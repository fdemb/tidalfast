package app

import "../render"

// The shell puts a blurred view of the desktop behind the window. The frame
// clears to transparent, the rest draws opaque over it, and the player bar
// tints the blur.
FRAME_CLEAR :: render.Color{}
GLASS_BG :: render.Color{PANEL.r, PANEL.g, PANEL.b, 0.3}
