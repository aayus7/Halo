import SwiftUI

struct SearchView: View {
    @Environment(AddonStore.self) private var addons
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player

    struct ResultSection: Identifiable {
        let id: String
        let title: String
        var tracks: [Track]
        var error: String?
    }

    @State private var query = ""
    @State private var sections: [ResultSection] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                hint.listRowSeparator(.hidden)
            } else if !isSearching && sections.isEmpty {
                ContentUnavailableView.search(text: query).listRowSeparator(.hidden)
            }

            ForEach(sections) { section in
                Section(section.title) {
                    if let error = section.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(section.tracks.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(section.tracks, startAt: index) }
                    }
                }
            }

            if isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, artists, albums")
        .autocorrectionDisabled()
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue, delay: 450)
        }
        .onSubmit(of: .search) {
            scheduleSearch(query, delay: 0)
        }
    }

    @ViewBuilder
    private var hint: some View {
        let count = addons.enabledSearchAddons.count
        if count == 0 {
            ContentUnavailableView {
                Label("No search addons", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Install an addon in the Addons tab to search streaming sources. Your own library is always searchable.")
            }
        } else {
            ContentUnavailableView {
                Label("Search", systemImage: "magnifyingglass")
            } description: {
                Text("Searching your library and \(count) addon\(count == 1 ? "" : "s").")
            }
        }
    }

    private func scheduleSearch(_ text: String, delay: Int) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            sections = []
            isSearching = false
            return
        }
        searchTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            guard !Task.isCancelled else { return }
            await performSearch(q)
        }
    }

    private func performSearch(_ q: String) async {
        isSearching = true
        var results: [ResultSection] = []
        let local = library.search(q)
        if !local.isEmpty {
            results.append(ResultSection(id: "local", title: "Your Library", tracks: local))
        }
        sections = results

        let targets = addons.enabledSearchAddons
        await withTaskGroup(of: ResultSection.self) { group in
            for addon in targets {
                group.addTask {
                    do {
                        let tracks = try await AddonClient.search(addon, query: q)
                        return ResultSection(id: addon.id, title: addon.manifest.name, tracks: tracks)
                    } catch {
                        return ResultSection(id: addon.id, title: addon.manifest.name, tracks: [],
                                             error: error.localizedDescription)
                    }
                }
            }
            for await section in group {
                if Task.isCancelled { break }
                if !section.tracks.isEmpty || section.error != nil {
                    results.append(section)
                    sections = results
                }
            }
        }
        if !Task.isCancelled { isSearching = false }
    }
}
