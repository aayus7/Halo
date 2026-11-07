import Foundation

// Wire shapes of the addon protocol (the same one Eclipse and BitChord speak).
// An addon is just an HTTP server answering /manifest.json, /search?q= and /stream/{id}
// with JSON. Unknown keys are ignored, and every field the app doesn't need is optional.

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
        case .double(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        case .bool(let v): return v ? "true" : "false"
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

struct AddonSettingOption: Codable, Hashable, Sendable {
    var value: JSONScalar?
    var label: JSONScalar?
}

struct AddonSetting: Codable, Hashable, Sendable {
    var key: String
    var `default`: JSONScalar?
    var options: [AddonSettingOption]?

    enum CodingKeys: String, CodingKey { case key, `default`, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        self.default = try? c.decodeIfPresent(JSONScalar.self, forKey: .default)
        options = try? c.decodeIfPresent([AddonSettingOption].self, forKey: .options)
    }
}

/// GET {base}/manifest.json
struct AddonManifest: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var icon: URL?
    /// Capabilities this addon offers, e.g. ["search", "stream"]. Empty = didn't say.
    var resources: [String]
    var settings: [AddonSetting]
    var allowDownloads: JSONScalar?

    func supports(_ resource: String) -> Bool {
        resources.isEmpty || resources.contains { $0.caseInsensitiveCompare(resource) == .orderedSame }
    }

    var downloadsAllowed: Bool { allowDownloads?.flag ?? true }

    /// The defaults every request should carry as query parameters.
    var defaultParameters: [String: String] {
        var params: [String: String] = [:]
        for s in settings where !s.key.isEmpty {
            if let v = s.default?.queryValue { params[s.key] = v }
        }
        return params
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, icon, logo, resources, settings, allowDownloads
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        let rawName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        id = rawID
        name = rawName.isEmpty ? rawID : rawName
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        let iconURL = try? c.decodeIfPresent(URL.self, forKey: .icon)
        let logoURL = try? c.decodeIfPresent(URL.self, forKey: .logo)
        icon = iconURL ?? logoURL
        resources = (try? c.decodeIfPresent([String].self, forKey: .resources)) ?? []
        settings = (try? c.decodeIfPresent([AddonSetting].self, forKey: .settings)) ?? []
        allowDownloads = try? c.decodeIfPresent(JSONScalar.self, forKey: .allowDownloads)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encode(resources, forKey: .resources)
        try c.encode(settings, forKey: .settings)
        try c.encodeIfPresent(allowDownloads, forKey: .allowDownloads)
    }
}

struct InstalledAddon: Codable, Identifiable, Hashable, Sendable {
    var manifest: AddonManifest
    /// Base URL every endpoint hangs off: the pasted URL minus its "*.json" filename.
    /// Private tokens often live in this path, so treat it as a secret.
    var baseURL: URL
    var enabled: Bool = true
    var installedAt: Date = Date()

    var id: String { manifest.id }

    /// Host only, for display. The path may contain a token.
    var displayHost: String { baseURL.host ?? "addon" }
}

/// GET {base}/search?q=...  (only `tracks` is read; albums/artists arrays are ignored)
struct SearchResponse: Decodable {
    var tracks: [AddonTrack]

    enum CodingKeys: String, CodingKey { case tracks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode row by row so one malformed track doesn't sink the whole result.
        let rows = (try? c.decodeIfPresent([FailableDecodable<AddonTrack>].self, forKey: .tracks)) ?? []
        tracks = rows.compactMap(\.value)
    }
}

struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct AddonTrack: Decodable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double?
    var artworkURL: URL?
    var streamURL: URL?
    var format: String?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, artworkURL, albumArtworkURL, artwork, streamURL, format
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Empty id")
        }
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        artist = (try? c.decodeIfPresent(String.self, forKey: .artist)) ?? ""
        album = (try? c.decodeIfPresent(String.self, forKey: .album)) ?? ""
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        let art1 = Self.url(c, .artworkURL)
        let art2 = Self.url(c, .albumArtworkURL)
        let art3 = Self.url(c, .artwork)
        artworkURL = art1 ?? art2 ?? art3
        streamURL = Self.url(c, .streamURL)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
    }

    private static func url(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> URL? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: key),
              !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(string: s)
    }

    func toTrack(addonID: String) -> Track {
        Track(
            id: Track.addonID(addon: addonID, track: id),
            title: title.isEmpty ? "Untitled" : title,
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            album: album.isEmpty ? nil : album,
            duration: (duration ?? 0) > 0 ? duration : nil,
            artworkURL: artworkURL,
            directStreamURL: streamURL,
            source: .addon(addonID: addonID, trackID: id)
        )
    }
}

/// GET {base}/stream/{trackID}
struct StreamResponse: Decodable {
    var url: URL?
    var headers: [String: String]?
    var format: String?
    var quality: String?
    /// `none`, `hls` or `dash`: what the URL points at.
    var manifest: String?
    var mediaType: String?
    var encrypted: JSONScalar?
    /// Some addons answer 200 with {"error": "..."} instead of a status code.
    var error: String?

    enum CodingKeys: String, CodingKey {
        case url, headers, format, quality, manifest, mediaType, encrypted, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decodeIfPresent(String.self, forKey: .url), !s.isEmpty {
            url = URL(string: s)
        } else {
            url = nil
        }
        headers = try? c.decodeIfPresent([String: String].self, forKey: .headers)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
        quality = try? c.decodeIfPresent(String.self, forKey: .quality)
        manifest = try? c.decodeIfPresent(String.self, forKey: .manifest)
        mediaType = try? c.decodeIfPresent(String.self, forKey: .mediaType)
        encrypted = try? c.decodeIfPresent(JSONScalar.self, forKey: .encrypted)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    var isEncrypted: Bool {
        guard let encrypted else { return false }
        if case .string(let s) = encrypted {
            let v = s.lowercased()
            return !(v.isEmpty || v == "false" || v == "none")
        }
        return encrypted.flag ?? false
    }

    /// "hls", "dash" or nil (a plain file).
    var transport: String? {
        let stated = [manifest, mediaType, format]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }?
            .lowercased()
        switch stated {
        case "hls", "m3u8", "application/x-mpegurl", "application/vnd.apple.mpegurl": return "hls"
        case "dash", "mpd", "application/dash+xml": return "dash"
        default: return nil
        }
    }
}
