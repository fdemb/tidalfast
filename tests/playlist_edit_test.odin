package tidal_tests

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/ui"

// Making, renaming and deleting playlists: the jobs against the mock, and
// the sidebar's field and the delete question with the fake data.

CREATE_PATH :: "/v2/my-collection/playlists/folders/create-playlist"

// test_arena gives a test's State and the fake rows an arena, as the app's
// own memory block is, so what the app never frees isn't a leak.
@(private = "file")
test_arena :: proc(a: ^vmem.Arena) -> mem.Allocator {
	_ = vmem.arena_init_growing(a)
	return vmem.arena_allocator(a)
}

// playlist_state is a State signed in to m with the sidebar loaded from
// it, and the jobs that followed dropped.
@(private = "file")
playlist_state :: proc(m: ^Mock) -> ^app.State {
	s := library_state(false, m)
	run_kinds(s, app.Playlists_Job)
	return s
}

// run_kinds runs the queued jobs of kinds against the mock until no more
// come, and drops the rest.
@(private = "file")
run_kinds :: proc(s: ^app.State, kinds: ..typeid) {
	for {
		queued := data_jobs(&s.data)
		if len(queued) == 0 {
			return
		}
		for &job in queued {
			if slice.contains(kinds, reflect.union_variant_typeid(job.payload)) {
				run_now(s, job)
			} else {
				app.job_free(&job)
			}
		}
	}
}

// edit sends a playlist edit as a frame's Pending would, and returns its
// job from the queue, the rest of which it drops.
@(private = "file")
edit :: proc(t: ^testing.T, s: ^app.State, job: app.Playlist_Job, loc := #caller_location) -> (out: app.Job, ok: bool) {
	app.playlist_edit(s, job)
	testing.expect(t, s.data.playlist_out != nil, "the edit is out", loc = loc)
	for &queued in data_jobs(&s.data) {
		if _, is := queued.payload.(app.Playlist_Job); is && !ok {
			out, ok = queued, true
		} else {
			app.job_free(&queued)
		}
	}
	testing.expect(t, ok, "a Playlist_Job is queued", loc = loc)
	return
}

@(private = "file")
sidebar_names :: proc(s: ^app.State) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for it in s.data.sidebar.items {
		append(&out, it.name)
	}
	return out[:]
}

@(private = "file")
open_id :: proc(s: ^app.State) -> string {
	return strings.clone(app.small_str(&s.data.view.id), context.temp_allocator)
}

// A playlist made in the app goes at the top of the sidebar and opens, is
// renamed in the sidebar and the open list, and deleted leaves the sidebar
// and the view. TIDAL's next sidebar agrees each time.
@(test)
playlists_are_made_renamed_and_deleted :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := playlist_state(&m)
	defer library_state_free(s)
	d := &s.data
	testing.expect_value(t, len(d.sidebar.items), 0)
	testing.expect(t, d.sidebar.loaded, "the sidebar loads")

	job, ok := edit(t, s, {op = .Create, name = app.small("Road Mix")})
	if !ok {
		return
	}
	run_now(s, job)
	testing.expect_value(t, mock_count(&m, "PUT /v2/my-collection/playlists/folders/create-playlist?"), 1)
	testing.expect_value(t, m.last_query["name"], "Road Mix")
	testing.expect(t, d.playlist_out == nil, "the edit is answered")
	testing.expect(t, slice.equal(sidebar_names(s), []string{"Road Mix"}), "the sidebar has it")
	testing.expect(t, len(d.sidebar.items) == 1 && d.sidebar.items[0].owned && d.sidebar.items[0].id == "made-1", "it's the user's")
	testing.expect_value(t, s.library.playlist, 1)
	testing.expect_value(t, d.view.source, app.Source.Playlist)
	testing.expect_value(t, open_id(s), "made-1")
	testing.expect_value(t, app.view_title(s), "Road Mix")
	app.request_playlists(d)
	run_kinds(s, app.Playlists_Job, app.Tracks_Job)
	testing.expect(t, slice.equal(sidebar_names(s), []string{"Road Mix"}), "TIDAL lists it")
	testing.expect_value(t, d.view.count, 0)

	job, ok = edit(t, s, {op = .Rename, id = app.small("made-1"), name = app.small("Night Drive")})
	run_now(s, job)
	testing.expect_value(t, mock_count(&m, "POST /playlists/made-1"), 1)
	testing.expect(t, slice.equal(sidebar_names(s), []string{"Night Drive"}), "the sidebar has the new name")
	testing.expect_value(t, app.view_title(s), "Night Drive")
	testing.expect_value(t, m.playlists[0].name, "Night Drive")

	job, ok = edit(t, s, {op = .Delete, id = app.small("made-1")})
	run_now(s, job)
	testing.expect_value(t, mock_count(&m, "DELETE /playlists/made-1"), 1)
	testing.expect_value(t, len(d.sidebar.items), 0)
	testing.expect_value(t, len(m.playlists), 0)
	testing.expect(t, open_id(s) != "made-1", "the view leaves it")
	testing.expect(t, app.playlist_showing(s, 0) || app.home_showing(s), "back to Liked Songs or Home")
	app.request_playlists(d)
	run_kinds(s, app.Playlists_Job)
	testing.expect_value(t, len(d.sidebar.items), 0)
}

