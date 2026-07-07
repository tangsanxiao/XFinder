# Changelog

Key user-visible changes to XFinder. Newest first.

## [Unreleased]

### Added
- Skill Center search: a search box in the filter bar narrows the catalog by skill name or description, combined with the state/agent filters.
- Skill Center now also scans Codex skills (`~/.codex/skills/<name>/SKILL.md`) as a first-class "Codex" agent — Codex started storing skills in the same SKILL.md format, so they now appear in the unified catalog (and aggregate/flag drift against same-named Claude/Trae skills). Its `.system` internals and vendor imports are left out.
- Agent Inbox: local project-level review workbench for Claude / Codex activity, git changes, risk findings, related sessions, and commit-message drafts.
- Agent Inbox project governance: pin important projects, multi-select projects, bulk-hide low-value projects, and persist those preferences locally.
- Finder-style file essentials: Quick Look, Get Info, File Actions menu, recursive search, duplicate, undo/redo for common operations, and cancellable compression tasks.

### Changed
- Agent Inbox now reuses an in-memory snapshot when reopened; manual refresh performs the full rescan.
- Agent Inbox reads full transcripts only after a project is selected, keeping the project list fast.
- Related sessions in Agent Inbox can jump directly into the full session view; the sidebar keeps that view as `All Sessions`.
- Agent Inbox detail text is selectable for copying paths, findings, related-session text, decisions, todos, and commit drafts.
- What's New / CHANGELOG content is now summarized around major functional changes instead of exhaustive implementation notes.

### Fixed
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
