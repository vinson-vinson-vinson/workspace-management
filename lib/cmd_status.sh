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
      --mr      Also look up each repo's open merge request (a network call,
                so it's off by default — the rest of the report is local).
      --json    Machine-readable output, including the dependency checks
                (node_modules, vendor, cognitor key, test DB) the human view
                omits. Combine with --mr to include the MR links.
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

# ─── main ─────────────────────────────────────────────────────────────────
cmd_status() {
  local slug="" show_all=false show_mr=false show_json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) show_all=true; shift ;;
      --mr) show_mr=true; shift ;;
      --json) show_json=true; shift ;;
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
  # One lsof for every listening port, then a membership test — four separate
  # `lsof -i :PORT` calls cost ~4x as much (each is a full process spawn).
  # `|| true`: lsof exits non-zero when nothing listens, which set -e would
  # otherwise treat as fatal.
  local listening
  listening="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {n=$9; sub(/.*:/,"",n); print n}' | sort -u || true)"
  # Parallel "key:value" array rather than declare -A: macOS ships bash 3.2,
  # which has no associative arrays. Same trick as the APPS registry.
  local -a app_running=()
  local port
  for key in "${apps[@]}"; do
    port="$(port_for "$key")"
    if printf '%s\n' "$listening" | grep -qxF "$port"; then
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

  # ── links ───────────────────────────────────────────────────────────────
  # The task link is local string work; MR links are a glab call each, so they
  # only run under --mr. No separate `glab auth status` preflight (another round
  # trip) — _mr_url just yields nothing when glab is absent or unauthenticated.
  MR_LOOKUP="$show_mr"
  local task_url fe_mr="" be_mr=""
  task_url="$(_task_url "$slug")"
  if "$MR_LOOKUP" && command -v glab >/dev/null 2>&1; then
    fe_mr="$(_mr_url "$wt_fe" "$fe_branch")"
    be_mr="$(_mr_url "$wt_be" "$be_branch")"
  fi

  # ── which apps are actually served ──────────────────────────────────────
  # DEV SERVERS should list what this workspace serves, not every app that
  # happens to have a directory — panels/outlook aren't served by default and
  # were just noise. Read the nginx block for the ports it proxies; if the
  # workspace isn't served yet, fall back to what it WOULD serve so "stopped"
  # still means something.
  local -a served_apps=()
  local conf="$VALET_NGINX_DIR/$host" d
  for key in "${apps[@]}"; do
    if "$served"; then
      grep -qE "127\.0\.0\.1:$(port_for "$key")([^0-9]|$)" "$conf" 2>/dev/null \
        && served_apps+=("$key")
    else
      for d in "${DEFAULT_APPS[@]}"; do [[ "$key" == "$d" ]] && served_apps+=("$key"); done
    fi
  done

  # ── horizon (the backend queue worker) ──────────────────────────────────
  local horizon_state="stopped"
  _horizon_running "$wt_be" && horizon_state="running"

  if "$show_json"; then
    _status_json; return 0
  fi

  # ═══════════════════════════════════════════════════════════════════════
  # Render
  # ═══════════════════════════════════════════════════════════════════════

  local L=10   # label column width, shared by every block

  # Header — the workspace's own accent (its title-bar colour, the same one
  # `ws list` swatches and the favicon rings use) over the brand gradient rule,
  # so status reads as part of the same family as `ws list` / `ws serve`.
  local accent bar swatch
  accent="$(_ws_color "$slug")"
  bar="$(_accent_seq "$accent")"; [[ -n "$bar" ]] || bar="$C_DIM"
  swatch="$(_ws_swatch "$accent")"; [[ -n "$swatch" ]] || swatch="${C_DIM}●${C_RESET}"

  printf '\n  %s %s%s%s\n' "$swatch" "$C_BOLD" "$slug" "$C_RESET"
  printf '  %s\n' "$(ws_grad "$(ws_rule '─' 46)" 46)"
  printf '  %-*s %s\n' "$L" "path" "$session_dir"
  [[ -n "$task_url" ]] && printf '  %-*s %s\n' "$L" "task" "$(_status_link "$task_url")"
  if "$served"; then
    printf '  %-*s %s\n' "$L" "url" "$(_status_link "https://${host}${ADMIN_PATH}")"
  else
    printf '  %-*s %snot served%s\n' "$L" "url" "$C_DIM" "$C_RESET"
  fi

  # ── Frontend ────────────────────────────────────────────────────────────
  printf '\n  %s▍%s %sfrontend%s  %s%s%s\n' \
    "$bar" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$FRONTEND_DIR_NAME" "$C_RESET"
  printf '  %-*s %s\n' "$L" "branch" "$fe_branch"
  printf '  %-*s %s\n' "$L" "git" "$(_git_colour "$fe_git")"
  _status_mr "$fe_mr"
  local key entry is_running
  for key in ${served_apps[@]+"${served_apps[@]}"}; do
    is_running=false
    for entry in ${app_running[@]+"${app_running[@]}"}; do
      [[ "${entry%%:*}" == "$key" ]] && { is_running="${entry#*:}"; break; }
    done
    _server_line "$key" ":$(port_for "$key")" "$is_running"
  done

  # ── Backend ─────────────────────────────────────────────────────────────
  printf '\n  %s▍%s %sbackend%s  %s%s%s\n' \
    "$bar" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$BACKEND_DIR_NAME" "$C_RESET"
  printf '  %-*s %s\n' "$L" "branch" "$be_branch"
  printf '  %-*s %s\n' "$L" "git" "$(_git_colour "$be_git")"
  _status_mr "$be_mr"
  _server_line "horizon" "" "$([[ "$horizon_state" == running ]] && echo true || echo false)"

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
    printf '  %-10s %s\n' "mr" "$(_status_link "$url")"
  else
    printf '  %-10s %snone%s\n' "mr" "$C_DIM" "$C_RESET"
  fi
}

