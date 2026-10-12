import AppKit
import FocusCore
import WebKit

/// The browser's own pages, served under `focus://` (`focus://history`).
enum FocusPages {
    static let scheme = "focus"
    static let history = URL(string: "focus://history")!

    static func isHistory(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == scheme && url.host?.lowercased() == "history"
    }
}

/// Serves `focus://` pages to the panes' web views.
@MainActor
final class FocusPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = FocusPageSchemeHandler()

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let data = Data((FocusPages.isHistory(url) ? HistoryPage.html : HistoryPage.notFound).utf8)
        let headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": String(data.count),
            // Only its own scripts and styles, and never inside another page.
            "Content-Security-Policy": HistoryPage.contentSecurityPolicy + "; frame-ancestors 'none'",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Lets focus://history read and change the browsing history.
///
/// Every page can see a message handler, so this one only answers the history
/// page itself, in the main frame.
@MainActor
final class HistoryPageBridge: NSObject, WKScriptMessageHandler {
    static let shared = HistoryPageBridge()
    static let messageName = "focusHistory"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == FocusPages.scheme,
              let webView = message.webView as? FocusWebView,
              FocusPages.isHistory(webView.url),
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "load":
            send(to: webView)
        case "remove":
            let rows = (body["rows"] as? [[String: Any]] ?? []).compactMap { row -> (url: String, date: Date)? in
                guard let url = row["url"] as? String, let time = row["time"] as? Double else { return nil }
                return (url, Date(timeIntervalSince1970: time / 1000))
            }
            HistoryStore.shared.removeVisits(rows)
        case "clear":
            if HistoryStore.shared.confirmAndClear() { send(to: webView) }
        case "openInSplit":
            guard let url = Self.webURL(body["url"]) else { return }
            webView.openInNewSplit?(url)
        case "copy":
            guard let url = Self.webURL(body["url"]) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        default:
            break
        }
    }

    /// History only holds web addresses; anything else from the page is ignored.
    private static func webURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Hands the page its rows. The script checks where it's running in case the
    /// view moved on to another page in the meantime.
    private func send(to webView: WKWebView) {
        let rows = HistoryStore.shared.visits.map { visit -> [String: Any] in
            ["url": visit.url, "title": visit.title, "time": visit.date.timeIntervalSince1970 * 1000]
        }
        webView.callAsyncJavaScript(
            "if (window.location.protocol === 'focus:' && window.focusHistory) window.focusHistory.show(rows);",
            arguments: ["rows": rows],
            in: nil,
            in: .page
        ) { _ in }
    }
}

/// focus://history: every page you've visited, grouped by day, with search and removal.
enum HistoryPage {
    static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src https: data:"

    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
    <title>History</title>
    <style>\(stylesheet)</style>
    </head>
    <body>
    <header class="top" id="top">
      <div class="bar">
        <h1>\(Icon.history)History</h1>
        <label class="search">
          \(Icon.search)
          <input id="search" type="search" placeholder="Search history" autocomplete="off" spellcheck="false" aria-label="Search history">
        </label>
        <button id="clear" class="link" type="button">Clear History…</button>
      </div>
      <div class="selection">
        <span id="count" class="count"></span>
        <button id="cancel" class="link" type="button">Cancel</button>
        <button id="delete" class="primary" type="button">Delete</button>
      </div>
    </header>
    <main id="list"></main>
    <div id="more-rows"></div>
    <div id="empty" class="empty" hidden>
      \(Icon.history)
      <h2 id="empty-title"></h2>
      <p id="empty-detail"></p>
    </div>
    <div id="menu" class="menu" role="menu" hidden>
      <button type="button" role="menuitem" data-action="open-split">Open in New Split</button>
      <button type="button" role="menuitem" data-action="more">More from This Site</button>
      <button type="button" role="menuitem" data-action="copy">Copy Link</button>
      <hr>
      <button type="button" role="menuitem" data-action="remove" class="danger">Remove from History</button>
    </div>
    <script>\(script)</script>
    </body>
    </html>
    """

    static let notFound = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
    <title>Page Not Found</title>
    <style>\(stylesheet)</style>
    </head>
    <body>
    <div class="empty">
      <h2>This page doesn't exist</h2>
      <p>Try <a href="focus://history">focus://history</a>.</p>
    </div>
    </body>
    </html>
    """

    private enum Icon {
        static let history = #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12a9 9 0 1 0 2.64-6.36L3 8.3"/><path d="M3 3.5v4.8h4.8"/><path d="M12 7.5V12l3 2"/></svg>"#
        static let search = #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/></svg>"#
    }

