package app

// Making, renaming and deleting the user's own playlists. New playlist,
// the + by Your Library, opens a row with a text field under Liked Songs;
// Rename in the open playlist's More menu puts the same field in its
// sidebar row. Return sends the name; Escape, an empty name or the field
// losing the focus gives up. Delete playlist turns the menu into a
// question that a second press answers. Each goes to TIDAL as a
// Playlist_Job, one at a time, and the row shows the new name greyed until
// it's answered. With the fake data they change the fake sidebar at once.

import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

import "../render"
import "../text"
import "../tidal"
import "../ui"

Playlist_Op :: enum u8 {
	Create,
	Rename,
	Delete,
}

// Playlist_Result is a made playlist as the sidebar lists it, strings in
// the result's arena.
Playlist_Result :: struct {
	item: Sidebar_Item,
}

Edit_Mode :: enum u8 {
	None,
	Create, // the new playlist's row
	Rename, // the row of the playlist id
}

// Playlist_Editor is the sidebar's text field for a playlist's name.
Playlist_Editor :: struct {
	mode:   Edit_Mode,
	id:     Small, // Rename: the playlist's sidebar id, see sidebar_id
	field:  ui.Text_Field,
	focus:  bool, // the field takes the focus when it's next built
	reveal: bool, // scroll the sidebar to the row first
	built:  bool, // the field was built this frame
	back:   ui.Key, // what had the focus before, such as the +, which gets it back once Return or Escape closes the field
	ring:   bool, // back showed its focus ring
}

PLAYLIST_NAME_MAX :: len(Small{}.buf) // what a Playlist_Job carries
EDIT_FIELD_H :: 28
NEW_PLAYLIST_W :: 24
DELETE_MENU :: "delete_playlist_menu"
NEW_PLAYLIST_SEED :: 0x5eed // the new row's placeholder gradient

PLAYLIST_VERBS := [Playlist_Op]string {
	.Create = "create",
	.Rename = "rename",
	.Delete = "delete",
}

// Fake data

FAKE_SIDEBAR_MAX :: 64

// Fake_Playlist is a sidebar entry of the fake data. key stays with it as
// entries come and go, and is its index in PLAYLISTS for the ones there.
Fake_Playlist :: struct {
	name:  Small,
	key:   int,
	owned: bool,
}

Fake_Sidebar :: struct {
	items:    [FAKE_SIDEBAR_MAX]Fake_Playlist, // Liked Songs first
	count:    int,
	next_key: int,
}

// fake_sidebar is the fake data's sidebar, filled from PLAYLISTS the first
// time it's asked for. The mixes TIDAL makes aren't the user's.
fake_sidebar :: proc(d: ^Data) -> ^Fake_Sidebar {
	fs := &d.fake_sidebar
	if fs.count == 0 {
		for name, i in PLAYLISTS {
			fs.items[i] = {
				name  = small(name),
				key   = i,
				owned = i > 4,
			}
		}
		fs.count = len(PLAYLISTS)
		fs.next_key = len(PLAYLISTS)
	}
	return fs
}

// fake_made says whether a fake playlist was made with New playlist.
fake_made :: proc(pl: ^Fake_Playlist) -> bool {
	return pl.key >= len(PLAYLISTS)
}

// fake_tracks is how many songs the sidebar says a fake playlist has.
fake_tracks :: proc(pl: ^Fake_Playlist) -> int {
	switch {
	case pl.key == 0:
		return ROW_COUNT
	case fake_made(pl):
		return 0
	}
	return 20 + pl.key * 37 % 300
}

// fake_key is fake sidebar entry i's key, which the queue and the
// placeholder gradients go by.
fake_key :: proc(s: ^State, i: int) -> int {
	fs := fake_sidebar(&s.data)
	return fs.items[i].key if i >= 0 && i < fs.count else i
}

// Entries

// sidebar_id is sidebar entry i's id: TIDAL's, or the fake data's key as
// text. Liked Songs has none.
sidebar_id :: proc(s: ^State, i: int) -> string {
	if i < 1 || i >= sidebar_count(s) {
		return ""
	}
	if s.data.fake {
		return fmt.tprint(fake_sidebar(&s.data).items[i].key)
	}
	return s.data.sidebar.items[i - 1].id
}

