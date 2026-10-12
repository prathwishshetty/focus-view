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
/// Editing state lives on ``OmniboxModel``; the field itself is AppKit (see
/// ``AddressField``) so it takes clicks reliably in the toolbar and refuses
/// keyboard focus while at rest.
struct Omnibox: View {
    @Environment(Workspace.self) private var workspace
    /// Bumped to put the keyboard in the field and select its text.
    @State private var focusRequest = 0

    private var isEditing: Bool { workspace.omnibox.isEditing }

    var body: some View {
        let pane = workspace.focusedPane
        @Bindable var model = workspace.omnibox

        HStack(spacing: 8) {
            leadingIcon(for: pane)
                .frame(width: Self.sideWidth, alignment: .leading)

            ZStack {
                AddressField(
                    text: $model.text,
                    isActive: model.isEditing,
                    focusRequest: focusRequest,
                    onActivate: beginEditing,
                    onSubmit: submit,
                    onCancel: cancel,
                    onFocusLost: { if workspace.omnibox.isEditing { endEditing() } }
                )

                if !model.isEditing {
                    restingLabel(for: pane)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)

            trailingButtons(for: pane)
                .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 260, idealWidth: 520, maxWidth: 640, minHeight: 30)
        .background(RegisteringArea { workspace.registerOmniboxView($0) })
        .onChange(of: workspace.addressFocusRequest) { beginEditing() }
        .onChange(of: model.text) {
            model.textDidChange()
        }
        .onAppear {
            // At launch the first pane is empty: start in the address bar.
            if workspace.focusedPane.content == .newTab { beginEditing() }
        }
    }

    /// Fills in the focused pane's address and puts the keyboard in the field.
    /// Calling it again (⌘L twice) refreshes the address and reselects it.
    private func beginEditing() {
        let pane = workspace.focusedPane
        workspace.omnibox.beginEditing(with: AddressFormatter.editableString(for: pane.content == .web ? pane.url : nil))
        focusRequest &+= 1
    }

    private func endEditing() {
        workspace.omnibox.endEditing()
    }

    /// Room on each side of the field, kept equal so the resting host stays centered.
    private static let sideWidth: CGFloat = 38

    @ViewBuilder
    private func leadingIcon(for pane: Pane) -> some View {
        Group {
            if isEditing || pane.content == .newTab {
                Image(systemName: "magnifyingglass")
            } else if FocusPages.isHistory(pane.url) {
                Image(systemName: "clock.arrow.circlepath")
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
        endEditing()
    }

    private func cancel() {
        endEditing()
        // An empty pane would send the cursor straight back here; leave it at rest.
        if workspace.focusedPane.content == .web { workspace.focusContent() }
    }

}

/// The address bar's text field, in AppKit.
///
/// - At rest it refuses keyboard focus, so the window never parks a caret in it;
///   a click at rest asks to begin editing instead (`onActivate`).
/// - It owns its focus: each new `focusRequest` makes it first responder and
///   selects everything, retrying briefly until the toolbar is on screen.
/// - Focus it gives up on its own (a click on a page) is reported through
///   `onFocusLost`; focus taken away because editing ended is not.
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    let isActive: Bool
    let focusRequest: Int
    let onActivate: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onFocusLost: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AddressTextField {
        let field = AddressTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Don't act on a request that was made before this field existed.
        context.coordinator.focusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: AddressTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.onActivate = onActivate
        field.isActivated = isActive
        field.placeholderString = isActive ? "Search or enter address" : nil
        if field.stringValue != text {
            field.stringValue = text
        }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            coordinator.focus(field, attempts: 8)
        }
        if !isActive, field.currentEditor() != nil {
            DispatchQueue.main.async { coordinator.resign(field) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField?
        var focusRequest = 0
        /// Set while editing is being ended on purpose, so it isn't reported as lost focus.
        private var isResigning = false

        func focus(_ field: AddressTextField, attempts: Int) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, field.isActivated else { return }
                guard let window = field.window, window.isVisible else {
                    if attempts > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.focus(field, attempts: attempts - 1)
                        }
                    }
                    return
                }
                if field.currentEditor() == nil {
                    window.makeFirstResponder(field)
                }
                field.currentEditor()?.selectAll(nil)
            }
        }

        func resign(_ field: AddressTextField) {
            guard !field.isActivated, let editor = field.currentEditor(),
                  let window = field.window, window.firstResponder === editor else { return }
            isResigning = true
            window.makeFirstResponder(nil)
            isResigning = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent?.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isResigning else { return }
            parent?.onFocusLost()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent?.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent?.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

final class AddressTextField: NSTextField {
    /// Whether editing has begun; at rest the field can't take keyboard focus.
    var isActivated = false
    var onActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { isActivated }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isActivated {
            super.mouseDown(with: event)
        } else {
            onActivate?()
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
