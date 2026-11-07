import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SpotifyService.self) private var spotify
    @Environment(AddonStore.self) private var addons
    @Environment(PlayerEngine.self) private var player

    @State private var showSound = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                NavigationLink(value: Route.addons) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Addons").font(.body.weight(.semibold))
                            Text("\(addons.enabled.count) enabled").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.accent) }
                }
                NavigationLink {
                    SpotifySettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Spotify Import").font(.body.weight(.semibold))
                            Text(spotify.isConnected ? "Connected as \(spotify.profile?.name ?? "you")" : "Not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "music.note.house.fill").foregroundStyle(.green) }
                }
            } header: { Text("Sources") }

            Section("Appearance") {
                ColorPicker("Accent colour", selection: Binding(
                    get: { settings.accent },
                    set: { settings.accentHex = $0.hexString }
                ), supportsOpacity: false)
                Toggle("Tint pages with artwork colours", isOn: $settings.artworkTinting)
            }

            Section {
                Toggle("Hi-res artwork from Apple", isOn: $settings.hiResArtwork)
                Toggle("Animated covers", isOn: $settings.animatedArtwork)
                if settings.animatedArtwork {
                    SecureField("MusicKit developer token", text: $settings.appleMusicToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Storefront (e.g. us, in, gb)", text: $settings.storefront)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Re-check animated covers") {
                        Task { await ArtworkService.shared.clearMotionCache() }
                    }
                }
            } header: {
                Text("Artwork")
            } footer: {
                Text("Hi-res covers come from Apple's public iTunes catalog. Animated covers use the official Apple Music API: make a MusicKit key in your Apple developer account, sign a developer token with it (see docs/ANIMATED_ARTWORK.md) and paste it here.")
            }

            Section("Lyrics") {
                Toggle("Show lyrics", isOn: $settings.lyricsEnabled)
                Toggle("Uppercase lyrics", isOn: $settings.lyricsUppercase)
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Crossfade")
                        Spacer()
                        Text(settings.crossfade == 0 ? "Off" : String(format: "%.0f s", settings.crossfade)).foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.crossfade, in: 0...12, step: 1)
                }
                Toggle("Gapless playback", isOn: $settings.gapless)
                Picker("Speed", selection: Binding(get: { settings.speed }, set: { settings.speed = $0; player.applySoundSettings() })) {
                    ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%gx", $0)).tag($0) }
                }
                Toggle("Keep pitch when changing speed", isOn: Binding(get: { settings.keepPitch }, set: { settings.keepPitch = $0; player.applySoundSettings() }))
                Button { showSound = true } label: {
                    Label("Sound & EQ", systemImage: "slider.vertical.3")
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Gapless and crossfade prepare the next song ahead of time. EQ and effects work on files and progressive streams; HLS streams play untouched.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                Link("Addon protocol", destination: URL(string: "https://github.com/aayus7/Halo/blob/main/docs/ADDON_SPEC.md")!)
            }
        }
        .pageTitle("Settings")
        .sheet(isPresented: $showSound) { SoundSheet() }
    }
}

// MARK: - Sound

struct SoundSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                Section {
                    Toggle("Equalizer", isOn: $settings.eqEnabled)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EQPreset.all) { preset in
                                Button(preset.name) {
                                    withAnimation { settings.eqGains = preset.gains }
                                    settings.eqEnabled = true
                                }
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .glassCapsule(tint: settings.eqGains == preset.gains ? Theme.accent.opacity(0.6) : nil)
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    EQBands(gains: $settings.eqGains)
                        .frame(height: 220)
                        .opacity(settings.eqEnabled ? 1 : 0.4)
                        .disabled(!settings.eqEnabled)
                }
                Section("Effects") {
                    slider("Preamp", value: $settings.preamp, range: -12...6, unit: "dB")
                    slider("Bass boost", value: $settings.bassBoost, range: 0...12, unit: "dB")
                    slider("Stereo width", value: $settings.stereoWidth, range: 0...2, unit: "×")
                }
                .disabled(!settings.eqEnabled)
                Section {
                    Button("Reset", role: .destructive) {
                        settings.eqGains = EQPreset.all[0].gains
                        settings.preamp = 0
                        settings.bassBoost = 0
                        settings.stereoWidth = 1
                    }
                }
            }
            .navigationTitle("Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: settings.eqEnabled) { player.applySoundSettings() }
            .onChange(of: settings.eqGains) { player.applySoundSettings() }
            .onChange(of: settings.preamp) { player.applySoundSettings() }
            .onChange(of: settings.bassBoost) { player.applySoundSettings() }
            .onChange(of: settings.stereoWidth) { player.applySoundSettings() }
        }
        .presentationDetents([.medium, .large])
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: unit == "×" ? "%.2f%@" : "%+.1f %@", value.wrappedValue, unit)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}

/// Ten vertical band sliders.
struct EQBands: View {
    @Binding var gains: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(AppSettings.eqFrequencies.enumerated()), id: \.offset) { i, f in
                VStack(spacing: 6) {
                    Text(String(format: "%+.0f", i < gains.count ? gains[i] : 0))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    GeometryReader { geo in
                        let h = geo.size.height
                        let value = i < gains.count ? gains[i] : 0
                        let y = h * (1 - (value + 12) / 24)
                        ZStack(alignment: .top) {
                            Capsule().fill(.white.opacity(0.15)).frame(width: 4)
                            Capsule().fill(Theme.accent)
                                .frame(width: 4, height: abs(y - h / 2))
                                .offset(y: min(y, h / 2))
                            Circle().fill(.white).frame(width: 18, height: 18).offset(y: y - 9)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            let raw = (1 - v.location.y / h) * 24 - 12
                            guard i < gains.count else { return }
                            gains[i] = (min(max(raw, -12), 12) * 2).rounded() / 2
                        })
                    }
                    Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Spotify

struct SpotifySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SpotifyService.self) private var spotify
    @State private var connecting = false

    var body: some View {
        @Bindable var settings = settings
        List {
            if spotify.isConnected {
                Section {
                    HStack(spacing: 14) {
                        AsyncImage(url: spotify.profile?.imageURL) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                            .frame(width: 52, height: 52).clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(spotify.profile?.name ?? "Connected").font(.headline)
                            Text("\(spotify.home.playlists.count) playlists · \(spotify.home.likedTotal) liked songs")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        Task { await spotify.refreshHome(force: true) }
                    } label: {
                        HStack {
                            Text("Re-import now")
                            if spotify.isLoading { Spacer(); ProgressView() }
                        }
                    }
                    Button("Disconnect", role: .destructive) { spotify.disconnect() }
                }
            } else {
                Section {
                    TextField("Client ID", text: $settings.spotifyClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button {
                        connecting = true
                        Task {
                            await spotify.connect(clientID: settings.spotifyClientID)
                            connecting = false
                        }
                    } label: {
                        HStack {
                            Text("Connect Spotify").font(.body.weight(.semibold))
                            if connecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(settings.spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
                } footer: {
                    Text("""
                    One-time setup:
                    1. Open developer.spotify.com/dashboard and create an app.
                    2. Add the Redirect URI halo://spotify-callback and tick "Web API".
                    3. Under User Management, add your Spotify account's email.
                    4. Copy the app's Client ID here and tap Connect.

                    Halo reads your playlists, liked songs, top songs and artists to build Home. Songs play through your addons.
                    """)
                }
            }
            if let error = spotify.lastError {
                Section { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Spotify Import")
    }
}