// sidebar_find is the sidebar entry with id, -1 if there's none.
sidebar_find :: proc(s: ^State, id: string) -> int {
	if id == "" {
		return -1
	}
	for i in 1 ..< sidebar_count(s) {
		if sidebar_id(s, i) == id {
			return i
		}
	}
	return -1
}

// playlist_owned says whether sidebar entry i is a playlist the user made,
// which they can rename and delete. Liked Songs, mixes and playlists by
// others aren't.
playlist_owned :: proc(s: ^State, i: int) -> bool {
	if i < 1 || i >= sidebar_count(s) {
		return false
	}
	if s.data.fake {
		return fake_sidebar(&s.data).items[i].owned
	}
	return s.data.sidebar.items[i - 1].owned
}

// open_owned_entry is the sidebar entry the open list is, when it's a
// playlist the user made, or -1.
open_owned_entry :: proc(s: ^State) -> int {
	i := s.library.playlist
	if s.data.fake {
		return i if s.search.fake_source == .None && playlist_owned(s, i) else -1
	}
	v := &s.data.view
	if s.search.browsing || v.source != .Playlist || !playlist_owned(s, i) || sidebar_id(s, i) != small_str(&v.id) {
		return -1
	}
	return i
}

// playlists_editable says whether the sidebar can take a new playlist now:
// it has loaded, and no other playlist edit is out.
playlists_editable :: proc(s: ^State) -> bool {
	d := &s.data
	if d.fake {
		return fake_sidebar(d).count < FAKE_SIDEBAR_MAX
	}
	return d.account == .Signed_In && d.sidebar.loaded && d.playlist_out == nil
}

// Editing

// new_playlist_start opens the new playlist's row with its field focused.
new_playlist_start :: proc(s: ^State) {
	if !playlists_editable(s) {
		return
	}
	e := &s.library.edit
	e^ = {
		mode   = .Create,
		focus  = true,
		reveal = true,
	}
	e.back, e.ring = ui.focus_key()
	e.field.limit = PLAYLIST_NAME_MAX
}

// rename_start puts the field in sidebar entry i's row, holding its name.
rename_start :: proc(s: ^State, i: int) {
	if !playlist_owned(s, i) || s.data.playlist_out != nil {
		return
	}
	e := &s.library.edit
	e^ = {
		mode   = .Rename,
		id     = small(sidebar_id(s, i)),
		focus  = true,
		reveal = true,
	}
	e.back, e.ring = ui.focus_key()
	e.field.limit = PLAYLIST_NAME_MAX
	ui.field_set_text(&e.field, sidebar_entry(s, i).name)
}

// edit_commit sends the field's name, after the frame (pending_apply). An
// empty name, or a rename to the same name, only closes the field.
@(private = "file")
edit_commit :: proc(s: ^State, typed: string) {
	e := s.library.edit
	s.library.edit = {}
	name := strings.trim_space(typed)
	if name == "" {
		return
	}
	switch e.mode {
	case .None:
	case .Create:
		pending_set(s, Playlist_Job{op = .Create, name = small(name)})
	case .Rename:
		id := e.id
		i := sidebar_find(s, small_str(&id))
		if i > 0 && sidebar_entry(s, i).name != name {
			pending_set(s, Playlist_Job{op = .Rename, id = id, name = small(name)})
		}
	}
}

// playlist_edit does a Playlist_Job the frame asked for: on TIDAL, or on
// the fake sidebar at once.
playlist_edit :: proc(s: ^State, job: Playlist_Job) {
	d := &s.data
	if d.fake {
		fake_edit(s, job)
		return
	}
	if d.account != .Signed_In || d.playlist_out != nil {
		return
	}
	d.playlist_out = job
	push_job(d, {payload = job})
}