    private static let stylesheet = """
    :root {
      color-scheme: light dark;
      --background: #f2f2f4; --card: #ffffff; --text: #1d1d1f; --secondary: #6e6e73; --tertiary: #9c9ca1;
      --rule: rgba(0, 0, 0, 0.08); --hover: rgba(0, 0, 0, 0.045); --field: rgba(0, 0, 0, 0.055);
      --accent: #007aff; --danger: #d70015;
      --shadow: 0 1px 2px rgba(0, 0, 0, 0.05), 0 0 0 0.5px rgba(0, 0, 0, 0.06);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --background: #1c1c1e; --card: #2a2a2d; --text: #f2f2f7; --secondary: #a1a1a8; --tertiary: #737379;
        --rule: rgba(255, 255, 255, 0.09); --hover: rgba(255, 255, 255, 0.06); --field: rgba(255, 255, 255, 0.08);
        --accent: #0a84ff; --danger: #ff453a;
        --shadow: 0 0 0 0.5px rgba(255, 255, 255, 0.08);
      }
    }
    @supports (color: AccentColor) { :root { --accent: AccentColor; } }
    [hidden] { display: none !important; }
    * { box-sizing: border-box; }
    html { background: var(--background); }
    body {
      margin: 0;
      color: var(--text);
      font: 13px/1.4 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    button { font: inherit; color: inherit; }
    a { color: var(--accent); }

    .top {
      position: sticky; top: 0; z-index: 2;
      background: color-mix(in srgb, var(--background) 84%, transparent);
      -webkit-backdrop-filter: saturate(180%) blur(20px);
      backdrop-filter: saturate(180%) blur(20px);
      border-bottom: 1px solid transparent;
      transition: border-color 0.15s;
    }
    .top.scrolled { border-bottom-color: var(--rule); }
    .bar, .selection {
      max-width: 980px; height: 56px; margin: 0 auto; padding: 0 20px;
      display: flex; align-items: center; gap: 14px;
    }
    h1 { margin: 0; display: flex; align-items: center; gap: 8px; font-size: 20px; font-weight: 700; white-space: nowrap; }
    h1 svg { width: 20px; height: 20px; color: var(--accent); }
    .search {
      flex: 1; max-width: 520px; height: 30px; margin: 0 auto; padding: 0 10px;
      display: flex; align-items: center; gap: 7px;
      border-radius: 8px; background: var(--field);
      transition: box-shadow 0.15s;
    }
    .search:focus-within { box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 35%, transparent); }
    .search svg { flex: none; width: 13px; height: 13px; color: var(--secondary); }
    .search input { flex: 1; min-width: 0; border: 0; outline: none; background: none; color: inherit; font: inherit; }
    .link {
      flex: none; padding: 5px 9px; border: 0; border-radius: 6px;
      background: none; color: var(--accent); white-space: nowrap; cursor: pointer;
    }
    .link:hover { background: var(--hover); }
    .primary {
      flex: none; padding: 5px 14px; border: 0; border-radius: 6px;
      background: var(--accent); color: #fff; font-weight: 600; cursor: pointer;
    }
    .primary:hover { filter: brightness(1.08); }

    .selection { display: none; }
    body.selecting .bar { display: none; }
    body.selecting .selection { display: flex; }
    .count { flex: 1; font-size: 15px; font-weight: 600; }

    main { max-width: 980px; margin: 0 auto; padding: 4px 20px 24px; }
    .day { margin-top: 18px; }
    .day h2 { margin: 0 0 8px 14px; font-size: 13px; font-weight: 600; color: var(--secondary); }
    .card { padding: 5px 0; border-radius: 12px; background: var(--card); box-shadow: var(--shadow); }
    .row { position: relative; height: 40px; padding: 0 8px 0 14px; display: flex; align-items: center; gap: 12px; }
    .row:hover { background: var(--hover); }
    .row.selected { background: color-mix(in srgb, var(--accent) 13%, transparent); }
    .check { flex: none; width: 14px; height: 14px; margin: 0; accent-color: var(--accent); }
    time { flex: none; width: 62px; color: var(--secondary); font-size: 12px; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .icon {
      position: relative; flex: none; width: 16px; height: 16px; overflow: hidden;
      display: grid; place-items: center;
      border-radius: 4px; background: var(--field);
      color: var(--secondary); font-size: 10px; font-weight: 700;
    }
    .icon.loaded { background: none; color: transparent; }
    .icon img { position: absolute; inset: 0; width: 100%; height: 100%; }
    .title { flex: 0 1 auto; min-width: 0; color: var(--text); text-decoration: none; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .title:hover { text-decoration: underline; }
    .host { flex: 0 1 auto; max-width: 35%; min-width: 0; color: var(--tertiary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .more {
      flex: none; width: 28px; height: 28px; margin-left: auto; padding: 0;
      display: grid; place-items: center;
      border: 0; border-radius: 6px; background: none; color: var(--secondary);
      cursor: pointer; opacity: 0;
    }
    .more::before { content: "\\22EE"; font-size: 17px; font-weight: 700; line-height: 1; }
    .row:hover .more, .row.menu-open .more, .more:focus-visible { opacity: 1; }
    .more:hover, .row.menu-open .more { background: var(--hover); color: var(--text); }

    .menu {
      position: fixed; z-index: 10; min-width: 210px; padding: 5px;
      border-radius: 10px;
      background: color-mix(in srgb, var(--card) 90%, transparent);
      -webkit-backdrop-filter: saturate(180%) blur(24px);
      backdrop-filter: saturate(180%) blur(24px);
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2), 0 0 0 0.5px rgba(0, 0, 0, 0.15);
    }
    .menu button {
      display: block; width: 100%; padding: 5px 10px;
      border: 0; border-radius: 5px; background: none;
      text-align: left; cursor: default;
    }
    .menu button:hover, .menu button:focus-visible { outline: none; background: var(--accent); color: #fff; }
    .menu .danger { color: var(--danger); }
    .menu .danger:hover, .menu .danger:focus-visible { background: var(--danger); color: #fff; }
    .menu hr { margin: 4px 8px; border: 0; border-top: 1px solid var(--rule); }

    .empty { padding: 90px 24px; text-align: center; color: var(--secondary); }
    .empty svg { width: 44px; height: 44px; color: var(--tertiary); }
    .empty h2 { margin: 14px 0 4px; font-size: 17px; font-weight: 600; color: var(--text); }
    .empty p { margin: 0; }

    @media (max-width: 640px) {
      .bar { height: auto; padding: 10px 14px; flex-wrap: wrap; gap: 8px 10px; }
      .bar .link { margin-left: auto; }
      .search { order: 3; flex-basis: 100%; max-width: none; }
      .selection { padding: 0 14px; }
      main { padding: 0 10px 20px; }
      .row { gap: 10px; padding-left: 12px; }
      .host { display: none; }
      time { width: auto; min-width: 50px; }
    }
    """

