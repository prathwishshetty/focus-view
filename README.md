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
- **Full history** at `focus://history` (History ▸ Show Full History, ⌘Y): every
  page you've visited, grouped by day ("Today", "Yesterday", …) with the time of
  each visit, like Chrome's history page. Search it, use a row's ⋮ menu to open
  it in a new split, copy its link, see more from that site or remove it, check
  several rows to delete them at once, or clear everything. ⌘-click a page to
  open it in a split. It opens in an empty pane, or in a new split beside the
  current page.
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
- **Web extensions**, loaded from a folder or a `.zip` (see
  [Extensions](#extensions)). uBlock Origin Lite installs in one click from
  Settings. An extension's toolbar button opens its popup for the focused pane.
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
- **Extensions**: add, update, reload, turn on and off, and remove web
  extensions, open their settings, and install or update uBlock Origin Lite.
- **Shortcuts**: a reference of every keyboard shortcut.

## Extensions

Focus runs web extensions with WebKit's own extension support
(`WKWebExtensionController`), the engine behind Safari's extensions. There's no
store: you load extensions yourself.

- **uBlock Origin Lite**: Settings ▸ Extensions ▸ *Install uBlock Origin Lite*
  downloads the latest Safari build (`uBOLite_….safari.zip`) from
  [its releases](https://github.com/uBlockOrigin/uBOL-home/releases) and loads
  it. The same button updates it later, keeping its settings.
- **Anything else**: click **+** and choose an unpacked extension folder (the one
  with `manifest.json`) or a `.zip` / `.xpi` of one. Adding an extension that's
  already installed (same name) updates it in place. After editing an unpacked
  extension's files, add the folder again; *Reload* in the list's right-click
  menu re-reads what's installed.

Extensions are copied to `~/Library/Containers/<bundle id>/Data/Library/Application Support/Focus/Extensions/`
(or `~/Library/Application Support/Focus/Extensions/` when run with `swift run`).
Adding an extension grants what its manifest asks for; if it later asks for
more, Focus asks you first. Each pane is a tab to extensions, in a single
window; `tabs.create` and `windows.create` open splits.

Not every extension works. WebKit supports Manifest V3 and non-persistent
Manifest V2 extensions, but can't block network requests with `webRequest`.
That's why the classic **uBlock Origin** (Manifest V2, built on blocking
`webRequest`) doesn't work here, while **uBlock Origin Lite**, which blocks with
`declarativeNetRequest`, does. Extensions written for Safari are the safest bet;
Chrome and Firefox builds often work too. Extension keyboard shortcuts and
right-click menu items aren't supported yet. If an extension misbehaves, its row
in Settings lists the issues WebKit reported, and with *Allow Web Inspector* on,
its background page shows up in Safari's Develop menu.

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
| Show full history (`focus://history`) | ⌘Y |
| Reload / hard reload / stop | ⌘R / ⌥⌘R / ⌘. |
| Page zoom in / out / reset | ⌘= / ⌘- / ⌘0 |

## Building

Requires macOS 26 and Xcode 26.

**In Xcode:** open `Focus.xcodeproj` (or `make xcode`), pick the **Focus**
scheme and press ⌘R. It builds the real `Focus.app` with its icon,
`Support/Info.plist` and `Support/Focus.entitlements`; ⌘U runs the tests. The
project picks up every file in `Sources/` and `Tests/` on its own, so new files
need no project changes.

Don't open the folder or `Package.swift` in Xcode to run the app: Xcode then
runs Focus as a bare executable, like a command-line tool, with no app bundle,
icon, bundle identifier or entitlements. The Swift package is there for the
command line:

```sh
make run      # build a release Focus.app into build/ and open it
make test     # run the FocusCore unit tests
swift run     # quick start as a bare executable
```

### Signing and passkeys

Out of the box Focus is signed to run on this Mac only. That's enough to use
it, but not to sign in with **passkeys or security keys**: on macOS a browser
built on `WKWebView` may only use them when it's signed with Apple's web
browser passkey entitlement
(`com.apple.developer.web-browser.public-key-credential`), which Apple grants
on request. Without it, sites report that the browser doesn't support passkeys.

1. **Request the entitlement.** The Account Holder of your Apple Developer
   account submits the request form linked from the
   [entitlement's documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential).
2. **Sign with your team.**
   - *Xcode:* copy `Support/Signing.local.xcconfig.example` to
     `Support/Signing.local.xcconfig` (git-ignored) and set your team ID and a
     bundle identifier of your own. Xcode registers the App ID and manages the
     profile. Once Apple approves the request, enable the entitlement on that
     App ID (Certificates, Identifiers & Profiles → Identifiers) and uncomment
     the `CODE_SIGN_ENTITLEMENTS` line, which switches to
     `Support/FocusPasskeys.entitlements`.
   - *`make run`:* register the App ID and create a macOS provisioning profile
     for it yourself (*macOS App Development* with this Mac registered, or
     *Developer ID* to share builds). Copy `signing.env.example` to
     `signing.env` (git-ignored) and set your signing identity
     (`security find-identity -v -p codesigning` lists them) and the profile's
     path. The build takes the profile's bundle identifier, embeds the profile,
     and claims the passkey entitlement as soon as the profile includes it. Its
     last line says whether passkeys are on.

Focus runs in the App Sandbox with the hardened runtime. Builds with different
bundle identifiers keep separate history, favorites, settings and website
logins.

## Layout

```
Sources/FocusCore/      Platform-independent logic (unit tested)
  SplitTree.swift       Binary split tree: split, close, resize, equalize, spatial navigation
  AddressResolver.swift Address vs. search detection, search engines and their suggestions, URL display
  BrowsingHistory.swift Visit history: one entry per address, visit counts, the days it was visited, size limit
  SuggestionMatcher.swift  Ranks history and favorites against what's typed
  FuzzyMatcher.swift    Fuzzy matching for the command palette
Sources/Focus/
  App/                  App entry point, menu commands
  Model/                Workspace (tree + focus + zoom), Pane (owns its WKWebView), WebKit delegates,
                        history store and the focus://history page, omnibox and palette models,
                        find-in-page and reader mode
  Views/                Split rendering, pane cards, omnibox and suggestions, command palette, new tab page
  Settings/             Settings window and stored preferences
  Extensions/           Web extensions: loading, installing, and panes as tabs
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
- **Reader mode settings**: font, text size and theme controls, and saving articles to read later.

### Privacy & security
- **Private panes**: a pane with its own ephemeral data store that leaves nothing behind.
- **Per-site permissions**: camera, microphone, location and notifications, managed in Settings.
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
