import Foundation

/// A page in the browsing history.
public struct HistoryEntry: Codable, Hashable, Sendable {
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisited: Date
    /// When the page was visited: the latest visit of each day, newest first.
    public var visits: [Date]

    public init(url: String, title: String, visitCount: Int = 1, lastVisited: Date, visits: [Date]? = nil) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisited = lastVisited
        self.visits = visits ?? [lastVisited]
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, visitCount, lastVisited, visits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        visitCount = try container.decode(Int.self, forKey: .visitCount)
        lastVisited = try container.decode(Date.self, forKey: .lastVisited)
        // History saved before visits were kept only knows the last one.
        visits = try container.decodeIfPresent([Date].self, forKey: .visits) ?? [lastVisited]
    }
}

/// One row of the history page: a page and its latest visit on one day.
public struct HistoryVisit: Hashable, Sendable {
    public var url: String
    public var title: String
    public var date: Date

    public init(url: String, title: String, date: Date) {
        self.url = url
        self.title = title
        self.date = date
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
    /// Each page remembers the days it was visited on, up to this many.
    static let visitDaysLimit = 90

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
    public mutating func recordVisit(to url: URL, title: String, at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let key = Self.key(for: url) else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = entries.firstIndex(where: { $0.url == key }) {
            var entry = entries.remove(at: index)
            let isRepeat = index == 0 && date.timeIntervalSince(entry.lastVisited) < Self.repeatWindow
            if !isRepeat { entry.visitCount += 1 }
            entry.lastVisited = date
            if let latest = entry.visits.first, calendar.isDate(latest, inSameDayAs: date) {
                entry.visits[0] = date
            } else {
                entry.visits.insert(date, at: 0)
                if entry.visits.count > Self.visitDaysLimit { entry.visits.removeLast(entry.visits.count - Self.visitDaysLimit) }
            }
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

    /// Every page once per day it was visited, newest first: the history page's rows.
    public var visits: [HistoryVisit] {
        entries
            .flatMap { entry in entry.visits.map { HistoryVisit(url: entry.url, title: entry.title, date: $0) } }
            .sorted { $0.date > $1.date }
    }

    /// Removes a page's visit on the day of `date` (one row of the history page).
    /// A page with no visits left leaves history altogether.
    public mutating func removeVisit(to url: String, onSameDayAs date: Date, calendar: Calendar = .current) {
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return }
        var entry = entries.remove(at: index)
        entry.visits.removeAll { calendar.isDate($0, inSameDayAs: date) }
        guard let latest = entry.visits.first else { return }
        // Its last visit may now be older; keep the newest-first order.
        entry.lastVisited = latest
        let position = entries.firstIndex { $0.lastVisited < latest } ?? entries.endIndex
        entries.insert(entry, at: position)
    }

    public mutating func remove(_ url: String) {
        entries.removeAll { $0.url == url }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
