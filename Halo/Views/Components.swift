import AVKit
import SwiftUI

// MARK: - Navigation

enum Route: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(RemotePlaylist)
    case userPlaylist(String)
    case liked
    case history
    case spotifyLiked
    case local
    case settings
    case addons
}

extension View {
    func haloDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let a): CollectionView(source: .album(a))
            case .artist(let a): ArtistView(artist: a)
            case .playlist(let p): CollectionView(source: .remotePlaylist(p))
            case .userPlaylist(let id): CollectionView(source: .userPlaylist(id))
            case .liked: CollectionView(source: .liked)
            case .history: CollectionView(source: .history)
            case .spotifyLiked: CollectionView(source: .spotifyLiked)
            case .local: CollectionView(source: .local)
            case .settings: SettingsView()
            case .addons: AddonsView()
            }
        }
    }
}

// MARK: - Artwork

struct ArtworkView: View {
    let track: Track?
    var url: URL? = nil
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = Theme.artworkRadius
    var pixelSize: Int = 600
    var onImage: ((UIImage) -> Void)? = nil

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
                        .transition(.opacity)
                } else {
                    ArtworkPlaceholder(seed: track?.title ?? url?.absoluteString ?? "", size: size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: (track?.id ?? "") + (url?.absoluteString ?? "")) {
                image = nil
                let hiRes = AppSettings.shared.hiResArtwork
                let loaded: UIImage?
                if let track {
                    loaded = await ArtworkLoader.image(for: track, hiRes: hiRes, size: pixelSize)
                } else {
                    loaded = await ArtworkLoader.image(at: url)
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                if let loaded { onImage?(loaded) }
            }
    }
}

struct ArtworkPlaceholder: View {
    let seed: String
    var size: CGFloat?

    var body: some View {
        let value = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hue = Double(abs(value) % 360) / 360
        LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.45),
                     Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.22)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: max(12, (size ?? 160) * 0.32), weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// An HLS motion cover, muted and looping, drawn over the static artwork.
struct MotionArtworkView: UIViewRepresentable {
    let url: URL

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var url: URL?
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .clear
        configure(view)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.url != url { configure(view) }
    }

    private func configure(_ view: PlayerView) {
        view.player?.pause()
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = 6_000_000
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        view.looper = AVPlayerLooper(player: player, templateItem: item)
        view.player = player
        view.url = url
        view.playerLayer.player = player
        player.play()
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.player?.pause()
        view.looper = nil
        view.player = nil
    }
}

// MARK: - Rows

