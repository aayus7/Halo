import Foundation

/// Extra artist art from TheAudioDB (community database, free public key):
/// the artist's own logo (transparent PNG), wide fanart, cutout and biography.
actor ArtistInfoService {
    static let shared = ArtistInfoService()

    struct Info: Codable, Sendable {
        var logo: URL?
        var fanart: URL?
        var wide: URL?
        var bio: String?
    }

    private var cache: [String: Info] = [:]
    private var loaded = false
    private let file = "artist-info.json"

    func info(for name: String) async -> Info? {
        if !loaded {
            loaded = true
            cache = Store.load([String: Info].self, from: file) ?? [:]
        }
        let key = name.lowercased()
        if let hit = cache[key] { return hit.logo == nil && hit.fanart == nil && hit.bio == nil ? nil : hit }
        var comps = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/123/search.php")!
        comps.queryItems = [URLQueryItem(name: "s", value: name)]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let row = (obj["artists"] as? [[String: Any]])?.first { ($0["strArtist"] as? String)?.lowercased() == key }
            ?? (obj["artists"] as? [[String: Any]])?.first
        func link(_ k: String) -> URL? { (row?[k] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        let bio = (row?["strBiographyEN"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let info = Info(logo: link("strArtistLogo"), fanart: link("strArtistFanart"), wide: link("strArtistWideThumb"), bio: bio)
        cache[key] = info
        Store.save(cache, to: file)
        return info
    }
}
