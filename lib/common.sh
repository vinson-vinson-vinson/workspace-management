# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/common.sh — shared helpers for the `workspaces` CLI.
#
# Sourced by the `workspaces` dispatcher (and thus by every subcommand). Not
# executable on its own. Relies on $WSM_HOME (the real dir of the dispatcher)
# being set before it is sourced.
# -----------------------------------------------------------------------------

WSM_VERSION="2.3.0"

# Sudoers drop-in installed by `ws trust` (NOPASSWD for the exact nginx
# commands `ws serve` runs). Shared: trust writes it, serve checks for it.
WSM_SUDOERS_FILE="/etc/sudoers.d/workspace-management"

# ------------------------------- colors -------------------------------------
# Only emit ANSI when stdout is a terminal; piped/redirected output stays clean.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
  TTY=true
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
  TTY=false
fi

# ---------------------------- brand gradient --------------------------------
# The wordmark fade (vaporwave: pink -> sky) from `ws help`. Shared here so the
# banner and `ws serve`'s summary box use one accent.
WSM_GRAD_R1=255; WSM_GRAD_G1=113; WSM_GRAD_B1=206     # pink
WSM_GRAD_R2=1;   WSM_GRAD_G2=205; WSM_GRAD_B2=254     # sky

# Per-char slicing of multibyte glyphs only works in a UTF-8 locale — under a
# byte-oriented one (LC_ALL=C) ${#} counts bytes and we'd cut a glyph in half.
# Probe with a single box-drawing char: 1 = char-wise, 3 = byte-wise.
_WS_UTF8_PROBE='─'
if [[ ${#_WS_UTF8_PROBE} -eq 1 ]]; then WS_UTF8=true; else WS_UTF8=false; fi

if "$TTY"; then
  WSM_GRAD_START=$'\033[1;38;2;255;113;206m'
  WSM_GRAD_END=$'\033[1;38;2;1;205;254m'
else
  WSM_GRAD_START=""; WSM_GRAD_END=""
fi

# Echo $1 with the brand fade interpolated per character across a ramp of $2
# columns (default: the text's own width). No indent, no trailing newline.
# Prints plain text when stdout isn't a TTY or the locale is byte-oriented.
ws_grad() {
  local text="$1"
  local ramp="${2:-${#text}}"
  local n=${#text} i t r g b
  if ! "$TTY" || ! "$WS_UTF8"; then printf '%s' "$text"; return; fi
  (( ramp < 2 )) && ramp=2
  for ((i = 0; i < n; i++)); do
    t=$i; (( t > ramp - 1 )) && t=$(( ramp - 1 ))
    r=$(( WSM_GRAD_R1 + (WSM_GRAD_R2 - WSM_GRAD_R1) * t / (ramp - 1) ))
    g=$(( WSM_GRAD_G1 + (WSM_GRAD_G2 - WSM_GRAD_G1) * t / (ramp - 1) ))
    b=$(( WSM_GRAD_B1 + (WSM_GRAD_B2 - WSM_GRAD_B1) * t / (ramp - 1) ))
    printf '\033[1;38;2;%d;%d;%dm%s' "$r" "$g" "$b" "${text:i:1}"
  done
  printf '%s' "$C_RESET"
}

# Echo char $1 repeated $2 times (bash-3.2 safe).
ws_rule() {
  local ch="$1" n="$2" i out=""
  for ((i = 0; i < n; i++)); do out+="$ch"; done
  printf '%s' "$out"
}

# ---------------------------- wordmark banner --------------------------------
# "WORKSPACES" in the Calvin S box-drawing font (3 rows, 3 cols per glyph).
# The tool goes by the command's own name; the repo keeps its longer one.
# Shown by `ws help` and above the `ws list` table.
_WSM_L1='╦ ╦╔═╗╦═╗╦╔═╔═╗╔═╗╔═╗╔═╗╔═╗╔═╗'
_WSM_L2='║║║║ ║╠╦╝╠╩╗╚═╗╠═╝╠═╣║  ╠═ ╚═╗'
_WSM_L3='╚╩╝╚═╝╩╚═╩ ╩╚═╝╩  ╩ ╩╚═╝╚═╝╚═╝'

_WSM_RAMP=30

# Print the WORKSPACES wordmark. Optional $1: left indent (default 2).
# Optional $2: total width — when wider than the wordmark, a racing stripe of
# '═' flanks the middle row on both sides: it starts/ends halfway between the
# outer edge and the mark and runs up to the mark, and the pink->sky fade
# spans the WHOLE width (wordmark included) so stripe and mark read as one.
wsm_banner() {
  local indent="${1:-2}" width="${2:-$_WSM_RAMP}" l pad
  pad="$(ws_rule ' ' "$indent")"
  # Flank widths (2-space gap on both sides of the mark); the right one takes
  # the integer-division remainder so the row always fills exactly $width.
  local flank=$(( (width - _WSM_RAMP) / 2 - 2 ))
  if (( flank < 4 )); then
    printf '\n'
    for l in "$_WSM_L1" "$_WSM_L2" "$_WSM_L3"; do
      printf '%s%s\n' "$pad" "$(ws_grad "$l" "$_WSM_RAMP")"
    done
    return 0
  fi
  local flank_r=$((width - _WSM_RAMP - 4 - flank))
  # Inner half of each flank: from the halfway point up to the mark.
  local stripe_l=$((flank / 2)) stripe_r=$((flank_r / 2))
  local row1 row2 row3
  row1="$(ws_rule ' ' "$flank")  ${_WSM_L1}"
  row2="$(ws_rule ' ' $((flank - stripe_l)))$(ws_rule '═' "$stripe_l")  ${_WSM_L2}  $(ws_rule '═' "$stripe_r")"
  row3="$(ws_rule ' ' "$flank")  ${_WSM_L3}"
  printf '\n'
  for l in "$row1" "$row2" "$row3"; do
    printf '%s%s\n' "$pad" "$(ws_grad "$l" "$width")"
  done
}

# ------------------------------- logging ------------------------------------
# The dispatcher sets LOG_PREFIX to the running subcommand, so messages read
# like "[serve] …" / "[create] …".
LOG_PREFIX="ws"
log()  { printf '[%s] %s\n' "$LOG_PREFIX" "$*"; }
# A completed milestone: green check, no [prefix] noise.
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
# Step detail: shown only under -v. A normal run prints just the milestone
# checks. (`return 0` keeps a false VERBOSE from surfacing as a non-zero status
# under `set -e`.)
vlog() { "$VERBOSE" && log "$@"; return 0; }
err()  { printf '[%s] ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$LOG_PREFIX" "$*" >&2; }

# ------------------------------- spinner ------------------------------------
# Shows "<spinner> doing the thing" while a step runs, then replaces that line
# in place with the "✓ thing done" check. Usage:
#
#     spin "removing worktrees"
#     ...work...
#     spin_ok "worktrees removed"        # clears the spinner, prints the check
#
# Deliberately inert unless stdout is a TTY: piped output would otherwise fill
# with \r frames. Also inert under -v, where step narration prints freely and
# would shred a single redrawn line. In both cases spin_ok still prints its ✓,
# so callers need no branching.
if "$WS_UTF8"; then
  _WS_SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  _WS_SPIN_FRAMES=('|' '/' '-' '\')
fi
_WS_SPIN_PID=""

_ws_spin_active() { "$TTY" && ! "$VERBOSE" && ! "$DRY_RUN"; }

spin() {
  _WS_SPIN_MSG="$1"
  _ws_spin_active || return 0
  spin_stop                      # never leave two spinners racing one line
  printf '\033[?25l'             # hide cursor; restored by spin_stop
  (
    local i=0 n=${#_WS_SPIN_FRAMES[@]}
    while :; do
      printf '\r\033[2K  %s%s%s %s' \
        "$C_CYAN" "${_WS_SPIN_FRAMES[i % n]}" "$C_RESET" "$_WS_SPIN_MSG"
      i=$((i + 1))
      sleep 0.08
    done
  ) &
  _WS_SPIN_PID=$!
}

# Kill the spinner and wipe its line. Safe to call when none is running, so
# error paths can call it unconditionally before printing.
spin_stop() {
  [[ -n "$_WS_SPIN_PID" ]] || return 0
  # `|| true` on both: if the spinner already exited, kill/wait return non-zero
  # and `set -e` would abort the caller mid-step — with the cursor still hidden.
  kill "$_WS_SPIN_PID" 2>/dev/null || true
  wait "$_WS_SPIN_PID" 2>/dev/null || true
  _WS_SPIN_PID=""
  printf '\r\033[2K\033[?25h'    # clear line, show cursor
  return 0
}

# Stop the spinner and replace its line with the ✓ check.
spin_ok() { spin_stop; ok "${1:-$_WS_SPIN_MSG}"; }

# A stray spinner would leave the cursor hidden and a background loop running.
# INT/TERM only — an EXIT trap here would be clobbered by cmd_create's own.
trap 'spin_stop; exit 130' INT
trap 'spin_stop; exit 143' TERM

# Run a command with its output hidden, so it can't shred the spinner line.
# Output is shown under -v, or on failure (where it's the error message and must
# never be swallowed). Mirrors run_cmd's dry-run behaviour.
run_quiet() {
  if "$DRY_RUN"; then printf '[dry-run] %s\n' "$*"; return 0; fi
  if "$VERBOSE"; then "$@"; return $?; fi
  local out status=0
  out="$("$@" 2>&1)" || status=$?
  if [[ $status -ne 0 ]]; then
    spin_stop
    printf '%s\n' "$out" >&2
  fi
  return $status
}

# --------------------------- shared flag defaults ---------------------------
# Each subcommand parses whatever subset it supports; these defaults keep the
# helpers below safe under `set -u` before parsing runs.
DRY_RUN=false
VERBOSE=false

run_cmd() {
  if "$DRY_RUN"; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }
}

require_repo() {
  [[ -d "$1/.git" ]] || { err "Not a git repo: $1"; exit 1; }
}

# ---------------------------- configuration ---------------------------------
# Resolution order:
#   1. $WSM_CONFIG                                     (explicit override)
#   2. config.sh next to the `workspaces` command      (git clone / install.sh)
#   3. $XDG_CONFIG_HOME/workspace-management/config.sh  (Homebrew / packaged)
# Also derives TASK_ID_PREFIX_LC for case-insensitive slug matching.
load_config() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/workspace-management/config.sh"
  local cfg
  if [[ -n "${WSM_CONFIG:-}" ]]; then
    cfg="$WSM_CONFIG"
  elif [[ -f "$WSM_HOME/config.sh" ]]; then
    cfg="$WSM_HOME/config.sh"
  else
    cfg="$xdg"
  fi
  if [[ ! -f "$cfg" ]]; then
    err "config file not found: $cfg"
    printf 'Copy config.example.sh to config.sh next to the `workspaces` command, or to\n' >&2
    printf '  %s\n' "$xdg" >&2
    printf 'or point WSM_CONFIG at your config file.\n' >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$cfg"
  TASK_ID_PREFIX_LC="$(printf '%s' "$TASK_ID_PREFIX" | tr '[:upper:]' '[:lower:]')"
  # Optional settings — defaulted here so configs predating them keep working
  # under `set -u`.
  NO_OPEN_AFTER_CREATE="${NO_OPEN_AFTER_CREATE:-false}"
  USE_REMOTE_MAIN="${USE_REMOTE_MAIN:-false}"
  REQUIRE_CONFIRM_REMOVE="${REQUIRE_CONFIRM_REMOVE:-true}"
  MAIN_WORKSPACE_FILE="${MAIN_WORKSPACE_FILE:-}"
  # IDE per repo role (see config.example.sh); defaulted and validated here so
  # configs predating the settings keep working and typos fail loudly.
  FRONTEND_IDE="$(printf '%s' "${FRONTEND_IDE:-vscode}" | tr '[:upper:]' '[:lower:]')"
  BACKEND_IDE="$(printf '%s' "${BACKEND_IDE:-vscode}" | tr '[:upper:]' '[:lower:]')"
  _validate_ide FRONTEND_IDE "$FRONTEND_IDE"
  _validate_ide BACKEND_IDE "$BACKEND_IDE"
  # Array default, bash-3.2/set -u safe: keeps an unset EXTRA_WORKSPACE_FOLDERS
  # from blowing up expansion in configs predating the setting.
  EXTRA_WORKSPACE_FOLDERS=(${EXTRA_WORKSPACE_FOLDERS[@]+"${EXTRA_WORKSPACE_FOLDERS[@]}"})
  # Per-workspace test database (see cmd_test.sh); defaults keep configs
  # predating the feature working, with the feature ON — creation is
  # warn-and-continue, so machines without MySQL lose nothing.
  TEST_DB_ENABLED="${TEST_DB_ENABLED:-true}"
  TEST_DB_PREFIX="${TEST_DB_PREFIX:-anny_bookings_test}"
  TEST_DB_HOST="${TEST_DB_HOST:-127.0.0.1}"
  TEST_DB_USER="${TEST_DB_USER:-root}"
  TEST_DB_PASSWORD="${TEST_DB_PASSWORD:-}"
  # Terminal opened for post-create commands (e.g. yarn serve-*, an agent).
  TERMINAL_APP="${TERMINAL_APP:-terminal}"
  # Commands auto-started in terminal tabs after ws create. $WT_FRONTEND and
  # $WT_BACKEND are substituted at runtime. Same +"" guard as above.
  POST_CREATE_TERMINALS=(${POST_CREATE_TERMINALS[@]+"${POST_CREATE_TERMINALS[@]}"})
}

# --------------------------- post-create terminals --------------------------
# Terminal.app: one `do script` per command, each opening its own tab.
open_terminal_window() {
  local cmd="$1"
  if "$DRY_RUN"; then
    printf '[dry-run] open %s terminal: %s\n' "$TERMINAL_APP" "$cmd"
    return 0
  fi
  osascript -e "tell application \"Terminal\" to do script \"$cmd\""
}

# Warp: one launch configuration holding every command as its own tab, opened
# via warp://launch/<name>.
#
# Warp has no CLI, and its URL scheme cannot carry a command — `warp://action/
# new_tab?path=` only sets a directory. A launch configuration is the one
# documented way to start a tab that runs something. It is also nicer than the
# alternative: one window of N tabs rather than N scattered windows.
#
# Two constraints that fail SILENTLY if broken, hence the care here:
#   - warp://launch/ resolves a NAME inside ~/.warp/launch_configurations, not
#     a path, so the file has to be written there first.
#   - cwd must be absolute; a tilde or relative path makes Warp skip the config
#     without any error.
open_warp_launch_config() {
  local name="$1" cwd="$2"; shift 2
  local dir="$HOME/.warp/launch_configurations"
  local file="$dir/${name}.yaml"

  if "$DRY_RUN"; then
    printf '[dry-run] write %s (%d tab(s)) ; open warp://launch/%s\n' "$file" "$#" "$name"
    local c
    for c in "$@"; do printf '[dry-run]   tab: %s\n' "$c"; done
    return 0
  fi

  mkdir -p "$dir"
  # Emitted by python3 (already a dependency) because these commands contain
  # &&, $ and quotes — hand-rolled YAML quoting is how you get a config Warp
  # silently refuses to load. JSON is valid YAML, so json.dump is safe here.
  python3 -c '
import json, sys
name, cwd = sys.argv[1], sys.argv[2]
tabs = [{"title": c.split("&&")[-1].strip()[:24] or "tab",
         "layout": {"cwd": cwd, "commands": [{"exec": c}]}}
        for c in sys.argv[3:]]
print(json.dumps({"name": name, "windows": [{"tabs": tabs}]}, indent=2))
' "$name" "$cwd" "$@" > "$file" || { warn "Could not write the Warp launch config."; return 1; }

  vlog "Wrote Warp launch config: $file"
  open "warp://launch/${name}"
}

# Open terminal tabs for every command in POST_CREATE_TERMINALS. $1 and $2 are
# the frontend and backend worktree paths (substituted for $WT_FRONTEND /
# $WT_BACKEND in each command).
auto_open_terminals() {
  local wt_fe="$1" wt_be="$2"
  [[ ${#POST_CREATE_TERMINALS[@]} -gt 0 ]] || return 0

  local cmd
  local -a cmds=()
  for cmd in "${POST_CREATE_TERMINALS[@]}"; do
    cmd="${cmd//\$WT_FRONTEND/$wt_fe}"
    cmd="${cmd//\$WT_BACKEND/$wt_be}"
    vlog "Terminal command: $cmd"
    cmds+=("$cmd")
  done

  case "$TERMINAL_APP" in
    warp)
      # Named after the workspace so re-creating it overwrites its own config
      # instead of littering ~/.warp/launch_configurations.
      local session_dir; session_dir="$(dirname "$wt_fe")"
      open_warp_launch_config "ws-$(basename "$session_dir")" "$session_dir" "${cmds[@]}"
      ;;
    *)
      for cmd in "${cmds[@]}"; do open_terminal_window "$cmd"; done
      ;;
  esac
}

# Whether `ws create` should open POST_CREATE_TERMINALS at all. An all-VS-Code
# workspace already starts the same commands from its .code-workspace tasks
# block — running both would start every dev server twice and collide on ports.
auto_open_terminals_if_needed() {
  local wt_fe="$1" wt_be="$2"
  [[ "$FRONTEND_IDE" == "vscode" && "$BACKEND_IDE" == "vscode" ]] && return 0
  auto_open_terminals "$wt_fe" "$wt_be"
}

# ------------------------------- IDE launchers -------------------------------
# Workspaces open in the IDE(s) named by FRONTEND_IDE / BACKEND_IDE in the
# config (vscode | phpstorm | webstorm | zed; default vscode). The same value
# on both sides opens the workspace combined in ONE window; different values
# open each worktree separately in its own IDE. The launcher/label/open
# mechanics live here so cmd_open and cmd_create share one implementation.

# The CLI launcher an IDE is driven through.
ide_command() {
  case "$1" in
    vscode) printf 'code' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# Human-readable IDE name for milestone messages.
ide_label() {
  case "$1" in
    vscode)   printf 'VS Code' ;;
    phpstorm) printf 'PhpStorm' ;;
    webstorm) printf 'WebStorm' ;;
    zed)      printf 'Zed' ;;
    *)        printf '%s' "$1" ;;
  esac
}

# Reject anything that isn't a supported IDE. $1 is the config variable's NAME
# (for the error message), $2 its value.
_validate_ide() {
  case "$2" in
    vscode|phpstorm|webstorm|zed) return 0 ;;
    *)
      err "Invalid $1 in config: '$2' (allowed: vscode, phpstorm, webstorm, zed)"
      exit 1 ;;
  esac
}