# "clean" in green, anything else (uncommitted/unpushed) in yellow.
_git_colour() {
  [[ "$1" == "clean" ]] && printf '%sclean%s' "$C_GREEN" "$C_RESET" \
    || printf '%s%s%s' "$C_YELLOW" "$1" "$C_RESET"
}

# One "server" line: name, optional detail (a :port), and running/stopped.
_server_line() {
  local label="$1" detail="$2" up="$3" state
  if [[ "$up" == "true" ]]; then
    state="${C_GREEN}running${C_RESET}"
  else
    state="${C_DIM}stopped${C_RESET}"
  fi
  printf '  %-10s %-7s %s\n' "$label" "$detail" "$state"
}

# True if a `php artisan horizon` is running out of this backend worktree.
# Matched by cwd, since horizon's argv carries no path — pgrep alone can't tell
# one workspace's worker from another's.
_horizon_running() {
  local wt_be="$1" pid wd
  for pid in $(pgrep -f 'artisan horizon' 2>/dev/null); do
    wd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    case "$wd" in "$wt_be"*) return 0 ;; esac
  done
  return 1
}

# Machine-readable report. Reads cmd_status's locals (bash dynamic scope) and
# emits JSON via python3 — the deps live here rather than cluttering the human
# view, which is almost always all-green. Env vars, not argv, to sidestep
# quoting.
_status_json() {
  local key entry is_running apps_lines=""
  for key in ${served_apps[@]+"${served_apps[@]}"}; do
    is_running=false
    for entry in ${app_running[@]+"${app_running[@]}"}; do
      [[ "${entry%%:*}" == "$key" ]] && { is_running="${entry#*:}"; break; }
    done
    apps_lines="${apps_lines}$(printf '%s\t%s\t%s' "$key" "$(port_for "$key")" "$is_running")
"
  done

  WSJ_SLUG="$slug" WSJ_PATH="$session_dir" WSJ_SERVED="$served" \
  WSJ_HOST="$host" WSJ_ADMIN="$ADMIN_PATH" WSJ_TASK="$task_url" \
  WSJ_FE_BRANCH="$fe_branch" WSJ_FE_GIT="$fe_git" WSJ_NODE="$node_modules_ok" WSJ_FE_MR="$fe_mr" \
  WSJ_BE_BRANCH="$be_branch" WSJ_BE_GIT="$be_git" WSJ_VENDOR="$vendor_ok" WSJ_COG="$cognitor_ok" \
  WSJ_TESTDB="$test_db_state" WSJ_HORIZON="$horizon_state" WSJ_BE_MR="$be_mr" \
  WSJ_APPS="$apps_lines" \
  python3 <<'PY'
import json, os
def b(v): return v == "true"
served = b(os.environ["WSJ_SERVED"])
servers = []
for line in os.environ.get("WSJ_APPS", "").splitlines():
    if not line.strip():
        continue
    name, port, running = line.split("\t")
    servers.append({"app": name, "port": int(port), "running": b(running)})
print(json.dumps({
    "slug": os.environ["WSJ_SLUG"],
    "path": os.environ["WSJ_PATH"],
    "served": served,
    "url": ("https://%s%s" % (os.environ["WSJ_HOST"], os.environ["WSJ_ADMIN"])) if served else None,
    "task_url": os.environ["WSJ_TASK"] or None,
    "frontend": {
        "branch": os.environ["WSJ_FE_BRANCH"],
        "git": os.environ["WSJ_FE_GIT"],
        "node_modules": b(os.environ["WSJ_NODE"]),
        "servers": servers,
        "mr": os.environ["WSJ_FE_MR"] or None,
    },
    "backend": {
        "branch": os.environ["WSJ_BE_BRANCH"],
        "git": os.environ["WSJ_BE_GIT"],
        "vendor": b(os.environ["WSJ_VENDOR"]),
        "cognitor_key": b(os.environ["WSJ_COG"]),
        "test_db": os.environ["WSJ_TESTDB"],
        "horizon": os.environ["WSJ_HORIZON"],
        "mr": os.environ["WSJ_BE_MR"] or None,
    },
}, indent=2))
PY
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