// playlist_result takes a Playlist_Job's answer. A made playlist goes at
// the top of the sidebar and opens; a deleted one leaves the sidebar, the
// view and the list cache. A failure changes nothing and says so.
playlist_result :: proc(s: ^State, res: ^Result, job: Playlist_Job) {
	d := &s.data
	job := job
	d.playlist_out = nil
	if err, failed := res.err.?; failed {
		verb := PLAYLIST_VERBS[job.op]
		log.warnf("lists: couldn't %s a playlist: %v", verb, err)
		why := small_str(&res.message)
		d.message = small(fmt.tprintf("Couldn't %s the playlist: %s", verb, why) if why != "" else fmt.tprintf("Couldn't %s the playlist", verb))
		return
	}
	id := strings.clone(small_str(&job.id), context.temp_allocator)
	switch job.op {
	case .Create:
		made, _ := res.payload.(Playlist_Result)
		if made.item.id == "" {
			return
		}
		if sidebar_find(s, made.item.id) < 0 {
			sidebar_insert(s, made.item)
		}
		playlist_open(s, sidebar_find(s, made.item.id))
	case .Rename:
		sidebar_rename(s, id, small_str(&job.name))
	case .Delete:
		playlist_removed(s, id)
	}
}

// sidebar_allocator is the sidebar arena's allocator, for strings put in
// it after it came.
@(private = "file")
sidebar_allocator :: proc(d: ^Data) -> mem.Allocator {
	if d.sidebar.arena == nil {
		d.sidebar.arena = arena_new()
	}
	return vmem.arena_allocator(d.sidebar.arena)
}

// sidebar_insert puts a made playlist at the top of the playlists.
@(private = "file")
sidebar_insert :: proc(s: ^State, item: Sidebar_Item) {
	d := &s.data
	sb := &d.sidebar
	a := sidebar_allocator(d)
	items := make([]Sidebar_Item, len(sb.items) + 1, a)
	items[0] = item
	items[0].id = strings.clone(item.id, a)
	items[0].name = strings.clone(item.name, a)
	items[0].image = strings.clone(item.image, a)
	items[0].owned = true
	copy(items[1:], sb.items)
	sb.items = items
	sidebar_moved(s, 1, 1)
	sidebar_save(d)
}

// sidebar_rename gives playlist id its new name in the sidebar and the
// open list.
@(private = "file")
sidebar_rename :: proc(s: ^State, id, name: string) {
	d := &s.data
	if i := sidebar_find(s, id); i > 0 {
		d.sidebar.items[i - 1].name = strings.clone(name, sidebar_allocator(d))
		sidebar_save(d)
	}
	if v := &d.view; v.source == .Playlist && small_str(&v.id) == id {
		v.name = small(name)
	}
}

// playlist_removed takes deleted playlist id out of the sidebar, leaving
// it first if it shows, and out of the list cache. The play queue is a
// copy, so playback goes on; a list it still loads stops loading.
@(private = "file")
playlist_removed :: proc(s: ^State, id: string) {
	d := &s.data
	if i := sidebar_find(s, id); i > 0 {
		playlist_leave(s, i)
		sb := &d.sidebar
		copy(sb.items[i - 1:], sb.items[i:])
		sb.items = sb.items[:len(sb.items) - 1]
		sidebar_moved(s, i, -1)
		sidebar_save(d)
	}
	if q := &d.queued; q.source == .Playlist && small_str(&q.id) == id {
		queued_drop(d)
	}
	if r := &d.refresh; r.source == .Playlist && small_str(&r.id) == id {
		refresh_drop(d)
	}
	if i := lru_find(d, .Playlist, id); i >= 0 {
		lru_drop(d, i)
	}
	disk_push(d, {op = .Delete, source = .Playlist, id = small(id)})
}

// sidebar_moved fixes what goes by a sidebar entry's place after an entry
// came at at (by 1) or went from there (by -1).
@(private = "file")
sidebar_moved :: proc(s: ^State, at, by: int) {
	lib := &s.library
	switch {
	case by < 0 && lib.playlist == at:
		lib.playlist = 0
	case lib.playlist >= at:
		lib.playlist += by
	}
	if lib.status in ADD_STATUSES {
		lib.status = .None // it names a sidebar entry by its place
	}
}

// playlist_open shows sidebar entry i, as a click on it does.
@(private = "file")
playlist_open :: proc(s: ^State, i: int) {
	if i < 0 {
		return
	}
	place := Playlist_Place{index = i}
	history_visit(s, place)
	place_go(s, place)
}

