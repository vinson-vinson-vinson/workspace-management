# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/common.sh — shared helpers for the `workspaces` CLI.
#
# Sourced by the `workspaces` dispatcher (and thus by every subcommand). Not
# executable on its own. Relies on $WSM_HOME (the real dir of the dispatcher)
# being set before it is sourced.
# -----------------------------------------------------------------------------

WSM_VERSION="1.3.1"

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
