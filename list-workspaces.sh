#!/usr/bin/env bash

set -euo pipefail

# Load configuration (see config.example.sh). WSM_CONFIG can point elsewhere.
# Resolve this script's real dir following symlinks, so it still finds config.sh
# when symlinked onto your PATH (see install.sh).
_src="${BASH_SOURCE[0]}"
while [[ -h "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
CONFIG_FILE="${WSM_CONFIG:-$SCRIPT_DIR/config.sh}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  printf 'ERROR: config file not found: %s\n' "$CONFIG_FILE" >&2
  printf 'Copy config.example.sh to config.sh and edit it (or set WSM_CONFIG).\n' >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

MAIN_FRONTEND="$FRONTEND_REPO"                 # main workspace repos (not under worktrees)
MAIN_BACKEND="$BACKEND_REPO"

# Lowercased task-id prefix, used for case-insensitive slug matching.
TASK_ID_PREFIX_LC="$(printf '%s' "$TASK_ID_PREFIX" | tr '[:upper:]' '[:lower:]')"

QUIET=false

# ANSI green + OSC 8 hyperlinks, only when stdout is a terminal.
if [[ -t 1 ]]; then
  GREEN=$'\033[32m'
  RESET=$'\033[0m'
  TTY=true
else
  GREEN=""
  RESET=""
  TTY=false
fi

# Render a clickable, green link for a bare host+path (https:// is added here).
# On a terminal, wraps the URL in an OSC 8 hyperlink so it opens in the browser;
# otherwise prints the plain https URL.
link() {
  local url="https://$1"
  if "$TTY"; then
    printf '\033]8;;%s\033\\%s%s%s\033]8;;\033\\' "$url" "$GREEN" "$url" "$RESET"
  else
    printf '%s' "$url"
  fi
}

print_usage() {
  cat <<'USAGE'
Usage:
  list-workspaces.sh [--quiet]

Lists all workspaces that currently exist under the worktrees root. A workspace
is a session directory created by create-workspace.sh, containing the frontend
and backend git worktrees.

Each line shows the workspace name, and — if the workspace is being served by
serve-workspace.sh — a green link to its admin calendar.

Options:
  -q, --quiet   Print only the workspace names, one per line (script-friendly).
  -h, --help    Show this help.

Examples:
  list-workspaces.sh
  list-workspaces.sh --quiet
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q|--quiet)
        QUIET=true
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      -*)
        printf '[list] ERROR: Unknown option: %s\n' "$1" >&2
        print_usage
        exit 1
        ;;
      *)
        printf '[list] ERROR: Unexpected argument: %s\n' "$1" >&2
        print_usage
        exit 1
        ;;
    esac
  done
}

# Echo a repo's current branch, or empty if none/detached.
repo_branch() {
  local repo="$1"
  [[ -d "$repo/.git" ]] || return 0
  git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# Echo the branch label for the main workspace: one branch if both repos agree,
# otherwise both labeled. Empty if neither repo resolves.
main_branch_label() {
  local fe be
  fe="$(repo_branch "$MAIN_FRONTEND")"
  be="$(repo_branch "$MAIN_BACKEND")"
  if [[ -n "$fe" && "$fe" == "$be" ]]; then
    printf '%s' "$fe"
  elif [[ -n "$fe" || -n "$be" ]]; then
    printf '%s:%s %s:%s' "$FRONTEND_DIR_NAME" "${fe:-?}" "$BACKEND_DIR_NAME" "${be:-?}"
  fi
}

# Derive the serve-workspace subdomain from a slug's task id.
# Echoes e.g. "cu-1234" for "CU-1234_feature"; returns 1 if not a CU- pattern.
resolve_subdomain() {
  local slug="$1" sub
  sub="$(printf '%s' "${slug%%_*}" | tr '[:upper:]' '[:lower:]')"
  [[ "$sub" =~ ^${TASK_ID_PREFIX_LC}-[a-z0-9]+$ ]] || return 1
  printf '%s' "$sub"
}

# Echo the admin URL for a slug if an nginx block exists, else nothing.
# Always returns 0 so `url="$(admin_url ...)"` is safe under `set -e`.
admin_url() {
  local slug="$1" sub host
  sub="$(resolve_subdomain "$slug")" || return 0
  host="${sub}.${BASE_DOMAIN}"
  if [[ -f "$VALET_NGINX_DIR/$host" ]]; then
    printf '%s' "${host}${ADMIN_PATH}"
  fi
  return 0
}

main() {
  parse_args "$@"

  local cwd
  cwd="$(pwd -P)"

  # Collect workspace slugs: immediate subdirectories of the worktrees root.
  local slugs=()
  if [[ -d "$WORKTREES_ROOT" ]]; then
    local entry
    for entry in "$WORKTREES_ROOT"/*/; do
      [[ -d "$entry" ]] || continue
      slugs+=("$(basename "$entry")")
    done
  fi

  # Figure out which workspace the CLI is currently inside. Each workspace owns a
  # few base dirs (frontend, backend, and their parent); the workspace whose base
  # is the LONGEST prefix of the cwd wins, so sitting in a task worktree stars
  # that task rather than MAIN (whose parent, the project root, also matches).
  local -a cand_key=() cand_base=()
  cand_key+=("MAIN"); cand_base+=("$ROOT_DIR")        # parent dir
  cand_key+=("MAIN"); cand_base+=("$MAIN_FRONTEND")
  cand_key+=("MAIN"); cand_base+=("$MAIN_BACKEND")
  local slug
  for slug in "${slugs[@]}"; do
    cand_key+=("$slug"); cand_base+=("$WORKTREES_ROOT/$slug")  # covers front/back/parent
  done

  local current_key="" best_len=-1 i base
  for i in "${!cand_base[@]}"; do
    base="${cand_base[$i]}"
    if [[ "$cwd" == "$base" || "$cwd" == "$base/"* ]] && (( ${#base} > best_len )); then
      best_len=${#base}
      current_key="${cand_key[$i]}"
    fi
  done

  if "$QUIET"; then
    printf 'MAIN\n'
    [[ ${#slugs[@]} -gt 0 ]] && printf '%s\n' "${slugs[@]}"
    exit 0
  fi

  # A leading "* " marks the workspace containing the cwd; others get "  " so the
  # names stay column-aligned.
  local m

  # Main workspace: the root repos, always served at anny.dev.
  local main_label
  main_label="$(main_branch_label)"
  [[ "$current_key" == "MAIN" ]] && m='* ' || m='  '
  printf '%sMAIN %s  %s\n' "$m" "$main_label" "$(link "${BASE_DOMAIN}${ADMIN_PATH}")"

  local url
  for slug in "${slugs[@]}"; do
    [[ "$current_key" == "$slug" ]] && m='* ' || m='  '
    url="$(admin_url "$slug")"
    if [[ -n "$url" ]]; then
      printf '%s%s  %s\n' "$m" "$slug" "$(link "$url")"
    else
      printf '%s%s\n' "$m" "$slug"
    fi
  done
}

main "$@"
