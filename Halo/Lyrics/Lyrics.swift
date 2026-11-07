import Foundation

struct LyricWord: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct LyricLine: Identifiable, Hashable, Sendable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    /// Word timings: real ones from enhanced LRC, otherwise estimated inside the line's span.
    var words: [LyricWord]
    var isInstrumentalBreak = false
}

struct Lyrics: Sendable {
    enum Kind: Sendable { case synced, plain }
    var kind: Kind
    var lines: [LyricLine]
    var source: String
    var hasRealWordTiming = false

    func index(at time: Double) -> Int? {
        guard kind == .synced, !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

enum LRCParser {
    /// Parses LRC, including multiple stamps per line and enhanced `<mm:ss.xx>` word stamps.
    static func parse(_ text: String, duration: Double?, source: String) -> Lyrics? {
        var stamped: [(Double, String)] = []
        var offset = 0.0
        for raw in text.components(separatedBy: .newlines) {
            var line = Substring(raw.trimmingCharacters(in: .whitespaces))
            if line.lowercased().hasPrefix("[offset:") {
                let v = line.dropFirst(8).prefix { $0 != "]" }
                offset = (Double(v.trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                continue
            }
            var times: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                if let t = parseTime(tag) { times.append(t) } else { break }
                line = line[line.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let body = String(line).trimmingCharacters(in: .whitespaces)
            for t in times { stamped.append((max(0, t - offset), body)) }
        }
        guard !stamped.isEmpty else { return nil }
        stamped.sort { $0.0 < $1.0 }

        var lines: [LyricLine] = []
        var realWords = false
        let songEnd = duration ?? ((stamped.last?.0 ?? 0) + 6)
        for (i, entry) in stamped.enumerated() {
            let next = i + 1 < stamped.count ? stamped[i + 1].0 : songEnd
            let (clean, words) = parseWords(entry.1, lineStart: entry.0, lineEnd: next)
            if !words.isEmpty { realWords = true }
            if clean.isEmpty {
                // Empty stamp = an instrumental gap. Keep long ones as a "•••" line.
                if next - entry.0 >= 7 {
                    lines.append(LyricLine(id: lines.count, start: entry.0, end: next, text: "", words: [], isInstrumentalBreak: true))
                }
                continue
            }
            let end = min(next, entry.0 + max(2.5, Double(clean.count) * 0.32 + 1.5))
            lines.append(LyricLine(id: lines.count, start: entry.0, end: max(end, entry.0 + 0.5), text: clean,
                                   words: words.isEmpty ? estimateWords(clean, start: entry.0, end: max(end, entry.0 + 0.5)) : words))
        }
        // A long silence before the first line also gets dots.
        if let first = lines.first, first.start >= 7 {
            lines.insert(LyricLine(id: -1, start: 0, end: first.start, text: "", words: [], isInstrumentalBreak: true), at: 0)
            for i in lines.indices { lines[i].id = i }
        }
        return Lyrics(kind: .synced, lines: lines, source: source, hasRealWordTiming: realWords)
    }

    static func plain(_ text: String, source: String) -> Lyrics? {
        let rows = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard rows.contains(where: { !$0.isEmpty }) else { return nil }
        let lines = rows.enumerated().map { LyricLine(id: $0.offset, start: 0, end: 0, text: $0.element, words: []) }
        return Lyrics(kind: .plain, lines: lines, source: source)
    }

    private static func parseTime<S: StringProtocol>(_ tag: S) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count >= 2, let m = Double(parts[0]) else { return nil }
        let rest = parts[1...].joined(separator: ":").replacingOccurrences(of: ",", with: ".")
        let secParts = rest.split(separator: ":")
        guard let s = Double(secParts[0]) else { return nil }
        var t = m * 60 + s
        if secParts.count > 1, let frac = Double(secParts[1]) { t += frac / 100 }
        return t
    }

    /// Splits "<00:01.20>Hello <00:01.80>world" into clean text plus timed words.
    private static func parseWords(_ body: String, lineStart: Double, lineEnd: Double) -> (String, [LyricWord]) {
        guard body.contains("<") else { return (body, []) }
        var words: [LyricWord] = []
        var clean = ""
        var currentStart: Double?
        var buffer = ""
        var i = body.startIndex
        func flush(until t: Double?) {
            let text = buffer
            buffer = ""
            guard let start = currentStart, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            words.append(LyricWord(text: text, start: start, end: t ?? lineEnd))
        }
        while i < body.endIndex {
            if body[i] == "<", let close = body[i...].firstIndex(of: ">"),
               let t = parseTime(body[body.index(after: i)..<close]) {
                flush(until: t)
                currentStart = t
                i = body.index(after: close)
                continue
            }
            buffer.append(body[i])
            clean.append(body[i])
            i = body.index(after: i)
        }
        flush(until: nil)
        let trimmed = clean.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        return (trimmed, words.isEmpty ? [] : words)
    }

    /// Spreads a line's time over its words by length, so the glow can sweep word by word.
    static func estimateWords(_ text: String, start: Double, end: Double) -> [LyricWord] {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let span = max(end - start, 0.3) * 0.92
        let weights = tokens.map { Double($0.count) + 1.5 }
        let total = weights.reduce(0, +)
        var t = start
        return tokens.enumerated().map { i, w in
            let d = span * weights[i] / total
            defer { t += d }
            return LyricWord(text: (i < tokens.count - 1) ? w + " " : w, start: t, end: t + d)
        }
    }
}

/// Fetches lyrics. LRCLIB is open and keyless; more providers can slot in here later.
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: Lyrics?] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.httpAdditionalHeaders = ["User-Agent": "Halo/0.2 (https://github.com/aayus7/Halo)"]
        return URLSession(configuration: c)
    }()

    func lyrics(for track: Track) async -> Lyrics? {
        if let hit = cache[track.id] { return hit }
        var result: Lyrics?
        if track.isLocal, let embedded = await embedded(track) {
            result = embedded
        }
        if result == nil { result = await lrclib(track) }
        cache[track.id] = result
        return result
    }

    private func embedded(_ track: Track) async -> Lyrics? {
        guard case .local(let fileName) = track.source else { return nil }
        let url = Paths.music.appendingPathComponent(fileName)
        // A sidecar .lrc next to the file wins.
        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
        if let text = try? String(contentsOf: lrc, encoding: .utf8),
           let parsed = LRCParser.parse(text, duration: track.duration, source: "Local .lrc") {
            return parsed
        }
        return nil
    }

    private func lrclib(_ track: Track) async -> Lyrics? {
        let title = Self.cleanTitle(track.title)
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        if let album = track.album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let d = track.duration { items.append(URLQueryItem(name: "duration", value: String(Int(d.rounded())))) }
        comps.queryItems = items
        if let row = await fetchObject(comps.url), let lyrics = convert(row, track: track) { return lyrics }

        // Fuzzy fallback: search and take the closest duration.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title),
                             URLQueryItem(name: "artist_name", value: track.artist)]
        guard let url = search.url, let (data, _) = try? await session.data(from: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let ranked = rows.sorted { a, b in
            let da = abs((a["duration"] as? Double ?? 0) - (track.duration ?? 0))
            let db = abs((b["duration"] as? Double ?? 0) - (track.duration ?? 0))
            let sa = (a["syncedLyrics"] as? String) != nil ? 0 : 1
            let sb = (b["syncedLyrics"] as? String) != nil ? 0 : 1
            return (sa, da) < (sb, db)
        }
        for row in ranked.prefix(3) {
            if let lyrics = convert(row, track: track) { return lyrics }
        }
        return nil
    }

    private func fetchObject(_ url: URL?) async -> [String: Any]? {
        guard let url, let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func convert(_ row: [String: Any], track: Track) -> Lyrics? {
        if row["instrumental"] as? Bool == true {
            return Lyrics(kind: .plain, lines: [LyricLine(id: 0, start: 0, end: 0, text: "♪ Instrumental", words: [])], source: "LRCLIB")
        }
        if let synced = row["syncedLyrics"] as? String,
           let parsed = LRCParser.parse(synced, duration: track.duration, source: "LRCLIB") {
            return parsed
        }
        if let plain = row["plainLyrics"] as? String { return LRCParser.plain(plain, source: "LRCLIB") }
        return nil
    }

    static func cleanTitle(_ title: String) -> String {
        var t = title
        for marker in [" (feat.", " (ft.", " [feat.", " - Remaster", " (Remaster", " - Live", " (Official"] {
            if let r = t.range(of: marker, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
