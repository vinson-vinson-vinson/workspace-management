# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_open.sh — `workspaces open`: open a workspace in the configured
# IDE(s) by its `ws list` index (or slug). Just the editor — no serving, no
# side effects.
# -----------------------------------------------------------------------------

cmd_open_usage() {
  cat <<'USAGE'
Usage:
  ws open <N | SLUG>

Opens the workspace in the IDE(s) named by FRONTEND_IDE / BACKEND_IDE in
config.sh — vscode (the default), phpstorm, webstorm, or zed. With the SAME
IDE on both sides the workspace opens combined in one window (vscode: the
.code-workspace; zed: one multi-folder window; phpstorm/webstorm: the session
dir as a single project). With DIFFERENT IDEs each worktree opens separately
in its own IDE.

N is the row index printed by `ws list` (the # column); a workspace slug works
too. Index 0 (or "MAIN") is the main workspace: with VS Code it opens
MAIN_WORKSPACE_FILE from config.sh, or — if unset/missing — both main repos in
one new window.

Options:
  -h, --help    Show this help.

Examples:
  ws open 0
  ws open 2
  ws open CU-1234_my-feature
USAGE
}

# The MAIN workspace (`ws open 0`): the two main clones. VS Code prefers
# MAIN_WORKSPACE_FILE when it exists; there is no session dir, so a JetBrains
# IDE opens the repos as two project windows.
open_main_workspace() {
  local workspace_file="$MAIN_WORKSPACE_FILE"
  if [[ -n "$workspace_file" && ! -f "$workspace_file" ]]; then
    warn "MAIN_WORKSPACE_FILE not found ($workspace_file) — opening the repos directly."
    workspace_file=""
  fi
  open_workspace_editors "$FRONTEND_REPO" "$BACKEND_REPO" "$workspace_file" "" "MAIN"
}

cmd_open() {
  local target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) cmd_open_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_open_usage; exit 1 ;;
      *)
        if [[ -n "$target" ]]; then
          err "Expected exactly one argument."; cmd_open_usage; exit 1
        fi
        target="$1"; shift ;;
    esac
  done
  if [[ -z "$target" ]]; then
    cmd_open_usage; exit 1
  fi

  require_configured_ides

  local slug
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    # Index form: resolve against the same fixed sequence `ws list` numbers;
    # 0 is MAIN. 10# guards leading zeros ("08" would otherwise parse as bad
    # octal).
    local n=$((10#$target))
    if (( n == 0 )); then
      open_main_workspace
      return 0
    fi
    local slugs=() line
    while IFS= read -r line; do slugs+=("$line"); done < <(workspace_slugs)
    if (( n < 1 || n > ${#slugs[@]} )); then
      err "Index $n is out of range — 'ws list' shows ${#slugs[@]} workspace(s) (0 = MAIN)."
      exit 1
    fi
    slug="${slugs[n - 1]}"
  elif [[ "$target" == "MAIN" || "$target" == "main" ]]; then
    open_main_workspace
    return 0
  else
    slug="$target"
    if [[ ! -d "$WORKSPACES_ROOT/$slug" ]]; then
      err "No workspace named '$slug' (see 'ws list')."
      exit 1
    fi
  fi

  local session_dir="$WORKSPACES_ROOT/$slug"

  # The .code-workspace only matters when the combined window is VS Code's;
  # every other IDE (and the split case) opens the worktree directories.
  local workspace_file=""
  if [[ "$FRONTEND_IDE" == "vscode" && "$BACKEND_IDE" == "vscode" ]]; then
    workspace_file="$(workspace_file_for "$slug")"
    [[ -f "$workspace_file" ]] || workspace_file="$(legacy_workspace_file_for "$slug")"
    if [[ ! -f "$workspace_file" ]]; then
      err "No workspace file for '$slug' — 'ws create $slug' regenerates it."
      exit 1
    fi
  fi

  open_workspace_editors "$session_dir/$FRONTEND_DIR_NAME" "$session_dir/$BACKEND_DIR_NAME" \
    "$workspace_file" "$session_dir" "$slug"
}
