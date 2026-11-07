import Foundation

enum AddonError: LocalizedError {
    case invalidURL
    case notFound
    case badStatus(Int)
    case invalidResponse(String)
    case addonMessage(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid addon URL."
        case .notFound: return "This addon doesn't have that track."
        case .badStatus(let code): return "The addon responded with HTTP \(code)."
        case .invalidResponse(let what): return "The addon sent an unexpected \(what)."
        case .addonMessage(let message): return message
        case .unsupported(let why): return why
        }
    }
}

/// Talks to addons over HTTP. Compatible with the Eclipse / BitChord addon protocol.
/// See docs/ADDON_SPEC.md.
enum AddonClient {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Halo/0.1 (iOS)"]
        return URLSession(configuration: config)
    }()

    /// Accepts "https://x.com/TOKEN/manifest.json", "https://x.com/TOKEN/", or "x.com/TOKEN".
    /// Only a trailing "*.json" filename is removed. Tokens in the path and query are kept.
    static func normalize(_ input: String) throws -> (manifest: URL, base: URL) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw AddonError.invalidURL }
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
            manifest = try await get(manifestURL, what: "manifest")
        } catch AddonError.notFound {
            throw AddonError.addonMessage("No addon manifest at that URL.")
        }
        guard !manifest.id.isEmpty else {
            throw AddonError.addonMessage("That URL answered, but not with an addon manifest.")
        }
        guard manifest.supports("search") else {
            throw AddonError.addonMessage("This addon declares \(manifest.resources.joined(separator: ", ")). Halo needs search.")
        }
        return InstalledAddon(manifest: manifest, baseURL: base)
    }

    static func search(_ addon: InstalledAddon, query: String) async throws -> [Track] {
        var params = addon.manifest.defaultParameters
        params["q"] = query
        guard let url = endpoint(base: addon.baseURL, segments: ["search"], params: params) else {
            throw AddonError.invalidURL
        }
        let response: SearchResponse = try await get(url, what: "search result")
        return response.tracks.map { $0.toTrack(addonID: addon.id) }
    }

    static func resolveStream(_ addon: InstalledAddon, trackID: String) async throws -> StreamInfo {
        guard let url = endpoint(base: addon.baseURL, segments: ["stream", trackID],
                                 params: addon.manifest.defaultParameters) else {
            throw AddonError.invalidURL
        }
        let response: StreamResponse = try await get(url, what: "stream")
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
            throw AddonError.unsupported("This addon returned a DASH stream. iPhone only plays HLS or plain files. Try a different quality setting.")
        }
        return StreamInfo(url: streamURL, headers: response.headers)
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
        return comps.url
    }

    private static func get<T: Decodable>(_ url: URL, what: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200

            if status == 429, attempt < 2 {
                // Busy addon: wait it out instead of treating it as "no track".
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let wait = min(Double(header ?? "") ?? pow(2, Double(attempt)), 5)
                attempt += 1
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            if status == 404 { throw AddonError.notFound }
            guard (200..<300).contains(status) else {
                if let message = try? JSONDecoder().decode([String: String].self, from: data)["error"] {
                    throw AddonError.addonMessage(message)
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
}