# Make sure the launcher for IDE $1 is on PATH, with an install hint per IDE.
require_ide() {
  local ide="$1" cmd
  cmd="$(ide_command "$ide")"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  err "Required command not found: $cmd ($(ide_label "$ide"))"
  case "$ide" in
    vscode)
      printf "Install it from VS Code: Cmd+Shift+P -> \"Shell Command: Install 'code' command in PATH\".\n" >&2 ;;
    phpstorm|webstorm)
      printf 'Enable the launcher in JetBrains Toolbox (Settings -> Generate shell scripts)\n' >&2
      printf 'or in the IDE: Tools -> Create Command-line Launcher.\n' >&2 ;;
    zed)
      printf 'Install it from Zed: Zed menu -> Install CLI.\n' >&2 ;;
  esac
  exit 1
}

# Every launcher the current IDE config needs (one combined, two when split).
require_configured_ides() {
  require_ide "$FRONTEND_IDE"
  [[ "$FRONTEND_IDE" == "$BACKEND_IDE" ]] || require_ide "$BACKEND_IDE"
}

# Open ONE directory in IDE $1, in a new window where the CLI supports it.
open_dir_in_ide() {
  local ide="$1" dir="$2"
  case "$ide" in
    vscode) run_cmd code -n "$dir" ;;
    zed)    run_cmd zed -n "$dir" ;;
    *)      run_cmd "$(ide_command "$ide")" "$dir" ;;
  esac
}

