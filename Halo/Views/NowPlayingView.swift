import SwiftUI

struct NowPlayingView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showQueue = false

    private var displayedTime: Double { isScrubbing ? scrubTime : player.currentTime }

    var body: some View {
        let track = player.currentTrack
        ZStack {
            background(track)

            VStack(spacing: 22) {
                Spacer(minLength: 12)

                if showQueue {
                    QueueView()
                        .transition(.opacity)
                } else {
                    ArtworkView(track: track, cornerRadius: 18)
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                        .scaleEffect(player.isPlaying ? 1 : 0.86)
                        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
                        .transition(.opacity)
                }

                Spacer(minLength: 12)

                titleRow(track)
                scrubber
                controls
                bottomBar
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: Pieces

    private func background(_ track: Track?) -> some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 1.2
            ZStack {
                Color.black
                ArtworkView(track: track, size: side, cornerRadius: 0)
                    .blur(radius: 70)
                    .opacity(0.8)
                    .frame(width: geo.size.width, height: geo.size.height)
                Color.black.opacity(0.3)
            }
            .clipped()
        }
        .ignoresSafeArea()
    }

    private func titleRow(_ track: Track?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track?.title ?? "Not Playing")
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(track?.artist ?? " ")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let track {
                let liked = library.isLiked(track)
                Button { library.toggleLike(track) } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(liked ? Theme.like : Color.white)
                        .symbolEffect(.bounce, value: liked)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(displayedTime, max(player.duration, 1)) },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubTime = player.currentTime
                        isScrubbing = true
                    } else {
                        player.seek(to: scrubTime)
                        isScrubbing = false
                    }
                }
            )
            .tint(.white)
            HStack {
                Text(formatTime(displayedTime))
                Spacer()
                Text("-" + formatTime(max(player.duration - displayedTime, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.shuffleEnabled ? Theme.accent : Color.secondary)
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 74, height: 74)
                    if player.isLoading && player.isPlaying {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.black)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Theme.accent)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack {
            AirPlayButton().frame(width: 36, height: 36)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showQueue.toggle() }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(showQueue ? Theme.accent : Color.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct QueueView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next").font(.headline)
            if player.upNext.isEmpty {
                Text("Nothing queued. Swipe right on a song to add it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 10) {
                            ArtworkView(track: track, size: 40, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).font(.subheadline).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.jumpToUpNext(index) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }
                    .onDelete { player.removeFromUpNext(at: $0) }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
