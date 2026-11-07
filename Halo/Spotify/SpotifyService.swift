import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit

/// Imports the user's own Spotify library (official Web API, PKCE login, the user's own Client ID)
/// so Home can be built from it. Spotify only supplies metadata here; playback is matched to addons.
@MainActor
@Observable
final class SpotifyService {
    static let sourceID = "spotify"
    static let redirectURI = "halo://spotify-callback"
    static let scopes = [
        "user-read-private", "user-library-read", "user-top-read", "user-read-recently-played",
        "playlist-read-private", "playlist-read-collaborative", "user-follow-read",
    ]

    struct Profile: Codable, Sendable { var name: String; var imageURL: URL? }

    struct HomeData: Codable, Sendable {
        var recent: [Track] = []
        var topTracks: [Track] = []
        var topArtists: [Artist] = []
        var playlists: [RemotePlaylist] = []
        var albums: [Album] = []
        var liked: [Track] = []
        var likedTotal: Int = 0
        var followed: [Artist] = []
        var fetchedAt: Date = .distantPast
    }

    private(set) var profile: Profile?
    private(set) var home = HomeData()
    private(set) var isLoading = false
    private(set) var lastError: String?

    var isConnected: Bool { tokens != nil }

    private struct Tokens: Codable {
        var access: String
        var refresh: String?
        var expires: Date
    }

    @ObservationIgnored private var tokens: Tokens? {
        didSet { Keychain.set(tokens.flatMap { try? JSONEncoder().encode($0) }, for: "spotify.tokens") }
    }
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter = AuthPresenter()
    @ObservationIgnored private let api = URLSession(configuration: .default)

    init() {
        if let data = Keychain.get("spotify.tokens") {
            tokens = try? JSONDecoder().decode(Tokens.self, from: data)
        }
        home = Store.load(HomeData.self, from: "spotify-home.json") ?? HomeData()
        profile = Store.load(Profile.self, from: "spotify-profile.json")
    }

    // MARK: Login

    func connect(clientID: String) async {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { lastError = "Paste your Spotify app's Client ID first."; return }
        lastError = nil

        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
        ]
        guard let authURL = comps.url else { return }

