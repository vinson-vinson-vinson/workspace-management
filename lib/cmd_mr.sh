# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_mr.sh — `workspaces mr`: for the current workspace, open or create a
# GitLab merge request per repo — but only where the branch is actually ahead
# of its target. Auto-detects the workspace from CWD.
# -----------------------------------------------------------------------------

cmd_mr_usage() {
  cat <<'USAGE'
Usage:
  ws mr [SLUG] [--fe | --be | --all] [--target <branch>] [--nd] [--dry-run]

For each repo of a workspace, open its merge request if one exists, or create a
draft — but only when the branch has commits the target doesn't. A repo with
nothing to merge is skipped, so running this on a half-done workspace does the
right thing on each side independently.

Arguments:
  SLUG          Workspace to act on. Defaults to the one CWD is inside.

Options:
      --fe      Frontend repo only.
      --be      Backend repo only.
      --all     Both repos (the default).
      --target <branch>
                Target branch for the MR. Defaults per repo to the base branch
                it was cut from (FRONTEND_BASE_BRANCH / BACKEND_BASE_BRANCH,
                both "main" out of the box).
      --nd      No-draft: create the MR ready for review, not as a draft.
      --dry-run Print what would happen without pushing or touching GitLab.
  -h, --help    Show this help.

The MR title is derived from the branch name:
  CU-1234_fix-login  ->  "CU-1234: Fix login"
  experiment         ->  "Experiment"

Set MR_ASSIGNEE in config.sh to a GitLab username to auto-assign new MRs.
USAGE
}

# Title from a branch: CU-1234_fix-login -> "CU-1234: Fix login".
# Pure parameter expansion + tr — no ${var^^} (bash 4) and no sed \u/\b (GNU),
# neither of which exists on the macOS bash 3.2 / BSD sed this runs under.
_mr_title() {
  local branch="$1" id="" rest="$1" head
  head="${branch%%_*}"
  # Task id = <prefix>-<id>. The id is alphanumeric — ClickUp's are hashes like
  # 86cath6g5, not just digits — so match [A-Za-z0-9]+, not [0-9]+. Uppercase
  # only the prefix (cu -> CU); the id keeps its own case, since a ClickUp hash
  # read shouted (86CATH6G5) is wrong.
  if [[ "$branch" == *_* ]] && printf '%s' "$head" | grep -qE '^[A-Za-z]+-[A-Za-z0-9]+$'; then
    local pfx="${head%%-*}" idpart="${head#*-}"
    id="$(printf '%s' "$pfx" | tr '[:lower:]' '[:upper:]')-${idpart}"
    rest="${branch#*_}"
  fi
  local words out="" w first
  words="$(printf '%s' "$rest" | tr '_-' '  ')"
  for w in $words; do
    first="$(printf '%s' "${w:0:1}" | tr '[:lower:]' '[:upper:]')"
    out="${out:+$out }${first}${w:1}"
  done
  [[ -n "$id" ]] && printf '%s: %s' "$id" "$out" || printf '%s' "$out"
}

