# Playback

`src/audio` plays FLAC at any rate and depth: TIDAL's `LOSSLESS` as one FLAC file, and `HI_RES_LOSSLESS` (up to 24-bit 192 kHz) as DASH. `src/app/player.odin` connects it to the queue, the player bar and the shell.

## Getting a stream

`tidal.resolve_stream(session, track_id, quality)` asks v1 `tracks/{id}/playbackinfopostpaywall` with `playbackmode=STREAM`, `assetpresentation=FULL` and an `audioquality`. The app calls it through `resolve_stream_flac`. A PKCE login asks for `HI_RES_LOSSLESS` first, and asks again for `LOSSLESS` if TIDAL refuses that tier: a 403, no stream at that tier, an encrypted one, or a lossy one in its place. That's riptide's rule; it found a 403 means the account isn't entitled to the tier, and that a `HI_RES_LOSSLESS` answer can carry AAC. A 401, a 429 or a 5xx isn't a refusal of the tier and fails the track as it is. The device-code login asks for `LOSSLESS` only. Either tier may come as either manifest: mare-player found the Android client gets DASH for `LOSSLESS` too. The answer carries one of two manifests:

- BTS (`application/vnd.tidal.bts`): base64 JSON with `mimeType` (`audio/flac`), `codecs`, `encryptionType` and `urls`. `resolve_stream` returns the first URL.
- DASH (`application/dash+xml`): a base64 MPD with one `Representation` (`codecs="flac"`, `mimeType="audio/mp4"`) and a `SegmentTemplate` with absolute `initialization` and `media` URLs (`$Number$` from `startNumber`, a token in the query) and a `SegmentTimeline`. `dash_info_from_mpd` expands the timeline (`t`, `d`, `r` repeat counts, `r="-1"` up to the next `t` or the end of the period) into segments with their start and length in `timescale` units. `resolve_stream` returns the initialization URL, the segments and the timescale.

Both come with the sample rate and bit depth and the ReplayGain fields `trackReplayGain`, `trackPeakAmplitude`, `albumReplayGain` and `albumPeakAmplitude`, the names tidalapi, riptide and the other reference clients read. It refuses encrypted streams (an `encryptionType` other than `NONE`, or a `ContentProtection` in the MPD) and anything that isn't FLAC. A non-FLAC manifest fails with `Lossy_Stream` and the codec as its detail. The player bar then says "TIDAL sent AAC for this login. Log in with TIDAL again for lossless." and playback stops on that track rather than failing through the queue, since every track comes the same way for that login. There's no AAC decoder. A missing gain is 0 dB and a missing peak 1.0. A track without album gain uses its track gain for both.

Resolving runs as a `Stream` job on the data workers. A stream that doesn't resolve is logged on stderr with the track id, the error kind, the HTTP status, TIDAL's `subStatus` if the body had a numeric one, and for `Lossy_Stream` the manifest's codec:

```
app: stream for track 900101 failed: Lossy_Stream, codec MP4A
app: stream for track 900101 at HI_RES_LOSSLESS failed, asking for LOSSLESS: Http, HTTP 403, subStatus 4005
```

