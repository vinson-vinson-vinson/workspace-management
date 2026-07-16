# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
New entries are collected under **Unreleased** and moved into a version section
when a release is tagged.

## [Unreleased]

### Added
- `ws serve`: browser-tab favicons in served workspaces are badged with the
  workspace's accent color — the app's own icon shrunk to the middle with a
  ring around it in the workspace color (same as the VS Code title bar and
  the `ws list` swatch). Icons are generated per app into the session dir
  (`.favicons/`, pure python3 — no image tooling) and nginx shadows the apps'
  `/_favicons/` icon URLs with exact-match locations; the repos are never
  touched.

### Fixed
- `ws serve`: sudo is requested *before* the nginx block is rewritten. A
  denied/cancelled sudo used to leave the new block on disk unreloaded — and
  every later run then judged the routing "unchanged" and never reloaded it.
- `ws serve`: `/storage/*` URLs (gallery images, logos — user uploads) 404ed
  in served workspaces because the worktree has no `public/storage` link and
  the workspace nginx block serves static files straight from `public/`.
  serve now links `public/storage` to the main repo's `storage/app/public`,
  matching the shared main DB whose records point at main's uploads.

## [1.3.2] — 2026-07-16

### Added
- `EXTRA_WORKSPACE_FOLDERS` config: an array of absolute paths (e.g. shared
  local packages like `~/Projects/packages/laravel-integrations`) appended as
  additional folders to every generated `.code-workspace`. Paths missing on
  the machine are skipped with a warning.

## [1.3.1] — 2026-07-16

### Added
- `NO_OPEN_AFTER_CREATE` config: with `true`, `ws create` builds the workspace
  as usual but doesn't launch VS Code at the end (and no longer requires the
  `code` CLI).
- `USE_REMOTE_MAIN` config: with `true`, `ws create` fetches
  `origin/<base-branch>` in both repos and cuts new workspace branches from
  the live remote instead of the possibly-stale local checkout. A failed
  fetch (e.g. offline) degrades to the last-fetched origin state with a
  warning. New branches are created `--no-track`.

## [1.3.0] — 2026-07-16

### Added
- `ws create` writes VS Code tasks into the `.code-workspace`: on folder open,
  one terminal runs `ws serve`, and when it finishes one terminal per default
  app starts `yarn serve-<app>`. All three share a split panel. Opt out per
  workspace with `ws create -n|--neanderthal`.
- `ws list`: workspace names are clickable (OSC 8 `file://` hyperlinks) and
  open the workspace in VS Code.

### Changed
- `ws serve`: backend vendor clone and yarn install are separate
  spinner/checked steps ("backend vendor cloned", "yarn installed"); yarn's
  output is hidden unless `-v` or the install fails.

## [1.2.0] — 2026-07-16

### Changed
- Slow steps (worktree creation, env copying, nginx reload, SCM ignore sync)
  run behind spinners that resolve into their milestone checks.

## [1.1.0] — 2026-07-15

### Added
- Gradient wordmark banner; condensed command output down to milestone checks.

### Fixed
- `ws serve`: seed the Cognitor JWT key the backend `.env` actually points at
  (missing key made every authenticated request 500).
- `ws serve`: a missing Cognitor key counts as incomplete dependencies — the
  run warns and exits non-zero instead of claiming success.
- `ws serve`: clone the backend vendor before the (slow, network-dependent)
  yarn install so an interrupted install can't leave the backend unbootable;
  exit code reflects degraded runs.

## [1.0.0] — 2026-07-13

### Added
- Unified `workspaces` CLI (alias `ws`) with subcommands `create`, `list`,
  `serve`, `remove`, `sync` — replaces the separate per-action scripts.
- `ws sync` + automatic VS Code Source Control ignore-list syncing, so each
  workspace window only shows its own two repos instead of every worktree.
- `ws list`: aligned table with color swatches, current-workspace marker, and
  served-URL links.

### Changed
- Consistent "workspaces" naming throughout (formerly "worktrees").
- The `.code-workspace` file lives inside the session directory, making each
  workspace self-contained.

## [0.1.0] — 2026-07-06

### Added
- Initial tagged release: per-task git-worktree workspaces cutting matching
  branches across both repos (`anny-ui` + `bookings-api`), VS Code workspace
  generation with per-workspace title-bar colors, serving workspaces at their
  own `<sub>.anny.dev` subdomain via Laravel Valet/nginx, Cognitor key
  seeding, `install.sh`, and Homebrew tap packaging.

[Unreleased]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.3.2...HEAD
[1.3.2]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/vinson-vinson-vinson/workspace-management/releases/tag/v0.1.0
