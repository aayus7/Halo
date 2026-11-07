import AVFoundation
import XCTest
@testable import Halo

/// End-to-end checks of the addon pipeline against mock addons built from real manifests.
@MainActor
final class AddonPipelineTests: XCTestCase {
    let tidoBase = "https://tido.test/tok"
    let lockedBase = "https://locked.test/tok"
    var tone: URL!

    override func setUp() async throws {
        MockAddonProtocol.install()
        tone = Fixtures.toneFile()
        let toneURL = tone.absoluteString

        // A Tido-like addon: real manifest; resolve endpoints don't know the song; search does;
        // Hi-Res tiers come back as DASH (like Tidal), LOSSLESS as a plain FLAC file.
        MockAddonProtocol.routes["tido.test"] = { path, query in
            switch path {
            case "/manifest.json":
                return .init(json: Fixtures.tidoManifest)
            case "/resolve-isrc":
                return .init(status: 404, json: ["error": "not found"])
            case "/resolve":
                return .init(json: ["item": NSNull()])
            case "/search":
                let q = query["q"] ?? ""
                guard q.localizedCaseInsensitiveContains("family business") || q == "USDJ20400376" else {
                    return .init(json: ["tracks": []])
                }
                return .init(json: ["tracks": [
                    ["id": "t-live", "title": "Family Business (Live at Abbey Road)", "artist": "Kanye West", "duration": 402],
                    ["id": "t-cover", "title": "Family Business", "artist": "Some Cover Band", "duration": 300],
                    ["id": "t-good", "title": "Family Business", "artist": "Kanye West", "album": "The College Dropout", "duration": 356],
                ]])
            case "/stream/t-good":
                switch query["quality"] ?? "MAX" {
                case "MAX", "HIRES":
                    return .init(json: ["url": "https://cdn.test/t-good.mpd", "codec": "flac", "manifest": "dash"])
                default:
                    return .init(json: ["url": toneURL, "codec": "flac", "container": "flac", "manifest": "none",
                                        "sampleRate": 44100, "bitDepth": 16, "quality": "Lossless"])
                }
            default:
                return .init(status: 404, json: ["error": "not found"])
            }
        }

        // An addon that only answers BitChord (signed device token), like juanjob hi res.
        MockAddonProtocol.routes["locked.test"] = { path, _ in
            if path == "/manifest.json" {
                return .init(json: ["id": "dev.locked", "name": "Locked", "version": "1.0", "resources": ["search", "stream"]])
            }
            return .init(status: 401, json: ["error": "missing", "message": "This addon only works in the official BitChord app"])
        }
    }

    private func freshStore() -> AddonStore {
        let store = AddonStore()
        for addon in store.addons { store.remove(addon) }
        return store
    }

    // MARK: Manifest

    func testRealTidoManifestParses() async throws {
        let addon = try await AddonClient.fetchManifest(from: tidoBase + "/manifest.json")
        XCTAssertEqual(addon.manifest.name, "Tido")
        XCTAssertTrue(addon.manifest.supports("isrc"))
        XCTAssertTrue(addon.manifest.supports("resolve"))
        XCTAssertTrue(addon.manifest.supports("search"))
        XCTAssertEqual(addon.manifest.catalogs.count, 2)
        let quality = try XCTUnwrap(addon.manifest.settings.first { $0.key == "quality" })
        XCTAssertTrue(quality.perNetwork)
        XCTAssertEqual(quality.default?.queryValue, "MAX")
        XCTAssertNil(addon.manifest.lockedToApp)
    }

    func testQualityLadderStepsDownFromDefault() async throws {
        let store = freshStore()
        let addon = try await store.install(from: tidoBase + "/manifest.json")
        let ladder = AddonClient.qualityLadder(store.context(for: addon)).map { $0?.1 }
        XCTAssertEqual(ladder, [nil, "LOSSLESS", "HIGH", "LOW"])
    }

