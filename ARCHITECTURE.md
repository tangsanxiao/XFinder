# Architecture

XFinder is a macOS multi-pane file manager (QSpace-inspired) built as a single
SwiftPM executable using SwiftUI with AppKit interop. This document describes the
stable topology — module boundaries and data flow. Volatile specifics (exact
sizes, counts, lists) live in the code and tests, which can't go stale.

For working conventions and known traps, see [AGENTS.md](AGENTS.md).

## Build & run

- `swift build` — compile.
- `swift test` — swift-testing suite (no XCTest; see AGENTS.md for why).
- `swift format lint --strict --recursive Sources Tests` — style gate (config: `.swift-format`); `swift format format -i ...` to auto-fix.
- `./scripts/build-app.sh` — package `dist/XFinder.app` (ad-hoc signed).
- `./scripts/release.sh` — build + zip + checksum into `release/` (tag-triggered in CI).

`WorkspaceStore` takes an optional `supportDirectory` so tests inject a temp
directory and stay isolated from the real Application Support; file-operation
collision handling is covered by tests against temp directories.

## Process & windowing

- `XFinderApp` (`@main`) hosts the main workspace `WindowGroup` with a hidden
  titlebar and a value-driven Markdown document `WindowGroup` opened only on
  demand.
- `WindowChromeConfigurator` configures the `NSWindow` once (transparent titlebar,
  full-size content). The app deliberately avoids `NavigationSplitView` and uses a
  custom sidebar/content split to keep titlebar spacing controllable.
- `WindowDragArea` / `WindowZoomController` handle drag-to-move and double-click zoom.

## State: single source of truth

`WorkspaceStore` is a `@MainActor ObservableObject` that owns all app state and
every file-system mutation:

- **Workspaces & panes** — a `Workspace` holds an ordered list of `DirectoryItem`
  (each = one pane root). Persisted as JSON under Application Support.
- **Live pane locations** — `paneLocations[paneID]` tracks where each pane has
  navigated, so navigation survives workspace switches (panes are recreated on
  switch and restore from here).
- **Layout** — `WorkspaceLayout` defines the pane arrangement and a
  `preferredPaneCount`. `applyLayout` only switches the layout; when it wants
  more panes than there are folders, the grid renders greyed "add a pane"
  placeholders for the empty cells instead of auto-creating panes.
- **File operations** — create folder, create Markdown file, copy, move, rename,
  trash, duplicate, and compress. Each mutation bumps `fileOperationRevision`,
  which panes observe to reload while preserving local expansion state where
  appropriate. Common operations also register undo/redo history in the store.
- **Long file tasks** — cancellable external tasks (currently zip compression)
  are published as `FileTask` rows and shown in the window overlay.
- **System bookmarks** — Desktop/Documents/Downloads/etc. for the sidebar.

Views never touch the file system directly; they call the store.

## View layer

```
ContentView
├─ Sidebar (SidebarViews)        workspaces list + system bookmarks
└─ WorkspaceDetailView (WorkspaceViews)
   ├─ FinderLikeToolbar          title, Layout control, View mode, restart
   └─ MultiPaneBrowserView       arranges panes per layout (grid / main+stack)
      └─ BrowserPane (BrowserPaneView)   one navigable pane
         ├─ toolbar: back/forward/up, breadcrumbs, reveal, copy path, close
         ├─ list / icons / columns views
         └─ rows (FileItemViews): FileRow, IconFileCell, ColumnFileRow
```

- **View mode is pane-local** (`paneViewModes[paneID]`); focus is tracked by
  `focusedDirectoryID` and drives the toolbar title and bookmark targeting.
- **`FileRowMetrics`** is the single source of truth for list-row geometry
  (height, selection corner radius, alternating tint) shared by rows, the
  selection fill, and the stripe filler.
- **`FileIconView`** renders the real system icon for any URL.

## File browsing

`FileBrowserService` is a stateless enum that reads a directory's contents into
`BrowserFileItem` values (name, dates, size, kind, package/dir flags), hiding
dot/hidden files and sorting folders-first. `BrowserPane` keeps inline expansion
state and reloads expanded subfolders after file operations or FSEvents updates.
`DisplayFormatters` turns dates/sizes into display strings (pure, injectable
clock for testing). Directory reads run off the main thread via the async
`contents` overload; panes guard concurrent reloads with a generation counter.
`FileSearchService` recursively searches a focused pane's folder off-main, and
`FileInfoService` builds the Get Info snapshot (path, kind, size, timestamps,
permissions, access flags). `QuickLookController` delegates to the system
`QLPreviewPanel` for Finder-style Space previews.

## Markdown documents

- Double-clicking `.md` / `.markdown` sends a `MarkdownWindowRequest` to the
  value-driven document window; no document controller or parser remains active
  until the user opens a file.
