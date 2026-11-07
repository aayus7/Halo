import SwiftUI

@main
struct HaloApp: App {
    @State private var library: LibraryStore
    @State private var addons: AddonStore
    @State private var player: PlayerEngine

    init() {
        let library = LibraryStore()
        let addons = AddonStore()
        let player = PlayerEngine()
        player.library = library
        player.addons = addons
        _library = State(initialValue: library)
        _addons = State(initialValue: addons)
        _player = State(initialValue: player)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(addons)
                .environment(player)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.64, green: 0.45, blue: 1.0)
    static let like = Color(red: 1.0, green: 0.36, blue: 0.62)
}
