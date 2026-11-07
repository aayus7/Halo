import SwiftUI

struct NowPlayingView: View {
    enum Mode { case artwork, lyrics, queue }

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(NavigationModel.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .artwork
    @State private var palette = Palette.fallback
    @State private var motionURL: URL?
    @State private var showEffects = false
    @State private var artwork: UIImage?
    @State private var backdrop: UIImage?
    @State private var drift = false

    var body: some View {
        let track = player.currentTrack
        GeometryReader { geo in
            ZStack(alignment: .top) {
                background(track, width: geo.size.width)

                VStack(spacing: 0) {
                    Capsule().fill(.white.opacity(0.45)).frame(width: 40, height: 5)
                        .padding(.top, 8)
                        .padding(.bottom, 6)

                    switch mode {
                    case .artwork:
                        Spacer(minLength: 0)
                    case .lyrics:
                        compactHeader(track)
                        if let track { LyricsPanel(track: track) } else { Spacer() }
                    case .queue:
                        compactHeader(track)
                        QueuePanel()
                    }

                    if mode == .artwork { titleRow(track).padding(.horizontal, 24) }
                    Scrubber()
                        .padding(.horizontal, 24)
                        .padding(.top, mode == .artwork ? 18 : 8)
                    controls
                        .padding(.horizontal, 24)
                        .padding(.top, 22)
                    bottomBar
                        .padding(.horizontal, 44)
                        .padding(.top, 28)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 12))
                }
                .padding(.top, geo.safeAreaInsets.top)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showEffects) { SoundSheet() }
        .task(id: track?.id) { await loadArtwork(track) }
        .task(id: track?.id) { await loadMotion(track) }
        .onAppear {
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    // MARK: Background

    /// The artwork at the top, melting into a blurred, colour-rich copy of itself that fills the screen.
    @ViewBuilder
    private func background(_ track: Track?, width: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black
                if let backdrop {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(drift ? 1.45 : 1.25)
                        .offset(x: drift ? 24 : -24, y: drift ? -30 : 20)
                        .rotationEffect(.degrees(drift ? 4 : -4))
                        .clipped()
                        .transition(.opacity)
                } else {
                    LinearGradient(colors: [palette.primary, palette.secondary, .black], startPoint: .top, endPoint: .bottom)
                }
                // Keep the controls readable.
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.25), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)

                ZStack {
                    if let artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        ArtworkPlaceholder(seed: track?.title ?? "", size: width)
                    }
                    if let motionURL {
                        MotionArtworkView(url: motionURL).transition(.opacity)
                    }
                }
                .frame(width: width, height: width)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .opacity(mode == .artwork ? 1 : 0)
                .scaleEffect(mode == .artwork ? 1 : 1.08, anchor: .top)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: mode)
        .animation(.easeInOut(duration: 0.6), value: backdrop)
        .ignoresSafeArea()
    }

    private func loadArtwork(_ track: Track?) async {
        guard let track else { return }
        guard let image = await ArtworkLoader.image(for: track, hiRes: settings.hiResArtwork, size: 1400),
              !Task.isCancelled else { return }
        artwork = image
        let p = PaletteExtractor.palette(for: image, key: track.id)
        withAnimation(.easeInOut(duration: 0.6)) { palette = p }
        let blurred = await Task.detached(priority: .userInitiated) { Backdrop.make(from: image) }.value
        guard !Task.isCancelled, player.currentTrack?.id == track.id else { return }
        backdrop = blurred
    }

    // MARK: Pieces

    private func titleRow(_ track: Track?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Not Playing")
                    .font(.black(30))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(track?.artist ?? " ")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let track { trackButtons(track) }
        }
    }

    private func compactHeader(_ track: Track?) -> some View {
        HStack(spacing: 14) {
            ArtworkView(track: track, size: 64, cornerRadius: 10, pixelSize: 200)
                .onTapGesture { withAnimation { mode = .artwork } }
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "").font(.black(22)).lineLimit(1)
                Text(track?.artist ?? "").font(.system(size: 16, weight: .bold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let track { trackButtons(track) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func trackButtons(_ track: Track) -> some View {
        HStack(spacing: 4) {
            Button {
                // "Not for me": drop it from the queue and move on.
                player.next()
            } label: {
                Image(systemName: "xmark").font(.system(size: 22, weight: .semibold)).frame(width: 40, height: 40)
            }
            let liked = library.isLiked(track)
            Button { library.toggleLike(track) } label: {
                Image(systemName: liked ? "star.fill" : "star")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(liked ? Color.yellow : Color.white)
                    .symbolEffect(.bounce, value: liked)
                    .frame(width: 40, height: 40)
            }
            Menu {
                moreMenu(track)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).frame(width: 40, height: 40)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func moreMenu(_ track: Track) -> some View {
        TrackMenuItems(track: track)
        Divider()
        Menu {
            ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0], id: \.self) { s in
                Button {
                    settings.speed = s
                    player.applySoundSettings()
                } label: {
                    if abs(settings.speed - s) < 0.01 { Label(String(format: "%gx", s), systemImage: "checkmark") } else { Text(String(format: "%gx", s)) }
                }
            }
        } label: {
            Label("Speed (\(String(format: "%gx", settings.speed)))", systemImage: "gauge.with.needle")
        }
        Menu {
            if player.sleepTimerEnd != nil || player.sleepAtEndOfTrack {
                Button(role: .destructive) { player.cancelSleepTimer() } label: { Label("Turn Off", systemImage: "moon.zzz") }
            }
            Button("End of Track") { player.sleepAfterCurrentTrack() }
            ForEach([5, 15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
            }
        } label: {
            Label(sleepLabel, systemImage: "moon")
        }
        Button { showEffects = true } label: { Label("Sound & EQ", systemImage: "slider.vertical.3") }
        if let info = player.currentStream?.summary, !info.isEmpty {
            Section("Stream") { Text(info) }
        }
    }

    private var sleepLabel: String {
        if player.sleepAtEndOfTrack { return "Sleep: end of track" }
        if let end = player.sleepTimerEnd {
            let mins = max(1, Int(end.timeIntervalSinceNow / 60))
            return "Sleep: \(mins) min left"
        }
        return "Sleep Timer"
    }

    private var controls: some View {
        HStack {
            if player.contentType == .music {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(player.shuffleEnabled ? Theme.accent : .white.opacity(0.45))
                }
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 38))
                }
            } else {
                Spacer()
                Button { player.skip(by: player.contentType == .podcast ? -15 : -30) } label: {
                    Image(systemName: player.contentType == .podcast ? "gobackward.15" : "gobackward.30").font(.system(size: 34, weight: .semibold))
                }
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                ZStack {
                    if player.isLoading && player.isPlaying {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 50))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 70, height: 70)
            }
            Spacer()
            if player.contentType == .music {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 38))
                }
                Spacer()
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.45) : Theme.accent)
                }
            } else {
                Button { player.skip(by: player.contentType == .podcast ? 15 : 30) } label: {
                    Image(systemName: player.contentType == .podcast ? "goforward.15" : "goforward.30").font(.system(size: 34, weight: .semibold))
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack {
            Button { withAnimation(.spring(duration: 0.45)) { mode = mode == .lyrics ? .artwork : .lyrics } } label: {
                Image(systemName: mode == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(mode == .lyrics ? Color.white : .white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            .disabled(!settings.lyricsEnabled)
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
            Spacer()
            Button { withAnimation(.spring(duration: 0.45)) { mode = mode == .queue ? .artwork : .queue } } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(mode == .queue ? Color.white : .white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadMotion(_ track: Track?) async {
        withAnimation { motionURL = nil }
        guard let track, settings.animatedArtwork, !settings.appleMusicToken.isEmpty else { return }
        let url = await ArtworkService.shared.motionURL(for: track, token: settings.appleMusicToken,
                                                       storefront: settings.storefront)
        guard !Task.isCancelled, player.currentTrack?.id == track.id else { return }
        withAnimation(.easeIn(duration: 0.6)) { motionURL = url }
    }
}

/// Thin progress bar like the Music app; grows while you drag.
struct Scrubber: View {
    @Environment(PlayerEngine.self) private var player
    @State private var dragging: Double?

    var body: some View {
        let duration = max(player.duration, 0.01)
        let shown = dragging ?? player.currentTime
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let fraction = min(max(shown / duration, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white).frame(width: max(w * fraction, 6))
                }
                .frame(height: dragging == nil ? 6 : 11)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in dragging = min(max(v.location.x / w, 0), 1) * duration }
                        .onEnded { v in
                            let target = min(max(v.location.x / w, 0), 1) * duration
                            player.seek(to: target)
                            dragging = nil
                        }
                )
                .animation(.spring(duration: 0.25), value: dragging == nil)
            }
            .frame(height: 20)
            HStack {
                Text(formatTime(shown))
                Spacer()
                if let chapter = player.currentChapter {
                    Text(chapter.title).lineLimit(1)
                } else {
                    QualityBadgeButton()
                }
                Spacer()
                Text("-" + formatTime(max(player.duration - shown, 0)))
            }
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct QueuePanel: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Up Next").font(.heavy(20))
                    if let title = player.queueTitle {
                        Text("Playing from \(title)").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer()
                if !player.upNext.isEmpty {
                    Button("Clear") { player.clearUpNext() }
                        .font(.subheadline.weight(.bold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            if player.upNext.isEmpty {
                Text("Nothing queued. Swipe right on a song to add it.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 20)
                Spacer()
            } else {
                List {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 12) {
                            ArtworkView(track: track, size: 46, cornerRadius: 6, pixelSize: 150)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                                Text(track.artist).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.jumpToUpNext(index) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                    }
                    .onDelete { player.removeFromUpNext(at: $0) }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}
