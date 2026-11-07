# Halo

A personal iPhone music player. It sits between BitChord and Eclipse: a native SwiftUI player with **Eclipse-compatible addon support** plus your own local files.

## What's in v0.1

- **Addons**: paste any Eclipse/BitChord-style addon URL. Search across all enabled addons at once. Streams are resolved lazily, and the next track is prefetched. See [`docs/ADDON_SPEC.md`](docs/ADDON_SPEC.md).
- **Local library**: import files (MP3, AAC, ALAC, FLAC, WAV, AIFF), or drop them into Files › On My iPhone › Halo › Music and pull to refresh.
- **Player**: queue, play next, add to queue, shuffle, and repeat (off / all / one). Background audio, lock screen and Control Center controls, AirPlay, and interruption handling.
- **Home**: Recently Played, Top Picks, On Repeat, Liked Songs, and On This iPhone.
- **Likes and history**, saved on the device.

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
