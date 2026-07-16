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

Options:
  -h, --help    Show this help.

Examples:
  ws open 2
  ws open CU-1234_my-feature
USAGE
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
    # Index form: resolve against the same fixed sequence `ws list` numbers.
    # 10# guards leading zeros ("08" would otherwise parse as bad octal).
    local n=$((10#$target))
    local slugs=() line
    while IFS= read -r line; do slugs+=("$line"); done < <(workspace_slugs)
    if (( n < 1 || n > ${#slugs[@]} )); then
      err "Index $n is out of range — 'ws list' shows ${#slugs[@]} workspace(s)."
      exit 1
    fi
    slug="${slugs[n - 1]}"
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
