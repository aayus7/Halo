import Foundation

enum AddonError: LocalizedError {
    case invalidURL
    case notFound
    case badStatus(Int)
    case invalidResponse(String)
    case addonMessage(String)
    case unsupported(String)
    case lockedToApp(String)
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid addon URL."
        case .notFound: return "This addon doesn't have that."
        case .badStatus(let code): return "The addon responded with HTTP \(code)."
        case .invalidResponse(let what): return "The addon sent an unexpected \(what)."
        case .addonMessage(let message): return message
        case .unsupported(let why): return why
        case .lockedToApp(let app): return "This addon only works inside the \(app) app, so Halo can't use it."
        case .unauthorized(let message): return message
        }
    }
}

/// Everything a request to one addon needs: the addon and the setting values to send.
struct AddonContext: Sendable {
    var addon: InstalledAddon
    /// The manifest's setting defaults overlaid with the user's choices.
    var params: [String: String]
    var noticesEnabled: Bool

    var id: String { addon.id }
}

/// Talks to addons over HTTP. Compatible with the Eclipse / BitChord addon protocol.
/// See docs/ADDON_SPEC.md.
enum AddonClient {
    /// Replaceable so tests can route requests to a mock addon.
    nonisolated(unsafe) static var session: URLSession = makeSession()

