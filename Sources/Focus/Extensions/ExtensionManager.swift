import AppKit
import Observation
import WebKit

/// A web extension the user added, as saved in `UserDefaults`.
struct InstalledExtension: Codable, Identifiable, Hashable {
    /// Stable for the life of the install: names its folder, and becomes the
    /// extension's `runtime.id` and the key for its storage, so settings survive updates.
    var id: String
    var isEnabled = true
    var addedAt = Date()
    /// Optional permissions and websites the user allowed when the extension asked at runtime.
    var grantedPermissions: [String] = []
    var grantedMatchPatterns: [String] = []
}

/// Loads web extensions (WebKit's `WKWebExtension`) into every pane.
///
/// Extensions are unpacked into Application Support and loaded at launch.
/// Each pane appears to extensions as a tab in a single window, the workspace.
@MainActor
@Observable
final class ExtensionManager {
    static let shared = ExtensionManager()

    private(set) var installed: [InstalledExtension] {
        didSet { save() }
    }

    /// Parsed extensions, by install ID (also for disabled ones, to show their name).
    private(set) var extensions: [String: WKWebExtension] = [:]
    /// Loaded (enabled) extensions, by install ID.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Why an extension couldn't be read or loaded, by install ID.
    private(set) var loadErrors: [String: String] = [:]
    /// Bumped when an extension changes its toolbar button (icon, badge, title).
    private(set) var actionRevision = 0

    /// Shared by every pane's web view configuration.
    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored private let delegate = ExtensionControllerDelegate()
    @ObservationIgnored private(set) weak var workspace: Workspace?
    @ObservationIgnored let window = ExtensionWindow()
    @ObservationIgnored private var tabs: [PaneID: ExtensionTab] = [:]
    /// Each extension's toolbar button, to anchor its popup.
    @ObservationIgnored private var actionAnchors: [String: WeakView] = [:]
    @ObservationIgnored private var didLoad = false

    private init() {
        // The default configuration keeps extension storage on disk.
        controller = WKWebExtensionController()
        if let data = UserDefaults.standard.data(forKey: BrowserSettings.Key.extensions),
           let saved = try? JSONDecoder().decode([InstalledExtension].self, from: data) {
            installed = saved
        } else {
            installed = []
        }
        delegate.manager = self
        controller.delegate = delegate
    }

    /// Where unpacked extensions live, one folder per install ID.
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Focus", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }

    static func folder(for id: String) -> URL? {
        directory?.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Launch

    /// Reads and loads every installed extension. Called once at launch.
    func loadInstalled() async {
        guard !didLoad else { return }
        didLoad = true
        for record in installed {
            await read(record)
            if record.isEnabled { activate(record.id) }
        }
    }

    /// Parses an installed extension's files.
    private func read(_ record: InstalledExtension) async {
        guard let folder = Self.folder(for: record.id) else { return }
        do {
            extensions[record.id] = try await WKWebExtension(resourceBaseURL: folder)
            loadErrors[record.id] = nil
        } catch {
            extensions[record.id] = nil
            loadErrors[record.id] = error.localizedDescription
        }
    }

    /// Loads a parsed extension into the browser.
    private func activate(_ id: String) {
        guard contexts[id] == nil, let webExtension = extensions[id],
              let record = installed.first(where: { $0.id == id }) else { return }
        let context = WKWebExtensionContext(for: webExtension)
        // A stable identity keeps the extension's storage and settings across launches.
        context.uniqueIdentifier = id
        if let baseURL = URL(string: "webkit-extension://\(id)/") {
            context.baseURL = baseURL
        }
        context.isInspectable = BrowserSettings.webInspector
        context.inspectionName = webExtension.displayName
        grantPermissions(to: context, record: record)
        do {
            try controller.load(context)
            contexts[id] = context
            loadErrors[id] = nil
        } catch {
            loadErrors[id] = error.localizedDescription
        }
    }

    private func deactivate(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        actionAnchors[id] = nil
    }

    /// Adding an extension is the user's consent to what its manifest asks for;
    /// optional permissions are restored from what the user allowed before.
    private func grantPermissions(to context: WKWebExtensionContext, record: InstalledExtension) {
        let webExtension = context.webExtension
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        for permission in webExtension.optionalPermissions where record.grantedPermissions.contains(permission.rawValue) {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.optionalPermissionMatchPatterns where record.grantedMatchPatterns.contains(pattern.string) {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    /// Remembers the optional permissions an extension holds, so they're granted again next launch.
    func rememberPermissions(of context: WKWebExtensionContext) {
        guard let index = installed.firstIndex(where: { $0.id == context.uniqueIdentifier }) else { return }
        // Only lasting grants: activeTab and similar grants expire on their own.
        let lasting = Date().addingTimeInterval(60 * 60 * 24 * 365)
        let optional = context.webExtension.optionalPermissions
        let optionalPatterns = Set(context.webExtension.optionalPermissionMatchPatterns.map(\.string))
        let permissions = context.grantedPermissions
            .filter { optional.contains($0.key) && $0.value > lasting }
            .map(\.key.rawValue)
        let patterns = context.grantedPermissionMatchPatterns
            .filter { optionalPatterns.contains($0.key.string) && $0.value > lasting }
            .map(\.key.string)
        var record = installed[index]
        record.grantedPermissions = permissions.sorted()
        record.grantedMatchPatterns = patterns.sorted()
        if record != installed[index] { installed[index] = record }
    }

    func saveNow() {
        for context in contexts.values { rememberPermissions(of: context) }
    }

    // MARK: - Managing

    func displayName(for id: String) -> String {
        extensions[id]?.displayName ?? extensions[id]?.displayShortName ?? "Extension"
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].isEnabled = enabled
        if enabled {
            activate(id)
        } else {
            if let context = contexts[id] { rememberPermissions(of: context) }
            deactivate(id)
        }
    }

    /// Unloads an extension, deletes its files and its stored data.
    func remove(_ id: String) {
        let finish = { [self] in
            deactivate(id)
            installed.removeAll { $0.id == id }
            extensions[id] = nil
            loadErrors[id] = nil
            if let folder = Self.folder(for: id) { try? FileManager.default.removeItem(at: folder) }
        }
        guard let context = contexts[id] else { return finish() }
        let types = WKWebExtensionController.allExtensionDataTypes
        controller.fetchDataRecord(ofTypes: types, for: context) { [controller] record in
            guard let record else { return finish() }
            controller.removeData(ofTypes: types, from: [record]) { finish() }
        }
    }

    /// Re-reads an extension's files from disk and loads it again (after editing an unpacked extension).
    func reload(_ id: String) async {
        guard let record = installed.first(where: { $0.id == id }) else { return }
        if let context = contexts[id] { rememberPermissions(of: context) }
        deactivate(id)
        await read(record)
        if let fresh = installed.first(where: { $0.id == id }), fresh.isEnabled { activate(id) }
    }

    /// Installs an unpacked extension folder already moved into place under `id`.
    /// Updating keeps the install's ID, so its settings and permissions carry over.
    func didInstall(_ webExtension: WKWebExtension, id: String) {
        extensions[id] = webExtension
        loadErrors[id] = nil
        if installed.contains(where: { $0.id == id }) {
            if let index = installed.firstIndex(where: { $0.id == id }), installed[index].isEnabled { activate(id) }
        } else {
            installed.append(InstalledExtension(id: id))
            activate(id)
        }
    }

    /// Unloads an extension before its files are replaced by an update.
    func prepareForUpdate(_ id: String) {
        if let context = contexts[id] { rememberPermissions(of: context) }
        deactivate(id)
    }

    /// The installed extension with this name, so adding it again updates it.
    func installedID(named name: String?) -> String? {
        guard let name else { return nil }
        return installed.first { extensions[$0.id]?.displayName == name }?.id
    }

    /// Opens an extension's settings page in a new split.
    func openOptions(for id: String) {
        guard let url = contexts[id]?.optionsPageURL, let workspace else { return }
        workspace.openPaneForExtension(url, focus: true)
        workspace.mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        UserDefaults.standard.set(data, forKey: BrowserSettings.Key.extensions)
    }

    // MARK: - Extension pages

    /// The loaded extension a `webkit-extension://` address belongs to.
    func context(forExtensionURL url: URL) -> WKWebExtensionContext? {
        guard url.scheme?.lowercased() == "webkit-extension" else { return nil }
        return controller.extensionContext(for: url)
    }

    /// WebKit requires an extension's own pages to load in a web view made from its configuration.
    func webViewConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard let configuration = context(forExtensionURL: url)?.webViewConfiguration else { return nil }
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    // MARK: - Toolbar

    /// Enabled extensions with a toolbar button, in the order they were added.
    var toolbarExtensionIDs: [String] {
        installed.compactMap { record in
            guard let context = contexts[record.id] else { return nil }
            let manifest = context.webExtension.manifest
            return manifest["action"] != nil || manifest["browser_action"] != nil ? record.id : nil
        }
    }

    func action(for id: String, pane: Pane?) -> WKWebExtension.Action? {
        contexts[id]?.action(for: pane.map { tab(for: $0) })
    }

    /// Clicks an extension's toolbar button: shows its popup, or tells it it was clicked.
    func performAction(for id: String, pane: Pane?) {
        contexts[id]?.performAction(for: pane.map { tab(for: $0) })
    }

    func registerActionAnchor(_ view: NSView, for id: String) {
        actionAnchors[id] = WeakView(view)
    }

    fileprivate func actionDidChange() {
        actionRevision &+= 1
    }

    fileprivate func present(_ action: WKWebExtension.Action, for id: String) {
        guard let popover = action.popupPopover else { return }
        if let anchor = actionAnchors[id]?.view, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = workspace?.mainWindow?.contentView {
            // No button on screen (toolbar overflow): hang it from the top right corner.
            let corner = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 1, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
    }

    // MARK: - Tabs & window

    /// Called once the workspace exists, so extensions can see its panes.
    func attach(_ workspace: Workspace) {
        self.workspace = workspace
        window.workspace = workspace
        controller.didOpenWindow(window)
        for pane in workspace.extensionTabOrder { controller.didOpenTab(tab(for: pane)) }
        controller.didActivateTab(tab(for: workspace.focusedPane))
        controller.didFocusWindow(window)
    }

    func tab(for pane: Pane) -> ExtensionTab {
        if let tab = tabs[pane.id] { return tab }
        let tab = ExtensionTab(pane: pane)
        tabs[pane.id] = tab
        return tab
    }

    func paneOpened(_ pane: Pane) {
        guard workspace != nil, tabs[pane.id] == nil else { return }
        controller.didOpenTab(tab(for: pane))
    }

    func paneClosed(_ id: PaneID) {
        guard let tab = tabs.removeValue(forKey: id) else { return }
        controller.didCloseTab(tab)
    }

    func focusChanged(from previous: PaneID, to current: PaneID) {
        guard previous != current, let pane = workspace?.pane(current) else { return }
        controller.didActivateTab(tab(for: pane), previousActiveTab: tabs[previous])
    }

    func pane(_ pane: Pane, didChange properties: WKWebExtension.TabChangedProperties) {
        guard let tab = tabs[pane.id] else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }
}

// MARK: - Controller delegate

/// Answers WebKit's questions about windows and tabs, opens what extensions
/// ask to open, and asks the user before granting extra permissions.
@MainActor
final class ExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    weak var manager: ExtensionManager?

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let manager, manager.workspace != nil else { return [] }
        return [manager.window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let manager, manager.workspace != nil else { return nil }
        return manager.window
    }

    /// `tabs.create` opens a split beside the focused pane.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let manager, let workspace = manager.workspace else { return completionHandler(nil, nil) }
        let pane = workspace.openPaneForExtension(configuration.url, focus: configuration.shouldBeActive)
        completionHandler(manager.tab(for: pane), nil)
    }

    /// There's one window, so `windows.create` opens its pages as splits.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard let manager, let workspace = manager.workspace else { return completionHandler(nil, nil) }
        let urls: [URL?] = configuration.tabURLs.isEmpty ? [nil] : configuration.tabURLs
        for url in urls {
            workspace.openPaneForExtension(url, focus: configuration.shouldBeFocused)
        }
        completionHandler(manager.window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        manager?.openOptions(for: extensionContext.uniqueIdentifier)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        manager?.present(action, for: context.uniqueIdentifier)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        manager?.actionDidChange()
    }

    // MARK: Permission prompts

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let lines = permissions.map { ExtensionPermissionText.describe($0) }
        ask(extensionContext, toAllow: lines) { [weak self] allowed in
            completionHandler(allowed ? permissions : [], nil)
            self?.remember(extensionContext)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let hosts = Set(urls.compactMap(\.host)).sorted()
        ask(extensionContext, toAllow: ["Read and change your data on \(hosts.joined(separator: ", "))"]) { [weak self] allowed in
            completionHandler(allowed ? urls : [], nil)
            self?.remember(extensionContext)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        ask(extensionContext, toAllow: [ExtensionPermissionText.describe(matchPatterns)]) { [weak self] allowed in
            completionHandler(allowed ? matchPatterns : [], nil)
            self?.remember(extensionContext)
        }
    }

    private func remember(_ context: WKWebExtensionContext) {
        // WebKit records the grant after the completion handler returns.
        DispatchQueue.main.async { [weak self] in self?.manager?.rememberPermissions(of: context) }
    }

    private func ask(_ context: WKWebExtensionContext, toAllow lines: [String], completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let name = context.webExtension.displayName ?? "This extension"
        alert.messageText = "Allow “\(name)” to do more?"
        alert.informativeText = "It's asking to:\n" + lines.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if let window = manager?.workspace?.mainWindow {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

// MARK: - Describing permissions

/// Plain-language descriptions of what an extension can do, for prompts and Settings.
enum ExtensionPermissionText {
    static func describe(_ permission: WKWebExtension.Permission) -> String {
        switch permission.rawValue {
        case "activeTab": "Access the page you're on when you click its button"
        case "alarms": "Schedule work in the background"
        case "clipboardWrite": "Copy to the clipboard"
        case "contextMenus", "menus": "Add items to right-click menus"
        case "cookies": "Read and change cookies"
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess": "Block and change content on websites"
        case "declarativeNetRequestFeedback": "See what it blocked"
        case "nativeMessaging": "Talk to other apps"
        case "scripting": "Run scripts on websites"
        case "storage", "unlimitedStorage": "Store data"
        case "tabs": "See the address and title of every pane"
        case "webNavigation": "See the pages you visit as you browse"
        case "webRequest": "See network requests websites make"
        default: permission.rawValue
        }
    }

    static func describe(_ patterns: Set<WKWebExtension.MatchPattern>) -> String {
        if patterns.contains(where: { $0.matchesAllURLs || $0.matchesAllHosts }) {
            return "Read and change your data on all websites"
        }
        let hosts = Set(patterns.compactMap(\.host)).sorted()
        return "Read and change your data on \(hosts.joined(separator: ", "))"
    }

    /// Everything an extension's manifest asks for, one line each.
    static func summary(of webExtension: WKWebExtension) -> [String] {
        var lines = Set(webExtension.requestedPermissions.map { describe($0) }).sorted()
        let patterns = webExtension.requestedPermissionMatchPatterns
        if !patterns.isEmpty { lines.insert(describe(patterns), at: 0) }
        return lines
    }
}