    private static let script = #"""
    (() => {
      'use strict';
      const PAGE = 150;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.focusHistory;
      const post = (message) => { if (handler) handler.postMessage(message); };

      const $ = (id) => document.getElementById(id);
      const header = $('top'), list = $('list'), moreRows = $('more-rows'), search = $('search'), menu = $('menu');
      const empty = $('empty'), emptyTitle = $('empty-title'), emptyDetail = $('empty-detail'), count = $('count');

      const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
      const timeFormat = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });

      let all = [];         // every row: { url, title, time, host, day, key }
      let filtered = [];    // the rows matching the search
      let shown = 0;        // how many of `filtered` are on the page
      let signature = null; // what `all` was built from, to skip needless redraws
      let lastDay = null, currentCard = null;
      let lastChecked = -1;
      let menuRow = null;
      const selected = new Set();

      const startOfDay = (time) => { const date = new Date(time); date.setHours(0, 0, 0, 0); return date.getTime(); };
      const hostOf = (url) => { try { return new URL(url).hostname.replace(/^www[.]/, ''); } catch (error) { return ''; } };
      const signatureOf = (rows) => rows.map((row) => row.url + ' ' + row.time + ' ' + row.title).join('\n');
      const element = (tag, className) => { const node = document.createElement(tag); if (className) node.className = className; return node; };

      // Called by the browser with every visit, newest first.
      function show(rows) {
        const next = signatureOf(rows);
        if (next === signature) return;
        signature = next;
        all = rows.map((row) => ({
          url: row.url,
          title: row.title || '',
          time: row.time,
          host: hostOf(row.url),
          day: startOfDay(row.time),
          key: row.url + '\n' + row.time,
        }));
        const keys = new Set(all.map((row) => row.key));
        for (const key of [...selected]) if (!keys.has(key)) selected.delete(key);
        closeMenu();
        applyFilter(false);
      }
      window.focusHistory = { show };

