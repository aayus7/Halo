import Foundation

/// Turns a track Halo only knows by identity (title, artist, ISRC — e.g. from a Spotify import)
/// into a playable addon track. Order per addon: /resolve-isrc → /resolve → search and score.
@MainActor
final class TrackResolver {
    weak var addons: AddonStore?

    private var matches: [String: Track] = [:]
    private let file = "matches.json"

    init() {
        matches = Store.load([String: Track].self, from: file) ?? [:]
    }

    func forget(_ track: Track) {
        matches[track.id] = nil
    }

    func playable(for track: Track) async throws -> Track {
        if let hit = matches[track.id], let id = hit.addonID, addons?.context(forID: id) != nil { return hit }
        guard let addons else { throw PlayerError.addonMissing }
        let candidates = addons.enabled.filter { $0.manifest.supports("stream") || $0.manifest.supports("search") }
        guard !candidates.isEmpty else { throw PlayerError.noAddons }

        var lastError: Error?
        for addon in candidates {
            let ctx = addons.context(for: addon)
            do {
                if let found = try await match(track, in: ctx) {
                    var playable = found
                    // Keep the nicer catalog metadata for display.
                    playable.artworkURL = track.artworkURL ?? found.artworkURL
                    matches[track.id] = playable
                    Store.save(matches, to: file)
                    return playable
                }
            } catch {
                lastError = error
            }
        }
        if let lastError, !(lastError is CancellationError) {
            throw PlayerError.noMatch(track.title, lastError.localizedDescription)
        }
        throw PlayerError.noMatch(track.title, nil)
    }

    private func match(_ track: Track, in ctx: AddonContext) async throws -> Track? {
        let manifest = ctx.addon.manifest
        if manifest.supports("isrc") || manifest.supports("resolve") {
            if let exact = try await AddonClient.resolve(ctx, isrc: track.isrc, title: track.title,
                                                         artist: track.artist, duration: track.duration) {
                return exact
            }
            if manifest.supports("resolve") { return nil }
        }
        guard manifest.supports("search") else { return nil }
        let primaryArtist = track.artist.components(separatedBy: ",").first ?? track.artist
        let query = "\(LyricsService.cleanTitle(track.title)) \(primaryArtist)"
        let result = try await AddonClient.search(ctx, query: query)
        return Self.best(result.tracks, for: track)
    }

    static func best(_ results: [Track], for target: Track) -> Track? {
        if let isrc = target.isrc?.uppercased(), !isrc.isEmpty,
           let exact = results.first(where: { $0.isrc?.uppercased() == isrc }) {
            return exact
        }
        let wantTitle = ArtworkService.normalize(LyricsService.cleanTitle(target.title))
        let wantArtists = target.artist.lowercased().components(separatedBy: ",").map(ArtworkService.normalize).filter { !$0.isEmpty }
        var best: (Int, Track)?
        for (rank, candidate) in results.prefix(12).enumerated() {
            let title = ArtworkService.normalize(LyricsService.cleanTitle(candidate.title))
            let artist = ArtworkService.normalize(candidate.artist)
            var score = 0
            if title == wantTitle { score += 6 } else if title.contains(wantTitle) || wantTitle.contains(title) { score += 3 } else { continue }
            if wantArtists.contains(where: { artist.contains($0) || $0.contains(artist) }) { score += 5 }
            if let a = target.duration, let b = candidate.duration {
                let diff = abs(a - b)
                score += diff < 3 ? 3 : diff < 8 ? 1 : diff > 30 ? -4 : 0
            }
            let lowered = candidate.title.lowercased()
            for bad in ["live", "remix", "sped up", "slowed", "karaoke", "instrumental", "cover", "8d"]
                where lowered.contains(bad) && !target.title.lowercased().contains(bad) {
                score -= 3
            }
            score -= rank / 4
            if score >= 8, score > (best?.0 ?? Int.min) { best = (score, candidate) }
        }
        return best?.1
    }
}
