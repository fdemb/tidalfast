# Text input

## The text field

`ui.text_field(id, &field, placeholder, width, height)` is a single-line text field. Its state is a `ui.Text_Field` the app keeps: up to 256 bytes of UTF-8 in a fixed buffer, the cursor and the selection's anchor, the input method's marked text and the undo stacks. It's plain data, so it survives a hot reload, and `edit.odin` holds the editing on its own, which the tests drive without a window.

Every offset is a byte offset on a grapheme cluster boundary. The boundaries come from `text.grapheme_starts`, the same segmentation the renderer uses, so Backspace removes a whole 가, a whole jamo syllable, a ZWJ family or a flag with its two regional indicators, and an Arabic letter with its marks. The one exception is a replacement range from the input method, which the field takes by codepoint as the shell's mirror does (see below), so an input method that replaces part of a cluster leaves the cursor inside it. kb_text_shape broke before the last pictograph of a ZWJ sequence (👨‍👩‍ and 👧), so `grapheme_starts` now joins them as rule GB11 says, which fixes truncation of such titles too.

With the focus, the field takes:

- Left and Right by cluster, Option by word, Command to either end (`ui.WORD` and `ui.LINE`, per OS like `ui.PRIMARY`), and Up, Down, Home and End to either end. Shift extends the selection. Word movement skips separators, then goes over letters and digits.
- Backspace and Delete by cluster, Option by word, Command to the end of the line.
- Cmd-A, Cmd-C, Cmd-X, Cmd-V, Cmd-Z and Shift-Cmd-Z, Control-A and Control-E.
- Clicks: one places the cursor (Shift extends), two select a word, three select everything, and dragging selects by cluster, or by word after a double-click.
- Return reports `submitted`. Escape clears the text, and a second Escape gives up the focus.

Undo keeps whole snapshots, 32 deep. Typing right after typing joins one step, and so do Backspaces in a row and Deletes in a row. Moving the cursor or clicking ends the step, and cut, paste and word or line deletes are steps of their own. A composition belongs to the step of the typing before it.

Pasted and typed text becomes one line: a run of line breaks and tabs (LF, CR, tab, NEL, U+2028, U+2029) becomes one space, or none at the start of the text, and the other C0 and C1 controls, DEL, U+FFFD and invalid UTF-8 go. A paste that doesn't fit is cut at a cluster boundary. Text from the input method that doesn't fit goes in whole or not at all.

Keys, text and focus changes reach the field in the order they came, even within one frame. Text typed before a Tab goes in, though the field has lost the focus by the time it's built. After Escape gives up the focus, the frame's text goes nowhere unless something gives the focus back. `ui.focus_shortcut(box, key, modifiers)` makes a key give a field the focus with its text selected, at its place among the events, so Cmd-F followed by typing in the same frame replaces the text. `Field_Signal.submitted_text` is the text when Return was pressed.

The field draws its insides as floating boxes: the selection, the text moved left by `scroll` to keep the caret in view, the marked text's underline (thin under the composition, thick under the clause the input method has selected) and the caret. Positions come from the shaped run. Each cluster's left and right edge is the extent of its glyphs. A cluster without a glyph of its own, as inside a ligature, shares the one before it. A cluster reads right to left when the next cluster sits to its left. The caret goes on a cluster's leading edge, so mixed Arabic and Latin text draws with bidi while the cursor moves in logical order.

The caret blinks every 0.53 s through `ui.wake_at`, only while the window has the keyboard (`Frame_Input.key_window`). Without the keyboard it's hidden and asks for no frames.

## Keys, text and the input method

While a text field has the focus, the UI keeps Return, Space, the arrows and Escape for it instead of clicking or moving the focus. Tab still moves the focus.

The shell's view is an `NSTextInputClient`. After each frame the app tells the shell about the focused field through `Shell.set_text_input`: its text, selection and marked range in bytes, and a rect for the marked text or the caret, or nil when no field has the focus. It sends changes, and it also sends the state after the field takes text or marked text from the shell, even if nothing changed. While a field has the focus, `keyDown` goes through the view's input context:

