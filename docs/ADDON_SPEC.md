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
