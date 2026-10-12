import Foundation

/// A page the address bar can suggest: something from history or a favorite.
public struct SuggestionCandidate: Hashable, Sendable {
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisited: Date?
    public var isFavorite: Bool

    public init(url: String, title: String, visitCount: Int = 0, lastVisited: Date? = nil, isFavorite: Bool = false) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisited = lastVisited
        self.isFavorite = isFavorite
    }

    public init(_ entry: HistoryEntry) {
        self.init(url: entry.url, title: entry.title, visitCount: entry.visitCount, lastVisited: entry.lastVisited)
    }
}

public struct SuggestionMatch: Hashable, Sendable {
    public var candidate: SuggestionCandidate
    public var score: Double
    /// What was typed is the start of this page's address ("git" → github.com),
    /// so it's a good guess for where the user is going.
    public var isPrefixMatch: Bool
}

/// Ranks history and favorites against what's typed in the address bar.
///
/// A page matches when every typed word starts its host, a word in its address
/// or a word in its title (or, for longer words, appears anywhere). Matches are
/// ordered by how well they match, then by how often and how recently the page
/// was visited, with favorites given a boost.
public enum SuggestionMatcher {
    public static func matches(
        for query: String,
        in candidates: [SuggestionCandidate],
        limit: Int,
        now: Date = Date()
    ) -> [SuggestionMatch] {
        let query = normalizedQuery(query)
        guard !query.isEmpty, limit > 0 else { return [] }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)

        var best: [String: SuggestionMatch] = [:]
        for candidate in candidates {
            guard var match = match(terms: terms, query: query, candidate: candidate) else { continue }
            match.score += frecency(of: candidate, now: now)

            let key = dedupeKey(candidate.url)
            if let existing = best[key] {
                // The same page from history and favorites: keep one, with the best of both.
                var merged = existing.score >= match.score ? existing : match
                merged.candidate.isFavorite = existing.candidate.isFavorite || match.candidate.isFavorite
                merged.isPrefixMatch = existing.isPrefixMatch || match.isPrefixMatch
                best[key] = merged
            } else {
                best[key] = match
            }
        }

        return best.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let left = lhs.candidate.lastVisited ?? .distantPast
                let right = rhs.candidate.lastVisited ?? .distantPast
                if left != right { return left > right }
                return lhs.candidate.url.count < rhs.candidate.url.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func match(terms: [String], query: String, candidate: SuggestionCandidate) -> SuggestionMatch? {
        let address = strippedAddress(candidate.url)
        let host = address.prefix { $0 != "/" && $0 != "?" && $0 != ":" }
        let isRootPage = address.count == host.count

        // One word typed that starts the address: the strongest kind of match.
        if terms.count == 1 {
            let rootBonus: Double = isRootPage ? 15 : 0
            if host.hasPrefix(query) {
                return SuggestionMatch(candidate: candidate, score: 100 + rootBonus, isPrefixMatch: true)
            }
            if address.hasPrefix(query) {
                return SuggestionMatch(candidate: candidate, score: 90, isPrefixMatch: true)
            }
        }

        let addressWords = words(in: address)
        let title = candidate.title.lowercased()
        let titleWords = words(in: title)
        var total: Double = 0
        for term in terms {
            if addressWords.contains(where: { $0.hasPrefix(term) }) {
                total += 50
            } else if titleWords.contains(where: { $0.hasPrefix(term) }) {
                total += 40
            } else if term.count >= 3, address.contains(term) || title.contains(term) {
                total += 15
            } else {
                return nil
            }
        }
        return SuggestionMatch(candidate: candidate, score: total / Double(terms.count), isPrefixMatch: false)
    }

    /// Frequently and recently visited pages, and favorites, rank higher.
    private static func frecency(of candidate: SuggestionCandidate, now: Date) -> Double {
        var score = min(log2(Double(candidate.visitCount) + 1) * 10, 40)
        if let visited = candidate.lastVisited {
            let age = now.timeIntervalSince(visited)
            if age < 86_400 { score += 20 } else if age < 7 * 86_400 { score += 12 } else if age < 30 * 86_400 { score += 6 }
        }
        if candidate.isFavorite { score += 30 }
        return score
    }

    /// Lowercased, without the scheme or a leading "www.", so "https://www.gith" matches like "gith".
    static func normalizedQuery(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// "https://www.github.com/a/b" → "github.com/a/b".
    static func strippedAddress(_ url: String) -> String {
        var text = url.lowercased()
        if let range = text.range(of: "://") { text.removeSubrange(text.startIndex..<range.upperBound) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func dedupeKey(_ url: String) -> String {
        strippedAddress(url)
    }

    private static func words(in text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }
}