# Open a workspace in the configured IDE(s):
#
#   open_workspace_editors FRONTEND_PATH BACKEND_PATH WORKSPACE_FILE COMBINED_DIR LABEL
#
# Identical FRONTEND_IDE/BACKEND_IDE -> ONE combined window: vscode opens
# WORKSPACE_FILE (falling back to both folders in one window when it's empty or
# missing), zed opens both folders as one multi-folder workspace, and
# phpstorm/webstorm — which have no multi-root projects — open COMBINED_DIR
# (the session dir) as a single project, or both dirs as two project windows
# when COMBINED_DIR is empty (MAIN has no session dir). Different IDEs -> each
# worktree opens separately in its own IDE.
open_workspace_editors() {
  local fe_path="$1" be_path="$2" workspace_file="$3" combined_dir="$4" label="$5"
  if [[ "$FRONTEND_IDE" != "$BACKEND_IDE" ]]; then
    open_dir_in_ide "$FRONTEND_IDE" "$fe_path"
    ok "$(ide_label "$FRONTEND_IDE") opened ($label — $FRONTEND_DIR_NAME)"
    open_dir_in_ide "$BACKEND_IDE" "$be_path"
    ok "$(ide_label "$BACKEND_IDE") opened ($label — $BACKEND_DIR_NAME)"
    return 0
  fi
  case "$FRONTEND_IDE" in
    vscode)
      if [[ -n "$workspace_file" && -f "$workspace_file" ]]; then
        run_cmd code -n "$workspace_file"
      else
        [[ -n "$workspace_file" ]] \
          && warn "workspace file not found ($workspace_file) — opening the folders directly."
        run_cmd code -n "$fe_path" "$be_path"
      fi
      ok "VS Code opened ($label)"
      ;;
    zed)
      run_cmd zed -n "$fe_path" "$be_path"
      ok "Zed opened ($label)"
      ;;
    phpstorm|webstorm)
      if [[ -n "$combined_dir" ]]; then
        run_cmd "$(ide_command "$FRONTEND_IDE")" "$combined_dir"
        ok "$(ide_label "$FRONTEND_IDE") opened ($label — one project)"
      else
        open_dir_in_ide "$FRONTEND_IDE" "$fe_path"
        open_dir_in_ide "$FRONTEND_IDE" "$be_path"
        ok "$(ide_label "$FRONTEND_IDE") opened ($label — $FRONTEND_DIR_NAME + $BACKEND_DIR_NAME as separate projects)"
      fi
      ;;
  esac
}

