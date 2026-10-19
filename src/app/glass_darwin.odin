package app

import "../render"

// The shell puts a blurred view of the desktop behind the window. The frame
// clears to transparent, the rest draws opaque over it,
// and the sidebar tints the blur.
FRAME_CLEAR :: render.Color{}
GLASS_BG :: render.Color{PANEL.r, PANEL.g, PANEL.b, 0.3}
SEARCH_BG :: render.Color{SURFACE.r, SURFACE.g, SURFACE.b, 0.5}

// White over the glass, so the blur shows through a highlighted row too.
// The alphas give about the solid greys of the other OS over PANEL.
SIDEBAR_ROWS :: Row_Colors {
	selected       = {1, 1, 1, 0.013},
	hover          = {1, 1, 1, 0.007},
	selected_hover = {1, 1, 1, 0.02},
}
