import Foundation
import UIKit

/// Finds better artwork for a track:
///  • hi-res static covers from the public iTunes Search API (up to 3000 px),
///  • animated covers (Apple Music "motion artwork") from the official Apple Music API,
///    when the user has pasted a MusicKit developer token from their own Apple developer account.
actor ArtworkService {
    static let shared = ArtworkService()

    struct Match: Codable, Sendable {
        var collectionID: Int?
        var artworkTemplate: String?
        var motionURL: URL?
        var motionChecked: Bool = false
    }

    private var cache: [String: Match] = [:]
    private var inFlight: [String: Task<Match?, Never>] = [:]
    private let cacheFile = "artwork-matches.json"
    private var loaded = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        return URLSession(configuration: c)
    }()

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        cache = Store.load([String: Match].self, from: cacheFile) ?? [:]
    }

    private static func key(for track: Track) -> String {
        "\(track.artist.lowercased())|\(track.album?.lowercased() ?? track.title.lowercased())"
    }

    /// A hi-res cover URL at the requested pixel size, or nil when nothing matched.
    func hiResURL(for track: Track, size: Int = 1400) async -> URL? {
        guard let found = await self.match(for: track), let template = found.artworkTemplate else { return nil }
        return URL(string: template.replacingOccurrences(of: "{s}", with: "\(size)x\(size)"))
    }

    /// An HLS URL of the album's animated cover, when Apple Music has one and a token is set.
    func motionURL(for track: Track, token: String, storefront: String) async -> URL? {
        guard !token.isEmpty, var found = await self.match(for: track), let collection = found.collectionID else { return nil }
        if found.motionChecked { return found.motionURL }
        let url = await fetchMotion(collectionID: collection, token: token, storefront: storefront)
        found.motionURL = url
        found.motionChecked = url != nil || !lastMotionFailed
        cache[Self.key(for: track)] = found
        Store.save(cache, to: cacheFile)
        return url
    }

    func clearMotionCache() {
        loadIfNeeded()
        for (k, var v) in cache {
            v.motionChecked = false
            v.motionURL = nil
            cache[k] = v
        }
        Store.save(cache, to: cacheFile)
    }

    // MARK: iTunes Search

    private func match(for track: Track) async -> Match? {
        loadIfNeeded()
        let key = Self.key(for: track)
        if let hit = cache[key] { return hit.artworkTemplate == nil && hit.collectionID == nil ? nil : hit }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.search(track) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result ?? Match()
        Store.save(cache, to: cacheFile)
        return result
    }

    private func search(_ track: Track) async -> Match? {
        let term = [track.artist, track.album ?? track.title].joined(separator: " ")
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: track.album == nil ? "song" : "album"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return nil }

        let wantArtist = Self.normalize(track.artist)
        let wantAlbum = Self.normalize(track.album ?? "")
        let wantTitle = Self.normalize(track.title)
        var best: (score: Int, row: [String: Any])?
        for row in results {
            let artist = Self.normalize(row["artistName"] as? String ?? "")
            let album = Self.normalize(row["collectionName"] as? String ?? "")
            let title = Self.normalize(row["trackName"] as? String ?? "")
            var score = 0
            if !wantArtist.isEmpty, artist.contains(wantArtist) || wantArtist.contains(artist) { score += 3 }
            if !wantAlbum.isEmpty, album == wantAlbum { score += 3 } else if !wantAlbum.isEmpty, album.hasPrefix(wantAlbum) || wantAlbum.hasPrefix(album) { score += 2 }
            if !wantTitle.isEmpty, title == wantTitle { score += 2 }
            if score >= 3, score > (best?.score ?? 0) { best = (score, row) }
        }
        guard let row = best?.row, let art = row["artworkUrl100"] as? String else { return nil }
        let template = art.replacingOccurrences(of: "100x100bb", with: "{s}bb")
        return Match(collectionID: row["collectionId"] as? Int, artworkTemplate: template)
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        // Drop "(feat. …)", "[Deluxe]", "- Single" and the like.
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                t.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        for suffix in [" - single", " - ep"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    // MARK: Apple Music API (official, developer token)

    private var lastMotionFailed = false

    private func fetchMotion(collectionID: Int, token: String, storefront: String) async -> URL? {
        let sf = storefront.isEmpty ? "us" : storefront
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(sf)/albums/\(collectionID)?extend=editorialVideo") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        lastMotionFailed = false
        guard let (data, response) = try? await session.data(for: request) else {
            lastMotionFailed = true
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            lastMotionFailed = true
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["data"] as? [[String: Any]])?.first,
              let attributes = first["attributes"] as? [String: Any],
              let video = attributes["editorialVideo"] as? [String: Any] else { return nil }
        for key in ["motionDetailSquare", "motionSquareVideo1x1", "motionDetailTall", "motionTallVideo3x4"] {
            if let entry = video[key] as? [String: Any], let s = entry["video"] as? String, let u = URL(string: s) {
                return u
            }
        }
        return nil
    }
}
