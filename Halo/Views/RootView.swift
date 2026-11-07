import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .miniPlayerInset()
                .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack { SearchView() }
                .miniPlayerInset()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { LibraryView() }
                .miniPlayerInset()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }

            NavigationStack { AddonsView() }
                .miniPlayerInset()
                .tabItem { Label("Addons", systemImage: "puzzlepiece.extension.fill") }
        }
        .sheet(isPresented: Binding(
            get: { player.isNowPlayingPresented },
            set: { player.isNowPlayingPresented = $0 }
        )) {
            NowPlayingView()
        }
        .overlay(alignment: .top) {
            if let message = player.errorMessage {
                ErrorToast(message: message) { player.errorMessage = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: player.errorMessage)
    }
}

private struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .lineLimit(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal)
            .onTapGesture(perform: dismiss)
            .task(id: message) {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                dismiss()
            }
    }
}

extension View {
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerView() }
    }
}
