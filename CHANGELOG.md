# Changelog

Key user-visible changes to XFinder. Newest first.

## [Unreleased]

## [0.6.0] — Network Status Center

### Added
- Network Status center in the sidebar with bounded checks for OpenAI API, Claude API, Baidu, Tencent, and custom HTTP(S) endpoints.
- Egress IP/approximate region and provider availability-risk indicators, with live API rejection kept separate from policy-list inference.
- On-demand stability monitoring with latency, P95, jitter, success rate, DNS/TCP/TLS/TTFB detail, and bounded history sparklines.
- Live physical-interface upload/download rates plus an explicit, cancellable macOS `networkQuality` capacity test.

## [0.5.0] — Agent Center and Session Review

### Added
- Agent Center unifies Inbox and Sessions navigation, adds rendered Markdown session reading/copying, and supports direct project/session round trips.
- File lists can now sort by Size and Kind as well as Name and Modified.

### Changed
- Agent Center shares a persistent session metadata catalog and samples oversized transcripts with hard performance limits.
- Markdown sessions group consecutive fragments into IM-style turns, with user input on the right and assistant replies on the left.

### Fixed
- File double-click handling is reliable across list, icon, and column views, including video-heavy folders; external-open failures now appear in Activity & Errors.
- Codex sessions use the same generated or renamed display titles shown by Codex instead of always using the first user message.

## [0.4.0] — Markdown Workflow and Finder Polish

### Added
- Built-in lightweight Markdown reading and editing with preview/source/split modes and protected saves.
- Markdown reader improvements: same-folder Markdown navigation, in-document search, task checkbox toggling, `==highlight==` rendering, rich-text copy, PDF export, syntax cheatsheet insertion, and note/meeting/research templates.
- Markdown external-change sync for clean documents, with activity feedback and changed-block highlighting.
- Read Aloud for documents and searchable PDFs, with optional Doubao Speech and automatic system-voice fallback.
- Skill Center search: a search box in the filter bar narrows the catalog by skill name or description, combined with the state/agent filters.
- Skill Center now also scans Codex skills (`~/.codex/skills/<name>/SKILL.md`) as a first-class "Codex" agent — Codex started storing skills in the same SKILL.md format, so they now appear in the unified catalog (and aggregate/flag drift against same-named Claude/Trae skills). Its `.system` internals and vendor imports are left out.
- Agent Inbox: local project-level review workbench for Claude / Codex activity, git changes, risk findings, related sessions, and commit-message drafts.
- Agent Inbox project governance: pin important projects, multi-select projects, bulk-hide low-value projects, and persist those preferences locally.
- Finder-style file essentials: Quick Look, Get Info, File Actions menu, recursive search, duplicate, undo/redo for common operations, and cancellable compression tasks.

### Changed
- File row context menus are grouped by open/view actions, copy actions, organization actions, and destructive actions; they now include a Finder-compatible Copy command alongside Copy Path and Copy To.
- Markdown window toolbar labels and feedback are clearer, including copy confirmation and a shorter PDF export label.
- Agent Inbox now reuses an in-memory snapshot when reopened; manual refresh performs the full rescan.
- Agent Inbox reads full transcripts only after a project is selected, keeping the project list fast.
- Related sessions in Agent Inbox can jump directly into the full session view; the sidebar keeps that view as `All Sessions`.
- Agent Inbox detail text is selectable for copying paths, findings, related-session text, decisions, todos, and commit drafts.
- What's New / CHANGELOG content is now summarized around major functional changes instead of exhaustive implementation notes.

### Fixed
- Selecting a file no longer quickly slips into rename mode; rename keeps Finder-like delayed behavior and context-menu access.
- Empty Markdown files open cleanly without parser/read errors.
- Folder ordering stays stable when filesystem refreshes happen in a project folder.
- Markdown Read Aloud can be stopped by clicking the read button again.
- Markdown windows no longer show overlapping duplicate title text.
- Cmd+A selects visible files in the focused pane.
- Compression failures now report clearer diagnostics and avoid leaving the UI waiting on a lost zip process.
- Reduced file-pane CPU spikes during large expanded lists and bursty filesystem changes.

## [0.3.0] — Agent-Aware File Management

### Highlights
- Renamed the app/package/release artifacts to XFinder.
- Added Skill Center and Session Center for local agent skills and transcripts.
- Added git-aware panes: row badges, project status, recent changes, in-app diff, and optional Claude explanation.
- Added Claude Code bridge actions while keeping Claude integration opt-in.
- Added hidden-file browsing, app-package browsing, stars, multi-pane layout improvements, live refresh, and bilingual UI.
- Added CI, swift-format, swift-testing coverage, architecture docs, and project collaboration rules.

## [0.1.5]

- Baseline tagged release: multi-pane browsing, rename, drag-move between panes, sorting, adaptive resizable columns, toolbar double-click zoom, and GitHub Release distribution.
