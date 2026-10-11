import FocusCore
import SwiftUI

/// A single pane: a rounded card holding either a web page or the new tab page.
struct PaneView: View {
    let pane: Pane
    let isFocused: Bool
    /// True when this pane fills the window (only pane, or zoomed).
    let isAlone: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .top) {
            content

            if let error = pane.loadError {
                LoadErrorView(error: error) { pane.reload() }
                    .transition(.opacity)
            }

            LoadingBar(progress: pane.progress, isLoading: pane.isLoading, tint: accent)
        }
        .clipShape(shape)
        .overlay {
            // Unfocused splits recede slightly, like Ghostty's unfocused-split dimming.
            shape
                .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10))
                .opacity(isFocused || isAlone ? 0 : 1)
                .allowsHitTesting(false)
        }
        .overlay {
            shape
                .strokeBorder(borderStyle, lineWidth: isFocused && !isAlone ? 2 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isFocused && !isAlone ? 0.22 : 0.10), radius: isFocused ? 10 : 4, y: 2)
        .background(ClickFocusMonitor { workspace.focus(pane.id) })
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .animation(.easeOut(duration: 0.2), value: pane.loadError)
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .newTab:
            NewTabView(pane: pane, isFocused: isFocused)
        case .web:
            WebViewHost(pane: pane, isFocused: isFocused, cornerRadius: PaneMetrics.cornerRadius)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var accent: Color {
        if let themeColor = pane.themeColor { return Color(nsColor: themeColor) }
        return .accentColor
    }

    private var borderStyle: AnyShapeStyle {
        if isFocused && !isAlone {
            AnyShapeStyle(Color.accentColor.opacity(0.85))
        } else {
            AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
        }
    }
}

/// A thin progress line along the top edge of a pane.
private struct LoadingBar: View {
    let progress: Double
    let isLoading: Bool
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.6), tint],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(proxy.size.width * progress, 12))
                .shadow(color: tint.opacity(0.6), radius: 3)
        }
        .frame(height: 2.5)
        .opacity(isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: progress)
        .animation(.easeOut(duration: 0.4), value: isLoading)
        .allowsHitTesting(false)
    }
}

private struct LoadErrorView: View {
    let error: Pane.LoadError
    let retry: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Text(error.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if let url = error.url {
                    Text(AddressFormatter.displayHost(for: url))
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Button("Try Again", action: retry)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .padding(32)
        }
    }
}
