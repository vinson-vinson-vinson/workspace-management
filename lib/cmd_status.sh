# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_status.sh — `workspaces status`: workspace health check.
#
# Auto-detects slug from CWD or accepts it as a positional argument. Shows a
# structured report of every aspect of a workspace: branches, git status, nginx
# serving, port assignments, dev-server liveness, and dependency state.
# -----------------------------------------------------------------------------

# --- reuse the app-registry + port helpers from serve ------------------------
# shellcheck source=/dev/null
source "$LIB_DIR/cmd_serve.sh"

cmd_status_usage() {
  cat <<'USAGE'
Usage:
  ws status [SLUG] [--all]

Show a workspace health report: branch, git status, serving, ports, dev-server
liveness, and dependencies.

With no SLUG, reports the workspace you are standing in; from anywhere else,
falls back to a one-line-per-workspace overview of all of them (--all forces
the overview).

Options:
      --all     Overview of every workspace instead of one report.
  -h, --help    Show this help.
USAGE
}

# ─── git helpers ──────────────────────────────────────────────────────────
# Echo "uncommitted" and count changed files, or nothing.
_git_uncommitted() {
  local repo="$1" out count
  out="$(git -C "$repo" status --porcelain 2>/dev/null)" || return 0
  [[ -z "$out" ]] && return 0
  count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  printf 'uncommitted (%s file(s))' "$count"
}

# Echo "unpushed" and commit count ahead, or nothing. Checks HEAD's own upstream
# (the branch @{u} actually tracks), not a hardcoded origin/main.
_git_unpushed() {
  local repo="$1" ahead
  ahead="$(git -C "$repo" rev-list --count @{u}..HEAD 2>/dev/null)" || return 0
  [[ "$ahead" -gt 0 ]] && printf 'unpushed (%s commit(s))' "$ahead"
}

# Combined git summary: "clean" or "uncommitted (N)" and/or "unpushed (N)".
_git_summary() {
  local repo="$1" u p
  u="$(_git_uncommitted "$repo")"
  p="$(_git_unpushed "$repo")"
  if [[ -z "$u" && -z "$p" ]]; then
    printf 'clean'
  elif [[ -n "$u" && -n "$p" ]]; then
    printf '%s, %s' "$u" "$p"
  elif [[ -n "$u" ]]; then
    printf '%s' "$u"
  else
    printf '%s' "$p"
  fi
}

# ─── dependency helpers ────────────────────────────────────────────────────
# Cognitor key path relative to storage/, read from the worktree .env
# (falling back to main's). Empty if neither env exists.
_cognitor_rel_path() {
  local env="$1"
  [[ -f "$env" ]] || return 0
  local val
  val="$(grep -E '^IAM_PUBLIC_KEY_PATH=' "$env" | tail -1 | cut -d= -f2-)"
  val="${val//\"/}"; val="${val//\'/}"; val="${val// /}"
  [[ -n "$val" ]] || val="cognitor.key"
  printf '%s' "$val"
}

# Existence of the workspace's test DB. Three answers, not two: "can't check"
# (bad creds, mysql down) must not read as "missing" — the fix is different.
# Echoes yes|no|disabled|unavailable.
_test_db_state() {
  local slug="$1" name out
  "$TEST_DB_ENABLED" || { printf 'disabled'; return 0; }
  command -v mysql >/dev/null 2>&1 || { printf 'unavailable'; return 0; }
  name="$(resolve_test_db "$slug")" || { printf 'unavailable'; return 0; }
  out="$(_test_db_sql "SHOW DATABASES LIKE '${name}'")"
  case "$out" in
    *ERROR*) printf 'unavailable' ;;
    *"$name"*) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

# Like _status_check but for a state that isn't a boolean.
_status_state() {
  local label="$1" state="$2" icon
  case "$state" in
    yes)         icon="${C_GREEN}✓${C_RESET}" ;;
    disabled)    icon="${C_DIM}— disabled${C_RESET}" ;;
    unavailable) icon="${C_YELLOW}? unavailable${C_RESET}" ;;
    *)           icon="${C_YELLOW}✗${C_RESET}" ;;
  esac
  printf '  %-18s %b\n' "$label" "$icon"
}

# ─── status check outputs (one per concern, @ok/@warn-style) ──────────────
_status_check() {
  local label="$1" ok="$2"
  local check icon
  if "$ok"; then
    check="${C_GREEN}✓${C_RESET}"
  else
    check="${C_YELLOW}✗${C_RESET}"
  fi
  printf '  %-18s %s\n' "$label" "$check"
}

