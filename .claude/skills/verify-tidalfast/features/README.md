# TIDALfast verification map

The maintained recipes for proving TIDALfast's user-facing features. Read `../SKILL.md` first for `verify.sh`, the step syntax and the proof rules, then the file for your feature.

| Feature | File | Modes |
| --- | --- | --- |
| Search | [search.md](search.md) | fake, mock |
| Library and lists | [library.md](library.md) | fake, mock |
| Playback | [playback.md](playback.md) | fake, mock |
| Login against the mock | [login.md](login.md) | mock |

## Baseline preconditions

- `$V build` is newer than the source, and `$V doctor` prints `doctor: ready`.
- Mock recipes need `$V mock-start`. The mock serves 1433 liked tracks, a 3000-track `Mock Long Playlist`, and search answers for any query.
- Fake recipes use the 10,000 fake rows. "Jóga" matches 145 songs from 26 albums and 34 artists.
- Start every recipe from a fresh launch. `$V run` always launches one.

## Driving conventions

- `V=.claude/skills/verify-tidalfast/verify.sh`, run from the repo root.
- Start input at 3 s in fake mode and 8 s in mock mode.
- Begin with `size=` so the capture width is known. Use 820, 1100 and 1600 pt for layout work.
- Find labels with `ax-dump` before writing an `ax-press`.
- End every script with `quit`.

## Proof and skip reporting

- A proof is the evidence directory: `steps.txt`, `app.log` and the PNGs you looked at.
- When a journey can't run, report it as failed with the reason. Don't drop steps to make it pass.
- Say which mode a proof used. A fake-mode proof says nothing about the network path.