      function applyFilter(reset) {
        const terms = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
        filtered = terms.length === 0 ? all : all.filter((row) => {
          const text = (row.title + ' ' + row.url).toLowerCase();
          return terms.every((term) => text.includes(term));
        });
        lastChecked = -1;
        if (reset) { shown = 0; window.scrollTo(0, 0); }
        render(Math.max(shown, PAGE));
      }

      function render(target) {
        list.textContent = '';
        shown = 0;
        lastDay = null;
        currentCard = null;
        appendRows(target);
        updateEmpty();
        updateSelection();
        fill();
      }

      function appendRows(amount) {
        const end = Math.min(filtered.length, shown + amount);
        const fragment = document.createDocumentFragment();
        for (let index = shown; index < end; index++) {
          const row = filtered[index];
          if (row.day !== lastDay) {
            lastDay = row.day;
            const section = element('section', 'day');
            const heading = element('h2');
            heading.textContent = dayTitle(row.day);
            currentCard = element('div', 'card');
            section.append(heading, currentCard);
            fragment.append(section);
          }
          currentCard.append(rowElement(row, index));
        }
        list.append(fragment);
        shown = end;
      }

      // Adds rows while the end of the list is near the bottom of the window.
      function fill() {
        while (shown < filtered.length && moreRows.getBoundingClientRect().top < window.innerHeight + 800) {
          appendRows(PAGE);
        }
      }

      function dayTitle(day) {
        const today = startOfDay(Date.now());
        const date = dayFormat.format(new Date(day));
        if (day === today) return 'Today – ' + date;
        if (day === startOfDay(today - 1)) return 'Yesterday – ' + date;
        return date;
      }

      function rowElement(row, index) {
        const item = element('div', 'row');
        item.dataset.index = String(index);
        const isSelected = selected.has(row.key);
        if (isSelected) item.classList.add('selected');

        const check = element('input', 'check');
        check.type = 'checkbox';
        check.checked = isSelected;
        check.setAttribute('aria-label', 'Select ' + (row.title || row.host));

        const time = element('time');
        time.dateTime = new Date(row.time).toISOString();
        time.textContent = timeFormat.format(new Date(row.time));

        const link = element('a', 'title');
        link.href = row.url;
        link.title = row.url;
        link.textContent = row.title || row.url;

        const host = element('span', 'host');
        host.textContent = row.host;

        const more = element('button', 'more');
        more.type = 'button';
        more.title = 'More';
        more.setAttribute('aria-label', 'More actions for ' + (row.title || row.host));

        item.append(check, time, siteIcon(row.host), link, host, more);
        return item;
      }

      function siteIcon(host) {
        const icon = element('span', 'icon');
        icon.textContent = (host[0] || '?').toUpperCase();
        if (host) {
          const image = element('img');
          image.alt = '';
          image.loading = 'lazy';
          image.decoding = 'async';
          image.addEventListener('load', () => icon.classList.add('loaded'));
          image.addEventListener('error', () => image.remove());
          image.src = 'https://www.google.com/s2/favicons?domain=' + encodeURIComponent(host) + '&sz=32';
          icon.append(image);
        }
        return icon;
      }

      function updateEmpty() {
        $('clear').hidden = all.length === 0;
        const isEmpty = filtered.length === 0;
        empty.hidden = !isEmpty;
        if (!isEmpty) return;
        if (all.length === 0) {
          emptyTitle.textContent = 'Your browsing history appears here';
          emptyDetail.textContent = 'Pages you visit are listed by day, newest first.';
        } else {
          emptyTitle.textContent = 'No results';
          emptyDetail.textContent = 'Nothing in your history matches “' + search.value.trim() + '”.';
        }
      }

      // MARK: Selection

      function toggle(index, checked, extend) {
        const from = extend && lastChecked >= 0 ? Math.min(lastChecked, index) : index;
        const to = extend && lastChecked >= 0 ? Math.max(lastChecked, index) : index;
        for (let i = from; i <= to; i++) {
          const row = filtered[i];
          if (!row) continue;
          if (checked) selected.add(row.key); else selected.delete(row.key);
        }
        lastChecked = index;
        syncChecks();
        updateSelection();
      }

      function syncChecks() {
        for (const item of list.querySelectorAll('.row')) {
          const row = filtered[Number(item.dataset.index)];
          const on = !!row && selected.has(row.key);
          item.classList.toggle('selected', on);
          item.querySelector('.check').checked = on;
        }
      }

