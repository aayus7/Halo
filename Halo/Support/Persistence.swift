import Foundation

enum Paths {
    static var appSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halo", isDirectory: true)
        ensure(url)
        return url
    }

    /// User-visible music folder (Files app › On My iPhone › Halo › Music).
    static var music: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        ensure(url)
        return url
    }

    static var artwork: URL {
        let url = appSupport.appendingPathComponent("Artwork", isDirectory: true)
        ensure(url)
        return url
    }

    static func artworkFile(for trackID: String) -> URL {
        let safe = Data(trackID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return artwork.appendingPathComponent(String(safe.suffix(120)) + ".jpg")
    }

    private static func ensure(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

enum Store {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = Paths.appSupport.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = Paths.appSupport.appendingPathComponent(name)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
