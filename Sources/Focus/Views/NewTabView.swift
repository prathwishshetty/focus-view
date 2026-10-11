import FocusCore
import SwiftUI

/// The page a pane shows before it navigates anywhere.
struct NewTabView: View {
    let pane: Pane
    let isFocused: Bool

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let compact = size.width < 560 || size.height < 520
            let tiny = size.height < 340

            ZStack {
                AmbientBackground()

                VStack(spacing: compact ? 22 : 34) {
                    if !tiny {
                        ClockHeader(compact: compact)
                    }
                    searchField(compact: compact)
                    if !tiny {
                        FavoritesGrid(compact: compact) { site in
                            pane.load(site.url)
                        }
                    }
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, compact ? 20 : 40)
                .offset(y: compact ? 0 : -24)

                if !compact {
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

struct FavoriteSite: Identifiable, Hashable {
    let name: String
    let url: URL
    let tint: Color

    var id: URL { url }
    var host: String { url.host ?? name }

    static let defaults: [FavoriteSite] = [
        .init(name: "Apple", url: URL(string: "https://www.apple.com")!, tint: .gray),
        .init(name: "GitHub", url: URL(string: "https://github.com")!, tint: .purple),
        .init(name: "YouTube", url: URL(string: "https://www.youtube.com")!, tint: .red),
        .init(name: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!, tint: .teal),
        .init(name: "Hacker News", url: URL(string: "https://news.ycombinator.com")!, tint: .orange),
        .init(name: "Reddit", url: URL(string: "https://www.reddit.com")!, tint: .orange),
        .init(name: "Figma", url: URL(string: "https://www.figma.com")!, tint: .pink),
        .init(name: "Claude", url: URL(string: "https://claude.ai")!, tint: .brown),
    ]
}

private struct FavoritesGrid: View {
    let compact: Bool
    let open: (FavoriteSite) -> Void

    var body: some View {
        let tile: CGFloat = compact ? 64 : 76
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: tile + 8, maximum: tile + 24), spacing: compact ? 10 : 16)],
            spacing: compact ? 12 : 18
        ) {
            ForEach(FavoriteSite.defaults) { site in
                Button { open(site) } label: {
                    FavoriteTile(site: site, size: compact ? 46 : 54)
                }
                .buttonStyle(TileButtonStyle())
                .help(site.url.absoluteString)
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
            ZStack {
                // Monogram first, so there's always something while the icon loads.
                Text(site.name.prefix(1))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(site.tint.gradient)
                AsyncImage(url: faviconURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: size * 0.5, height: size * 0.5)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .background(
                                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                                    .fill(.background)
                                    .frame(width: size, height: size)
                            )
                    }
                }
            }
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(site.tint.opacity(0.12)), in: .rect(cornerRadius: size * 0.28))

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

// MARK: - Background

/// A slowly drifting mesh gradient behind the new tab page.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase = false

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: points,
            colors: colorScheme == .dark ? Self.darkColors : Self.lightColors,
            smoothsColors: true
        )
        .overlay(Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.25 : 0.15))
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
        .accessibilityHidden(true)
    }

    private var points: [SIMD2<Float>] {
        let drift: Float = phase ? 1 : -1
        let leftMid: Float = 0.5 + 0.08 * drift
        let rightMid: Float = 0.5 - 0.08 * drift
        let centerX: Float = 0.5 + 0.12 * drift
        let centerY: Float = 0.5 - 0.06 * drift
        let bottomMid: Float = 0.5 - 0.1 * drift
        return [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
            SIMD2(0, leftMid), SIMD2(centerX, centerY), SIMD2(1, rightMid),
            SIMD2(0, 1), SIMD2(bottomMid, 1), SIMD2(1, 1),
        ]
    }

    private static let lightColors: [Color] = [
        Color(red: 0.98, green: 0.90, blue: 0.86), Color(red: 0.93, green: 0.90, blue: 0.99), Color(red: 0.86, green: 0.93, blue: 1.00),
        Color(red: 0.99, green: 0.94, blue: 0.90), Color(red: 0.95, green: 0.95, blue: 0.99), Color(red: 0.88, green: 0.96, blue: 0.97),
        Color(red: 0.94, green: 0.90, blue: 0.98), Color(red: 0.90, green: 0.94, blue: 1.00), Color(red: 0.93, green: 0.97, blue: 0.94),
    ]

    private static let darkColors: [Color] = [
        Color(red: 0.11, green: 0.08, blue: 0.20), Color(red: 0.07, green: 0.09, blue: 0.20), Color(red: 0.04, green: 0.13, blue: 0.20),
        Color(red: 0.20, green: 0.09, blue: 0.22), Color(red: 0.09, green: 0.09, blue: 0.16), Color(red: 0.05, green: 0.17, blue: 0.21),
        Color(red: 0.09, green: 0.07, blue: 0.15), Color(red: 0.13, green: 0.07, blue: 0.19), Color(red: 0.06, green: 0.11, blue: 0.17),
    ]
}