        do {
            let callback: URL = try await withCheckedThrowingContinuation { cont in
                let session = ASWebAuthenticationSession(url: authURL, callback: .customScheme("halo")) { url, error in
                    if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? URLError(.cancelled)) }
                }
                session.presentationContextProvider = presenter
                session.prefersEphemeralWebBrowserSession = false
                authSession = session
                session.start()
            }
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let err = items.first(where: { $0.name == "error" })?.value {
                lastError = "Spotify said: \(err)"
                return
            }
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                lastError = "Spotify login didn't return a code."
                return
            }
            try await exchange(["grant_type": "authorization_code", "code": code,
                                "redirect_uri": Self.redirectURI, "client_id": id, "code_verifier": verifier])
            await refreshHome(force: true)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                lastError = error.localizedDescription
            }
        }
    }

    func disconnect() {
        tokens = nil
        profile = nil
        home = HomeData()
        Store.save(home, to: "spotify-home.json")
    }

    private func exchange(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await api.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AddonError.addonMessage("Spotify login failed. \(body.prefix(160))")
        }
        let expiresIn = obj["expires_in"] as? Double ?? 3600
        tokens = Tokens(access: access, refresh: (obj["refresh_token"] as? String) ?? tokens?.refresh,
                        expires: Date().addingTimeInterval(expiresIn - 60))
    }

    private func validToken() async throws -> String {
        guard let t = tokens else { throw AddonError.addonMessage("Not connected to Spotify.") }
        if t.expires > Date() { return t.access }
        guard let refresh = t.refresh else { throw AddonError.addonMessage("Spotify session expired. Connect again.") }
        try await exchange(["grant_type": "refresh_token", "refresh_token": refresh,
                            "client_id": AppSettings.shared.spotifyClientID])
        return tokens?.access ?? ""
    }

    // MARK: API

    private func get(_ path: String) async throws -> [String: Any] {
        let token = try await validToken()
        let url = path.hasPrefix("http") ? URL(string: path)! : URL(string: "https://api.spotify.com/v1" + path)!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for attempt in 0..<3 {
            let (data, response) = try await api.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429, attempt < 2 {
                let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(for: .seconds(min(wait, 10)))
                continue
            }
            if status == 401 { tokens?.expires = .distantPast }
            guard status == 200 else { throw AddonError.badStatus(status) }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        throw AddonError.badStatus(429)
    }

    /// Re-imports Home. Every section is optional: Spotify keeps removing endpoints from developer-mode apps.
    func refreshHome(force: Bool = false) async {
        guard isConnected, !isLoading else { return }
        if !force, Date().timeIntervalSince(home.fetchedAt) < 30 * 60 { return }
        isLoading = true
        defer { isLoading = false }

        if let me = try? await get("/me") {
            let image = ((me["images"] as? [[String: Any]])?.first?["url"] as? String).flatMap(URL.init)
            profile = Profile(name: me["display_name"] as? String ?? me["id"] as? String ?? "You", imageURL: image)
            Store.save(profile, to: "spotify-profile.json")
        }

        var data = HomeData()
        async let recentJSON = try? get("/me/player/recently-played?limit=50")
        async let topJSON = try? get("/me/top/tracks?limit=50&time_range=short_term")
        async let artistsJSON = try? get("/me/top/artists?limit=20&time_range=medium_term")
        async let playlistsJSON = try? get("/me/playlists?limit=50")
        async let albumsJSON = try? get("/me/albums?limit=30")
        async let likedJSON = try? get("/me/tracks?limit=50")
        async let followedJSON = try? get("/me/following?type=artist&limit=30")

        if let j = await recentJSON {
            var seen = Set<String>()
            data.recent = ((j["items"] as? [[String: Any]]) ?? []).compactMap { Self.track($0["track"]) }.filter { seen.insert($0.id).inserted }
        }
        if let j = await topJSON { data.topTracks = ((j["items"] as? [[String: Any]]) ?? []).compactMap { Self.track($0) } }
        if let j = await artistsJSON { data.topArtists = ((j["items"] as? [[String: Any]]) ?? []).compactMap(Self.artist) }
        if let j = await playlistsJSON { data.playlists = ((j["items"] as? [[String: Any]]) ?? []).compactMap(Self.playlist) }
        if let j = await albumsJSON { data.albums = ((j["items"] as? [[String: Any]]) ?? []).compactMap { Self.album($0["album"]) } }
        if let j = await likedJSON {
            data.liked = ((j["items"] as? [[String: Any]]) ?? []).compactMap { Self.track($0["track"]) }
            data.likedTotal = j["total"] as? Int ?? data.liked.count
        }
        if let j = await followedJSON {
            let artists = (j["artists"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            data.followed = artists.compactMap(Self.artist)
        }
        data.fetchedAt = Date()
        if data.recent.isEmpty && data.topTracks.isEmpty && data.playlists.isEmpty && data.liked.isEmpty {
            lastError = "Spotify returned nothing. If your app is in Development Mode, add your account under Users Management on developer.spotify.com."
        } else {
            lastError = nil
        }
        home = data
        Store.save(home, to: "spotify-home.json")
    }

    // MARK: Search (Spotify is the metadata source; addons only play)

    func search(_ query: String) async throws -> AddonSearchResult {
        var comps = URLComponents(string: "https://api.spotify.com/v1/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track,artist,album,playlist"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        let j = try await get(comps.url!.absoluteString)
        func items(_ key: String) -> [[String: Any]] {
            ((j[key] as? [String: Any])?["items"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }
        return AddonSearchResult(
            tracks: items("tracks").compactMap { Self.track($0) },
            albums: items("albums").compactMap { Self.album($0) },
            artists: items("artists").compactMap(Self.artist),
            playlists: items("playlists").compactMap(Self.playlist)
        )
    }

    /// An artist's most popular songs, via search (top-tracks is often unavailable to developer apps).
    private func popular(_ artist: Artist) async -> [Track] {
        var comps = URLComponents(string: "https://api.spotify.com/v1/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: "artist:\"\(artist.name)\""),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let j = try? await get(comps.url!.absoluteString) else { return [] }
        let rows = ((j["tracks"] as? [String: Any])?["items"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        return rows.compactMap { Self.track($0) }.filter { $0.artistID == artist.artistID || $0.artist.localizedCaseInsensitiveContains(artist.name) }
    }

    // MARK: Details

    func playlistTracks(_ id: String) async throws -> [Track] {
        var tracks: [Track] = []
        var next: String? = "/playlists/\(id)/items?limit=100&additional_types=track"
        var triedLegacy = false
        while let path = next, tracks.count < 1000 {
            let page: [String: Any]
            do {
                page = try await get(path)
            } catch AddonError.badStatus(let code) where (code == 404 || code == 403) && !triedLegacy && tracks.isEmpty {
                triedLegacy = true
                next = "/playlists/\(id)/tracks?limit=100"
                continue
            }
            for row in (page["items"] as? [[String: Any]]) ?? [] {
                if let t = Self.track(row["item"] ?? row["track"]) { tracks.append(t) }
            }
            next = page["next"] as? String
        }
        return tracks
    }

    func likedTracks() async throws -> [Track] {
        var tracks: [Track] = []
        var next: String? = "/me/tracks?limit=50"
        while let path = next, tracks.count < 2000 {
            let page = try await get(path)
            tracks += ((page["items"] as? [[String: Any]]) ?? []).compactMap { Self.track($0["track"]) }
            next = page["next"] as? String
        }
        return tracks
    }

    func albumTracks(_ album: Album) async throws -> [Track] {
        let j = try await get("/albums/\(album.albumID)")
        let items = ((j["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let art = Self.image(j["images"])
        return items.compactMap { row -> Track? in
            guard var t = Self.track(row) else { return nil }
            if t.album == nil { t.album = album.title }
            if t.artworkURL == nil { t.artworkURL = art ?? album.artworkURL }
            t.albumID = album.albumID
            return t
        }
    }

    func artistDetail(_ artist: Artist) async -> (Artist, [Track], [Album]) {
        var info = artist
        if let j = try? await get("/artists/\(artist.artistID)") {
            info = Self.artist(j) ?? artist
        }
        var top: [Track] = []
        if let j = try? await get("/artists/\(artist.artistID)/top-tracks") {
            top = ((j["tracks"] as? [[String: Any]]) ?? []).compactMap { Self.track($0) }
        }
        var albums: [Album] = []
        if let j = try? await get("/artists/\(artist.artistID)/albums?include_groups=album,single&limit=30") {
            albums = ((j["items"] as? [[String: Any]]) ?? []).compactMap { Self.album($0) }
        }
        if top.isEmpty { top = await popular(artist) }
        if top.isEmpty {
            // Endpoint unavailable: fall back to this artist's songs among the user's own.
            let mine = home.topTracks + home.liked + home.recent
            var seen = Set<String>()
            top = mine.filter { $0.artistID == artist.artistID || $0.artist.localizedCaseInsensitiveContains(artist.name) }
                .filter { seen.insert($0.id).inserted }
        }
        return (info, top, albums)
    }

    // MARK: JSON → models

    private static func image(_ any: Any?) -> URL? {
        guard let images = any as? [[String: Any]] else { return nil }
        // Largest first in Spotify's arrays.
        return (images.first?["url"] as? String).flatMap(URL.init)
    }

    static func track(_ any: Any?) -> Track? {
        guard let j = any as? [String: Any], let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
        if (j["type"] as? String).map({ $0 != "track" }) == true { return nil }
        let artists = (j["artists"] as? [[String: Any]]) ?? []
        let album = j["album"] as? [String: Any]
        let isrc = (j["external_ids"] as? [String: Any])?["isrc"] as? String
        return Track(
            id: "spotify:\(id)",
            title: name,
            artist: artists.compactMap { $0["name"] as? String }.joined(separator: ", "),
            album: album?["name"] as? String,
            duration: (j["duration_ms"] as? Double).map { $0 / 1000 },
            artworkURL: image(album?["images"]),
            source: .catalog(service: sourceID, id: id),
            isrc: isrc,
            albumID: album?["id"] as? String,
            artistID: artists.first?["id"] as? String,
            explicit: j["explicit"] as? Bool
        )
    }

    static func artist(_ j: [String: Any]) -> Artist? {
        guard let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
        return Artist(addonID: sourceID, artistID: id, name: name, artworkURL: image(j["images"]),
                      genres: (j["genres"] as? [String]) ?? [], bio: nil,
                      followers: (j["followers"] as? [String: Any])?["total"] as? Int)
    }

    static func playlist(_ j: [String: Any]) -> RemotePlaylist? {
        guard let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
        let owner = (j["owner"] as? [String: Any])?["display_name"] as? String
        let count = ((j["items"] ?? j["tracks"]) as? [String: Any])?["total"] as? Int
        return RemotePlaylist(addonID: sourceID, playlistID: id, title: name, creator: owner,
                              artworkURL: image(j["images"]), trackCount: count,
                              description: (j["description"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func album(_ any: Any?) -> Album? {
        guard let j = any as? [String: Any], let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
        let artists = (j["artists"] as? [[String: Any]]) ?? []
        return Album(addonID: sourceID, albumID: id, title: name,
                     artist: artists.compactMap { $0["name"] as? String }.joined(separator: ", "),
                     artworkURL: image(j["images"]), year: (j["release_date"] as? String).map { String($0.prefix(4)) },
                     trackCount: j["total_tracks"] as? Int, description: nil)
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

enum Keychain {
    static func set(_ data: Data?, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                    kSecAttrService as String: "com.aa.halo"]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                    kSecAttrService as String: "com.aa.halo", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
