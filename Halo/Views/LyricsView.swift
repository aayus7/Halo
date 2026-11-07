import SwiftUI

/// Apple Music-style lyrics: heavy type, the sung line lit word by word, the others dimmed and blurred.
struct LyricsView: View {
    let lyrics: Lyrics
    var uppercase = false
    var fontSize: CGFloat = 34

    @Environment(PlayerEngine.self) private var player
    @State private var userScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        let active = lyrics.index(at: player.currentTime + 0.15)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    Color.clear.frame(height: 40)
                    ForEach(lyrics.lines) { line in
                        lineView(line, active: active)
                            .id(line.id)
                            .onTapGesture {
                                guard lyrics.kind == .synced else { return }
                                player.seek(to: line.start)
                                if !player.isPlaying { player.resume() }
                                userScrolling = false
                            }
                    }
                    Color.clear.frame(height: 320)
                }
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    userScrolling = true
                    resumeTask?.cancel()
                } else if phase == .idle, userScrolling {
                    resumeTask?.cancel()
                    resumeTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        userScrolling = false
                    }
                }
            }
            .onChange(of: active) { _, new in
                guard let new, !userScrolling else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                    proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.22))
                }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.22)) }
            }
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                       .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine, active: Int?) -> some View {
        let distance = active.map { abs(line.id - $0) } ?? 0
        let isActive = lyrics.kind == .synced && line.id == active
        let isPast = active.map { line.id < $0 } ?? false
        Group {
            if line.isInstrumentalBreak {
                InstrumentalDots(line: line, isActive: isActive)
            } else if isActive {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { context in
                    let t = player.time(at: context.date)
                    sungText(line, at: t)
                }
            } else {
                Text(display(line.text))
                    .font(.black(fontSize))
                    .foregroundStyle(.white.opacity(lyrics.kind == .plain ? 0.9 : (isPast ? 0.3 : 0.35)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .blur(radius: (lyrics.kind == .synced && !isActive && !userScrolling) ? min(CGFloat(distance) * 1.6, 5) : 0)
        .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isActive)
        .animation(.easeOut(duration: 0.3), value: userScrolling)
    }

    /// Each word brightens as it's sung, with a soft glow on the current one.
    private func sungText(_ line: LyricLine, at time: Double) -> some View {
        var text = Text("")
        for word in line.words {
            let progress = word.end > word.start ? min(max((time - word.start) / (word.end - word.start), 0), 1) : (time >= word.start ? 1 : 0)
            let opacity = 0.35 + 0.65 * progress
            text = text + Text(display(word.text)).foregroundColor(.white.opacity(opacity))
        }
        if line.words.isEmpty { text = Text(display(line.text)).foregroundColor(.white) }
        return text
            .font(.black(fontSize))
            .shadow(color: .white.opacity(0.35), radius: 10)
    }

    private func display(_ s: String) -> String { uppercase ? s.uppercased() : s }
}

/// Three dots that fill over an instrumental break.
private struct InstrumentalDots: View {
    let line: LyricLine
    let isActive: Bool
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive || !player.isPlaying)) { context in
            let t = player.time(at: context.date)
            let progress = isActive ? min(max((t - line.start) / max(line.end - line.start, 0.1), 0), 1) : 0
            let breathe = isActive ? 1 + 0.08 * sin(context.date.timeIntervalSinceReferenceDate * 3) : 1
            HStack(spacing: 10) {
                ForEach(0..<3) { i in
                    let fill = min(max(progress * 3 - Double(i), 0), 1)
                    Circle()
                        .fill(.white.opacity(0.3 + 0.7 * fill))
                        .frame(width: 14, height: 14)
                }
            }
            .scaleEffect(breathe, anchor: .leading)
            .padding(.vertical, 8)
        }
        .opacity(isActive ? 1 : 0.4)
    }
}

/// Loads lyrics for a track and shows them, or a friendly empty state.
struct LyricsPanel: View {
    let track: Track
    @Environment(AppSettings.self) private var settings
    @State private var lyrics: Lyrics?
    @State private var loading = true

    var body: some View {
        Group {
            if let lyrics {
                VStack(alignment: .leading, spacing: 0) {
                    LyricsView(lyrics: lyrics, uppercase: settings.lyricsUppercase)
                    Text("Lyrics from \(lyrics.source)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                }
            } else if loading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble").font(.largeTitle)
                    Text("No lyrics for this song").font(.headline)
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: track.id) {
            loading = true
            lyrics = nil
            let found = await LyricsService.shared.lyrics(for: track)
            guard !Task.isCancelled else { return }
            lyrics = found
            loading = false
        }
    }
}
