import AppKit
import WebKit

/// Navigation, UI and download delegate for a pane's web view.
@MainActor
final class PaneWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private weak var pane: Pane?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    /// Schemes the web view handles itself; everything else is handed to macOS.
    private static let webSchemes: Set<String> = ["http", "https", "about", "file", "data", "blob", "javascript"]

    init(pane: Pane) {
        self.pane = pane
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }

        if let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            // mailto:, facetime:, app links… let the system open them.
            NSWorkspace.shared.open(url)
            return .cancel
        }

        if navigationAction.shouldPerformDownload {
            return .download
        }

        // ⌘-click opens the link in a new split next to this pane, like a background tab.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let pane, let workspace = pane.workspace {
            let focusNew = navigationAction.modifierFlags.contains(.shift)
            workspace.openInNewPane(url, beside: pane.id, focus: focusNew)
            return .cancel
        }

        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            return .download
        }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pane?.loadError = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pane?.pageDidCommit()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pane?.loadError = .init(
            title: "This page stopped working",
            message: "The web content process quit unexpectedly. Reload to try again.",
            url: webView.url ?? pane?.url
        )
    }

    private func report(_ error: Error) {
        let error = error as NSError
        // Cancelled loads and navigations turned into downloads aren't failures.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }

        let failingURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? pane?.url
        let title: String
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            title = "You're not connected to the internet"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            title = "Can't find this server"
        case NSURLErrorTimedOut:
            title = "The page took too long to respond"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot:
            title = "This connection isn't secure"
        default:
            title = "Can't open this page"
        }
        pane?.loadError = .init(title: title, message: error.localizedDescription, url: failingURL)
    }

    // MARK: - WKUIDelegate

    /// `window.open` and `target=_blank` open in a new split instead of a new window.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let pane, let workspace = pane.workspace else { return nil }
        let newPane = workspace.openPopup(beside: pane.id, configuration: configuration)
        return newPane.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let pane, let workspace = pane.workspace else { return }
        workspace.close(pane.id)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        _ = await present(alert, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert, in: webView) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = makeAlert(message: prompt, frame: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await present(alert, in: webView) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else {
            return panel.runModal() == .OK ? panel.urls : nil
        }
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.urls : nil
    }

    private func makeAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, in webView: WKWebView) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = Self.uniqueURL(for: suggestedFilename, in: folder)
        downloadDestinations[ObjectIdentifier(download)] = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Bounce the Downloads stack in the Dock, like Safari does.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSSound.beep()
    }

    private static func uniqueURL(for filename: String, in folder: URL) -> URL {
        let name = filename.isEmpty ? "Download" : filename
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) \(index)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = folder.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }
}
