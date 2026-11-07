import Foundation
import Observation
import SwiftUI

/// User preferences, persisted to UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // Appearance
    var accentHex: String { didSet { save("accentHex", accentHex) } }
    var artworkTinting: Bool { didSet { save("artworkTinting", artworkTinting) } }

    // Artwork
    var hiResArtwork: Bool { didSet { save("hiResArtwork", hiResArtwork) } }
    var animatedArtwork: Bool { didSet { save("animatedArtwork", animatedArtwork) } }
    /// A MusicKit developer token (JWT) the user generated with their own Apple developer account.
    var appleMusicToken: String { didSet { save("appleMusicToken", appleMusicToken) } }
    var storefront: String { didSet { save("storefront", storefront) } }

    // Lyrics
    var lyricsEnabled: Bool { didSet { save("lyricsEnabled", lyricsEnabled) } }
    var lyricsUppercase: Bool { didSet { save("lyricsUppercase", lyricsUppercase) } }

    // Playback
    var crossfade: Double { didSet { save("crossfade", crossfade) } }
    var gapless: Bool { didSet { save("gapless", gapless) } }
    var speed: Double { didSet { save("speed", speed) } }
    var keepPitch: Bool { didSet { save("keepPitch", keepPitch) } }
    var autoplay: Bool { didSet { save("autoplay", autoplay) } }

    // Sound
    var eqEnabled: Bool { didSet { save("eqEnabled", eqEnabled) } }
    var eqGains: [Double] { didSet { save("eqGains", eqGains) } }
    var preamp: Double { didSet { save("preamp", preamp) } }
    var bassBoost: Double { didSet { save("bassBoost", bassBoost) } }
    var stereoWidth: Double { didSet { save("stereoWidth", stereoWidth) } }

    // Spotify import
    var spotifyClientID: String { didSet { save("spotifyClientID", spotifyClientID) } }

    static let eqFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { (d.object(forKey: "halo." + key) as? T) ?? fallback }
        accentHex = value("accentHex", "A373FF")
        artworkTinting = value("artworkTinting", true)
        hiResArtwork = value("hiResArtwork", true)
        animatedArtwork = value("animatedArtwork", true)
        appleMusicToken = value("appleMusicToken", "")
        storefront = value("storefront", Locale.current.region?.identifier.lowercased() ?? "us")
        lyricsEnabled = value("lyricsEnabled", true)
        lyricsUppercase = value("lyricsUppercase", false)
        crossfade = value("crossfade", 0.0)
        gapless = value("gapless", true)
        speed = value("speed", 1.0)
        keepPitch = value("keepPitch", true)
        autoplay = value("autoplay", true)
        eqEnabled = value("eqEnabled", false)
        let gains: [Double] = value("eqGains", [])
        eqGains = gains.count == Self.eqFrequencies.count ? gains : Array(repeating: 0, count: Self.eqFrequencies.count)
        preamp = value("preamp", 0.0)
        bassBoost = value("bassBoost", 0.0)
        stereoWidth = value("stereoWidth", 1.0)
        spotifyClientID = value("spotifyClientID", "")
    }

    var accent: Color { Color(hex: accentHex) ?? Color(red: 0.64, green: 0.45, blue: 1.0) }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: "halo." + key)
    }
}

/// Built-in EQ presets (gains in dB for the 10 bands).
struct EQPreset: Identifiable, Hashable {
    let name: String
    let gains: [Double]
    var id: String { name }

    static let all: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Warm", gains: [3, 3, 2, 1, 0, -1, -1, -2, -2, -3]),
        EQPreset(name: "Vocal", gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        EQPreset(name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 0, 2, 4, 5]),
        EQPreset(name: "Rock", gains: [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]),
        EQPreset(name: "Late Night", gains: [2, 2, 1, 0, 0, 0, -1, -2, -3, -4]),
        EQPreset(name: "Treble", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        EQPreset(name: "Loudness", gains: [5, 4, 2, 0, -1, 0, 1, 2, 4, 5]),
    ]
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}