      function updateSelection() {
        document.body.classList.toggle('selecting', selected.size > 0);
        count.textContent = selected.size === 1 ? '1 selected' : selected.size + ' selected';
      }

      function clearSelection() {
        selected.clear();
        lastChecked = -1;
        syncChecks();
        updateSelection();
      }

      function removeRows(rows) {
        if (rows.length === 0) return;
        post({ action: 'remove', rows: rows.map((row) => ({ url: row.url, time: row.time })) });
        const gone = new Set(rows.map((row) => row.key));
        all = all.filter((row) => !gone.has(row.key));
        for (const key of gone) selected.delete(key);
        signature = signatureOf(all);
        applyFilter(false);
      }

      // MARK: Row menu

      function openMenu(row, button) {
        closeMenu();
        menuRow = row;
        button.closest('.row').classList.add('menu-open');
        menu.hidden = false;
        const rect = button.getBoundingClientRect();
        let top = rect.bottom + 4;
        if (top + menu.offsetHeight > window.innerHeight - 8) top = rect.top - menu.offsetHeight - 4;
        menu.style.top = Math.max(8, top) + 'px';
        menu.style.left = Math.max(8, Math.min(rect.right - menu.offsetWidth, window.innerWidth - menu.offsetWidth - 8)) + 'px';
        menu.querySelector('button').focus();
      }

      function closeMenu() {
        if (menu.hidden) return;
        menu.hidden = true;
        menuRow = null;
        for (const item of list.querySelectorAll('.row.menu-open')) item.classList.remove('menu-open');
      }

      menu.addEventListener('click', (event) => {
        const button = event.target.closest('button[data-action]');
        if (!button || !menuRow) return;
        const row = menuRow;
        closeMenu();
        switch (button.dataset.action) {
          case 'open-split': post({ action: 'openInSplit', url: row.url }); break;
          case 'more': setQuery(row.host); break;
          case 'copy': post({ action: 'copy', url: row.url }); break;
          case 'remove': removeRows([row]); break;
        }
      });

      // MARK: Events

      list.addEventListener('click', (event) => {
        const item = event.target.closest('.row');
        if (!item) return;
        const index = Number(item.dataset.index);
        const row = filtered[index];
        if (!row) return;
        if (event.target.closest('.check')) {
          toggle(index, event.target.checked, event.shiftKey);
        } else if (event.target.closest('.more')) {
          event.stopPropagation();
          if (menuRow === row) closeMenu(); else openMenu(row, event.target.closest('.more'));
        }
      });

      document.addEventListener('click', (event) => {
        if (!menu.contains(event.target)) closeMenu();
      });

      $('clear').addEventListener('click', () => post({ action: 'clear' }));
      $('cancel').addEventListener('click', clearSelection);
      $('delete').addEventListener('click', () => removeRows(all.filter((row) => selected.has(row.key))));

      let searchTimer = null;
      search.addEventListener('input', () => {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => setQuery(search.value), 120);
      });

      // Keeps the search in the address (focus://history?q=…) so reloads and Back keep it.
      function setQuery(query) {
        search.value = query;
        const base = window.location.href.split(/[?#]/)[0];
        const trimmed = query.trim();
        try {
          window.history.replaceState(null, '', trimmed ? base + '?q=' + encodeURIComponent(trimmed) : base);
        } catch (error) {
          // Not essential: the search still applies.
        }
        applyFilter(true);
      }

      document.addEventListener('keydown', (event) => {
        const inField = event.target === search;
        if (event.key === 'Escape') {
          if (!menu.hidden) closeMenu();
          else if (inField && search.value) setQuery('');
          else if (selected.size > 0) clearSelection();
          else return;
          event.preventDefault();
        } else if ((event.key === 'Delete' || event.key === 'Backspace') && !inField && selected.size > 0) {
          event.preventDefault();
          removeRows(all.filter((row) => selected.has(row.key)));
        }
      });

      window.addEventListener('scroll', () => {
        header.classList.toggle('scrolled', window.scrollY > 4);
        closeMenu();
        fill();
      }, { passive: true });
      window.addEventListener('resize', () => { closeMenu(); fill(); });

      // Stay current: other panes keep adding to history while this one is open.
      window.addEventListener('focus', () => post({ action: 'load' }));
      window.addEventListener('pageshow', (event) => { if (event.persisted) post({ action: 'load' }); });

      search.value = new URLSearchParams(window.location.search).get('q') || '';
      search.focus();
      if (handler) post({ action: 'load' }); else show([]);
    })();
    """#
}
