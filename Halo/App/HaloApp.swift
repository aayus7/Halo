import SwiftUI

@main
struct HaloApp: App {
    @State private var library: LibraryStore
    @State private var addons: AddonStore
    @State private var player: PlayerEngine
    @State private var spotify: SpotifyService
    @State private var nav: NavigationModel
    @Environment(\.scenePhase) private var scenePhase
    private var settings: AppSettings { AppSettings.shared }

    init() {
        // Fresh install (or the app was reinstalled): bring back addons, Spotify, playlists, prefs.
        Backup.restoreIfFreshInstall()
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
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Backup.saveToKeychain() }
                }
                .task {
                    if UserDefaults.standard.bool(forKey: "halo.restoredFromBackup") {
                        UserDefaults.standard.removeObject(forKey: "halo.restoredFromBackup")
                        NoticeCenter.shared.show("Your addons, Spotify connection and playlists are back.",
                                                 title: "Restored from backup", level: .success)
                    }
                }
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
