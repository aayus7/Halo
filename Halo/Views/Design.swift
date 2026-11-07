import SwiftUI

/// Halo's look: true black, heavy type, Liquid Glass controls, artwork-tinted pages.
@MainActor
enum Theme {
    static var accent: Color { AppSettings.shared.accent }
    static let like = Color(red: 1.0, green: 0.36, blue: 0.62)
    static let artworkRadius: CGFloat = 10
}

extension Font {
    /// The heavy display face used for titles (like the Music app / Chroma).
    static func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
    static func black(_ size: CGFloat) -> Font { .system(size: size, weight: .black) }
}

extension View {
    /// Liquid Glass in a shape, optionally tinted.
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return glassEffect(g, in: shape)
    }

    func glassCircle(tint: Color? = nil) -> some View {
        glass(Circle(), tint: tint, interactive: true)
    }

    func glassCapsule(tint: Color? = nil) -> some View {
        glass(Capsule(), tint: tint, interactive: true)
    }

    /// Large title headers the way Chroma / the Music app draw them.
    func pageTitle(_ text: String) -> some View {
        navigationTitle(text).navigationBarTitleDisplayMode(.large)
    }
}

/// A round glass icon button.
struct GlassIconButton: View {
    let systemImage: String
    var size: CGFloat = 48
    var tint: Color? = nil
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassCircle(tint: tint)
    }
}

/// Shuffle · Play · + row used on album / playlist / artist pages.
struct PlayControlsRow: View {
    var onShuffle: () -> Void
    var onPlay: () -> Void
    var onAdd: (() -> Void)?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 16) {
            GlassIconButton(systemImage: "shuffle", size: 48, action: onShuffle)
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 170, height: 52)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            if let onAdd {
                GlassIconButton(systemImage: "plus", size: 48, action: onAdd)
            } else {
                Color.clear.frame(width: 48, height: 48)
            }
        }
    }
}

/// Section heading at the Music app's size.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let subtitle {
                Text(subtitle).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(title).font(.heavy(22)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

/// Fills the background with the palette of an image, fading to black.
struct TintedBackground: View {
    var palette: Palette
    var height: CGFloat = 520

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            LinearGradient(colors: [palette.primary, palette.primary.opacity(0.55), .black],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: palette)
    }
}