// A make, rename or delete TIDAL refuses changes nothing and says why.
@(test)
refused_playlist_edits_change_nothing :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := playlist_state(&m)
	defer library_state_free(s)
	d := &s.data

	m.answers[CREATE_PATH] = {500, `{"status":500,"userMessage":"Broken"}`}
	job, ok := edit(t, s, {op = .Create, name = app.small("Road Mix")})
	if !ok {
		return
	}
	run_now(s, job)
	testing.expect(t, d.playlist_out == nil, "the edit is answered")
	testing.expect_value(t, len(d.sidebar.items), 0)
	testing.expect(t, strings.has_prefix(app.small_str(&d.message), "Couldn't create the playlist"), app.small_str(&d.message))
	_, toast := app.current_error(s)
	testing.expect(t, strings.has_prefix(toast, "Couldn't create the playlist"), "a toast says so")
	delete_key(&m.answers, CREATE_PATH)

	job, _ = edit(t, s, {op = .Create, name = app.small("Road Mix")})
	run_now(s, job)
	testing.expect_value(t, len(d.sidebar.items), 1)

	m.answers["/playlists/made-1"] = {503, `{"status":503,"userMessage":"Unavailable"}`}
	job, _ = edit(t, s, {op = .Rename, id = app.small("made-1"), name = app.small("Night Drive")})
	run_now(s, job)
	testing.expect(t, slice.equal(sidebar_names(s), []string{"Road Mix"}), "the old name stays")
	testing.expect_value(t, app.view_title(s), "Road Mix")
	testing.expect(t, strings.has_prefix(app.small_str(&d.message), "Couldn't rename the playlist"), app.small_str(&d.message))

	job, _ = edit(t, s, {op = .Delete, id = app.small("made-1")})
	run_now(s, job)
	testing.expect(t, slice.equal(sidebar_names(s), []string{"Road Mix"}), "it stays")
	testing.expect_value(t, open_id(s), "made-1")
	testing.expect(t, strings.has_prefix(app.small_str(&d.message), "Couldn't delete the playlist"), app.small_str(&d.message))
	testing.expect_value(t, len(m.playlists), 1)
}

// An answer that comes after a sign-out is dropped, and the sign-out
// leaves no edit out.
@(test)
playlist_edits_from_before_a_sign_out_are_dropped :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	for op in app.Playlist_Op {
		m: Mock
		mock_start(&m)
		defer mock_stop(&m)
		s := playlist_state(&m)
		defer library_state_free(s)
		d := &s.data
		if op != .Create {
			job, _ := edit(t, s, {op = .Create, name = app.small("Road Mix")})
			run_now(s, job)
		}
		job, ok := edit(t, s, {op = op, id = app.small("made-1" if op != .Create else ""), name = app.small("Night Drive")})
		if !ok {
			continue
		}
		res := app.run_job(d, job)
		testing.expectf(t, res.err == nil, "%v: TIDAL takes it", op)
		app.sign_out(s, "")
		testing.expectf(t, d.playlist_out == nil, "%v: the sign-out ends the edit", op)
		app.handle_result(s, &res, 0)
		app.result_free(&res)
		testing.expectf(t, len(d.sidebar.items) == 0 && !d.sidebar.loaded, "%v: the old account's answer is dropped", op)
		testing.expect_value(t, s.library.playlist, 0)
	}
}

