#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pre-remove hook: unregister the workspace's T3 Code project (pairs with
# post-create/t3-project.sh).
#
# No --force: that flag also deletes the project's threads, and a workspace's
# agent history shouldn't vanish with `ws remove`. Safe to enable everywhere:
# without T3 Code installed it does nothing. Always exits 0, because a failing
# pre-remove hook aborts the remove.
#
# ENABLE IT: copy this tree into the live (gitignored) hooks dir + chmod +x —
#     cp -R hooks.example/ hooks/
#     chmod +x hooks/pre-remove/t3-project.sh
#
# Override: T3_CLI   path to the t3 CLI (default: `t3` on PATH, then ~/.t3/bin/t3)
#
# ws remove exports: WS_SLUG, WS_SESSION_DIR, WS_FRONTEND, WS_BACKEND,
# WS_FRONTEND_DIR_NAME, WS_BACKEND_DIR_NAME, WS_DRY_RUN.
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

[[ -n "${WS_SESSION_DIR:-}" ]] || exit 0
t3="$(find_t3)" || exit 0

if [[ "${WS_DRY_RUN:-false}" == true ]]; then
  echo "[dry-run] $t3 project remove $WS_SESSION_DIR"
  exit 0
fi

"$t3" project remove "$WS_SESSION_DIR" \
  || echo "T3 project not removed (never added, or T3 refused) — left as is."
exit 0