# ─── main ─────────────────────────────────────────────────────────────────
cmd_status() {
  local slug="" show_all=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) show_all=true; shift ;;
      -h|--help) cmd_status_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_status_usage; exit 1 ;;
      *)  [[ -z "$slug" ]] || { err "Unexpected extra argument: $1"; exit 1; }
          slug="$1"; shift ;;
    esac
  done

  require_command git
  require_command lsof

  # ── resolve slug ───────────────────────────────────────────────────────
  # Standing outside a worktree with no slug is not an error — it just means
  # you asked about the fleet rather than one workspace.
  if "$show_all"; then
    _status_overview; return $?
  fi
  if [[ -z "$slug" ]]; then
    slug="$(slug_from_cwd)" || { _status_overview; return $?; }
  fi

  local session_dir="$WORKSPACES_ROOT/$slug"
  [[ -d "$session_dir" ]] || { err "Workspace not found: $slug"; exit 1; }

  local wt_fe="$session_dir/$FRONTEND_DIR_NAME"
  local wt_be="$session_dir/$BACKEND_DIR_NAME"
  [[ -d "$wt_fe" && -d "$wt_be" ]] || {
    err "Incomplete workspace '$slug': missing frontend or backend worktree."
    exit 1
  }

  # ── branches ───────────────────────────────────────────────────────────
  local fe_branch be_branch
  fe_branch="$(worktree_branch "$wt_fe")"
  be_branch="$(worktree_branch "$wt_be")"
  fe_branch="${fe_branch:-(detached)}"
  be_branch="${be_branch:-(detached)}"

  # ── serving ────────────────────────────────────────────────────────────
  local sub host served=false
  sub="$(resolve_subdomain "$slug")" || sub="$slug"
  host="${sub}.${BASE_DOMAIN}"
  [[ -f "$VALET_NGINX_DIR/$host" ]] && served=true

  # ── port base ──────────────────────────────────────────────────────────
  PORT_BASE="$(compute_port_base "$sub")"

  # Collect servable apps that have a directory in this worktree.
  local -a apps=()
  local key
  while IFS= read -r key; do
    [[ -d "$wt_fe/$(app_dir "$key")" ]] && apps+=("$key")
  done < <(all_app_keys)

  # ── dev-server liveness ────────────────────────────────────────────────
  # Parallel "key:value" array rather than declare -A: macOS ships bash 3.2,
  # which has no associative arrays, and /bin/bash is what `ws` actually runs
  # under. Same trick as the APPS registry in config.sh.
  local -a app_running=()
  local port pid
  for key in "${apps[@]}"; do
    port="$(port_for "$key")"
    # `|| true`: lsof exits 1 when nothing is listening, and an assignment
    # takes the exit status of its command substitution — so under set -e the
    # first stopped dev server would abort `ws status` entirely.
    pid="$(lsof -i ":$port" -sTCP:LISTEN -t 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      app_running+=("${key}:true")
    else
      app_running+=("${key}:false")
    fi
  done

  # ── git status ─────────────────────────────────────────────────────────
  local fe_git be_git
  fe_git="$(_git_summary "$wt_fe")"
  be_git="$(_git_summary "$wt_be")"

  # ── backend deps ───────────────────────────────────────────────────────
  local vendor_ok=false cognitor_ok=false
  [[ -d "$wt_be/vendor" ]] && vendor_ok=true
  local cog_env="$wt_be/.env"
  [[ -f "$cog_env" ]] || cog_env="$BACKEND_REPO/.env"
  local cog_rel; cog_rel="$(_cognitor_rel_path "$cog_env")"
  [[ -n "$cog_rel" && -f "$wt_be/storage/$cog_rel" ]] && cognitor_ok=true
  local test_db_state; test_db_state="$(_test_db_state "$slug")"

  # ── frontend deps ──────────────────────────────────────────────────────
  local node_modules_ok=false
  [[ -d "$wt_fe/node_modules" ]] && node_modules_ok=true

  # ── links (single-workspace only; each MR is a network call) ────────────
  # Compute the auth check once, not per repo.
  MR_LOOKUP=false
  if command -v glab >/dev/null 2>&1 && glab auth status >/dev/null 2>&1; then
    MR_LOOKUP=true
  fi
  local task_url fe_mr="" be_mr=""
  task_url="$(_task_url "$slug")"
  if "$MR_LOOKUP"; then
    fe_mr="$(_mr_url "$wt_fe" "$fe_branch")"
    be_mr="$(_mr_url "$wt_be" "$be_branch")"
  fi

  # ═══════════════════════════════════════════════════════════════════════
  # Render
  # ═══════════════════════════════════════════════════════════════════════

  printf '\n'
  printf '  %sWORKSPACE%s  %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_CYAN" "$slug" "$C_RESET"
  printf '  %-11s %s\n' "Path" "$session_dir"
  [[ -n "$task_url" ]] && printf '  %-11s %s\n' "Task" "$(_status_link "$task_url")"

  # --- served row ---
  local served_label served_url
  if "$served"; then
    served_label="${C_GREEN}✓${C_RESET}"
    served_url="$(_status_link "https://${host}${ADMIN_PATH}")"
  else
    served_label="${C_DIM}—${C_RESET}"
    served_url="${C_DIM}not served${C_RESET}"
  fi
  printf '  %-11s %s  %s\n' "Served" "$served_label" "$served_url"

  # ── Frontend block ──────────────────────────────────────────────────────
  printf '\n  %s%sFRONTEND%s (%s)%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$FRONTEND_DIR_NAME" "$C_RESET"
  printf '    %-15s %s\n' "Branch" "$fe_branch"
  printf '    %-15s %s\n' "Git" "$fe_git"
  _status_check "node_modules" "$node_modules_ok"
  _status_mr "$fe_mr"

  # ── Backend block ───────────────────────────────────────────────────────
  printf '\n  %s%sBACKEND%s (%s)%s\n' \
    "$C_BOLD" "$C_MAGENTA" "$C_RESET" "$BACKEND_DIR_NAME" "$C_RESET"
  printf '    %-15s %s\n' "Branch" "$be_branch"
  printf '    %-15s %s\n' "Git" "$be_git"
  _status_check "vendor" "$vendor_ok"
  _status_check "cognitor.key" "$cognitor_ok"
  _status_state "test db" "$test_db_state"
  _status_mr "$be_mr"

  # ── Dev servers ─────────────────────────────────────────────────────────
  printf '\n  %s%sDEV SERVERS%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
  if [[ ${#apps[@]} -eq 0 ]]; then
    printf '    %s(no servable apps)%s\n' "$C_DIM" "$C_RESET"
  else
    local running_label entry is_running
    for key in "${apps[@]}"; do
      port="$(port_for "$key")"
      # Look the key up in the parallel array (see the bash 3.2 note above).
      # Full if/then, not `[[ … ]] && break`: under set -e a non-matching last
      # iteration would return 1 and take the whole command down with it.
      is_running=false
      for entry in ${app_running[@]+"${app_running[@]}"}; do
        if [[ "${entry%%:*}" == "$key" ]]; then
          is_running="${entry#*:}"
          break
        fi
      done
      if "$is_running"; then
        running_label="${C_GREEN}running${C_RESET}"
      else
        running_label="${C_DIM}not running${C_RESET}"
      fi
      printf '    %-10s :%-6s %s\n' "$key" "$port" "$running_label"
    done
  fi

  printf '\n'
}

# Task-tracker URL for a slug, or nothing. Needs TASK_URL_TEMPLATE set and the
# slug to be a task (<PREFIX>-<id>_…); {id} is the bit between the prefix dash
# and the first underscore.
_task_url() {
  local slug="$1" id
  [[ -n "$TASK_URL_TEMPLATE" ]] || return 0
  case "$slug" in
    "${TASK_ID_PREFIX}-"*|"${TASK_ID_PREFIX_LC}-"*) ;;
    *) return 0 ;;
  esac
  id="${slug#*-}"; id="${id%%_*}"
  [[ -n "$id" ]] || return 0
  printf '%s' "${TASK_URL_TEMPLATE//\{id\}/$id}"
}

