import Foundation

// Wire shapes of the addon protocol (the one Eclipse and BitChord speak).
// An addon is an HTTP server answering /manifest.json, /search?q= and /stream/{id} with JSON,
// plus optional /album, /artist, /playlist, /catalog, /resolve and /resolve-isrc.
// Unknown keys are ignored, and every field the app doesn't need is optional.
// See docs/ADDON_SPEC.md.

/// A JSON scalar (string / number / bool) as it would go into a query parameter.
enum JSONScalar: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a scalar")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }

    var queryValue: String? {
        switch self {
        case .string(let v): return v.isEmpty ? nil : v
        case .int(let v): return String(v)
        case .double(let v): return v.rounded() == v && abs(v) < 1e15 ? String(Int(v)) : String(v)
        case .bool(let v): return v ? "true" : "false"
        }
    }

    var displayText: String {
        switch self {
        case .string(let v): return v
        default: return queryValue ?? ""
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .string(let v): return Double(v)
        case .bool(let v): return v ? 1 : 0
        }
    }

    /// Manifest switches may be written 1/0, true/false, or either as a string.
    var flag: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .double(let v): return v != 0
        case .string(let v):
            switch v.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off", "none", "": return false
            default: return nil
            }
        }
    }
}

// MARK: - Manifest

struct AddonSettingOption: Codable, Hashable, Sendable {
    var value: JSONScalar?
    var label: JSONScalar?
}

struct AddonSetting: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case select, toggle, text, number }

    var key: String
    var type: Kind
    var label: String
    var help: String?
    var `default`: JSONScalar?
    var options: [AddonSettingOption]
    var perNetwork: Bool
    var min: Double?
    var max: Double?
    var step: Double?
    var maxLength: Int?
    var placeholder: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, type, label, help, `default`, options, perNetwork, min, max, step, maxLength, placeholder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        let rawType = (try? c.decodeIfPresent(String.self, forKey: .type))?.lowercased()
        options = (try? c.decodeIfPresent([AddonSettingOption].self, forKey: .options)) ?? []
        if let rawType, let kind = Kind(rawValue: rawType) {
            type = kind
        } else {
            type = options.isEmpty ? .text : .select
        }
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? key
        help = try? c.decodeIfPresent(String.self, forKey: .help)
        self.default = try? c.decodeIfPresent(JSONScalar.self, forKey: .default)
        perNetwork = (try? c.decodeIfPresent(JSONScalar.self, forKey: .perNetwork))?.flag ?? false
        min = (try? c.decodeIfPresent(JSONScalar.self, forKey: .min))?.doubleValue
        max = (try? c.decodeIfPresent(JSONScalar.self, forKey: .max))?.doubleValue
        step = (try? c.decodeIfPresent(JSONScalar.self, forKey: .step))?.doubleValue
        maxLength = try? c.decodeIfPresent(Int.self, forKey: .maxLength)
        placeholder = try? c.decodeIfPresent(String.self, forKey: .placeholder)
    }
}

struct AddonCatalog: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var type: String
    var name: String
}

/// GET {base}/manifest.json
struct AddonManifest: Codable, Hashable, Sendable {
    enum ContentType: String, Codable, Sendable { case music, audiobook, podcast }

    var id: String
    var name: String
    var version: String
    var description: String?
    var icon: URL?
    /// Capabilities this addon offers, e.g. ["search", "stream"]. Empty = didn't say.
    var resources: [String]
    var types: [String]
    var contentType: ContentType
    var settings: [AddonSetting]
    var catalogs: [AddonCatalog]
    var allowDownloads: JSONScalar?
    /// Set when the addon only answers one specific app (e.g. `bitchordAuth: true` needs BitChord's signed device token).
    var lockedToApp: String?

    func supports(_ resource: String) -> Bool {
        resources.contains { $0.caseInsensitiveCompare(resource) == .orderedSame }
            || (resources.isEmpty && (resource == "search" || resource == "stream"))
    }

