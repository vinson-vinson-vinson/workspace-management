#!/usr/bin/env bash

set -euo pipefail

# Load configuration (see config.example.sh). WSM_CONFIG can point elsewhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${WSM_CONFIG:-$SCRIPT_DIR/config.sh}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  printf 'ERROR: config file not found: %s\n' "$CONFIG_FILE" >&2
  printf 'Copy config.example.sh to config.sh and edit it (or set WSM_CONFIG).\n' >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Lowercased task-id prefix, used for case-insensitive slug matching.
TASK_ID_PREFIX_LC="$(printf '%s' "$TASK_ID_PREFIX" | tr '[:upper:]' '[:lower:]')"

DRY_RUN=false
REMOVE_MODE=false
TASK_INPUT=""
FEATURE_NAME=""
OPEN_CLAUDE="${OPEN_CLAUDE_DEFAULT:-true}"
CLAUDE_PROMPT=""

print_usage() {
  cat <<'USAGE'
Usage:
  create-workspace.sh <NAME_OR_TASK_AND_NAME> [--dry-run] [--remove]

Rules:
  - One argument only.
  - With task: CU-<taskId>_<feature-name> -> branch/slug => CU-<taskId>_<feature-name>
  - Without task: <feature-name> -> branch/slug => <feature-name>
  - With --remove: remove session worktrees, local branches, and workspace file.
  - By default the VS Code workspace opens AND a Claude Code session is started
    in the Claude desktop app rooted at the new session dir. Use --no-claude to
    skip opening the Claude desktop app.

Options:
  --dry-run            Print actions without executing them.
  --remove             Remove the session instead of creating it.
  --no-claude          Do not open the Claude desktop app for the session.
  --prompt <text>      Prefill the Claude Code session with this prompt.

Examples:
  create-workspace.sh CU-1234_Test-Project
  create-workspace.sh MeinNeuesProjekt
  create-workspace.sh CU-1234_Test-Project --dry-run
  create-workspace.sh CU-1234_Test-Project --remove
  create-workspace.sh CU-1234_Test-Project --no-claude
  create-workspace.sh CU-1234_Test-Project --prompt "Implement the task"
USAGE
}

log() {
  printf '[session] %s\n' "$*"
}

err() {
  printf '[session] ERROR: %s\n' "$*" >&2
}

