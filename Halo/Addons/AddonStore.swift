import Foundation
import Observation

@MainActor
@Observable
final class AddonStore {
    private(set) var addons: [InstalledAddon] = []

    private let fileName = "addons.json"

    init() {
        addons = Store.load([InstalledAddon].self, from: fileName) ?? []
    }

    var enabledSearchAddons: [InstalledAddon] {
        addons.filter { $0.enabled && $0.manifest.supports("search") }
    }

    func addon(withID id: String) -> InstalledAddon? {
        addons.first { $0.id == id }
    }

    @discardableResult
    func install(from input: String) async throws -> InstalledAddon {
        let addon = try await AddonClient.fetchManifest(from: input)
        if let i = addons.firstIndex(where: { $0.id == addon.id }) {
            var updated = addon
            updated.enabled = addons[i].enabled
            addons[i] = updated
        } else {
            addons.append(addon)
        }
        save()
        return addon
    }

    func refresh(_ addon: InstalledAddon) async throws {
        try await install(from: addon.baseURL.absoluteString)
    }

    func remove(_ addon: InstalledAddon) {
        addons.removeAll { $0.id == addon.id }
        save()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let i = addons.firstIndex(where: { $0.id == id }) else { return }
        addons[i].enabled = enabled
        save()
    }

    private func save() {
        Store.save(addons, to: fileName)
    }
}
