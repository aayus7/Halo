import Foundation
import Observation

/// Toasts: addon notices and the app's own messages.
@MainActor
@Observable
final class NoticeCenter {
    static let shared = NoticeCenter()

    struct Toast: Identifiable, Equatable {
        var id: String
        var title: String?
        var message: String
        var level: AddonNotice.Level
        var source: String?
        var icon: URL?
        var progress: Double?
        var duration: Double
    }

    private(set) var current: Toast?
    @ObservationIgnored private var recent: [String: Date] = [:]
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func post(_ notice: AddonNotice, source: String, icon: URL?) {
        let key = "\(source)|\(notice.title ?? "")|\(notice.message)"
        // Same text from the same addon isn't repeated within a minute (unless it carries an id to update).
        if notice.id == nil, let last = recent[key], Date().timeIntervalSince(last) < 60 { return }
        recent[key] = Date()
        let defaultDuration: Double = (notice.level == .warning || notice.level == .error) ? 6 : 4
        show(Toast(id: notice.id ?? UUID().uuidString, title: notice.title, message: notice.message,
                   level: notice.level, source: source, icon: icon, progress: notice.progress,
                   duration: notice.duration ?? defaultDuration))
    }

    func show(_ message: String, title: String? = nil, level: AddonNotice.Level = .info) {
        show(Toast(id: UUID().uuidString, title: title, message: message, level: level,
                   source: nil, icon: nil, progress: nil, duration: level == .error ? 6 : 4))
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    private func show(_ toast: Toast) {
        current = toast
        dismissTask?.cancel()
        let id = toast.id
        let duration = toast.duration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self?.current?.id == id else { return }
            self?.current = nil
        }
    }
}
