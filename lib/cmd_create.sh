# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_create.sh — `workspaces create`: cut matching frontend+backend
# worktrees into a session dir, write a .code-workspace, and open VS Code.
# (Teardown lives in `workspaces remove`.)
# -----------------------------------------------------------------------------

cmd_create_usage() {
  cat <<'USAGE'
Usage:
  ws create <NAME_OR_TASK_AND_NAME> [--dry-run]

Rules:
  - With task:    CU-<taskId>_<feature-name>  -> slug/branch CU-<taskId>_<feature-name>
  - Without task: <feature-name>              -> slug/branch <feature-name>
  - The VS Code workspace opens automatically.

Options:
  --dry-run            Print actions without executing them.
  -h, --help           Show this help.

Examples:
  ws create CU-1234_Test-Project
  ws create MyNewProject
  ws create CU-1234_Test-Project --dry-run
USAGE
}

normalize_task_id() {
  local raw="$1" body
  body="$(printf '%s' "$raw" | tr -d '[:space:]')"
  # Strip the prefix in either case (e.g. CU- / cu-) before re-adding it.
  body="${body#"${TASK_ID_PREFIX}"-}"
  body="${body#"${TASK_ID_PREFIX_LC}"-}"
  body="$(printf '%s' "$body" | tr -cd '[:alnum:]-')"
  if [[ -z "$body" ]]; then
    err "Invalid task id: '$raw'"; exit 1
  fi
  printf '%s-%s' "$TASK_ID_PREFIX" "$body"
}

slugify_name() {
  local raw="$1" out
  out="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  out="$(printf '%s' "$out" | sed -E 's/[[:space:]_]+/-/g')"
  out="$(printf '%s' "$out" | sed -E 's/[^a-z0-9-]//g')"
  out="$(printf '%s' "$out" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$out" ]]; then
    err "Feature name produces empty slug: '$raw'"; exit 1
  fi
  printf '%s' "$out"
}

resolve_base_ref() {
  local repo="$1" branch="$2"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s' "$branch"; return
  fi
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    printf 'origin/%s' "$branch"; return
  fi
  err "Base branch '$branch' not found in $repo (local or origin/$branch)"; exit 1
}

worktree_registered() {
  git -C "$1" worktree list --porcelain | grep -Fqx "worktree $2"
}

branch_exists_local() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2"
}

# Read-only check whether a branch exists on origin. Uses the already-fetched
# remote-tracking ref first, then a network query that mutates nothing locally.
remote_branch_exists() {
  local repo="$1" branch="$2"
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    return 0
  fi
  git -C "$repo" ls-remote --heads --exit-code origin "$branch" >/dev/null 2>&1
}

# Records how the branch was obtained, so the milestone check can say what
# actually happened rather than always claiming "created".
BRANCH_ORIGIN=""

add_worktree() {
  local repo="$1" branch="$2" worktree_path="$3" base_ref="$4"
  if branch_exists_local "$repo" "$branch"; then
    vlog "Reusing existing local branch '$branch' in $repo"
    BRANCH_ORIGIN="reused existing local branch"
    run_quiet git -C "$repo" worktree add "$worktree_path" "$branch"
    return
  fi
  if remote_branch_exists "$repo" "$branch"; then
    vlog "Checking out existing remote branch 'origin/$branch' in $repo"
    BRANCH_ORIGIN="checked out from origin"
    run_quiet git -C "$repo" fetch origin "$branch"
    run_quiet git -C "$repo" worktree add --track -b "$branch" "$worktree_path" "origin/$branch"
    return
  fi
  vlog "Creating new branch '$branch' from '$base_ref' in $repo"
  BRANCH_ORIGIN="created from $base_ref"
  run_quiet git -C "$repo" worktree add -b "$branch" "$worktree_path" "$base_ref"
}

open_workspace() {
  local workspace_file="$1"
  run_cmd code -n "$workspace_file"
}

# Pick a legible title-bar foreground ("dark"/"light") for a "#rrggbb" bg using
# the W3C relative-luminance threshold.
contrast_foreground() {
  local hex="${1#\#}" r g b lum
  r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
  lum=$(((r * 299 + g * 587 + b * 114) / 1000))
  if ((lum > 150)); then printf 'dark'; else printf 'light'; fi
}

