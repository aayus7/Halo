import SwiftUI

struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AddonStore.self) private var addons
    @Environment(SpotifyService.self) private var spotify

    @State private var catalogRows: [CatalogRow] = []
    @State private var heroPalette = Palette.fallback
    @State private var loadingMix: String?

    private var home: SpotifyService.HomeData { spotify.home }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if isEmpty {
                    onboarding
                } else {
                    if !heroItems.isEmpty { heroCarousel }
                    if !shortcuts.isEmpty { shortcutGrid }
                    if !home.recent.isEmpty { TrackShelf(title: "Jump Back In", tracks: Array(home.recent.prefix(20))) }
                    if !library.history.isEmpty, home.recent.isEmpty {
                        TrackShelf(title: "Recently Played", tracks: Array(library.history.prefix(20)))
                    }
                    if !home.topTracks.isEmpty {
                        TrackShelf(title: "On Repeat", subtitle: "Your top songs lately", tracks: Array(home.topTracks.prefix(25)))
                    } else if !library.mostPlayed.isEmpty {
                        TrackShelf(title: "On Repeat", tracks: library.mostPlayed)
                    }
                    if !home.playlists.isEmpty { PlaylistShelf(title: "Your Playlists", playlists: home.playlists) }
                    ForEach(catalogRows) { row in catalogShelf(row) }
                    if !home.albums.isEmpty { AlbumShelf(title: "Saved Albums", albums: home.albums) }
                    if !artistsYouLove.isEmpty { ArtistShelf(title: "Artists You Love", artists: artistsYouLove) }
                    if !library.liked.isEmpty { TrackShelf(title: "Liked in Halo", tracks: Array(library.liked.prefix(20))) }
                    if !library.localTracks.isEmpty { TrackShelf(title: "On This iPhone", tracks: Array(library.localTracks.prefix(20))) }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { TintedBackground(palette: heroPalette, height: 620) }
        .pageTitle("Home")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .bold))
                        avatar
                    }
                }
            }
        }
        .refreshable {
            await spotify.refreshHome(force: true)
            await loadCatalogs()
        }
        .task(id: addons.enabled.map(\.id)) { await loadCatalogs() }
    }

    private var isEmpty: Bool {
        !spotify.isConnected && library.history.isEmpty && library.localTracks.isEmpty
            && library.liked.isEmpty && catalogRows.isEmpty
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = spotify.profile?.imageURL {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.gray }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 22))
        }
    }

    // MARK: Hero carousel ("Mixes" built from your top artists)

    private struct HeroItem: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var url: URL?
        var artist: Artist?
        var playlist: RemotePlaylist?
    }

    private var heroItems: [HeroItem] {
        let artists = home.topArtists.isEmpty ? home.followed : home.topArtists
        if !artists.isEmpty {
            return artists.prefix(8).enumerated().map { i, a in
                let others = artists.dropFirst(i + 1).prefix(4).map(\.name)
                return HeroItem(id: a.id, title: "\(a.name) Mix",
                                subtitle: others.isEmpty ? (a.genres.first?.capitalized ?? "Based on your listening") : ([a.name] + others).joined(separator: ", "),
                                url: a.artworkURL, artist: a)
            }
        }
        return home.playlists.prefix(6).map {
            HeroItem(id: $0.id, title: $0.title, subtitle: $0.creator ?? "", url: $0.artworkURL, playlist: $0)
        }
    }

    private var heroCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(heroItems) { item in
                    Button { openHero(item) } label: {
                        HeroCard(title: item.title, subtitle: item.subtitle, url: item.url, width: 300)
                            .overlay(alignment: .topTrailing) {
                                if loadingMix == item.id {
                                    ProgressView().padding(12).glassCircle()
                                        .padding(10)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .task(id: heroItems.first?.url) {
            guard let url = heroItems.first?.url, let image = await ArtworkLoader.image(at: url) else { return }
            heroPalette = PaletteExtractor.palette(for: image, key: url.absoluteString)
        }
    }

    private func openHero(_ item: HeroItem) {
        if let playlist = item.playlist {
            NavigationModelProxy.open(.playlist(playlist))
            return
        }
        guard let artist = item.artist else { return }
        loadingMix = item.id
        Task {
            defer { loadingMix = nil }
            let (_, top, _) = await spotify.artistDetail(artist)
            // A mix: this artist's best plus your own favourites from the artists around them.
            let neighbours = Set(heroItems.compactMap(\.artist?.name).map { $0.lowercased() })
            let mine = (home.topTracks + home.liked).filter { t in
                neighbours.contains { t.artist.lowercased().contains($0) }
            }
            var seen = Set<String>()
            let mix = (top + mine).filter { seen.insert($0.id).inserted }
            guard !mix.isEmpty else {
                NoticeCenter.shared.show("Couldn't build a mix for \(artist.name).", level: .warning)
                return
            }
            player.playShuffled(mix, title: item.title)
        }
    }

    // MARK: Shortcut grid

    private struct Shortcut: Identifiable {
        var id: String
        var title: String
        var url: URL?
        var route: Route
        var systemImage: String?
    }

    private var shortcuts: [Shortcut] {
        var items: [Shortcut] = []
        if spotify.isConnected {
            items.append(Shortcut(id: "liked", title: "Liked Songs", route: .spotifyLiked, systemImage: "heart.fill"))
        } else if !library.liked.isEmpty {
            items.append(Shortcut(id: "liked", title: "Liked Songs", route: .liked, systemImage: "heart.fill"))
        }
        items += library.playlists.prefix(3).map {
            Shortcut(id: $0.id, title: $0.name, url: $0.tracks.first?.artworkURL, route: .userPlaylist($0.id))
        }
        items += home.playlists.prefix(8 - items.count).map {
            Shortcut(id: $0.id, title: $0.title, url: $0.artworkURL, route: .playlist($0))
        }
        if items.count < 8 {
            items += home.albums.prefix(8 - items.count).map {
                Shortcut(id: $0.id, title: $0.title, url: $0.artworkURL, route: .album($0))
            }
        }
        return items.count >= 2 ? Array(items.prefix(8)) : []
    }

    private var shortcutGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(shortcuts) { s in
                NavigationLink(value: s.route) {
                    ShortcutTile(title: s.title, url: s.url, systemImage: s.systemImage,
                                 gradient: s.systemImage != nil ? [Color(red: 0.36, green: 0.25, blue: 0.95), Color(red: 0.55, green: 0.75, blue: 0.95)] : nil)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var artistsYouLove: [Artist] {
        var seen = Set<String>()
        return (home.followed + home.topArtists).filter { seen.insert($0.id).inserted }
    }

    // MARK: Addon catalogs

    @ViewBuilder
    private func catalogShelf(_ row: CatalogRow) -> some View {
        if !row.tracks.isEmpty {
            TrackShelf(title: row.catalog.name, subtitle: row.addonName, tracks: row.tracks)
        } else if !row.albums.isEmpty {
            AlbumShelf(title: row.catalog.name, albums: row.albums)
        } else if !row.playlists.isEmpty {
            PlaylistShelf(title: row.catalog.name, playlists: row.playlists)
        } else if !row.artists.isEmpty {
            ArtistShelf(title: row.catalog.name, artists: row.artists)
        }
    }

    private func loadCatalogs() async {
        let contexts = addons.enabled.filter { $0.manifest.supports("catalog") && !$0.manifest.catalogs.isEmpty }
            .map { addons.context(for: $0) }
        guard !contexts.isEmpty else { catalogRows = []; return }
        var rows: [CatalogRow] = []
        await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            var order = 0
            for ctx in contexts {
                for catalog in ctx.addon.manifest.catalogs {
                    let position = order
                    order += 1
                    group.addTask { (position, try? await AddonClient.catalog(ctx, catalog)) }
                }
            }
            var collected: [(Int, CatalogRow)] = []
            for await (i, row) in group { if let row, !row.isEmpty { collected.append((i, row)) } }
            rows = collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        catalogRows = rows
    }

    // MARK: Onboarding

    private var onboarding: some View {
        VStack(spacing: 14) {
            OnboardingCard(icon: "music.note.house.fill", title: "Bring your Home",
                           text: "Connect Spotify to build Home from your playlists, top songs and artists. Songs play through your addons.",
                           route: .settings)
            OnboardingCard(icon: "puzzlepiece.extension.fill", title: "Install an addon",
                           text: "Addons are where the music comes from. Paste an Eclipse-compatible addon URL.",
                           route: .addons)
            OnboardingCard(icon: "folder.fill", title: "Add your own files",
                           text: "Import MP3, AAC, ALAC, FLAC or WAV from the Library tab.",
                           route: .local)
        }
        .padding(.horizontal, 16)
    }
}

private struct OnboardingCard: View {
    let icon: String
    let title: String
    let text: String
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.heavy(19))
                    Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(18)
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Lets plain buttons push routes without threading the navigation model through every view.
@MainActor
enum NavigationModelProxy {
    static weak var model: NavigationModel?
    static func open(_ route: Route) { model?.open(route) }
}