What the server said (`userMessage`, `errors[].detail`, or the start of a body that isn't JSON) never goes to a log. A 500 from a CDN can echo a signed URL, and an error body can hold anything. That text stays in the error's detail for the player bar. `tidal.error_summary` builds the log line from the structured fields alone, and a codec or quality name gets in only if it's on a known list (`tidal.codec_name`, `tidal.quality_name`), so a manifest with a URL for a codec logs `codec unknown`. `src/tidal` follows the same rule on its own `log` calls: a failed login logs its HTTP status, a backoff its status and length, and an error response no body at all. Nothing logs a token, a stream URL, or the pasted PKCE address with its one-time code.

 Stream URLs expire, so when a download fails with a 4xx the app resolves the track once more and carries on from where it was.

## Threads and buffers

```
fetch thread per track slot --bytes--> Stream window --> decode thread --float frames--> Pcm_Ring --> audio callback --> device
```

- **Fetch.** Each of the two track slots, current and next, has a thread that downloads the file with curl into a 3 MB window: about 17 s of 16/44.1 FLAC and 5 s of 24/192, with the ring's 3 s after it. A DASH track is the initialization segment and then each media segment, fetched one after another into the same window as one run of bytes; see DASH below. The window slides forward as the decoder reads and keeps 256 KB behind the read position for short seeks back. Each request is an HTTP `Range` from where the window ends. When the window is full the thread blocks on a condition variable, so a paused track holds a connection and uses no CPU. If the server closes the connection, the thread resumes from where it got to. After 5 failures in a row, or a 4xx, the track fails. The window is a mapping of its own. When the slot's stream is cleared, by a stop, another track or none, its pages go back to the system with `MADV_FREE_REUSABLE` and stop counting against the app until bytes arrive again. It was 8 MB of heap that stayed dirty after playback stopped: after the mock's hi-res album played out, 5.9 MB of it was still counted, and none is now.
- **Decode.** One thread owns the slots and the device. It feeds dr_flac (`ma.decoder` with our own read and seek callbacks) the header bytes and then the file from whatever frame a seek started at, applies the track's ReplayGain and writes float frames into the ring. Commands and arriving bytes wake it through a semaphore. Nothing wakes it when the ring has room: while the device runs it also wakes on a timer, every 250 ms or sooner if a quarter of the ring (`LOW_WATER`) would play in less, and tops the ring up. While nothing plays (paused, stopped, or the queue ended) the device is stopped and it waits on the semaphore with no timeout.
- **Ring.** `Pcm_Ring` is a single-producer, single-consumer ring of 131,072 frames (3 s at 44.1 kHz) with atomic read and write positions. The decode thread drops everything not yet played by storing a flush position, which the callback skips to on its next call, so the writer never touches the reader's position. A queue of marks next to it says which track or seek starts at which ring position. The callback adopts each mark once it has read past it, so the status describes the frame being played.
- **Callback.** It copies frames out, ramps the volume over one buffer, adopts marks and publishes the current mark and position. It never locks, allocates, logs, waits or makes a system call, and it doesn't use the Odin context. For the seek latency log it reads `clock_ticks` (`src/audio/clock_darwin.odin`), which is `mach_absolute_time` and reads the commpage. The mark's serial, seek id and end flag and the position go out in their own atomics under a sequence count that is odd while they change, and `status` reads them again if the count was odd or moved, so it never pairs one track's or seek's mark with another's position.
- **Main thread.** The app sends commands (`play`, `stop`, `seek`, `set_next`, `set_paused`) under a mutex that the decode thread holds only to copy them, and reads a `Status` snapshot each frame. Neither waits on the network or the device. The decode thread wakes the UI when the status changes, and four times a second while playing for the progress bar.

## Queue and gapless

Double-clicking a row copies the open list into the queue and plays from that row. The rows after it follow. Each new queue gets a generation, and a preloaded track is reused only if its generation, row and track id all match, so a row of a new list never plays bytes preloaded for the old one. The play button and the toggle media command start the selected row (or the first) when nothing is loaded, start the queue again from the top once it has played out, and otherwise pause or resume. Signing out, or TIDAL ending the session, stops the player and clears the queue and Now Playing. The volume stays. It is saved in the settings file when the slider is let go. Next and previous move through the queue and skip rows without a track id. Previous restarts the track instead once it has played 3 seconds. The queue follows the list while its pages load, also after another list opens.

About 30 seconds before the current track ends, or once all of it has downloaded, the player asks for the next track. The app resolves it and hands it over with `set_next`, and its fetch thread starts downloading. When the current track's decoder runs out, the decode thread writes the next track's first frames into the ring right after the last ones, with a mark between them, so the device sees one unbroken stream. When the mark plays, the queue moves on. If the next track's stream fails to resolve, the app remembers it by queue generation, row and track id and doesn't ask for it again while the current track plays, even though the player keeps asking for a next track. When the current track ends that track becomes current, gets one more try, and if it fails again the player bar says why and the queue skips on. A new queue forgets it. If the next track has a different sample rate or channel count (or bit depth, in bit-perfect mode), the decode thread lets the ring play out and reopens the device, which leaves a short gap. While it waits it wakes as soon as the ring should be empty instead of every 250 ms, so the gap is the device's re-clock and little else (see Bit-perfect output).

## Shuffle and repeat

The queue plays its items in an order, `Playback.order`: each item once, in list order, or with shuffle on, the track that starts the queue first and the rest shuffled (`audio.queue_order`). Every "what's next" goes through it, so next, previous, the preloaded next track and the end of the queue all follow the shuffle. Turning shuffle on mid-track shuffles what comes after the current track, and turning it off goes on in list order from it. While the list's pages load, each new copy of it keeps the order up to the current track and the preloaded next one, by track id, and shuffles the rest again.

Repeat goes off, all, one. On repeat all, the end of the order goes round to its start; a shuffled queue goes round in the same order. On repeat one, the current track is preloaded as its own next track, so it loops gaplessly; next still moves on, and previous behaves as usual. A track that fails to resolve skips forward without going round, so a queue where nothing plays stops at its end instead of asking for streams forever. Changing shuffle or repeat drops a preloaded next track that isn't audible yet, and the player asks for the right one.

Album gain looks at the neighbours in play order, so a shuffled album gets track gain. Both settings are in the settings file. The play order isn't in the queue file: a restored queue with shuffle on starts with the saved track and shuffles the rest.

## Resuming after a restart

The queue, its current track and the position in it are kept in `queue.tfq` in the signed-in account's list cache folder, so the next start shows the same track paused where it was. The file is a `Queue_Header` (the current item, the position in samples and the rate it is in, and the key of the list the queue came from), then the queue's rows as a list file (`list_file.odin`), read back with the same checks as any cached list. `queue_save` writes it from the disk thread when the queue, its current track, pause, a finished seek or the end of the queue changes, but not as the position moves. While the list the queue came from is still loading, its pages don't each rewrite the file. It's written when play starts, again each time the loaded rows double, so a crash keeps at least half of them, and once more when the list has loaded or stopped on an error. `playback_shutdown` writes the last position at quit. `app_shutdown` stops the workers and the disk thread before it, so no older write can land after it, and writes any settings still waiting for a worker in between. A header with a negative position, a rate above 768 kHz or a position past a day is damaged; a position without a rate starts the track over. Stopping playback, as at sign-out, deletes it, and sign-out deletes the folder anyway. With the fake data there is no list cache, so nothing resumes.

At sign-in the file is read right after the cached sidebar. If nothing plays yet, `playback_restore` rebuilds the queue, starts its track paused at the saved position and resolves its stream at once, so play starts without a wait. If that track's stream fails, the queue moves on to the next track, still paused. The player bar shows the saved position, or a seek made since, while the stream resolves; if the stream's sample rate differs from the saved one, the position is converted. A stream URL that expired by the time play is pressed gets the same single re-resolve as during playback, from the paused position. The restored queue is never re-copied from the open list, even when that list is the one it came from.

## ReplayGain and volume

In bit-perfect mode neither applies (see below). Otherwise a track gets album gain when it plays as part of its album in order: the queue entry before or after it is from the same album, with the track number one away. Otherwise it gets track gain, so a playlist of singles plays at an even level. The factor is `10^(gain/20)`, lowered to `1/peak` if it would push the peak over full scale. The decode thread applies it. The volume slider applies after it, in the callback, as the cube of the slider's position, so half way is about -18 dB.

## Seeking

A seek shows its position in the player bar at once. It names the track it's for, and the decode thread drops it if that track no longer plays; `play` also drops a seek it hasn't applied yet, so a new track never starts at the old one's seek position. The player bar stops showing the target as soon as its track isn't current, including when the audio moved on to the next track before the seek arrived. The decode thread then looks for the frame to start from. It brackets the target with the SEEKTABLE's points, or with the first frame and the end of the file when there is no SEEKTABLE. It guesses a byte offset in proportion and looks there for a frame header that the next header confirms: sync code, CRC-8, and the next frame starting where this one's samples end. It narrows the bracket until it has a frame no more than 0.3 s before the target, decodes from there and drops the samples before the target. A guess outside the downloaded window empties it and starts a new range request at that offset, and playback goes on from those bytes. A seek inside the window doesn't touch the network.

Measured from the seek command to the first sample at the new position leaving the callback, against the mock with `-audio-delay=50 -audio-rate=400` (50 ms before each audio response, 400 KB/s per connection, about three times the stream's bitrate) and `TIDALFAST_AUDIO_WINDOW_KB=512`, seven seeks each:

| file | latencies |
|---|---|
| with SEEKTABLE | 25, 62, 101, 109, 113, 142, 278 ms |
| without | 12, 101, 103, 105, 108, 142, 311 ms |

After the callback stopped waking the decode thread, the same setup with SEEKTABLE gave 9, 96, 102, 102, 122, 132 and 300 ms.

The slowest in both is a seek to 18.7 s in a 20 s track, which needed a second probe. With the default window (8 MB then, 3 MB now) the whole mock track is already downloaded, and a seek took 9 ms. Seven seeks into the first album track while it downloads at 400 KB/s, six of them past what had arrived, took 105 to 142 ms with the 3 MB window and 101 to 140 ms with 8 MB, and the one inside the window 10 ms with either. Allowing up to 1 s before the target instead of 0.3 s made seeks that landed far from a seekpoint take 380 to 400 ms, since that second had to download and decode before being thrown away. The player logs each seek's latency to stderr.

## Media keys and Now Playing

`MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` are Obj-C classes, and Odin dev-2026-10 crashes compiling Obj-C method calls, so both live in `shell/shell.m`. The shell enables play, pause, toggle, next, previous and `changePlaybackPosition`, and turns each command into an `EVENT_MEDIA` event: `media` is the `Media_Command`, `dx` the position for a seek. The app handles them in `playback_update`, the same way as the player bar's buttons.

The app calls `Shell.set_now_playing` with the title, artist, album, duration, elapsed time, state and the cover as RGBA pixels, which an `Artwork` job fetches at 640x640. It calls it only when one of those changes, since macOS moves the elapsed time along by itself from the playback rate. The shell copies everything before it returns and rebuilds the artwork only when `artwork_key` changes. Now Playing came with platform ABI version 2; text input and accessibility made it version 3 (see [Text input](text-input.md)). Every struct the two sides share has a size check on both sides.

## Hot reload

The callback, the decode thread and the fetch threads all run dylib code. `unload` destroys the player: it stops and closes the device, joins the threads and frees the decoders. In bit-perfect mode that also puts the device back to the rate and format it had and releases hog mode, so a reload never leaves it changed with nobody to restore it. `reload` makes a new player and plays the same tracks from where they were, or from a seek's target if the seek hadn't landed yet; their URLs, and a DASH track's segment URLs, live in heap memory, not in the dylib. So a reload leaves a short silence, and the next track's download starts over. Moving the callback into the shell would avoid the silence, but the shell would need its own ring and its own marks and positions, and decoding would still stop for the reload. A short silence while developing costs less. Two reloads during playback, one right after a gapless track change, resumed at the right position.

## DASH and fMP4

A DASH slot's stream fetches URL 0, the initialization segment, then the media segments in order, each with a plain GET (and a `Range` to resume one the server cut short). Offsets count from 0 at the segment the stream last started from; it can't seek by byte, only start again at a segment (`stream_restart_segment`).

`src/audio/fmp4.odin` parses what's in it. The initialization segment's `moov` box leads to `trak/mdia/minf/stbl/stsd`, whose `fLaC` sample entry holds a `dfLa` box: FLAC's metadata blocks as they'd follow `fLaC` in a file. `parse_mp4_init` returns `"fLaC"` plus those blocks, the last one flagged last, and `mdhd`'s timescale, the track id and `trex`'s defaults. Each media segment is an optional `styp`, a `moof` and an `mdat`. `parse_mp4_moof` reads `tfhd` (track, default sample size, base offset), `tfdt` (the fragment's first sample in the track's timescale) and every `trun`'s sample sizes and data offset, which can carry on from the previous `trun`. A FLAC sample is one FLAC frame.

Data offsets count from the base ISO 14496-12 gives the `traf`: an explicit `base_data_offset` counts from the first byte of the segment file, which the stream records for each segment as it fetches them (`stream_segment_start`); `default-base-is-moof`, or neither flag in the first `traf`, counts from the `moof`. A later `traf` with neither flag would start where the previous `traf`'s data ended, which needs the other tracks' sample sizes, so it's refused with an error that says so.

Segments come from the network, so nothing in a `moof` is trusted. The demuxer reads the header of the `mdat` after each `moof` before parsing it, and every sample must lie inside that `mdat`. A `trun`'s count is checked against its own table and, when the sizes come from defaults, against what's left of the `mdat` (`count * default_size`), all before anything is appended. One fragment holds at most 65,536 samples (a 4 s segment of 192 kHz FLAC has about 190). Box sizes are checked against what holds them, 64-bit sizes above `max(i64)` are refused, and an `mdat` that runs to the end of the segment (size 0) after a `moof` is refused rather than guessed at. A broken box fails the track with the reason in the player bar. `tests/hires_test.odin` checks all of this on hand-made boxes and on 20,000 randomly damaged ones.

The decoder sees the same thing as for a FLAC file: `fLaC` and the metadata blocks (with the sample count zeroed, as for a seek), then frames. The demuxer behind it (`demux_read`) walks the boxes in order, reads each `moof`, then copies its samples out of the `mdat` that follows, and skips any other box. dr_flac decodes 24-bit samples to `v / 2^23` in float, which a 32-bit float holds exactly, so nothing on the way changes a bit.

A seek finds the segment whose start is at or before the target (`dash_segment_index`, a binary search over the timeline's starts converted to samples), starts the stream again at it, decodes from its first frame and drops the frames before the target. The first `moof`'s `tfdt` then says exactly which sample its first frame is, and that, not the MPD's arithmetic, sets how many to drop. A DASH seek always costs one segment request.

## Bit-perfect output

Off, miniaudio plays at the track's rate into an AudioUnit, and CoreAudio converts to whatever rate the device runs at and mixes with other apps. On, `src/audio/coreaudio_darwin.odin` takes the device itself through the CoreAudio HAL, which is a C API (`AudioObjectGetPropertyData`, `AudioObjectSetPropertyData`, `AudioDeviceCreateIOProcID`, `AudioDeviceStart`), declared by hand in Odin:

1. At the first track, it remembers the device's nominal rate and its output stream's physical format, to restore them.
2. With hog mode on, it takes `kAudioDevicePropertyHogMode`. Setting that property toggles it, whatever the value, so it's set only when nobody holds it and released only when this process does.
3. If `kAudioDevicePropertyAvailableNominalSampleRates` has the track's rate, it sets `kAudioDevicePropertyNominalSampleRate`, and a physical format (`kAudioStreamPropertyPhysicalFormat`) at that rate with the track's channels that holds every bit of the track: signed integers of exactly the track's bit depth if the device has them, then the smallest integer depth above it, then 32-bit float, which holds up to 24 bits exactly. A device with only 16-bit formats has nothing for a 24-bit track. It then polls every 2 ms on the decode thread, for at most 2 s, until the device reports the rate, that physical format, and a 32-bit float virtual format at the rate.
4. An IOProc fills the device's buffers from the ring (`hal_fill`). Each buffer is checked: one without data is skipped, frames come from the buffer that holds the fewest so every channel gets the same ones, and whatever is left of a buffer, frames the ring didn't have or bytes past the last whole frame, is zeroed. Mono and stereo go on the device's preferred stereo pair (`kAudioDevicePropertyPreferredChannelsForStereo`, read when the device opens), mono on both, and other device channels are silent. One interleaved buffer that already has the ring's layout is written in place; anything else, such as one buffer per channel, goes through a scratch buffer. It keeps the callback's rules: no locks, allocation, logging or system calls.

ReplayGain and the volume slider are skipped: the decode thread doesn't multiply, and the IOProc copies with a gain of exactly 1. No dither, no conversion. The IOProc sees the virtual format, 32-bit float, and the HAL converts that to the physical format. A float holding `v / 2^23` converts to the 24-bit integer `v` exactly, and the same for 16 bits. If any step above fails (a 192 kHz track on speakers that stop at 96, no format deep enough, a format or rate the device refuses or doesn't report back), the device is put back as it was and miniaudio plays that track, converted, with no ReplayGain. The Output menu then says "Not bit-perfect" and why, such as "no 24-bit format at 96 kHz".

The device it uses is the default output when the first track opens it, and it stays that device until the output is restored. While this app hogs it, it's no longer the system's default, so asking again would find another device.

The device gets its rate, format and hog mode back when bit-perfect output is turned off, on a hot reload and when the app quits (`app_shutdown`). The shell turns SIGTERM, SIGINT (Ctrl-C in the terminal) and SIGHUP (the terminal closing) into a normal quit on the main queue, so they reach `app_shutdown` too. Between tracks it isn't restored, only switched.

SIGKILL and a crash can't be caught. macOS releases hog mode with the process, but the nominal rate and physical format stay where the last track set them. So while a device is switched, the settings file also holds a `device_change` record: the device's UID, the rate and physical format it had, and the rate the app set. The decode thread publishes it in the player's status and the app saves it as soon as it changes. On a normal quit it goes away. At the next start, if the record is there, the device with that UID still runs at the rate the app set and nobody has changed it since, the app puts the old rate and format back before anything plays, then drops the record. The record is written a frame or so after the switch, so a crash in that window leaves nothing to restore from.

The decode thread also watches the device. A listener on its `kAudioDevicePropertyDeviceIsAlive` and one on the system's default output only note what changed and wake the decode thread. CoreAudio may still be running a listener after `AudioObjectRemovePropertyListener` returns, so a listener touches only the player's `Device_Watch`: the flags it sets and the semaphore it posts both live there, and the decode thread sleeps on that semaphore. The watch is never freed. After the player is destroyed nobody waits on it, and a late post does nothing. When the device has gone, as when a USB DAC is unplugged mid-track, the decode thread stops and destroys the dead output without trying to restore anything on it, and plays on from the audible position on whatever is now the default output. If nothing can open, the track fails and the player bar says so. When the default output moves to another device while this one isn't hogged, the device is put back and the track moves to the new default the same way. A hogged device stops being the default, so the default moving then is no reason to leave. miniaudio follows the default output by itself.

Gapless still works at the same rate: the ring doesn't care. A rate change lets the ring play out, stops the IOProc, sets the new rate and starts it again. The player logs the time from the last IOProc call with the old track's frames to the first with the new one's.

## Output settings

The player bar has an "Output" button, left of the volume. In bit-perfect mode it says "Bit-perfect", or the format the device plays, such as `24/96`, in cyan. It opens a menu with "Bit-perfect output" and, when that's on, "Hog mode", and a short line saying what reaches the device. A change goes to the player at once: it closes the device (restoring it) and plays on from the audible position through the new output, since the ring's frames went through the old one's gain. The settings go in `~/Library/Application Support/tidalfast/settings.json` (`{"bit_perfect": true, "hog": false, "scrollbars": "Floating"}`, plus `device_change` while a device is switched, see above) and are read when the app starts. Hog mode only counts with bit-perfect output.

## Scrollbars

Every `ui.scroll_view` draws a 6 pt scrollbar over its right edge while its content is taller than it. The "Settings" button in the sidebar's header opens a menu with three modes, saved as `scrollbars` in the settings file. Floating, the default, fades in when the view moves and out a second after it stops, unless the mouse is on it; it asks for one wake-up to hide and draws nothing in between. Docked always shows and takes a 10 pt gutter from the rows. Never draws none. Pressing the thumb drags it; pressing beside it centres the thumb there. The drag is applied when the view is built, before its rows, so the virtual rows match the new offset.

Saving goes through `settings_queue`: it makes the settings the newest, with a generation number, and has a worker save them. A save holds a mutex for the whole write, reads the newest settings when it starts, and skips the write if the file already has that generation. So with four workers there's still one write at a time, older settings never land after newer ones, and a burst of clicks makes few writes. Each write goes to a temp file of its own name, which is synced and renamed over the file. The path the workers use is Data's own copy, freed only after the workers have stopped.

## Checking hi-res and bit-perfect output

`tests/bitperfect_check` reads a capture and the integer WAVs the tracks were made from, finds each track in the capture, compares every sample's bits and reports the silence between tracks. Against the mock's hi-res album on a MacBook Air's built-in speakers:

```
./build/mock_tidal -port=8787 -hires-only
echo '{"bit_perfect": true, "hog": true}' > /tmp/settings.json
TIDALFAST_API=http://127.0.0.1:8787 TIDALFAST_KEYCHAIN=tidalfast-p6-test \
    TIDALFAST_PKCE_REDIRECT='http://127.0.0.1:8787/android/login/auth?code=mock-pkce-code-1' \
    TIDALFAST_SETTINGS=/tmp/settings.json TIDALFAST_AUDIO_CAPTURE=/tmp/cap.wav \
    TIDALFAST_REMOTE_TEST=8:play ./build/tidalfast       # Ctrl-C after about 40 s
odin run tests/bitperfect_check -- /tmp/cap.wav /tmp/tidalfast-mock-audio/hires-{a,b,c}-source.wav
security delete-generic-password -s tidalfast-p6-test
```

After the review fixes the same run gave 0 samples different in all three tracks, the 96 to 96 kHz change gapless again, and 480 frames between the 44.1 and 96 kHz tracks. Ctrl-C (SIGINT) after the album put the speakers back to 48 kHz and 32-bit float and released hog mode, and the settings file lost its `device_change`. A run killed with SIGKILL during the 24/96 track left the speakers at 96 kHz with hog mode released and the record on disk; the next start put them back to 48 kHz before anything played and dropped the record. Paused, the app's CPU time didn't move in 10 s.

What it showed:

- The speakers offer 44.1, 48, 88.2 and 96 kHz, all as 2-channel 32-bit float only, and ran at 48 kHz before. A second process reading `kAudioDevicePropertyNominalSampleRate` every 2 ms saw 48000, then 44100 when the 16/44.1 track started, 96000 when the first 24/96 track started, and 48000 again when the app quit, with hog mode held by the app's pid from the first track to the quit and released after.
- All three tracks reached the IOProc unchanged: 352,800 frames of 16/44.1, then 960,000 and 576,000 frames of 24/96, 0 samples different, in runs with hog mode off and on, and with a pause in the middle.
- 44.1 to 96 kHz: 36 to 40 ms from the IOProc's last call with 44.1 kHz frames to its first with 96 kHz ones, of which setting the rate took 10 to 15 ms. The 96 to 96 kHz change between the two hi-res tracks was gapless: no frame between them.
- A hot reload (`./build.sh app`) during the 24/96 track with hog mode on put the speakers back to 48 kHz, then the new player took them back to 96 kHz with hog mode and played on. Quitting restored 48 kHz.
- Paused, the app used no CPU: its CPU time didn't move in 10 s.

`tests/hires_test.odin` checks the parts without a device: the MPD's timeline with repeat counts and jumps, the `moov`/`dfLa`/`moof`/`trun` parsing (64-bit box sizes, default sizes, `trun`s without a data offset), 24-bit samples through fMP4 and dr_flac with no bit changed, segment lookup for seeks, a DASH track played by the player on the null device in bit-perfect mode with every sample exact and a seek into the second segment starting exactly at its target, turning bit-perfect on mid-track, the PKCE redirect parsing and exchange against the test mock, the Keychain's client id, and the settings file. Since the review it also checks `moof` bounds on hand-made and randomly damaged boxes, both base offset rules and a DASH track with an explicit `base_data_offset` played bit for bit, `hal_fill` against buffer lists of several shapes, the choice of a physical format deep enough, the Output menu's reason, a simulated device loss (`audio.simulate_device_loss`, test builds only), four threads saving settings at once while another reads the file, and the settings path outliving `playback_shutdown`. `tests/login_test.odin` checks that a superseded device login is dropped and that a PKCE login retries with its tokens, before and after a reload. `tests/android_login_test.odin` checks the address validation, the login screen's states (PKCE first, a bad address, a good one, a failed exchange, the switch to a code), a `Login_Pkce` the full queue refused going out again, the AAC notice for a device-client login and logging in again over it, the AAC line in the player bar, the quality fallback against the test mock, a device code that arrives after the switch to the PKCE login, a next track that fails to resolve being asked for once and not again until it's current, and that hostile error bodies (a signed URL in `userMessage`, `errors[].detail`, a non-JSON body, an anti-abuse 403 and a manifest's codec) never reach the app's stream error line or what `src/tidal` logs.

Against `tests/mock_tidal -hires-only`, a device login made with "Log in with a code instead" (through `TIDALFAST_SHELL_TEST`'s `ax-press`) showed the AAC notice, and play put the AAC line in the player bar, with the `Lossy_Stream` line on stderr. Started again with that login in the Keychain, the notice was there from the start. A PKCE login through `TIDALFAST_PKCE_REDIRECT` played the album: 16/44.1 BTS, then both 24/96 tracks as DASH. With `-refuse-hires -lossless-dash` each track logged the 403 and played as `LOSSLESS` FLAC in DASH.

Not checked here, for want of an account or a DAC:

- That TIDAL still gives the Android client hi-res, and the real MPDs and segments. The MPD parser follows the shape of the TIDAL manifest in `tests/tidal_test.odin`, and a `ContentProtection` or `mp4a` answer is refused rather than played.
- A device with integer physical formats: picking a 24-bit integer format for a 24-bit track, and falling back with "Not bit-perfect" on a 16-bit-only device, are written and tested only against made-up format lists, since the built-in speakers are float only. So is anything above 96 kHz. A device with more than one output buffer or more channels than the track is tested only with made-up buffer lists.
- Unplugging a DAC mid-track and the default output changing: the listeners are registered against the real HAL, but the handling is tested only through `simulate_device_loss`, since this machine has no second output to switch to.
- What a USB DAC does while it re-clocks (some click or mute for longer), and how long it takes.
- Another app holding hog mode.

## Without an account

- The mock's first three liked tracks are a live album: three FLAC files cut from one continuous sine sweep with a little noise, at lengths that aren't whole FLAC frames, with an album gain of -6.02 dB and different track gains. Every other track plays one of four tones. The mock makes them at start as WAV, encodes them with `afconvert -f flac -d flac`, and adds a SEEKTABLE with a point every 2 s and a PADDING block, which afconvert leaves out. It serves the files with `Range` support.
- `TIDALFAST_FAKE=1` plays a 30-second sine tone for each fake row, so the player bar, queue, seeking and Now Playing work without any server.

To check gapless playback, play the album through with `TIDALFAST_AUDIO_CAPTURE` and compare the capture with the sweep:

```
./build/mock_tidal -port=8787
TIDALFAST_API=http://127.0.0.1:8787 TIDALFAST_KEYCHAIN=tidalfast-gapless-test \
    TIDALFAST_PKCE_REDIRECT='http://127.0.0.1:8787/android/login/auth?code=mock-pkce-code-1' \
    TIDALFAST_AUDIO_NULL=1 TIDALFAST_AUDIO_CAPTURE=/tmp/cap.wav \
    TIDALFAST_REMOTE_TEST=8:play ./build/tidalfast     # quit after about 60 s
security delete-generic-password -s tidalfast-gapless-test
odin run tests/audio_check -o:speed -- /tmp/cap.wav /tmp/tidalfast-mock-audio/album-source.wav 883234 1633711
```

`audio_check` finds where the sweep starts in the capture, fits the gain, and compares every frame after the first buffer's volume ramp with the source times that gain. A gap, a repeated or dropped frame, or a gain change at a track boundary fails it. The numbers after the files are the boundaries' source frames, which it reports on. It passes: 2,163,136 frames (49.05 s) across both boundaries, 0 samples off, a largest error of 6.3e-9 (float rounding), at x0.1715, which is the album gain of x0.5 times the default volume of 0.7 cubed.

`tests/player_test.odin` sends media commands through `playback_update` with the fake data on the null device, and checks the queue, the player's position after a seek, and what goes to Now Playing. It also checks that a new list's row doesn't take the old list's preloaded track, that the toggle starts playback from idle and after the end, and that a seek still pending when the track changes or the app reloads doesn't pin the player bar. Those four feed made-up player statuses to `playback_observe`, the half of `playback_update` that reads the status, so they run without waiting on the audio. `tests/audio_test.odin` checks on the null device that `play` drops a pending seek, that `status` never pairs a mark with another mark's position, that the callback never posts the decode thread's semaphore, and that a listener still running after its player is destroyed touches nothing the player owned.

## CPU

Apple M1, the mock album playing to the null device: 1.5% with an optimized dylib and about 4% with a debug one, mostly the four UI frames a second for the progress bar. Paused, the device is stopped and the decode thread sleeps on its semaphore: 0.0%.

Measured again after the callback stopped waking the decode thread, with CPU time from `ps`: the fake tones with an optimized dylib use 0.20 s in 15 s of playing (1.3%), and nothing in 7 s idle before playing or 20 s paused. The mock album with a debug dylib uses 2.3 to 3.6%, and nothing in 20 s paused once the next track's download has filled its window.
