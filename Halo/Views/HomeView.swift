import SwiftUI

struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    @State private var picks: [Track] = []

    private var isEmpty: Bool {
        library.history.isEmpty && library.localTracks.isEmpty && library.liked.isEmpty
    }

    var body: some View {
        ScrollView {
            if isEmpty {
                ContentUnavailableView {
                    Label("Welcome to Halo", systemImage: "sparkles")
                } description: {
                    Text("Install an addon in the Addons tab to search and stream, or import your own files from the Library tab.")
                }
                .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    quickActions
                    if !library.history.isEmpty {
                        Shelf(title: "Recently Played", tracks: Array(library.history.prefix(20)))
                    }
                    if !picks.isEmpty {
                        Shelf(title: "Top Picks for You", tracks: picks)
                    }
                    if !library.mostPlayed.isEmpty {
                        Shelf(title: "On Repeat", tracks: library.mostPlayed)
                    }
                    if !library.liked.isEmpty {
                        Shelf(title: "Liked Songs", tracks: Array(library.liked.prefix(20)))
                    }
                    if !library.localTracks.isEmpty {
                        Shelf(title: "On This iPhone", tracks: Array(library.localTracks.prefix(20)))
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(greeting)
        .onAppear { if picks.isEmpty { picks = library.topPicks } }
        .refreshable { picks = library.topPicks }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            QuickButton(title: "Shuffle Liked", systemImage: "heart.fill", tint: Theme.like) {
                player.playShuffled(library.liked)
            }
            .disabled(library.liked.isEmpty)
            QuickButton(title: "Shuffle All", systemImage: "shuffle", tint: Theme.accent) {
                var all = library.localTracks
                let ids = Set(all.map(\.id))
                all += library.liked.filter { !ids.contains($0.id) }
                player.playShuffled(all)
            }
            .disabled(library.localTracks.isEmpty && library.liked.isEmpty)
        }
        .padding(.horizontal)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late night"
        }
    }
}

private struct QuickButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

struct Shelf: View {
    let title: String
    let tracks: [Track]

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        Button { player.play(tracks, startAt: index) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(track: track, size: 140, cornerRadius: 12)
                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 140, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenuItems(track: track) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