struct TrackRow: View {
    let track: Track
    var index: Int? = nil
    var showArtwork = true
    var onDelete: (() -> Void)? = nil

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 14) {
            if let index, !showArtwork {
                Text("\(index)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            if showArtwork {
                ArtworkView(track: track, size: 54, cornerRadius: 6, pixelSize: 200)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isCurrent ? Theme.accent : Color.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if track.explicit == true {
                        Image(systemName: "e.square.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(track.artist)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if library.isLiked(track) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.like)
            }
            Menu {
                TrackMenuItems(track: track, onDelete: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
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
    }
}

struct TrackMenuItems: View {
    let track: Track
    var onDelete: (() -> Void)? = nil

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var nav

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
        Menu {
            Button {
                library.createPlaylist(track.title, tracks: [track])
            } label: {
                Label("New Playlist", systemImage: "plus")
            }
            ForEach(library.playlists) { p in
                Button(p.name) { library.add([track], to: p.id) }
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        if let album = albumRoute {
            Button { nav.open(album) } label: { Label("Go to Album", systemImage: "square.stack") }
        }
        if let artist = artistRoute {
            Button { nav.open(artist) } label: { Label("Go to Artist", systemImage: "music.microphone") }
        }
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete from iPhone", systemImage: "trash")
            }
        }
    }

    private var sourceID: String? {
        switch track.source {
        case .addon(let id, _): return id
        case .catalog(let service, _): return service
        case .local: return nil
        }
    }

    private var albumRoute: Route? {
        guard let source = sourceID, let id = track.albumID else { return nil }
        return .album(Album(addonID: source, albumID: id, title: track.album ?? "Album", artist: track.artist,
                            artworkURL: track.artworkURL))
    }

    private var artistRoute: Route? {
        guard let source = sourceID, let id = track.artistID else { return nil }
        return .artist(Artist(addonID: source, artistID: id, name: track.artist.components(separatedBy: ",").first ?? track.artist))
    }
}

// MARK: - Cards

/// A square cover with a title and subtitle under it.
struct CoverCard: View {
    let title: String
    var subtitle: String?
    var url: URL?
    var track: Track?
    var size: CGFloat = 156
    var circle = false

    var body: some View {
        VStack(alignment: circle ? .center : .leading, spacing: 7) {
            ArtworkView(track: track, url: url, size: size, cornerRadius: circle ? size / 2 : Theme.artworkRadius, pixelSize: 400)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: circle ? .center : .leading)
    }
}

/// The big carousel card from the top of Home: artwork on a tinted block, title and subtitle below.
struct HeroCard: View {
    let title: String
    var subtitle: String?
    var url: URL?
    var track: Track?
    var width: CGFloat = 300

    @State private var palette = Palette.fallback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(track: track, url: url, size: width, cornerRadius: 0, pixelSize: 700) { image in
                let key = track?.id ?? url?.absoluteString ?? title
                let p = PaletteExtractor.palette(for: image, key: key)
                withAnimation(.easeOut(duration: 0.3)) { palette = p }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.heavy(20)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: 86, alignment: .topLeading)
            .background(palette.primary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The 2-column shortcut tile: small cover + bold title on a tint from the cover.
struct ShortcutTile: View {
    let title: String
    var url: URL?
    var track: Track?
    var systemImage: String?
    var gradient: [Color]?

    @State private var palette = Palette.fallback

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let systemImage {
                    ZStack {
                        LinearGradient(colors: gradient ?? [Theme.accent, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: systemImage).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    }
                } else {
                    ArtworkView(track: track, url: url, size: 54, cornerRadius: 8, pixelSize: 200) { image in
                        let p = PaletteExtractor.palette(for: image, key: track?.id ?? url?.absoluteString ?? title)
                        palette = p
                    }
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
        }
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: tint.opacity(0.25))
    }

    private var tint: Color {
        if systemImage != nil, let first = gradient?.first { return first.opacity(0.7) }
        return palette.primary
    }
}

/// A horizontally scrolling shelf with a heading.
struct Shelf<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content()
                }
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
        }
    }
}

/// Shelf of tracks that play in order from the tapped one.
struct TrackShelf: View {
    let title: String
    var subtitle: String? = nil
    let tracks: [Track]

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Shelf(title: title, subtitle: subtitle) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button { player.play(tracks, startAt: index, title: title) } label: {
                    CoverCard(title: track.title, subtitle: track.artist, track: track)
                }
                .buttonStyle(.plain)
                .contextMenu { TrackMenuItems(track: track) }
            }
        }
    }
}

struct AlbumShelf: View {
    let title: String
    let albums: [Album]

    var body: some View {
        Shelf(title: title) {
            ForEach(albums) { album in
                NavigationLink(value: Route.album(album)) {
                    CoverCard(title: album.title, subtitle: [album.artist, album.year ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                              url: album.artworkURL)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct PlaylistShelf: View {
    let title: String
    let playlists: [RemotePlaylist]

    var body: some View {
        Shelf(title: title) {
            ForEach(playlists) { p in
                NavigationLink(value: Route.playlist(p)) {
                    CoverCard(title: p.title, subtitle: p.creator, url: p.artworkURL)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ArtistShelf: View {
    let title: String
    let artists: [Artist]

    var body: some View {
        Shelf(title: title) {
            ForEach(artists) { a in
                NavigationLink(value: Route.artist(a)) {
                    CoverCard(title: a.name, subtitle: a.genres.first?.capitalized, url: a.artworkURL, size: 130, circle: true)
                }
                .buttonStyle(.plain)
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