- Text it inserts (`insertText`) reaches the app as a `Text` event, and the key doesn't.
- Marked text (`setMarkedText`, `unmarkText`) reaches it as `Marked_Text` and `Unmark_Text` events, and the key doesn't. While there is marked text every key belongs to the input method.
- Keys it turns into commands (arrows, Delete, Return, Escape, Tab) reach the app as key events, which the field handles. So do Command shortcuts, which skip the input context.

Event text lives in a byte buffer that comes with the frame's events (`Frame_Input.text`). A text event carries an offset and length into it, and an optional replacement range in bytes, as when the accent menu replaces the letter typed before it.

Input methods ask questions synchronously, often right after `setMarkedText` and before the app has had a frame. So the shell keeps a mirror of the field, applies every edit it sends on to the mirror too, and answers `selectedRange`, `markedRange`, `hasMarkedText` and `attributedSubstringForProposedRange` from it. It converts between the app's UTF-8 bytes and AppKit's UTF-16 units and never lands between a surrogate pair's halves. The mirror and the field have to make the same edit, but Cocoa's composed character sequences and the app's grapheme clusters differ, so they use rules that need no segmentation:

- Text is cleaned byte for byte the same way: `field_sanitize` in the shell, `sanitize` in `src/ui/edit.odin`. Both decode UTF-8 the way Odin's `utf8.decode_rune` does, dropping an invalid sequence a byte at a time. `test_edit_sanitize_table` holds the outputs the shell printed for the same inputs (`clean=` below).
- A replacement range is clamped to the text and each end moved back to the start of its codepoint. The input method's selection inside marked text is clamped to the cleaned text and moved back the same way.
- If the cleaned text doesn't fit the limit (`Text_Input.limit`, in bytes) in place of the range, the whole edit is refused. A refused `setMarkedText` changes nothing. A refused `insertText` ends the composition as it was, as `unmarkText` does.

So with the search field at 115 of 119 bytes, marking "a‍👩" (8 bytes) changes neither, and a commit after it goes where the caret was. The app's next state replaces the mirror after every edit anyway. `firstRectForCharacterRange` returns the marked text's rect in screen coordinates, so the candidate window opens under the composition. When the app ends a composition itself, as when the field loses the focus, the shell calls `discardMarkedText` so the input method forgets it.

The clipboard goes through `Shell.set_clipboard` and `Shell.get_clipboard`, which use `NSPasteboard`. `ui.copy_to_clipboard` puts a string on it from anywhere in the UI.

## Platform ABI version 3

- `Event` grew to 88 bytes: text offset and length, a replacement range, the input method's selection inside marked text, and a `target` node id. New kinds: `Text`, `Marked_Text`, `Unmark_Text`, `Access_Press` and `Access_Focus`.
- `Frame_Input` (48 bytes) carries the text buffer and whether the window is key.
- `Frame_Result` (8 bytes) has `wake_after`.
- `Shell` (64 bytes) adds `set_text_input`, `set_clipboard`, `get_clipboard` and `set_accessibility`.
- New structs: `Text_Input` (48 bytes) and `Access_Node` (56 bytes). `Text_Input.limit` took the place of a padding field, so a shell or app that leaves it 0 means no limit, and the version stays 3.

## Platform ABI version 6

Version 6 takes the macOS-only parts out of the ABI, so a shell for another OS can fill the same structs.

- `Event.key` is a `Key`: keys by their place on a US keyboard, which the shell maps its own key codes to. It took the place of `key_code`, which held macOS virtual key codes. Keys outside the enum arrive as `None`. `Event.media` holds the `Media_Command` in what was a padding byte, so `Event` stays 88 bytes. `platform.h` and `platform.odin` both check that `Key` has 65 values.
- The modifiers are `Shift`, `Control`, `Alt` and `Super`, with the same bits as before. Alt is Option and Super is Command on macOS.
- `Frame_Input` (56 bytes) adds `mouse_buttons`, the buttons held down in any app, which the UI used to ask CoreGraphics for itself.
- `Shell` (56 bytes) has one `surface` in place of `metal_device` and `metal_layer`. On macOS it is the `CAMetalLayer`, set up by the shell, and the Metal backend takes the device from it. On Linux it points to a `Wayland_Surface` (16 bytes): the `wl_display` and the `wl_surface`, which the Vulkan backend makes its `VkSurfaceKHR` from. `Wayland_Surface` isn't part of `Shell`, so adding it didn't change the version.
