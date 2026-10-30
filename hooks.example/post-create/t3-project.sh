#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# post-create hook: register the new workspace as a T3 Code project
# (https://t3.codes), with the frontend's favicon as its sidebar icon.
#
# The project root is the session dir, so T3 threads see both worktrees side by
# side, like the VS Code window does. T3 picks up <root>/favicon.ico when a
# project is added, so the favicon is linked there first — a symlink, so it
# follows the frontend worktree and stays outside both repos.
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
#   T3_FAVICON   favicon path relative to the frontend worktree
#                (default: app-admin/public/_favicons/favicon.ico)
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
favicon="$WS_FRONTEND/${T3_FAVICON:-app-admin/public/_favicons/favicon.ico}"

if [[ "${WS_DRY_RUN:-false}" == true ]]; then
  [[ -f "$favicon" ]] && echo "[dry-run] ln -sfn $favicon $WS_SESSION_DIR/favicon.ico"
  echo "[dry-run] $t3 project add --title $WS_SLUG $WS_SESSION_DIR"
  exit 0
fi

[[ -f "$favicon" ]] && ln -sfn "$favicon" "$WS_SESSION_DIR/favicon.ico"
"$t3" project add --title "$WS_SLUG" "$WS_SESSION_DIR" || true
exit 0
