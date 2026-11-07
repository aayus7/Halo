# Halo

A personal iPhone music player. It sits between BitChord and Eclipse: a native SwiftUI player with **Eclipse-compatible addon support** plus your own local files.

## What's in v0.2

- **Liquid Glass UI** (iOS 26) modelled on Chroma: full-bleed artwork player, heavy type, a glass mini player and tab bar, and pages tinted with artwork colours.
- **Addons**: the full Eclipse protocol. Search covers songs, albums, artists and playlists; there are album, artist and playlist pages, Home rows from addon catalogs, per-addon settings (including per-network ones), notices, ISRC/resolve matching, podcast and audiobook modes, and stream info. See [`docs/ADDON_SPEC.md`](docs/ADDON_SPEC.md).
- **Spotify Home import**: connect your own Spotify app (Settings › Spotify Import). Home fills with your mixes, playlists, top songs, saved albums and artists. Songs play through your addons.
- **Artwork**: hi-res covers from Apple, and animated covers with your own MusicKit token ([`docs/ANIMATED_ARTWORK.md`](docs/ANIMATED_ARTWORK.md)).
- **Lyrics**: synced, word by word, with the other lines blurred (LRCLIB, or a `.lrc` file next to a local song).
- **Playback**: gapless, crossfade (0–12 s), a 10-band EQ with presets, bass boost, stereo width, speed with or without pitch, a sleep timer, and the queue.
- **Library**: playlists, likes, history, and local files (MP3, AAC, ALAC, FLAC, WAV, AIFF).

Requires **iOS 26**.

## Building (no Mac needed)

GitHub Actions builds an **unsigned IPA** on every push to `main`:

1. Push this repo to GitHub.
2. Open **Actions → Build IPA**, then the latest run.
3. Download the **Halo-unsigned-ipa** artifact and unzip it.
4. Sign and install `Halo-unsigned.ipa` with your certificate (Sideloadly, ESign, Feather, etc.).

If a build fails, download the `build-log` artifact and send it over.

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen), so there's no `.xcodeproj` checked in.

## Try an addon

`addon-example/worker.js` is a tiny addon for the Internet Archive's free music. Deploy it to Cloudflare Workers (free), then paste its `/manifest.json` URL into the Addons tab.

## Roadmap ideas

- Synced lyrics (LRCLIB)
- Crossfade / gapless playback
- EQ
- Offline downloads for addon tracks
- Playlists
- Album and artist pages
- Now-playing skins
- CarPlay
- Last.fm scrobbling
- Widgets / Live Activity
- Smarter recommendations