    var downloadsAllowed: Bool { allowDownloads?.flag ?? true }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, icon, logo, resources, types, contentType, settings, catalogs, allowDownloads
        case bitchordAuth, lockedToApp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        let rawName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        id = rawID
        name = rawName.isEmpty ? rawID : rawName
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        let iconURL = Self.url(c, .icon)
        let logoURL = Self.url(c, .logo)
        icon = iconURL ?? logoURL
        resources = (try? c.decodeIfPresent([String].self, forKey: .resources)) ?? []
        types = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? []
        let rawContent = (try? c.decodeIfPresent(String.self, forKey: .contentType))?.lowercased() ?? "music"
        contentType = ContentType(rawValue: rawContent) ?? .music
        let rawSettings = (try? c.decodeIfPresent([FailableDecodable<AddonSetting>].self, forKey: .settings)) ?? []
        settings = rawSettings.compactMap(\.value).filter { !$0.key.isEmpty }
        let rawCatalogs = (try? c.decodeIfPresent([FailableDecodable<AddonCatalog>].self, forKey: .catalogs)) ?? []
        catalogs = rawCatalogs.compactMap(\.value)
        allowDownloads = try? c.decodeIfPresent(JSONScalar.self, forKey: .allowDownloads)
        if let locked = try? c.decodeIfPresent(String.self, forKey: .lockedToApp) {
            lockedToApp = locked
        } else if (try? c.decodeIfPresent(JSONScalar.self, forKey: .bitchordAuth))?.flag == true {
            lockedToApp = "BitChord"
        }
    }

    private static func url(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> URL? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(icon?.absoluteString, forKey: .icon)
        try c.encode(resources, forKey: .resources)
        try c.encode(types, forKey: .types)
        try c.encode(contentType.rawValue, forKey: .contentType)
        try c.encode(settings, forKey: .settings)
        try c.encode(catalogs, forKey: .catalogs)
        try c.encodeIfPresent(allowDownloads, forKey: .allowDownloads)
        try c.encodeIfPresent(lockedToApp, forKey: .lockedToApp)
    }
}

struct InstalledAddon: Codable, Identifiable, Hashable, Sendable {
    var manifest: AddonManifest
    /// Base URL every endpoint hangs off: the pasted URL minus its "*.json" filename.
    /// Private tokens often live in this path, so treat it as a secret.
    var baseURL: URL
    var enabled: Bool = true
    var installedAt: Date = Date()
    /// Cosmetic rename; never sent to the addon.
    var customName: String?
    var showNotices: Bool = true

    var id: String { manifest.id }
    var displayName: String {
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty { return customName }
        return manifest.name
    }

    /// Host only, for display. The path may contain a token.
    var displayHost: String { baseURL.host ?? "addon" }

    enum CodingKeys: String, CodingKey { case manifest, baseURL, enabled, installedAt, customName, showNotices }

    init(manifest: AddonManifest, baseURL: URL) {
        self.manifest = manifest
        self.baseURL = baseURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try c.decode(AddonManifest.self, forKey: .manifest)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        installedAt = (try? c.decodeIfPresent(Date.self, forKey: .installedAt)) ?? Date()
        customName = try? c.decodeIfPresent(String.self, forKey: .customName)
        showNotices = (try? c.decodeIfPresent(Bool.self, forKey: .showNotices)) ?? true
    }
}

// MARK: - Shared item shapes

struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Lenient field readers shared by every wire type.
struct Lenient {
    static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ keys: K...) -> String? {
        for key in keys {
            if let s = try? c.decodeIfPresent(String.self, forKey: key) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            } else if let i = try? c.decodeIfPresent(Int.self, forKey: key) {
                return String(i)
            }
        }
        return nil
    }

    static func url<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ keys: K...) -> URL? {
        for key in keys {
            if let s = try? c.decodeIfPresent(String.self, forKey: key),
               !s.trimmingCharacters(in: .whitespaces).isEmpty, let u = URL(string: s) {
                return u
            }
        }
        return nil
    }

    static func double<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        (try? c.decodeIfPresent(JSONScalar.self, forKey: key))?.doubleValue
    }

    static func bool<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
        (try? c.decodeIfPresent(JSONScalar.self, forKey: key))?.flag
    }

    static func list<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [T] {
        let rows = (try? c.decodeIfPresent([FailableDecodable<T>].self, forKey: key)) ?? []
        return rows.compactMap(\.value)
    }
}

