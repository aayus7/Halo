import SwiftUI

struct AddonsView: View {
    @Environment(AddonStore.self) private var addons

    @State private var urlText = ""
    @State private var isInstalling = false
    @State private var errorText: String?

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                TextField("https://addon.example.com/manifest.json", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(install)
                HStack {
                    Button(action: install) {
                        if isInstalling {
                            ProgressView()
                        } else {
                            Label("Install Addon", systemImage: "plus.circle.fill").font(.body.weight(.semibold))
                        }
                    }
                    .disabled(trimmed.isEmpty || isInstalling)
                    Spacer()
                    Button {
                        if let s = UIPasteboard.general.string { urlText = s }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Install")
            } footer: {
                Text("Paste an addon's install URL. Addons supply search results, browse pages and streams; Halo plays what they return. Eclipse-compatible addons work as-is.")
            }

            Section {
                if addons.addons.isEmpty {
                    Text("No addons yet.").foregroundStyle(.secondary)
                }
                ForEach(addons.addons) { addon in
                    NavigationLink {
                        AddonDetailView(addonID: addon.id)
                    } label: {
                        AddonRow(addon: addon)
                    }
                }
                .onMove { addons.move(from: $0, to: $1) }
                .onDelete { idx in idx.map { addons.addons[$0] }.forEach(addons.remove) }
            } header: {
                Text("Installed")
            } footer: {
                if addons.addons.count > 1 {
                    Text("Order matters: imported songs are matched against addons from the top down.")
                }
            }
        }
        .navigationTitle("Addons")
        .toolbar { EditButton() }
    }

    private func install() {
        let input = trimmed
        guard !input.isEmpty, !isInstalling else { return }
        isInstalling = true
        errorText = nil
        Task {
            do {
                let addon = try await addons.install(from: input)
                NoticeCenter.shared.show("Installed \(addon.manifest.name)", level: .success)
                urlText = ""
            } catch {
                errorText = error.localizedDescription
            }
            isInstalling = false
        }
    }
}

struct AddonIcon: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: size * 0.45))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.accent.opacity(0.15))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

private struct AddonRow: View {
    let addon: InstalledAddon

