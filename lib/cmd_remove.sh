# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_remove.sh — `workspaces remove`: tear a workspace down safely. Reverts
# serve routing, removes worktrees, deletes local branches, cleans the session
# dir. Refuses on unpushed work (unless --force) and never touches a main/base
# checkout.
# -----------------------------------------------------------------------------

cmd_remove_usage() {
  cat <<'USAGE'
Usage:
  ws remove [SLUG] [--dry-run] [--force] [-v]

Arguments:
  SLUG        Workspace slug. If omitted, auto-detects from the current directory.

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
  ws remove                                     # auto-detect from cwd
  ws remove CU-86c9vwd5w_generic-remote-open
  ws remove CU-86c9vwd5w_generic-remote-open --force
USAGE
}

# Reverse whatever serve set up: remove the nginx block and reload. The copied
# envs / installed node_modules / cloned vendor live inside the session dir and
# are removed with it, so nothing else needs undoing here.
revert_serve_setup() {
  local slug="$1" sub host conf
  if ! sub="$(resolve_subdomain "$slug")"; then
    vlog "Slug has no subdomain mapping; no routing to revert."
    return 0
  fi
  host="${sub}.${BASE_DOMAIN}"
  conf="$VALET_NGINX_DIR/$host"

  if [[ ! -f "$conf" ]]; then
    vlog "No nginx block for $host. Nothing to revert."
    return 0
  fi

  vlog "Reverting routing for https://$host"
  if "$DRY_RUN"; then
    printf '[dry-run] rm -f %s\n' "$conf"
    printf '[dry-run] sudo nginx -t && sudo nginx -s reload\n'
    return 0
  fi

  # Visible, like serve's: sudo is about to prompt and should say why. NOTE: no
  # spinner around sudo — it would fight the password prompt for the line.
  log "Requesting sudo (needed to reload nginx)…"
  sudo -v || { err "sudo is required to reload nginx."; exit 1; }

  spin "reverting routing"
  rm -f "$conf"
  if run_nginx -t && run_nginx -s reload; then
    vlog "Removed nginx block and reloaded nginx."
    spin_ok "routing reverted ($host)"
  else
    spin_stop
    warn "nginx reload failed after removing $conf — check the config manually."
  fi
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

has_uncommitted_changes() {
  local worktree_path="$1"
  [[ -d "$worktree_path" ]] || return 1
  local status_output
  status_output="$(git -C "$worktree_path" status --porcelain 2>/dev/null)"
  [[ -n "$status_output" ]]
}

# Commits reachable from HEAD but from no remote-tracking ref (origin/*). 0 for a
# fresh branch cut from main, a pushed branch, or one not ahead of its upstream;
# >0 only for genuine local-only work.
has_unpushed_commits() {
  local worktree_path="$1"
  [[ -d "$worktree_path" ]] || return 1
  git -C "$worktree_path" rev-parse --verify HEAD &>/dev/null || return 1
  local count
  count="$(git -C "$worktree_path" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
  [[ "${count:-0}" -gt 0 ]]
}

# Echo a one-line "<label>: <issues>" summary if the worktree has local-only
# work, else echo nothing. Returns 1 when dirty. Deliberately does NOT print its
# own errors — the caller collects every worktree's verdict into ONE error block,
# rather than eight consecutive ERROR: lines for a single problem.
check_worktree_clean() {
  local worktree_path="$1" label="$2" issues=()
  if [[ ! -d "$worktree_path" ]]; then
    vlog "$label worktree not found at $worktree_path — skipping checks."
    return 0
  fi
  has_uncommitted_changes "$worktree_path" && issues+=("uncommitted changes")
  has_unpushed_commits "$worktree_path"    && issues+=("unpushed commits")
  if [[ ${#issues[@]} -gt 0 ]]; then
    local joined; joined="$(printf '%s, ' "${issues[@]}")"
    printf '%s: %s' "$label" "${joined%, }"
    return 1
  fi
  vlog "$label worktree is clean."
  return 0
}

confirm_removal() {
  local slug="$1"
  if "$FORCE" || "$DRY_RUN"; then return 0; fi
  # Never behind -v: a destructive prompt must state what it destroys.
  log "About to remove workspace: $slug"
  log "This will:"
  printf '  - Revert serve routing (remove nginx block + reload), if any\n'
  printf '  - Remove git worktrees (frontend + backend)\n'
  printf '  - Delete local branches\n'
  printf '  - Remove session directory\n'
  printf '  - Remove .code-workspace file\n'
  printf 'Continue? [y/N] '
  local answer; read -r answer
  case "$answer" in
    [Yy]|[Yy]es) return 0 ;;
    *) log "Aborted."; exit 0 ;;
  esac
}

remove_worktree() {
  local repo="$1" worktree_path="$2" label="$3"
  if [[ ! -d "$worktree_path" ]]; then
    vlog "$label worktree does not exist. Skipping."; return 0
  fi
  if git -C "$repo" worktree list --porcelain | grep -Fqx "worktree $worktree_path"; then
    vlog "Removing $label worktree: $worktree_path"
    # Tolerate failure: serve adds ignored files (installed node_modules, cloned
    # vendor, copied .env). The session-dir rm -rf and `git worktree prune`
    # finish the cleanup if this can't.
    if "$FORCE"; then
      run_quiet git -C "$repo" worktree remove -f "$worktree_path" \
        || warn "git worktree remove failed for $worktree_path; will clean up directly."
    else
      run_quiet git -C "$repo" worktree remove "$worktree_path" \
        || warn "git worktree remove failed for $worktree_path; retry with --force or push your work."
    fi
  else
    warn "$label path exists but is not a registered git worktree: $worktree_path"
    warn "Skipping git worktree removal. Directory will still be cleaned up."
  fi
}

remove_local_branch() {
  local repo="$1" branch="$2" label="$3"
  # Never delete a protected base branch, even if its worktree was already gone.
  if is_protected_branch "$branch"; then
    warn "Refusing to delete protected base branch '$branch' in $label repo."
    return 0
  fi
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    vlog "Deleting local $label branch: $branch"
    # run_quiet: `git branch -D` prints "Deleted branch …", which would shred
    # the spinner's redrawn line.
    run_quiet git -C "$repo" branch -D "$branch"
  else
    vlog "No local $label branch '$branch'. Skipping."
  fi
}

cmd_remove() {
  DRY_RUN=false
  FORCE=false
  VERBOSE=false
  local slug="" positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)    DRY_RUN=true; shift ;;
      --force)      FORCE=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_remove_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_remove_usage; exit 1 ;;
      *)  positional+=("$1"); shift ;;
    esac
  done

  if [[ ${#positional[@]} -gt 1 ]]; then
    err "Expected at most one positional argument (slug)."; cmd_remove_usage; exit 1
  fi
  [[ ${#positional[@]} -eq 1 ]] && slug="${positional[0]}"

  if [[ -z "$slug" ]]; then
    slug="$(slug_from_cwd)" || {
      err "Not inside a worktree directory and no slug provided."
      err "Expected a path under: $WORKSPACES_ROOT/"
      exit 1
    }
    vlog "Auto-detected slug from CWD: $slug"
  fi

  local session_dir="$WORKSPACES_ROOT/$slug"
  local frontend_worktree="$session_dir/$FRONTEND_DIR_NAME"
  local backend_worktree="$session_dir/$BACKEND_DIR_NAME"
  local workspace_file; workspace_file="$(workspace_file_for "$slug")"

  vlog "Slug: $slug"
  vlog "Session dir: $session_dir"
  vlog "Frontend worktree: $frontend_worktree"
  vlog "Backend worktree: $backend_worktree"
  vlog "Workspace file: $workspace_file"
  vlog ""

  # SAFETY: bail out before touching anything if this is a main/base checkout.
  guard_not_main "$slug" "$frontend_worktree" "$backend_worktree"

  # --- Safety checks ---
  # Collect every worktree's verdict first, then report once. One problem should
  # produce one error, not one per worktree per issue.
  local -a dirty=()
  local verdict
  verdict="$(check_worktree_clean "$frontend_worktree" "$FRONTEND_DIR_NAME")" || dirty+=("$verdict")
  verdict="$(check_worktree_clean "$backend_worktree" "$BACKEND_DIR_NAME")"  || dirty+=("$verdict")

  if [[ ${#dirty[@]} -gt 0 ]]; then
    # One prefixed headline, then bare continuation lines — repeating
    # "[remove] ERROR:" down the block just makes one problem look like four.
    if "$FORCE"; then
      warn "Workspace has local-only work, but --force was given — it will be lost:"
      for verdict in "${dirty[@]}"; do printf '           - %s\n' "$verdict" >&2; done
    else
      err "Workspace has local-only work:"
      for verdict in "${dirty[@]}"; do printf '           - %s\n' "$verdict" >&2; done
      printf '         Push it, or use --force to discard it.\n' >&2
      exit 1
    fi
  fi

  confirm_removal "$slug"

  vlog "Removing workspace..."

  revert_serve_setup "$slug"

  spin "removing worktrees"
  remove_worktree "$FRONTEND_REPO" "$frontend_worktree" "Frontend"
  remove_worktree "$BACKEND_REPO" "$backend_worktree" "Backend"
  spin_ok "worktrees removed"

  spin "deleting branches"
  remove_local_branch "$FRONTEND_REPO" "$slug" "frontend"
  remove_local_branch "$BACKEND_REPO" "$slug" "backend"
  spin_ok "branches deleted"

  # Deleting the session dir is the slow part: a served workspace holds a cloned
  # vendor and an installed node_modules — tens of thousands of small files.
  spin "deleting workspace files"

  if [[ -d "$session_dir" ]]; then
    if [[ -z "$(ls -A "$session_dir" 2>/dev/null)" ]]; then
      vlog "Removing empty session directory: $session_dir"
      run_cmd rmdir "$session_dir"
    else
      vlog "Session directory not empty after worktree removal. Forcing removal."
      run_cmd rm -rf "$session_dir"
    fi
  else
    vlog "Session directory does not exist. Skipping."
  fi

  # The workspace file now lives inside the session dir (removed above with it);
  # also clean the legacy project-root location for pre-move workspaces.
  local wf removed_wf=false
  for wf in "$workspace_file" "$(legacy_workspace_file_for "$slug")"; do
    if [[ -f "$wf" ]]; then
      vlog "Removing workspace file: $wf"
      run_cmd rm -f "$wf"
      removed_wf=true
    fi
  done
  "$removed_wf" || vlog "No workspace file found. Skipping."

  run_quiet git -C "$FRONTEND_REPO" worktree prune
  run_quiet git -C "$BACKEND_REPO" worktree prune

  vlog "Workspace '$slug' removed successfully."
  spin_ok "workspace removed ($slug)"

  # Its own step, after the removal is done: refresh the REMAINING workspaces'
  # ignore-lists so they drop this workspace's repos.
  sync_scm_ignores
}