// A rate limit holds the edit in the queue rather than failing it, so it
// goes once TIDAL lets it.
@(test)
rate_limited_playlist_edit_waits :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := playlist_state(&m)
	defer library_state_free(s)
	d := &s.data
	m.answers[CREATE_PATH] = {429, `{"status":429,"userMessage":"Too many requests"}`}
	job, ok := edit(t, s, {op = .Create, name = app.small("Road Mix")})
	if !ok {
		return
	}
	res := app.run_job(d, job)
	err, failed := res.err.?
	testing.expect(t, failed && err == .Too_Many_Requests, "the worker puts it back")
	app.result_free(&res)
	testing.expect(t, d.playlist_out != nil, "it's still out")
	testing.expect_value(t, len(d.sidebar.items), 0)
}

// The sidebar's rows past the bottom of the window aren't built, and which
// those are depends on the OS: on macOS the sidebar keeps room for the
// window's buttons above Home (sidebar_top), so fewer rows show. So these
// tests find sidebar entries through the app's own list and open them as a
// click would, and look up on screen only what shows whatever the OS. They
// draw a short window (SHORT), where most rows are off screen everywhere,
// so Linux runs the same path macOS does. A lookup that fails says what
// the frame had.

SHORT :: [2]f32{1000, 520}

// entry_named is the sidebar entry called name, -1 if there's none.
@(private = "file")
entry_named :: proc(s: ^app.State, name: string) -> int {
	for i in 0 ..< app.sidebar_count(s) {
		if app.sidebar_entry(s, i).name == name {
			return i
		}
	}
	return -1
}

// entry_names lists the sidebar's entries, for a failure's message.
@(private = "file")
entry_names :: proc(s: ^app.State) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< app.sidebar_count(s) {
		append(&names, app.sidebar_entry(s, i).name)
	}
	return strings.join(names[:], " | ", context.temp_allocator)
}

// shown describes the last frame for a failure's message: the window, the
// fonts and every node's label.
@(private = "file")
shown :: proc(s: ^app.State, f: ^Frame) -> string {
	labels := make([dynamic]string, context.temp_allocator)
	for n in nodes_of(s) {
		if label := string(n.label); label != "" {
			append(&labels, label)
		}
	}
	size := f.size if f.size != {} else {1000, 700}
	return fmt.tprintf("window %v, fonts %v, nodes: %s", size, f.fonts != nil, strings.join(labels[:], " | ", context.temp_allocator))
}

// find finds the node whose label starts with label, and fails the test
// saying what the frame had when there's none.
@(private = "file")
find :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, label: string, loc := #caller_location) -> (platform.Access_Node, bool) {
	n, ok := access_node(s, label)
	testing.expectf(t, ok, "no node %q; %s", label, shown(s, f), loc = loc)
	return n, ok
}

// press_found presses the node whose label starts with label, if find
// finds it, and draws the frame after.
@(private = "file")
press_found :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, label: string, loc := #caller_location) -> bool {
	n := find(t, s, f, label, loc) or_return
	library_frame(t, s, f, {kind = .Access_Press, target = n.id}, loc = loc)
	library_frame(t, s, f, loc = loc)
	return true
}

// open_entry opens the sidebar entry called name as a click on its row
// does, whether or not the row is on screen.
@(private = "file")
open_entry :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, name: string, loc := #caller_location) -> bool {
	i := entry_named(s, name)
	if !testing.expectf(t, i >= 0, "no sidebar entry %q; the sidebar has %s", name, entry_names(s), loc = loc) {
		return false
	}
	app.pending_set(s, app.Playlist_Place{index = i})
	app.pending_apply(s)
	library_frame(t, s, f, loc = loc)
	library_frame(t, s, f, loc = loc)
	return testing.expectf(t, app.view_title(s) == name, "%q opens, the view shows %q", name, app.view_title(s), loc = loc)
}