# Open or create the MR for one repo's worktree. Never exits — one repo failing
# must not stop the other.
#   $1 worktree path, $2 label, $3 target override (may be empty), $4 base branch
_mr_for_repo() {
  local worktree="$1" label="$2" target_override="$3" base_branch="$4"
  local branch target base_ref ahead

  [[ -d "$worktree" ]] || { vlog "$label: no worktree at $worktree — skipping."; return 0; }
  branch="$(worktree_branch "$worktree")"
  [[ -n "$branch" ]] || { warn "$label: no branch in the worktree — skipping."; return 0; }
  target="${target_override:-$base_branch}"

  # Count commits the branch has that the target doesn't. Prefer origin/<target>
  # — the MR is judged against the remote, so that's the honest baseline.
  base_ref="$target"
  git -C "$worktree" rev-parse --verify --quiet "refs/remotes/origin/$target" >/dev/null 2>&1 \
    && base_ref="origin/$target"
  ahead="$(git -C "$worktree" rev-list --count "${base_ref}..${branch}" 2>/dev/null || printf '0')"

  if [[ "$ahead" -eq 0 ]]; then
    ok "$label: nothing to merge into $target"
    return 0
  fi

  # Committed work is what an MR carries; a dirty tree just means some of it
  # isn't in the diff yet. Worth saying, not worth blocking on.
  [[ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]] \
    && warn "$label: uncommitted changes are not part of the MR."

  local title; title="$(_mr_title "$branch")"

  if "$DRY_RUN"; then
    local kind="draft MR"; "$NO_DRAFT" && kind="MR"
    printf '[dry-run] %s: %s commit(s) ahead of %s\n' "$label" "$ahead" "$target"
    printf '[dry-run]   push %s, then %s "%s" -> %s\n' "$branch" "$kind" "$title" "$target"
    [[ -n "$MR_ASSIGNEE" ]] && printf '[dry-run]   assignee: %s\n' "$MR_ASSIGNEE"
    return 0
  fi

  # An MR needs the branch on the remote. Push when origin has no copy or is
  # behind — from the worktree, so glab reads the right remote afterwards.
  local need_push=false
  if ! git -C "$worktree" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    need_push=true
  elif [[ "$(git -C "$worktree" rev-list --count "origin/$branch..$branch" 2>/dev/null || printf '1')" -gt 0 ]]; then
    need_push=true
  fi
  if "$need_push"; then
    log "$label: pushing $branch…"
    ( cd "$worktree" && git push -u origin "$branch" ) >/dev/null 2>&1 \
      || { err "$label: push failed — resolve it and re-run."; return 1; }
  fi

  # Already an MR for this branch? Open it instead of making a second.
  local existing url
  existing="$( cd "$worktree" && glab mr list --source-branch "$branch" --output json 2>/dev/null )" || true
  if [[ -n "$existing" && "$existing" != "[]" ]]; then
    url="$(printf '%s' "$existing" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["web_url"])' 2>/dev/null)" || true
    ok "$label: MR already open${url:+ — $url}"
    [[ -n "$url" ]] && open "$url"
    return 0
  fi

  # Draft by default; --nd (NO_DRAFT) opens it ready for review instead.
  local kind="draft MR"; "$NO_DRAFT" && kind="MR"
  log "$label: creating $kind -> $target"
  # Build the optional flags as an array so an unset one adds nothing rather
  # than a stray empty argument: --draft (unless --nd) and --assignee.
  local -a extra=()
  "$NO_DRAFT" || extra+=(--draft)
  [[ -n "$MR_ASSIGNEE" ]] && extra+=(--assignee "$MR_ASSIGNEE")
  local out
  out="$( cd "$worktree" && glab mr create --yes --fill \
      --source-branch "$branch" --target-branch "$target" --title "$title" \
      ${extra[@]+"${extra[@]}"} 2>&1 )" || {
    err "$label: glab mr create failed:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  }
  url="$(printf '%s\n' "$out" | grep -oE 'https://[^ ]+/merge_requests/[0-9]+' | head -1)"
  ok "$label: $kind created -> $target"
  [[ -n "$url" ]] && { printf '    %s\n' "$url"; open "$url"; }
}

cmd_mr() {
  DRY_RUN=false
  NO_DRAFT=false
  local fe=false be=false target="" slug=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fe)       fe=true; shift ;;
      --be)       be=true; shift ;;
      --all)      fe=true; be=true; shift ;;
      --target)   target="${2:-}"; [[ -n "$target" ]] || { err "--target needs a branch"; exit 1; }; shift 2 ;;
      --nd)       NO_DRAFT=true; shift ;;
      --dry-run)  DRY_RUN=true; shift ;;
      -h|--help)  cmd_mr_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_mr_usage; exit 1 ;;
      *)  [[ -z "$slug" ]] || { err "Unexpected extra argument: $1"; exit 1; }
          slug="$1"; shift ;;
    esac
  done

  require_command git
  require_command glab

  # Fail fast, before any push. glab authenticates via GITLAB_TOKEN or a
  # `glab auth login` credential; without either, the only error otherwise
  # surfaces at the create step — after the branch is already pushed.
  glab auth status >/dev/null 2>&1 || {
    err "glab is not authenticated. Run 'glab auth login', or set GITLAB_TOKEN."
    exit 1
  }

  # Neither side named → both.
  "$fe" || "$be" || { fe=true; be=true; }

  [[ -n "$slug" ]] || slug="$(slug_from_cwd)" || {
    err "Not inside a workspace and no SLUG given."
    err "Run from a workspace, or: ws mr <slug>"
    exit 1
  }

  local session_dir="$WORKSPACES_ROOT/$slug"
  [[ -d "$session_dir" ]] || { err "Workspace not found: $slug"; exit 1; }

  "$fe" && _mr_for_repo "$session_dir/$FRONTEND_DIR_NAME" "Frontend" "$target" "$FRONTEND_BASE_BRANCH"
  "$be" && _mr_for_repo "$session_dir/$BACKEND_DIR_NAME"  "Backend"  "$target" "$BACKEND_BASE_BRANCH"
}
