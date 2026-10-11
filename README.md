# Focus

A focus-first web browser for macOS 26, built on `WKWebView`.

Focus has **no tabs and no windows**. It has a single view that you divide
into splits, the way you split a terminal in Ghostty. One pane has focus at a
time, and the toolbar (back/forward, the omnibox, reload) always acts on that
pane. New pages open as splits instead of in a tab strip or sidebar.

## Features (v0)

- **Splits**: split any pane right or down, drag the gaps to resize,
  double-click a gap to even it out, equalize everything, or zoom one pane to
  fill the window.
- **Rearranging**: move the pointer to the top edge of a pane to reveal its
  handle and grab it. The pane lifts into a postcard that follows the pointer.
  Drop it on another pane's edge to dock it on that side, in the middle to swap
  the two, or along an edge of the window to make it a full-height column or
  full-width row (two rows become two columns this way).
- **Focus navigation**: move between panes by direction (it uses the actual
  geometry, like Ghostty's `goto_split`) or cycle through them. Unfocused panes
  dim slightly.
- **One omnibox** that follows focus. At rest it shows the page's host,
  centered; click it (or press ⌘L) to edit the full address. It accepts an
  address or a search and understands `localhost:3000`, IP addresses, `.local`
  hosts and explicit schemes.
- **Transparent toolbar** over the window background, which follows the
  system's light or dark appearance.
- **Right-click menu** on pages and the new tab page with split, zoom, equalize
  and close actions. WebKit's "Open Link in New Window" becomes "Open Link in
  New Split".
- **New tab page** with a clock, a Liquid Glass search field, favourite sites
  (just their icons) and a list of shortcuts. It adapts to small panes.
- **Shrink to fit**: sites with a fixed minimum width are zoomed out just enough
  to fit a narrow split (down to 50%) instead of scrolling sideways, and zoom
  back as the pane widens. Your own ⌘+/⌘- zoom is the upper limit.
- `target=_blank`, `window.open` and ⌘-click open as a **new split** next to the
  current pane. ⇧⌘-click also moves focus to it.
- Downloads go to `~/Downloads`. JavaScript alerts, confirms and prompts, file
  uploads, page zoom, and error pages are all handled.

## Keyboard

| Action | Shortcut |
| --- | --- |
| New pane (auto direction) | ⌘T |
| Split right / down | ⌘D / ⇧⌘D |
| Close pane | ⌘W |
| Close window | ⇧⌘W |
| Move focus | ⌥⌘ + arrow keys |
| Next / previous pane | ⌃⇥ / ⌃⇧⇥ |
| Zoom pane | ⇧⌘↩ |
| Resize split | ⌃⌘ + arrow keys |
| Equalize splits | ⌃⌘= |
| Focus omnibox | ⌘L |
| Back / forward | ⌘[ / ⌘] |
| Reload / hard reload / stop | ⌘R / ⇧⌘R / ⌘. |
| Page zoom in / out / reset | ⌘= / ⌘- / ⌘0 |

## Building

Requires macOS 26 and Xcode 26.

```sh
make run      # build a release Focus.app into build/ and open it
make test     # run the FocusCore unit tests
make xcode    # generate Focus.xcodeproj with XcodeGen and open it
swift run     # quick start as a bare executable
```

## Layout

```
Sources/FocusCore/      Platform-independent logic (unit tested)
  SplitTree.swift       Binary split tree: split, close, resize, equalize, spatial navigation
  AddressResolver.swift Address vs. search detection, search engines, URL display
Sources/Focus/
  App/                  App entry point, menu commands
  Model/                Workspace (tree + focus + zoom), Pane (owns its WKWebView), WebKit delegates
  Views/                Split rendering, pane cards, omnibox, new tab page
  Support/              Keyboard shortcut routing
```

Each pane owns its `WKWebView`. SwiftUI only re-parents the view when the
split tree changes shape, so pages never reload when you split, close or zoom
something else.

## Next up

Ideas for the next iterations: session restore, history and autocomplete in
the omnibox, a command palette, find in page, a settings window (search engine,
favourites), drag-to-rearrange panes, and per-pane privacy.
