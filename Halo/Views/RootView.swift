import SwiftUI

/// Tab selection and per-tab navigation paths, so any screen (even Now Playing) can open a page.
@MainActor
@Observable
final class NavigationModel {
    enum Tab: Hashable { case home, library, search }

    var tab: Tab = .home
    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    var searchPath = NavigationPath()
    var dismissPlayer: (() -> Void)?

    func open(_ route: Route) {
        dismissPlayer?()
        switch tab {
        case .home: homePath.append(route)
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        }
    }
}

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(NavigationModel.self) private var nav
    @Environment(AddonStore.self) private var addons
    @Environment(SpotifyService.self) private var spotify

    var body: some View {
        @Bindable var navModel = nav
        @Bindable var engine = player
        TabView(selection: $navModel.tab) {
            Tab("Home", systemImage: "house.fill", value: NavigationModel.Tab.home) {
                NavigationStack(path: $navModel.homePath) {
                    HomeView().haloDestinations()
                }
            }
            Tab("Library", systemImage: "square.stack.fill", value: NavigationModel.Tab.library) {
                NavigationStack(path: $navModel.libraryPath) {
                    LibraryView().haloDestinations()
                }
            }
            Tab(value: NavigationModel.Tab.search, role: .search) {
                NavigationStack(path: $navModel.searchPath) {
                    SearchView().haloDestinations()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayerView()
        }
        .fullScreenCover(isPresented: $engine.isNowPlayingPresented) {
            NowPlayingView()
        }
        .overlay(alignment: .top) { ToastOverlay() }
        .onAppear {
            let model = player
            nav.dismissPlayer = { [weak model] in model?.isNowPlayingPresented = false }
        }
        .task {
            await spotify.refreshHome()
        }
    }
}

struct ToastOverlay: View {
    private var center: NoticeCenter { NoticeCenter.shared }

    var body: some View {
        ZStack {
            if let toast = center.current {
                HStack(spacing: 12) {
                    Group {
                        if let icon = toast.icon {
                            AsyncImage(url: icon) { $0.resizable().scaledToFill() } placeholder: { symbol(toast.level) }
                                .frame(width: 30, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        } else {
                            symbol(toast.level)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = toast.title ?? toast.source {
                            Text(title).font(.subheadline.weight(.bold)).lineLimit(1)
                        }
                        Text(toast.message).font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(3)
                        if let p = toast.progress {
                            ProgressView(value: p).tint(Theme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 14)
                .onTapGesture { center.dismiss() }
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35), value: center.current)
    }

    private func symbol(_ level: AddonNotice.Level) -> some View {
        let (name, color): (String, Color) = switch level {
        case .info: ("info.circle.fill", .blue)
        case .success: ("checkmark.circle.fill", .green)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .error: ("xmark.octagon.fill", .red)
        }
        return Image(systemName: name).font(.title3).foregroundStyle(color).frame(width: 30, height: 30)
    }
}
