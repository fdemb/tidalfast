---
name: verify-tidalfast
description: Drive a private TIDALfast instance on macOS to prove a change in the real app. Builds into /tmp/tidalfast-verify, runs with fake data or against tests/mock_tidal, scripts keys, typing and accessibility presses through TIDALFAST_SHELL_TEST, and captures PNGs at chosen window sizes, logs and audio. Use it to check a UI, search, list or playback change without touching the user's app, keychain or TIDAL account.
---

# Verify TIDALfast

TIDALfast is a native window. You can't see it, the screen may be locked, and the user runs AeroSpace, a tiling window manager that resizes every new window. `verify.sh` in this directory handles all of that. It builds its own copy of the app, launches it with private settings, cache and keychain item, floats the window so resizes stick, plays a timed script of input, and leaves PNGs and logs in an evidence directory.

Read `AGENTS.md` at the repo root first. Its "Things that hurt the user" section applies to every run.

```
V=.claude/skills/verify-tidalfast/verify.sh
$V build                        # shell, app dylib and mock into /tmp/tidalfast-verify/bin
$V doctor                       # is this setup worth driving?
$V search "Jóga"                # the search proof at 1100, 820 and 1600 pt, fake data
$V mock-start                   # then the same against the mock server:
$V search "Jóga" mock
$V run <label> <fake|mock> "<steps>"   # any other journey
$V cleanup                      # stop what we started, delete the test keychain item
```

## Launch

`$V build` compiles `shell/shell.m`, `src/app` and `tests/mock_tidal` into `/tmp/tidalfast-verify/bin`. It never writes `build/tidalfast` or `build/app.dylib`, so the user's running debug build doesn't hot-reload your work and the user's shell keeps its Keychain signature. The dylib is optimized with `-define:TIDALFAST_MOCK_API=true`, as `./build.sh measure` does, so it honours `TIDALFAST_API` and `TIDALFAST_PKCE_REDIRECT`. A build takes about 40 s. Rebuild after every source change; `doctor` fails when `src/` or `shell/` is newer than the build.

There are two data modes:

- `fake` sets `TIDALFAST_FAKE=1`: 10,000 fake rows, sine tones, no network and no keychain at all. Search runs on the UI thread. Use it for layout and anything that doesn't need the network path.
- `mock` needs `$V mock-start` first. It starts `tests/mock_tidal -port=0` and records its URL. The app logs in at start through `TIDALFAST_PKCE_REDIRECT`, stores the login in a keychain item named `tidalfast-verify-<random>`, and sends every request to the mock. `TIDALFAST_LOG_HTTP=1` is on, so `app.log` lists each request with its status.

`$V run` starts the app with `env -i`, so no `TIDALFAST_` variable from your shell leaks in. It always sets `TIDALFAST_AUDIO_NULL=1`. Nothing ever reaches the speakers.

The app is ready when `app.log` shows `app: started`. In mock mode it is logged in when `GET .../users/123/playlistsAndFavoritePlaylists: HTTP 200` appears, which takes under a second. Steps can't wait on log lines, so the script starts input at 3 s (fake) or 8 s (mock), well after both.

Teardown happens on its own: the last step is `quit`. If the app is still up 15 s after the last step, `run` kills it by PID.

## Doctor

`$V doctor` is read-only. It checks that the three binaries exist and are newer than every file in `src/` and `shell/`, that the shell has the `size=` step, that no app from an earlier run is still up, that a recorded mock answers HTTP, and that the AeroSpace CLI answers if AeroSpace runs. It lists leftover `tidalfast-verify-*` keychain items. Run it first, and again whenever a run fails in a way you don't understand. It prints `doctor: ready` or `doctor: not ready` with a `FAIL` line per problem.

## Drive

`$V run <label> <fake|mock> "<steps>"` passes the steps to `TIDALFAST_SHELL_TEST`. Steps are `seconds:command[=arg]`, separated by `;`. Several commands at one time go together, separated by `|`. Times count from the window appearing. The commands, all from `test_step` in `shell/shell.m`:

| Step | What it does |
| --- | --- |
| `key=cmd+f` | a key press with modifiers `cmd`, `shift`, `opt`, `ctrl`. Named keys: `return`, `tab`, `space`, `backspace`, `escape`, `delete`, `home`, `end`, `left`, `right`, `up`, `down`, and single characters |
| `commit=text` | text typed through the input method, as a keyboard would |
| `mark=text`, `unmark`, `commit-marked=text`, `mark-range=loc,len,text`, `commit-range=loc,len,text` | input method composition |
| `ime` | logs the text field's input method state |
| `size=w,h` | resizes the window's content to w by h points |
| `ax-dump` | logs the accessibility tree: role, label, value, frame, `focused`, `press` |
| `ax-press=prefix` | presses the first pressable element whose label or value starts with prefix |
| `capture=@name` | copies the last presented frame to `name.png` in the evidence directory |
| `hide`, `unhide` | hides the app and shows it again, as Cmd-H and clicking its Dock icon do |
| `quit` | quits the app |

