import Foundation

/// Search providers the omnibox can fall back to when input isn't an address.
public enum SearchEngine: String, CaseIterable, Codable, Sendable {
    case google
    case duckDuckGo
    case bing
    case kagi

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        }
    }

    private var base: String {
        switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .kagi: "https://kagi.com/search"
        }
    }

    public func searchURL(for query: String) -> URL {
        URL(string: "\(base)?q=\(Self.encode(query))")!
    }

    /// Where to fetch completions for a partial query (OpenSearch suggestion JSON).
    public func suggestionsURL(for query: String) -> URL? {
        let query = Self.encode(query)
        return switch self {
        case .google: URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=\(query)")
        case .duckDuckGo: URL(string: "https://duckduckgo.com/ac/?type=list&q=\(query)")
        case .bing: URL(string: "https://api.bing.com/osjson.aspx?query=\(query)")
        case .kagi: URL(string: "https://kagi.com/api/autosuggest?q=\(query)")
        }
    }

    /// URLComponents leaves "+" and "&" partially unescaped, which search
    /// engines would misread, so queries are encoded by hand.
    static func encode(_ query: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }
}

/// Reads search engine suggestions in the OpenSearch format: `["query", ["one", "two", …]]`.
public enum SearchSuggestionParser {
    public static func parse(_ data: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: data))
            // Some endpoints answer in Latin-1 despite being asked for UTF-8.
            ?? String(data: data, encoding: .isoLatin1)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let array = json as? [Any], array.count >= 2, let items = array[1] as? [Any] else { return [] }
        var seen = Set<String>()
        return items.compactMap { item in
            guard let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  seen.insert(text.lowercased()).inserted else { return nil }
            return text
        }
    }
}

/// Turns whatever the user typed into a URL: either the address they meant or a search.
public enum AddressResolver {
    /// Schemes we accept verbatim when typed with "://".
    static let hierarchicalSchemes: Set<String> = ["http", "https", "file", "ftp", "focus"]
    /// Schemes we accept verbatim when typed with a bare ":".
    static let opaqueSchemes: Set<String> = ["about", "data", "mailto", "tel", "view-source"]

    public static func resolve(_ input: String, engine: SearchEngine = .google) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = explicitURL(text) { return url }
        if !text.contains(where: \.isWhitespace), looksLikeHost(text),
           let url = URL(string: (isLocal(text) ? "http://" : "https://") + text), url.host != nil {
            return url
        }
        return engine.searchURL(for: text)
    }

    /// Whether `input` would open as an address rather than run a search.
    public static func isAddress(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if explicitURL(text) != nil { return true }
        return !text.contains(where: \.isWhitespace) && looksLikeHost(text)
            && URL(string: (isLocal(text) ? "http://" : "https://") + text)?.host != nil
    }

    private static func explicitURL(_ text: String) -> URL? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon].lowercased()
        let rest = text[text.index(after: colon)...]
        if hierarchicalSchemes.contains(scheme), rest.hasPrefix("//") {
            return URL(string: text) ?? URL(string: text.replacingOccurrences(of: " ", with: "%20"))
        }
        if opaqueSchemes.contains(scheme), !rest.isEmpty {
            return URL(string: text)
        }
        return nil
    }

    /// The host portion of a scheme-less address, e.g. "example.com" in "example.com:8080/path".
    private static func hostPart(_ text: String) -> Substring {
        let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex
        var authority = text[..<end]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("[") { return authority } // IPv6 literal
        if let colon = authority.lastIndex(of: ":") {
            let port = authority[authority.index(after: colon)...]
            guard port.allSatisfy(\.isNumber) else { return "" }
            authority = authority[..<colon]
        }
        return authority
    }

    private static func isLocal(_ text: String) -> Bool {
        let host = hostPart(text).lowercased()
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || isIPv4(host)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part) else { return false }
            return value <= 255
        }
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        let host = hostPart(text)
        if host.hasPrefix("[") && host.hasSuffix("]") { return true }
        let lower = host.lowercased()
        if lower == "localhost" || isIPv4(lower) { return true }
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard labels.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return false }
        // A top-level domain has at least two letters ("com", "io", "dev", "xn--…").
        guard let tld = labels.last, tld.count >= 2, tld.contains(where: \.isLetter) else { return false }
        return true
    }
}

/// Friendly, compact representations of URLs for the UI.
public enum AddressFormatter {
    /// "https://www.example.com/path" → "example.com".
    public static func displayHost(for url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        // The browser's own pages show their whole address, like "focus://history".
        if url.scheme?.lowercased() == "focus", let host = url.host, !host.isEmpty { return "focus://\(host)" }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The full address shown while editing. `about:blank` shows as empty.
    public static func editableString(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }
}