    static func makeSession(protocolClasses: [AnyClass] = []) -> URLSession {
        let config = URLSessionConfiguration.default
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses + (config.protocolClasses ?? []) }
        config.timeoutIntervalForRequest = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Halo/0.2 (iOS)"]
        return URLSession(configuration: config)
    }

    /// Accepts "https://x.com/TOKEN/manifest.json", "https://x.com/TOKEN/", or "x.com/TOKEN".
    /// Only a trailing "*.json" filename is removed. Tokens in the path and query are kept.
    static func normalize(_ input: String) throws -> (manifest: URL, base: URL) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw AddonError.invalidURL }
        if s.lowercased().hasPrefix("eclipse://") || s.lowercased().hasPrefix("halo://") {
            s = String(s[s.range(of: "://")!.upperBound...])
        }
        if !s.contains("://") { s = "https://" + s }
        guard var comps = URLComponents(string: s), let host = comps.host, !host.isEmpty,
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw AddonError.invalidURL
        }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if let last = path.split(separator: "/").last, last.lowercased().hasSuffix(".json") {
            path.removeLast(last.count)
            while path.hasSuffix("/") { path.removeLast() }
        }
        comps.path = path
        comps.fragment = nil
        guard let base = comps.url else { throw AddonError.invalidURL }
        guard let manifest = endpoint(base: base, segments: ["manifest.json"], params: [:]) else {
            throw AddonError.invalidURL
        }
        return (manifest, base)
    }

    static func fetchManifest(from input: String) async throws -> InstalledAddon {
        let (manifestURL, base) = try normalize(input)
        let manifest: AddonManifest
        do {
            manifest = try await get(manifestURL, what: "manifest", notices: nil)
        } catch AddonError.notFound {
            throw AddonError.addonMessage("No addon manifest at that URL.")
        }
        guard !manifest.id.isEmpty else {
            throw AddonError.addonMessage("That URL answered, but not with an addon manifest.")
        }
        if let app = manifest.lockedToApp {
            throw AddonError.lockedToApp(app)
        }
        guard manifest.supports("search") || manifest.supports("catalog") else {
            throw AddonError.addonMessage("This addon declares \(manifest.resources.joined(separator: ", ")). Halo needs search or catalog.")
        }
        return InstalledAddon(manifest: manifest, baseURL: base)
    }

    // MARK: Endpoints

    static func search(_ ctx: AddonContext, query: String) async throws -> AddonSearchResult {
        var params = ctx.params
        params["q"] = query
        let url = try url(ctx, ["search"], params)
        let r: SearchResponse = try await get(url, what: "search result", notices: ctx)
        let id = ctx.id
        return AddonSearchResult(
            tracks: r.tracks.map { $0.toTrack(addonID: id) },
            albums: r.albums.map { $0.toAlbum(addonID: id) },
            artists: r.artists.map { $0.toArtist(addonID: id) },
            playlists: r.playlists.map { $0.toPlaylist(addonID: id) }
        )
    }

    static func album(_ ctx: AddonContext, id albumID: String) async throws -> (Album, [Track]) {
        let r: AddonAlbum = try await get(try url(ctx, ["album", albumID], ctx.params), what: "album", notices: ctx)
        return (r.toAlbum(addonID: ctx.id), r.tracksFilled(addonID: ctx.id))
    }

    static func artist(_ ctx: AddonContext, id artistID: String) async throws -> (Artist, [Track], [Album]) {
        let r: AddonArtist = try await get(try url(ctx, ["artist", artistID], ctx.params), what: "artist", notices: ctx)
        let tracks = r.topTracks.map { t -> Track in
            var track = t.toTrack(addonID: ctx.id)
            if track.artistID == nil { track.artistID = r.id }
            return track
        }
        return (r.toArtist(addonID: ctx.id), tracks, r.albums.map { $0.toAlbum(addonID: ctx.id) })
    }

    static func playlist(_ ctx: AddonContext, id playlistID: String) async throws -> (RemotePlaylist, [Track]) {
        let r: AddonPlaylist = try await get(try url(ctx, ["playlist", playlistID], ctx.params), what: "playlist", notices: ctx)
        return (r.toPlaylist(addonID: ctx.id), r.tracks.map { $0.toTrack(addonID: ctx.id) })
    }

    static func catalog(_ ctx: AddonContext, _ catalog: AddonCatalog, skip: Int = 0) async throws -> CatalogRow {
        var params = ctx.params
        params["skip"] = String(skip)
        let r: CatalogResponse = try await get(try url(ctx, ["catalog", catalog.id], params), what: "catalog", notices: ctx)
        var row = CatalogRow(addonID: ctx.id, addonName: ctx.addon.displayName, catalog: catalog)
        for item in r.items {
            if let t = item.track { row.tracks.append(t.toTrack(addonID: ctx.id)) }
            if let a = item.album { row.albums.append(a.toAlbum(addonID: ctx.id)) }
            if let a = item.artist { row.artists.append(a.toArtist(addonID: ctx.id)) }
            if let p = item.playlist { row.playlists.append(p.toPlaylist(addonID: ctx.id)) }
        }
        return row
    }

    /// Asks the addon for the exact recording. Returns nil when it doesn't have it.
    static func resolve(_ ctx: AddonContext, isrc: String?, title: String, artist: String, duration: Double?) async throws -> Track? {
        if let isrc, !isrc.isEmpty, ctx.addon.manifest.supports("isrc") {
            var params = ctx.params
            params["isrc"] = isrc
            do {
                let r: ISRCResponse = try await get(try url(ctx, ["resolve-isrc"], params), what: "ISRC lookup", notices: ctx)
                if let id = r.trackID {
                    return Track(id: Track.addonID(addon: ctx.id, track: id), title: title, artist: artist,
                                 duration: duration, source: .addon(addonID: ctx.id, trackID: id), isrc: isrc)
                }
            } catch AddonError.notFound {}
        }
        guard ctx.addon.manifest.supports("resolve") else { return nil }
        var params = ctx.params
        if let isrc, !isrc.isEmpty { params["isrc"] = isrc }
        params["title"] = title
        params["artist"] = artist
        if let duration { params["durationMs"] = String(Int(duration * 1000)) }
        do {
            let r: ResolveResponse = try await get(try url(ctx, ["resolve"], params), what: "resolve", notices: ctx)
            return r.item?.toTrack(addonID: ctx.id)
        } catch AddonError.notFound {
            return nil
        }
    }

    /// Resolves a stream. If the addon hands back something iPhone can't play (DASH, Ogg, DRM),
    /// it is asked again with each lower option of its "quality" setting before giving up.
    static func resolveStream(_ ctx: AddonContext, trackID: String) async throws -> StreamInfo {
        var params = ctx.params
        var lastError: Error = AddonError.invalidResponse("stream")
        for quality in qualityLadder(ctx) {
            if let q = quality { params[q.0] = q.1 }
            do {
                return try await resolveStreamOnce(ctx, trackID: trackID, params: params)
            } catch let error as AddonError {
                guard case .unsupported = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// The current quality first, then every option listed after it (manifests list best → worst).
    static func qualityLadder(_ ctx: AddonContext) -> [(String, String)?] {
        guard let setting = ctx.addon.manifest.settings.first(where: {
            $0.type == .select && $0.key.lowercased().contains("quality") && !$0.key.lowercased().contains("video")
        }) else { return [nil] }
        let values = setting.options.compactMap { $0.value?.queryValue }
        let current = ctx.params[setting.key] ?? setting.default?.queryValue
        guard let current, let start = values.firstIndex(of: current) else { return [nil] }
        return [nil] + values[(start + 1)...].map { (setting.key, $0) }
    }

    private static func resolveStreamOnce(_ ctx: AddonContext, trackID: String, params: [String: String]) async throws -> StreamInfo {
        let response: StreamResponse = try await get(try url(ctx, ["stream", trackID], params),
                                                     what: "stream", notices: ctx, retryUnavailable: true)
        if let error = response.error, !error.isEmpty, response.url == nil {
            throw AddonError.addonMessage(error)
        }
        guard let streamURL = response.url else {
            throw AddonError.invalidResponse("stream (no URL)")
        }
        if response.isEncrypted {
            throw AddonError.unsupported("This stream is DRM-protected, which Halo can't play.")
        }
        if response.transport == "dash" {
            throw AddonError.unsupported("The addon only offered a DASH stream, which iPhone can't play. Try a lower quality in the addon's settings.")
        }
        if let codec = response.codec?.lowercased(), ["opus", "vorbis"].contains(codec),
           (response.container?.lowercased() ?? "ogg") == "ogg" {
            throw AddonError.unsupported("The addon returned \(codec.capitalized) in Ogg, which iPhone can't play.")
        }
        return response.toStreamInfo(streamURL)
    }

    // MARK: Plumbing

    private static func url(_ ctx: AddonContext, _ segments: [String], _ params: [String: String]) throws -> URL {
        guard let url = endpoint(base: ctx.addon.baseURL, segments: segments, params: params) else {
            throw AddonError.invalidURL
        }
        return url
    }

    /// {base}/{segments…}?{base query + params}, with each segment percent-encoded.
    static func endpoint(base: URL, segments: [String], params: [String: String]) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        var path = comps.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for segment in segments {
            path += "/" + (segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment)
        }
        comps.percentEncodedPath = path
        var items = comps.queryItems ?? []
        for key in params.keys.sorted() {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: params[key]))
        }
        comps.queryItems = items.isEmpty ? nil : items
        // "+" in a value would otherwise be read as a space by most servers.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    private static func get<T: Decodable>(_ url: URL, what: String, notices ctx: AddonContext?,
                                          retryUnavailable: Bool = false) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            await postNotice(from: data, ctx: ctx)

            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            if status == 429, attempt < 2 {
                // Busy addon: wait it out instead of treating it as "no track".
                let wait = min(retryAfter ?? pow(2, Double(attempt)), 5)
                attempt += 1
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            if status == 503, retryUnavailable, attempt < 4 {
                // "Still preparing this song." Eclipse waits up to 30 s per try.
                let wait = min(retryAfter ?? 5, 30)
                attempt += 1
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            if status == 404 { throw AddonError.notFound }
            guard (200..<300).contains(status) else {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Prefer the human sentence ("message") over a code ("error": "missing").
                    let message = (obj["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if status == 401 || status == 403 {
                        throw AddonError.unauthorized((message ?? "The addon refused the request (HTTP \(status)).") + " Halo can't use this addon.")
                    }
                    if let message { throw AddonError.addonMessage(message) }
                    if let message = obj["error"] as? String { throw AddonError.addonMessage(message) }
                    if let notice = obj["notice"] as? [String: Any], let message = notice["message"] as? String {
                        throw AddonError.addonMessage(message)
                    }
                }
                if status == 401 || status == 403 {
                    throw AddonError.unauthorized("The addon refused the request (HTTP \(status)). It may need its own app or a login.")
                }
                throw AddonError.badStatus(status)
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw AddonError.invalidResponse(what)
            }
        }
    }

    private static func postNotice(from data: Data, ctx: AddonContext?) async {
        guard let ctx, ctx.noticesEnabled, ctx.addon.manifest.supports("notifications"),
              let envelope = try? JSONDecoder().decode(NoticeEnvelope.self, from: data),
              let notice = envelope.notice else { return }
        let name = ctx.addon.displayName
        let icon = ctx.addon.manifest.icon
        await MainActor.run {
            NoticeCenter.shared.post(notice, source: name, icon: icon)
        }
    }
}
