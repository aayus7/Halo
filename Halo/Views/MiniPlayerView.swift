import SwiftUI

struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 42, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { player.togglePlayPause() } label: {
                    ZStack {
                        if player.isLoading && player.isPlaying {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 36, height: 40)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: geo.size.width * player.progress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { player.isNowPlayingPresented = true }
        }
    }
}
