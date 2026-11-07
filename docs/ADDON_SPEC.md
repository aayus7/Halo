# Halo addon protocol

Halo uses the same HTTP addon protocol as Eclipse and BitChord. Any addon built for those apps installs in Halo by pasting its URL.

An addon is just a web server. Halo never downloads or runs addon code. It only makes three kinds of GET requests and reads JSON back.

## Install URL

Users paste either form:

```
https://addon.example.com/SOME_TOKEN/manifest.json
https://addon.example.com/SOME_TOKEN
```

Halo strips a trailing `*.json` filename and uses the rest as the **base URL**. Everything in the path and query is kept, because private tokens often live there. Treat a base URL like a password.

## 1. `GET {base}/manifest.json`

```json
{
  "id": "com.example.myaddon",
  "name": "My Addon",
  "version": "1.0.0",
  "description": "Streams from somewhere",
  "icon": "https://addon.example.com/icon.png",
  "resources": ["search", "stream"],
  "settings": [
    { "key": "quality", "default": "lossless",
      "options": [{ "value": "high", "label": "High" }, { "value": "lossless", "label": "Lossless" }] }
  ]
}
```

- `id` is required. `name` falls back to `id`.
- `resources`: `search` is required. If the list is empty, Halo assumes the addon supports everything.
- `settings`: every setting's `default` is sent as a query parameter on each search and stream request, e.g. `?quality=lossless`.

## 2. `GET {base}/search?q=QUERY`

```json
{
  "tracks": [
    {
      "id": "abc123",
      "title": "Song",
      "artist": "Artist",
      "album": "Album",
      "duration": 215,
      "artworkURL": "https://…/cover.jpg",
      "streamURL": "https://…/audio.mp3"
    }
  ]
}
```

- Only `id` is required. Other arrays (`albums`, `artists`) are ignored for now.
- `artworkURL` can also be sent as `albumArtworkURL`.
- If `streamURL` is present, Halo skips the `/stream` call.

## 3. `GET {base}/stream/{id}`

```json
{ "url": "https://…/audio.flac", "format": "flac", "quality": "Lossless", "headers": { "Referer": "…" } }
```

- `headers` (optional) are sent with the audio request.
- `manifest`: `"hls"` works. `"dash"` is refused, because iOS's AVPlayer can't play DASH.
- `encrypted`: anything other than `false` is refused (no DRM).
- `{"error": "..."}` with no `url` is shown to the user.
- `404` means "this addon doesn't have that track".
- `429` is retried, honouring `Retry-After`.

## Playable formats on iPhone

MP3, AAC/M4A, ALAC, FLAC, WAV/AIFF, and HLS (`.m3u8`). Not playable: Opus/WebM, DASH.

## Optional endpoints (Eclipse-compatible)

Halo implements the rest of the Eclipse addon guide too:

| Endpoint | When it's used |
|---|---|
| `GET /album/{id}` → `{id,title,artist,artworkURL,year,description,tracks:[…]}` | Album pages (search results with `albums`) |
| `GET /artist/{id}` → `{id,name,artworkURL,bio,genres,topTracks:[…],albums:[…]}` | Artist pages |
| `GET /playlist/{id}` → `{id,title,creator,artworkURL,description,tracks:[…]}` | Playlist pages |
| `GET /catalog/{id}?skip=N` → `{items:[{type,…}]}` | Home rows, declared in `manifest.catalogs` with `"catalog"` in `resources` |
| `GET /resolve-isrc?isrc=` → `{trackId}` | Playing imported songs (Spotify Home) by exact recording; needs `"isrc"` in `resources` |
| `GET /resolve?isrc=&title=&artist=&durationMs=` → `{item:{…}\|null}` | Same, by identity; needs `"resolve"` in `resources` |

Search may return `tracks`, `albums`, `artists` and `playlists`. Tracks may carry `isrc`, `albumId`,
`artistId`, `explicit`, and `durationMs` instead of `duration`.

### Settings

`manifest.settings[]` items with `type` `select` / `toggle` / `text` / `number`, `label`, `help`,
`default`, `options`, `perNetwork`, `min`/`max`/`step`, `maxLength`, `placeholder` get a settings
screen. Values are sent as query parameters on every request; `perNetwork` settings send the Wi-Fi or
cellular value depending on the connection.

### Stream extras

`/stream` may also return `codec`, `container`, `sampleRate`, `bitDepth` (shown under "Stream" in the
player's ⋯ menu), `expiresAt` (Unix seconds; Halo re-resolves before it), and `chapters`
(`[{title,startTime}]`). `manifest.contentType` `"podcast"` / `"audiobook"` swaps previous/next for
15 s / 30 s skips.

Answer `/stream` with **503 + `Retry-After`** while a song is being prepared; Halo waits (≤30 s per
try, 4 tries).

### Notices

With `"notifications"` in `resources`, any JSON reply may include
`{"notice":{"message","title","level":"info|success|warning|error","id","progress","duration"}}`.
Halo shows it as a toast with the addon's icon. Users can turn notices off per addon.

### Install links

`halo://install?url=<urlencoded manifest URL>` installs an addon from a link.
