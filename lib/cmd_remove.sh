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
  - The "Continue? [y/N]" prompt can be disabled for good with
    REQUIRE_CONFIRM_REMOVE=false in config.sh (the checks above still apply).

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

  # Quiet with the `ws trust` rule installed; otherwise a visible prompt. NOTE:
  # no spinner around sudo — it would fight the password prompt for the line.
  ensure_sudo_for_nginx || { err "sudo is required to reload nginx."; exit 1; }

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
  # Config opt-out (REQUIRE_CONFIRM_REMOVE=false). Only the prompt — the
  # protected-branch guard and the unpushed-work check still apply.
  if ! "$REQUIRE_CONFIRM_REMOVE"; then
    vlog "Confirmation prompt disabled (REQUIRE_CONFIRM_REMOVE=false)."
    return 0
  fi
  # Never behind -v: a destructive prompt must state what it destroys.
  log "About to remove workspace: $slug"
  log "This will:"
  if "$TEST_DB_ENABLED"; then
    printf '  - Drop the workspace test database (%s), if any\n' \
      "$(resolve_test_db "$slug" 2>/dev/null || printf '?')"
  fi
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

# True if anything belonging to this workspace actually exists — a session dir,
# a registered worktree, a leftover local branch, or a workspace file. Guards
# against "removing" a bogus slug (or a stray numeric arg) and printing a full
# set of ✓ steps while touching nothing. Self-healing is preserved: a leftover
# registration/branch/file still counts, so a half-deleted workspace is removable.
remove_target_exists() {
  local slug="$1" fe_wt="$2" be_wt="$3" wf="$4"
  [[ -d "$WORKSPACES_ROOT/$slug" ]] && return 0
  git -C "$FRONTEND_REPO" worktree list --porcelain 2>/dev/null | grep -Fqx "worktree $fe_wt" && return 0
  git -C "$BACKEND_REPO"  worktree list --porcelain 2>/dev/null | grep -Fqx "worktree $be_wt" && return 0
  git -C "$FRONTEND_REPO" show-ref --verify --quiet "refs/heads/$slug" && return 0
  git -C "$BACKEND_REPO"  show-ref --verify --quiet "refs/heads/$slug" && return 0
  [[ -n "$wf" && -f "$wf" ]] && return 0
  [[ -f "$(legacy_workspace_file_for "$slug")" ]] && return 0
  return 1
}

# Remove one repo's worktree. Returns 0 ONLY when a registered worktree was
# actually removed, so the caller prints "✓ removed" only when it's true. A
# missing / unregistered / failed removal returns 1 (with its own vlog/warn) —
# the session-dir rm -rf and `git worktree prune` still finish the cleanup.
remove_worktree() {
  local repo="$1" worktree_path="$2" label="$3"
  if [[ ! -d "$worktree_path" ]]; then
    vlog "$label worktree does not exist. Skipping."; return 1
  fi
  if git -C "$repo" worktree list --porcelain | grep -Fqx "worktree $worktree_path"; then
    vlog "Removing $label worktree: $worktree_path"
    # Tolerate failure: serve adds ignored files (installed node_modules, cloned
    # vendor, copied .env). The session-dir rm -rf and `git worktree prune`
    # finish the cleanup if this can't.
    if "$FORCE"; then
      run_quiet git -C "$repo" worktree remove -f "$worktree_path" \
        || { warn "git worktree remove failed for $worktree_path; will clean up directly."; return 1; }
    else
      run_quiet git -C "$repo" worktree remove "$worktree_path" \
        || { warn "git worktree remove failed for $worktree_path; retry with --force or push your work."; return 1; }
    fi
    return 0
  else
    warn "$label path exists but is not a registered git worktree: $worktree_path"
    warn "Skipping git worktree removal. Directory will still be cleaned up."
    return 1
  fi
}

