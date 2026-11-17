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
  ws status [SLUG] [--mr] [--json]
  ws status --all [--mr] [--json]

Show a workspace health report: branch, git status, serving, ports, dev-server
liveness, and dependencies.

With no SLUG, reports the workspace you are standing in; from anywhere else,
falls back to a one-line-per-workspace table of all of them.

Options:
      --all     Every workspace. Without --json: the one-line-per-workspace
                table. With --json: the full report of each, as one array.
      --mr      Also look up each repo's open merge request. Network calls, so
                off by default (the rest of the report is local): two glab
                calls for one workspace; with --all, one MR listing per repo
                for the whole fleet.
      --json    Machine-readable output, including the dependency checks
                (node_modules, vendor, cognitor key, test DB) the human view
                omits. The shape follows the arguments, never the current
                directory: one object for a workspace (SLUG, or the one you
                stand in), an array with --all. Outside a workspace without
                SLUG or --all it is an error.
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
  MR_LOOKUP="$show_mr"
  if "$show_all"; then
    _status_fleet "$show_json"; return $?
  fi
  # The JSON shape follows the arguments, never the cwd: a tool spawned inside
  # a workspace and one spawned outside must get the same kind of answer. So
  # the fleet array needs --all; only the human view falls back to the table.
  if [[ -z "$slug" ]]; then
    if ! slug="$(slug_from_cwd)"; then
      if "$show_json"; then
        err "Not inside a workspace — pass a SLUG, or --all for every workspace."
        exit 1
      fi
      _status_overview; return $?
    fi
  fi

  [[ -d "$WORKSPACES_ROOT/$slug" ]] || { err "Workspace not found: $slug"; exit 1; }

  local $_STATUS_VARS
  _status_collect "$slug"
  if [[ -n "$status_error" ]]; then
    err "Incomplete workspace '$slug': $status_error."
    exit 1
  fi

  if "$show_json"; then
    _status_record | _status_json_from_records object; return 0
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
  local entry key port running
  for entry in ${servers[@]+"${servers[@]}"}; do
    key="${entry%%:*}"; entry="${entry#*:}"
    port="${entry%%:*}"; running="${entry#*:}"
    _server_line "$key" ":$port" "$running"
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

# The variables _status_collect fills. The single-workspace report declares
# them local (`local $_STATUS_VARS`) so they don't outlive it; bash's dynamic
# scope hands them to the collector and to _status_record. (The fleet collects
# each workspace in its own subshell, which can't leak anything anyway.)
_STATUS_VARS="session_dir wt_fe wt_be status_error fe_branch be_branch sub host served
  fe_git be_git vendor_ok cognitor_ok test_db_state node_modules_ok task_url
  fe_mr be_mr horizon_state servers"

