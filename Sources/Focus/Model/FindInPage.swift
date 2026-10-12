/// The JavaScript behind the find bar.
///
/// WebKit's own `find(_:)` can't count matches, so the search runs in the page:
/// every visible match is highlighted with the CSS Custom Highlight API (which
/// never touches the page's DOM), the current one stands out, and it's scrolled
/// into view. It runs in an isolated content world, where the page can't see it.
enum FindInPage {
    /// Installs `window.__focusFind` (once per page) with `search`, `step` and
    /// `clear`, each returning `{count, index}`.
    static let script = """
    if (!window.__focusFind) {
      const ALL = 'focus-find', CURRENT = 'focus-find-current', LIMIT = 2000;
      const highlights = (typeof Highlight !== 'undefined' && window.CSS && CSS.highlights) ? CSS.highlights : null;
      let ranges = [];
      let index = -1;

      const state = () => ({ count: ranges.length, index: index + 1 });

      const ensureStyle = () => {
        if (document.getElementById('__focus-find-style')) return;
        const style = document.createElement('style');
        style.id = '__focus-find-style';
        style.textContent =
          '::highlight(' + ALL + ') { background-color: rgba(255, 214, 10, 0.45); color: inherit; }' +
          '::highlight(' + CURRENT + ') { background-color: rgb(255, 159, 10); color: black; }';
        (document.head || document.documentElement).appendChild(style);
      };

      const clear = () => {
        if (highlights) { highlights.delete(ALL); highlights.delete(CURRENT); }
        ranges = [];
        index = -1;
        return state();
      };

      const reveal = () => {
        if (index < 0) return;
        const range = ranges[index];
        if (highlights) highlights.set(CURRENT, new Highlight(range));
        const element = range.startContainer.parentElement;
        if (!element) return;
        let rect = range.getBoundingClientRect();
        const offscreen = r => r.top < 0 || r.bottom > innerHeight || r.left < 0 || r.right > innerWidth;
        if (!offscreen(rect)) return;
        // Bring nested scroll areas along, then center the match itself.
        element.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        rect = range.getBoundingClientRect();
        if (offscreen(rect)) {
          window.scrollBy({ top: rect.top - innerHeight / 2, left: rect.left < 0 || rect.right > innerWidth ? rect.left - innerWidth / 2 : 0 });
        }
      };

      const isShown = (() => {
        const cache = new Map();
        return element => {
          let shown = cache.get(element);
          if (shown === undefined) {
            shown = element.checkVisibility ? element.checkVisibility({ visibilityProperty: true }) : true;
            cache.set(element, shown);
          }
          return shown;
        };
      });

      const search = query => {
        clear();
        if (!query) return state();
        ensureStyle();
        const needle = query.toLowerCase();
        const shown = isShown();
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            const parent = node.parentElement;
            if (!parent) return NodeFilter.FILTER_REJECT;
            const tag = parent.tagName;
            if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') return NodeFilter.FILTER_REJECT;
            return shown(parent) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          }
        });
        let node;
        while ((node = walker.nextNode()) && ranges.length < LIMIT) {
          const text = node.data.toLowerCase();
          // Lowercasing a few characters changes their length; offsets would be wrong.
          if (text.length !== node.data.length) continue;
          let at = text.indexOf(needle);
          while (at !== -1 && ranges.length < LIMIT) {
            const range = document.createRange();
            range.setStart(node, at);
            range.setEnd(node, at + needle.length);
            ranges.push(range);
            at = text.indexOf(needle, at + needle.length);
          }
        }
        if (!ranges.length) return state();
        if (highlights) highlights.set(ALL, new Highlight(...ranges));
        // Start from the first match on screen or below it, like Safari.
        index = ranges.findIndex(range => range.getBoundingClientRect().bottom >= 0);
        if (index < 0) index = 0;
        reveal();
        return state();
      };

      const step = delta => {
        if (!ranges.length) return state();
        index = (index + delta + ranges.length) % ranges.length;
        reveal();
        return state();
      };

      window.__focusFind = { search, step, clear };
    }
    """
}
