# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_sync.sh — `workspaces sync`: recompute each workspace's VS Code
# git.ignoredRepositories so every window shows only its own worktrees.
#
# All worktrees of a repo share one .git, so VS Code's built-in Source Control
# would otherwise list every workspace's worktrees (and the main clones) in
# every window. This regenerates the per-workspace deny-list from the current
# worktree set. Runs automatically on create/remove; this exposes a manual
# re-sync (e.g. after editing worktrees by hand).
# -----------------------------------------------------------------------------

cmd_sync_usage() {
  cat <<'USAGE'
Usage:
  ws sync [--dry-run]

Recompute the VS Code Source Control ignore-list (git.ignoredRepositories) in
every workspace's .code-workspace file so each window shows only its own
frontend/backend worktrees — hiding the other workspaces' worktrees and the
main clones. Idempotent and safe to run anytime; runs automatically on
`ws create` and `ws remove`.

Options:
  --dry-run     Show what would happen without writing any files.
  -h, --help    Show this help.
USAGE
}

cmd_sync() {
  DRY_RUN=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  DRY_RUN=true; shift ;;
      -h|--help)  cmd_sync_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_sync_usage; exit 1 ;;
      *)  err "Unexpected argument: $1"; cmd_sync_usage; exit 1 ;;
    esac
  done
  # Manual invocation: the sync IS the headline here, so announce the result.
  sync_scm_ignores announce
}