# Gather everything the report shows about SLUG into the caller's
# $_STATUS_VARS. An incomplete workspace sets status_error and stops early.
_status_collect() {
  local slug="$1"
  session_dir="$WORKSPACES_ROOT/$slug"
  wt_fe="$session_dir/$FRONTEND_DIR_NAME"
  wt_be="$session_dir/$BACKEND_DIR_NAME"
  status_error=""
  servers=()
  fe_branch=""; be_branch=""; fe_git=""; be_git=""; fe_mr=""; be_mr=""
  served=false; sub=""; host=""; task_url=""
  vendor_ok=false; cognitor_ok=false; node_modules_ok=false
  test_db_state=""; horizon_state="stopped"
  if [[ ! -d "$wt_fe" || ! -d "$wt_be" ]]; then
    status_error="missing frontend or backend worktree"
    return 0
  fi

  # ── branches ───────────────────────────────────────────────────────────
  fe_branch="$(worktree_branch "$wt_fe")"
  be_branch="$(worktree_branch "$wt_be")"
  fe_branch="${fe_branch:-(detached)}"
  be_branch="${be_branch:-(detached)}"

  # ── serving ────────────────────────────────────────────────────────────
  sub="$(resolve_subdomain "$slug")" || sub="$slug"
  host="${sub}.${BASE_DOMAIN}"
  [[ -f "$VALET_NGINX_DIR/$host" ]] && served=true

  # ── port base ──────────────────────────────────────────────────────────
  PORT_BASE="$(compute_port_base "$sub")"

  # ── dev servers ────────────────────────────────────────────────────────
  # What this workspace serves, not every app that happens to have a
  # directory — panels/outlook aren't served by default and were just noise:
  # the ports its nginx block proxies, or — not served yet — the default apps,
  # so "stopped" still means something. Each entry "key:port:running", worked
  # out once here for the human view and the JSON alike. A "key:…" list rather
  # than declare -A: macOS ships bash 3.2, which has no associative arrays.
  local conf="$VALET_NGINX_DIR/$host" key port is_served running d
  while IFS= read -r key; do
    if [[ ! -d "$wt_fe/$(app_dir "$key")" ]]; then
      continue
    fi
    port="$(port_for "$key")"
    is_served=false
    if "$served"; then
      if grep -qE "127\.0\.0\.1:${port}([^0-9]|$)" "$conf" 2>/dev/null; then
        is_served=true
      fi
    else
      for d in ${DEFAULT_APPS[@]+"${DEFAULT_APPS[@]}"}; do
        if [[ "$key" == "$d" ]]; then
          is_served=true
        fi
      done
    fi
    if "$is_served"; then
      running=false
      if _status_port_listening "$port"; then
        running=true
      fi
      servers+=("${key}:${port}:${running}")
    fi
  done < <(all_app_keys)

  # ── git status ─────────────────────────────────────────────────────────
  fe_git="$(_git_summary "$wt_fe")"
  be_git="$(_git_summary "$wt_be")"

  # ── backend deps ───────────────────────────────────────────────────────
  [[ -d "$wt_be/vendor" ]] && vendor_ok=true
  local cog_env="$wt_be/.env"
  [[ -f "$cog_env" ]] || cog_env="$BACKEND_REPO/.env"
  local cog_rel; cog_rel="$(_cognitor_rel_path "$cog_env")"
  [[ -n "$cog_rel" && -f "$wt_be/storage/$cog_rel" ]] && cognitor_ok=true
  test_db_state="$(_test_db_state "$slug")"

  # ── frontend deps ──────────────────────────────────────────────────────
  [[ -d "$wt_fe/node_modules" ]] && node_modules_ok=true

  # ── links ───────────────────────────────────────────────────────────────
  # The task link is local string work; MR links are a glab call each, so they
  # only run under --mr. No separate `glab auth status` preflight (another round
  # trip) — _mr_url just yields nothing when glab is absent or unauthenticated.
  task_url="$(_task_url "$slug")"
  if "$MR_LOOKUP"; then
    if "$_STATUS_MRS_LOADED"; then
      # Fleet: answered from the per-repo listing loaded once up front.
      fe_mr="$(_status_mr_from_index "$_STATUS_FE_MRS" "$fe_branch")"
      be_mr="$(_status_mr_from_index "$_STATUS_BE_MRS" "$be_branch")"
    elif command -v glab >/dev/null 2>&1; then
      fe_mr="$(_mr_url "$wt_fe" "$fe_branch")"
      be_mr="$(_mr_url "$wt_be" "$be_branch")"
    fi
  fi

  # ── horizon (the backend queue worker) ──────────────────────────────────
  if _horizon_running "$wt_be"; then
    horizon_state="running"
  fi
  return 0
}

# Listening TCP ports, one per line. One lsof for every port, cached for the
# rest of the run so a fleet report pays for it once. `|| true`: lsof exits
# non-zero when nothing listens, which set -e would otherwise treat as fatal.
_STATUS_LISTENING=""
_STATUS_LISTENING_LOADED=false
_status_load_listening() {
  if "$_STATUS_LISTENING_LOADED"; then
    return 0
  fi
  _STATUS_LISTENING_LOADED=true
  _STATUS_LISTENING="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {n=$9; sub(/.*:/,"",n); print n}' | sort -u || true)"
}