- `MarkdownFileService` performs bounded UTF-8 reads and atomic writes off the
  main actor. Saves compare uncached metadata plus a content fingerprint so an
  external edit cannot be overwritten silently.
- `MarkdownDocumentParsing` uses the pinned `swift-markdown` parser and converts
  its immutable syntax tree into a small `Sendable` render model. Parsing is
  debounced, cancellable by generation, and capped by character, block, nesting,
  table-row, and image-size limits.
- `MarkdownDocumentView` uses native SwiftUI controls for selectable preview,
  source editing, and split mode. Remote images are never fetched; local images
  are decoded into bounded thumbnails only when their preview rows appear.

## Git awareness & agent bridge

- `GitStatusService` shells out to `git` (off-main) and returns an immutable
  `GitDirectorySnapshot`: branch, per-path statuses (row badges), recent
  commits (the toolbar's project status card). Porcelain/log parsing is pure
  and unit-tested; a temp-repo integration test covers the real CLI.
- `AgentInboxScanner` is the local review-workbench aggregator. It combines
  known project roots from workspaces, stars, and Claude/Codex session metadata,
  then attaches each project's git snapshot, recent changes, and lightweight
  risk findings. The list pass never parses whole transcripts; decisions/todos
  are extracted lazily when a project is selected.
- `WorkspaceStore` owns the Agent Inbox cache, refresh state, selected-project
  transcript extraction state, and local project governance preferences (hidden
  / pinned). Entering the Inbox reuses the cached snapshot; the refresh button
  is the explicit full rescan.
- `SessionCatalog`, also owned by `WorkspaceStore`, is the shared metadata source
  for Agent Inbox and Session Center. It coalesces concurrent scans and persists
  path/size/mtime-keyed summaries; refreshes enumerate the roots but reread the
  bounded JSONL head only for new or changed files. It has no polling loop.
- The sidebar exposes one Agent Center entry. `AppSettings.agentCenterSection`
  selects Inbox or Sessions, and `ContentView` instantiates only that section;
  project/session deep links switch the section without keeping both scans alive.
- `AgentRiskAnalyzer` is pure except for bounded text-file reads used to detect
  likely secrets in changed files. Keep new risk rules here and cover them with
  swift-testing tests; the UI should only render the findings.
- `ClaudeBridge` runs the locally installed Claude Code CLI headless
  (`claude -p`) in a pane's directory — preset analysis, free-form ask, and
  selection ask all go through one editable-question sheet. "Open in Claude
  Code" launches the interactive CLI in Terminal via AppleScript. Deliberately
  no API-key handling in-app: the CLI owns auth, tools, and context.
- `ProjectStatusViews` holds the status card popover and the ask sheet.
- `PaneGridGeometry` is the single source of truth for the pane grid's
  rows×columns; both the rendered grid and the Layout control's live
  description read it, so they cannot disagree.

## In-app self-inspection

- `AppInfoViews` provides the "What's New" sheet (renders the CHANGELOG.md
  bundled by build-app.sh via `ChangelogParser`, a pure line-based parser)
  and the Activity & Errors trace panel.
- `WorkspaceStore` records every `statusMessage`/`lastError` into a capped
  `events` log (newest first) that the trace panel displays.
- `SessionCenterView` lists local Claude/Codex transcripts and lazily builds a
  local full-text transcript index only when the user searches, keeping the
  default list scan cheap for large session directories. Opening it reuses the
  store-owned `SessionCatalog`, including a scan already performed by Agent Inbox.
- `CodexThreadTitleCatalog` performs one bounded read-only SQLite pass per
  catalog scan, preferring Codex's desktop display title and falling back to its
  state title, then the existing JSONL first-message title.
- Selected transcripts use a bounded head/tail reader with message and character
  caps. Markdown mode groups consecutive same-role fragments into conversation
  turns, then parses only the selected sampled transcript off-main,
  applies a second set of block/character limits, and replaces images with text.

## Persistence

- Pane locations → `pane-locations.json` next to the workspaces file, pruned
  when panes/workspaces are removed.

- Workspaces → JSON in `~/Library/Application Support/XFinder/` (migrated from a
  legacy `FinderHub` directory if present).
- Agent Inbox hidden/pinned projects → `agent-inbox-preferences.json` in the
  same Application Support directory.
- Session list metadata → `session-catalog.json` in the same directory; this is
  a rebuildable local cache and never contains full transcript bodies.
- `dist/`, `release/`, `.build/`, and `AI_CONTEXT.md` are gitignored.
- Third-party license texts are tracked under `ThirdPartyLicenses/` and copied
  into packaged apps with `THIRD_PARTY_NOTICES.md`.

## CI / distribution

- `.github/workflows/ci.yml` — build + test + package on every push/PR to `main`.
- `.github/workflows/release.yml` — on a `v*` tag, builds and uploads the zip +
  checksum as a GitHub Release.
