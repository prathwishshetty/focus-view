import AppKit
import FocusCore
import Observation

/// The browsing history, saved as JSON in Application Support.
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var history: BrowsingHistory

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static var fileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("Focus", isDirectory: true).appendingPathComponent("History.json")
    }

    private init() {
        if let url = Self.fileURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(BrowsingHistory.self, from: data) {
            history = saved
        } else {
            history = BrowsingHistory()
        }
    }

    var entries: [HistoryEntry] { history.entries }

    func recordVisit(_ url: URL, title: String) {
        guard history.recordVisit(to: url, title: title) else { return }
        scheduleSave()
    }

    func updateTitle(_ title: String, for url: URL) {
        let before = history
        history.updateTitle(title, for: url)
        if history != before { scheduleSave() }
    }

    func clear() {
        history.removeAll()
        scheduleSave()
    }

    /// History and favorites, ready for ``SuggestionMatcher``.
    func suggestionCandidates() -> [SuggestionCandidate] {
        let visited = history.entries.map { SuggestionCandidate($0) }
        let favorites = FavoritesStore.shared.sites.compactMap { site -> SuggestionCandidate? in
            guard let url = site.url else { return nil }
            return SuggestionCandidate(url: url.absoluteString, title: site.name, isFavorite: true)
        }
        return visited + favorites
    }

    /// Asks before clearing; used from the History menu.
    func confirmAndClear() {
        let alert = NSAlert()
        alert.messageText = "Clear browsing history?"
        alert.informativeText = "This removes every page from your history and address bar suggestions."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { clear() }
    }

    // MARK: - Saving

    /// Visits come in bursts (redirects, title changes); save once things settle.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
