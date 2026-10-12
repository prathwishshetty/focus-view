import FocusCore
import SwiftUI

/// The ⌘K palette: jump to any pane (minimized ones too), run a command, or
/// open what you typed. Drawn over the panes, near the top.
struct CommandPalette: View {
    /// The size of the pane area this floats over.
    let canvasSize: CGSize
    @Environment(Workspace.self) private var workspace
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        if workspace.palette.isVisible {
            ZStack(alignment: .top) {
                // Clicking outside closes it.
                Rectangle()
                    .fill(Color.black.opacity(0.12))
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.hidePalette() }
                    .transition(.opacity)

                panel
                    .frame(width: min(600, canvasSize.width - 32))
                    .padding(.top, min(72, canvasSize.height * 0.1))
                    .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
            .onAppear {
                workspace.palette.openSettings = { openSettings() }
                DispatchQueue.main.async { isFieldFocused = true }
            }
        }
    }

    private var panel: some View {
        @Bindable var palette = workspace.palette
        let items = palette.items
        let selected = items.isEmpty ? nil : min(palette.selectedIndex, items.count - 1)

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Search panes and commands, or enter an address", text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFieldFocused)
                    .onSubmit { palette.runSelected() }
                    .onExitCommand { workspace.hidePalette() }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            if !items.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, isSelected: index == selected)
                                    .id(item.id)
                                    .onTapGesture { palette.run(item) }
                                    .onHover { hovering in if hovering { palette.select(index) } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: min(380, canvasSize.height * 0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: palette.selectedIndex) { _, index in
                        guard items.indices.contains(index) else { return }
                        proxy.scrollTo(items[index].id)
                    }
                }
            } else if !palette.query.isEmpty {
                Divider()
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }

            Divider()
            HStack(spacing: 14) {
                KeyHint(keys: "↑↓", label: "Navigate")
                KeyHint(keys: "↩", label: "Run")
                KeyHint(keys: "esc", label: "Close")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .floatingPanel(cornerRadius: 16)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            } else if item.kind != .command {
                Text(item.kind.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: item.subtitle?.isEmpty == false ? 38 : 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        case .site(let host):
            SiteIcon(host: host)
                .frame(width: 16, height: 16)
        }
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}
