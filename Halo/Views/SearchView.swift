import SwiftUI

struct SearchView: View {
    @Environment(AddonStore.self) private var addons
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    struct SourceResult: Identifiable {
        let id: String
        let name: String
        var result: AddonSearchResult
        var error: String?
    }

    @State private var query = ""
    @State private var sourceFilter: String = "all"
    @State private var results: [SourceResult] = []
    @State private var localResults: [Track] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if addons.enabledSearchAddons.count > 1 { sourcePicker }

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    hint
                } else {
                    if !localResults.isEmpty, sourceFilter == "all" || sourceFilter == "local" {
                        songsSection(title: "In Your Library", tracks: localResults)
                    }
                    ForEach(filtered) { source in
                        sourceSection(source)
                    }
                    if isSearching {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                    } else if filtered.allSatisfy({ $0.result.isEmpty && $0.error == nil }) && localResults.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .pageTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: query) { _, newValue in scheduleSearch(newValue, delay: 450) }
        .onSubmit(of: .search) { scheduleSearch(query, delay: 0) }
    }

    private var filtered: [SourceResult] {
        sourceFilter == "all" ? results : results.filter { $0.id == sourceFilter }
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("all", "All")
                chip("local", "Library")
                ForEach(addons.enabledSearchAddons) { addon in chip(addon.id, addon.displayName) }
            }
            .padding(.horizontal, 20)
        }
    }

    private func chip(_ id: String, _ title: String) -> some View {
        Button { sourceFilter = id } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(sourceFilter == id ? Color.black : Color.white)
                .background(Capsule().fill(sourceFilter == id ? Color.white : Color.clear))
        }
        .buttonStyle(.plain)
        .glassCapsule()
    }

    @ViewBuilder
    private var hint: some View {
        let count = addons.enabledSearchAddons.count
        if count == 0 {
            ContentUnavailableView {
                Label("No search addons", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Install an addon in Settings › Addons to search streaming sources. Your own library is always searchable.")
            } actions: {
                NavigationLink("Install an Addon", value: Route.addons).buttonStyle(.glassProminent)
            }
            .padding(.top, 60)
        } else {
            ContentUnavailableView {
                Label("Search", systemImage: "magnifyingglass")
            } description: {
                Text("Searching your library and \(count) addon\(count == 1 ? "" : "s").")
            }
            .padding(.top, 60)
        }
    }

    @ViewBuilder
    private func sourceSection(_ source: SourceResult) -> some View {
        let r = source.result
        if let error = source.error {
            Label("\(source.name): \(error)", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
        if !r.tracks.isEmpty {
            songsSection(title: results.count > 1 ? "Songs · \(source.name)" : "Songs", tracks: r.tracks)
        }
        if !r.artists.isEmpty { ArtistShelf(title: "Artists", artists: r.artists) }
        if !r.albums.isEmpty { AlbumShelf(title: "Albums", albums: r.albums) }
        if !r.playlists.isEmpty { PlaylistShelf(title: "Playlists", playlists: r.playlists) }
    }

    private func songsSection(title: String, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.prefix(8).enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 5)
                        .onTapGesture { player.play(tracks, startAt: index, title: "Search") }
                }
            }
        }
    }

    // MARK: Searching

    private func scheduleSearch(_ text: String, delay: Int) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            localResults = []
            isSearching = false
            return
        }
        searchTask = Task {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            await performSearch(q)
        }
    }

    private func performSearch(_ q: String) async {
        isSearching = true
        localResults = library.search(q)
        let targets = addons.enabledSearchAddons.map { addons.context(for: $0) }
        var collected: [SourceResult] = targets.map { SourceResult(id: $0.id, name: $0.addon.displayName, result: AddonSearchResult()) }
        results = []
        await withTaskGroup(of: (String, AddonSearchResult?, String?).self) { group in
            for ctx in targets {
                group.addTask {
                    do { return (ctx.id, try await AddonClient.search(ctx, query: q), nil) }
                    catch { return (ctx.id, nil, error.localizedDescription) }
                }
            }
            for await (id, result, error) in group {
                if Task.isCancelled { break }
                if let i = collected.firstIndex(where: { $0.id == id }) {
                    collected[i].result = result ?? AddonSearchResult()
                    collected[i].error = error
                }
                results = collected.filter { !$0.result.isEmpty || $0.error != nil }
            }
        }
        if !Task.isCancelled { isSearching = false }
    }
}
