import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

enum PlayerError: LocalizedError {
    case addonMissing
    case noAddons
    case noMatch(String, String?)

    var errorDescription: String? {
        switch self {
        case .addonMissing: return "The addon for this track isn't installed or enabled."
        case .noAddons: return "Install an addon to play streamed songs."
        case .noMatch(let title, let why):
            return "None of your addons has “\(title)”." + (why.map { " (\($0))" } ?? "")
        }
    }
}

/// One AVPlayer and what it's playing. The engine keeps two, so the next song can be
/// prepared ahead of time and crossfaded or started gaplessly.
@MainActor
final class Deck {
    let player = AVPlayer()
    var track: Track?
    var queueIndex: Int?
    var stream: StreamInfo?
    var item: AVPlayerItem? { player.currentItem }
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var statusObservation: NSKeyValueObservation?
    var generation = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
    }

    func clear() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        track = nil
        queueIndex = nil
        stream = nil
        generation += 1
    }
}

/// Owns playback: queue, two decks, effects, lock screen / Control Center, interruptions, sleep timer.
@MainActor
@Observable
final class PlayerEngine {
    // MARK: Observable state

    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffleEnabled = false
    private(set) var currentStream: StreamInfo?
    /// The addon track actually playing (differs from `currentTrack` for imported catalog songs).
    private(set) var playingAs: Track?
    private(set) var sleepTimerEnd: Date?
    private(set) var sleepAtEndOfTrack = false
    private(set) var queueTitle: String?
    var repeatMode: RepeatMode = .off
    var isNowPlayingPresented = false

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    var upNext: [Track] {
        guard let i = currentIndex else { return [] }
        return Array(queue.dropFirst(i + 1))
    }

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    /// Podcast / audiobook addons get skip buttons instead of previous/next.
    var contentType: AddonManifest.ContentType {
        guard let id = (playingAs ?? currentTrack)?.addonID else { return .music }
        return addons?.addon(withID: id)?.manifest.contentType ?? .music
    }

    var currentChapter: Chapter? {
        guard let chapters = currentStream?.chapters else { return nil }
        return chapters.last { $0.startTime <= currentTime }
    }

    // MARK: Dependencies

    @ObservationIgnored weak var addons: AddonStore? { didSet { resolver.addons = addons } }
    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored let settings = AppSettings.shared
    @ObservationIgnored private let resolver = TrackResolver()

    // MARK: Internals

    @ObservationIgnored private let decks = [Deck(), Deck()]
    @ObservationIgnored private var activeDeck = 0
    private var active: Deck { decks[activeDeck] }
    private var standby: Deck { decks[1 - activeDeck] }
    @ObservationIgnored private var standbyReady = false
    @ObservationIgnored private var preparingStandby = false
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var isCrossfading = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var resolvedCache: [String: (info: StreamInfo, playable: Track, at: Date)] = [:]
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var timeControlObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastTickAt = Date()
    /// Addons whose stream failed to play for a track, so the chain skips them for a while.
    @ObservationIgnored private var failedAddons: [String: Set<String>] = [:]

    /// The playhead at `date`, interpolated between the 4 Hz ticks (for lyrics).
    func time(at date: Date) -> Double {
        guard isPlaying, !isLoading else { return currentTime }
        let ahead = min(max(date.timeIntervalSince(lastTickAt), 0), 0.6) * settings.speed
        return currentTime + ahead
    }

    init() {
        configureAudioSession()
        configureRemoteCommands()
        for (i, deck) in decks.enumerated() { observe(deck, index: i) }
        observeInterruptions()
        applySoundSettings()
    }

    // MARK: Public controls

    func play(_ tracks: [Track], startAt index: Int = 0, title: String? = nil) {
        guard tracks.indices.contains(index) else { return }
        originalQueue = tracks
        queueTitle = title
        failedAddons = [:]
        if shuffleEnabled {
            var rest = tracks
            let first = rest.remove(at: index)
            rest.shuffle()
            queue = [first] + rest
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = index
        }
        consecutiveFailures = 0
        loadCurrent(autoplay: true)
    }

