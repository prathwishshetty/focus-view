import FocusCore
import SwiftUI
import WebKit

/// The app's Settings window (⌘,), laid out like macOS's own settings panes.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Appearance", systemImage: "paintbrush") {
                AppearanceSettings()
            }
            Tab("Websites", systemImage: "globe") {
                WebsiteSettings()
            }
            Tab("Favorites", systemImage: "star") {
                FavoritesSettings()
            }
            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsSettings()
            }
        }
        .frame(width: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(BrowserSettings.Key.searchEngine) private var searchEngine: SearchEngine = .google
    @AppStorage(BrowserSettings.Key.searchSuggestions) private var searchSuggestions = true
    @AppStorage(BrowserSettings.Key.newPaneBehavior) private var newPaneBehavior: NewPaneBehavior = .newTabPage
    @AppStorage(BrowserSettings.Key.homepage) private var homepage = ""

    var body: some View {
        Form {
            Section {
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Toggle("Include search engine suggestions", isOn: $searchSuggestions)
            } footer: {
                Text("Used when what you type in the address bar isn't a web address. With suggestions on, what you type is sent to \(searchEngine.displayName) as you type; history and favorites are always suggested.")
                    .settingsFootnote()
            }

            Section {
                Picker("New panes open with", selection: $newPaneBehavior) {
                    ForEach(NewPaneBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                TextField("Homepage", text: $homepage, prompt: Text("example.com"))
                    .disabled(newPaneBehavior != .homepage)
            } header: {
                Text("New Panes")
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(BrowserSettings.Key.appearance) private var appearance: AppearanceMode = .system
    @AppStorage(BrowserSettings.Key.dimUnfocusedPanes) private var dimUnfocusedPanes = true
    @AppStorage(BrowserSettings.Key.showFocusRing) private var showFocusRing = true
    @AppStorage(BrowserSettings.Key.showClock) private var showClock = true
    @AppStorage(BrowserSettings.Key.showFavorites) private var showFavorites = true
    @AppStorage(BrowserSettings.Key.showShortcutHints) private var showShortcutHints = true

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Panes") {
                Toggle("Dim panes that don't have focus", isOn: $dimUnfocusedPanes)
                Toggle("Outline the focused pane", isOn: $showFocusRing)
            }

            Section("New Tab Page") {
                Toggle("Show clock", isOn: $showClock)
                Toggle("Show favorites", isOn: $showFavorites)
                Toggle("Show keyboard shortcut hints", isOn: $showShortcutHints)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
        .onChange(of: appearance) { _, mode in mode.apply() }
    }
}

// MARK: - Websites

private struct WebsiteSettings: View {
    @AppStorage(BrowserSettings.Key.shrinkToFit) private var shrinkToFit = true
    @AppStorage(BrowserSettings.Key.defaultZoom) private var defaultZoom = 1.0
    @AppStorage(BrowserSettings.Key.blockPopups) private var blockPopups = false
    @AppStorage(BrowserSettings.Key.webInspector) private var webInspector = true

    @State private var isConfirmingClear = false
    @State private var isConfirmingClearHistory = false
    @State private var clearState: ClearState = .idle

    private enum ClearState { case idle, clearing, done }

    private static let zoomLevels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Form {
            Section {
                Picker("Default page zoom", selection: $defaultZoom) {
                    ForEach(Self.zoomLevels, id: \.self) { level in
                        Text(level.formatted(.percent.precision(.fractionLength(0)))).tag(level)
                    }
                }
                Toggle("Shrink wide pages to fit narrow panes", isOn: $shrinkToFit)
            } footer: {
                Text("Pages that can't get narrower than a pane are zoomed out just enough to fit, instead of scrolling sideways.")
                    .settingsFootnote()
            }

            Section {
                Toggle("Block pop-up windows", isOn: $blockPopups)
                Toggle("Allow Web Inspector", isOn: $webInspector)
            } footer: {
                Text("Links that open in a new window always open as a new split. Changes apply to pages opened afterwards.")
                    .settingsFootnote()
            }

            Section("Privacy") {
                LabeledContent("History") {
                    Button("Clear History…") { isConfirmingClearHistory = true }
                        .disabled(HistoryStore.shared.entries.isEmpty)
                }
                LabeledContent("Website data") {
                    HStack(spacing: 8) {
                        switch clearState {
                        case .idle: EmptyView()
                        case .clearing: ProgressView().controlSize(.small)
                        case .done:
                            Label("Cleared", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        Button("Clear Browsing Data…") { isConfirmingClear = true }
                            .disabled(clearState == .clearing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
        .confirmationDialog("Clear browsing history?", isPresented: $isConfirmingClearHistory) {
            Button("Clear History", role: .destructive) { HistoryStore.shared.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every page from your history and address bar suggestions.")
        }
        .confirmationDialog(
            "Clear all browsing data?",
            isPresented: $isConfirmingClear
        ) {
            Button("Clear", role: .destructive, action: clearData)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes cookies, caches and other website data, and signs you out of websites.")
        }
    }

    private func clearData() {
        clearState = .clearing
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            clearState = .done
        }
    }
}

// MARK: - Favorites

private struct FavoritesSettings: View {
    @Bindable private var store = FavoritesStore.shared
    @State private var selection: FavoriteSite.ID?
    @State private var editing: FavoriteSite?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shown on the new tab page. Drag to reorder; double-click to edit.")
                .settingsFootnote()

            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.sites) { site in
                        HStack(spacing: 10) {
                            SiteIcon(host: site.url?.host)
                                .frame(width: 16, height: 16)
                            Text(site.name)
                            Spacer()
                            Text(site.address)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(site.id)
                    }
                    .onMove { store.sites.move(fromOffsets: $0, toOffset: $1) }
                }
                .contextMenu(forSelectionType: FavoriteSite.ID.self) { ids in
                    if let id = ids.first {
                        Button("Edit…") { edit(id) }
                        Button("Remove", role: .destructive) { remove(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()

                // The classic macOS +/− bar under a list.
                HStack(spacing: 0) {
                    Button { isAdding = true } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add a favorite")
                    Divider().frame(height: 16)
                    Button {
                        if let selection { remove(selection) }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(selection == nil)
                    .help("Remove the selected favorite")
                    Spacer()
                    Button("Restore Defaults") { store.restoreDefaults() }
                        .controlSize(.small)
                        .padding(.trailing, 6)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 3)
                .background(.bar)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
        }
        .padding(20)
        .frame(height: 400)
        .sheet(isPresented: $isAdding) {
            FavoriteEditor(site: FavoriteSite(name: "", address: ""), isNew: true) { site in
                store.sites.append(site)
                selection = site.id
            }
        }
        .sheet(item: $editing) { site in
            FavoriteEditor(site: site, isNew: false) { updated in
                if let index = store.sites.firstIndex(where: { $0.id == updated.id }) {
                    store.sites[index] = updated
                }
            }
        }
    }

    private func edit(_ id: FavoriteSite.ID) {
        editing = store.sites.first { $0.id == id }
    }

    private func remove(_ id: FavoriteSite.ID) {
        store.sites.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }
}

private struct FavoriteEditor: View {
    @State var site: FavoriteSite
    let isNew: Bool
    let save: (FavoriteSite) -> Void
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        !site.name.trimmingCharacters(in: .whitespaces).isEmpty && site.url != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Favorite" : "Edit Favorite")
                .font(.headline)
            Form {
                TextField("Name", text: $site.name, prompt: Text("Example"))
                TextField("Address", text: $site.address, prompt: Text("example.com"))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    site.name = site.name.trimmingCharacters(in: .whitespaces)
                    site.address = site.address.trimmingCharacters(in: .whitespaces)
                    save(site)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    private struct Shortcut: Identifiable {
        let action: String
        let keys: String
        var id: String { action }
    }

    private struct ShortcutGroup: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    private let sections: [ShortcutGroup] = [
        ShortcutGroup(title: "Panes", shortcuts: [
            Shortcut(action: "New pane", keys: "⌘T"),
            Shortcut(action: "Split right", keys: "⌘D"),
            Shortcut(action: "Split down", keys: "⇧⌘D"),
            Shortcut(action: "Close pane", keys: "⌘W"),
            Shortcut(action: "Maximize / restore pane", keys: "⇧⌘↩"),
            Shortcut(action: "Minimize pane", keys: "⌃⌘M"),
            Shortcut(action: "Equalize panes", keys: "⌃⌘="),
            Shortcut(action: "Resize split", keys: "⌃⌘ ←↑↓→"),
        ]),
        ShortcutGroup(title: "Focus", shortcuts: [
            Shortcut(action: "Move focus", keys: "⌥⌘ ←↑↓→"),
            Shortcut(action: "Next pane", keys: "⌃⇥"),
            Shortcut(action: "Previous pane", keys: "⌃⇧⇥"),
            Shortcut(action: "Address bar", keys: "⌘L"),
            Shortcut(action: "Open in a new split (in the address bar)", keys: "⌘↩"),
            Shortcut(action: "Command palette", keys: "⌘K"),
        ]),
        ShortcutGroup(title: "Pages", shortcuts: [
            Shortcut(action: "Back", keys: "⌘["),
            Shortcut(action: "Forward", keys: "⌘]"),
            Shortcut(action: "Show full history", keys: "⌘Y"),
            Shortcut(action: "Reload", keys: "⌘R"),
            Shortcut(action: "Reload from origin", keys: "⌥⌘R"),
            Shortcut(action: "Stop loading", keys: "⌘."),
            Shortcut(action: "Find in page", keys: "⌘F"),
            Shortcut(action: "Next / previous match", keys: "⌘G ⇧⌘G"),
            Shortcut(action: "Show / hide reader", keys: "⇧⌘R"),
            Shortcut(action: "Zoom in / out / actual size", keys: "⌘= ⌘- ⌘0"),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.shortcuts) { shortcut in
                        LabeledContent(shortcut.action) {
                            Text(shortcut.keys)
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}
