import AppKit
import FocusCore
import SwiftUI

/// The one address field. It always reflects — and drives — the focused pane.
///
/// At rest it shows the page's host, centered. Clicking it (or ⌘L) switches to
/// the full address with everything selected, ready to replace. As you type,
/// suggestions from history, favorites and the search engine appear below it
/// (see ``OmniboxSuggestionList``).
///
/// The field itself is always left-aligned and visible (an invisible field can't
/// take focus); at rest it's empty and a centered label is drawn over it. Flipping
/// the field's own alignment would leave the cursor stranded in the middle.
struct Omnibox: View {
    @Environment(Workspace.self) private var workspace
    @FocusState private var isEditing: Bool

    var body: some View {
        let pane = workspace.focusedPane
        @Bindable var model = workspace.omnibox

        HStack(spacing: 8) {
            leadingIcon(for: pane)
                .frame(width: Self.sideWidth, alignment: .leading)

            ZStack {
                TextField("", text: $model.text, prompt: Text(isEditing ? "Search or enter address" : ""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isEditing)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)

                if !isEditing {
                    restingLabel(for: pane)
                        .allowsHitTesting(false)
                }
            }

            trailingButtons(for: pane)
                .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 260, idealWidth: 520, maxWidth: 640, minHeight: 30)
        .background(RegisteringArea { workspace.registerOmniboxView($0) })
        .onChange(of: workspace.addressFocusRequest) { isEditing = true }
        .onChange(of: isEditing) { _, editing in
            if editing {
                let pane = workspace.focusedPane
                model.beginEditing(with: AddressFormatter.editableString(for: pane.content == .web ? pane.url : nil))
                selectAll()
            } else {
                model.endEditing()
            }
        }
        .onChange(of: model.text) {
            model.textDidChange()
        }
        .onChange(of: model.isEditing) { _, editing in
            // The model ends editing on its own when a suggestion is opened.
            if !editing, isEditing { isEditing = false }
        }
        .onChange(of: workspace.focusedPaneID) {
            isEditing = false
        }
    }

    /// Room on each side of the field, kept equal so the resting host stays centered.
    private static let sideWidth: CGFloat = 38

    @ViewBuilder
    private func leadingIcon(for pane: Pane) -> some View {
        Group {
            if isEditing || pane.content == .newTab {
                Image(systemName: "magnifyingglass")
            } else if pane.isSecure, pane.url?.scheme == "https" {
                Image(systemName: "lock.fill")
            } else {
                Image(systemName: "globe")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    /// The centered text shown when not editing: the site's host, or the prompt.
    @ViewBuilder
    private func restingLabel(for pane: Pane) -> some View {
        if let host = pane.displayHost {
            Text(host)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("Search or enter address")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }

    /// Reader mode (when the page is an article) and reload/stop.
    @ViewBuilder
    private func trailingButtons(for pane: Pane) -> some View {
        if pane.content == .web, !isEditing {
            HStack(spacing: 6) {
                if pane.isReaderAvailable || pane.isReaderVisible {
                    Button {
                        workspace.toggleReader()
                    } label: {
                        Image(systemName: pane.isReaderVisible ? "doc.plaintext.fill" : "doc.plaintext")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(pane.isReaderVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(pane.isReaderVisible ? "Hide Reader (⇧⌘R)" : "Show Reader (⇧⌘R)")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Button {
                    pane.isLoading ? pane.stopLoading() : pane.reload()
                } label: {
                    Image(systemName: pane.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(pane.isLoading ? "Stop loading (⌘.)" : "Reload (⌘R)")
            }
            .animation(.easeOut(duration: 0.15), value: pane.isReaderAvailable)
        } else {
            Color.clear
        }
    }

    private func submit() {
        let model = workspace.omnibox
        guard !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return cancel() }
        workspace.submitAddressBar()
        isEditing = false
    }

    private func cancel() {
        isEditing = false
        workspace.focusContent()
    }

    private func selectAll() {
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
}

/// Suggestions under the address bar, drawn over the panes.
struct OmniboxSuggestionList: View {
    /// The size of the pane area this list floats over.
    let canvasSize: CGSize
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let model = workspace.omnibox
        if model.isShowingSuggestions {
            let anchor = workspace.omniboxFrameInCanvas()
            let width = min(max(anchor?.width ?? 520, 440), canvasSize.width - 16)
            let midX = anchor?.midX ?? canvasSize.width / 2
            let x = min(max(midX - width / 2, 8), canvasSize.width - width - 8)

            VStack(spacing: 2) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionRow(suggestion: suggestion, isSelected: index == model.selectedIndex)
                        .overlay(
                            ClickArea(
                                onHover: { hovering in if hovering { model.select(index) } },
                                onClick: {
                                    model.select(index)
                                    workspace.submitAddressBar()
                                    model.endEditing()
                                }
                            )
                        )
                }
            }
            .padding(6)
            .frame(width: width)
            .floatingPanel(cornerRadius: 14)
            .background(RegisteringArea { workspace.registerSuggestionsView($0) })
            // Real layout (not an offset), so the click areas' AppKit views land in the right place.
            .padding(.leading, x)
            .padding(.top, max((anchor?.maxY ?? 0) + 6, 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: OmniboxSuggestion
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: suggestion.kind == .topHit ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let tag {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: suggestion.detail == nil ? 28 : 38)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch suggestion.kind {
        case .topHit, .history, .favorite:
            SiteIcon(host: suggestion.url.host)
        case .search:
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        case .address:
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        }
    }

    private var tag: String? {
        switch suggestion.kind {
        case .topHit: "Top Hit"
        case .favorite: "Favorite"
        case .history, .search, .address: nil
        }
    }
}

extension View {
    /// The look shared by floating panels (suggestions, the command palette):
    /// a thick material card with a hairline edge and a soft shadow.
    func floatingPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.thickMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
    }
}
