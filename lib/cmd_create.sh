# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_create.sh — `workspaces create`: cut matching frontend+backend
# worktrees into a session dir, write a .code-workspace, and open the
# configured IDE(s). (Teardown lives in `workspaces remove`.)
# -----------------------------------------------------------------------------

cmd_create_usage() {
  cat <<'USAGE'
Usage:
  ws create <NAME_OR_TASK_AND_NAME> [BASE_BRANCH] [-n|--neanderthal] [--dry-run]

Rules:
  - With task:    CU-<taskId>_<feature-name>  -> slug/branch CU-<taskId>_<feature-name>
  - Without task: <feature-name>              -> slug/branch <feature-name>
  - BASE_BRANCH bases the new workspace branches on an existing branch instead
    of the configured base (main) — e.g. to stack follow-up work on a feature
    still in review. Applied per repo where the branch exists (locally or on
    origin); a repo without it falls back to its configured base, with a
    warning. Missing in both repos is an error.
  - The workspace opens automatically in the IDE(s) named by FRONTEND_IDE /
    BACKEND_IDE in config.sh (disable with NO_OPEN_AFTER_CREATE=true). When
    that is VS Code, it also starts one terminal running `ws serve`, and when
    it finishes, one terminal per default app running `yarn serve-<app>`.

Options:
  -n, --neanderthal    Bare workspace: skip the auto-started serve/dev-server
                       terminals (you run everything by hand, like it's 2024).
  --dry-run            Print actions without executing them.
  -h, --help           Show this help.

Examples:
  ws create CU-1234_Test-Project
  ws create CU-5678_follow-up CU-1234_Test-Project
  ws create MyNewProject --neanderthal
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
  # USE_REMOTE_MAIN flips the preference: base on origin/<branch> (freshly
  # fetched by cmd_create) instead of the local checkout, falling back to the
  # local branch only when no remote-tracking ref exists.
  if "$USE_REMOTE_MAIN" && git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    printf 'origin/%s' "$branch"; return
  fi
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

# True if BRANCH exists in REPO at all — locally or on origin.
branch_available() {
  branch_exists_local "$1" "$2" || remote_branch_exists "$1" "$2"
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
  # --no-track: when the base is origin/<base-branch> (USE_REMOTE_MAIN), git
  # would otherwise set THAT as upstream and the feature branch would look like
  # it pushes to main. No-op for a local base.
  run_quiet git -C "$repo" worktree add --no-track -b "$branch" "$worktree_path" "$base_ref"
}

# Open the workspace in the configured IDE(s) and print the milestone check —
# or, with NO_OPEN_AFTER_CREATE=true in the config, do neither and say so
# instead. Uses cmd_create's session paths (dynamic scope).
open_workspace() {
  local workspace_file="$1"
  if "$NO_OPEN_AFTER_CREATE"; then
    ok "IDE not opened (config: NO_OPEN_AFTER_CREATE)"
    return 0
  fi
  open_workspace_editors "$frontend_worktree" "$backend_worktree" \
    "$workspace_file" "$session_dir" "$branch_slug"
}

# The .code-workspace auto-serve tasks only ever fire in VS Code, so with any
# other IDE configured `ws create` finished with an unserved workspace and no
# indication why. Run `ws serve` directly in that case, to match the zero-step
# VS Code flow. Idempotent: safe on an already-served workspace.
auto_serve_if_needed() {
  if ! "$AUTO_SERVE"; then
    vlog "Neanderthal mode — skipping auto-serve."
    return 0
  fi
  # VS Code handles serve + dev servers via .code-workspace tasks.
  [[ "$FRONTEND_IDE" == "vscode" && "$BACKEND_IDE" == "vscode" ]] && return 0
  # The child process parses its own flags, so --dry-run would NOT propagate —
  # without this guard a dry-run create performed a fully real serve (env
  # writes, dependency install, nginx + sudo) on an existing workspace.
  if "$DRY_RUN"; then
    printf '[dry-run] %s serve %s\n' "$WSM_HOME/workspaces" "$branch_slug"
    return 0
  fi
  # `|| true`: a failed serve must not abort create — the worktrees exist and
  # are usable, and serve prints its own diagnosis.
  log "Serving workspace…"
  WSM_HOME="$WSM_HOME" "$WSM_HOME/workspaces" serve "$branch_slug" || true
}

# Pick a legible title-bar foreground ("dark"/"light") for a "#rrggbb" bg using
# the W3C relative-luminance threshold.
contrast_foreground() {
  local hex="${1#\#}" r g b lum
  r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
  lum=$(((r * 299 + g * 587 + b * 114) / 1000))
  if ((lum > 150)); then printf 'dark'; else printf 'light'; fi
}

# Emit the workspace "tasks" block that auto-starts the dev terminals when the
# workspace opens: one terminal running `ws serve`, then — once serve has
# finished — one terminal per default app running `yarn serve-<app>`. The dev
# servers MUST wait for serve: on a fresh worktree it copies .env.yarn (the
# private-registry tokens .yarnrc.yml needs, e.g. ANNY_NPM_TOKEN) and installs
# node_modules; started in parallel, yarn dies immediately on the missing env.
# Each yarn task therefore dependsOn "ws serve" directly — VS Code dedupes the
# shared dependency, so serve runs once and both terminals start when it's done.
# (Deliberately NOT a command-less "dev servers" compound between them: nested
# compounds are exactly what VS Code sequenced unreliably.) "folderOpen" makes
# VS Code run it automatically (first open may ask once to allow automatic
# tasks / trust the folder).
# NOTE: built with printf, not a captured heredoc — macOS bash 3.2 mishandles
# heredocs inside $(...) (same caveat as the nginx block in cmd_serve.sh).
emit_workspace_tasks() {
  local frontend_dir="$1" backend_dir="$2"
  local app labels=""
  printf '%s\n' \
'  "tasks": {' \
'    "version": "2.0.0",' \
'    "tasks": [' \
'      {' \
'        "label": "ws serve",' \
'        "type": "shell",' \
'        "command": "ws serve",' \
"        \"options\": { \"cwd\": \"\${workspaceFolder:${backend_dir}}\" }," \
'        "presentation": { "panel": "dedicated", "reveal": "always", "group": "dev-servers" },' \
'        "problemMatcher": []' \
'      },'
  for app in ${DEFAULT_APPS[@]+"${DEFAULT_APPS[@]}"}; do
    printf '%s\n' \
'      {' \
"        \"label\": \"yarn serve-${app}\"," \
'        "type": "shell",' \
"        \"command\": \"yarn serve-${app}\"," \
"        \"options\": { \"cwd\": \"\${workspaceFolder:${frontend_dir}}\" }," \
'        "isBackground": true,' \
'        "dependsOn": ["ws serve"],' \
'        "presentation": { "panel": "dedicated", "reveal": "always", "group": "dev-servers" },' \
'        "problemMatcher": []' \
'      },'
    [[ -n "$labels" ]] && labels+=", "
    labels+="\"yarn serve-${app}\""
  done
  printf '%s\n' \
'      {' \
'        "label": "workspace up",' \
"        \"dependsOn\": [${labels}]," \
'        "runOptions": { "runOn": "folderOpen" },' \
'        "problemMatcher": []' \
'      }' \
'    ]' \
'  },'
}

write_workspace_file() {
  # frontend_dir/backend_dir are relative to the workspace file, which now lives
  # inside the session dir next to the two worktrees — so the paths are just the
  # worktree directory names and the whole session dir is self-contained.
  local workspace_file="$1" frontend_dir="$2" backend_dir="$3" accent_color="$4"
  local tasks_note=""
  "$AUTO_SERVE" && tasks_note=" (with auto-serve terminal tasks)"
  if "$DRY_RUN"; then
    printf '[dry-run] write workspace file %s%s\n' "$workspace_file" "$tasks_note"; return
  fi
  local active_fg inactive_fg
  if [[ "$(contrast_foreground "$accent_color")" == "dark" ]]; then
    active_fg="#000000"; inactive_fg="#000000cc"
  else
    active_fg="#ffffff"; inactive_fg="#ffffffcc"
  fi
  # --neanderthal writes the same file minus the tasks block (and minus the
  # setting that lets the block run unprompted — pointless without it).
  local tasks_block="" allow_tasks=""
  if "$AUTO_SERVE"; then
    tasks_block="$(emit_workspace_tasks "$frontend_dir" "$backend_dir")"$'\n'
    allow_tasks=$'\n    "task.allowAutomaticTasks": "on",'
  fi
  # Shared local packages etc. from the config, appended as extra workspace
  # folders (absolute paths — they live outside the session dir). Paths missing
  # on this machine are skipped so a config written elsewhere can't produce
  # dead folders.
  local extra_folders="" extra
  for extra in ${EXTRA_WORKSPACE_FOLDERS[@]+"${EXTRA_WORKSPACE_FOLDERS[@]}"}; do
    if [[ -d "$extra" ]]; then
      extra_folders+=$',\n    { "path": "'"$extra"'" }'
    else
      warn "extra workspace folder not found (skipped): $extra"
    fi
  done
  cat >"$workspace_file" <<EOF
{
  "folders": [
    { "path": "$frontend_dir" },
    { "path": "$backend_dir" }$extra_folders
  ],
${tasks_block}  "settings": {${allow_tasks}
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
  AUTO_SERVE=true
  local TASK_INPUT="" FEATURE_NAME="" BASE_OVERRIDE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--neanderthal) AUTO_SERVE=false; shift ;;
      --dry-run)   DRY_RUN=true; shift ;;
      -h|--help)   cmd_create_usage; exit 0 ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
      -*) err "Unknown option: $1"; cmd_create_usage; exit 1 ;;
      *)  positional+=("$1"); shift ;;
    esac
  done

  if [[ ${#positional[@]} -lt 1 || ${#positional[@]} -gt 2 ]]; then
    cmd_create_usage; exit 1
  fi
  combined="${positional[0]}"
  BASE_OVERRIDE="${positional[1]:-}"

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
  # The IDE launcher(s) are only needed to open the workspace at the end.
  "$NO_OPEN_AFTER_CREATE" || require_configured_ides
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

  # Optional BASE_BRANCH argument: base the workspace on an existing branch
  # instead of the configured base — per repo, since a feature branch may only
  # exist in one of them (the other keeps its configured base).
  local fe_base="$FRONTEND_BASE_BRANCH" be_base="$BACKEND_BASE_BRANCH"
  if [[ -n "$BASE_OVERRIDE" ]]; then
    local fe_has=false be_has=false
    branch_available "$FRONTEND_REPO" "$BASE_OVERRIDE" && fe_has=true
    branch_available "$BACKEND_REPO" "$BASE_OVERRIDE" && be_has=true
    if ! "$fe_has" && ! "$be_has"; then
      err "Base branch '$BASE_OVERRIDE' not found in either repo (local or origin)."
      exit 1
    fi
    if "$fe_has"; then fe_base="$BASE_OVERRIDE"; else
      warn "'$BASE_OVERRIDE' not found in $FRONTEND_DIR_NAME — using '$fe_base' there."
    fi
    if "$be_has"; then be_base="$BASE_OVERRIDE"; else
      warn "'$BASE_OVERRIDE' not found in $BACKEND_DIR_NAME — using '$be_base' there."
    fi
  fi

  # USE_REMOTE_MAIN promises the LIVE remote: refresh the remote-tracking refs
  # first, or origin/<base-branch> would just mean "as of the last fetch". A
  # failed fetch (e.g. offline) degrades to that last-fetched state with a
  # warning rather than aborting.
  if "$USE_REMOTE_MAIN"; then
    local fetch_ok=true
    spin "fetching origin base branches"
    run_quiet git -C "$FRONTEND_REPO" fetch origin "$fe_base" || fetch_ok=false
    run_quiet git -C "$BACKEND_REPO" fetch origin "$be_base" || fetch_ok=false
    if "$fetch_ok"; then
      spin_ok "origin base branches fetched"
    else
      spin_stop
      warn "fetch failed — branching from the last-fetched origin state instead."
    fi
  fi

  frontend_ref="$(resolve_base_ref "$FRONTEND_REPO" "$fe_base")"
  backend_ref="$(resolve_base_ref "$BACKEND_REPO" "$be_base")"

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
      # Idempotent; also retrofits workspaces created before test DBs existed.
      # Everything in CONDITIONS — a bare `x && y` in a body trips set -e. The
      # helper stops the spinner itself before any warning.
      if "$TEST_DB_ENABLED"; then
        spin "creating test database"
        if test_db_ensure "$branch_slug"; then
          spin_ok "test DB ready ($(resolve_test_db "$branch_slug"))"
        fi
      fi
      open_workspace "$workspace_file"
      auto_serve_if_needed
      auto_open_terminals_if_needed "$frontend_worktree" "$backend_worktree" "${DEFAULT_APPS[@]}"
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
  local fe_branch_origin be_branch_origin
  spin "creating worktrees"
  add_worktree "$FRONTEND_REPO" "$branch_slug" "$frontend_worktree" "$frontend_ref"
  created_frontend=true
  fe_branch_origin="$BRANCH_ORIGIN"
  add_worktree "$BACKEND_REPO" "$branch_slug" "$backend_worktree" "$backend_ref"
  created_backend=true
  be_branch_origin="$BRANCH_ORIGIN"
  spin_stop
  # Usually both repos take the same base and the two origins agree; with a
  # BASE_BRANCH that exists in only one repo they can differ — say so.
  if [[ "$fe_branch_origin" == "$be_branch_origin" ]]; then
    ok "branches ${BRANCH_ORIGIN} ($branch_slug)"
  else
    ok "branches: $FRONTEND_DIR_NAME ${fe_branch_origin}, $BACKEND_DIR_NAME ${be_branch_origin} ($branch_slug)"
  fi
  ok "worktrees added ($FRONTEND_DIR_NAME, $BACKEND_DIR_NAME)"

  workspace_color="$(random_workspace_color)"
  vlog "Workspace color: $workspace_color"
  write_workspace_file "$workspace_file" "$FRONTEND_DIR_NAME" "$BACKEND_DIR_NAME" "$workspace_color"
  ok "workspace file written"

  vlog "Worktrees created successfully. Opening workspace."
  sync_scm_ignores
  # Warn-and-continue: workspace creation must not fail over an optional
  # convenience (no MySQL, bad creds); `ws test` re-ensures on demand. The
  # helper stops the spinner itself before any warning.
  if "$TEST_DB_ENABLED"; then
    spin "creating test database"
    if test_db_ensure "$branch_slug"; then
      spin_ok "test DB ready ($(resolve_test_db "$branch_slug"))"
    fi
  fi
  # Checked last, once it has actually happened — not announced in advance.
  open_workspace "$workspace_file"
  auto_serve_if_needed
  auto_open_terminals_if_needed "$frontend_worktree" "$backend_worktree" "${DEFAULT_APPS[@]}"

  trap - EXIT
}
