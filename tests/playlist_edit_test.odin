package tidal_tests

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

// The editable row: Return makes the playlist and opens it; Escape, an
// empty name or a click elsewhere gives up and makes nothing.
@(test)
new_playlist_row_takes_its_keys :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	count := app.sidebar_count(s)

	new_row :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, loc := #caller_location) {
		library_frame(t, s, f, press(s, "New playlist"), loc = loc)
		library_frame(t, s, f, loc = loc)
		n, ok := access_node(s, "Playlist name")
		testing.expect(t, ok && n.role == .Text_Field && .Focused in n.flags, "a focused field named Playlist name", loc = loc)
		testing.expect(t, ui.text_focused(), "typing goes to it", loc = loc)
	}

	// Escape.
	new_row(t, s, &f)
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

	// A click elsewhere.
	new_row(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "abc"))
	down, up := left_click(s, "Discover Weekly")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	_, open = access_node(s, "Playlist name")
	testing.expect(t, !open, "a click elsewhere closes the row")
	testing.expect_value(t, app.sidebar_count(s), count)

	// Return.
	new_row(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "  Road Mix "))
	library_frame(t, s, &f, key(.Return))
	library_frame(t, s, &f)
	testing.expect_value(t, app.sidebar_count(s), count + 1)
	_, made := access_node(s, "Road Mix, 0 songs")
	testing.expect(t, made, "the sidebar has it")
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
	f: Frame
	library_frame(t, s, &f)

	more :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, name: string) {
		library_frame(t, s, f, press(s, name))
		library_frame(t, s, f)
		library_frame(t, s, f, press(s, strings.concatenate({"More options for ", name}, context.temp_allocator)))
		library_frame(t, s, f)
	}
	for name in ([]string{"Liked Songs", "Discover Weekly"}) {
		more(t, s, &f, name)
		_, rename := access_node(s, "Rename")
		_, del := access_node(s, "Delete playlist")
		testing.expectf(t, !rename && !del, "%s can't be renamed or deleted", name)
		library_frame(t, s, &f, key(.Escape))
	}

	more(t, s, &f, "Polskie hity")
	library_frame(t, s, &f, press(s, "Delete playlist"))
	library_frame(t, s, &f)
	ask, asked := access_node(s, "Delete “Polskie hity”?")
	testing.expect(t, asked && ask.role == .Static_Text, "it asks")
	cancel, _ := access_node(s, "Cancel")
	testing.expect(t, .Focused in cancel.flags, "the keyboard lands on Cancel")
	library_frame(t, s, &f, press(s, "Cancel"))
	library_frame(t, s, &f)
	_, kept := access_node(s, "Polskie hity, 242 songs")
	testing.expect(t, kept, "Cancel keeps it")
	testing.expect_value(t, app.view_title(s), "Polskie hity")

	count := app.sidebar_count(s)
	more(t, s, &f, "Polskie hity")
	library_frame(t, s, &f, press(s, "Delete playlist"))
	library_frame(t, s, &f)
	n, _ := access_node(s, "Delete")
	for node in nodes_of(s) {
		if string(node.label) == "Delete" && node.role == .Menu_Item {
			n = node
		}
	}
	library_frame(t, s, &f, {kind = .Access_Press, target = n.id})
	library_frame(t, s, &f)
	_, kept = access_node(s, "Polskie hity, 242 songs")
	testing.expect(t, !kept, "Delete removes it")
	testing.expect_value(t, app.sidebar_count(s), count - 1)
	testing.expect_value(t, app.view_title(s), "Discover Weekly")
}

// Rename puts the field in the playlist's sidebar row with its name, and
// Return gives it the new one.
@(test)
renaming_a_playlist_in_its_row :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = test_arena(&arena)
	defer vmem.arena_destroy(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Workout Bangers"))
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "More options for Workout Bangers"))
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Rename"))
	library_frame(t, s, &f)
	field, ok := access_node(s, "Playlist name")
	testing.expect(t, ok && .Focused in field.flags && string(field.value) == "Workout Bangers", "the row's field holds the name")
	// Typing replaces the name, which the field selected.
	library_frame(t, s, &f, type_text(&f, "Gym"))
	library_frame(t, s, &f, key(.Return))
	library_frame(t, s, &f)
	_, renamed := access_node(s, "Gym, ")
	testing.expect(t, renamed, "the row has the new name")
	testing.expect_value(t, app.view_title(s), "Gym")

	// Escape keeps the name.
	library_frame(t, s, &f, press(s, "More options for Gym"))
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Rename"))
	library_frame(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "Other"))
	library_frame(t, s, &f, key(.Escape))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Gym")
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
	library_frame(t, s, &f, press(s, "New playlist"))
	library_frame(t, s, &f, type_text(&f, "Road Mix"))
	library_frame(t, s, &f, key(.Return))
	library_frame(t, s, &f)
	_, sending := access_node(s, "Road Mix, Creating…")
	testing.expect(t, sending, "the row shows it on its way")
	testing.expect(t, !enabled(s, "New playlist"), "one at a time")
	job: app.Job
	for &queued in data_jobs(&s.data) {
		if _, is := queued.payload.(app.Playlist_Job); is {
			job = queued
		}
	}
	run_now(s, job)
	library_frame(t, s, &f)
	_, made := access_node(s, "Road Mix, 0 songs")
	testing.expect(t, made, "the sidebar has it")
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
