import SwiftUI

/// The glass bar above the tab bar (the tab view's bottom accessory).
struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let track = player.currentTrack
        HStack(spacing: 10) {
            ArtworkView(track: track, size: placement == .inline ? 28 : 36, cornerRadius: 18, pixelSize: 120)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(track?.title ?? "Not Playing")
                    .font(.system(size: 15, weight: .heavy))
                    .lineLimit(1)
                if placement != .inline, let artist = track?.artist {
                    Text(artist)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button { player.togglePlayPause() } label: {
                ZStack {
                    if player.isLoading && player.isPlaying {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(track == nil)
            if placement != .inline {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(track == nil)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if track != nil { player.isNowPlayingPresented = true }
        }
    }
}
