package app

// What happens to each kind of job between push_job and its result: whether
// a held one asks for what another does, can go to make room, is still
// wanted, and what dropping it undoes; whether it talks to TIDAL, belongs
// to the account, and can end the login; and what it owns. Every switch
// here names every kind, so a new kind doesn't compile until each of these
// says what it does.
//
// Covers and the launch log are pushed with jobs.push and wait for room,
// and disk jobs go to the disk thread, so those three are never held.

import "base:runtime"
import "core:reflect"
import "core:time"

// same_request says whether two jobs ask for the same thing. The kinds that
// wait behind a flag or are sent one at a time each ask for one thing, and
// an Artwork asks for its track's serial. A Stream's serial and a page's
// offset are never asked for twice, and every add or playlist edit is its
// own. Only one follow change per artist is out, see Toggle_Out.
@(private)
same_request :: proc(held, job: Job) -> bool {
	switch p in job.payload {
	case Restore_Job, Login_Start_Job, Login_Wait_Job, Login_Pkce_Job, Playlists_Job, Liked_Ids_Job, Search_Job, Save_Settings_Job, Home_Job, Profile_Job:
		return reflect.union_variant_typeid(held.payload) == reflect.union_variant_typeid(job.payload)
	case Artwork_Job:
		h, art := held.payload.(Artwork_Job)
		return art && h.serial == p.serial
	case Artist_Job:
		h, artist := held.payload.(Artist_Job)
		return artist && h == p
	case Tracks_Job, Stream_Job, Add_Track_Job, Follow_Job, Playlist_Job:
		return false
	case Cover_Job, Launch_Log_Job, Disk_Job:
		return false // never held
	}
	return false
}

// held_evictable says whether a held job can go to make room for a new one:
// a Stream, Artwork or Add_Track, whose track has most likely moved on, an
// Artist, whose page asks again, or a Follow, whose button goes back.
// hold_job keeps one of each other kind, view_pages one page per list and
// playlist_edit one playlist edit, so they never fill the list.
@(private)
held_evictable :: proc(job: Job) -> bool {
	switch _ in job.payload {
	case Stream_Job, Artwork_Job, Add_Track_Job, Artist_Job, Follow_Job:
		return true
	case Restore_Job, Login_Start_Job, Login_Wait_Job, Login_Pkce_Job, Playlists_Job, Tracks_Job, Search_Job, Save_Settings_Job, Liked_Ids_Job, Home_Job, Profile_Job, Playlist_Job:
		return false
	case Cover_Job, Launch_Log_Job, Disk_Job:
		return false // never held
	}
	return false
}

// held_wanted says whether a held job is still wanted: its login hasn't
// ended and what it's for still waits for it. Kinds whose answer is checked
// when it comes, as Stream's track serial is, always are, and so is Search:
// search_stop drops the held one with the queued one.
@(private)
held_wanted :: proc(d: ^Data, job: Job) -> bool {
	l := &d.login
	if job.auth != d.auth_gen {
		return false
	}
	_, code_shown := l.card.(Login_Code)
	switch p in job.payload {
	case Restore_Job:
		return d.account == .Restoring
	case Login_Start_Job:
		asked, ok := l.code.(Code_Asked)
		return code_shown && ok && asked.attempt == p.attempt
	case Login_Wait_Job:
		_, polling := l.code.(Code_Polling)
		return code_shown && polling
	case Login_Pkce_Job:
		_, exchanging := l.card.(Login_Exchanging)
		return exchanging
	case Playlists_Job, Home_Job, Profile_Job:
		return d.account == .Signed_In
	case Tracks_Job:
		return track_view(d, p.view) != nil
	case Artist_Job:
		return artist_waiting(d, p) != nil
	case Stream_Job, Artwork_Job, Search_Job, Save_Settings_Job, Add_Track_Job, Liked_Ids_Job, Follow_Job, Playlist_Job:
		return true
	case Cover_Job, Launch_Log_Job, Disk_Job:
		return true // never held
	}
	return true
}

// held_drop lets go of a held job that won't be pushed. Its caller counted
// it as out, so the flag holding back the next one is cleared. A like,
// unlike or follow change never reached TIDAL, so its button goes back, and
// a playlist edit's row shows as it was.
@(private)
held_drop :: proc(d: ^Data, job: ^Job) {
	l := &d.login
	switch p in job.payload {
	case Login_Start_Job:
		if asked, ok := l.code.(Code_Asked); ok && asked.attempt == p.attempt {
			l.code = nil
		}
	case Login_Wait_Job:
		if poll, ok := &l.code.(Code_Polling); ok {
			poll.out = false
		}
	case Playlists_Job:
		d.sidebar.loading = false
	case Liked_Ids_Job:
		d.liked.loading = false
		clear(&d.liked.edits)
		clear(&d.followed.edits)
	case Add_Track_Job:
		if p.source == .Liked {
			liked_answer(d, p.track, false)
		}
	case Follow_Job:
		follow_answer(d, p.artist, false)
	case Artist_Job:
		artist_job_dropped(d, p)
	case Home_Job:
		home_job_dropped(d)
	case Profile_Job:
		d.profile.loading = false
	case Playlist_Job:
		d.playlist_out = nil
	case Restore_Job, Login_Pkce_Job, Save_Settings_Job, Stream_Job, Artwork_Job, Search_Job:
		// No flag waits on these.
	case Tracks_Job:
		// Whoever drops a page of a list still open takes it off the
		// list's in_flight, see held_remove_if.
	case Cover_Job, Launch_Log_Job, Disk_Job:
		// Never held.
	}
	job_free(job)
}