# ------------------------- git / workspace helpers --------------------------
# The branch a worktree currently has checked out (empty if detached/unknown).
worktree_branch() {
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# True if BRANCH is one of the protected base ("main") branches we must never
# serve over or remove.
is_protected_branch() {
  local branch="$1"
  [[ -n "$branch" ]] || return 1
  case "$branch" in
    "$FRONTEND_BASE_BRANCH"|"$BACKEND_BASE_BRANCH"|main|master) return 0 ;;
    *) return 1 ;;
  esac
}

# Path to a workspace's VS Code .code-workspace file. It lives INSIDE the session
# dir (alongside the two worktrees) so the whole workspace is self-contained.
workspace_file_for() { printf '%s' "$WORKSPACES_ROOT/$1/$1.code-workspace"; }

# Pre-move location (project root). Kept so `list`/`remove` still handle
# workspaces created before the file moved into the session dir.
legacy_workspace_file_for() { printf '%s' "$ROOT_DIR/$1.code-workspace"; }

# All workspace slugs (immediate subdirectories of WORKSPACES_ROOT), one per
# line, in fixed glob order. `ws list` numbers this exact sequence and
# `ws open <N>` indexes into it — both MUST use this helper so the indices
# can never drift apart.
workspace_slugs() {
  local entry
  [[ -d "$WORKSPACES_ROOT" ]] || return 0
  for entry in "$WORKSPACES_ROOT"/*/; do
    [[ -d "$entry" ]] || continue
    printf '%s\n' "$(basename "$entry")"
  done
}

# Echo the workspace slug for the current directory (first path component under
# WORKSPACES_ROOT), or return 1 if the cwd isn't inside a workspace. No output on
# failure so callers can print their own error (avoids exit-in-subshell).
slug_from_cwd() {
  local cwd="$PWD"
  [[ "$cwd" == "$WORKSPACES_ROOT/"* ]] || return 1
  local rel="${cwd#"$WORKSPACES_ROOT/"}"
  local slug="${rel%%/*}"
  [[ -n "$slug" ]] || return 1
  printf '%s' "$slug"
}

# ---------------------- VS Code SCM ignore-list sync ------------------------
# Every worktree of a repo shares one .git, so VS Code's built-in Source Control
# lists ALL of them (plus the main clone) in every window. VS Code has no
# allow-list setting — only the `git.ignoredRepositories` deny-list — so each
# workspace must explicitly ignore the OTHER workspaces' repos. That list is
# pure derived state (a function of which worktrees currently exist), so we
# generate it here and never hand-maintain it. See `ws sync`.

# Overwrite settings["git.ignoredRepositories"] in a .code-workspace file with
# the given repo paths, preserving every other setting. python3 keeps the JSON
# valid; the tool is macOS-only, where git (via the Xcode CLT) brings python3.
update_workspace_ignores() {
  local file="$1"; shift
  python3 - "$file" "$@" <<'PY'
import json, sys
path, ignores = sys.argv[1], sys.argv[2:]
with open(path) as fh:
    data = json.load(fh)
data.setdefault("settings", {})["git.ignoredRepositories"] = ignores
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

# Recompute git.ignoredRepositories for every workspace so each VS Code window
# shows only the repos inside its own session dir (its frontend/backend
# worktrees) and hides the other workspaces' worktrees and the main clones.
# Idempotent; safe to run anytime. Called by create/remove and `ws sync`.
#
# Always its own spinner + check step. It shells out to python3 once per
# workspace, which is slow enough to look like a hang if it hides inside a
# neighbouring step's spinner.
sync_scm_ignores() {
  if "$DRY_RUN"; then
    printf '[dry-run] re-sync VS Code Source Control ignore-lists across all workspaces\n'
    return 0
  fi
  # Silent work (nothing on stdout) — spinner-shaped.
  spin "syncing Source Control repo lists"
  if ! command -v python3 >/dev/null 2>&1; then
    spin_stop
    warn "python3 not found — skipping SCM ignore-list sync (run 'ws sync' after installing it)."
    return 0
  fi

  # Every repo VS Code would otherwise surface: both repos' worktrees, incl. each
  # main clone (git lists it first). Absolute, real paths, one per line.
  local -a all_repos=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && all_repos+=("$line")
  done < <(
    { git -C "$FRONTEND_REPO" worktree list --porcelain 2>/dev/null
      git -C "$BACKEND_REPO"  worktree list --porcelain 2>/dev/null
    } | awk '/^worktree /{ print substr($0, 10) }'
  )
  [[ ${#all_repos[@]} -gt 0 ]] || { warn "No worktrees found; nothing to sync."; return 0; }

  local session slug wf repo synced=0
  for session in "$WORKSPACES_ROOT"/*/; do
    [[ -d "$session" ]] || continue
    session="${session%/}"
    slug="${session##*/}"
    # The workspace file lives in the session dir (current) or project root (legacy).
    wf="$(workspace_file_for "$slug")"
    [[ -f "$wf" ]] || wf="$(legacy_workspace_file_for "$slug")"
    [[ -f "$wf" ]] || continue

    # Ignore every repo NOT directly inside this session dir — i.e. keep this
    # workspace's own worktrees visible, hide the siblings and the main clones.
    local -a ignores=()
    for repo in "${all_repos[@]}"; do
      [[ "${repo%/*}" == "$session" ]] && continue
      ignores+=("$repo")
    done

    if update_workspace_ignores "$wf" ${ignores[@]+"${ignores[@]}"}; then
      vlog "SCM sync: $slug -> ${#ignores[@]} repo(s) hidden"
      synced=$((synced + 1))
    else
      warn "SCM sync: failed to update $wf (left unchanged)"
    fi
  done
  vlog "Synced VS Code Source Control ignore-lists for $synced workspace(s)."
  spin_ok "Source Control repo lists synced ($synced workspace(s))"
}

