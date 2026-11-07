import Foundation

/// Finds a playable stream for any track by walking the user's addons in order (Settings › Addons).
///
/// For each addon: its own track id (if the track came from it) → a remembered match →
/// /resolve-isrc → /resolve → search and score. If an addon finds the song but its stream
/// fails, the next addon is tried. So the last addon in the list acts as the fallback.
@MainActor
final class TrackResolver {
    weak var addons: AddonStore?

    private var matches: [String: Track] = [:]
    /// Addons that refused Halo this session (401/403), so we don't ask them for every song.
    private(set) var refused: [String: String] = [:]
    private let file = "matches.json"

    init() {
        matches = Store.load([String: Track].self, from: file) ?? [:]
    }

    func forget(_ track: Track) {
        matches[track.id] = nil
        Store.save(matches, to: file)
    }

    /// Resolves a stream, skipping addons in `excluding` (ones that already failed for this track).
    func stream(for track: Track, excluding: Set<String>) async throws -> (StreamInfo, Track) {
        guard let addons else { throw PlayerError.addonMissing }
        var attempts: [String] = []

        // 1. The addon the track came from.
        if case .addon(let addonID, let trackID) = track.source, !excluding.contains(addonID) {
            if let direct = track.directStreamURL {
                return (StreamInfo(url: direct), track)
            }
            if let ctx = addons.context(forID: addonID) {
                do {
                    return (try await AddonClient.resolveStream(ctx, trackID: trackID), track)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    attempts.append("\(ctx.addon.displayName): \(error.localizedDescription)")
                }
            }
        }

        // 2. A match we found before.
        if let hit = matches[track.id], let id = hit.addonID, !excluding.contains(id),
           let ctx = addons.context(forID: id) {
            do {
                return (try await streamInfo(for: hit, ctx: ctx), hit)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                forget(track)
            }
        }

        // 3. Every other enabled addon, in the user's order.
        for (id, why) in refused where addons.addon(withID: id) != nil {
            attempts.append("\(addons.addon(withID: id)?.displayName ?? id): \(why)")
        }
        let candidates = addons.enabled.filter {
            !excluding.contains($0.id) && $0.id != track.addonID && refused[$0.id] == nil
                && ($0.manifest.supports("search") || $0.manifest.supports("resolve") || $0.manifest.supports("isrc"))
        }
        if candidates.isEmpty && attempts.isEmpty { throw PlayerError.noAddons }

        for addon in candidates {
            try Task.checkCancellation()
            let ctx = addons.context(for: addon)
            do {
                guard let found = try await match(track, in: ctx) else {
                    attempts.append("\(addon.displayName): no match")
                    continue
                }
                let info = try await streamInfo(for: found, ctx: ctx)
                var playable = found
                playable.artworkURL = track.artworkURL ?? found.artworkURL
                matches[track.id] = playable
                Store.save(matches, to: file)
                return (info, playable)
            } catch is CancellationError {
                throw CancellationError()
            } catch AddonError.unauthorized(let why) {
                refused[addon.id] = why
                attempts.append("\(addon.displayName): \(why)")
            } catch {
                attempts.append("\(addon.displayName): \(error.localizedDescription)")
            }
        }
        throw PlayerError.noMatch(track.title, attempts.isEmpty ? nil : attempts.joined(separator: " · "))
    }

    private func streamInfo(for track: Track, ctx: AddonContext) async throws -> StreamInfo {
        if let direct = track.directStreamURL { return StreamInfo(url: direct) }
        guard case .addon(_, let trackID) = track.source else { throw PlayerError.addonMissing }
        return try await AddonClient.resolveStream(ctx, trackID: trackID)
    }

    // MARK: Matching

    private func match(_ track: Track, in ctx: AddonContext) async throws -> Track? {
        let manifest = ctx.addon.manifest
        if manifest.supports("isrc") || manifest.supports("resolve") {
            // A failing resolve endpoint shouldn't stop us from searching.
            if let exact = try? await AddonClient.resolve(ctx, isrc: track.isrc, title: track.title,
                                                          artist: track.artist, duration: track.duration) {
                return exact
            }
        }
        guard manifest.supports("search") else { return nil }

        let title = LyricsService.cleanTitle(track.title)
        let primaryArtist = track.artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? track.artist
        var queries = ["\(title) \(primaryArtist)", title]
        if let isrc = track.isrc, !isrc.isEmpty { queries.insert(isrc, at: 0) }

        var lastError: Error?
        var searched = 0
        for query in queries {
            do {
                let result = try await AddonClient.search(ctx, query: query)
                searched += 1
                if let best = Self.best(result.tracks, for: track) { return best }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        // Only surface the error if no search worked at all.
        if searched == 0, let lastError { throw lastError }
        return nil
    }

    private static let noise: Set<String> = [
        "official", "video", "audio", "lyrics", "lyric", "music", "visualizer", "hd", "hq", "4k", "mv",
        "topic", "vevo", "feat", "ft", "the", "a", "remastered", "remaster", "version", "explicit", "clean",
    ]

    private static func words(_ s: String) -> Set<String> {
        let lowered = s.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let parts = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return Set(parts.filter { !noise.contains($0) })
    }

    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    static func best(_ results: [Track], for target: Track) -> Track? {
        if let isrc = target.isrc?.uppercased(), !isrc.isEmpty,
           let exact = results.first(where: { $0.isrc?.uppercased() == isrc }) {
            return exact
        }
        let wantTitle = words(LyricsService.cleanTitle(target.title))
        let wantArtists = target.artist.components(separatedBy: ",").map(words).filter { !$0.isEmpty }
        let wantLower = target.title.lowercased()

        var best: (Double, Track)?
        for (rank, candidate) in results.prefix(15).enumerated() {
            let title = words(LyricsService.cleanTitle(candidate.title))
            let artist = words(candidate.artist)
            // YouTube-style results often put "Artist - Song" in the title.
            let titleSim = max(similarity(wantTitle, title), similarity(wantTitle, title.subtracting(artist)))
            guard titleSim >= 0.6 else { continue }

            let artistHit = wantArtists.contains { want in
                similarity(want, artist) >= 0.5 || similarity(want, title) >= 1
            }
            var score = titleSim * 6 + (artistHit ? 5 : 0)
            if let a = target.duration, let b = candidate.duration {
                let diff = abs(a - b)
                score += diff < 3 ? 3 : diff < 8 ? 1.5 : diff > 40 ? -5 : 0
            }
            let lowered = candidate.title.lowercased()
            for bad in ["live", "remix", "sped up", "slowed", "karaoke", "instrumental", "cover", "8d", "nightcore", "reverb"]
                where lowered.contains(bad) && !wantLower.contains(bad) {
                score -= 3
            }
            score -= Double(rank) * 0.15
            if score > (best?.0 ?? -.infinity) { best = (score, candidate) }
        }
        // Title match plus either the artist or the length lining up.
        guard let best, best.0 >= 7.5 else { return nil }
        return best.1
    }
}
