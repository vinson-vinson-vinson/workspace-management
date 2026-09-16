# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_ui.sh — `workspaces ui`: the local dashboard (ui/server.mjs).
#
# A zero-dependency Node server (>= 18) that renders one card per workspace and
# drives the same commands you'd type: open, serve, remove, create, plus
# start/stop of the per-app dev servers. It shells out to THIS checkout's
# dispatcher and reads THIS checkout's config.sh, so the UI can never drift onto
# another install.
#
# Default run is detached: the server outlives the shell that started it, and a
# second `ws ui` just reopens the browser on the already-running instance.
# -----------------------------------------------------------------------------

WS_UI_DEFAULT_PORT=7777

cmd_ui_usage() {
  cat <<'USAGE'
Usage:
  ws ui [options]

Start the workspaces dashboard and open it in your browser. One card per
workspace (MAIN first): branches and git state, the serve URL, and every app's
dev server with its assigned port — each with buttons for open / serve /
start / stop / logs / create / remove.

The server runs detached on http://localhost:7777 and is reused by later
`ws ui` calls (nothing is started twice). Logs: ~/.ws-ui/server.log.

Options:
  -p, --port <n>   Port to listen on (default: 7777, or $WS_UI_PORT).
      --no-open    Start (or report) the server without opening the browser.
      --foreground Run in this terminal instead of detaching (Ctrl-C stops it).
      --stop       Stop the running dashboard server.
      --dry-run    Show what would happen without starting anything.
  -h, --help       Show this help.
USAGE
}

# PID(s) of whatever listens on the dashboard port.
_ws_ui_pids() { lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true; }

cmd_ui() {
  local port="${WS_UI_PORT:-$WS_UI_DEFAULT_PORT}"
  local open_browser=true foreground=false stop=false
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--port)    port="${2:-}"; [[ -n "$port" ]] || { err "--port needs a value"; exit 1; }; shift 2 ;;
      --port=*)     port="${1#*=}"; shift ;;
      --no-open)    open_browser=false; shift ;;
      --foreground) foreground=true; shift ;;
      --stop)       stop=true; shift ;;
      --dry-run)    DRY_RUN=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_ui_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_ui_usage; exit 1 ;;
      *)  err "Unexpected argument: $1"; cmd_ui_usage; exit 1 ;;
    esac
  done

  [[ "$port" =~ ^[0-9]+$ ]] || { err "Invalid port: $port"; exit 1; }

  local url="http://localhost:$port"
  local server="$WSM_HOME/ui/server.mjs"
  local log_dir="$HOME/.ws-ui"
  local pids; pids="$(_ws_ui_pids "$port")"

  if "$stop"; then
    if [[ -z "$pids" ]]; then
      log "nothing is listening on port $port."
      return 0
    fi
    # shellcheck disable=SC2086  # intentional word splitting: one PID per line
    run_cmd kill $pids
    ok "stopped the dashboard on $url"
    return 0
  fi

  [[ -f "$server" ]] || { err "dashboard not found: $server"; exit 1; }
  require_command node

  # config.sh is sourced, not exported, by load_config — hand the server the
  # path this run resolved (empty = let it resolve its own sibling config).
  local cfg_path="${WSM_CONFIG:-}"
  [[ -z "$cfg_path" && -f "$WSM_HOME/config.sh" ]] && cfg_path="$WSM_HOME/config.sh"

  if [[ -n "$pids" ]]; then
    ok "already running → $url"
    if "$open_browser"; then run_cmd open "$url"; fi
    return 0
  fi

  if "$foreground"; then
    log "starting the dashboard on $url (Ctrl-C to stop)"
    if "$DRY_RUN"; then printf '[dry-run] node %s\n' "$server"; return 0; fi
    local -a argv=(node "$server")
    if "$open_browser"; then argv+=(--open); fi
    WS_UI_PORT="$port" WSM_HOME="$WSM_HOME" WSM_CONFIG="$cfg_path" WS_BIN="$WSM_HOME/workspaces" \
      exec "${argv[@]}"
  fi

  if "$DRY_RUN"; then
    printf '[dry-run] node %s (detached, port %s)\n' "$server" "$port"
    if "$open_browser"; then printf '[dry-run] open %s\n' "$url"; fi
    return 0
  fi

  mkdir -p "$log_dir"
  # Detach fully (nohup + &) so the dashboard survives this shell exiting.
  WS_UI_PORT="$port" WSM_HOME="$WSM_HOME" WSM_CONFIG="$cfg_path" WS_BIN="$WSM_HOME/workspaces" \
    nohup node "$server" >>"$log_dir/server.log" 2>&1 &
  disown 2>/dev/null || true

  # Wait (max ~3s) for the port before declaring success / opening the browser.
  local i
  for i in $(seq 1 15); do
    [[ -n "$(_ws_ui_pids "$port")" ]] && break
    sleep 0.2
  done

  if [[ -z "$(_ws_ui_pids "$port")" ]]; then
    err "the dashboard didn't come up on $url — see $log_dir/server.log"
    exit 1
  fi

  ok "dashboard → $url"
  vlog "logs: $log_dir/server.log"
  if "$open_browser"; then run_cmd open "$url"; fi
  return 0
}
