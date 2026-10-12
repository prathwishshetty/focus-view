import AppKit
import FocusCore
import Observation

/// Every user setting, stored in `UserDefaults`.
///
/// Views bind with `@AppStorage(BrowserSettings.Key.…)`; model code reads the
/// static accessors below. Defaults live in one place (`registerDefaults`).
enum BrowserSettings {
    enum Key {
        static let searchEngine = "searchEngine"
        static let searchSuggestions = "search.engineSuggestions"
        static let newPaneBehavior = "newPaneBehavior"
        static let homepage = "homepage"
        static let appearance = "appearance"
        static let dimUnfocusedPanes = "panes.dimUnfocused"
        static let showFocusRing = "panes.showFocusRing"
        static let showClock = "newTab.showClock"
        static let showFavorites = "newTab.showFavorites"
        static let showShortcutHints = "newTab.showShortcutHints"
        static let shrinkToFit = "web.shrinkToFit"
        static let defaultZoom = "web.defaultZoom"
        static let blockPopups = "web.blockPopups"
        static let webInspector = "web.inspector"
        static let favorites = "favorites"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.searchEngine: SearchEngine.google.rawValue,
            Key.searchSuggestions: true,
            Key.newPaneBehavior: NewPaneBehavior.newTabPage.rawValue,
            Key.homepage: "",
            Key.appearance: AppearanceMode.system.rawValue,
            Key.dimUnfocusedPanes: true,
            Key.showFocusRing: true,
            Key.showClock: true,
            Key.showFavorites: true,
            Key.showShortcutHints: true,
            Key.shrinkToFit: true,
            Key.defaultZoom: 1.0,
            Key.blockPopups: false,
            Key.webInspector: true,
        ])
    }

    private static var store: UserDefaults { .standard }

    static var searchEngine: SearchEngine {
        SearchEngine(rawValue: store.string(forKey: Key.searchEngine) ?? "") ?? .google
    }

    /// Whether the address bar asks the search engine for suggestions as you type.
    static var searchSuggestions: Bool { store.bool(forKey: Key.searchSuggestions) }

    static var newPaneBehavior: NewPaneBehavior {
        NewPaneBehavior(rawValue: store.string(forKey: Key.newPaneBehavior) ?? "") ?? .newTabPage
    }

    /// The homepage to open in new panes, if that's what the user chose.
    static var homepageURL: URL? {
        guard newPaneBehavior == .homepage else { return nil }
        return AddressResolver.resolve(store.string(forKey: Key.homepage) ?? "", engine: searchEngine)
    }

    static var appearance: AppearanceMode {
        AppearanceMode(rawValue: store.string(forKey: Key.appearance) ?? "") ?? .system
    }

    static var shrinkToFit: Bool { store.bool(forKey: Key.shrinkToFit) }
    static var defaultZoom: Double {
        let zoom = store.double(forKey: Key.defaultZoom)
        return zoom > 0 ? zoom : 1
    }
    static var blockPopups: Bool { store.bool(forKey: Key.blockPopups) }
    static var webInspector: Bool { store.bool(forKey: Key.webInspector) }
}

enum NewPaneBehavior: String, CaseIterable {
    case newTabPage
    case homepage

    var title: String {
        switch self {
        case .newTabPage: "New Tab Page"
        case .homepage: "Homepage"
        }
    }
}

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

// MARK: - Favorites

/// A site shown on the new tab page.
struct FavoriteSite: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    /// What the user typed; resolved like the omnibox does.
    var address: String

    var url: URL? { AddressResolver.resolve(address) }
    var host: String { url?.host ?? name }

    static let defaults: [FavoriteSite] = [
        FavoriteSite(name: "Apple", address: "https://www.apple.com"),
        FavoriteSite(name: "GitHub", address: "https://github.com"),
        FavoriteSite(name: "YouTube", address: "https://www.youtube.com"),
        FavoriteSite(name: "Wikipedia", address: "https://www.wikipedia.org"),
        FavoriteSite(name: "Hacker News", address: "https://news.ycombinator.com"),
        FavoriteSite(name: "Reddit", address: "https://www.reddit.com"),
        FavoriteSite(name: "Figma", address: "https://www.figma.com"),
        FavoriteSite(name: "Claude", address: "https://claude.ai"),
    ]
}

/// The user's favorites, persisted as JSON in `UserDefaults`.
@MainActor
@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    var sites: [FavoriteSite] {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: BrowserSettings.Key.favorites),
           let saved = try? JSONDecoder().decode([FavoriteSite].self, from: data) {
            sites = saved
        } else {
            sites = FavoriteSite.defaults
        }
    }

    func restoreDefaults() {
        sites = FavoriteSite.defaults
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        UserDefaults.standard.set(data, forKey: BrowserSettings.Key.favorites)
    }
}
