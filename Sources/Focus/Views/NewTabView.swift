import AppKit
import FocusCore
import SwiftUI

/// The page a pane shows before it navigates anywhere.
struct NewTabView: View {
    let pane: Pane
    let isFocused: Bool

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool
    @Environment(Workspace.self) private var workspace
    @AppStorage(BrowserSettings.Key.showClock) private var showClock = true
    @AppStorage(BrowserSettings.Key.showFavorites) private var showFavorites = true
    @AppStorage(BrowserSettings.Key.showShortcutHints) private var showShortcutHints = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let compact = size.width < 560 || size.height < 520
            let tiny = size.height < 340

            ZStack {
                Rectangle()
                    .fill(.background)
                    .contextMenu { PaneContextMenu(paneID: pane.id) }

                VStack(spacing: compact ? 22 : 34) {
                    if !tiny && showClock {
                        ClockHeader(compact: compact)
                    }
                    searchField(compact: compact)
                    if !tiny && showFavorites && !FavoritesStore.shared.sites.isEmpty {
                        FavoritesGrid(
                            compact: compact,
                            open: { site in
                                if let url = site.url { pane.load(url) }
                            },
                            openInNewPane: { site in
                                if let url = site.url { workspace.open(url, inNewPaneBeside: pane.id) }
                            }
                        )
                    }
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, compact ? 20 : 40)
                .offset(y: compact ? 0 : -24)

                if !compact && showShortcutHints {
                    VStack {
                        Spacer()
                        ShortcutHints()
                            .padding(.bottom, 22)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .onAppear {
            if isFocused { focusField() }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { focusField() }
        }
        .onChange(of: pane.newTabFocusRequest) {
            focusField()
        }
    }

    private func searchField(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: compact ? 15 : 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search or enter address", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 15 : 18))
                .focused($isFieldFocused)
                .onSubmit(submit)
                .onKeyPress(.escape) {
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: compact ? 44 : 54)
        .glassEffect(.regular.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
    }

    private func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        query = ""
        pane.navigate(to: text)
    }

    private func focusField() {
        // Wait a beat so the field exists in the window before focusing it.
        DispatchQueue.main.async { isFieldFocused = true }
    }
}

// MARK: - Clock

private struct ClockHeader: View {
    let compact: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: compact ? 2 : 6) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: compact ? 48 : 84, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(greeting(for: context.date)) · \(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))")
                    .font(.system(size: compact ? 13 : 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
    }

    private func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
    }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    let compact: Bool
    let open: (FavoriteSite) -> Void
    let openInNewPane: (FavoriteSite) -> Void

    var body: some View {
        let tile: CGFloat = compact ? 64 : 76
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: tile + 8, maximum: tile + 24), spacing: compact ? 10 : 16)],
            spacing: compact ? 12 : 18
        ) {
            ForEach(FavoritesStore.shared.sites) { site in
                Button { open(site) } label: {
                    FavoriteTile(site: site, size: compact ? 32 : 40)
                }
                .buttonStyle(TileButtonStyle())
                .help(site.url?.absoluteString ?? site.address)
                .contextMenu {
                    Button("Open", systemImage: "arrow.up.forward.square") { open(site) }
                    Button("Open in New Split", systemImage: "rectangle.split.2x1") { openInNewPane(site) }
                    Divider()
                    Button("Copy Link", systemImage: "link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(site.url?.absoluteString ?? site.address, forType: .string)
                    }
                }
            }
        }
        .frame(maxWidth: compact ? 360 : 460)
    }
}

private struct FavoriteTile: View {
    let site: FavoriteSite
    let size: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            AsyncImage(url: faviconURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                } else {
                    // A plain letter until the icon arrives (or if it can't load).
                    Text(site.name.prefix(1))
                        .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)

            Text(site.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var faviconURL: URL? {
        URL(string: "https://www.google.com/s2/favicons?domain=\(site.host)&sz=128")
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : (isHovering ? 1.06 : 1))
                .offset(y: isHovering && !configuration.isPressed ? -2 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Shortcut hints

private struct ShortcutHints: View {
    private struct Hint: Identifiable {
        let keys: String
        let label: String
        var id: String { keys }
    }

    private let hints: [Hint] = [
        Hint(keys: "⌘D", label: "Split right"),
        Hint(keys: "⇧⌘D", label: "Split down"),
        Hint(keys: "⌥⌘ ←→", label: "Move focus"),
        Hint(keys: "⇧⌘↩", label: "Zoom"),
        Hint(keys: "⌘W", label: "Close"),
    ]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(hints) { hint in
                HStack(spacing: 6) {
                    Text(hint.keys)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(hint.label)
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Context menu

/// Pane actions for right-clicking SwiftUI content (the web page builds its own).
struct PaneContextMenu: View {
    let paneID: PaneID
    @Environment(Workspace.self) private var workspace
    @AppStorage(BrowserSettings.Key.showClock) private var showClock = true
    @AppStorage(BrowserSettings.Key.showFavorites) private var showFavorites = true
    @AppStorage(BrowserSettings.Key.showShortcutHints) private var showShortcutHints = true

    var body: some View {
        Button("Split Right", systemImage: "rectangle.split.2x1") { workspace.split(.right, from: paneID) }
        Button("Split Down", systemImage: "rectangle.split.1x2") { workspace.split(.down, from: paneID) }
        if workspace.paneCount > 1 {
            Button(
                workspace.zoomedPaneID == paneID ? "Restore Pane Size" : "Maximize Pane",
                systemImage: workspace.zoomedPaneID == paneID
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            ) {
                workspace.toggleZoom(paneID)
            }
            Button("Minimize Pane", systemImage: "minus") { workspace.minimize(paneID) }
            Button("Equalize Panes", systemImage: "square.grid.2x2") { workspace.equalize() }
        }
        Divider()
        Button("Close Pane", systemImage: "xmark") { workspace.close(paneID) }
            .disabled(workspace.paneCount == 1)
    }
}