    private var detailLine: String {
        var parts: [String] = []
        if !addon.manifest.version.isEmpty { parts.append("v" + addon.manifest.version) }
        parts.append(addon.displayHost)
        if addon.manifest.contentType != .music { parts.append(addon.manifest.contentType.rawValue.capitalized) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            AddonIcon(url: addon.manifest.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(addon.displayName).font(.body.weight(.semibold))
                Text(detailLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if addon.manifest.lockedToApp != nil {
                Image(systemName: "lock.fill").foregroundStyle(.orange)
            } else if !addon.enabled {
                Text("Off").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .opacity(addon.enabled ? 1 : 0.55)
    }
}

/// One addon: enable, rename, notices, and the settings its manifest declares.
struct AddonDetailView: View {
    let addonID: String

    @Environment(AddonStore.self) private var addons
    @Environment(\.dismiss) private var dismiss
    @State private var editingCellular = false
    @State private var refreshing = false
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        if let addon = addons.addon(withID: addonID) {
            List {
                Section {
                    HStack(spacing: 14) {
                        AddonIcon(url: addon.manifest.icon, size: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(addon.manifest.name).font(.title3.weight(.bold))
                            Text("v\(addon.manifest.version) · \(addon.displayHost)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let d = addon.manifest.description, !d.isEmpty {
                        Text(d).font(.callout).foregroundStyle(.secondary)
                    }
                    if let app = addon.manifest.lockedToApp {
                        Label("This addon only answers the \(app) app (it requires \(app)'s signed login), so Halo can't use it. Remove it, or ask its author for an Eclipse-compatible link.",
                              systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    Toggle("Enabled", isOn: Binding(get: { addon.enabled }, set: { addons.setEnabled(addon.id, $0) }))
                    TextField("Display name", text: Binding(get: { addon.customName ?? "" }, set: { addons.rename(addon.id, to: $0) }),
                              prompt: Text(addon.manifest.name))
                    if addon.manifest.supports("notifications") {
                        Toggle("Notifications", isOn: Binding(get: { addon.showNotices }, set: { addons.setShowNotices(addon.id, $0) }))
                    }
                }

                if !addon.manifest.settings.isEmpty {
                    Section {
                        if addon.manifest.settings.contains(where: \.perNetwork) {
                            Picker("Network", selection: $editingCellular) {
                                Text("Wi-Fi").tag(false)
                                Text("Cellular").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        ForEach(addon.manifest.settings) { setting in
                            AddonSettingRow(addon: addon, setting: setting, cellular: editingCellular && setting.perNetwork)
                        }
                    } header: {
                        Text("Settings")
                    } footer: {
                        Text("Sent to the addon with every request.")
                    }
                }

                Section("Capabilities") {
                    Text(addon.manifest.resources.isEmpty ? "search, stream" : addon.manifest.resources.joined(separator: ", "))
                        .font(.callout.monospaced())
                    if !addon.manifest.catalogs.isEmpty {
                        Text("Home rows: " + addon.manifest.catalogs.map(\.name).joined(separator: ", ")).font(.callout)
                    }
                }

                Section {
                    Button {
                        testing = true
                        testResult = nil
                        Task {
                            testResult = await AddonClient.diagnose(addons.context(for: addon))
                            testing = false
                        }
                    } label: {
                        HStack { Text("Test Connection"); if testing { Spacer(); ProgressView() } }
                    }
                    if let testResult {
                        Text(testResult).font(.footnote.monospaced())
                            .foregroundStyle(testResult.hasPrefix("Working") ? .green : .orange)
                            .textSelection(.enabled)
                    }
                    Button {
                        refreshing = true
                        Task {
                            do { try await addons.refresh(addon) } catch {
                                NoticeCenter.shared.show(error.localizedDescription, title: "Refresh failed", level: .error)
                            }
                            refreshing = false
                        }
                    } label: {
                        HStack { Text("Refresh Manifest"); if refreshing { Spacer(); ProgressView() } }
                    }
                    Button("Remove Addon", role: .destructive) {
                        addons.remove(addon)
                        dismiss()
                    }
                }
            }
            .navigationTitle(addon.displayName)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Addon removed", systemImage: "puzzlepiece.extension")
        }
    }
}

private struct AddonSettingRow: View {
    let addon: InstalledAddon
    let setting: AddonSetting
    let cellular: Bool

    @Environment(AddonStore.self) private var addons

    private var current: JSONScalar? { addons.value(for: setting, in: addon, cellular: cellular) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let help = setting.help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch setting.type {
        case .toggle:
            Toggle(setting.label, isOn: Binding(
                get: { current?.flag ?? false },
                set: { set(.bool($0)) }
            ))
        case .select:
            Picker(setting.label, selection: Binding(
                get: { current?.queryValue ?? "" },
                set: { newValue in
                    let match = setting.options.first { $0.value?.queryValue == newValue }
                    set(match?.value ?? .string(newValue))
                }
            )) {
                ForEach(Array(setting.options.enumerated()), id: \.offset) { _, option in
                    Text(option.label?.displayText ?? option.value?.displayText ?? "?").tag(option.value?.queryValue ?? "")
                }
            }
        case .number:
            HStack {
                Text(setting.label)
                Spacer()
                TextField(setting.placeholder ?? "", text: Binding(
                    get: { current?.queryValue ?? "" },
                    set: { text in
                        guard let v = Double(text) else { if text.isEmpty { set(nil) }; return }
                        var clamped = v
                        if let lo = setting.min { clamped = max(clamped, lo) }
                        if let hi = setting.max { clamped = min(clamped, hi) }
                        set(clamped.rounded() == clamped ? .int(Int(clamped)) : .double(clamped))
                    }
                ))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
            }
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(setting.label).font(.subheadline)
                TextField(setting.placeholder ?? "", text: Binding(
                    get: { current?.displayText ?? "" },
                    set: { text in
                        let limited = setting.maxLength.map { String(text.prefix($0)) } ?? text
                        set(.string(limited))
                    }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        }
    }

    private func set(_ value: JSONScalar?) {
        addons.setValue(value, for: setting, in: addon, cellular: cellular)
    }
}
