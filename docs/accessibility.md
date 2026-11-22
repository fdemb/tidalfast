# Accessibility

Boxes say what assistive apps should see with `ui.accessible(box, role, label, value)`. `ui.button`, menus and menu items do it themselves. `end_frame` walks the tree after layout and flattens every box with a role into a list of `Access_Node`s, parents first, with their clipped rects, focus and selection. A box clipped away, and everything inside a clipping box clipped away, stays out, so the virtualized track table only ever gives the rows in view. Keyed boxes use their key as the node id. The rest get one from their parent's id and their place among its nodes, which stays put while the tree does. The app hashes the list and calls `Shell.set_accessibility` only when the hash changes.

What's exposed: the search field (`AXTextField` with the text as its value), the sidebar (`AXList` of `AXRow`s), the track table (`AXTable` whose `AXRow`s are labelled "title, artist, album" and hold one `AXStaticText` each, and the "More options for title" button that opens the track menu, on the selected row), the search tabs and the found lists, the artist page (the name and biography as `AXStaticText`, Play, Shuffle, Follow or Following, Share, More and the biography's Read more as buttons, the five top tracks as an `AXTable` labelled "Top tracks", each shelf as an `AXList` named by its title with its cards as buttons labelled "title, subtitle", and the shelf's page and View all buttons, such as "Next page of Albums" and "View all Albums"), a shelf's grid, the headings, the status bar when `TIDALFAST_STATUS_BAR` is set, the player bar's buttons, links and three sliders (Position, Volume and the sidebar's width) with their values, the login screen's buttons, and context menus, each named by what it's for (`ui.menu`'s `name`: the song's title, the list's, Sleep timer, Output). A menu item drawn with a mark before it, such as the sleep timer's choices and Bit-perfect output, is named without the mark and is selected when chosen; the search tabs and the settings' choices are selected the same way. The output menu's signal path and its line about it are static text.

The shell copies the nodes. It makes `NSAccessibilityElement`s from them only once an assistive app has asked the view for its children or hit-tested it, and after every change from then on. So without VoiceOver running a changed tree costs one copy. Only the macOS shell hands the tree to assistive apps. The Linux and Windows shells keep it only while `TIDALFAST_SHELL_TEST` is set, for its `ax-dump` and `ax-press` steps; AT-SPI and UI Automation aren't done. Elements are kept by node id, so VoiceOver stays on an element while it moves or changes, and frames are turned into screen coordinates when asked for. After a change the shell posts a layout change, a focus change when the focused node is a new one, and a value change for a focused text field. AXPress on a button, row or menu item comes to the app as an `Access_Press` event, which the UI treats as a keyboard click: buttons click, sidebar rows open their playlist and track rows play. Setting the focus comes as `Access_Focus`.

## Rules the tree keeps

`tests/access_tree_test.odin` builds every page and overlay of the fake library (the list with a song playing and a row selected, the track menu and its playlist chooser, the output, sleep timer and user menus, a playlist's More menu, the question before a delete, the rename and new playlist fields, an album, an artist's page and grid, Home, Settings, the search page and each of its tabs, a tooltip and the toast) and checks each node:

- a button, text field, row, menu, menu item, slider, list or table has a name, which isn't an id (`##`), holds no icon glyph from the private use area and has no space around it, as an unchecked mark's padding would leave;
- a button, row or menu item, which an assistive app can press, is a keyed, clickable box, so the press reaches it;
- a slider has a value;
- a control that isn't disabled is focusable or inside a focusable box, such as a row in the table, so the keyboard reaches it (the window's own buttons are left out of Tab order, as the system's are);
- no node is in the tree twice or has no size, and no two nodes under one parent share a role and name, rows aside;
- every focusable box on screen, not see-through, is in the tree.

So a control added without a name, or out of the keyboard's reach, fails there. `tests/keyboard_test.odin` walks the same screens with Tab, the arrows, Enter and Escape.

The macOS shell doesn't take AXIncrement and AXDecrement yet, so VoiceOver's own slider gestures do nothing; with the keyboard focus on a slider, the arrow keys move it.

## Checking it

There is no human or VoiceOver in the loop here, so the checks run the shell's own entry points:

```
./build/mock_tidal -port=8787
TIDALFAST_API=http://127.0.0.1:8787 TIDALFAST_KEYCHAIN=tidalfast-p7-test TIDALFAST_AUDIO_NULL=1 \
    TIDALFAST_CAPTURE=/tmp/cap.tga \
    TIDALFAST_SHELL_TEST="10:key=cmd+f;10.5:mark=にほんご;11.2:ime;11.3:capture=/tmp/marked.tga;12:commit=日本語;14:capture=/tmp/results.tga;14.5:ax-dump;15:ax-press=日本語 1,;16.5:quit" \
    ./build/tidalfast
security delete-generic-password -s tidalfast-p7-test
```

The mock approves the login after about 3 s. `ime` printed `text "にほんご", marked {0, 4}, selected {4, 0}` and a rect under the field. After the commit the app logged `search: "日本語"`, the mock answered 50 of 120 tracks, and the second page came as a tracks-only search at offset 50. `ax-dump` listed the `AXTextField` with the value 日本語, the playlists list, the search tabs as buttons, the table with seven rows of title, artist and album, and the player's Previous, Play and Next buttons. `ax-press` on the first row played it.

An `AXUIElementCreateApplication` walk from another process needs the Accessibility permission, which the environment this was built in doesn't grant (`AXIsProcessTrusted` returns false). `ax-dump` reads the tree in process instead, from the window down through AppKit's NSAccessibility calls, the same path an assistive app's requests take.
