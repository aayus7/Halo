import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// Keeps Halo's setup (addons + their settings, Spotify Client ID, playlists, likes, preferences)
/// safe across app updates and reinstalls.
///
/// • Automatically: a copy lives in the iOS Keychain, which survives updates and even deleting
///   the app, as long as it is signed with the same Team + bundle id. On a fresh install it is
///   restored before anything loads.
/// • Manually: Settings › Backup exports / imports the same data as a .json file.
enum Backup {
    /// Files in Application Support/Halo worth keeping. Caches (artwork, matches) are not.
    static let files = ["addons.json", "addon-settings.json", "playlists.json", "library.json"]
    private static let keychainKey = "halo.backup.v1"
    private static let defaultsPrefix = "halo."

    struct Payload: Codable {
        var version = 1
        var createdAt = Date()
        var files: [String: Data] = [:]
        /// UserDefaults "halo.*" values, as a binary plist.
        var defaults: Data?
        /// Spotify tokens, so the connection survives too.
        var spotifyTokens: Data?
    }

    // MARK: Snapshot / apply

    static func snapshot() -> Payload {
        var payload = Payload()
        for name in files {
            if let data = try? Data(contentsOf: Paths.appSupport.appendingPathComponent(name)) {
                payload.files[name] = data
            }
        }
        let prefs = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix(defaultsPrefix) }
        payload.defaults = try? PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
        payload.spotifyTokens = Keychain.get("spotify.tokens")
        return payload
    }

    static func apply(_ payload: Payload) {
        for (name, data) in payload.files where files.contains(name) {
            try? data.write(to: Paths.appSupport.appendingPathComponent(name), options: .atomic)
        }
        if let data = payload.defaults,
           let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in prefs where key.hasPrefix(defaultsPrefix) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        if let tokens = payload.spotifyTokens, Keychain.get("spotify.tokens") == nil {
            Keychain.set(tokens, for: "spotify.tokens")
        }
    }

    // MARK: Keychain copy

    /// Call at launch, before any store loads. Restores the Keychain copy on a fresh install.
    static func restoreIfFreshInstall() {
        let marker = Paths.appSupport.appendingPathComponent("addons.json")
        guard !FileManager.default.fileExists(atPath: marker.path),
              let data = Keychain.get(keychainKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        apply(payload)
        UserDefaults.standard.set(true, forKey: "halo.restoredFromBackup")
    }

    /// Saves the Keychain copy. Cheap; called when the app goes to the background and after big changes.
    static func saveToKeychain() {
        guard let data = try? JSONEncoder().encode(snapshot()) else { return }
        Keychain.set(data, for: keychainKey)
    }

    static var lastKeychainBackup: Date? {
        guard let data = Keychain.get(keychainKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return payload.createdAt
    }

    // MARK: File export / import

    static func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot())
    }

    static func importData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        apply(payload)
        saveToKeychain()
    }
}

/// A .json backup file for `fileExporter`.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