write_workspace_file() {
  # frontend_dir/backend_dir are relative to the workspace file, which now lives
  # inside the session dir next to the two worktrees — so the paths are just the
  # worktree directory names and the whole session dir is self-contained.
  local workspace_file="$1" frontend_dir="$2" backend_dir="$3" accent_color="$4"
  if "$DRY_RUN"; then
    printf '[dry-run] write workspace file %s\n' "$workspace_file"; return
  fi
  local active_fg inactive_fg
  if [[ "$(contrast_foreground "$accent_color")" == "dark" ]]; then
    active_fg="#000000"; inactive_fg="#000000cc"
  else
    active_fg="#ffffff"; inactive_fg="#ffffffcc"
  fi
  cat >"$workspace_file" <<EOF
{
  "folders": [
    { "path": "$frontend_dir" },
    { "path": "$backend_dir" }
  ],
  "settings": {
    "git.autoRepositoryDetection": false,
    "git.openRepositoryInParentFolders": "never",
    "window.titleBarStyle": "custom",
    "workbench.colorCustomizations": {
      "titleBar.activeBackground": "$accent_color",
      "titleBar.inactiveBackground": "$accent_color",
      "titleBar.activeForeground": "$active_fg",
      "titleBar.inactiveForeground": "$inactive_fg",
      "commandCenter.foreground": "$active_fg",
      "commandCenter.activeForeground": "$active_fg",
      "commandCenter.inactiveForeground": "$inactive_fg",
      "commandCenter.border": "$inactive_fg",
      "commandCenter.inactiveBorder": "$inactive_fg"
    }
  }
}
EOF
}

random_workspace_color() {
  local -a colors=(
    '#e6194b' '#3cb44b' '#ffe119' '#4363d8'
    '#f58231' '#911eb4' '#42d4f4' '#f032e6'
    '#bfef45' '#fabed4' '#469990' '#dcbeff'
    '#9a6324' '#fffac8' '#800000' '#aaffc3'
    '#808000' '#ffd8b1' '#000075' '#a9a9a9'
    '#ff4500' '#1e90ff' '#32cd32' '#ff1493'
    '#8b4513' '#00ced1' '#9400d3' '#ff8c00'
    '#2e8b57' '#7b68ee' '#dc143c' '#00fa9a'
    '#4682b4' '#d2691e' '#6b8e23' '#c71585'
    '#008080' '#b22222' '#daa520' '#5f9ea0'
    '#8a2be2' '#228b22' '#cd5c5c' '#4b0082'
    '#ff6347' '#20b2aa' '#9932cc' '#556b2f'
    '#e9967a' '#191970'
  )
  printf '%s' "${colors[RANDOM % ${#colors[@]}]}"
}

