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
- **Maximize & minimize**: hover near a pane's top edge for its controls.
  Maximize fills the window with the pane (click again to restore). Minimize
  takes it out of the layout but keeps it loaded, as a chip in the toolbar;
  click the chip to put it back where it was.
- **Focus navigation**: move between panes by direction (it uses the actual
  geometry, like Ghostty's `goto_split`) or cycle through them. Unfocused panes
  dim slightly.
- **One omnibox** that follows focus. At rest it shows the page's host,
  centered; click it (or press ⌘L) to edit the full address. It accepts an
  address or a search and understands `localhost:3000`, IP addresses, `.local`
  hosts and explicit schemes.
- **Suggestions as you type** from your history, your favorites and the search
  engine. A site whose address starts with what you typed becomes the
  **Top Hit** (type `git` and press Return for github.com). Use ↑/↓ to pick a
  row, Return to open it, or ⌘Return to open it in a new split.
- **Command palette** (⌘K): jump to any open or minimized pane, run any command
  (split, maximize, find, reader, zoom, settings…), or type an address or a
  search to open it here or in a new split. Matching is fuzzy, so `spr` finds
  "Split Right".
- **Find in page** (⌘F): a small floating bar in the pane's corner. It
  highlights every match, shows "3 of 12", and steps with Return / ⇧Return or
  ⌘G / ⇧⌘G. Each pane keeps its own search.
- **Reader mode** (⇧⌘R, or the page icon in the omnibox when a page looks like
  an article): the article on its own, in a calm serif layout whose text size
  and margins scale with the pane, so it reads well in a narrow split and when
  maximized. It follows light and dark mode and your ⌘+/⌘- zoom.
- **Back/forward history**: press and hold the back or forward button to see
  the pane's history and jump straight to any page. History ▸ Recently Visited
  lists the last pages you opened.
- **Transparent toolbar** over the window background, which follows the
  system's light or dark appearance.
- **Right-click menu** on pages and the new tab page with split, zoom, equalize
  and close actions. WebKit's "Open Link in New Window" becomes "Open Link in
  New Split".
- **New tab page** with a clock, favourite sites (just their icons) and a list
  of shortcuts. It adapts to small panes. There's one place to type, the
  address bar at the top: a new empty pane puts the cursor there.
- **Shrink to fit**: sites with a fixed minimum width are zoomed out just enough
  to fit a narrow split (down to 50%) instead of scrolling sideways, and zoom
  back as the pane widens. Your own ⌘+/⌘- zoom is the upper limit.
- `target=_blank`, `window.open` and ⌘-click open as a **new split** next to the
  current pane. ⇧⌘-click also moves focus to it.
- Downloads go to `~/Downloads`. JavaScript alerts, confirms and prompts, file
  uploads, page zoom, and error pages are all handled.

## Settings

Focus ▸ Settings… (⌘,) opens a standard macOS settings window:

- **General**: search engine and whether to ask it for suggestions; new panes
  open the new tab page or a homepage.
- **Appearance**: System / Light / Dark; dim unfocused panes; outline the
  focused pane; show or hide the clock, favorites and shortcut hints on the new
  tab page.
- **Websites**: default page zoom, shrink-to-fit, block pop-ups, Web Inspector,
  clear history and clear browsing data.
- **Favorites**: add, edit, remove and reorder the new tab page's sites.
- **Shortcuts**: a reference of every keyboard shortcut.

## Keyboard

| Action | Shortcut |
| --- | --- |
| New pane (auto direction) | ⌘T |
| Split right / down | ⌘D / ⇧⌘D |
| Close pane | ⌘W |
| Close window | ⇧⌘W |
| Move focus | ⌥⌘ + arrow keys |
| Next / previous pane | ⌃⇥ / ⌃⇧⇥ |
| Maximize / restore pane | ⇧⌘↩ |
| Minimize pane | ⌃⌘M |
| Resize split | ⌃⌘ + arrow keys |
| Equalize splits | ⌃⌘= |
| Focus omnibox | ⌘L |
| Open suggestion in a new split | ⌘↩ (in the omnibox) |
| Command palette | ⌘K |
| Find in page / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Reader mode | ⇧⌘R |
| Back / forward | ⌘[ / ⌘] (hold the buttons for history) |
| Reload / hard reload / stop | ⌘R / ⌥⌘R / ⌘. |
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
  AddressResolver.swift Address vs. search detection, search engines and their suggestions, URL display
  BrowsingHistory.swift Visit history: one entry per address, visit counts, size limit
  SuggestionMatcher.swift  Ranks history and favorites against what's typed
  FuzzyMatcher.swift    Fuzzy matching for the command palette
Sources/Focus/
  App/                  App entry point, menu commands
  Model/                Workspace (tree + focus + zoom), Pane (owns its WKWebView), WebKit delegates,
                        history store, omnibox and palette models, find-in-page and reader mode
  Views/                Split rendering, pane cards, omnibox and suggestions, command palette, new tab page
  Settings/             Settings window and stored preferences
  Support/              Keyboard shortcut routing
```

Each pane owns its `WKWebView`. SwiftUI only re-parents the view when the
split tree changes shape, so pages never reload when you split, close or zoom
something else.

## Ideas for future versions

Candidate features, roughly grouped. None of these are built yet.

### Panes & layout
- **Session restore**: reopen the last layout, with each pane's page and back/forward history.
- **Saved layouts (workspaces)**: name an arrangement of panes ("Research", "Dev") and switch between them.
- **Layout presets**: one-click 2-up, 3-column, 2×2 grid, or main pane with a sidebar stack.
- **Pinned panes**: keep a pane (music, chat, docs) fixed in place while others come and go.
- **Linked panes**: a reference pane where every link clicked opens in a chosen neighbour pane.
- **Swap with neighbour** shortcuts (⌃⌥ + arrows) to move panes without dragging.
- **Undo close pane** (⇧⌘T) with its history intact.
- **Per-pane mute**, with an indicator for panes playing audio.

### Address bar & navigation
- **Search shortcuts**: `w swift` searches Wikipedia, `gh focus` searches GitHub, and so on.
- **History window**: browse and search everything you've visited, grouped by day, and remove entries.
- **Reader mode settings**: font, text size and theme controls, and saving articles to read later.

### Privacy & security
- **Private panes**: a pane with its own ephemeral data store that leaves nothing behind.
- **Per-site permissions**: camera, microphone, location and notifications, managed in Settings.
- **Content blocking** using WebKit content rules (ads, trackers), with per-site toggles.
- **HTTPS-only mode** with a warning page before loading plain-http sites.
- **Separate profiles** (work / personal) with isolated cookies.

### Content & productivity
- **Picture in picture** for videos, or a "float this pane" mode.
- **Downloads panel** in the toolbar with progress and reveal-in-Finder.
- **Bookmarks** with folders, plus import from Safari/Chrome.
- **Share menu** and copy-link for the focused pane.
- **Page screenshot** of a pane (visible area or full page).
- **Split-aware print and PDF export** of the focused pane.

### System integration
- **Default browser support**: open links from other apps as a new split.
- **Handoff and iCloud sync** of favorites and open pages.
- **Shortcuts.app / AppleScript actions**: open a URL in a split, get the focused page.
- **Customizable keyboard shortcuts** in Settings.
- **Menu bar extra** for quickly opening a URL into the focused workspace.

### Polish
- **Animated focus transitions** and an optional "spotlight" mode that blurs unfocused panes.
- **Pane labels on hover** showing the site and title for unfocused panes.
- **Per-site zoom memory** so a site keeps the zoom you last used.
- **Onboarding page** explaining splits and shortcuts.
