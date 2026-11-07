import SwiftUI

/// Artist page: full-bleed photo, the artist's own logo (or their name set large), play,
/// what you liked from them, their popular songs and albums.
struct ArtistView: View {
    let artist: Artist

    @Environment(PlayerEngine.self) private var player
    @Environment(AddonStore.self) private var addons
    @Environment(SpotifyService.self) private var spotify
    @Environment(LibraryStore.self) private var library

    @State private var info: Artist?
    @State private var extra: ArtistInfoService.Info?
    @State private var top: [Track] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var palette = Palette.fallback
    @State private var showAbout = false

    private var shown: Artist { info ?? artist }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(spacing: 0) {
                    hero(width: outer.size.width)
                    VStack(alignment: .leading, spacing: 22) {
                        buttons
                        if !likedFromArtist.isEmpty { likedCard }
                        if isLoading && top.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 10)
                        }
                        if !top.isEmpty { popular }
                        if !albums.isEmpty { AlbumShelf(title: "Albums", albums: albums) }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background {
            LinearGradient(colors: [palette.primary, palette.primary.opacity(0.75), palette.secondary.opacity(0.5), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { player.playShuffled(top, title: shown.name) } label: { Label("Shuffle", systemImage: "shuffle") }
                    Button { library.toggleFollow(shown) } label: {
                        Label(library.isFollowing(shown) ? "Unfollow" : "Follow",
                              systemImage: library.isFollowing(shown) ? "person.badge.minus" : "person.badge.plus")
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAbout) { about }
        .task { await load() }
    }

    // MARK: Hero

    private func hero(width: CGFloat) -> some View {
        let height = width * 1.12
        return GeometryReader { geo in
            let pull = max(geo.frame(in: .scrollView).minY, 0)
            ZStack(alignment: .bottom) {
                FillImage(url: shown.artworkURL ?? extra?.fanart) { image in
                    let p = PaletteExtractor.palette(for: image, key: "artist:" + shown.id)
                    withAnimation(.easeOut(duration: 0.4)) { palette = p }
                }
                .frame(width: width, height: height + pull)
                .clipped()
                .offset(y: -pull)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }

                VStack(spacing: 6) {
                    nameView
                    if let line = subtitleLine {
                        Text(line)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private var nameView: some View {
        if let logo = extra?.logo {
            AsyncImage(url: logo) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .shadow(color: .black.opacity(0.35), radius: 12)
                } else {
                    styledName
                }
            }
            .frame(maxWidth: 300, maxHeight: 96)
        } else {
            styledName
        }
    }

    private var styledName: some View {
        Text(shown.name.uppercased())
            .font(.system(size: 42, weight: .bold, design: .serif))
            .kerning(1.5)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .shadow(color: .black.opacity(0.35), radius: 12)
    }

    private var subtitleLine: String? {
        if let f = shown.followers, f > 0 { return "\(Self.compact(f)) followers" }
        if !shown.genres.isEmpty { return shown.genres.prefix(2).map(\.capitalized).joined(separator: " · ") }
        return nil
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 26) {
            GlassIconButton(systemImage: "info", size: 50) { showAbout = true }
            Button {
                if !top.isEmpty { player.play(top, startAt: 0, title: shown.name) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .offset(x: 2)
                    .frame(width: 80, height: 80)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(.plain)
            .disabled(top.isEmpty)
            GlassIconButton(systemImage: library.isFollowing(shown) ? "person.fill.checkmark" : "person.badge.plus", size: 50) {
                library.toggleFollow(shown)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: You liked

    private var likedFromArtist: [Track] {
        let name = shown.name.lowercased()
        var seen = Set<String>()
        return (library.liked + spotify.home.liked).filter { t in
            (t.artistID == shown.artistID || t.artist.lowercased().contains(name)) && seen.insert(t.id).inserted
        }
    }

    private var likedCard: some View {
        let liked = likedFromArtist
        return NavigationLink(value: Route.tracks(title: "Liked from \(shown.name)", subtitle: shown.name, tracks: liked)) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.15))
                    Image(systemName: "heart.fill").foregroundStyle(.green).font(.system(size: 20))
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You liked").font(.system(size: 17, weight: .bold))
                    Text("\(liked.count) song\(liked.count == 1 ? "" : "s") • \(shown.name)")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .glassCircle()
            }
            .padding(12)
            .glass(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: Popular

    private var popular: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Popular").font(.heavy(24)).padding(.horizontal, 20).padding(.bottom, 4)
            ForEach(Array(top.prefix(10).enumerated()), id: \.offset) { index, track in
                HStack(spacing: 14) {
                    ArtworkView(track: track, size: 58, cornerRadius: 4, pixelSize: 200)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                            .foregroundStyle(player.currentTrack?.id == track.id ? Theme.accent : .white)
                        HStack(spacing: 5) {
                            if track.explicit == true {
                                Image(systemName: "e.square.fill").font(.caption2)
                            }
                            Text(track.album ?? shown.name).lineLimit(1)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 6)
                    Menu {
                        TrackMenuItems(track: track)
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(.white.opacity(0.5)).frame(width: 30, height: 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { player.play(top, startAt: index, title: shown.name) }
                if index < min(top.count, 10) - 1 {
                    Divider().opacity(0.3).padding(.leading, 92)
                }
            }
        }
    }

    // MARK: About

    private var about: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let f = shown.followers { Text("\(f.formatted()) followers").font(.headline) }
                    if !shown.genres.isEmpty {
                        Text(shown.genres.map(\.capitalized).joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                    Text(extra?.bio ?? shown.bio ?? "No biography available.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(shown.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Data

    private func load() async {
        async let art = ArtistInfoService.shared.info(for: artist.name)
        defer { isLoading = false }
        if artist.addonID == SpotifyService.sourceID {
            let (a, t, al) = await spotify.artistDetail(artist)
            info = a; top = t; albums = al
        } else if let ctx = addons.context(forID: artist.addonID) {
            if let r = try? await AddonClient.artist(ctx, id: artist.artistID) {
                info = r.0; top = r.1; albums = r.2
            } else if let r = try? await AddonClient.search(ctx, query: artist.name) {
                top = r.tracks.filter { $0.artist.localizedCaseInsensitiveContains(artist.name) }
                albums = r.albums.filter { $0.artist.localizedCaseInsensitiveContains(artist.name) }
            }
        }
        extra = await art
    }
}
