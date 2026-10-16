# Playback

Double-clicking or pressing Return on a track row plays it. The player bar at the bottom shows the track with Previous, Play/Pause and Next, a position slider and a volume slider. The next track is resolved ahead for gapless playback. `docs/playback.md` has the details.

## Sub-features

- `playback-start`: a track row plays and the player bar shows it.
- `playback-controls`: Play/Pause, Previous and Next.
- `playback-gapless`: consecutive tracks play without a gap.
- `playback-output`: what reaches the output device, recorded as a WAV.

## How to get to it (user POV)

- Double-click a track row, or select it and press Return.
- Use the buttons in the player bar.

## Driving it with verify.sh

- **Play a search result.** `AUDIO_CAPTURE=1 $V run play mock "8:size=1100,700;8.5:key=cmd+f;9:commit=Jóga;11:ax-press=Jóga, ;14:capture=@playing;14.5:ax-dump;15:quit"`. `app.log` has `shell: ax: pressing AXRow "Jóga, ..."`, then `app: track N resolved: LOSSLESS FLAC, 16-bit 44100 Hz` and `audio: null device open at 44100 Hz`. The next track resolves right after. The PNG shows the track in the player bar, and `afinfo audio.wav` reports a few seconds of 2 ch 44100 Hz Float32.
- **Fake tones.** The same in fake mode plays a 30 s sine tone per row. Use it for player bar layout. It has no network or decoder path.
- **Gapless.** Follow "To check gapless playback" in `docs/playback.md` with `audio.wav` from a mock run, and compare it with `tests/audio_check`.

## Gotchas

- `verify.sh` always plays to the null device. The capture still records what would reach the speakers.
- The mock's audio lives in `/tmp/tidalfast-verify/run/mock-audio` and goes away at cleanup. Copy a source WAV into the evidence directory before cleanup if a comparison needs it later.
- Don't test bit-perfect mode with this script. It changes the real output device; `AGENTS.md` says how to do it safely.
- A capture taken right after the press can still show "Nothing playing". Wait 3 s.
