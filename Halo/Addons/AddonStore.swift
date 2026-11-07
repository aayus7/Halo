import Foundation
import Network
import Observation

@MainActor
@Observable
final class AddonStore {
    private(set) var addons: [InstalledAddon] = []
    /// addonID → setting key → value. Per-network settings store "key@cell" alongside "key".
    private(set) var values: [String: [String: JSONScalar]] = [:]
    private(set) var isOnCellular = false

    @ObservationIgnored private let fileName = "addons.json"
    @ObservationIgnored private let valuesFile = "addon-settings.json"
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        addons = Store.load([InstalledAddon].self, from: fileName) ?? []
        values = Store.load([String: [String: JSONScalar]].self, from: valuesFile) ?? [:]
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            Task { @MainActor in self?.isOnCellular = cellular }
        }
        monitor.start(queue: DispatchQueue(label: "halo.network"))
    }

    var enabled: [InstalledAddon] { addons.filter(\.enabled) }

    var enabledSearchAddons: [InstalledAddon] {
        addons.filter { $0.enabled && $0.manifest.supports("search") }
    }

    func addon(withID id: String) -> InstalledAddon? {
        addons.first { $0.id == id }
    }

    // MARK: Request context

    func context(for addon: InstalledAddon) -> AddonContext {
        AddonContext(addon: addon, params: parameters(for: addon), noticesEnabled: addon.showNotices)
    }

    func context(forID id: String) -> AddonContext? {
        guard let addon = addon(withID: id), addon.enabled else { return nil }
        return context(for: addon)
    }

    /// Defaults from the manifest, overlaid with the user's values for the current network.
    func parameters(for addon: InstalledAddon) -> [String: String] {
        var params: [String: String] = [:]
        for setting in addon.manifest.settings {
            if let v = value(for: setting, in: addon, cellular: isOnCellular)?.queryValue {
                params[setting.key] = v
            }
        }
        return params
    }

    func value(for setting: AddonSetting, in addon: InstalledAddon, cellular: Bool) -> JSONScalar? {
        let stored = values[addon.id] ?? [:]
        if setting.perNetwork, cellular, let v = stored[setting.key + "@cell"] { return v }
        return stored[setting.key] ?? setting.default
    }

    func setValue(_ value: JSONScalar?, for setting: AddonSetting, in addon: InstalledAddon, cellular: Bool) {
        let key = setting.perNetwork && cellular ? setting.key + "@cell" : setting.key
        var stored = values[addon.id] ?? [:]
        stored[key] = value
        values[addon.id] = stored
        Store.save(values, to: valuesFile)
    }

    // MARK: Install / manage

    @discardableResult
    func install(from input: String) async throws -> InstalledAddon {
        let fetched = try await AddonClient.fetchManifest(from: input)
        if let i = addons.firstIndex(where: { $0.id == fetched.id }) {
            var updated = fetched
            updated.enabled = addons[i].enabled
            updated.customName = addons[i].customName
            updated.showNotices = addons[i].showNotices
            updated.installedAt = addons[i].installedAt
            addons[i] = updated
        } else {
            addons.append(fetched)
        }
        save()
        return fetched
    }

    func refresh(_ addon: InstalledAddon) async throws {
        try await install(from: addon.baseURL.absoluteString)
    }

    func remove(_ addon: InstalledAddon) {
        addons.removeAll { $0.id == addon.id }
        values[addon.id] = nil
        Store.save(values, to: valuesFile)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        update(id) { $0.enabled = enabled }
    }

    func rename(_ id: String, to name: String) {
        update(id) { $0.customName = name.isEmpty ? nil : name }
    }

    func setShowNotices(_ id: String, _ on: Bool) {
        update(id) { $0.showNotices = on }
    }

    private func update(_ id: String, _ change: (inout InstalledAddon) -> Void) {
        guard let i = addons.firstIndex(where: { $0.id == id }) else { return }
        change(&addons[i])
        save()
    }

    private func save() {
        Store.save(addons, to: fileName)
    }
}
