#!/usr/bin/env bash

set -euo pipefail

# Load configuration (see config.example.sh). Resolution order:
#   1. $WSM_CONFIG                                     (explicit override)
#   2. config.sh next to the script                   (git clone / install.sh)
#   3. $XDG_CONFIG_HOME/workspace-management/config.sh (Homebrew / packaged)
# Resolve this script's real dir following symlinks so a sibling config.sh is
# found even when the command is symlinked onto your PATH (install.sh / brew).
_src="${BASH_SOURCE[0]}"
while [[ -h "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
_xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}/workspace-management/config.sh"
if [[ -n "${WSM_CONFIG:-}" ]]; then
  CONFIG_FILE="$WSM_CONFIG"
elif [[ -f "$SCRIPT_DIR/config.sh" ]]; then
  CONFIG_FILE="$SCRIPT_DIR/config.sh"
else
  CONFIG_FILE="$_xdg_config"
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
  printf 'ERROR: config file not found: %s\n' "$CONFIG_FILE" >&2
  printf 'Copy config.example.sh to config.sh next to the scripts, or to\n' >&2
  printf '  %s\n' "$_xdg_config" >&2
  printf 'or point WSM_CONFIG at your config file.\n' >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Lowercased task-id prefix, used for case-insensitive slug matching.
TASK_ID_PREFIX_LC="$(printf '%s' "$TASK_ID_PREFIX" | tr '[:upper:]' '[:lower:]')"

DRY_RUN=false
FORCE=false
VERBOSE=false
TARGET_SLUG=""

print_usage() {
  cat <<'USAGE'
Usage:
  remove-workspace.sh [SLUG] [--dry-run] [--force]

Arguments:
  SLUG        The workspace slug (e.g. CU-86c9vwd5w_generic-remote-open-integration).
              If omitted, auto-detects from current working directory.

Options:
  --dry-run     Show what would be done without executing.
  --force       Skip the confirmation prompt AND the unpushed-work safety check.
                Removes worktrees and deletes local branches even when they have
                uncommitted changes or unpushed/diverged commits.
  -v, --verbose Show nginx's own output/warnings (hidden by default on success).
  -h, --help    Show this help.

Safety:
  - Works for any workspace name, but refuses to remove a worktree that is on a
    protected base branch (main/master or your configured base branch).
  - Checks for uncommitted changes and unpushed commits before removal.
  - Aborts if any worktree has local-only work (unless --force is given).

Examples:
  remove-workspace.sh                                     # auto-detect from cwd
  remove-workspace.sh CU-86c9vwd5w_generic-remote-open-integration
  remove-workspace.sh CU-86c9vwd5w_generic-remote-open-integration --dry-run
  remove-workspace.sh CU-86c9vwd5w_generic-remote-open-integration --force
USAGE
}

log() {
  printf '[remove] %s\n' "$*"
}

err() {
  printf '[remove] ERROR: %s\n' "$*" >&2
}

warn() {
  printf '[remove] WARN: %s\n' "$*" >&2
}

run_cmd() {
  if "$DRY_RUN"; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Run an nginx command, hiding its (noisy, valet-wide) deprecation warnings on
# success. Output is shown only with --verbose, or always when the command fails.
run_nginx() {
  local out status=0
  # `|| status=$?` keeps `set -e` from aborting on a failed nginx command, so we
  # can print its captured output ourselves before returning the error.
  out="$(sudo nginx "$@" 2>&1)" || status=$?
  if [[ $status -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    return "$status"
  fi
  if "$VERBOSE"; then
    printf '%s\n' "$out"
  fi
  return 0
}

# Derive the serve-workspace subdomain label from a slug (same logic as
# serve-workspace): the task id for a task slug, otherwise the whole slug,
# lowercased with non-DNS characters collapsed to '-'. Returns 1 if nothing
# usable remains.
resolve_subdomain() {
  local slug="$1"
  local sub
  sub="$(printf '%s' "${slug%%_*}" | tr '[:upper:]' '[:lower:]')"
  sub="$(printf '%s' "$sub" | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$sub" ]] || return 1
  printf '%s' "$sub"
}

# Reverse whatever serve-workspace.sh set up: remove the nginx block and reload.
# The copied envs / installed node_modules / cloned vendor live inside the
# session dir and are removed with it, so nothing else needs undoing here.
revert_serve_setup() {
  local slug="$1"
  local sub host conf
  if ! sub="$(resolve_subdomain "$slug")"; then
    log "Slug has no CU- subdomain mapping; no routing to revert."
    return 0
  fi
  host="${sub}.${BASE_DOMAIN}"
  conf="$VALET_NGINX_DIR/$host"

  if [[ ! -f "$conf" ]]; then
    log "No nginx block for $host. Nothing to revert."
    return 0
  fi

  log "Reverting routing for https://$host"
  if "$DRY_RUN"; then
    printf '[dry-run] rm -f %s\n' "$conf"
    printf '[dry-run] sudo nginx -t && sudo nginx -s reload\n'
    return 0
  fi

  sudo -v || { err "sudo is required to reload nginx."; exit 1; }
  rm -f "$conf"
  if run_nginx -t && run_nginx -s reload; then
    log "Removed nginx block and reloaded nginx."
  else
    warn "nginx reload failed after removing $conf — check the config manually."
  fi
}

parse_args() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      -*)
        err "Unknown option: $1"
        print_usage
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -gt 1 ]]; then
    err "Expected at most one positional argument (slug)."
    print_usage
    exit 1
  fi

  if [[ ${#positional[@]} -eq 1 ]]; then
    TARGET_SLUG="${positional[0]}"
  fi
}

detect_slug_from_cwd() {
  local cwd="$PWD"

  # Check if we're inside a worktree under WORKTREES_ROOT
  if [[ "$cwd" != "$WORKTREES_ROOT/"* ]]; then
    err "Not inside a worktree directory and no slug provided."
    err "CWD: $cwd"
    err "Expected path under: $WORKTREES_ROOT/"
    exit 1
  fi

  # Extract the slug (first path component after WORKTREES_ROOT)
  local relative="${cwd#"$WORKTREES_ROOT/"}"
  TARGET_SLUG="${relative%%/*}"

  if [[ -z "$TARGET_SLUG" ]]; then
    err "Could not determine workspace slug from CWD."
    exit 1
  fi

  log "Auto-detected slug from CWD: $TARGET_SLUG"
}

# The branch a worktree currently has checked out (empty if detached/unknown).
worktree_branch() {
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# True if BRANCH is one of the protected base ("main") branches.
is_protected_branch() {
  local branch="$1"
  [[ -n "$branch" ]] || return 1
  case "$branch" in
    "$FRONTEND_BASE_BRANCH"|"$BACKEND_BASE_BRANCH"|main|master) return 0 ;;
    *) return 1 ;;
  esac
}

# SAFETY: never remove a workspace whose worktrees are on a protected base
# ("main") branch. A task/plain workspace always sits on its own slug branch, so
# this only ever fires when the tooling is pointed at a main/base checkout.
guard_not_main() {
  local slug="$1" fe="$2" be="$3"
  local fe_branch="" be_branch=""
  [[ -d "$fe" ]] && fe_branch="$(worktree_branch "$fe")"
  [[ -d "$be" ]] && be_branch="$(worktree_branch "$be")"
  if is_protected_branch "$fe_branch" || is_protected_branch "$be_branch"; then
    err "Refusing to remove '$slug': worktree is on a protected branch (frontend='$fe_branch', backend='$be_branch')."
    err "This protects your main worktree from accidental deletion."
    exit 1
  fi
}

# Check if a worktree has uncommitted changes (staged or unstaged)
has_uncommitted_changes() {
  local worktree_path="$1"
  [[ -d "$worktree_path" ]] || return 1

  local status_output
  status_output="$(git -C "$worktree_path" status --porcelain 2>/dev/null)"
  [[ -n "$status_output" ]]
}

# Check if a worktree has commits that exist ONLY locally (on no remote).
# Counts commits reachable from HEAD but from no remote-tracking ref
# (origin/*). This is 0 for a fresh branch cut from main (its tip is already on
# origin/main), for a branch pushed to its own remote, or for one with an
# upstream it's not ahead of — and >0 only when there is genuine local-only work.
# (The previous logic flagged any branch without an origin/<branch> as unpushed,
# even when it had zero commits beyond main — a false positive.)
has_unpushed_commits() {
  local worktree_path="$1"
  [[ -d "$worktree_path" ]] || return 1
  git -C "$worktree_path" rev-parse --verify HEAD &>/dev/null || return 1

  local count
  count="$(git -C "$worktree_path" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
  [[ "${count:-0}" -gt 0 ]]
}

check_worktree_clean() {
  local worktree_path="$1"
  local label="$2"
  local issues=()

  if [[ ! -d "$worktree_path" ]]; then
    log "$label worktree not found at $worktree_path — skipping checks."
    return 0
  fi

  if has_uncommitted_changes "$worktree_path"; then
    issues+=("has uncommitted changes")
  fi

  if has_unpushed_commits "$worktree_path"; then
    issues+=("has unpushed commits")
  fi

  if [[ ${#issues[@]} -gt 0 ]]; then
    err "$label worktree ($worktree_path):"
    for issue in "${issues[@]}"; do
      err "  - $issue"
    done
    return 1
  fi

  log "$label worktree is clean."
  return 0
}

confirm_removal() {
  local slug="$1"

  if "$FORCE" || "$DRY_RUN"; then
    return 0
  fi

  printf '[remove] About to remove workspace: %s\n' "$slug"
  printf '[remove] This will:\n'
  printf '  - Revert serve routing (remove nginx block + reload), if any\n'
  printf '  - Remove git worktrees (frontend + backend)\n'
  printf '  - Delete local branches\n'
  printf '  - Remove session directory\n'
  printf '  - Remove .code-workspace file\n'
  printf 'Continue? [y/N] '
  read -r answer
  case "$answer" in
    [Yy]|[Yy]es) return 0 ;;
    *) log "Aborted."; exit 0 ;;
  esac
}

remove_worktree() {
  local repo="$1"
  local worktree_path="$2"
  local label="$3"

  if [[ ! -d "$worktree_path" ]]; then
    log "$label worktree does not exist. Skipping."
    return 0
  fi

  # Check if registered as a worktree
  if git -C "$repo" worktree list --porcelain | grep -Fqx "worktree $worktree_path"; then
    log "Removing $label worktree: $worktree_path"
    # Tolerate failure: serve-workspace adds ignored files (installed
    # node_modules, cloned vendor, copied .env). The session-dir rm -rf and the
    # `git worktree prune` in main finish the cleanup if this can't.
    if "$FORCE"; then
      run_cmd git -C "$repo" worktree remove -f "$worktree_path" \
        || warn "git worktree remove failed for $worktree_path; will clean up directly."
    else
      run_cmd git -C "$repo" worktree remove "$worktree_path" \
        || warn "git worktree remove failed for $worktree_path; retry with --force or push your work."
    fi
  else
    warn "$label path exists but is not a registered git worktree: $worktree_path"
    warn "Skipping git worktree removal. Directory will still be cleaned up."
  fi
}

remove_local_branch() {
  local repo="$1"
  local branch="$2"
  local label="$3"

  # Never delete a protected base branch, even if its worktree was already gone.
  if is_protected_branch "$branch"; then
    warn "Refusing to delete protected base branch '$branch' in $label repo."
    return 0
  fi

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    log "Deleting local $label branch: $branch"
    run_cmd git -C "$repo" branch -D "$branch"
  else
    log "No local $label branch '$branch'. Skipping."
  fi
}

main() {
  parse_args "$@"

  # Auto-detect slug if not provided
  if [[ -z "$TARGET_SLUG" ]]; then
    detect_slug_from_cwd
  fi

  local session_dir="$WORKTREES_ROOT/$TARGET_SLUG"
  local frontend_worktree="$session_dir/$FRONTEND_DIR_NAME"
  local backend_worktree="$session_dir/$BACKEND_DIR_NAME"
  local workspace_file="$ROOT_DIR/$TARGET_SLUG.code-workspace"

  log "Slug: $TARGET_SLUG"
  log "Session dir: $session_dir"
  log "Frontend worktree: $frontend_worktree"
  log "Backend worktree: $backend_worktree"
  log "Workspace file: $workspace_file"
  log ""

  # SAFETY: bail out before touching anything if this is a main/base checkout.
  guard_not_main "$TARGET_SLUG" "$frontend_worktree" "$backend_worktree"

  # --- Safety checks ---
  local clean=true

  if ! check_worktree_clean "$frontend_worktree" "Frontend"; then
    clean=false
  fi

  if ! check_worktree_clean "$backend_worktree" "Backend"; then
    clean=false
  fi

  if ! "$clean"; then
    if "$FORCE"; then
      warn ""
      warn "Workspace has uncommitted or unpushed work, but --force was given."
      warn "Proceeding anyway — local-only commits will be lost."
    else
      err ""
      err "Workspace has unpushed work. Push all changes to remote before removing."
      err "Or use --force to remove anyway (discards local-only commits and branches)."
      err "Aborting."
      exit 1
    fi
  fi

  # --- Confirmation ---
  confirm_removal "$TARGET_SLUG"

  # --- Removal ---
  log ""
  log "Removing workspace..."

  # Revert serve-workspace routing first (nginx block + reload).
  revert_serve_setup "$TARGET_SLUG"

  # Remove git worktrees
  remove_worktree "$FRONTEND_REPO" "$frontend_worktree" "Frontend"
  remove_worktree "$BACKEND_REPO" "$backend_worktree" "Backend"

  # Remove local branches
  remove_local_branch "$FRONTEND_REPO" "$TARGET_SLUG" "frontend"
  remove_local_branch "$BACKEND_REPO" "$TARGET_SLUG" "backend"

  # Remove session directory
  if [[ -d "$session_dir" ]]; then
    if [[ -z "$(ls -A "$session_dir" 2>/dev/null)" ]]; then
      log "Removing empty session directory: $session_dir"
      run_cmd rmdir "$session_dir"
    else
      log "Session directory not empty after worktree removal. Forcing removal."
      run_cmd rm -rf "$session_dir"
    fi
  else
    log "Session directory does not exist. Skipping."
  fi

  # Remove workspace file
  if [[ -f "$workspace_file" ]]; then
    log "Removing workspace file: $workspace_file"
    run_cmd rm -f "$workspace_file"
  else
    log "No workspace file found. Skipping."
  fi

  # Clean up any stale worktree bookkeeping left behind.
  run_cmd git -C "$FRONTEND_REPO" worktree prune
  run_cmd git -C "$BACKEND_REPO" worktree prune

  log ""
  log "Workspace '$TARGET_SLUG' removed successfully."
}

main "$@"