// The editable row: Return makes the playlist and opens it; Escape, an
// empty name or a click elsewhere gives up and makes nothing.
@(test)
new_playlist_row_takes_its_keys :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = SHORT}
	library_frame(t, s, &f)
	count := app.sidebar_count(s)

	new_row :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, loc := #caller_location) -> bool {
		press_found(t, s, f, "New playlist", loc) or_return
		n := find(t, s, f, "Playlist name", loc) or_return
		testing.expectf(t, n.role == .Text_Field && .Focused in n.flags, "a focused field named Playlist name, got role %v, flags %v", n.role, n.flags, loc = loc)
		testing.expect(t, ui.text_focused(), "typing goes to it", loc = loc)
		return true
	}

	// Escape.
	if !new_row(t, s, &f) {
		return
	}
	library_frame(t, s, &f, type_text(&f, "abc"))
	settle_edit(t, s, &f)
	library_frame(t, s, &f, key(.Escape))
	testing.expect(t, f.animating, "Escape asks for the frame without the row")
	library_frame(t, s, &f)
	_, open := access_node(s, "Playlist name")
	testing.expect(t, !open, "Escape closes the row")
	testing.expect_value(t, app.sidebar_count(s), count)

	// An empty name.
	new_row(t, s, &f)
	settle_edit(t, s, &f)
	library_frame(t, s, &f, key(.Return))
	testing.expect(t, f.animating, "Return asks for the frame without the row")
	library_frame(t, s, &f)
	_, open = access_node(s, "Playlist name")
	testing.expect(t, !open, "Return with no name closes the row")
	testing.expect_value(t, app.sidebar_count(s), count)

	// A click elsewhere: on Home, at the top of the sidebar on every OS.
	new_row(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "abc"))
	if _, ok := find(t, s, &f, "Home"); ok {
		down, up := left_click(s, "Home")
		library_frame(t, s, &f, down, up)
		library_frame(t, s, &f)
	}
	_, open = access_node(s, "Playlist name")
	testing.expect(t, !open, "a click elsewhere closes the row")
	testing.expect_value(t, app.sidebar_count(s), count)

	// Return.
	new_row(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "  Road Mix "))
	library_frame(t, s, &f, key(.Return))
	library_frame(t, s, &f)
	testing.expect_value(t, app.sidebar_count(s), count + 1)
	testing.expectf(t, entry_named(s, "Road Mix") == 1, "it goes under Liked Songs; the sidebar has %s", entry_names(s))
	// Second in the sidebar, so its row shows whatever the OS.
	find(t, s, &f, "Road Mix, 0 songs")
	testing.expect_value(t, app.view_title(s), "Road Mix")
	testing.expect(t, app.playlist_showing(s, 1), "it opens")
	testing.expect_value(t, app.view_count(s), 0)
}

// settle_edit draws frames a second apart until the window asks for no
// more, as a window left alone does, so a frame that asks for another
// shows.
@(private = "file")
settle_edit :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, loc := #caller_location) {
	for _ in 0 ..< 20 {
		library_frame(t, s, f, dt = 1, loc = loc)
		if !f.animating {
			return
		}
	}
	testing.expect(t, false, "the frames settle", loc = loc)
}

// Rename and Delete playlist are offered only for the user's own
// playlists. Delete asks first; Cancel keeps the playlist and Delete
// removes it and goes back.
@(test)
deleting_a_playlist_asks_first :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = SHORT}
	library_frame(t, s, &f)

	more :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, name: string, loc := #caller_location) -> bool {
		open_entry(t, s, f, name, loc) or_return
		return press_found(t, s, f, strings.concatenate({"More options for ", name}, context.temp_allocator), loc)
	}
	for name in ([]string{"Liked Songs", "Discover Weekly"}) {
		if !more(t, s, &f, name) {
			return
		}
		_, rename := access_node(s, "Rename")
		_, del := access_node(s, "Delete playlist")
		testing.expectf(t, !rename && !del, "%s can't be renamed or deleted; %s", name, shown(s, &f))
		library_frame(t, s, &f, key(.Escape))
	}

	if !more(t, s, &f, "Polskie hity") || !press_found(t, s, &f, "Delete playlist") {
		return
	}
	ask, asked := find(t, s, &f, "Delete “Polskie hity”?")
	testing.expectf(t, asked && ask.role == .Static_Text, "it asks, got role %v", ask.role)
	cancel, _ := find(t, s, &f, "Cancel")
	testing.expectf(t, .Focused in cancel.flags, "the keyboard lands on Cancel, its flags are %v", cancel.flags)
	press_found(t, s, &f, "Cancel")
	testing.expectf(t, entry_named(s, "Polskie hity") > 0, "Cancel keeps it; the sidebar has %s", entry_names(s))
	testing.expect_value(t, app.view_title(s), "Polskie hity")

	count := app.sidebar_count(s)
	if !more(t, s, &f, "Polskie hity") || !press_found(t, s, &f, "Delete playlist") {
		return
	}
	confirm: Maybe(platform.Access_Node)
	for node in nodes_of(s) {
		if string(node.label) == "Delete" && node.role == .Menu_Item {
			confirm = node
		}
	}
	n, found := confirm.?
	if !testing.expectf(t, found, "no Delete menu item; %s", shown(s, &f)) {
		return
	}
	library_frame(t, s, &f, {kind = .Access_Press, target = n.id})
	library_frame(t, s, &f)
	testing.expectf(t, entry_named(s, "Polskie hity") < 0, "Delete removes it; the sidebar has %s", entry_names(s))
	testing.expect_value(t, app.sidebar_count(s), count - 1)
	testing.expect_value(t, app.view_title(s), "Discover Weekly")
}

