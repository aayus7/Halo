import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

enum PlayerError: LocalizedError {
    case addonMissing
    var errorDescription: String? { "The addon for this track isn't installed or enabled." }
}

/// Owns playback: queue, AVPlayer, lock screen / Control Center, interruptions.
/// Addon streams are resolved lazily — nothing is fetched until a track is about to play,
/// and the next track's stream is prefetched so skips feel instant.
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
    var repeatMode: RepeatMode = .off
    var errorMessage: String?
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

    // MARK: Dependencies

    @ObservationIgnored weak var addons: AddonStore?
    @ObservationIgnored weak var library: LibraryStore?

    // MARK: Internals

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var resolvedCache: [String: (info: StreamInfo, at: Date)] = [:]
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?

    init() {
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
    }

    // MARK: Public controls

    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        originalQueue = tracks
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

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        play(tracks, startAt: Int.random(in: tracks.indices))
    }

    func playNext(_ track: Track) {
        guard let i = currentIndex else { play([track]); return }
        queue.insert(track, at: i + 1)
        originalQueue.append(track)
        prefetchNext()
    }

    func addToQueue(_ track: Track) {
        guard currentIndex != nil else { play([track]); return }
        queue.append(track)
        originalQueue.append(track)
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
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard let i = currentIndex else { return }
        var tail = Array(queue.dropFirst(i + 1))
        tail.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue.prefix(i + 1)) + tail
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentTrack != nil else { return }
        if player.currentItem == nil {
            loadCurrent(autoplay: true)
            return
        }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
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

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
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
        prefetchNext()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: Loading

    private func loadCurrent(autoplay: Bool) {
        guard let track = currentTrack else { stop(); return }
        loadGeneration += 1
        let generation = loadGeneration

        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = track.duration ?? 0
        isLoading = true
        isPlaying = autoplay
        errorMessage = nil
        nowPlayingArtwork = nil
        updateNowPlaying()
        library?.recordPlay(track)

        Task {
            do {
                let stream = try await resolve(track)
                guard generation == loadGeneration else { return }
                let item = makeItem(stream)
                observe(item)
                player.replaceCurrentItem(with: item)
                if autoplay {
                    activateSession()
                    player.play()
                }
                updateNowPlaying()
                prefetchNext()
            } catch {
                guard generation == loadGeneration else { return }
                handleFailure(track: track, error: error)
            }
        }

        Task {
            guard let image = await ArtworkLoader.image(for: track) else { return }
            guard generation == loadGeneration else { return }
            nowPlayingArtwork = Self.makeArtwork(image)
            updateNowPlaying()
        }
    }

    private func resolve(_ track: Track) async throws -> StreamInfo {
        switch track.source {
        case .local(let fileName):
            return StreamInfo(url: Paths.music.appendingPathComponent(fileName), headers: nil)
        case .addon(let addonID, let trackID):
            if let direct = track.directStreamURL {
                return StreamInfo(url: direct, headers: nil)
            }
            if let cached = resolvedCache[track.id], Date().timeIntervalSince(cached.at) < 600 {
                return cached.info
            }
            guard let addon = addons?.addon(withID: addonID), addon.enabled else {
                throw PlayerError.addonMissing
            }
            let info = try await AddonClient.resolveStream(addon, trackID: trackID)
            resolvedCache[track.id] = (info, Date())
            return info
        }
    }

    private func prefetchNext() {
        guard let i = currentIndex, queue.indices.contains(i + 1) else { return }
        let nextTrack = queue[i + 1]
        guard !nextTrack.isLocal, nextTrack.directStreamURL == nil, resolvedCache[nextTrack.id] == nil else { return }
        Task { _ = try? await resolve(nextTrack) }
    }

    private func makeItem(_ stream: StreamInfo) -> AVPlayerItem {
        var options: [String: Any] = [:]
        if let headers = stream.headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: stream.url, options: options)
        return AVPlayerItem(asset: asset)
    }

    private func handleFailure(track: Track, error: Error) {
        isLoading = false
        consecutiveFailures += 1
        resolvedCache[track.id] = nil
        errorMessage = "Couldn't play “\(track.title)”: \(error.localizedDescription)"
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

    private func advance(automatic: Bool) {
        guard let i = currentIndex else { return }
        if i + 1 < queue.count {
            currentIndex = i + 1
            loadCurrent(autoplay: true)
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            loadCurrent(autoplay: true)
        } else if automatic {
            // Reached the end of the queue.
            player.pause()
            player.seek(to: .zero)
            currentTime = 0
            isPlaying = false
            updateNowPlaying()
        }
    }

    private func handleItemEnded() {
        consecutiveFailures = 0
        if repeatMode == .one {
            player.seek(to: .zero)
            player.play()
            return
        }
        advance(automatic: true)
    }

    private func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Observation

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.syncTimeControl(status) }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume)
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.isPlaying = false; self?.updateNowPlaying()
                case .ended: if shouldResume { self?.resume() }
                @unknown default: break
                }
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleItemEnded() }
        }

        let generation = loadGeneration
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription ?? "Unknown error"
            Task { @MainActor in
                guard let self, generation == self.loadGeneration else { return }
                if status == .failed, let track = self.currentTrack {
                    self.handleFailure(track: track, error: NSError(
                        domain: "Halo", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                } else if status == .readyToPlay {
                    self.consecutiveFailures = 0
                }
            }
        }
    }

    private func tick(_ time: CMTime) {
        let t = time.seconds
        if t.isFinite { currentTime = t }
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0, abs(d - duration) > 0.5 {
                duration = d
                updateNowPlaying()
            }
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
            if player.currentItem != nil {
                isLoading = false
                // Covers system-initiated pauses, e.g. headphones unplugged.
                if player.currentItem?.status == .readyToPlay { isPlaying = false }
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
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        guard let t = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isLoading ? 1.0 : 0.0,
        ]
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: MediaPlayer calls this handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