cmd_create() {
  local positional=() combined=""
  DRY_RUN=false
  local TASK_INPUT="" FEATURE_NAME=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   DRY_RUN=true; shift ;;
      -h|--help)   cmd_create_usage; exit 0 ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
      -*) err "Unknown option: $1"; cmd_create_usage; exit 1 ;;
      *)  positional+=("$1"); shift ;;
    esac
  done

  if [[ ${#positional[@]} -ne 1 ]]; then
    cmd_create_usage; exit 1
  fi
  combined="${positional[0]}"

  # One-argument task form: <PREFIX>-1234_MyProject (prefix case-insensitive).
  local combined_lc
  combined_lc="$(printf '%s' "$combined" | tr '[:upper:]' '[:lower:]')"
  if [[ "$combined_lc" == "${TASK_ID_PREFIX_LC}"-*_* ]]; then
    TASK_INPUT="${combined%%_*}"
    FEATURE_NAME="${combined#*_}"
    [[ -n "$FEATURE_NAME" ]] || { err "Missing feature name after '_' in '$combined'"; exit 1; }
  else
    FEATURE_NAME="$combined"
  fi

  require_command git
  require_command sed
  require_command code
  require_repo "$FRONTEND_REPO"
  require_repo "$BACKEND_REPO"

  local name_slug branch_slug session_dir frontend_worktree backend_worktree
  local workspace_file workspace_color="" frontend_ref backend_ref

  name_slug="$(slugify_name "$FEATURE_NAME")"
  if [[ -n "$TASK_INPUT" ]]; then
    branch_slug="$(normalize_task_id "$TASK_INPUT")_${name_slug}"
  else
    branch_slug="$name_slug"
  fi

  session_dir="$WORKSPACES_ROOT/$branch_slug"
  frontend_worktree="$session_dir/$FRONTEND_DIR_NAME"
  backend_worktree="$session_dir/$BACKEND_DIR_NAME"
  workspace_file="$(workspace_file_for "$branch_slug")"

  frontend_ref="$(resolve_base_ref "$FRONTEND_REPO" "$FRONTEND_BASE_BRANCH")"
  backend_ref="$(resolve_base_ref "$BACKEND_REPO" "$BACKEND_BASE_BRANCH")"

  vlog "Session slug: $branch_slug"
  vlog "Frontend worktree: $frontend_worktree"
  vlog "Backend worktree: $backend_worktree"
  vlog "Workspace file: $workspace_file"

  local frontend_exists=false backend_exists=false
  [[ -d "$frontend_worktree" ]] && frontend_exists=true
  [[ -d "$backend_worktree" ]] && backend_exists=true

  if "$frontend_exists" && "$backend_exists"; then
    if worktree_registered "$FRONTEND_REPO" "$frontend_worktree" && worktree_registered "$BACKEND_REPO" "$backend_worktree"; then
      vlog "Session already exists completely. Opening workspace only."
      ok "workspace already exists ($branch_slug)"
      if [[ ! -f "$workspace_file" ]]; then
        workspace_color="$(random_workspace_color)"
        vlog "Workspace color: $workspace_color"
        write_workspace_file "$workspace_file" "$FRONTEND_DIR_NAME" "$BACKEND_DIR_NAME" "$workspace_color"
        ok "workspace file written"
      fi
      sync_scm_ignores
      open_workspace "$workspace_file"
      ok "VS Code opened"
      exit 0
    fi
    err "Both worktree paths exist, but at least one is not registered as git worktree. Refusing."
    exit 1
  fi

  if "$frontend_exists" || "$backend_exists"; then
    err "Partial existing session detected. Refusing to continue."
    exit 1
  fi

  local created_frontend=false created_backend=false
  cleanup_on_error() {
    local status=$?
    if [[ $status -ne 0 ]] && ! "$DRY_RUN"; then
      err "Creation failed. Rolling back newly created worktrees."
      "$created_backend"  && git -C "$BACKEND_REPO" worktree remove -f "$backend_worktree" || true
      "$created_frontend" && git -C "$FRONTEND_REPO" worktree remove -f "$frontend_worktree" || true
    fi
    exit "$status"
  }
  trap cleanup_on_error EXIT

  run_cmd mkdir -p "$session_dir"

  # Can be slow: may fetch from origin before adding each worktree.
  spin "creating worktrees"
  add_worktree "$FRONTEND_REPO" "$branch_slug" "$frontend_worktree" "$frontend_ref"
  created_frontend=true
  add_worktree "$BACKEND_REPO" "$branch_slug" "$backend_worktree" "$backend_ref"
  created_backend=true
  spin_stop
  # Both repos take the same slug, so BRANCH_ORIGIN from the last add_worktree
  # describes both.
  ok "branches ${BRANCH_ORIGIN} ($branch_slug)"
  ok "worktrees added ($FRONTEND_DIR_NAME, $BACKEND_DIR_NAME)"

  workspace_color="$(random_workspace_color)"
  vlog "Workspace color: $workspace_color"
  write_workspace_file "$workspace_file" "$FRONTEND_DIR_NAME" "$BACKEND_DIR_NAME" "$workspace_color"
  ok "workspace file written"

  vlog "Worktrees created successfully. Opening workspace."
  sync_scm_ignores
  # Checked last, once it has actually happened — not announced in advance.
  open_workspace "$workspace_file"
  ok "VS Code opened"

  trap - EXIT
}
