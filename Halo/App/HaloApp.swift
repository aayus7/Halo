import SwiftUI

@main
struct HaloApp: App {
    @State private var library: LibraryStore
    @State private var addons: AddonStore
    @State private var player: PlayerEngine
    @State private var spotify: SpotifyService
    @State private var nav: NavigationModel
    private let settings = AppSettings.shared

    init() {
        let library = LibraryStore()
        let addons = AddonStore()
        let player = PlayerEngine()
        player.library = library
        player.addons = addons
        let nav = NavigationModel()
        NavigationModelProxy.model = nav
        _library = State(initialValue: library)
        _addons = State(initialValue: addons)
        _player = State(initialValue: player)
        _spotify = State(initialValue: SpotifyService())
        _nav = State(initialValue: nav)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(addons)
                .environment(player)
                .environment(spotify)
                .environment(nav)
                .environment(settings)
                .tint(settings.accent)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // halo://install?url=<addon manifest URL>
                    guard url.scheme == "halo", url.host == "install",
                          let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "url" })?.value else { return }
                    Task {
                        do {
                            let addon = try await addons.install(from: target)
                            NoticeCenter.shared.show("Installed \(addon.manifest.name)", level: .success)
                        } catch {
                            NoticeCenter.shared.show(error.localizedDescription, title: "Install failed", level: .error)
                        }
                    }
                }
        }
    }
}
