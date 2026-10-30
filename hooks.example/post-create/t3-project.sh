#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# post-create hook: register the new workspace as a T3 Code project
# (https://t3.codes), with the frontend's favicon as its sidebar icon.
#
# The project root is the session dir, so T3 threads see both worktrees side by
# side, like the VS Code window does. T3 picks up <root>/favicon.ico when a
# project is added, so the icon is linked there first: the app's favicon with a
# ring in the workspace color, the same badge `ws serve` puts in browser tabs
# (generated into <session>/.favicons/, where `ws serve` writes its own). With
# no workspace color, python3 or lib/favicon_ring.py, it links the plain icon.
#
# Safe to enable everywhere: without T3 Code installed it does nothing. Re-run
# on an existing workspace is a no-op. It never fails the create.
#
# ENABLE IT: copy this tree into the live (gitignored) hooks dir + chmod +x —
#     cp -R hooks.example/ hooks/
#     chmod +x hooks/post-create/t3-project.sh
#
# Overrides:
#   T3_CLI       path to the t3 CLI (default: `t3` on PATH, then ~/.t3/bin/t3)
#   T3_FAVICON_APP   app key whose favicon is used (default: admin); its icons
#                    are read from <frontend>/app-<key>/public/_favicons/
#   T3_OPEN          open the new project in T3 Code: auto (default — only when
#                    `ws create` runs inside T3, e.g. its terminal or an agent),
#                    always, or never
#
# ws create exports: WS_SLUG, WS_SESSION_DIR, WS_FRONTEND, WS_BACKEND,
# WS_FRONTEND_DIR_NAME, WS_BACKEND_DIR_NAME, WS_WORKSPACE_FILE, WS_DRY_RUN.
# ---------------------------------------------------------------------------
set -uo pipefail

# Echo the T3 Code CLI, or nothing. A candidate counts only if it answers
# `t3 project add --help`, so an unrelated `t3` on PATH is never called.
find_t3() {
  local c
  for c in "${T3_CLI:-}" "$(command -v t3 2>/dev/null)" "$HOME/.t3/bin/t3"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" project add --help >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

[[ -n "${WS_SESSION_DIR:-}" && -n "${WS_FRONTEND:-}" ]] || exit 0
t3="$(find_t3)" || { echo "T3 Code not installed — skipping."; exit 0; }
app="${T3_FAVICON_APP:-admin}"
src="$WS_FRONTEND/app-$app/public/_favicons"
ringed="$WS_SESSION_DIR/.favicons/$app/favicon.ico"
# WSM_HOME is exported by run_hooks; the fallback is the default hooks/ layout.
ring="${WSM_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/favicon_ring.py"

# The workspace accent color (titleBar.activeBackground), as `ws list` reads it.
ws_file="${WS_WORKSPACE_FILE:-$WS_SESSION_DIR/$WS_SLUG.code-workspace}"
color="$(grep -o '"titleBar\.activeBackground"[[:space:]]*:[[:space:]]*"#[0-9a-fA-F]\{6\}"' \
  "$ws_file" 2>/dev/null | grep -o '#[0-9a-fA-F]\{6\}' | head -n1)"

if [[ "${WS_DRY_RUN:-false}" == true ]]; then
  [[ -n "$color" ]] && echo "[dry-run] ring $src in $color -> $ringed"
  echo "[dry-run] ln -sfn <icon> $WS_SESSION_DIR/favicon.ico"
  echo "[dry-run] $t3 project add --title $WS_SLUG $WS_SESSION_DIR"
  exit 0
fi

# Inside T3 Code, its env carries T3CODE_THREAD_ID / T3CODE_CLI_PATH.
open_in_t3=false
case "${T3_OPEN:-auto}" in
  always) open_in_t3=true ;;
  auto) [[ -n "${T3CODE_THREAD_ID:-}${T3CODE_CLI_PATH:-}" ]] && open_in_t3=true ;;
esac

icon="$src/favicon.ico"
if [[ -n "$color" && -f "$ring" ]] && command -v python3 >/dev/null 2>&1 \
   && python3 "$ring" "$color" "$WS_SESSION_DIR/.favicons" "$app:$src"; then
  icon="$ringed"
fi
[[ -f "$icon" ]] && ln -sfn "$icon" "$WS_SESSION_DIR/favicon.ico"
"$t3" project add --title "$WS_SLUG" "$WS_SESSION_DIR" || true
if "$open_in_t3"; then "$t3" app "$WS_SESSION_DIR" || true; fi
exit 0
