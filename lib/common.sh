# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/common.sh — shared helpers for the `workspaces` CLI.
#
# Sourced by the `workspaces` dispatcher (and thus by every subcommand). Not
# executable on its own. Relies on $WSM_HOME (the real dir of the dispatcher)
# being set before it is sourced.
# -----------------------------------------------------------------------------

WSM_VERSION="0.1.0"

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

# ------------------------------- logging ------------------------------------
# The dispatcher sets LOG_PREFIX to the running subcommand, so messages read
# like "[serve] …" / "[create] …".
LOG_PREFIX="ws"
log()  { printf '[%s] %s\n' "$LOG_PREFIX" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$LOG_PREFIX" "$*" >&2; }

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
sync_scm_ignores() {
  if "$DRY_RUN"; then
    log "[dry-run] would re-sync VS Code SCM ignore-lists across all workspaces"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
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
      log "SCM sync: $slug -> ${#ignores[@]} repo(s) hidden"
      synced=$((synced + 1))
    else
      warn "SCM sync: failed to update $wf (left unchanged)"
    fi
  done
  log "Synced VS Code SCM ignore-lists for $synced workspace(s)."
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