# Extract a workspace's accent color (titleBar.activeBackground) from its
# .code-workspace file. Echoes a hex like "#571f74", or nothing. Used by `list`
# (color swatch) and `serve` (tinted favicons).
_ws_color() {
  local file
  file="$(workspace_file_for "$1")"
  [[ -f "$file" ]] || file="$(legacy_workspace_file_for "$1")"
  [[ -f "$file" ]] || return 0
  grep -o '"titleBar\.activeBackground"[[:space:]]*:[[:space:]]*"#[0-9a-fA-F]\{6\}"' "$file" 2>/dev/null \
    | grep -o '#[0-9a-fA-F]\{6\}' | head -n1
}

# Derive a DNS-safe subdomain label from a slug: the task id for a task slug
# (CU-1234_x -> cu-1234), else the whole slug, lowercased with non-DNS chars
# collapsed to '-'. Returns 1 if nothing usable remains.
resolve_subdomain() {
  local slug="$1" sub
  sub="$(printf '%s' "${slug%%_*}" | tr '[:upper:]' '[:lower:]')"
  sub="$(printf '%s' "$sub" | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$sub" ]] || return 1
  printf '%s' "$sub"
}

# Make sure upcoming `sudo nginx` calls won't die on authentication: quiet
# when the `ws trust` rule is installed or credentials are still cached,
# otherwise a visible `sudo -v` prompt. NOTE: with the (command-scoped) trust
# rule, `sudo -v` would STILL prompt — it validates general credentials, not
# command rules — so it must be skipped, not attempted. Returns non-zero if
# the user can't/won't authenticate; callers add their own context.
ensure_sudo_for_nginx() {
  if [[ -f "$WSM_SUDOERS_FILE" ]]; then
    vlog "ws trust rule present — no sudo prompt needed."
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  log "Requesting sudo (needed to reload nginx)…"
  log "(Run 'ws trust' once to stop these prompts for good.)"
  sudo -v
}