struct AddonTrack: Decodable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var artworkURL: URL?
    var streamURL: URL?
    var isrc: String?
    var albumID: String?
    var artistID: String?
    var explicit: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, name, artist, album, duration, durationMs, artworkURL, albumArtworkURL, artwork,
             streamURL, isrc, albumId, albumID, artistId, artistID, explicit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = Lenient.string(c, .id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing id")
        }
        self.id = id
        title = Lenient.string(c, .title, .name) ?? ""
        artist = Lenient.string(c, .artist) ?? ""
        album = Lenient.string(c, .album)
        if let d = Lenient.double(c, .duration), d > 0 {
            duration = d
        } else if let ms = Lenient.double(c, .durationMs), ms > 0 {
            duration = ms / 1000
        }
        artworkURL = Lenient.url(c, .artworkURL, .albumArtworkURL, .artwork)
        streamURL = Lenient.url(c, .streamURL)
        isrc = Lenient.string(c, .isrc)
        albumID = Lenient.string(c, .albumId, .albumID)
        artistID = Lenient.string(c, .artistId, .artistID)
        explicit = Lenient.bool(c, .explicit)
    }

    func toTrack(addonID: String) -> Track {
        Track(
            id: Track.addonID(addon: addonID, track: id),
            title: title.isEmpty ? "Untitled" : title,
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            album: album,
            duration: duration,
            artworkURL: artworkURL,
            directStreamURL: streamURL,
            source: .addon(addonID: addonID, trackID: id),
            isrc: isrc,
            albumID: albumID,
            artistID: artistID,
            explicit: explicit
        )
    }
}

struct AddonAlbum: Decodable {
    var id: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var year: String?
    var trackCount: Int?
    var description: String?
    var tracks: [AddonTrack]

    enum CodingKeys: String, CodingKey { case id, title, name, artist, artworkURL, artwork, year, trackCount, description, tracks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = Lenient.string(c, .id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing id")
        }
        self.id = id
        title = Lenient.string(c, .title, .name) ?? "Untitled"
        artist = Lenient.string(c, .artist) ?? ""
        artworkURL = Lenient.url(c, .artworkURL, .artwork)
        year = Lenient.string(c, .year)
        trackCount = Lenient.double(c, .trackCount).map { Int($0) }
        description = Lenient.string(c, .description)
        tracks = Lenient.list(c, .tracks)
    }

    func toAlbum(addonID: String) -> Album {
        Album(addonID: addonID, albumID: id, title: title, artist: artist, artworkURL: artworkURL,
              year: year, trackCount: trackCount ?? (tracks.isEmpty ? nil : tracks.count), description: description)
    }

    /// Album tracks often omit the album's own name and art; fill them in.
    func tracksFilled(addonID: String) -> [Track] {
        tracks.map { t in
            var track = t.toTrack(addonID: addonID)
            if track.album == nil { track.album = title }
            if track.artworkURL == nil { track.artworkURL = artworkURL }
            if track.albumID == nil { track.albumID = id }
            if track.artist == "Unknown Artist", !artist.isEmpty { track.artist = artist }
            return track
        }
    }
}

struct AddonArtist: Decodable {
    var id: String
    var name: String
    var artworkURL: URL?
    var genres: [String]
    var bio: String?
    var topTracks: [AddonTrack]
    var albums: [AddonAlbum]

