import Foundation

/// A playable song, regardless of where it comes from.
struct Track: Identifiable, Codable, Hashable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        /// A file stored in the app's Documents/Music folder.
        case local(fileName: String)
        /// A track provided by an installed addon. The stream URL is resolved lazily.
        case addon(addonID: String, trackID: String)
        /// Metadata from a catalog (e.g. Spotify import). Played by matching it to an addon.
        case catalog(service: String, id: String)
    }

    let id: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var artworkURL: URL?
    /// Optional stream URL the addon gave us up-front (skips the /stream call).
    var directStreamURL: URL?
    var source: Source
    var isrc: String?
    /// Addon-side ids for drilling into the album / artist page.
    var albumID: String?
    var artistID: String?
    var explicit: Bool?

    init(id: String, title: String, artist: String, album: String? = nil, duration: Double? = nil,
         artworkURL: URL? = nil, directStreamURL: URL? = nil, source: Source,
         isrc: String? = nil, albumID: String? = nil, artistID: String? = nil, explicit: Bool? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.directStreamURL = directStreamURL
        self.source = source
        self.isrc = isrc
        self.albumID = albumID
        self.artistID = artistID
        self.explicit = explicit
    }

    var isLocal: Bool {
        if case .local = source { return true }
        return false
    }

    var addonID: String? {
        if case .addon(let id, _) = source { return id }
        return nil
    }

    var subtitle: String {
        [artist, album ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func localID(for fileName: String) -> String { "local:\(fileName)" }
    static func addonID(addon: String, track: String) -> String { "addon:\(addon):\(track)" }
}

/// A resolved, ready-to-play stream.
struct StreamInfo: Codable, Hashable, Sendable {
    var url: URL
    var headers: [String: String]?
    var codec: String?
    var container: String?
    var quality: String?
    var sampleRate: Double?
    var bitDepth: Int?
    var expiresAt: Date?
    var chapters: [Chapter]?

    init(url: URL, headers: [String: String]? = nil, codec: String? = nil, container: String? = nil,
         quality: String? = nil, sampleRate: Double? = nil, bitDepth: Int? = nil,
         expiresAt: Date? = nil, chapters: [Chapter]? = nil) {
        self.url = url
        self.headers = headers
        self.codec = codec
        self.container = container
        self.quality = quality
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.expiresAt = expiresAt
        self.chapters = chapters
    }

    /// One line for "stats for nerds".
    var summary: String {
        var parts: [String] = []
        if let codec { parts.append(codec.uppercased()) }
        if let bitDepth { parts.append("\(bitDepth)-bit") }
        if let sampleRate { parts.append(String(format: "%g kHz", sampleRate / 1000)) }
        if let quality, !quality.isEmpty { parts.append(quality) }
        return parts.joined(separator: " · ")
    }
}

struct Chapter: Codable, Hashable, Sendable {
    var title: String
    var startTime: Double

    enum CodingKeys: String, CodingKey { case title, startTime }

    init(title: String, startTime: Double) {
        self.title = title
        self.startTime = startTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = Lenient.string(c, .title) ?? "Chapter"
        startTime = Lenient.double(c, .startTime) ?? 0
    }
}

/// An album as an addon describes it.
struct Album: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(addonID):\(albumID)" }
    var addonID: String
    var albumID: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var year: String?
    var trackCount: Int?
    var description: String?
}

struct Artist: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(addonID):\(artistID)" }
    var addonID: String
    var artistID: String
    var name: String
    var artworkURL: URL?
    var genres: [String] = []
    var bio: String?
}

struct RemotePlaylist: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(addonID):\(playlistID)" }
    var addonID: String
    var playlistID: String
    var title: String
    var creator: String?
    var artworkURL: URL?
    var trackCount: Int?
    var description: String?
}

/// A playlist the user made in Halo.
struct UserPlaylist: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var tracks: [Track] = []
    var createdAt: Date = Date()
}

enum RepeatMode: String, Codable, Sendable {
    case off, all, one
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds)
    if t >= 3600 {
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
    return String(format: "%d:%02d", t / 60, t % 60)
}
