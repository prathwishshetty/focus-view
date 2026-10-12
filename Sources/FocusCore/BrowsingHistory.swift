import Foundation

/// A page in the browsing history.
public struct HistoryEntry: Codable, Hashable, Sendable {
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisited: Date

    public init(url: String, title: String, visitCount: Int = 1, lastVisited: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisited = lastVisited
    }
}

/// Visited pages, most recent first, one entry per address.
public struct BrowsingHistory: Codable, Sendable, Equatable {
    public private(set) var entries: [HistoryEntry]
    /// The oldest entries are dropped beyond this many.
    public var limit: Int

    /// Revisiting the newest entry within this window (a redirect, a reload, a
    /// page that rewrites its own address) doesn't count as a new visit.
    static let repeatWindow: TimeInterval = 5

    public init(entries: [HistoryEntry] = [], limit: Int = 5000) {
        self.entries = entries
        self.limit = limit
    }

    /// The address history is keyed by: http(s) only, without the fragment.
    public static func key(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.string
    }

    /// Records a visit. Returns false for addresses history doesn't keep.
    @discardableResult
    public mutating func recordVisit(to url: URL, title: String, at date: Date = Date()) -> Bool {
        guard let key = Self.key(for: url) else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = entries.firstIndex(where: { $0.url == key }) {
            var entry = entries.remove(at: index)
            let isRepeat = index == 0 && date.timeIntervalSince(entry.lastVisited) < Self.repeatWindow
            if !isRepeat { entry.visitCount += 1 }
            entry.lastVisited = date
            if !title.isEmpty { entry.title = title }
            entries.insert(entry, at: 0)
        } else {
            entries.insert(HistoryEntry(url: key, title: title, lastVisited: date), at: 0)
            if entries.count > limit { entries.removeLast(entries.count - limit) }
        }
        return true
    }

    /// Pages often set their title after loading; keep the entry's title current.
    public mutating func updateTitle(_ title: String, for url: URL) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let key = Self.key(for: url),
              let index = entries.firstIndex(where: { $0.url == key }) else { return }
        entries[index].title = title
    }

    public mutating func remove(_ url: String) {
        entries.removeAll { $0.url == url }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