// playlist_leave goes Back from sidebar entry i when it shows, as long as
// Back doesn't go to it again, and to Home otherwise.
@(private = "file")
playlist_leave :: proc(s: ^State, i: int) {
	if !playlist_showing(s, i) {
		return
	}
	h := &s.history
	from := history_from(s)
	if from > 0 && from <= h.count {
		if p, ok := &h.places[from - 1].(Playlist_Place); !ok || playlist_index(s, p) != i {
			history_step(s, -1)
			return
		}
	}
	history_visit(s, Home_Place{})
	place_go(s, Home_Place{})
}

// fake_edit makes, renames or deletes a fake playlist at once.
@(private = "file")
fake_edit :: proc(s: ^State, job: Playlist_Job) {
	fs := fake_sidebar(&s.data)
	job := job
	switch job.op {
	case .Create:
		if fs.count == FAKE_SIDEBAR_MAX {
			return
		}
		copy(fs.items[2:fs.count + 1], fs.items[1:fs.count])
		fs.items[1] = {
			name  = job.name,
			key   = fs.next_key,
			owned = true,
		}
		fs.next_key += 1
		fs.count += 1
		sidebar_moved(s, 1, 1)
		playlist_open(s, 1)
	case .Rename:
		if i := sidebar_find(s, small_str(&job.id)); i > 0 {
			fs.items[i].name = job.name
		}
	case .Delete:
		i := sidebar_find(s, small_str(&job.id))
		if i < 1 {
			return
		}
		playlist_leave(s, i)
		copy(fs.items[i:fs.count - 1], fs.items[i + 1:fs.count])
		fs.count -= 1
		sidebar_moved(s, i, -1)
	}
}

// The worker's side

// run_playlist makes, renames or deletes a playlist on TIDAL.
run_playlist :: proc(s: ^tidal.Session, job: Playlist_Job, res: ^Result, alloc: mem.Allocator) {
	job := job
	id, name := small_str(&job.id), small_str(&job.name)
	switch job.op {
	case .Create:
		pl, err := tidal.user_create_playlist(s, name, "", allocator = alloc)
		if err != nil {
			fail(res, err)
			return
		}
		item := sidebar_item(pl)
		if item.name == "" {
			item.name = strings.clone(name, alloc)
		}
		res.payload = Playlist_Result{item}
	case .Rename:
		pl, err := tidal.playlist_get(s, id, context.temp_allocator)
		if err == nil {
			err = tidal.user_playlist_edit(s, &pl, title = name, allocator = context.temp_allocator)
		}
		if err != nil {
			fail(res, err)
		}
	case .Delete:
		if err := tidal.user_playlist_delete(s, id); err != nil {
			fail(res, err)
		}
	}
}

// Drawing

// draw_new_playlist_button is the + by the Your Library heading.
draw_new_playlist_button :: proc(s: ^State) {
	enabled := playlists_editable(s) && s.library.edit.mode != .Create
	flags := ui.Box_Flags{.Focusable, .Draw_Active_Effects}
	if !enabled {
		flags += {.Disabled}
	}
	ui.radius(6)
	_, sig := icon_button("new_playlist", text.ICON_PLUS, .Icon, "New playlist", SECONDARY if enabled else DIM, 1, NEW_PLAYLIST_W, flags, 15)
	if sig.clicked && enabled {
		new_playlist_start(s)
	}
	ui.tooltip(sig, "New playlist")
}

// new_playlist_row_shown says whether the playlists start with the new
// playlist's row: its field, or its name while TIDAL makes it.
new_playlist_row_shown :: proc(s: ^State) -> bool {
	if s.library.edit.mode == .Create {
		return true
	}
	out, ok := s.data.playlist_out.?
	return ok && out.op == .Create
}

// draw_new_playlist_row is the row under Liked Songs for a new playlist.
draw_new_playlist_row :: proc(s: ^State) {
	out, making := s.data.playlist_out.?
	making &&= out.op == .Create && s.library.edit.mode != .Create
	ui.set_next_radius(10)
	row := ui.row("##new_playlist", {}, ui.fill(), ui.px(PLAYLIST_ROW_H - PLAYLIST_GAP))
	ui.spacer(ui.px(8))
	cover_art(s, .Playlist, "", NEW_PLAYLIST_SEED, PLAYLIST_COVER, ui.px(PLAYLIST_COVER), radius = 6)
	ui.spacer(ui.px(10))
	if making {
		name := cat(small_str(&out.name)) // out is a copy
		ui.accessible(row, .Row, cat(name, ", Creating…"))
		playlist_lines(name, "Creating…", DIM)
	} else {
		ui.column("", {}, ui.fill(), ui.fill()).pad.y = (PLAYLIST_ROW_H - PLAYLIST_GAP - EDIT_FIELD_H) / 2
		edit_field(s)
	}
	ui.spacer(ui.px(8))
}

