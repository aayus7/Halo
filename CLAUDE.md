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
- **Tests gate the IPA.** `HaloTests/` runs on an iOS simulator in CI before the build. It uses mock addons (`MockAddonProtocol`) built from real manifests (`HaloTests/Fixtures/tido-manifest.json`) and plays a generated WAV through the real `PlayerEngine`. Add a test for every device bug the owner reports, and never hand over an IPA from a red run.
- Claude can't compile Swift locally, because download.swift.org is blocked in the sandbox. **CI is the compiler**: push, watch the run, read `build-log`, fix, repeat.
- CI is green as of v0.2. It uses `setup-xcode latest-stable` (Xcode 26.3, iOS 26.2 SDK, Swift 6.2). Helper: wait for the run, then grep the job log for `error:`.

## Direction (owner, Nov 2026)
- **UI target: Chroma (chroma.pw) / spoti.pw look.** Liquid Glass, true black, heavy type, artwork-tinted pages. The owner shared screenshots: full-bleed artwork player with a heavy title and ✕ ☆ ⋯, a thin scrubber, lyrics/AirPlay/queue along the bottom; word-by-word lyrics with blurred neighbouring lines; Home with a hero "Radio" carousel and a 2-column tinted shortcut grid; playlist page with a centred cover and shuffle · Play · +.
- spoti.pw is **PolyForm Strict**: read it for ideas only, never copy its code. BitChord is GPL-3.
- **Home import from Spotify** via the official Web API (PKCE, the user's own Client ID, redirect `halo://spotify-callback`). Spotify blocks its algorithmic playlists for new apps, so "Mixes" are built from top artists. Imported songs are `.catalog` tracks that get matched to addons (ISRC → `/resolve` → scored search).
- **Playback fallback = the addon chain.** `TrackResolver` tries every enabled addon in the Settings › Addons order, and a stream that fails to play is retried on the next addon. The owner asked for a built-in YouTube Music fallback. We declined, because extracting YouTube streams means getting around YouTube's protections. A YT Music *addon* placed last in the list is the supported fallback.
- **Owner's addons (Nov 2026):** "Tido" (Tidal-backed, Eclipse protocol, declares isrc/resolve, default quality MAX means DASH, so Halo steps down to LOSSLESS FLAC) works. "juanjob hi res" and "Trial" are **BitChord-locked** (`bitchordAuth: true`, a device token signed by BitChord's auth server). Halo detects and refuses them; don't try to impersonate BitChord.
- **Backup:** `Support/Backup.swift` copies the setup into the Keychain and restores it on a fresh install. It only survives if the IPA keeps the same bundle ID and team. Export/Import lives in Settings.
- **Animated covers** use the official Apple Music API with the owner's own MusicKit developer token (`docs/ANIMATED_ARTWORK.md`, `tools/musickit-token.mjs`). Scraping the web player's token was refused as access circumvention; don't go back to it. Hi-res static covers come from the public iTunes Search API.

## Architecture (SwiftUI, **iOS 26+**, Xcode 26 on CI, Swift 5 language mode, @Observable)
- `App/HaloApp.swift`: creates the stores and injects them: `LibraryStore`, `AddonStore`, `PlayerEngine`, `SpotifyService`, `NavigationModel`, `AppSettings.shared`.
- `Models/Track.swift`: `Track` (source `.local` / `.addon` / `.catalog`), `StreamInfo`, `Album`, `Artist`, `RemotePlaylist`, `UserPlaylist`, `Chapter`.
- `Addons/`: the full Eclipse protocol (`AddonModels`), the client (`AddonClient`: notices, 429/503 retry, album/artist/playlist/catalog/resolve), and `AddonStore` (per-addon setting values, per-network values via NWPathMonitor, rename, notices toggle, order).
- `Player/PlayerEngine.swift`: two `Deck`s (AVPlayer each). The standby deck preloads the next song for gapless playback and crossfade. Also handles speed and keep-pitch, the sleep timer, podcast skips, and the lock screen. `AudioEffects.swift` is an MTAudioProcessingTap with a 10-band biquad EQ, preamp, bass shelf and stereo width; it doesn't apply to HLS. `TrackResolver.swift` matches catalog tracks to addons.
- `Artwork/`: `ArtworkService` (iTunes hi-res and Apple Music motion), `Palette` (colour extraction).
- `Lyrics/Lyrics.swift`: LRC parser (enhanced word stamps, or estimated word timing), and `LyricsService` (sidecar .lrc, then LRCLIB).
- `Spotify/SpotifyService.swift`: PKCE login, Keychain tokens, Home import, and details for playlists, albums and artists.
- `Views/`: `Design` (glass helpers, fonts), `Components` (artwork, motion artwork, rows, cards, shelves, `Route`), `RootView` (TabView with search role, mini player in `tabViewBottomAccessory`, toasts), `HomeView`, `SearchView`, `LibraryView`, `CollectionView` (album / playlist / liked / local) and `ArtistView`, `NowPlayingView` (+ `Scrubber`, queue), `LyricsView`, `SettingsView` (+ Sound/EQ, Spotify), `AddonsView` (+ per-addon settings form).
- Persistence: JSON in Application Support/Halo (`Store`), preferences in UserDefaults (`halo.*`), Spotify tokens in the Keychain.

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
