import AppKit
import FocusCore
import WebKit

/// An article pulled out of a page for reader mode.
struct ReaderArticle {
    var title: String
    var byline: String
    var siteName: String
    /// Cleaned-up HTML of the article body: no scripts, styles or attributes beyond links and images.
    var html: String
    var language: String
    var direction: String

    /// Reads the extraction script's result; nil if it found no article.
    init?(_ value: Any) {
        guard let dictionary = value as? [String: Any],
              let html = dictionary["html"] as? String, !html.isEmpty else { return nil }
        self.html = html
        title = dictionary["title"] as? String ?? ""
        byline = dictionary["byline"] as? String ?? ""
        siteName = dictionary["siteName"] as? String ?? ""
        language = dictionary["language"] as? String ?? ""
        direction = dictionary["direction"] as? String ?? ""
    }
}

/// Reader mode: a clean, readable version of an article, laid out for the pane it's in.
enum ReaderMode {
    /// A reader view runs no scripts and keeps no data; it only shows the extracted article.
    @MainActor
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return configuration
    }

    /// Whether a page has enough running text to be worth showing in reader mode
    /// (the same rule of thumb as Mozilla's Readability).
    static let availabilityScript = """
    const unlikely = /comment|footer|sidebar|related|share|social|promo|newsletter|subscribe|advert|banner|cookie|popup|modal|menu|nav/i;
    let score = 0;
    for (const node of document.querySelectorAll('p, pre, article')) {
      const tag = node.tagName;
      if (tag === 'ARTICLE' && node.querySelector('p')) continue;
      if (unlikely.test((node.className || '') + ' ' + (node.id || ''))) continue;
      if (node.checkVisibility && !node.checkVisibility()) continue;
      const length = node.textContent.trim().length;
      if (length < 140) continue;
      score += Math.sqrt(length - 140);
      if (score > 20) return true;
    }
    return false;
    """

    /// Finds the main content (an explicit `<article>` or the element holding the
    /// most paragraph text), copies it and strips it down to plain, safe markup.
    static let extractionScript = """
    const unlikely = /comment|footer|sidebar|related|share|social|promo|newsletter|subscribe|advert|banner|cookie|popup|modal|menu|nav|breadcrumb|toolbar|widget/i;
    const likely = /article|content|post|entry|story|body|text|main/i;
    const meta = selector => {
      const element = document.querySelector(selector);
      return element ? (element.getAttribute('content') || '').trim() : '';
    };
    const label = element => ((element.className && element.className.baseVal === undefined ? element.className : '') + ' ' + (element.id || ''));

    // Score each paragraph's container, and half as much to the one above it.
    const scores = new Map();
    const credit = (element, points) => {
      if (!element || element === document.body || element === document.documentElement) return;
      let weight = unlikely.test(label(element)) ? 0.3 : 1;
      if (likely.test(label(element))) weight *= 1.25;
      scores.set(element, (scores.get(element) || 0) + points * weight);
    };
    for (const paragraph of document.querySelectorAll('p, pre, blockquote')) {
      const text = paragraph.textContent.trim();
      if (text.length < 25) continue;
      const points = 1 + Math.min(Math.floor(text.length / 100), 3) + text.split(',').length - 1;
      credit(paragraph.parentElement, points);
      if (paragraph.parentElement) credit(paragraph.parentElement.parentElement, points / 2);
    }
    let best = null;
    for (const [element, score] of scores) {
      if (!best || score > scores.get(best)) best = element;
    }
    if (!best) return { html: '' };

    // An enclosing <article> usually holds the headline, images and captions too.
    const article = best.closest('article, [itemprop="articleBody"]');
    if (article && article.textContent.length < best.textContent.length * 3) best = article;

    const clone = best.cloneNode(true);
    clone.querySelectorAll([
      'script', 'style', 'noscript', 'iframe', 'form', 'button', 'input', 'select', 'textarea', 'nav', 'aside',
      'footer', 'svg', 'canvas', 'object', 'embed', 'dialog', 'template', '[hidden]', '[aria-hidden="true"]',
      '[role="navigation"]', '[role="complementary"]', '[role="dialog"]'
    ].join(',')).forEach(element => element.remove());
    for (const element of [...clone.querySelectorAll('*')]) {
      if (!element.isConnected && !clone.contains(element)) continue;
      if (unlikely.test(label(element)) && element.querySelectorAll('p').length < 2 && element.textContent.length < 600) {
        element.remove();
      }
    }

    const title = meta('meta[property="og:title"]') || document.title || '';
    // The headline is shown above the article; don't repeat it.
    const heading = clone.querySelector('h1');
    if (heading && title && heading.textContent.trim() === title.trim()) heading.remove();

    // Keep only links, images and table structure; resolve addresses against the page.
    const keep = { A: ['href'], IMG: ['src', 'srcset', 'alt'], SOURCE: ['srcset', 'type', 'media'], TD: ['colspan', 'rowspan'], TH: ['colspan', 'rowspan'], OL: ['start'] };
    const absolute = value => { try { return new URL(value, location.href).href; } catch (error) { return null; } };
    for (const element of clone.querySelectorAll('*')) {
      if (element.tagName === 'IMG') {
        const lazy = element.getAttribute('data-src') || element.getAttribute('data-lazy-src') || element.getAttribute('data-original');
        const src = element.getAttribute('src') || '';
        if (lazy && (!src || src.startsWith('data:'))) element.setAttribute('src', lazy);
        const lazySet = element.getAttribute('data-srcset');
        if (lazySet && !element.getAttribute('srcset')) element.setAttribute('srcset', lazySet);
      }
      const allowed = keep[element.tagName] || [];
      for (const attribute of [...element.attributes]) {
        if (!allowed.includes(attribute.name)) element.removeAttribute(attribute.name);
      }
      for (const name of ['href', 'src']) {
        const value = element.getAttribute(name);
        if (value === null) continue;
        const resolved = absolute(value);
        if (resolved && !resolved.startsWith('javascript:')) element.setAttribute(name, resolved);
        else element.removeAttribute(name);
      }
    }

    if (clone.textContent.trim().length < 200) return { html: '' };
    const byline = meta('meta[name="author"]') || meta('meta[property="article:author"]') ||
      ((document.querySelector('[rel="author"], [itemprop="author"], .byline, .author') || {}).textContent || '').trim();
    return {
      title,
      byline: byline.length < 100 ? byline : '',
      siteName: meta('meta[property="og:site_name"]') || location.hostname.replace(/^www[.]/, ''),
      html: clone.innerHTML,
      language: document.documentElement.lang || '',
      direction: document.documentElement.dir || ''
    };
    """

    /// The reader page. Type and spacing are set in viewport units, so the text
    /// scales with the pane: compact in a narrow split, roomy when maximized.
    static func document(for article: ReaderArticle, pageURL: URL) -> String {
        let site = escape(article.siteName.isEmpty ? AddressFormatter.displayHost(for: pageURL) : article.siteName)
        let title = escape(article.title)
        let byline = article.byline.isEmpty ? "" : "<p class=\"byline\">\(escape(article.byline))</p>"
        let language = article.language.isEmpty ? "" : " lang=\"\(escape(article.language))\""
        let direction = article.direction.isEmpty ? "" : " dir=\"\(escape(article.direction))\""
        return """
        <!doctype html>
        <html\(language)\(direction)>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data: blob:; media-src *; style-src 'unsafe-inline'; font-src *">
        <title>\(title)</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <article>
        <header>
        <p class="site">\(site)</p>
        <h1 class="title">\(title)</h1>
        \(byline)
        </header>
        \(article.html)
        </article>
        </body>
        </html>
        """
    }

    private static let stylesheet = """
    :root {
      color-scheme: light dark;
      --text: #1d1d1f; --secondary: #6e6e73; --background: #fbfbfa; --link: #0068da; --rule: rgba(0, 0, 0, 0.1); --wash: rgba(0, 0, 0, 0.04);
    }
    @media (prefers-color-scheme: dark) {
      :root { --text: #e6e6e9; --secondary: #9a9aa0; --background: #1e1e20; --link: #5aa9ff; --rule: rgba(255, 255, 255, 0.12); --wash: rgba(255, 255, 255, 0.06); }
    }
    html { background: var(--background); }
    body {
      margin: 0;
      padding: clamp(24px, 7vw, 80px) clamp(18px, 6vw, 56px) 120px;
      color: var(--text);
      font: clamp(16px, 0.9vw + 12px, 21px)/1.65 "New York", ui-serif, Georgia, serif;
      -webkit-font-smoothing: antialiased;
      text-rendering: optimizeLegibility;
      overflow-wrap: break-word;
    }
    article { max-width: 38em; margin: 0 auto; }
    header { margin-bottom: 2em; padding-bottom: 1.4em; border-bottom: 1px solid var(--rule); }
    .site { margin: 0; font: 600 0.72em/1.3 -apple-system, system-ui, sans-serif; letter-spacing: 0.06em; text-transform: uppercase; color: var(--secondary); }
    .title { margin: 0.35em 0 0.3em; font-size: clamp(1.55em, 2.2vw + 1em, 2.3em); line-height: 1.15; letter-spacing: -0.01em; }
    .byline { margin: 0; font: 0.85em/1.4 -apple-system, system-ui, sans-serif; color: var(--secondary); }
    p, ul, ol, blockquote, pre, table, figure { margin: 0 0 1.15em; }
    h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.7em 0 0.55em; }
    h1 { font-size: 1.6em; } h2 { font-size: 1.35em; } h3 { font-size: 1.15em; } h4, h5, h6 { font-size: 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    img, video, picture, figure { max-width: 100%; height: auto; }
    img { display: block; margin: 1.4em auto; border-radius: 6px; }
    figure img { margin-bottom: 0.5em; }
    figcaption { font: 0.78em/1.45 -apple-system, system-ui, sans-serif; color: var(--secondary); text-align: center; }
    blockquote { padding-left: 1em; border-left: 3px solid var(--rule); color: var(--secondary); }
    code, pre, kbd { font: 0.84em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
    code { padding: 0.1em 0.3em; border-radius: 4px; background: var(--wash); }
    pre { padding: 1em; overflow-x: auto; border-radius: 8px; background: var(--wash); }
    pre code { padding: 0; background: none; }
    table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; font-size: 0.9em; }
    td, th { padding: 0.4em 0.65em; border: 1px solid var(--rule); }
    hr { border: none; border-top: 1px solid var(--rule); margin: 2em 0; }
    ::selection { background: rgba(0, 122, 255, 0.25); }
    """

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Handles clicks in a reader view: links leave reader mode and open in the
/// pane (⌘-click opens a new split), and in-page anchors scroll as usual.
@MainActor
final class ReaderCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var pane: Pane?

    init(pane: Pane) {
        self.pane = pane
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            return .allow
        }
        // Footnotes and other jumps within the article.
        if let current = webView.url, url.fragment != nil, Self.withoutFragment(url) == Self.withoutFragment(current) {
            return .allow
        }
        guard let pane, let workspace = pane.workspace else { return .cancel }
        if navigationAction.modifierFlags.contains(.command) {
            workspace.openInNewPane(url, beside: pane.id, focus: navigationAction.modifierFlags.contains(.shift))
        } else {
            pane.hideReader()
            pane.load(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pane?.readerDidFinishLoading()
    }

    /// "Open Link in New Split" from the context menu.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let pane, let workspace = pane.workspace, let url = navigationAction.request.url {
            workspace.openInNewPane(url, beside: pane.id, focus: true)
        }
        return nil
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}