# True if something listens on PORT. An in-shell match against the cached
# list: no fork per app and workspace.
_status_port_listening() {
  _status_load_listening
  [[ $'\n'"$_STATUS_LISTENING"$'\n' == *$'\n'"$1"$'\n'* ]]
}

# Working directories of every running `php artisan horizon`, one per line.
# One lsof for all of them, cached like the ports: lsof costs ~0.1 s a call,
# and a machine with a dozen workspaces runs a dozen workers.
_STATUS_HORIZON_CWDS=""
_STATUS_HORIZON_LOADED=false
_status_load_horizon() {
  if "$_STATUS_HORIZON_LOADED"; then
    return 0
  fi
  _STATUS_HORIZON_LOADED=true
  local pids
  pids="$(pgrep -f 'artisan horizon' 2>/dev/null | paste -sd, - || true)"
  if [[ -z "$pids" ]]; then
    return 0
  fi
  _STATUS_HORIZON_CWDS="$(lsof -a -p "$pids" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)"
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

# web_url of the open MR for BRANCH in WORKTREE, or nothing. One network call,
# made only for a single-workspace report under --mr; the fleet uses the
# per-repo listing below instead of two calls per workspace.
_mr_url() {
  local worktree="$1" branch="$2" json
  [[ -n "$branch" ]] || return 0
  json="$( cd "$worktree" 2>/dev/null && glab mr list --source-branch "$branch" --output json 2>/dev/null )" || return 0
  [[ -n "$json" && "$json" != "[]" ]] || return 0
  printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["web_url"])' 2>/dev/null || true
}

# Every open MR of REPO as "source_branch<TAB>web_url" lines: one glab call
# per page of 100, so `--all --mr` costs a call or two per repo instead of two
# per workspace (a burst of a dozen at a time against GitLab's rate limit).
# Returns 1 when glab fails, so the caller can say so instead of reporting
# "no MR" for workspaces that have one.
_status_mr_index() {
  local repo="$1" page=1 json lines count
  while (( page <= 20 )); do
    json="$(cd "$repo" && glab mr list --output json --per-page 100 --page "$page" 2>/dev/null)" || return 1
    lines="$(printf '%s' "$json" | python3 -c '
import json, sys
for mr in json.load(sys.stdin):
    print("%s\t%s" % (mr.get("source_branch") or "", mr.get("web_url") or ""))
')" || return 1
    if [[ -z "$lines" ]]; then
      break
    fi
    printf '%s\n' "$lines"
    count="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
    if (( count < 100 )); then
      break
    fi
    page=$(( page + 1 ))
  done
  return 0
}

# Load both repos' MR listings once, before the fleet forks its collectors.
# A failed listing is reported on stderr and leaves that side's mr fields null.
_STATUS_MRS_LOADED=false
_STATUS_FE_MRS=""
_STATUS_BE_MRS=""
_status_load_mrs() {
  _STATUS_MRS_LOADED=true
  if ! command -v glab >/dev/null 2>&1; then
    warn "glab not found — MR links left out."
    return 0
  fi
  if ! _STATUS_FE_MRS="$(_status_mr_index "$FRONTEND_REPO")"; then
    _STATUS_FE_MRS=""
    warn "MR lookup failed for $FRONTEND_DIR_NAME (glab) — its mr fields are null."
  fi
  if ! _STATUS_BE_MRS="$(_status_mr_index "$BACKEND_REPO")"; then
    _STATUS_BE_MRS=""
    warn "MR lookup failed for $BACKEND_DIR_NAME (glab) — its mr fields are null."
  fi
}

