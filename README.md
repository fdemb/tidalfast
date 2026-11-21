<h1>
<p align="center">
  <img src="docs/icon.png" alt="TIDALfast icon" width="128">
  <br>TIDALfast
</p>
</h1>
<p align="center">
  Finally, a better desktop TIDAL app. 
  <br>
  Focused on performance, small footprint and great UI feel without sacrificing modern UI niceties.
  <br>
  <br>
  <a href="#about">About</a>
  ·
  <a href="https://github.com/fdemb/tidalfast/releases">Download</a>
  ·
  <a href="#status">Status</a>
  ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <img src="docs/image.png" alt="Home page in TIDALfast" width="900">
</p>

## About

TIDALfast is a TIDAL player written from scratch in Odin.

## Features

- **Lossless and hi-res.** TIDAL's FLAC streams, from CD quality up to 24-bit 192 kHz.
- **Gapless playback.** The next track downloads before the current one ends and plays straight after it, so live albums and DJ mixes play without a break.
- **Bit-perfect output.** The app can play each track at its own sample rate and send your DAC the samples unchanged: through the CoreAudio HAL on macOS, PipeWire on Linux and WASAPI's exclusive mode on Windows. When a track can't play bit-perfect, the app tells you why.
- **ReplayGain.** Albums played in order get album gain, and everything else gets track gain, so a playlist of singles plays at one level.
- **Your library.** Playlists, Liked Songs and followed artists from your account. Make a playlist with the + by Your Library, rename or delete your own from its More menu, drag a song onto a playlist to add it, or click its heart to like it.
- **Search and artist pages.** Results for songs, albums, artists and playlists show as you type. Artist pages have top tracks, albums, EPs and singles, appearances and similar artists.
- **Media keys and Now Playing.** The keyboard's media keys and the system's media controls show the track and control playback: Control Center on macOS, MPRIS on Linux and the media overlay on Windows.
- **Keyboard and VoiceOver.** Tab, the arrow keys and Enter reach every control, and VoiceOver reads them on macOS. Screen readers on Linux and Windows don't see them yet.
- **Every script.** Right-to-left text, emoji, and input methods for Japanese, Chinese and Korean in the search field.

## Download

Get it from [Releases](https://github.com/fdemb/tidalfast/releases): a .dmg for macOS, an AppImage for Linux and a .zip for Windows. You need a TIDAL subscription.

The macOS app isn't notarized yet, so Gatekeeper blocks it the first time. Allow it in System Settings > Privacy & Security, or run:

```bash
xattr -dr com.apple.quarantine /Applications/TIDALfast.app
```

## Status

TIDALfast is in early pre-release, so expect rough edges.

## Contributing

To build TIDALfast from source or work on it, read [CONTRIBUTING.md](CONTRIBUTING.md). [docs/architecture.md](docs/architecture.md) explains how the app fits together.

TIDALfast isn't affiliated with or endorsed by TIDAL.
