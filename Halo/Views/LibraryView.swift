import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    @State private var showImporter = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TrackListView(title: "Liked Songs") { library.liked }
                } label: {
                    LibraryLink(title: "Liked Songs", systemImage: "heart.fill",
                                count: library.liked.count, tint: Theme.like)
                }
                NavigationLink {
                    TrackListView(title: "Recently Played") { library.history }
                } label: {
                    LibraryLink(title: "Recently Played", systemImage: "clock.fill",
                                count: library.history.count, tint: .orange)
                }
            }

            Section {
                if library.localTracks.isEmpty {
                    Text("Tap + to import audio files, or drop them into Files › On My iPhone › Halo › Music and pull to refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(library.localTracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, onDelete: { library.deleteLocal(track) })
                        .onTapGesture { player.play(library.localTracks, startAt: index) }
                }
            } header: {
                HStack {
                    Text("On This iPhone")
                    Spacer()
                    if !library.localTracks.isEmpty {
                        Text("\(library.localTracks.count) songs")
                    }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .refreshable { await library.rescan() }
        .overlay {
            if library.isImporting {
                ProgressView("Importing…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

private struct LibraryLink: View {
    let title: String
    let systemImage: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.body.weight(.medium))
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }
}

struct TrackListView: View {
    let title: String
    let tracks: () -> [Track]

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let items = tracks()
        List {
            if items.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "music.note.list")
                    .listRowSeparator(.hidden)
            } else {
                HStack(spacing: 12) {
                    Button { player.play(items) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { player.playShuffled(items) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .listRowSeparator(.hidden)

                ForEach(Array(items.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track)
                        .onTapGesture { player.play(items, startAt: index) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
    }
}
