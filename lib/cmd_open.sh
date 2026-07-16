# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_open.sh — `workspaces open`: open a workspace's VS Code window by its
# `ws list` index (or slug). Just the editor — no serving, no side effects.
# -----------------------------------------------------------------------------

cmd_open_usage() {
  cat <<'USAGE'
Usage:
  ws open <N | SLUG>

Opens the workspace's .code-workspace in VS Code. N is the row index printed
by `ws list` (the # column); a workspace slug works too.

Index 0 (or "MAIN") is the main workspace: it opens MAIN_WORKSPACE_FILE from
config.sh, or — if unset/missing — both main repos in one new VS Code window.

Options:
  -h, --help    Show this help.

Examples:
  ws open 0
  ws open 2
  ws open CU-1234_my-feature
USAGE
}

# The MAIN workspace (`ws open 0`): MAIN_WORKSPACE_FILE from the config when
# it exists, otherwise both main repos together in one new VS Code window.
open_main_workspace() {
  if [[ -n "$MAIN_WORKSPACE_FILE" && -f "$MAIN_WORKSPACE_FILE" ]]; then
    code -n "$MAIN_WORKSPACE_FILE"
    ok "VS Code opened (MAIN — $(basename "$MAIN_WORKSPACE_FILE"))"
    return 0
  fi
  [[ -n "$MAIN_WORKSPACE_FILE" ]] \
    && warn "MAIN_WORKSPACE_FILE not found ($MAIN_WORKSPACE_FILE) — opening the repos directly."
  code -n "$FRONTEND_REPO" "$BACKEND_REPO"
  ok "VS Code opened (MAIN — $FRONTEND_DIR_NAME + $BACKEND_DIR_NAME)"
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

  require_command code

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

  local workspace_file
  workspace_file="$(workspace_file_for "$slug")"
  [[ -f "$workspace_file" ]] || workspace_file="$(legacy_workspace_file_for "$slug")"
  if [[ ! -f "$workspace_file" ]]; then
    err "No workspace file for '$slug' — 'ws create $slug' regenerates it."
    exit 1
  fi

  code -n "$workspace_file"
  ok "VS Code opened ($slug)"
}