# web_url of the open MR for BRANCH in WORKTREE, or nothing. One network call —
# callers gate on MR_LOOKUP so it never runs in the fleet overview.
_mr_url() {
  local worktree="$1" branch="$2" json
  [[ -n "$branch" ]] || return 0
  json="$( cd "$worktree" 2>/dev/null && glab mr list --source-branch "$branch" --output json 2>/dev/null )" || return 0
  [[ -n "$json" && "$json" != "[]" ]] || return 0
  printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["web_url"])' 2>/dev/null || true
}

# Render an "MR" row: the link, or a dim "none". Only when MR lookup is on.
_status_mr() {
  local url="$1"
  "$MR_LOOKUP" || return 0
  if [[ -n "$url" ]]; then
    printf '    %-15s %s\n' "MR" "$(_status_link "$url")"
  else
    printf '    %-15s %snone%s\n' "MR" "$C_DIM" "$C_RESET"
  fi
}

# Clickable green link for a URL. Terminal-only; plain text otherwise.
_status_link() {
  local url="$1"
  if "$TTY"; then
    printf '\033]8;;%s\033\\%s%s%s\033]8;;\033\\' "$url" "$C_GREEN" "$url" "$C_RESET"
  else
    printf '%s' "$url"
  fi
}

# ─── overview (every workspace, one line each) ─────────────────────────────
# Deliberately cheaper than the per-workspace report: branch + git + served +
# how many of the default apps are listening. Anything needing a per-app lsof
# beyond that belongs in the single-workspace view.
_status_overview() {
  local -a slugs=()
  local slug
  while IFS= read -r slug; do
    [[ -n "$slug" ]] && slugs+=("$slug")
  done < <(workspace_slugs)

  if [[ ${#slugs[@]} -eq 0 ]]; then
    log "No workspaces in $WORKSPACES_ROOT/"
    return 0
  fi

  spin "collecting workspace status"
  local -a rows=()
  local wt_fe wt_be sub host branch git_state served up total key port pid
  for slug in "${slugs[@]}"; do
    wt_fe="$WORKSPACES_ROOT/$slug/$FRONTEND_DIR_NAME"
    wt_be="$WORKSPACES_ROOT/$slug/$BACKEND_DIR_NAME"

    # ASCII placeholder: printf pads by BYTES, so a multibyte dash would
    # shift every column right of it.
    branch="$(worktree_branch "$wt_fe" 2>/dev/null)"; branch="${branch:--}"

    # Worst of the two repos: a workspace is only "clean" if both are.
    git_state="clean"
    if [[ -n "$(_git_uncommitted "$wt_fe")$(_git_uncommitted "$wt_be")" ]]; then
      git_state="dirty"
    elif [[ -n "$(_git_unpushed "$wt_fe")$(_git_unpushed "$wt_be")" ]]; then
      git_state="unpushed"
    fi

    served="no"; up=0; total=0
    if sub="$(resolve_subdomain "$slug" 2>/dev/null)"; then
      host="${sub}.${BASE_DOMAIN}"
      [[ -f "$VALET_NGINX_DIR/$host" ]] && served="yes"
      PORT_BASE="$(compute_port_base "$sub")"
      for key in "${DEFAULT_APPS[@]}"; do
        total=$(( total + 1 ))
        port="$(port_for "$key")"
        pid="$(lsof -i ":$port" -sTCP:LISTEN -t 2>/dev/null || true)"
        [[ -n "$pid" ]] && up=$(( up + 1 ))
      done
    fi

    # No BRANCH column: ws names the branch after the slug, so it would just
    # repeat this value. `ws status <slug>` shows the actual branch.
    rows+=("${slug}|${git_state}|${served}|${up}/${total}")
  done
  spin_stop

  # Size the name column to the data, capped — a ClickUp task slug can run 60+
  # chars and would otherwise shove every other column off the screen.
  local cap=40 name_w=9 row name
  for row in "${rows[@]}"; do
    name="${row%%|*}"
    [[ ${#name} -gt $name_w ]] && name_w=${#name}
  done
  [[ $name_w -gt $cap ]] && name_w=$cap

  printf '\n  %-*s %-9s %-7s %s\n' "$name_w" "WORKSPACE" "GIT" "SERVED" "SERVERS"
  local gs sv sr colour
  for row in "${rows[@]}"; do
    name="${row%%|*}"; row="${row#*|}"
    gs="${row%%|*}";   row="${row#*|}"
    sv="${row%%|*}";   sr="${row#*|}"
    # ASCII '~' marker, not '…': printf pads by bytes, so a multibyte ellipsis
    # would misalign the columns it's meant to fix.
    [[ ${#name} -gt $name_w ]] && name="${name:0:name_w-1}~"
    [[ "$gs" == "clean" ]] && colour="$C_GREEN" || colour="$C_YELLOW"
    printf '  %-*s %b%-9s%b %-7s %s\n' \
      "$name_w" "$name" "$colour" "$gs" "$C_RESET" "$sv" "$sr"
  done
  printf '\n  %sws status <slug>%s for the full report.\n\n' "$C_DIM" "$C_RESET"
}
