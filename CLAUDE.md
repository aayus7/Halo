# Halo: project context for Claude

Read this first. It carries the history from the first planning session (Nov 2026).

## Who / what
- Owner: **Aa** (GitHub `aayus7`). Personal project: "the best music player for me" on **iPhone**. We build it together.
- Baselines studied:
  - **BitChord** (github.com/kushagrasinghx/BitChord, v1.9.1): an Android YouTube Music client. Features: bit-perfect USB DAC output, Automix (beat-matched DJ transitions), crossfade, word-synced lyrics, Top Picks from listening history, auto-updating playlists, sleep timer, downloads, Last.fm.
  - **Eclipse** (eclipsemusic.app): a cross-platform player for your own library. Features: addons via install URL, Jam sessions, Connect handoff, synced lyrics, now-playing skins, 10-band EQ, crossfade, CarPlay.
- Goal: **the middle ground**. A polished native player with **Eclipse-style addon support** as the core, plus local files and BitChord-style smarts and UI polish.

## Build & install (no Mac)
- The owner has a **Windows PC** and an **Apple developer certificate**. They sign and install IPAs themselves (e.g. Sideloadly/ESign/Feather). Don't worry about signing.
- **GitHub Actions** (`.github/workflows/build.yml`, `macos-15`) runs XcodeGen, then `xcodebuild` with signing off, and uploads the artifact `Halo-unsigned-ipa` plus `build-log`.
- No `.xcodeproj` is committed. `project.yml` (XcodeGen) is the source of truth. Info.plist is generated from `project.yml`.
- Claude can't compile Swift locally, because download.swift.org is blocked in the sandbox. **CI is the compiler**: push, watch the run, read `build-log`, fix, repeat.
- v0.1 was written blind and has **never been compiled**. The first job is to get CI green.

## Architecture (SwiftUI, iOS 17+, Swift 5 language mode, @Observable)
- `Halo/App/HaloApp.swift`: creates `LibraryStore`, `AddonStore` and `PlayerEngine`, injects them via `.environment`, and sets `Theme` colors.
- `Halo/Models/Track.swift`: `Track` (source `.local(fileName)` or `.addon(addonID, trackID)`), `StreamInfo`, `RepeatMode`, `formatTime`.
- `Halo/Addons/`: `AddonModels` (wire format), `AddonClient` (HTTP), `AddonStore` (installed addons, persisted to JSON).
- `Halo/Library/LibraryStore.swift`: local files in Documents/Music (Files-app visible), likes, history, play counts, `mostPlayed`, `topPicks`, embedded-artwork extraction.
- `Halo/Player/PlayerEngine.swift`: AVPlayer, queue, shuffle/repeat, lazy stream resolve + prefetch of the next track, lock screen (MPNowPlayingInfoCenter / MPRemoteCommandCenter), interruptions, auto-skip on failure.
- `Halo/Views/`: Root (4 tabs + mini player via safeAreaInset), Home (shelves), Search (local + all addons in parallel), Library, Addons, NowPlaying (+ queue, AirPlay), Components.
- Persistence: JSON files in Application Support/Halo (`Store`/`Paths` in `Support/Persistence.swift`).

## Addon protocol
- The same protocol as Eclipse/BitChord: an HTTP server with `/manifest.json`, `/search?q=` (returns `{tracks:[…]}`) and `/stream/{id}` (returns `{url,…}`). Full detail is in `docs/ADDON_SPEC.md`.
- It was checked against BitChord's source (`app/src/main/java/com/music/bitchord/data/sources/addon/AddonModels.kt` and `AddonClient.kt`):
  - Manifest `settings[].default` values are sent as query params.
  - Only a trailing `*.json` is stripped from the install URL (tokens live in the path).
  - Stream `error`/`encrypted`/`manifest` fields are honoured. DASH is refused (AVPlayer can't play it). HLS is fine.
  - 404 means "not found". 429 is retried.
- `addon-example/worker.js` is a Cloudflare Worker test addon for Internet Archive audio.

## Roadmap (agreed direction, in rough priority)
1. Get CI building, then fix runtime bugs the owner reports from the device.
2. Synced lyrics (LRCLIB first).
3. Crossfade / gapless playback.
4. Playlists.
5. Album and artist pages.
6. Offline downloads for addon tracks (respect `allowDownloads`).
7. EQ.
8. Now-playing skins / dynamic artwork theming.
9. Last.fm scrobbling.
10. CarPlay, widgets and a Live Activity.
11. Smarter recommendations (Automix-style transitions later).

## Working style
- The owner is enthusiastic and casual. Keep replies short, ship working builds, and ask before big direction changes.
- The player stays source-agnostic. Addons decide where audio comes from.