// playlist_lines are a sidebar row's name and subtitle, 33 pt, centred in
// the row.
playlist_lines :: proc(name, subtitle: string, color: render.Color) {
	ui.column("", {}, ui.fill(), ui.fill()).pad.y = (PLAYLIST_ROW_H - PLAYLIST_GAP - 33) / 2
	ui.text_style(.Medium, 13, color)
	ui.label(name, ui.fill(), ui.px(16))
	ui.spacer(ui.px(2))
	ui.text_style(.Regular, 12, QUIET)
	ui.label(subtitle, ui.fill(), ui.px(15))
}

// edit_field is the editor's text field. Return sends the name; Escape,
// or the field losing the focus, as to a click elsewhere, gives up.
edit_field :: proc(s: ^State) {
	e := &s.library.edit
	ui.text_style(.Medium, 13, TEXT)
	ui.set_next_background(SURFACE)
	ui.set_next_border_color(OUTLINE)
	ui.set_next_radius(6)
	focus := e.focus
	sig := ui.text_field("playlist_name", &e.field, "Playlist name", ui.fill(), EDIT_FIELD_H, focus = focus)
	e.focus = false
	e.built = true
	// Return and Escape give the focus back to what opened the field, the
	// + or the list's More button; a click or a Tab elsewhere keeps it.
	back, ring := e.back, e.ring
	switch {
	case sig.submitted:
		edit_commit(s, sig.submitted_text)
		ui.restore_focus(back, ring)
	case sig.escaped:
		s.library.edit = {}
		ui.restore_focus(back, ring)
	case !sig.focused && !focus:
		s.library.edit = {}
	case:
		return
	}
	// This frame built the field already, so the next one goes without it.
	ui.request_frame()
}

// sidebar_edit_reveal scrolls list, the sidebar's playlists h tall, to the
// row the editor opened in, at once, so the row is built with its field in
// this frame. extra is 1 while the new playlist's row is under Liked Songs.
sidebar_edit_reveal :: proc(s: ^State, list: ^ui.Box, h: f32, extra: int) {
	e := &s.library.edit
	if !e.reveal {
		return
	}
	e.reveal = false
	row := 1
	switch e.mode {
	case .None:
		return
	case .Create:
	case .Rename:
		i := sidebar_find(s, small_str(&e.id))
		if i < 0 {
			return
		}
		row = i + extra if i > 0 else i
	}
	y0 := list.pad.y + f32(row) * PLAYLIST_ROW_H
	y1 := y0 + PLAYLIST_ROW_H
	off := list.view_off_target.y
	if y0 < off {
		off = y0
	} else if y1 > off + h {
		off = y1 - h
	}
	list.view_off.y, list.view_off_target.y = off, off
}

// draw_delete_menu asks before deleting the playlist the More menu was
// opened for, in its place.
draw_delete_menu :: proc(s: ^State) {
	if ui.menu(DELETE_MENU, 260, "Delete playlist") {
		lib := &s.library
		i := sidebar_find(s, small_str(&lib.delete_id))
		name := sidebar_entry(s, i).name if i > 0 else ""
		ui.text_style(.Semibold, 13, TEXT)
		ui.set_next_text_pad(14)
		ask := ui.label(fmt.tprintf("Delete “%s”?", name), ui.fill(), ui.px(30))
		ui.accessible(ask, .Static_Text, ask.label)
		ui.menu_separator()
		// Cancel first, so the keyboard that opened it lands there.
		ui.text_style(.Regular, 13, TEXT)
		ui.menu_item("Cancel###delete_cancel")
		ui.text_style(.Regular, 13, PLAYBACK_ERROR)
		if ui.menu_item("Delete###delete_confirm").clicked && i > 0 {
			pending_set(s, Playlist_Job{op = .Delete, id = lib.delete_id})
		}
	}
}