run_cmd() {
  if "$DRY_RUN"; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

normalize_task_id() {
  local raw="$1"
  local body

  body="$(printf '%s' "$raw" | tr -d '[:space:]')"
  # Strip the prefix in either case (e.g. CU- / cu-) before re-adding it.
  body="${body#"${TASK_ID_PREFIX}"-}"
  body="${body#"${TASK_ID_PREFIX_LC}"-}"

  body="$(printf '%s' "$body" | tr -cd '[:alnum:]-')"
  if [[ -z "$body" ]]; then
    err "Invalid task id: '$raw'"
    exit 1
  fi

  printf '%s-%s' "$TASK_ID_PREFIX" "$body"
}

slugify_name() {
  local raw="$1"
  local out

  out="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  out="$(printf '%s' "$out" | sed -E 's/[[:space:]_]+/-/g')"
  out="$(printf '%s' "$out" | sed -E 's/[^a-z0-9-]//g')"
  out="$(printf '%s' "$out" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"

  if [[ -z "$out" ]]; then
    err "Feature name produces empty slug: '$raw'"
    exit 1
  fi

  printf '%s' "$out"
}

parse_args() {
  local positional=()
  local combined=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --remove)
        REMOVE_MODE=true
        shift
        ;;
      --no-claude)
        OPEN_CLAUDE=false
        shift
        ;;
      --prompt)
        if [[ $# -lt 2 ]]; then
          err "Missing value for --prompt"
          exit 1
        fi
        CLAUDE_PROMPT="$2"
        shift 2
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          positional+=("$1")
          shift
        done
        ;;
      -* )
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

  if [[ ${#positional[@]} -ne 1 ]]; then
    print_usage
    exit 1
  fi

  combined="${positional[0]}"

  # Support one-argument form: <PREFIX>-1234_MyProject (prefix is case-insensitive).
  local combined_lc
  combined_lc="$(printf '%s' "$combined" | tr '[:upper:]' '[:lower:]')"
  if [[ "$combined_lc" == "${TASK_ID_PREFIX_LC}"-*_* ]]; then
    TASK_INPUT="${combined%%_*}"
    FEATURE_NAME="${combined#*_}"
    if [[ -z "$FEATURE_NAME" ]]; then
      err "Missing feature name after '_' in '$combined'"
      exit 1
    fi
  else
    FEATURE_NAME="$combined"
  fi

  return 0
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { err "Required command not found: $cmd"; exit 1; }
}

require_repo() {
  local repo="$1"
  [[ -d "$repo/.git" ]] || { err "Not a git repo: $repo"; exit 1; }
}

resolve_base_ref() {
  local repo="$1"
  local branch="$2"

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s' "$branch"
    return
  fi

  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    printf 'origin/%s' "$branch"
    return
  fi

  err "Base branch '$branch' not found in $repo (local or origin/$branch)"
  exit 1
}

worktree_registered() {
  local repo="$1"
  local path="$2"

  git -C "$repo" worktree list --porcelain | grep -Fqx "worktree $path"
}

branch_exists_local() {
  local repo="$1"
  local branch="$2"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"
}

# Read-only check whether a branch exists on origin. Uses the already-fetched
# remote-tracking ref first, then falls back to a network query that mutates
# nothing locally.
remote_branch_exists() {
  local repo="$1"
  local branch="$2"

  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    return 0
  fi

  git -C "$repo" ls-remote --heads --exit-code origin "$branch" >/dev/null 2>&1
}

add_worktree() {
  local repo="$1"
  local branch="$2"
  local worktree_path="$3"
  local base_ref="$4"

  if branch_exists_local "$repo" "$branch"; then
    log "Reusing existing local branch '$branch' in $repo"
    run_cmd git -C "$repo" worktree add "$worktree_path" "$branch"
    return
  fi

  if remote_branch_exists "$repo" "$branch"; then
    log "Checking out existing remote branch 'origin/$branch' in $repo"
    run_cmd git -C "$repo" fetch origin "$branch"
    run_cmd git -C "$repo" worktree add --track -b "$branch" "$worktree_path" "origin/$branch"
    return
  fi

  log "Creating new branch '$branch' from '$base_ref' in $repo"
  run_cmd git -C "$repo" worktree add -b "$branch" "$worktree_path" "$base_ref"
}

open_workspace() {
  local workspace_file="$1"
  local session_dir="$2"

  run_cmd code -n "$workspace_file"

  if "$OPEN_CLAUDE"; then
    open_claude_session "$session_dir"
  fi
}

# Percent-encode a string so it is safe as a claude:// deep-link query value.
url_encode() {
  local raw="$1"
  local out=""
  local i c
  for (( i = 0; i < ${#raw}; i++ )); do
    c="${raw:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# Open the session directory as a Claude Code session in the Claude desktop app.
# Uses the claude://code/new deep link (folder = session root, optional prompt).
open_claude_session() {
  local session_dir="$1"
  local url="claude://code/new?folder=$(url_encode "$session_dir")"

  if [[ -n "$CLAUDE_PROMPT" ]]; then
    url="${url}&q=$(url_encode "$CLAUDE_PROMPT")"
  fi

  log "Opening Claude Code session in Claude desktop app for: $session_dir"
  run_cmd open "$url"
}

write_workspace_file() {
  local workspace_file="$1"
  local frontend_path="$2"
  local backend_path="$3"
  local accent_color="$4"

  if "$DRY_RUN"; then
    printf '[dry-run] write workspace file %s\n' "$workspace_file"
    return
  fi

  cat >"$workspace_file" <<EOF
{
  "folders": [
    { "path": "$frontend_path" },
    { "path": "$backend_path" }
  ],
  "settings": {
    "window.titleBarStyle": "custom",
    "workbench.colorCustomizations": {
      "titleBar.activeBackground": "$accent_color",
      "titleBar.inactiveBackground": "$accent_color",
      "titleBar.activeForeground": "#ffffff",
      "titleBar.inactiveForeground": "#ffffffcc"
    }
  }
}
EOF

}

remove_session() {
  local branch_slug="$1"
  local session_dir="$2"
  local frontend_worktree="$3"
  local backend_worktree="$4"
  local workspace_file="$5"

  log "Remove mode enabled for slug: $branch_slug"

  if worktree_registered "$FRONTEND_REPO" "$frontend_worktree"; then
    run_cmd git -C "$FRONTEND_REPO" worktree remove -f "$frontend_worktree"
  elif [[ -d "$frontend_worktree" ]]; then
    err "Frontend path exists but is not a registered worktree: $frontend_worktree"
    exit 1
  else
    log "No frontend worktree found. Skipping."
  fi

  if worktree_registered "$BACKEND_REPO" "$backend_worktree"; then
    run_cmd git -C "$BACKEND_REPO" worktree remove -f "$backend_worktree"
  elif [[ -d "$backend_worktree" ]]; then
    err "Backend path exists but is not a registered worktree: $backend_worktree"
    exit 1
  else
    log "No backend worktree found. Skipping."
  fi

  if branch_exists_local "$FRONTEND_REPO" "$branch_slug"; then
    run_cmd git -C "$FRONTEND_REPO" branch -D "$branch_slug"
  else
    log "No local frontend branch '$branch_slug'. Skipping."
  fi

  if branch_exists_local "$BACKEND_REPO" "$branch_slug"; then
    run_cmd git -C "$BACKEND_REPO" branch -D "$branch_slug"
  else
    log "No local backend branch '$branch_slug'. Skipping."
  fi

  if [[ -f "$workspace_file" ]]; then
    run_cmd rm -f "$workspace_file"
  else
    log "No workspace file found. Skipping."
  fi

  if [[ -d "$session_dir" ]] && [[ -z "$(ls -A "$session_dir")" ]]; then
    run_cmd rmdir "$session_dir"
  fi

  log "Remove complete for slug: $branch_slug"
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

main() {
  parse_args "$@"

  require_command git
  require_command sed
  require_repo "$FRONTEND_REPO"
  require_repo "$BACKEND_REPO"
  if ! "$REMOVE_MODE"; then
    require_command code
  fi

  local normalized_task=""
  local name_slug
  local branch_slug
  local session_dir
  local frontend_worktree
  local backend_worktree
  local workspace_file
  local workspace_color=""
  local frontend_ref
  local backend_ref

  name_slug="$(slugify_name "$FEATURE_NAME")"

  if [[ -n "$TASK_INPUT" ]]; then
    normalized_task="$(normalize_task_id "$TASK_INPUT")"
    branch_slug="${normalized_task}_${name_slug}"
  else
    branch_slug="$name_slug"
  fi

  session_dir="$WORKTREES_ROOT/$branch_slug"
  frontend_worktree="$session_dir/$FRONTEND_DIR_NAME"
  backend_worktree="$session_dir/$BACKEND_DIR_NAME"
  workspace_file="$ROOT_DIR/$branch_slug.code-workspace"

  frontend_ref="$(resolve_base_ref "$FRONTEND_REPO" "$FRONTEND_BASE_BRANCH")"
  backend_ref="$(resolve_base_ref "$BACKEND_REPO" "$BACKEND_BASE_BRANCH")"

  log "Session slug: $branch_slug"
  log "Frontend worktree: $frontend_worktree"
  log "Backend worktree: $backend_worktree"
  log "Workspace file: $workspace_file"

  if "$REMOVE_MODE"; then
    remove_session "$branch_slug" "$session_dir" "$frontend_worktree" "$backend_worktree" "$workspace_file"
    exit 0
  fi

  local frontend_exists=false
  local backend_exists=false
  [[ -d "$frontend_worktree" ]] && frontend_exists=true
  [[ -d "$backend_worktree" ]] && backend_exists=true

  if "$frontend_exists" && "$backend_exists"; then
    if worktree_registered "$FRONTEND_REPO" "$frontend_worktree" && worktree_registered "$BACKEND_REPO" "$backend_worktree"; then
      log "Session already exists completely. Opening workspace only."
      if [[ ! -f "$workspace_file" ]]; then
        workspace_color="$(random_workspace_color)"
        log "Workspace color: $workspace_color"
        write_workspace_file "$workspace_file" "$frontend_worktree" "$backend_worktree" "$workspace_color"
      fi
      open_workspace "$workspace_file" "$session_dir"
      exit 0
    fi

    err "Both worktree paths exist, but at least one is not registered as git worktree. Refusing."
    exit 1
  fi

  if "$frontend_exists" || "$backend_exists"; then
    err "Partial existing session detected. Refusing to continue."
    exit 1
  fi

  local created_frontend=false
  local created_backend=false

  cleanup_on_error() {
    local status=$?
    if [[ $status -ne 0 ]] && ! "$DRY_RUN"; then
      err "Creation failed. Rolling back newly created worktrees."
      if "$created_backend"; then
        git -C "$BACKEND_REPO" worktree remove -f "$backend_worktree" || true
      fi
      if "$created_frontend"; then
        git -C "$FRONTEND_REPO" worktree remove -f "$frontend_worktree" || true
      fi
    fi
    exit "$status"
  }
  trap cleanup_on_error EXIT

  run_cmd mkdir -p "$session_dir"

  add_worktree "$FRONTEND_REPO" "$branch_slug" "$frontend_worktree" "$frontend_ref"
  created_frontend=true

  add_worktree "$BACKEND_REPO" "$branch_slug" "$backend_worktree" "$backend_ref"
  created_backend=true

  workspace_color="$(random_workspace_color)"
  log "Workspace color: $workspace_color"
  write_workspace_file "$workspace_file" "$frontend_worktree" "$backend_worktree" "$workspace_color"

  log "Worktrees created successfully. Opening workspace."
  open_workspace "$workspace_file" "$session_dir"

  trap - EXIT
}

main "$@"
