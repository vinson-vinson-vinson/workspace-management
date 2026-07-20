# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
New entries are collected under **Unreleased** and moved into a version section
when a release is tagged.

## [Unreleased]

### Fixed
- `ws serve`: the backend's own JS dependencies are now provisioned too —
  `node_modules` is cloned from the main repo exactly like `vendor/`. Without
  it, `php artisan horizon:watch` died in every worktree (chokidar, via mjml,
  couldn't resolve) and mail rendering lacked mjml. Warn-only when the main
  repo has no `node_modules`; existing workspaces pick it up on the next
  `ws serve`.

## [2.3.0] — 2026-07-20

### Added
- Per-workspace test databases: `ws create` provisions an empty MySQL DB per
  workspace (`<TEST_DB_PREFIX>_<short-label>`, e.g.
  `anny_bookings_test_cu_1234`), `ws remove` drops it, and the new `ws test
  [slug] [phpunit args…]` runs the backend suite against it — so concurrent
  test runs in different workspaces can't `migrate:fresh` over each other.
  Works because phpunit.xml declares `DB_DATABASE` without `force="true"`, so
  the exported variable wins. Fails closed: no isolated DB → no run, never a
  silent fallback to the shared DB. Dropping is guarded hard (tool-derived
  names only, prefix+suffix pattern, dev DB / shared DB / system schemas
  denylisted) — a skipped drop always beats a wrong one. Config:
  `TEST_DB_ENABLED` (default true), `TEST_DB_PREFIX/HOST/USER/PASSWORD`;
  disabled = exactly the old behavior.

## [2.2.1] — 2026-07-20

### Fixed
- `ws remove`: self-heals from half-deleted worktrees (directory present but
  its `.git` link gone — e.g. after an interrupted removal). Stale
  registrations are pruned before the worktree/branch steps, since they fail
  `git worktree remove`'s validation and pin the branch against deletion; a
  branch that still can't be deleted warns instead of aborting the teardown.
- `ws list`: long branch names in the MAIN row are elided like workspace
  slugs already were (each branch individually when the repos disagree), so
  they can't stretch the WORKSPACE column and push SERVE URL off-screen.

## [2.2.0] — 2026-07-20

### Added
- `ws create` now serves the workspace for non-VS-Code setups. The
  `.code-workspace` tasks block only ever fires in VS Code, so since IDEs became
  configurable in 2.1.0 a Zed/PhpStorm user finished `ws create` with an
  unserved workspace and nothing saying why. `ws create` now runs `ws serve`
  itself when either IDE isn't vscode, matching the zero-step VS Code flow.
  `--neanderthal` still skips it, and an all-VS-Code workspace is untouched.
- `POST_CREATE_TERMINALS` config (default empty): commands auto-started in
  their own terminal tabs after `ws create` — the non-VS-Code counterpart to
  the tasks block, e.g. `yarn serve-<app>` per app plus an agent.
  `$WT_FRONTEND` / `$WT_BACKEND` are substituted with the session worktree
  paths at runtime — single-quote the entries so the literal `$WT_…` survives
  config loading. The new `TERMINAL_APP` setting picks the terminal:
  `terminal` (default, via `osascript`) or `warp` (via a generated launch
  configuration — Warp's URL scheme can't carry commands). Skipped entirely
  for all-VS-Code workspaces, which would otherwise start every dev server
  twice and collide on ports.

## [2.1.1] — 2026-07-20

### Fixed
- `ws serve`: re-pin `HOST`/`PORT` in an app's `.env` even when the file already
  exists. The "keep the existing env" guard returned before the port rewrite, so
  any `.env` already in the worktree — dropped by an editor, a worktree hook, or
  an earlier checkout — kept the main repo's port while nginx proxied to the
  workspace's. The result was a permanent 502 that looked like success from
  every angle: serve printed "envs copied successfully", `ws list` showed the
  workspace as served, and the dev server started cleanly on the wrong port.
  Only `--force` fixed it, and nothing said so. Everything else in the file is
  still preserved.
- `ws serve`: `set_env_var` no-ops when the exact `KEY=value` line is already
  present, so the HOST/PORT re-pin on every serve run doesn't bump the `.env`
  mtime — a running dev server watching the file would restart for nothing.

## [2.1.0] — 2026-07-17

### Added
- Configurable IDEs: new `FRONTEND_IDE` / `BACKEND_IDE` config settings
  (default `vscode`; also `phpstorm`, `webstorm`, `zed`). `ws open` and
  `ws create` open the workspace in the configured IDE(s): the same IDE on
  both sides opens ONE combined window (vscode: the `.code-workspace`; zed:
  one multi-folder window; phpstorm/webstorm — no multi-root projects — the
  session dir as a single project), while different IDEs open each worktree
  separately in its own IDE. Each IDE needs its CLI launcher on `PATH`
  (`code` / `phpstorm` / `webstorm` / `zed`); a missing one fails with an
  install hint.

## [2.0.0] — 2026-07-16

The tool is now simply **workspaces** — new single-row wordmark with a
gradient racing stripe, a redesigned `ws list`, and everything the 1.3–1.7
series built up to (auto-serve terminals, badged favicons, `ws open`,
`ws trust`, base-branch stacking). No breaking changes; the major bump marks
the identity change.

### Added
- `ws open 0` (or `ws open MAIN`) opens the main workspace: the new optional
  `MAIN_WORKSPACE_FILE` config names its .code-workspace; without it, both
  main repos open together in one new VS Code window. `ws list` numbers the
  MAIN row 0 and links its name to that file.

### Changed
- The in-tool wordmark is now "WORKSPACES" (one banner row instead of the
  stacked "WORKSPACE MANAGEMENT" two-row block) — the tool goes by the
  command's own name; the repo, sudoers file, and XDG config path keep the
  long name.
- `ws list` got a redesign: the wordmark banner over a rounded box-drawing
  table (`#` / `Workspace` / `Serve URL`), with a spinner while the rows are
  collected. The color swatch moved into the Workspace column next to the
  clickable name, and the current workspace is starred in the `#` column.
  Piped output keeps the plain aligned column format (and `--quiet` is
  untouched), so scripts keep working.

## [1.7.0] — 2026-07-16

### Added
- `REQUIRE_CONFIRM_REMOVE` config (default `true`): set to `false` to skip
  `ws remove`'s "Continue? [y/N]" prompt. Only the prompt — the
  protected-branch guard and the uncommitted/unpushed-work check still apply.
- `ws trust`: one-time sudoers drop-in (like `valet trust`) that allows
  exactly `nginx -t` and `nginx -s reload` without a password — the password
  is entered once to install the rule and never stored. Every nginx-touching
  command (`ws serve`, `ws remove`, and thus `ws create`'s auto-serve
  terminal) skips its sudo prompt when the rule is present, via one shared
  check (a `sudo -v` would still prompt despite the command-scoped rule, so
  it's bypassed, not attempted). `ws trust --revoke` removes the rule; the
  generated file is visudo-validated before it touches /etc/sudoers.d.

## [1.6.0] — 2026-07-16

### Added
- `ws open <N|slug>`: open a workspace's VS Code window by its `ws list` row
  index (or slug) — just the editor, no other side effects. `ws list` gained
  a `#` column with the row numbers; both commands enumerate workspaces
  through one shared helper so the indices can't drift apart.

## [1.5.0] — 2026-07-16

### Added
- `ws create <name> [BASE_BRANCH]`: base the new workspace branches on an
  existing branch instead of the configured base — e.g. to stack follow-up
  work on a feature still in review. Applied per repo where the branch exists
  (locally or on origin); a repo without it falls back to its configured base
  with a warning, and the "branches created from" milestone spells out both
  bases when they differ. Missing in both repos is an error.

### Removed
- Homebrew packaging (`packaging/`, `PACKAGING.md`, README install section):
  the tap was unused — everyone installs via git clone + `install.sh`. The
  `vinson-vinson-vinson/homebrew-tap` repo is orphaned by this and can be deleted.

## [1.4.0] — 2026-07-16

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

[Unreleased]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v2.3.0...HEAD
[2.3.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v2.2.1...v2.3.0
[2.2.1]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v2.1.1...v2.2.0
[2.1.1]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.7.0...v2.0.0
[1.7.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.3.2...v1.4.0
[1.3.2]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/vinson-vinson-vinson/workspace-management/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/vinson-vinson-vinson/workspace-management/releases/tag/v0.1.0