# web_url for BRANCH from an index of "source_branch<TAB>web_url" lines.
_status_mr_from_index() {
  local index="$1" branch="$2" b url
  while IFS=$'\t' read -r b url; do
    if [[ -n "$b" && "$b" == "$branch" ]]; then
      printf '%s' "$url"
      return 0
    fi
  done <<< "$index"
  return 0
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
  local wt_be="$1" wd
  _status_load_horizon
  while IFS= read -r wd; do
    case "$wd" in "$wt_be"|"$wt_be"/*) return 0 ;; esac
  done <<< "$_STATUS_HORIZON_CWDS"
  return 1
}

# Records for _status_json_from_records: one "key<TAB>value" line per field,
# a blank line after each record. Named, not positional, so a field added or
# moved can't silently shift every later one; a field the consumer expects but
# doesn't get fails loudly there. Newlines are dropped from values (they would
# end the line); a tab inside a value is kept (only the first one splits).
_status_field() {
  printf '%s\t%s\n' "$1" "${2//$'\n'/}"
}

# One workspace's collected state as a record. Reads the caller's
# $_STATUS_VARS and $slug (bash dynamic scope).
_status_record() {
  local entry joined=""
  for entry in ${servers[@]+"${servers[@]}"}; do
    joined="${joined}${entry},"
  done
  _status_field slug "$slug"
  _status_field path "$session_dir"
  _status_field error "$status_error"
  _status_field served "$served"
  _status_field host "$host"
  _status_field task_url "$task_url"
  _status_field fe_branch "$fe_branch"
  _status_field fe_git "$fe_git"
  _status_field node_modules "$node_modules_ok"
  _status_field fe_mr "$fe_mr"
  _status_field servers "$joined"
  _status_field be_branch "$be_branch"
  _status_field be_git "$be_git"
  _status_field vendor "$vendor_ok"
  _status_field cognitor_key "$cognitor_ok"
  _status_field test_db "$test_db_state"
  _status_field horizon "$horizon_state"
  _status_field be_mr "$be_mr"
  printf '\n'
}

# A record for a workspace whose collection failed: slug, path and the error.
_status_error_record() {
  _status_field slug "$1"
  _status_field path "$2"
  _status_field error "$3"
  printf '\n'
}

# Machine-readable report: records from _status_record on stdin, JSON on
# stdout. "object" prints the first record (`ws status <slug> --json`), "array"
# prints all of them (`--all --json`). The deps live here rather than
# cluttering the human view, which is almost always all-green. One python3 for
# the whole fleet.
_status_json_from_records() {
  WSJ_SHAPE="$1" WSJ_ADMIN="$ADMIN_PATH" python3 -c '
import json, os, sys
def b(v): return v == "true"
def none(v): return v or None
admin = os.environ["WSJ_ADMIN"]
records, cur = [], {}
# split("\n"), not splitlines(): the latter also breaks on \v, \f, U+2028
# and friends, which a branch or directory name may contain.
for line in sys.stdin.read().split("\n"):
    if line == "":
        if cur:
            records.append(cur)
            cur = {}
        continue
    key, _, value = line.partition("\t")
    cur[key] = value
if cur:
    records.append(cur)
out = []
for r in records:
    if r.get("error"):
        out.append({"slug": r.get("slug", ""), "path": r.get("path", ""), "error": r["error"]})
        continue
    servers = []
    for item in r["servers"].split(","):
        if not item:
            continue
        name, port, running = item.rsplit(":", 2)
        try:
            port = int(port)
        except ValueError:
            port = None
        servers.append({"app": name, "port": port, "running": b(running)})
    served = b(r["served"])
    url = None
    if served:
        url = "https://%s%s" % (r["host"], admin)
    out.append({
        "slug": r["slug"],
        "path": r["path"],
        "served": served,
        "url": url,
        "task_url": none(r["task_url"]),
        "frontend": {
            "branch": r["fe_branch"],
            "git": r["fe_git"],
            "node_modules": b(r["node_modules"]),
            "servers": servers,
            "mr": none(r["fe_mr"]),
        },
        "backend": {
            "branch": r["be_branch"],
            "git": r["be_git"],
            "vendor": b(r["vendor"]),
            "cognitor_key": b(r["cognitor_key"]),
            "test_db": r["test_db"],
            "horizon": r["horizon"],
            "mr": none(r["be_mr"]),
        },
    })
if os.environ["WSJ_SHAPE"] == "object":
    if out:
        print(json.dumps(out[0], indent=2))
else:
    print(json.dumps(out, indent=2))
'
}

# Every workspace: the one-line-per-workspace table, or with --json the full
# report of each as one array. A workspace that can't be reported — incomplete,
# or its collector died — appears as {"slug", "path", "error"}, never dropped.
_STATUS_JOBS=6
_STATUS_TMP=""
_status_fleet() {
  local as_json="$1"
  if ! "$as_json"; then
    _status_overview
    return $?
  fi
  # A workspace costs ~0.3 s (two git status runs, a mysql query, a dozen
  # small spawns), so up to _STATUS_JOBS are collected at once, each into its
  # own numbered file, read back in workspace order. The shared lookups load
  # first, so the background jobs inherit them instead of each repeating them.
  _status_load_listening
  _status_load_horizon
  if "$MR_LOOKUP"; then
    _status_load_mrs
  fi
  _STATUS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ws-status.XXXXXX")"
  # Removed on every way out: success, a failure under set -e, or Ctrl-C.
  trap _status_cleanup_tmp EXIT
  trap '_status_cleanup_tmp; exit 130' INT TERM

  local slug index=0 file
  local -a pids=() pid_slugs=() pid_files=()
  while IFS= read -r slug; do
    if [[ -z "$slug" ]]; then
      continue
    fi
    index=$(( index + 1 ))
    file="$_STATUS_TMP/$(printf '%04d' "$index")"
    (
      _status_collect "$slug"
      _status_record
    ) > "$file" &
    pids+=("$!"); pid_slugs+=("$slug"); pid_files+=("$file")
    # A sliding window, oldest first: a new job starts as soon as the oldest
    # finishes, not when a whole batch has. (bash 3.2 has no `wait -n`.)
    if (( ${#pids[@]} >= _STATUS_JOBS )); then
      _status_reap_oldest
    fi
  done < <(workspace_slugs)
  while (( ${#pids[@]} > 0 )); do
    _status_reap_oldest
  done

  for file in "$_STATUS_TMP"/*; do
    if [[ -f "$file" ]]; then
      cat "$file"
    fi
  done | _status_json_from_records array
  _status_cleanup_tmp
  trap - EXIT INT TERM
}

# Wait for the oldest running collector (the caller's pids/pid_slugs/pid_files,
# via dynamic scope). One that died — set -e, an unbound variable — gets an
# error record in place of whatever half it wrote, so the workspace still shows.
_status_reap_oldest() {
  local rc=0
  # `|| rc=$?`, not `if ! wait …; then rc=$?`: inside that branch $? is the
  # status of the negation (0), not the job's.
  wait "${pids[0]}" || rc=$?
  if (( rc != 0 )); then
    _status_error_record "${pid_slugs[0]}" "$WORKSPACES_ROOT/${pid_slugs[0]}" \
      "status collection failed (exit $rc)" > "${pid_files[0]}"
  fi
  pids=("${pids[@]:1}")
  pid_slugs=("${pid_slugs[@]:1}")
  pid_files=("${pid_files[@]:1}")
}

_status_cleanup_tmp() {
  if [[ -n "$_STATUS_TMP" ]]; then
    rm -rf "$_STATUS_TMP"
    _STATUS_TMP=""
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
# how many of the default apps are listening (one shared lsof for the ports).
# Everything else belongs in the single-workspace view.
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
  _status_load_listening
  local -a rows=()
  local wt_fe wt_be sub host branch git_state served up total key port
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
      for key in ${DEFAULT_APPS[@]+"${DEFAULT_APPS[@]}"}; do
        total=$(( total + 1 ))
        port="$(port_for "$key")"
        if _status_port_listening "$port"; then
          up=$(( up + 1 ))
        fi
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