    func playShuffled(_ tracks: [Track], title: String? = nil) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        play(tracks, startAt: Int.random(in: tracks.indices), title: title)
    }

    func playNext(_ track: Track) {
        guard let i = currentIndex else { play([track]); return }
        queue.insert(track, at: i + 1)
        originalQueue.append(track)
        invalidateStandby()
    }

    func addToQueue(_ track: Track) {
        guard currentIndex != nil else { play([track]); return }
        queue.append(track)
        originalQueue.append(track)
        if currentIndex.map({ $0 + 2 == queue.count }) == true { invalidateStandby() }
    }

    func jumpToUpNext(_ offset: Int) {
        guard let i = currentIndex, queue.indices.contains(i + 1 + offset) else { return }
        currentIndex = i + 1 + offset
        loadCurrent(autoplay: true)
    }

    func removeFromUpNext(at offsets: IndexSet) {
        guard let i = currentIndex else { return }
        let absolute = IndexSet(offsets.map { $0 + i + 1 }.filter { queue.indices.contains($0) })
        queue.remove(atOffsets: absolute)
        invalidateStandby()
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard let i = currentIndex else { return }
        var tail = Array(queue.dropFirst(i + 1))
        tail.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue.prefix(i + 1)) + tail
        invalidateStandby()
    }

    func clearUpNext() {
        guard let i = currentIndex else { return }
        queue = Array(queue.prefix(i + 1))
        invalidateStandby()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentTrack != nil else { return }
        if active.item == nil {
            loadCurrent(autoplay: true)
            return
        }
        activateSession()
        active.player.playImmediately(atRate: Float(settings.speed))
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        finishCrossfadeNow()
        active.player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        advance(automatic: false)
    }

    func previous() {
        guard let i = currentIndex else { return }
        if currentTime > 3 || i == 0 {
            seek(to: 0)
        } else {
            currentIndex = i - 1
            loadCurrent(autoplay: true)
        }
    }

    func skip(by seconds: Double) {
        seek(to: min(max(0, currentTime + seconds), max(duration - 1, 0)))
    }

    func seek(to seconds: Double) {
        finishCrossfadeNow()
        let target = max(0, seconds)
        currentTime = target
        lastTickAt = Date()
        active.player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                           toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        guard let current = currentTrack, let i = currentIndex else { return }
        if shuffleEnabled {
            originalQueue = queue
            var rest = queue
            rest.remove(at: i)
            rest.shuffle()
            queue = [current] + rest
            currentIndex = 0
        } else if let idx = originalQueue.firstIndex(where: { $0.id == current.id }) {
            queue = originalQueue
            currentIndex = idx
        }
        invalidateStandby()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        invalidateStandby()
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        sleepAtEndOfTrack = false
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEnd = end
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self else { return }
            await self.fadeOutAndPause()
            self.sleepTimerEnd = nil
        }
    }

    func sleepAfterCurrentTrack() {
        sleepTask?.cancel()
        sleepTimerEnd = nil
        sleepAtEndOfTrack = true
        invalidateStandby()
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTimerEnd = nil
        sleepAtEndOfTrack = false
    }

    private func fadeOutAndPause() async {
        let player = active.player
        let start = player.volume
        for step in 1...20 {
            player.volume = start * Float(20 - step) / 20
            try? await Task.sleep(for: .milliseconds(150))
        }
        pause()
        player.volume = 1
    }

    // MARK: Sound settings

    /// Pushes speed / pitch / EQ settings to the decks and the render thread.
    func applySoundSettings() {
        var v = DSPParameters.Values()
        v.enabled = settings.eqEnabled
        v.gains = settings.eqGains
        v.preamp = settings.preamp
        v.bassBoost = settings.bassBoost
        v.width = settings.stereoWidth
        DSPParameters.shared.update(v)

        let rate = Float(settings.speed)
        for deck in decks {
            deck.player.defaultRate = rate
            deck.item?.audioTimePitchAlgorithm = settings.keepPitch ? .spectral : .varispeed
        }
        if isPlaying, active.player.rate != 0 { active.player.rate = rate }
    }

    // MARK: Loading

    private func loadCurrent(autoplay: Bool) {
        guard let track = currentTrack, let index = currentIndex else { stop(); return }
        loadGeneration += 1
        let generation = loadGeneration
        cancelFade()

        // The next song may already be waiting on the standby deck.
        if standbyReady, standby.queueIndex == index, standby.track?.id == track.id {
            swapToStandby(crossfade: false, autoplay: autoplay)
            return
        }

        active.clear()
        invalidateStandby()
        currentTime = 0
        duration = track.duration ?? 0
        isLoading = true
        isPlaying = autoplay
        currentStream = nil
        playingAs = nil
        nowPlayingArtwork = nil
        updateNowPlaying()
        library?.recordPlay(track)
        loadArtwork(for: track, generation: generation)

        let deck = active
        Task {
            do {
                let (stream, playable) = try await resolve(track)
                guard generation == loadGeneration else { return }
                let item = makeItem(stream)
                await AudioEffects.attach(to: item)
                guard generation == loadGeneration else { return }
                deck.track = track
                deck.queueIndex = index
                deck.stream = stream
                deck.player.volume = 1
                watch(item, on: deck)
                deck.player.replaceCurrentItem(with: item)
                currentStream = stream
                playingAs = playable
                if autoplay {
                    activateSession()
                    deck.player.playImmediately(atRate: Float(settings.speed))
                }
                updateNowPlaying()
            } catch {
                guard generation == loadGeneration else { return }
                handleFailure(track: track, error: error)
            }
        }
    }

    private func loadArtwork(for track: Track, generation: Int) {
        let hiRes = settings.hiResArtwork
        Task {
            guard let image = await ArtworkLoader.image(for: track, hiRes: hiRes, size: 1000) else { return }
            guard generation == loadGeneration else { return }
            nowPlayingArtwork = Self.makeArtwork(image)
            updateNowPlaying()
        }
    }

    private func resolve(_ track: Track) async throws -> (StreamInfo, Track) {
        let excluded = failedAddons[track.id] ?? []
        if let cached = resolvedCache[track.id], Date().timeIntervalSince(cached.at) < 600,
           cached.info.expiresAt.map({ $0.timeIntervalSinceNow > 30 }) ?? true,
           !(cached.playable.addonID.map(excluded.contains) ?? false) {
            return (cached.info, cached.playable)
        }
        if case .local(let fileName) = track.source {
            return (StreamInfo(url: Paths.music.appendingPathComponent(fileName)), track)
        }
        let (info, playable) = try await resolver.stream(for: track, excluding: excluded)
        resolvedCache[track.id] = (info, playable, Date())
        return (info, playable)
    }

    private func makeItem(_ stream: StreamInfo) -> AVPlayerItem {
        var options: [String: Any] = [:]
        if let headers = stream.headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = settings.keepPitch ? .spectral : .varispeed
        item.preferredForwardBufferDuration = 30
        return item
    }

    /// The stream an addon gave us wouldn't play: try the same song on the next addon.
    private func retryOnNextAddon(_ track: Track) -> Bool {
        guard !track.isLocal, let addonID = playingAs?.addonID else { return false }
        var excluded = failedAddons[track.id] ?? []
        excluded.insert(addonID)
        failedAddons[track.id] = excluded
        resolvedCache[track.id] = nil
        let remaining = addons?.enabled.filter { !excluded.contains($0.id) } ?? []
        guard !remaining.isEmpty else { return false }
        NoticeCenter.shared.show("Trying \(remaining[0].displayName)…", title: "\(addons?.addon(withID: addonID)?.displayName ?? "Addon") couldn't play it")
        loadCurrent(autoplay: true)
        return true
    }

    private func handleFailure(track: Track, error: Error) {
        isLoading = false
        consecutiveFailures += 1
        resolvedCache[track.id] = nil
        NoticeCenter.shared.show(error.localizedDescription, title: "Couldn't play “\(track.title)”", level: .error)
        // Skip ahead, but don't spin forever if everything fails.
        if consecutiveFailures < min(queue.count, 5), let i = currentIndex,
           i + 1 < queue.count || repeatMode == .all {
            let generation = loadGeneration
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard generation == loadGeneration else { return }
                advance(automatic: true)
            }
        } else {
            isPlaying = false
            updateNowPlaying()
        }
    }

    private var nextIndex: Int? {
        guard let i = currentIndex else { return nil }
        if repeatMode == .one { return nil }
        if i + 1 < queue.count { return i + 1 }
        if repeatMode == .all, !queue.isEmpty { return 0 }
        return nil
    }

    private func advance(automatic: Bool) {
        guard let i = currentIndex else { return }
        if automatic, sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            active.player.pause()
            isPlaying = false
            updateNowPlaying()
            return
        }
        if i + 1 < queue.count {
            currentIndex = i + 1
            loadCurrent(autoplay: true)
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            loadCurrent(autoplay: true)
        } else if automatic {
            // Reached the end of the queue.
            active.player.pause()
            active.player.seek(to: .zero)
            currentTime = 0
            isPlaying = false
            updateNowPlaying()
        } else {
            seek(to: max(duration - 0.5, 0))
        }
    }

    private func handleItemEnded(deckIndex: Int) {
        guard deckIndex == activeDeck, !isCrossfading else { return }
        consecutiveFailures = 0
        if repeatMode == .one {
            active.player.seek(to: .zero)
            active.player.playImmediately(atRate: Float(settings.speed))
            return
        }
        if standbyReady, !sleepAtEndOfTrack, let n = nextIndex, standby.queueIndex == n {
            currentIndex = n
            swapToStandby(crossfade: false, autoplay: true)
            return
        }
        advance(automatic: true)
    }

    private func stop() {
        cancelFade()
        for deck in decks { deck.clear() }
        standbyReady = false
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Standby deck (gapless + crossfade)

    private func invalidateStandby() {
        guard !isCrossfading else { return }
        standby.clear()
        standbyReady = false
        preparingStandby = false
    }

    /// Resolves and buffers the next song on the standby deck.
    private func prepareStandbyIfNeeded() {
        guard !standbyReady, !preparingStandby, !sleepAtEndOfTrack,
              settings.gapless || settings.crossfade > 0,
              let n = nextIndex, queue.indices.contains(n) else { return }
        let remaining = duration - currentTime
        guard duration > 0, remaining < max(settings.crossfade + 25, 30) else { return }
        preparingStandby = true
        let track = queue[n]
        let deck = standby
        deck.clear()
        let generation = deck.generation
        Task {
            defer { if deck.generation == generation { preparingStandby = false } }
            guard let resolved = try? await resolve(track), deck.generation == generation else { return }
            let (stream, playable) = resolved
            let item = makeItem(stream)
            await AudioEffects.attach(to: item)
            guard deck.generation == generation, nextIndex == n, queue.indices.contains(n), queue[n].id == track.id else { return }
            deck.track = track
            deck.queueIndex = n
            deck.stream = stream
            deck.player.volume = 0
            deck.player.replaceCurrentItem(with: item)
            deck.player.pause()
            standbyReady = true
            resolvedCache[track.id] = (stream, playable, Date())
        }
    }

    private func swapToStandby(crossfade: Bool, autoplay: Bool) {
        guard let track = standby.track, let index = standby.queueIndex, let item = standby.item else { return }
        let old = active
        activeDeck = 1 - activeDeck
        standbyReady = false
        preparingStandby = false
        currentIndex = index
        loadGeneration += 1
        let generation = loadGeneration

        watch(item, on: active)
        currentStream = active.stream
        playingAs = resolvedCache[track.id]?.playable ?? track
        currentTime = 0
        duration = track.duration ?? item.duration.seconds.nonNaN ?? 0
        isLoading = item.status != .readyToPlay
        isPlaying = autoplay
        nowPlayingArtwork = nil
        library?.recordPlay(track)
        loadArtwork(for: track, generation: generation)

        if autoplay {
            activateSession()
            active.player.playImmediately(atRate: Float(settings.speed))
        }
        if crossfade, autoplay {
            startFade(from: old, to: active, seconds: settings.crossfade)
        } else {
            active.player.volume = 1
            old.clear()
        }
        updateNowPlaying()
    }

    private func startFade(from old: Deck, to new: Deck, seconds: Double) {
        cancelFade()
        isCrossfading = true
        let steps = max(Int(seconds * 20), 1)
        fadeTask = Task { [weak self] in
            for step in 0...steps {
                if Task.isCancelled { break }
                let t = Float(step) / Float(steps)
                // Equal-power curve.
                new.player.volume = sin(t * .pi / 2)
                old.player.volume = cos(t * .pi / 2)
                try? await Task.sleep(for: .milliseconds(50))
            }
            new.player.volume = 1
            old.clear()
            self?.isCrossfading = false
        }
    }

    private func finishCrossfadeNow() {
        guard isCrossfading else { return }
        cancelFade()
        active.player.volume = 1
        standby.clear()
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        if isCrossfading {
            isCrossfading = false
            standby.clear()
        }
    }

    // MARK: Observation

    private func observe(_ deck: Deck, index: Int) {
        deck.timeObserver = deck.player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, index == self.activeDeck else { return }
                self.tick(time)
            }
        }
        let observation = deck.player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self, index == self.activeDeck else { return }
                self.syncTimeControl(status)
            }
        }
        timeControlObservations.append(observation)
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume)
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    self?.isPlaying = false
                    self?.updateNowPlaying()
                case .ended:
                    if shouldResume { self?.resume() }
                @unknown default: break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            MainActor.assumeIsolated {
                // Headphones unplugged: pause like every other player.
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        }
    }

    private func watch(_ item: AVPlayerItem, on deck: Deck) {
        if let endObserver = deck.endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let deckIndex = decks.firstIndex { $0 === deck } ?? 0
        deck.endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleItemEnded(deckIndex: deckIndex) }
        }

        let generation = loadGeneration
        deck.statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription ?? "Unknown error"
            Task { @MainActor in
                guard let self, generation == self.loadGeneration, deckIndex == self.activeDeck else { return }
                if status == .failed, let track = self.currentTrack {
                    if self.retryOnNextAddon(track) { return }
                    self.handleFailure(track: track, error: NSError(
                        domain: "Halo", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                } else if status == .readyToPlay {
                    self.consecutiveFailures = 0
                    self.isLoading = false
                }
            }
        }
    }

    private func tick(_ time: CMTime) {
        let t = time.seconds
        if t.isFinite { currentTime = t }
        lastTickAt = Date()
        if let item = active.item {
            let d = item.duration.seconds
            if d.isFinite, d > 0, abs(d - duration) > 0.5 {
                duration = d
                updateNowPlaying()
            }
        }
        prepareStandbyIfNeeded()

        // Crossfade: start the next song early.
        let fade = settings.crossfade
        if fade > 0, isPlaying, !isCrossfading, standbyReady, !sleepAtEndOfTrack,
           duration > fade * 2 + 5, duration - currentTime <= fade,
           let n = nextIndex, standby.queueIndex == n {
            currentIndex = n
            swapToStandby(crossfade: true, autoplay: true)
        }
    }

    private func syncTimeControl(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            isPlaying = true
            isLoading = false
        case .waitingToPlayAtSpecifiedRate:
            isLoading = true
        case .paused:
            if active.item != nil {
                isLoading = false
                // Covers system-initiated pauses.
                if active.item?.status == .readyToPlay, !isCrossfading { isPlaying = false }
            }
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    // MARK: System integration

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        c.likeCommand.isEnabled = true
        c.likeCommand.localizedTitle = "Like"
        c.likeCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let t = self.currentTrack, let lib = self.library, !lib.isLiked(t) else { return }
                lib.toggleLike(t)
            }
            return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    func updateNowPlaying() {
        guard let t = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isLoading ? settings.speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: settings.speed,
        ]
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        if let i = currentIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = i
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let podcast = contentType != .music
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.isEnabled = podcast
        c.skipBackwardCommand.isEnabled = podcast
    }

    /// Built outside the main actor: MediaPlayer calls this handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

extension Double {
    var nonNaN: Double? { isFinite ? self : nil }
}
