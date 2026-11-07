import Foundation

/// A playable song, regardless of where it comes from.
struct Track: Identifiable, Codable, Hashable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        /// A file stored in the app's Documents/Music folder.
        case local(fileName: String)
        /// A track provided by an installed addon. The stream URL is resolved lazily.
        case addon(addonID: String, trackID: String)
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

    var isLocal: Bool {
        if case .local = source { return true }
        return false
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
