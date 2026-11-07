import SwiftUI

/// Album, playlist, liked songs, history, local files: one page, the Music app's layout.
struct CollectionView: View {
    enum Source: Hashable {
        case album(Album)
        case remotePlaylist(RemotePlaylist)
        case userPlaylist(String)
        case liked
        case history
        case spotifyLiked
        case local
    }

    let source: Source

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AddonStore.self) private var addons
    @Environment(SpotifyService.self) private var spotify

    @State private var loadedTracks: [Track] = []
    @State private var loadedAlbum: Album?
    @State private var loadedPlaylist: RemotePlaylist?
    @State private var isLoading = false
    @State private var error: String?
    @State private var palette = Palette.fallback
    @State private var showImporter = false

    var body: some View {
        let tracks = self.tracks
        ScrollView {
            VStack(spacing: 0) {
                header(tracks)
                if isLoading && tracks.isEmpty {
                    ProgressView().padding(.top, 40)
                } else if let error, tracks.isEmpty {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if tracks.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "music.note.list")
                        .padding(.top, 20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            VStack(spacing: 0) {
                                TrackRow(track: track, index: index + 1, showArtwork: !isAlbum,
                                         onDelete: deleteAction(for: track, at: index))
                                    .padding(.vertical, 8)
                                    .onTapGesture { player.play(tracks, startAt: index, title: title) }
                                Divider().opacity(0.4)
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    footer(tracks)
                }
            }
            .padding(.bottom, 40)
        }
        .background {
            ZStack(alignment: .top) {
                Color.black
                LinearGradient(colors: [palette.primary, palette.primary.opacity(0.7), palette.secondary.opacity(0.6), .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 900)
            }
            .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .userPlaylist(let id) = source {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { library.deletePlaylist(id) } label: { Label("Delete Playlist", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            if case .local = source {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
        .task { await load() }
    }

    // MARK: Data

    private var isAlbum: Bool {
        if case .album = source { return true }
        return false
    }

    private var tracks: [Track] {
        switch source {
        case .userPlaylist(let id): return library.playlist(id)?.tracks ?? []
        case .liked: return library.liked
        case .history: return library.history
        case .local: return library.localTracks
        default: return loadedTracks
        }
    }

    private var title: String {
        switch source {
        case .album(let a): return loadedAlbum?.title ?? a.title
        case .remotePlaylist(let p): return loadedPlaylist?.title ?? p.title
        case .userPlaylist(let id): return library.playlist(id)?.name ?? "Playlist"
        case .liked: return "Liked Songs"
        case .history: return "Recently Played"
        case .spotifyLiked: return "Liked Songs"
        case .local: return "On This iPhone"
        }
    }

    private var subtitle: String {
        switch source {
        case .album(let a):
            let album = loadedAlbum ?? a
            return [album.artist, album.year ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .remotePlaylist(let p): return (loadedPlaylist ?? p).creator ?? ""
        case .userPlaylist: return "Your playlist"
        case .liked: return "Liked in Halo"
        case .history: return "Your listening"
        case .spotifyLiked: return "From Spotify"
        case .local: return "Files in Halo's Music folder"
        }
    }

    private var coverURL: URL? {
        switch source {
        case .album(let a): return loadedAlbum?.artworkURL ?? a.artworkURL
        case .remotePlaylist(let p): return loadedPlaylist?.artworkURL ?? p.artworkURL
        default: return nil
        }
    }

    private var coverIcon: String? {
        switch source {
        case .liked, .spotifyLiked: return "heart.fill"
        case .history: return "clock.fill"
        case .local: return "iphone"
        default: return nil
        }
    }

    private func load() async {
        guard loadedTracks.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch source {
            case .album(let a):
                if a.addonID == SpotifyService.sourceID {
                    loadedTracks = try await spotify.albumTracks(a)
                } else if let ctx = addons.context(forID: a.addonID) {
                    let (album, tracks) = try await AddonClient.album(ctx, id: a.albumID)
                    loadedAlbum = album
                    loadedTracks = tracks
                } else {
                    error = "The addon for this album isn't enabled."
                }
            case .remotePlaylist(let p):
                if p.addonID == SpotifyService.sourceID {
                    loadedTracks = try await spotify.playlistTracks(p.playlistID)
                } else if let ctx = addons.context(forID: p.addonID) {
                    let (playlist, tracks) = try await AddonClient.playlist(ctx, id: p.playlistID)
                    loadedPlaylist = playlist
                    loadedTracks = tracks
                } else {
                    error = "The addon for this playlist isn't enabled."
                }
            case .spotifyLiked:
                loadedTracks = spotify.home.liked
                loadedTracks = try await spotify.likedTracks()
            default:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteAction(for track: Track, at index: Int) -> (() -> Void)? {
        switch source {
        case .local: return { library.deleteLocal(track) }
        case .userPlaylist(let id): return { library.remove(at: IndexSet(integer: index), from: id) }
        default: return nil
        }
    }

    // MARK: Header

    private func header(_ tracks: [Track]) -> some View {
        VStack(spacing: 14) {
            Group {
                if let icon = coverIcon {
                    ZStack {
                        LinearGradient(colors: [Color(red: 0.36, green: 0.25, blue: 0.95), Color(red: 0.55, green: 0.75, blue: 0.95)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: icon).font(.system(size: 80, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 250, height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onAppear { palette = Palette(primary: Color(red: 0.3, green: 0.22, blue: 0.62), secondary: Color(red: 0.15, green: 0.1, blue: 0.3), isLight: false) }
                } else {
                    ArtworkView(track: coverURL == nil ? tracks.first : nil, url: coverURL, size: 260, cornerRadius: 14, pixelSize: 900) { image in
                        let p = PaletteExtractor.palette(for: image, key: coverURL?.absoluteString ?? tracks.first?.id ?? title)
                        withAnimation(.easeOut(duration: 0.4)) { palette = p }
                    }
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
            .padding(.top, 20)

            VStack(spacing: 4) {
                Text(title).font(.heavy(26)).multilineTextAlignment(.center).lineLimit(2)
                Text(subtitleLine(tracks))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            PlayControlsRow(
                onShuffle: { player.playShuffled(tracks, title: title) },
                onPlay: {
                    if !tracks.isEmpty { player.play(tracks, startAt: 0, title: title) }
                },
                onAdd: canSave ? { saveAsPlaylist(tracks) } : nil
            )
            .disabled(tracks.isEmpty)
            .padding(.vertical, 6)

            if let artists = featuring(tracks) {
                Text(artists)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 12)
    }

    private func subtitleLine(_ tracks: [Track]) -> String {
        var parts = [subtitle].filter { !$0.isEmpty }
        if !tracks.isEmpty {
            parts.append("\(tracks.count) songs")
            let total = tracks.compactMap(\.duration).reduce(0, +)
            if total > 0 {
                let h = Int(total) / 3600, m = (Int(total) % 3600) / 60
                parts.append(h > 0 ? "\(h)h \(m)m" : "\(m) min")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func featuring(_ tracks: [Track]) -> String? {
        guard !isAlbum, tracks.count > 3 else { return nil }
        var counts: [String: Int] = [:]
        for t in tracks { for a in t.artist.components(separatedBy: ", ") { counts[a, default: 0] += 1 } }
        let top = counts.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        guard top.count >= 2 else { return nil }
        return "With " + top.joined(separator: ", ") + " and more"
    }

    private var canSave: Bool {
        switch source {
        case .album, .remotePlaylist, .spotifyLiked, .history: return true
        default: return false
        }
    }

    private func saveAsPlaylist(_ tracks: [Track]) {
        library.createPlaylist(title, tracks: tracks)
        NoticeCenter.shared.show("Saved “\(title)” to your playlists.", level: .success)
    }

    @ViewBuilder
    private func footer(_ tracks: [Track]) -> some View {
        if let description = loadedAlbum?.description ?? loadedPlaylist?.description, !description.isEmpty {
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ArtistView: View {
    let artist: Artist

    @Environment(PlayerEngine.self) private var player
    @Environment(AddonStore.self) private var addons
    @Environment(SpotifyService.self) private var spotify

    @State private var info: Artist?
    @State private var top: [Track] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var palette = Palette.fallback

    var body: some View {
        let shown = info ?? artist
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GeometryReader { geo in
                    let minY = geo.frame(in: .scrollView).minY
                    ZStack(alignment: .bottomLeading) {
                        ArtworkView(track: nil, url: shown.artworkURL, size: geo.size.width, cornerRadius: 0, pixelSize: 1000) { image in
                            palette = PaletteExtractor.palette(for: image, key: shown.artworkURL?.absoluteString ?? shown.id)
                        }
                        .frame(width: geo.size.width, height: geo.size.height + max(minY, 0))
                        .clipped()
                        .offset(y: -max(minY, 0))
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                        Text(shown.name)
                            .font(.black(44))
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .padding(20)
                    }
                }
                .frame(height: 380)

                HStack {
                    if !shown.genres.isEmpty {
                        Text(shown.genres.prefix(3).map(\.capitalized).joined(separator: " · "))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    GlassIconButton(systemImage: "shuffle", size: 46) { player.playShuffled(top, title: shown.name) }
                    GlassIconButton(systemImage: "play.fill", size: 54, tint: Theme.accent) {
                        if !top.isEmpty { player.play(top, startAt: 0, title: shown.name) }
                    }
                }
                .padding(.horizontal, 20)
                .disabled(top.isEmpty)

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Popular")
                        ForEach(Array(top.prefix(10).enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 4)
                                .onTapGesture { player.play(top, startAt: index, title: shown.name) }
                        }
                    }
                }
                if !albums.isEmpty { AlbumShelf(title: "Albums", albums: albums) }
                if let bio = shown.bio, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "About")
                        Text(bio).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20)
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .background {
            LinearGradient(colors: [palette.primary.opacity(0.6), .black, .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        if artist.addonID == SpotifyService.sourceID {
            let (a, t, al) = await spotify.artistDetail(artist)
            info = a; top = t; albums = al
        } else if let ctx = addons.context(forID: artist.addonID) {
            if let r = try? await AddonClient.artist(ctx, id: artist.artistID) {
                info = r.0; top = r.1; albums = r.2
            } else if let r = try? await AddonClient.search(ctx, query: artist.name) {
                // No /artist endpoint: fall back to a search.
                top = r.tracks.filter { $0.artist.localizedCaseInsensitiveContains(artist.name) }
                albums = r.albums.filter { $0.artist.localizedCaseInsensitiveContains(artist.name) }
            }
        }
    }
}
