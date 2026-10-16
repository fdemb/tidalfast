# Library and lists

The sidebar lists Liked Songs and the user's playlists. Picking one opens it as a virtualized track table with covers. Track rows link to their artist and album. `docs/ui.md` and `docs/tidal-data.md` have the details.

## Sub-features

- `library-sidebar`: the sidebar lists playlists with their song counts.
- `library-open`: picking a sidebar row opens its tracks.
- `library-scroll`: a long list scrolls and loads covers as rows come into view.
- `library-links`: artist and album names in a row open the artist's top tracks or the album.
- `library-refresh`: a playlist changed on the server updates in the app (mock only).

## How to get to it (user POV)

- Click a row in the sidebar.
- Click an artist or album name in a track row.

## Driving it with verify.sh

- **Open a playlist.** `$V run open mock "8:size=1100,700;8.5:ax-dump;9:ax-press=Mock Long Playlist;11:capture=@long;11.5:quit"`. The PNG shows the heading Mock Long Playlist and 3000 songs. `app.log` has the playlist's track requests with `HTTP 200`.
- **Follow a link.** After a list opens, `ax-dump` lists each row's artist and album as `AXButton`s. `ax-press=<artist name>` opens the artist's top tracks. Capture it.
- **Server change.** With the mock running, `curl "$(cat /tmp/tidalfast-verify/run/mock.url)/mock/change?playlist=1"` adds a track to playlist 1. Run the app after the curl, open the playlist and check the count in the PNG.
- **Fake library.** In fake mode the first sidebar row is `Liked Songs, Playlist · 10000 songs`.

## Gotchas

- Sidebar row labels are `name, Playlist · N songs`. `ax-press` matches a prefix, so the name alone is enough.
- Only the rows in view are in the accessibility tree. Scroll before pressing a row further down.
- The mock serves covers with a 40 ms delay. Capture 2 s after opening a list, or the covers are still placeholders.