# --------------------------- per-workspace test DB ---------------------------
# Every workspace gets its own MySQL test database so concurrent suite runs in
# different workspaces can't `migrate:fresh` over each other (phpunit.xml pins
# the SHARED anny_bookings_test, but declares DB_DATABASE without force="true",
# so an exported shell variable wins — that's what `ws test` does). Created by
# `ws create` / on demand by `ws test`, dropped by `ws remove`.

# Echo the test-DB name for a slug: TEST_DB_PREFIX + the same short label the
# subdomain uses (task id for task slugs), '-' mapped to '_', truncated to
# MySQL's 64-char identifier cap. Deliberately simple — if two very long slugs
# ever truncate to the same name, they're semantically related anyway.
resolve_test_db() {
  local slug="$1" label name
  label="$(resolve_subdomain "$slug")" || return 1
  name="${TEST_DB_PREFIX}_$(printf '%s' "$label" | tr '-' '_')"
  name="${name:0:64}"
  while [[ "$name" == *_ ]]; do name="${name%_}"; done
  printf '%s' "$name"
}

# Validation gate in front of ANY test-DB DDL. Refuses everything that is not
# unmistakably a tool-generated per-workspace test DB:
#   - must be TEST_DB_PREFIX + "_" + non-empty suffix — the bare prefix IS the
#     shared anny_bookings_test and must never be touched
#   - [a-z0-9_] only, <= 64 chars
#   - never the dev DB (read live from the backend .env), never a system schema
_test_db_name_ok() {
  local name="$1"
  [[ "$name" == "${TEST_DB_PREFIX}_"?* ]] || return 1
  [[ "$name" =~ ^[a-z0-9_]+$ ]] || return 1
  [[ ${#name} -le 64 ]] || return 1
  local dev_db=""
  dev_db="$(grep -E '^DB_DATABASE=' "$BACKEND_REPO/.env" 2>/dev/null \
    | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')"
  case "$name" in
    "$TEST_DB_PREFIX"|mysql|information_schema|performance_schema|sys) return 1 ;;
  esac
  [[ -n "$dev_db" && "$name" == "$dev_db" ]] && return 1
  return 0
}

# Run one SQL statement with the configured credentials.
_test_db_sql() {
  local -a args=(-h "$TEST_DB_HOST" -u "$TEST_DB_USER")
  [[ -n "$TEST_DB_PASSWORD" ]] && args+=("-p${TEST_DB_PASSWORD}")
  mysql "${args[@]}" -e "$1" 2>&1
}

# Ensure the workspace's test DB exists. Empty on purpose: RefreshDatabase
# loads the schema on the first run (~35s), and a clone-from-template would
# trade that once-off wait for a staleness failure mode that's far harder to
# debug. Returns non-zero on failure but never exits — `ws create` must not
# fail over an optional convenience; `ws test` checks the status and DOES fail
# (closed) on it.
test_db_ensure() {
  local slug="$1" name out
  "$TEST_DB_ENABLED" || { vlog "Per-workspace test DB disabled."; return 0; }
  name="$(resolve_test_db "$slug")" || { warn "No test-DB name derivable from '$slug'."; return 1; }
  if ! _test_db_name_ok "$name"; then
    warn "Refusing to create test DB '$name' (fails the safety checks)."
    return 1
  fi
  if "$DRY_RUN"; then
    printf '[dry-run] mysql: CREATE DATABASE IF NOT EXISTS \`%s\`\n' "$name"
    return 0
  fi
  command -v mysql >/dev/null 2>&1 || { warn "mysql client not found — skipping test DB."; return 1; }
  if out="$(_test_db_sql "CREATE DATABASE IF NOT EXISTS \`$name\`")"; then
    vlog "Test DB ready: $name"
    return 0
  fi
  warn "Could not create test DB '$name': ${out:-unknown error}"
  return 1
}

# Drop the workspace's test DB. Guarded to the teeth — see _test_db_name_ok;
# a skipped drop (warning) is always preferable to a wrong one. Never aborts
# the caller: `ws remove` must finish its teardown regardless.
test_db_drop() {
  local slug="$1" name out
  "$TEST_DB_ENABLED" || return 0
  name="$(resolve_test_db "$slug")" || return 0
  if ! _test_db_name_ok "$name"; then
    warn "NOT dropping '$name' — it fails the test-DB safety checks."
    return 0
  fi
  if "$DRY_RUN"; then
    printf '[dry-run] mysql: DROP DATABASE IF EXISTS \`%s\`\n' "$name"
    return 0
  fi
  command -v mysql >/dev/null 2>&1 || return 0
  if out="$(_test_db_sql "DROP DATABASE IF EXISTS \`$name\`")"; then
    vlog "Dropped test DB: $name"
  else
    warn "Could not drop test DB '$name': ${out:-unknown error}"
  fi
  return 0
}

# Run an nginx command, hiding valet-wide deprecation warnings on success.
# Output is shown only with --verbose (VERBOSE=true), or always when it fails.
run_nginx() {
  local out status=0
  # `|| status=$?` keeps `set -e` from aborting so we can print captured output.
  out="$(sudo nginx "$@" 2>&1)" || status=$?
  if [[ $status -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    return "$status"
  fi
  if "$VERBOSE"; then
    printf '%s\n' "$out"
  fi
  return 0
}
