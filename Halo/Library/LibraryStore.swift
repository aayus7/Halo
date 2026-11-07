import AVFoundation
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class LibraryStore {
    private(set) var localTracks: [Track] = []
    private(set) var liked: [Track] = []
    private(set) var history: [Track] = []
    private(set) var playCounts: [String: Int] = [:]
    private(set) var isImporting = false
    private(set) var playlists: [UserPlaylist] = []

    @ObservationIgnored private var knownTracks: [String: Track] = [:]

    private struct Snapshot: Codable {
        var liked: [Track]
        var history: [Track]
        var playCounts: [String: Int]
        var known: [Track]
    }

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "aif", "aiff", "caf", "alac"
    ]

    init() {
        if let snap = Store.load(Snapshot.self, from: "library.json") {
            liked = snap.liked
            history = snap.history
            playCounts = snap.playCounts
            for t in snap.known { knownTracks[t.id] = t }
        }
        localTracks = Store.load([Track].self, from: "local.json") ?? []
        playlists = Store.load([UserPlaylist].self, from: "playlists.json") ?? []
        Task { await rescan() }
    }

    // MARK: Likes

    func isLiked(_ track: Track) -> Bool {
        liked.contains { $0.id == track.id }
    }

    func toggleLike(_ track: Track) {
        if let i = liked.firstIndex(where: { $0.id == track.id }) {
            liked.remove(at: i)
        } else {
            liked.insert(track, at: 0)
        }
        save()
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(_ name: String, tracks: [Track] = []) -> UserPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let playlist = UserPlaylist(name: trimmed.isEmpty ? "New Playlist" : trimmed, tracks: tracks)
        playlists.insert(playlist, at: 0)
        savePlaylists()
        return playlist
    }

    func playlist(_ id: String) -> UserPlaylist? {
        playlists.first { $0.id == id }
    }

    func add(_ tracks: [Track], to playlistID: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let existing = Set(playlists[i].tracks.map(\.id))
        playlists[i].tracks += tracks.filter { !existing.contains($0.id) }
        savePlaylists()
    }

    func remove(at offsets: IndexSet, from playlistID: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.remove(atOffsets: offsets)
        savePlaylists()
    }

    func move(from source: IndexSet, to destination: Int, in playlistID: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.move(fromOffsets: source, toOffset: destination)
        savePlaylists()
    }

    func rename(_ playlistID: String, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].name = name
        savePlaylists()
    }

    func deletePlaylist(_ playlistID: String) {
        playlists.removeAll { $0.id == playlistID }
        savePlaylists()
    }

    private func savePlaylists() {
        Store.save(playlists, to: "playlists.json")
        Backup.saveToKeychain()
    }

    // MARK: History & stats

    func recordPlay(_ track: Track) {
        history.removeAll { $0.id == track.id }
        history.insert(track, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        playCounts[track.id, default: 0] += 1
        knownTracks[track.id] = track
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    /// Tracks you've played the most (BitChord-style "On Repeat").
    var mostPlayed: [Track] {
        playCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .compactMap { knownTracks[$0.key] }
            .prefix(25)
            .map { $0 }
    }

    /// Simple "Top Picks": liked + frequently played songs you haven't heard recently.
    var topPicks: [Track] {
        let recentIDs = Set(history.prefix(15).map(\.id))
        var seen = Set<String>()
        var picks: [Track] = []
        for t in mostPlayed + liked where !recentIDs.contains(t.id) && !seen.contains(t.id) {
            seen.insert(t.id)
            picks.append(t)
        }
        return Array(picks.shuffled().prefix(20))
    }

    func search(_ query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        return (localTracks + liked).filter { t in
            guard !seen.contains(t.id) else { return false }
            let hit = t.title.localizedCaseInsensitiveContains(q)
                || t.artist.localizedCaseInsensitiveContains(q)
                || (t.album?.localizedCaseInsensitiveContains(q) ?? false)
            if hit { seen.insert(t.id) }
            return hit
        }
    }

    // MARK: Local files

    func importFiles(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        let fm = FileManager.default
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var dest = Paths.music.appendingPathComponent(url.lastPathComponent)
            var n = 1
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            while fm.fileExists(atPath: dest.path) {
                dest = Paths.music.appendingPathComponent("\(base) \(n).\(ext)")
                n += 1
            }
            try? fm.copyItem(at: url, to: dest)
        }
        await rescan()
    }

    /// Syncs the list with whatever is in Documents/Music (files can also arrive via the Files app).
    func rescan() async {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: Paths.music.path)) ?? []
        let audio = files.filter { Self.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let existing = Dictionary(localTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Track] = []
        for file in audio {
            if let known = existing[Track.localID(for: file)] {
                result.append(known)
            } else {
                result.append(await Self.makeLocalTrack(fileName: file))
            }
        }
        localTracks = result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        Store.save(localTracks, to: "local.json")
    }

    func deleteLocal(_ track: Track) {
        guard case .local(let fileName) = track.source else { return }
        try? FileManager.default.removeItem(at: Paths.music.appendingPathComponent(fileName))
        try? FileManager.default.removeItem(at: Paths.artworkFile(for: track.id))
        localTracks.removeAll { $0.id == track.id }
        Store.save(localTracks, to: "local.json")
    }

    private static func makeLocalTrack(fileName: String) async -> Track {
        let id = Track.localID(for: fileName)
        let url = Paths.music.appendingPathComponent(fileName)
        let asset = AVURLAsset(url: url)
        var title = (fileName as NSString).deletingPathExtension
        var artist = "Unknown Artist"
        var album: String?
        var duration: Double?

        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            duration = d.seconds
        }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                case .commonKeyArtist:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
                case .commonKeyAlbumName:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { album = v }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        try? data.write(to: Paths.artworkFile(for: id))
                    }
                default:
                    break
                }
            }
        }
        return Track(id: id, title: title, artist: artist, album: album, duration: duration,
                     artworkURL: nil, directStreamURL: nil, source: .local(fileName: fileName))
    }

    private func save() {
        let snap = Snapshot(liked: liked, history: history, playCounts: playCounts,
                            known: Array(knownTracks.values))
        Store.save(snap, to: "library.json")
    }
}