# Delete one repo's local workspace branch. Returns 0 ONLY when a branch was
# actually deleted, so the caller counts real deletions and doesn't claim
# "branches deleted" when there were none (protected / absent / failed → 1).
remove_local_branch() {
  local repo="$1" branch="$2" label="$3"
  # Never delete a protected base branch, even if its worktree was already gone.
  if is_protected_branch "$branch"; then
    warn "Refusing to delete protected base branch '$branch' in $label repo."
    return 1
  fi
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    vlog "Deleting local $label branch: $branch"
    # run_quiet: `git branch -D` prints "Deleted branch …", which would shred
    # the spinner's redrawn line. Non-fatal: a branch still pinned by some
    # worktree registration must not abort the rest of the teardown.
    run_quiet git -C "$repo" branch -D "$branch" \
      || { warn "Could not delete $label branch '$branch' — remove it manually (git branch -D $branch)."; return 1; }
    return 0
  else
    vlog "No local $label branch '$branch'. Skipping."
    return 1
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

  # MAIN can never be removed — say so with a clear message rather than letting
  # it fall through to "not found" (index 0 is handled in the numeric block).
  if [[ "$slug" == "MAIN" || "$slug" == "main" ]]; then
    err "Refusing to remove MAIN — the main checkout is protected."
    exit 1
  fi

  # Accept a `ws list` index (the # column), like `ws open` does, so
  # `ws remove 3` works. Resolve against the same fixed sequence `ws list`
  # numbers; 0 is MAIN and is refused.
  if [[ "$slug" =~ ^[0-9]+$ ]]; then
    local n=$((10#$slug))     # 10# guards leading zeros ("08" -> not bad octal)
    if (( n == 0 )); then
      err "Refusing to remove MAIN (index 0) — the main checkout is protected."
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

  # Nothing to remove? Fail loudly instead of running the whole teardown over a
  # workspace that doesn't exist and printing a full set of ✓ steps that did
  # nothing (the old behaviour for a bad slug / a numeric arg).
  if ! remove_target_exists "$slug" "$frontend_worktree" "$backend_worktree" "$workspace_file"; then
    err "Workspace not found: $slug (see 'ws list')."
    exit 1
  fi

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

  # Custom pre-remove steps run HERE — after confirmation, before anything is
  # deleted, while both worktrees still exist (so a hook can copy files out of
  # them, e.g. archive planning docs). A failing hook aborts the teardown so
  # nothing is lost. The context is exported for the hook scripts.
  export WS_SLUG="$slug" WS_SESSION_DIR="$session_dir" \
         WS_FRONTEND="$frontend_worktree" WS_BACKEND="$backend_worktree" \
         WS_FRONTEND_DIR_NAME="$FRONTEND_DIR_NAME" WS_BACKEND_DIR_NAME="$BACKEND_DIR_NAME" \
         WS_DRY_RUN="$DRY_RUN"
  run_hooks pre-remove \
    || { err "Aborting: a pre-remove hook failed — nothing was deleted."; exit 1; }

  # Step out of the workspace before deleting it: `ws remove` is often run from
  # inside the worktree it's tearing down, and removing the shell's own cwd
  # leaves later git/rm steps operating on a deleted directory — which aborts the
  # teardown mid-way (under set -e) and strands a half-removed session dir. A dir
  # outside every workspace (the tool's own home, or / as a last resort) is safe.
  cd "$WSM_HOME" 2>/dev/null || cd / || true

  vlog "Removing workspace..."

  # Before routing: a launch config can exist without an nginx block, and
  # revert_serve_setup returns early in that case.
  remove_session_configs "$slug"

  revert_serve_setup "$slug"

  # Guarded to the teeth (see _test_db_name_ok) and never fatal — a skipped
  # drop is always preferable to a wrong one, and to an aborted teardown. The
  # helper prints its own warning (stopping the spinner first) on any skip.
  if "$TEST_DB_ENABLED"; then
    spin "dropping test database"
    if test_db_drop "$slug"; then
      spin_ok "test DB dropped ($(resolve_test_db "$slug"))"
    fi
  fi

  # Prune stale registrations BEFORE the worktree/branch steps, not only after:
  # a half-deleted worktree (directory present but its .git link gone) fails
  # `git worktree remove`'s validation AND pins its branch against deletion —
  # pruning upfront lets both steps self-heal. Healthy registrations are
  # untouched, so the normal path is unaffected.
  run_quiet git -C "$FRONTEND_REPO" worktree prune
  run_quiet git -C "$BACKEND_REPO" worktree prune

  # One step per worktree: removing a served worktree deletes its cloned
  # vendor/ and installed node_modules/ (tens of thousands of files), so a
  # single combined step sits silent for seconds and reads as stuck.
  # Each ✓ is printed only when that worktree was actually removed — a worktree
  # that was already gone or unregistered leaves its own vlog/warn and no ✓.
  spin "removing frontend worktree ($FRONTEND_DIR_NAME)"
  if remove_worktree "$FRONTEND_REPO" "$frontend_worktree" "Frontend"; then
    spin_ok "frontend worktree removed ($FRONTEND_DIR_NAME)"
  else
    spin_stop
  fi

  spin "removing backend worktree ($BACKEND_DIR_NAME)"
  if remove_worktree "$BACKEND_REPO" "$backend_worktree" "Backend"; then
    spin_ok "backend worktree removed ($BACKEND_DIR_NAME)"
  else
    spin_stop
  fi

  # Count real deletions so we only claim "branches deleted" when some were.
  spin "deleting branches"
  local branches_deleted=0
  if remove_local_branch "$FRONTEND_REPO" "$slug" "frontend"; then branches_deleted=$((branches_deleted + 1)); fi
  if remove_local_branch "$BACKEND_REPO" "$slug" "backend"; then branches_deleted=$((branches_deleted + 1)); fi
  if (( branches_deleted > 0 )); then
    spin_ok "branches deleted ($branches_deleted)"
  else
    spin_stop
  fi

  # Deleting the session dir is the slow part: a served workspace holds a cloned
  # vendor and an installed node_modules — tens of thousands of small files.
  spin "deleting workspace files"

  local removal_incomplete=false
  if [[ -d "$session_dir" ]]; then
    if [[ -z "$(ls -A "$session_dir" 2>/dev/null)" ]]; then
      vlog "Removing empty session directory: $session_dir"
      run_cmd rmdir "$session_dir"
    else
      vlog "Session directory not empty after worktree removal. Forcing removal."
      run_cmd rm -rf "$session_dir"
    fi
    # Verify: run_cmd doesn't check exit status, and a half-removed dir would
    # otherwise be reported as a clean removal AND keep showing in `ws list`
    # (which enumerates by directory). Retry once, then say so loudly.
    if ! "$DRY_RUN" && [[ -d "$session_dir" ]]; then
      rm -rf "$session_dir" 2>/dev/null || true
      if [[ -d "$session_dir" ]]; then
        spin_stop
        removal_incomplete=true
        warn "Session directory could not be fully removed: $session_dir"
        warn "It will still appear in 'ws list'. Remove it by hand: rm -rf \"$session_dir\""
      fi
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

  if "$removal_incomplete"; then
    warn "workspace '$slug' only partially removed — see the note above."
  else
    vlog "Workspace '$slug' removed successfully."
    spin_ok "workspace removed ($slug)"
  fi

  # Its own step, after the removal is done: refresh the REMAINING workspaces'
  # ignore-lists so they drop this workspace's repos.
  sync_scm_ignores
}