    func testBitChordLockedManifestIsRefusedAtInstall() async {
        MockAddonProtocol.routes["bc.test"] = { _, _ in
            .init(json: ["id": "dev.akira.bitchord-hires", "name": "juanjob hi res", "version": "1.2.1",
                         "resources": ["search", "stream"], "bitchordAuth": true])
        }
        do {
            _ = try await AddonClient.fetchManifest(from: "https://bc.test/manifest.json")
            XCTFail("should refuse")
        } catch AddonError.lockedToApp(let app) {
            XCTAssertEqual(app, "BitChord")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: Resolving

    func testImportedSongResolvesThroughSearchAndFallsBackToPlayableQuality() async throws {
        let store = freshStore()
        try await store.install(from: tidoBase + "/manifest.json")
        let resolver = TrackResolver()
        resolver.addons = store

        let (info, playable) = try await resolver.stream(for: Fixtures.familyBusiness, excluding: [])
        XCTAssertEqual(playable.addonID, "com.yourname.tidal.hifi")
        guard case .addon(_, let trackID) = playable.source else { return XCTFail("not an addon track") }
        XCTAssertEqual(trackID, "t-good", "should pick the studio version by Kanye, not the live one or the cover")
        XCTAssertEqual(info.url.absoluteString, tone.absoluteString, "DASH tiers must be skipped for LOSSLESS")
        XCTAssertEqual(info.codec, "flac")
        // It did search even though resolve-isrc / resolve said no.
        XCTAssertTrue(MockAddonProtocol.log.contains { $0.contains("/search") })
        XCTAssertTrue(MockAddonProtocol.log.contains { $0.contains("/stream/t-good") && $0.contains("quality=LOSSLESS") })
    }

    func testLockedAddonIsSkippedAndNextAddonPlays() async throws {
        let store = freshStore()
        try await store.install(from: lockedBase + "/manifest.json")
        try await store.install(from: tidoBase + "/manifest.json")
        XCTAssertEqual(store.addons.first?.id, "dev.locked")
        let resolver = TrackResolver()
        resolver.addons = store

        let (_, playable) = try await resolver.stream(for: Fixtures.familyBusiness, excluding: [])
        XCTAssertEqual(playable.addonID, "com.yourname.tidal.hifi")
        XCTAssertNotNil(resolver.refused["dev.locked"])
    }

    func testUnknownSongGivesReadableError() async throws {
        let store = freshStore()
        try await store.install(from: tidoBase + "/manifest.json")
        let resolver = TrackResolver()
        resolver.addons = store
        let missing = Track(id: "spotify:none", title: "Nonexistent Song", artist: "Nobody",
                            source: .catalog(service: "spotify", id: "none"))
        do {
            _ = try await resolver.stream(for: missing, excluding: [])
            XCTFail("should not resolve")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nonexistent Song"))
            XCTAssertTrue(error.localizedDescription.contains("Tido"))
        }
    }

    // MARK: Playback (real AVPlayer, in the simulator)

    func testImportedSongActuallyPlays() async throws {
        let store = freshStore()
        try await store.install(from: tidoBase + "/manifest.json")
        let engine = PlayerEngine()
        engine.addons = store
        engine.play([Fixtures.familyBusiness])

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, !(engine.isPlaying && engine.currentTime > 0.5) {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(engine.isPlaying, "engine should be playing")
        XCTAssertGreaterThan(engine.currentTime, 0.5, "playhead should move")
        XCTAssertEqual(engine.playingAs?.addonID, "com.yourname.tidal.hifi")
        XCTAssertEqual(engine.currentStream?.codec, "flac")
        engine.pause()
    }

    func testFailedSongDoesNotHopThroughTheQueue() async throws {
        let store = freshStore()
        try await store.install(from: tidoBase + "/manifest.json")
        let engine = PlayerEngine()
        engine.addons = store
        let queue = (1...6).map {
            Track(id: "spotify:missing\($0)", title: "Missing \($0)", artist: "Nobody",
                  source: .catalog(service: "spotify", id: "missing\($0)"))
        }
        engine.play(queue)
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(engine.currentIndex, 0, "a song the user tapped should stop on failure, not skip")
        XCTAssertFalse(engine.isPlaying)
    }

    func testFailurePolicy() {
        XCTAssertFalse(PlayerEngine.shouldSkipAfterFailure(userInitiated: true, consecutiveFailures: 1, hasNext: true))
        XCTAssertTrue(PlayerEngine.shouldSkipAfterFailure(userInitiated: false, consecutiveFailures: 1, hasNext: true))
        XCTAssertFalse(PlayerEngine.shouldSkipAfterFailure(userInitiated: false, consecutiveFailures: 3, hasNext: true))
        XCTAssertFalse(PlayerEngine.shouldSkipAfterFailure(userInitiated: false, consecutiveFailures: 1, hasNext: false))
    }
}

/// Matching and parsing, no network.
final class MatchingTests: XCTestCase {
    private func addonTrack(_ id: String, _ title: String, _ artist: String, _ duration: Double? = nil) -> Track {
        Track(id: "addon:x:\(id)", title: title, artist: artist, duration: duration, source: .addon(addonID: "x", trackID: id))
    }

    @MainActor
    func testYouTubeStyleTitlesMatch() {
        let target = Track(id: "s", title: "BIRDS OF A FEATHER", artist: "Billie Eilish", duration: 210,
                           source: .catalog(service: "spotify", id: "s"))
        let results = [
            addonTrack("1", "BIRDS OF A FEATHER (Sped Up)", "Billie Eilish", 170),
            addonTrack("2", "Billie Eilish - BIRDS OF A FEATHER (Official Music Video)", "Billie Eilish", 231),
            addonTrack("3", "BIRDS OF A FEATHER", "Billie Eilish - Topic", 211),
        ]
        XCTAssertEqual(TrackResolver.best(results, for: target)?.id, "addon:x:3")
    }

    @MainActor
    func testFeaturedArtistsAndRemasterTags() {
        let target = Track(id: "s", title: "Money Trees (feat. Jay Rock)", artist: "Kendrick Lamar, Jay Rock", duration: 386,
                           source: .catalog(service: "spotify", id: "s"))
        let results = [addonTrack("1", "Money Trees", "Kendrick Lamar", 386)]
        XCTAssertEqual(TrackResolver.best(results, for: target)?.id, "addon:x:1")
    }

    @MainActor
    func testWrongSongIsNotMatched() {
        let target = Track(id: "s", title: "Family Business", artist: "Kanye West", duration: 356,
                           source: .catalog(service: "spotify", id: "s"))
        let results = [addonTrack("1", "Family Affair", "Mary J. Blige", 266)]
        XCTAssertNil(TrackResolver.best(results, for: target))
    }

    @MainActor
    func testISRCWins() {
        var target = Fixtures.familyBusiness
        target.isrc = "ABC123"
        var exact = addonTrack("9", "Family Business - 2004 Version", "K. West")
        exact.isrc = "abc123"
        XCTAssertEqual(TrackResolver.best([addonTrack("1", "Family Business", "Kanye West", 356), exact], for: target)?.id, exact.id)
    }

    func testLRCParsing() throws {
        let lrc = """
        [ar:Test]
        [00:12.00]First line
        [00:15.50]<00:15.50>Word <00:16.00>timed <00:16.80>line
        [00:30.00]
        [00:40.00]After the break
        """
        let lyrics = try XCTUnwrap(LRCParser.parse(lrc, duration: 60, source: "test"))
        XCTAssertEqual(lyrics.kind, .synced)
        XCTAssertTrue(lyrics.hasRealWordTiming)
        XCTAssertTrue(lyrics.lines.contains { $0.isInstrumentalBreak }, "10 s gap should become dots")
        XCTAssertEqual(lyrics.lines.first { $0.text == "Word timed line" }?.words.count, 3)
        XCTAssertEqual(lyrics.index(at: 16), lyrics.lines.firstIndex { $0.text == "Word timed line" })
    }

    func testStreamResponseTransport() throws {
        let dash = try JSONDecoder().decode(StreamResponse.self, from: Data(#"{"url":"https://x/a.mpd","codec":"flac"}"#.utf8))
        XCTAssertEqual(dash.transport, "dash")
        let flac = try JSONDecoder().decode(StreamResponse.self, from: Data(#"{"url":"https://x/a.flac","manifest":"none","encrypted":false,"sampleRate":96000,"bitDepth":24}"#.utf8))
        XCTAssertNil(flac.transport)
        XCTAssertFalse(flac.isEncrypted)
        XCTAssertEqual(flac.toStreamInfo(flac.url!).summary, "24-bit · 96 kHz")
    }
}
