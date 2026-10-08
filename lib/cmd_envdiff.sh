# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_envdiff.sh — `workspaces envdiff`: what a workspace's .env files carry
# that MAIN's don't. The same comparison `ws remove` runs before deleting, so
# keys can be ported to MAIN while the workspace is still alive.
# -----------------------------------------------------------------------------

# shellcheck source=/dev/null
source "$LIB_DIR/envs.sh"

cmd_envdiff_usage() {
  cat <<'USAGE'
Usage:
  ws envdiff [N|SLUG] [--show-secrets] [-v]

Arguments:
  N|SLUG      Workspace slug, or its `ws list` index (the # column). If omitted,
              auto-detects from the current directory.

Options:
  --show-secrets  Print secret-looking values (SECRET/TOKEN/PASS/KEY/…) in full
                  instead of masked.
  -v, --verbose   Show step-by-step detail.
  -h, --help      Show this help.

Compares bookings-api/.env and every anny-ui/app-*/.env in the workspace with
its MAIN counterpart and lists what the workspace has that MAIN doesn't:

  + KEY = value             key MAIN doesn't have
  ~ KEY = value (MAIN: …)   same key, different value
  # KEY = value             a commented-out line MAIN doesn't have

What `ws serve` rewrites is ignored: the workspace host inside URLs, and the
pinned HOST / PORT / HMR_PORT / STORAGE_PREFIX. `ws remove` prints this same
report and backs the files up (see ENV_BACKUP_DIR) before deleting anything.

Examples:
  ws envdiff                       # the workspace you're in
  ws envdiff 3
  ws envdiff CU-1234_my-feature --show-secrets
USAGE
}

cmd_envdiff() {
  local slug=""
  ENV_SHOW_SECRETS=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --show-secrets) ENV_SHOW_SECRETS=true; shift ;;
      -v|--verbose)   VERBOSE=true; shift ;;
      -h|--help)      cmd_envdiff_usage; exit 0 ;;
      -*)             err "Unknown option: $1"; cmd_envdiff_usage; exit 1 ;;
      *)
        if [[ -n "$slug" ]]; then
          err "Too many arguments: $1"; cmd_envdiff_usage; exit 1
        fi
        slug="$1"; shift ;;
    esac
  done

  if [[ "$slug" =~ ^[0-9]+$ ]]; then
    local n=$((10#$slug))
    if (( n == 0 )); then
      err "Index 0 is MAIN — there is nothing to compare it with."
      exit 1
    fi
    local _slugs=() _line
    while IFS= read -r _line; do _slugs+=("$_line"); done < <(workspace_slugs)
    if (( n < 1 || n > ${#_slugs[@]} )); then
      err "Index $n is out of range — 'ws list' shows ${#_slugs[@]} workspace(s) (0 = MAIN)."
      exit 1
    fi
    slug="${_slugs[n - 1]}"
    vlog "Resolved index $n -> $slug"
  fi

  if [[ -z "$slug" ]]; then
    slug="$(slug_from_cwd)" || {
      err "Not inside a workspace directory and no slug provided."
      err "Expected a path under: $WORKSPACES_ROOT/"
      exit 1
    }
    vlog "Auto-detected slug from CWD: $slug"
  fi

  local session_dir="$WORKSPACES_ROOT/$slug"
  if [[ ! -d "$session_dir" ]]; then
    err "No such workspace: $slug (see 'ws list')."
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required to compare env files."
    exit 1
  fi

  printf '  %senvs of %s vs MAIN%s  %s(serve'"'"'s host/port rewrites ignored)%s\n' \
    "$C_BOLD" "$slug" "$C_RESET" "$C_DIM" "$C_RESET"
  env_report "$slug" "$session_dir" terminal
  if (( ENV_DIFF_COUNT == 0 )); then
    ok "envs match MAIN — nothing to carry over"
  else
    printf '  %s%d difference(s) — port what you need into MAIN before removing%s\n' \
      "$C_DIM" "$ENV_DIFF_COUNT" "$C_RESET"
  fi
  return 0
}
