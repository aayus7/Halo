import AVKit
import SwiftUI

struct ArtworkView: View {
    let track: Track?
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: track?.id) {
                image = nil
                guard let track else { return }
                image = await ArtworkLoader.image(for: track)
            }
    }

    private var placeholder: some View {
        let seed = (track?.title ?? "").unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hue = Double(seed % 360) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.45),
                     Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.25)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: (size ?? 200) * 0.35, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct TrackRow: View {
    let track: Track
    var onDelete: (() -> Void)? = nil

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, size: 48, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : Color.primary)
                    .lineLimit(1)
                Text(track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if library.isLiked(track) {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.like)
            }
            if let d = track.duration {
                Text(formatTime(d))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { TrackMenuItems(track: track, onDelete: onDelete) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { player.playNext(track) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(Theme.accent)
            Button { player.addToQueue(track) } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { library.toggleLike(track) } label: {
                Label("Like", systemImage: library.isLiked(track) ? "heart.slash" : "heart")
            }
            .tint(Theme.like)
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

struct TrackMenuItems: View {
    let track: Track
    var onDelete: (() -> Void)? = nil

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button { player.playNext(track) } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button { player.addToQueue(track) } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        Button { library.toggleLike(track) } label: {
            Label(library.isLiked(track) ? "Remove from Liked" : "Like",
                  systemImage: library.isLiked(track) ? "heart.slash" : "heart")
        }
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete from iPhone", systemImage: "trash")
            }
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
