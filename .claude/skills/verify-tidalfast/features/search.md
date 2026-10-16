# Search

The search field at the top of the sidebar finds songs, albums, artists and playlists. The songs become the open track list. Tabs above the table switch between the four result kinds. `docs/search.md` has the details.

## Sub-features

- `search-focus`: Cmd-F or Cmd-L focuses the field with its text selected.
- `search-results`: typing searches after a 250 ms pause, and the table shows "Results for “query”" with tab counts.
- `search-tabs`: the Albums, Artists and Playlists tabs show the other result kinds as rows.
- `search-open`: an album, artist or playlist result opens as its own track list.
- `search-ime`: nothing searches while the input method has marked text.
- `search-clear`: Escape or deleting the text closes the search and reopens the sidebar's list.
- `search-layout`: the results lay out at 820, 1100 and 1600 pt.

## How to get to it (user POV)

- Press Cmd-F or Cmd-L anywhere, then type.
- Click the search field at the top of the sidebar.

## Driving it with verify.sh

- **Results at three widths.** Run `$V search "Jóga"` (fake) or `$V search "Jóga" mock`. It focuses with `key=cmd+f`, types with `commit=`, captures `search-1100.png`, `search-820.png` and `search-1600.png`, dumps the accessibility tree and checks the log and widths. Fake mode logs `search: "Jóga": 145 songs, 26 albums, 34 artists, 0 playlists`. The mock logs `50 songs, 50 albums, 12 artists` and the table header later shows `203` songs as more pages arrive. Each PNG shows the heading "Results for “Jóga”", the tabs and rows titled Jóga.
- **Tabs.** `$V run tabs fake "3:size=1100,700;3.5:key=cmd+f;4:commit=Jóga;6:ax-press=Albums ;7.5:capture=@albums;8:ax-dump;8.5:quit"`. The PNG shows album rows, and the dump lists `AXButton "Albums  26"`.
- **Open a result.** Add `;9:ax-press=<album label from the dump>;10.5:capture=@album` before `quit`. The heading becomes the album's name.
- **Input method.** `3.5:key=cmd+f;4:mark=にほんご;4.6:ime;5:capture=@marked;5.5:commit=日本語;8:capture=@committed`. `app.log` has no `search:` line between the `mark` and `commit` steps, and one for `日本語` after.
- **Clear.** After results, `key=escape` then `capture=@cleared`. The table shows the sidebar's list again.

## Gotchas

- `commit=` text runs to the next `;`, so a query can't contain `;` or `|`.
- Capture at least 2 s after typing. The first results come after the debounce, and in mock mode after a round trip.
- Search tab labels have two spaces between the name and the count.
- Opening any list ends a search still waiting for its answer. Don't press a sidebar row before the results capture.