// Rename puts the field in the playlist's sidebar row with its name, and
// Return gives it the new one. The window is short enough that Workout
// Bangers' row is off screen on every OS, so this also checks that Rename
// scrolls the sidebar to the row.
@(test)
renaming_a_playlist_in_its_row :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = SHORT}
	library_frame(t, s, &f)
	if !open_entry(t, s, &f, "Workout Bangers") || !press_found(t, s, &f, "More options for Workout Bangers") || !press_found(t, s, &f, "Rename") {
		return
	}
	field, ok := find(t, s, &f, "Playlist name")
	testing.expectf(t, ok && .Focused in field.flags && string(field.value) == "Workout Bangers", "the row's field holds the name, focused; got %q, flags %v", string(field.value), field.flags)
	// Typing replaces the name, which the field selected.
	library_frame(t, s, &f, type_text(&f, "Gym"))
	library_frame(t, s, &f, key(.Return))
	library_frame(t, s, &f)
	testing.expectf(t, entry_named(s, "Gym") > 0 && entry_named(s, "Workout Bangers") < 0, "the entry has the new name; the sidebar has %s", entry_names(s))
	// The field scrolled the sidebar to the row, so it still shows.
	find(t, s, &f, "Gym, ")
	testing.expect_value(t, app.view_title(s), "Gym")

	// Escape keeps the name.
	if !press_found(t, s, &f, "More options for Gym") || !press_found(t, s, &f, "Rename") {
		return
	}
	library_frame(t, s, &f, type_text(&f, "Other"))
	library_frame(t, s, &f, key(.Escape))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Gym")
	testing.expectf(t, entry_named(s, "Gym") > 0, "Escape keeps the name; the sidebar has %s", entry_names(s))
	_, open := access_node(s, "Playlist name")
	testing.expect(t, !open, "Escape closes the field")
}

@(private = "file")
nodes_of :: proc(s: ^app.State) -> []platform.Access_Node {
	nodes, _ := ui.access_tree(&s.ui)
	return nodes
}

// While TIDAL makes a playlist its row shows the name greyed, and the +
// waits for the answer.
@(test)
new_playlist_row_waits_for_tidal :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := playlist_state(&m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 700}}
	library_frame(t, s, &f)
	if !press_found(t, s, &f, "New playlist") {
		return
	}
	library_frame(t, s, &f, type_text(&f, "Road Mix"))
	library_frame(t, s, &f, key(.Return))
	library_frame(t, s, &f)
	find(t, s, &f, "Road Mix, Creating…")
	testing.expect(t, !enabled(s, "New playlist"), "one at a time")
	job: app.Job
	for &queued in data_jobs(&s.data) {
		if _, is := queued.payload.(app.Playlist_Job); is {
			job = queued
		}
	}
	run_now(s, job)
	library_frame(t, s, &f)
	find(t, s, &f, "Road Mix, 0 songs")
	testing.expect(t, enabled(s, "New playlist"), "the + is back")
	for &queued in data_jobs(&s.data) {
		app.job_free(&queued)
	}
}

// The sidebar's file keeps which playlists are the user's, so a launch
// that shows the sidebar from disk offers Rename and Delete playlist on
// the right ones.
@(test)
sidebar_file_keeps_ownership :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	sb := app.Sidebar {
		items  = []app.Sidebar_Item{{id = "mine", name = "Mine", tracks = 3, owned = true}, {id = "theirs", name = "Theirs", tracks = 4}},
		loaded = true,
	}
	file := app.sidebar_encode(&sb, 100, context.allocator)
	app.file_seal(file)
	_, items, err := app.sidebar_decode(file, context.allocator)
	testing.expect_value(t, err, app.File_Error.None)
	testing.expect(t, len(items) == 2 && items[0].owned && !items[1].owned, "owned comes back")
	testing.expect(t, len(items) == 2 && items[0].name == "Mine" && items[1].tracks == 4, "the rest comes back")
}