Prefer `ax-press` with a label from `ax-dump` over keys that depend on focus. Labels are in the app's words: search tabs are `Songs  203` (two spaces), track rows are `title, artist, album`, sidebar rows are `name, Playlist · N songs`. `ax-press` on a track row plays it, on a sidebar row opens the playlist, and on a button clicks it.

Allow 1.5 s between `size=` and a `capture`, and 2 s between typing a query and capturing results: the search debounce is 250 ms and the mock needs a round trip.

Set `AUDIO_CAPTURE=1` before `$V run` to record what reaches the null device in `audio.wav`. Set `BLUR_REFERENCE=<material>[,<height>]` to pass `TIDALFAST_BLUR_REFERENCE` (see `docs/ui.md`); the captures show the content under the bar without AppKit's blur, which only the screen shows.

`run` sets `TIDALFAST_CAPTURE` only when the steps have a `capture=`. With it the window's drawables stay full size while it's covered or hidden. Without it the shell shrinks them to a pixel then, so a run that measures memory around `hide` and `unhide` must not capture.

The features in `features/` are the maintained recipes. Read `features/README.md` and the file for the feature you're proving.

## Evidence

Each run writes to `/tmp/tidalfast-verify/evidence/<date>-<time>-<label>/`:

- `steps.txt`, the exact script that ran.
- `app.log`, the app's stderr: test steps as they fire, `search:` lines, HTTP requests in mock mode, the `ax-dump` tree.
- `<name>.png` for each `capture=@name`, at 2x on a Retina screen.
- `audio.wav` with `AUDIO_CAPTURE=1`.

`$V search` also checks its own result. It fails unless `app.log` has `search: "<query>": N songs` and the three PNGs are 820, 1100 and 1600 points wide at one scale. A failed width check almost always means the window wasn't floated.

A proof follows these rules:

- Drive the path a user takes: keys, typing and accessibility presses through the shell's real entry points. Don't add test-only code paths.
- Capture the state after the action, and log the action. `steps.txt` plus `app.log` show what was done. The PNG shows what came of it.
- Look at the PNGs. A file that exists proves nothing. Read them at 1:1 crops for text, or downscale with `sips -Z 900 in.png --out small.png` to check layout.
- Check side effects alongside the picture: the HTTP lines in `app.log` for requests, `audio.wav` for playback, `settings.json` in `/tmp/tidalfast-verify/run/` for saved settings.
- Fake mode bypasses the network, the worker jobs and the keychain. A change in any of those needs a mock run.

## Cleanup

`$V cleanup` kills the app and mock it recorded, by PID and only if they run from `/tmp/tidalfast-verify/bin`. It deletes every `tidalfast-verify-*` keychain item it created, then removes `/tmp/tidalfast-verify/run`. It keeps `bin/` (`$V cleanup --bin` removes it too) and never touches `evidence/`. Run it after every session, and after any failed run before you retry.

Never `pkill tidalfast`. The user may have the real app open.

## Safety

- The real keychain item is service `tidalfast`. Fake mode never touches a keychain. Mock mode uses `tidalfast-verify-<random>`, and `cleanup` deletes only names with that prefix. Never pass `TIDALFAST_KEYCHAIN=tidalfast`.
- Never point a run at real TIDAL. The app refuses a `TIDALFAST_API` that isn't loopback, and `env -i` keeps your shell's variables out.
- Start the mock only with `mock-start`. `run` and `doctor` refuse a `mock.url` that is empty or not a loopback `http` URL, and the app shows the fake data instead of the real login when `TIDALFAST_KEYCHAIN` comes without a mock URL it takes.
- The app takes focus when it starts, and AeroSpace may switch to its workspace. Tell the user before a long series of runs.
- Bit-perfect mode changes the output device. Don't turn it on here. `AGENTS.md` and `docs/playback.md` cover how to test it.

## Limits

- `verify.sh` is macOS only. On Linux, run the Wayland shell under headless weston as `docs/linux.md` shows. Its shell test steps include `size=` too.
- Without AeroSpace, `float_window` does nothing and `size=` works as is. Another tiling window manager needs its own float command in `float_window`.
- The window can be larger than the screen. macOS still renders and captures it.
