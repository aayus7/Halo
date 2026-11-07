import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SpotifyService.self) private var spotify

    @State private var showImporter = false
    @State private var newPlaylistName = ""
    @State private var showNewPlaylist = false

    var body: some View {
        List {
            Section {
                row(.spotifyLiked, title: "Liked Songs", subtitle: spotify.isConnected ? "Spotify · \(spotify.home.likedTotal) songs" : nil,
                    icon: "heart.fill", tint: Color(red: 0.4, green: 0.3, blue: 0.95), visible: spotify.isConnected)
                row(.liked, title: spotify.isConnected ? "Liked in Halo" : "Liked Songs", subtitle: "\(library.liked.count) songs",
                    icon: "star.fill", tint: Theme.like, visible: true)
                row(.history, title: "Recently Played", subtitle: nil, icon: "clock.fill", tint: .orange, visible: true)
                row(.local, title: "On This iPhone", subtitle: "\(library.localTracks.count) files", icon: "iphone", tint: .teal, visible: true)
            }
            .listRowBackground(Color.clear)

            Section {
                ForEach(library.playlists) { p in
                    NavigationLink(value: Route.userPlaylist(p.id)) {
                        LibraryItemRow(title: p.name, subtitle: "Playlist · \(p.tracks.count) songs",
                                       url: p.tracks.first?.artworkURL, track: p.tracks.first)
                    }
                }
                .onDelete { idx in idx.map { library.playlists[$0].id }.forEach(library.deletePlaylist) }
                Button { showNewPlaylist = true } label: {
                    Label("New Playlist", systemImage: "plus").font(.body.weight(.semibold))
                }
            } header: {
                Text("Playlists").font(.heavy(20)).foregroundStyle(.primary).textCase(nil)
            }
            .listRowBackground(Color.clear)

            if !spotify.home.playlists.isEmpty {
                Section {
                    ForEach(spotify.home.playlists) { p in
                        NavigationLink(value: Route.playlist(p)) {
                            LibraryItemRow(title: p.title, subtitle: ["Playlist", p.creator ?? ""].filter { !$0.isEmpty }.joined(separator: " · "), url: p.artworkURL)
                        }
                    }
                } header: {
                    Text("From Spotify").font(.heavy(20)).foregroundStyle(.primary).textCase(nil)
                }
                .listRowBackground(Color.clear)
            }

            if !spotify.home.albums.isEmpty {
                Section {
                    ForEach(spotify.home.albums) { a in
                        NavigationLink(value: Route.album(a)) {
                            LibraryItemRow(title: a.title, subtitle: "Album · \(a.artist)", url: a.artworkURL)
                        }
                    }
                } header: {
                    Text("Albums").font(.heavy(20)).foregroundStyle(.primary).textCase(nil)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .pageTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showNewPlaylist = true } label: { Label("New Playlist", systemImage: "music.note.list") }
                    Button { showImporter = true } label: { Label("Import Files", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                library.createPlaylist(newPlaylistName)
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
        .refreshable {
            await library.rescan()
            await spotify.refreshHome(force: true)
        }
        .overlay {
            if library.isImporting {
                ProgressView("Importing…")
                    .padding(24)
                    .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func row(_ route: Route, title: String, subtitle: String?, icon: String, tint: Color, visible: Bool) -> some View {
        if visible {
            NavigationLink(value: route) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 17, weight: .bold))
                        if let subtitle { Text(subtitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

struct LibraryItemRow: View {
    let title: String
    var subtitle: String
    var url: URL?
    var track: Track? = nil

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(track: track, url: url, size: 56, cornerRadius: 8, pixelSize: 200)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(subtitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