    enum CodingKeys: String, CodingKey { case id, name, title, artworkURL, artwork, genres, bio, topTracks, tracks, albums }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = Lenient.string(c, .id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing id")
        }
        self.id = id
        name = Lenient.string(c, .name, .title) ?? "Unknown Artist"
        artworkURL = Lenient.url(c, .artworkURL, .artwork)
        genres = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? []
        bio = Lenient.string(c, .bio)
        let top: [AddonTrack] = Lenient.list(c, .topTracks)
        topTracks = top.isEmpty ? Lenient.list(c, .tracks) : top
        albums = Lenient.list(c, .albums)
    }

    func toArtist(addonID: String) -> Artist {
        Artist(addonID: addonID, artistID: id, name: name, artworkURL: artworkURL, genres: genres, bio: bio)
    }
}

struct AddonPlaylist: Decodable {
    var id: String
    var title: String
    var creator: String?
    var artworkURL: URL?
    var trackCount: Int?
    var description: String?
    var tracks: [AddonTrack]

    enum CodingKeys: String, CodingKey { case id, title, name, creator, artworkURL, artwork, trackCount, description, tracks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = Lenient.string(c, .id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing id")
        }
        self.id = id
        title = Lenient.string(c, .title, .name) ?? "Playlist"
        creator = Lenient.string(c, .creator)
        artworkURL = Lenient.url(c, .artworkURL, .artwork)
        trackCount = Lenient.double(c, .trackCount).map { Int($0) }
        description = Lenient.string(c, .description)
        tracks = Lenient.list(c, .tracks)
    }

    func toPlaylist(addonID: String) -> RemotePlaylist {
        RemotePlaylist(addonID: addonID, playlistID: id, title: title, creator: creator, artworkURL: artworkURL,
                       trackCount: trackCount ?? (tracks.isEmpty ? nil : tracks.count), description: description)
    }
}

// MARK: - Responses

/// GET {base}/search?q=...
struct SearchResponse: Decodable {
    var tracks: [AddonTrack]
    var albums: [AddonAlbum]
    var artists: [AddonArtist]
    var playlists: [AddonPlaylist]

    enum CodingKeys: String, CodingKey { case tracks, albums, artists, playlists }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode row by row so one malformed item doesn't sink the whole result.
        tracks = Lenient.list(c, .tracks)
        albums = Lenient.list(c, .albums)
        artists = Lenient.list(c, .artists)
        playlists = Lenient.list(c, .playlists)
    }
}

/// What one addon returned for a query, converted to app models.
struct AddonSearchResult: Sendable {
    var tracks: [Track] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [RemotePlaylist] = []

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

/// GET {base}/catalog/{id}?skip=N
struct CatalogResponse: Decodable {
    struct Item: Decodable {
        var type: String
        var track: AddonTrack?
        var album: AddonAlbum?
        var artist: AddonArtist?
        var playlist: AddonPlaylist?

        enum CodingKeys: String, CodingKey { case type }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = ((try? c.decodeIfPresent(String.self, forKey: .type)) ?? "track").lowercased()
            switch type {
            case "album": album = try AddonAlbum(from: decoder)
            case "artist": artist = try AddonArtist(from: decoder)
            case "playlist": playlist = try AddonPlaylist(from: decoder)
            default: track = try AddonTrack(from: decoder)
            }
        }
    }

    var items: [Item]

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = Lenient.list(c, .items)
    }
}

/// One row on Home, filled from an addon's catalog.
struct CatalogRow: Identifiable, Sendable {
    var id: String { "\(addonID):\(catalog.id)" }
    var addonID: String
    var addonName: String
    var catalog: AddonCatalog
    var tracks: [Track] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [RemotePlaylist] = []

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

/// A message an addon wants shown as a toast.
struct AddonNotice: Decodable, Sendable, Equatable {
    enum Level: String, Decodable, Sendable { case info, success, warning, error }

    var id: String?
    var title: String?
    var message: String
    var level: Level
    var progress: Double?
    var duration: Double?

