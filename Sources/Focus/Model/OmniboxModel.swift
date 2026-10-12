import FocusCore
import Foundation
import Observation

/// A row in the address bar's suggestion list.
struct OmniboxSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        /// The page the typed text most likely refers to ("git" → github.com).
        case topHit
        case history
        case favorite
        /// A search for the typed text or for one of the engine's suggestions.
        case search
        /// The typed text, opened as an address.
        case address
    }

    let kind: Kind
    let title: String
    let detail: String?
    let url: URL

    var id: String { url.absoluteString }
}

/// The address bar's editing state and suggestions.
///
/// Lives on the ``Workspace`` so the suggestion list (drawn over the panes)
/// and the keyboard shortcut monitor can reach it, not just the text field.
@MainActor
@Observable
final class OmniboxModel {
    /// What's in the field. Empty at rest (the host is drawn over it).
    var text = ""
    private(set) var isEditing = false
    private(set) var suggestions: [OmniboxSuggestion] = []
    private(set) var selectedIndex = 0
    /// Suggestions only appear once the user changes the prefilled address.
    private(set) var hasTyped = false

    @ObservationIgnored private var prefilledText = ""
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    /// The search engine's latest suggestions and the query they were for.
    @ObservationIgnored private var remote: (query: String, items: [String]) = ("", [])

    private static let maximumRows = 9
    private static let maximumPageRows = 4
    private static let maximumSearchRows = 4

    var isShowingSuggestions: Bool { isEditing && hasTyped && !suggestions.isEmpty }

    var selectedSuggestion: OmniboxSuggestion? {
        guard isShowingSuggestions, suggestions.indices.contains(selectedIndex) else { return nil }
        return suggestions[selectedIndex]
    }

    func beginEditing(with text: String) {
        prefilledText = text
        self.text = text
        hasTyped = false
        isEditing = true
        suggestions = []
        selectedIndex = 0
    }

    func endEditing() {
        remoteTask?.cancel()
        isEditing = false
        hasTyped = false
        text = ""
        suggestions = []
        selectedIndex = 0
    }

    /// Called whenever `text` changes; ignores the prefill itself.
    func textDidChange() {
        guard isEditing, hasTyped || text != prefilledText else { return }
        hasTyped = true
        selectedIndex = 0
        rebuild()
        fetchEngineSuggestions()
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
    }

    func select(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        selectedIndex = index
    }

    // MARK: - Building the list

    private func rebuild() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            suggestions = []
            return
        }
        let previousSelection = suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex].id : nil
        let engine = BrowserSettings.searchEngine

        var rows: [OmniboxSuggestion] = []
        var seen = Set<String>()
        func add(_ row: OmniboxSuggestion) {
            guard rows.count < Self.maximumRows, seen.insert(Self.dedupeKey(row.url)).inserted else { return }
            rows.append(row)
        }

        let matches = SuggestionMatcher.matches(
            for: query,
            in: HistoryStore.shared.suggestionCandidates(),
            limit: Self.maximumPageRows + 1
        )
        var pages = matches[...]
        if let top = matches.first, top.isPrefixMatch, let row = Self.pageRow(for: top, kind: .topHit) {
            add(row)
            pages = pages.dropFirst()
        }

        // What was typed, taken literally.
        if AddressResolver.isAddress(query), let url = AddressResolver.resolve(query, engine: engine) {
            add(OmniboxSuggestion(kind: .address, title: query, detail: "Open address", url: url))
        } else {
            add(OmniboxSuggestion(kind: .search, title: query, detail: "\(engine.displayName) Search", url: engine.searchURL(for: query)))
        }

        for match in pages.prefix(Self.maximumPageRows) {
            if let row = Self.pageRow(for: match, kind: match.candidate.isFavorite ? .favorite : .history) {
                add(row)
            }
        }

        // While a fresh request is in flight, keep showing the previous answers that still fit.
        let lowered = query.lowercased()
        let engineItems = remote.query == query
            ? remote.items
            : remote.items.filter { $0.lowercased().hasPrefix(lowered) }
        for item in engineItems.prefix(Self.maximumSearchRows) where item.lowercased() != lowered {
            add(OmniboxSuggestion(kind: .search, title: item, detail: nil, url: engine.searchURL(for: item)))
        }

        suggestions = rows
        selectedIndex = previousSelection.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    }

    private static func pageRow(for match: SuggestionMatch, kind: OmniboxSuggestion.Kind) -> OmniboxSuggestion? {
        guard let url = URL(string: match.candidate.url) else { return nil }
        let address = shortAddress(url)
        let title = match.candidate.title.isEmpty ? address : match.candidate.title
        return OmniboxSuggestion(kind: kind, title: title, detail: address, url: url)
    }

    /// "https://www.github.com/apple/swift/" → "github.com/apple/swift".
    static func shortAddress(_ url: URL) -> String {
        var text = AddressFormatter.displayHost(for: url)
        let path = url.path
        if path.count > 1 { text += path }
        return text
    }

    private static func dedupeKey(_ url: URL) -> String {
        var key = url.absoluteString.lowercased()
        if let range = key.range(of: "://") { key.removeSubrange(key.startIndex..<range.upperBound) }
        if key.hasPrefix("www.") { key.removeFirst(4) }
        if key.hasSuffix("/") { key.removeLast() }
        return key
    }

    // MARK: - Search engine suggestions

    private func fetchEngineSuggestions() {
        remoteTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BrowserSettings.searchSuggestions, !query.isEmpty, !AddressResolver.isAddress(query),
              let url = BrowserSettings.searchEngine.suggestionsURL(for: query) else { return }

        remoteTask = Task { [weak self] in
            // Wait for a pause in typing before asking.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 3)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !Task.isCancelled, let self else { return }
            self.remote = (query, SearchSuggestionParser.parse(data))
            if self.isEditing, self.hasTyped { self.rebuild() }
        }
    }
}