// job_free frees what a job owns, once it has run for good or won't run.
job_free :: proc(job: ^Job) {
	switch &p in job.payload {
	case Disk_Job:
		delete(p.blob, runtime.heap_allocator())
		p.blob = nil
	case Restore_Job, Login_Start_Job, Login_Wait_Job, Login_Pkce_Job, Playlists_Job, Tracks_Job, Cover_Job, Stream_Job, Artwork_Job, Search_Job, Save_Settings_Job, Add_Track_Job, Liked_Ids_Job, Follow_Job, Launch_Log_Job, Artist_Job, Home_Job, Profile_Job, Playlist_Job:
	}
}

// for_account says whether a job belongs to the signed-in account, so it
// goes when the account ends and its result is dropped after. A cover is
// the same for everyone.
for_account :: proc(job: Job) -> bool {
	switch _ in job.payload {
	case Cover_Job:
		return false
	case Restore_Job, Login_Start_Job, Login_Wait_Job, Login_Pkce_Job, Playlists_Job, Tracks_Job, Stream_Job, Artwork_Job, Search_Job, Save_Settings_Job, Disk_Job, Add_Track_Job, Liked_Ids_Job, Follow_Job, Launch_Log_Job, Artist_Job, Home_Job, Profile_Job, Playlist_Job:
		return true
	}
	return true
}

// ends_login says whether a job's .Authentication means TIDAL no longer
// takes the login. Only jobs that sent the login's tokens can end it. A
// cover or an artwork carries no token, and a login job's .Authentication
// means the user denied it.
ends_login :: proc(job: Job) -> bool {
	switch _ in job.payload {
	case Restore_Job, Playlists_Job, Tracks_Job, Stream_Job, Search_Job, Add_Track_Job, Liked_Ids_Job, Follow_Job, Artist_Job, Home_Job, Profile_Job, Playlist_Job:
		return true
	case Login_Start_Job, Login_Wait_Job, Login_Pkce_Job:
		return false
	case Cover_Job, Artwork_Job:
		return false
	case Save_Settings_Job, Launch_Log_Job, Disk_Job:
		return false // they stay on this machine
	}
	return false
}

// is_local says a job sends nothing to TIDAL, so a backoff doesn't hold
// it. A cover counts until it's found missing from disk.
@(private)
is_local :: proc(job: ^Job) -> bool {
	switch p in job.payload {
	case Save_Settings_Job, Launch_Log_Job, Disk_Job:
		return true
	case Cover_Job:
		return !p.image.remote
	case Artwork_Job:
		return !p.image.remote
	case Restore_Job, Login_Start_Job, Login_Wait_Job, Login_Pkce_Job, Playlists_Job, Tracks_Job, Stream_Job, Search_Job, Add_Track_Job, Liked_Ids_Job, Follow_Job, Artist_Job, Home_Job, Profile_Job, Playlist_Job:
		return false
	}
	return false
}

// requeued is job as it goes back in the queue. A Login_Wait that polled
// keeps the interval TIDAL asked for, slow_down included, and polls again
// no sooner than that interval from now. A cover that went to TIDAL waits
// out the backoff with the other requests. Other kinds go back as they
// were.
@(private)
requeued :: proc(job: Job, res: Result) -> Job {
	job := job
	switch &p in job.payload {
	case Cover_Job:
		p.image.remote ||= res.err != nil
	case Artwork_Job:
		p.image.remote ||= res.err != nil
	case Login_Wait_Job:
		if wait, ok := res.payload.(Login_Wait_Result); ok && wait.interval > 0 {
			p.interval = wait.interval
			p.not_before = time.tick_add(time.tick_now(), time.Duration(f64(p.interval) * f64(time.Second)))
		}
	case Restore_Job, Login_Start_Job, Login_Pkce_Job, Playlists_Job, Tracks_Job, Stream_Job, Search_Job, Save_Settings_Job, Disk_Job, Add_Track_Job, Liked_Ids_Job, Follow_Job, Launch_Log_Job, Artist_Job, Home_Job, Profile_Job, Playlist_Job:
	}
	return job
}
