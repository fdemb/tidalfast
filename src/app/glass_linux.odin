package app

// No glass behind the window here, see glass_darwin.odin.
FRAME_CLEAR :: CLEAR_COLOR
GLASS_BG :: PANEL
SEARCH_BG :: SURFACE

SIDEBAR_ROWS :: Row_Colors {
	selected       = {0x27 / 255.0, 0x27 / 255.0, 0x27 / 255.0, 1},
	hover          = {0x20 / 255.0, 0x20 / 255.0, 0x20 / 255.0, 1},
	selected_hover = {0x2e / 255.0, 0x2e / 255.0, 0x2e / 255.0, 1},
}
