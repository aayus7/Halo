import SwiftUI

struct AddonsView: View {
    @Environment(AddonStore.self) private var addons

    @State private var urlText = ""
    @State private var isInstalling = false
    @State private var errorText: String?
    @State private var successText: String?

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
                            Label("Install Addon", systemImage: "plus.circle.fill")
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
                if let successText {
                    Text(successText).font(.footnote).foregroundStyle(.green)
                }
            } header: {
                Text("Install")
            } footer: {
                Text("Paste an addon's install URL. Addons supply search results and streams. Halo just plays what they return.")
            }

            Section("Installed") {
                if addons.addons.isEmpty {
                    Text("No addons yet.").foregroundStyle(.secondary)
                }
                ForEach(addons.addons) { addon in
                    AddonRow(addon: addon)
                }
            }
        }
        .navigationTitle("Addons")
    }

    private func install() {
        let input = trimmed
        guard !input.isEmpty, !isInstalling else { return }
        isInstalling = true
        errorText = nil
        successText = nil
        Task {
            do {
                let addon = try await addons.install(from: input)
                successText = "Installed \(addon.manifest.name)"
                urlText = ""
            } catch {
                errorText = error.localizedDescription
            }
            isInstalling = false
        }
    }
}

private struct AddonRow: View {
    let addon: InstalledAddon
    @Environment(AddonStore.self) private var addons

    private var detailLine: String {
        var parts: [String] = []
        if !addon.manifest.version.isEmpty { parts.append("v" + addon.manifest.version) }
        parts.append(addon.displayHost)
        if !addon.manifest.resources.isEmpty { parts.append(addon.manifest.resources.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: addon.manifest.icon) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.accent.opacity(0.15))
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(addon.manifest.name).font(.body.weight(.semibold))
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let d = addon.manifest.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { addon.enabled },
                set: { addons.setEnabled(addon.id, $0) }
            ))
            .labelsHidden()
        }
        .swipeActions {
            Button(role: .destructive) { addons.remove(addon) } label: {
                Label("Remove", systemImage: "trash")
            }
            Button {
                Task { try? await addons.refresh(addon) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}