    enum CodingKeys: String, CodingKey { case id, title, message, level, progress, duration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let message = Lenient.string(c, .message) else {
            throw DecodingError.dataCorruptedError(forKey: .message, in: c, debugDescription: "No message")
        }
        self.message = String(message.replacingOccurrences(of: "\n", with: " ").prefix(120))
        title = Lenient.string(c, .title).map { String($0.prefix(40)) }
        id = Lenient.string(c, .id)
        level = Level(rawValue: (Lenient.string(c, .level) ?? "info").lowercased()) ?? .info
        progress = Lenient.double(c, .progress).map { min(max($0, 0), 1) }
        duration = Lenient.double(c, .duration).map { min(max($0, 2), 10) }
    }
}

struct NoticeEnvelope: Decodable {
    var notice: AddonNotice?
}

/// GET {base}/stream/{trackID}
struct StreamResponse: Decodable {
    var url: URL?
    var headers: [String: String]?
    var format: String?
    var quality: String?
    var codec: String?
    var container: String?
    /// `none`, `hls` or `dash`: what the URL points at.
    var manifest: String?
    var mediaType: String?
    var encrypted: JSONScalar?
    var sampleRate: Double?
    var bitDepth: Int?
    var expiresAt: Date?
    var chapters: [Chapter]
    /// Some addons answer 200 with {"error": "..."} instead of a status code.
    var error: String?

    enum CodingKeys: String, CodingKey {
        case url, headers, format, quality, codec, container, manifest, mediaType, encrypted,
             sampleRate, bitDepth, expiresAt, chapters, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = Lenient.url(c, .url)
        headers = try? c.decodeIfPresent([String: String].self, forKey: .headers)
        format = Lenient.string(c, .format)
        quality = Lenient.string(c, .quality)
        codec = Lenient.string(c, .codec)
        container = Lenient.string(c, .container)
        manifest = Lenient.string(c, .manifest)
        mediaType = Lenient.string(c, .mediaType)
        encrypted = try? c.decodeIfPresent(JSONScalar.self, forKey: .encrypted)
        sampleRate = Lenient.double(c, .sampleRate)
        bitDepth = Lenient.double(c, .bitDepth).map { Int($0) }
        if let ts = Lenient.double(c, .expiresAt), ts > 0 {
            expiresAt = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
        }
        chapters = Lenient.list(c, .chapters)
        error = Lenient.string(c, .error)
    }

    var isEncrypted: Bool {
        guard let encrypted else { return false }
        if case .string(let s) = encrypted {
            let v = s.lowercased()
            return !(v.isEmpty || v == "false" || v == "none" || v == "0")
        }
        return encrypted.flag ?? false
    }

    /// "hls", "dash" or nil (a plain file).
    var transport: String? {
        let stated = [manifest, mediaType]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }?
            .lowercased()
        switch stated {
        case "hls", "m3u8", "application/x-mpegurl", "application/vnd.apple.mpegurl": return "hls"
        case "dash", "mpd", "application/dash+xml": return "dash"
        default: break
        }
        if let path = url?.pathExtension.lowercased() {
            if path == "m3u8" { return "hls" }
            if path == "mpd" { return "dash" }
        }
        return nil
    }

    func toStreamInfo(_ url: URL) -> StreamInfo {
        StreamInfo(url: url, headers: headers, codec: codec ?? format, container: container,
                   quality: quality, sampleRate: sampleRate, bitDepth: bitDepth,
                   expiresAt: expiresAt, chapters: chapters.isEmpty ? nil : chapters)
    }
}

/// GET {base}/resolve-isrc?isrc=  →  {"trackId": "..."}  or  {"id": "..."}
struct ISRCResponse: Decodable {
    var trackID: String?
    enum CodingKeys: String, CodingKey { case trackId, id }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackID = Lenient.string(c, .trackId, .id)
    }
}

/// GET {base}/resolve?isrc=&title=&artist=&durationMs=  →  {"item": {...}|null}
struct ResolveResponse: Decodable {
    var item: AddonTrack?
    enum CodingKeys: String, CodingKey { case item }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try? c.decodeIfPresent(AddonTrack.self, forKey: .item)
    }
}
