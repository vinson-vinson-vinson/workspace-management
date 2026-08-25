# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_open.sh — `workspaces open`: open a workspace in the configured
# IDE(s) by its `ws list` index (or slug). Just the editor — no serving.
#
# One exception to "no side effects": a slug with no workspace behind it is
# created first (--no-create opts out). That is what makes an `ws://open/<slug>`
# deep link portable — the person clicking it doesn't have your session dir, and
# a link that errors out on every machine but yours is not a link.
# -----------------------------------------------------------------------------

cmd_open_usage() {
  cat <<'USAGE'
Usage:
  ws open <N | SLUG> [--branch <name>] [--remote <name>] [--base <branch>]
          [--no-create] [--dry-run]
  ws open --branch <name> [...]        (workspace named after the branch)

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

A SLUG with no workspace behind it is created first (`ws create <slug>`), then
opened. An index never creates anything: it can only name a workspace that
already exists.

Options:
  --branch <name>  Branch to put the worktrees on when the workspace has to be
                   created, for a branch whose name can't be the workspace's
                   directory name (an agent's "cursor/my-feature-05ff"). With
                   no N|SLUG given, the workspace is the branch's last segment
                   ("my-feature-05ff"), so a branch is enough to open one.
  --remote <name>  Fetch the branch through this remote in both repos when the
                   workspace has to be created (overrides FRONTEND_REMOTE /
                   BACKEND_REMOTE for that run).
  --base <branch>  Base branch to cut from if the branch is nowhere yet — same
                   meaning as `ws create <slug> <base>`.
  --no-create      Fail on an unknown slug instead of creating it.
  --dry-run        Print actions without executing them.
  -v, --verbose    Narrate each step.
  -h, --help       Show this help.

Examples:
  ws open 0
  ws open 2
  ws open CU-1234_my-feature
  ws open CU-1234_my-feature --remote upstream
  ws open CU-1234_my-feature --branch cursor/my-feature-05ff
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

# Hand an unknown slug to `ws create` — a separate process, so the create flow
# (fetch, worktrees, .code-workspace, terminals) runs exactly as it does on its
# own, with no half-shared state between the two commands.
open_by_creating() {
  local slug="$1" base="$2" branch="$3"
  local -a args=("$slug")
  [[ -n "$base" ]] && args+=("$base")
  [[ -n "$branch" ]] && args+=(--branch "$branch")
  [[ -n "$REMOTE_OVERRIDE" ]] && args+=(--remote "$REMOTE_OVERRIDE")
  "$DRY_RUN" && args+=(--dry-run)
  "$VERBOSE" && args+=(-v)
  log "No workspace '$slug' yet — creating it${branch:+ on branch $branch}${REMOTE_OVERRIDE:+ from remote $REMOTE_OVERRIDE}."
  "$WSM_HOME/workspaces" create "${args[@]}" \
    || { err "Could not create '$slug' — not opening anything."; exit 1; }
}

cmd_open() {
  local target="" base="" branch="" create_missing=true
  DRY_RUN=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote)
        [[ $# -ge 2 && -n "$2" ]] || { err "--remote needs a remote name."; exit 1; }
        REMOTE_OVERRIDE="$2"; shift 2 ;;
      --base)
        [[ $# -ge 2 && -n "$2" ]] || { err "--base needs a branch name."; exit 1; }
        base="$2"; shift 2 ;;
      --branch)
        [[ $# -ge 2 && -n "$2" ]] || { err "--branch needs a branch name."; exit 1; }
        branch="$2"; shift 2 ;;
      --no-create) create_missing=false; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help) cmd_open_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_open_usage; exit 1 ;;
      *)
        if [[ -n "$target" ]]; then
          err "Expected exactly one argument."; cmd_open_usage; exit 1
        fi
        target="$1"; shift ;;
    esac
  done
  # A branch alone is enough: the workspace is its last segment (see
  # slug_from_branch), so an agent branch needs no second name.
  if [[ -z "$target" && -n "$branch" ]]; then
    target="$(slug_from_branch "$branch")"
    vlog "No slug given — branch '$branch' names workspace '$target'."
  fi
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
      # `ws create` normalises what it is handed (canonical task id, slugified
      # feature name), so the directory is often not spelled like the argument —
      # CU-1234_My-Feature lives at CU-1234_my-feature. Resolve before deciding
      # anything is missing, or a link would create a duplicate of a workspace
      # that is already there.
      local canonical; canonical="$(workspace_slug_for "$slug")"
      if [[ -d "$WORKSPACES_ROOT/$canonical" ]]; then
        vlog "'$slug' resolves to workspace '$canonical'."
        slug="$canonical"
      else
        "$create_missing" || { err "No workspace named '$slug' (see 'ws list')."; exit 1; }
        open_by_creating "$slug" "$base" "$branch"
        slug="$canonical"
        # create opened the IDE itself unless the config told it not to; only
        # then does the normal open path below still have work to do.
        "$NO_OPEN_AFTER_CREATE" || return 0
        "$DRY_RUN" && return 0      # nothing was created, so nothing to open
      fi
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
