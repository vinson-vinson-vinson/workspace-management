#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pre-remove hook: back up the workspace's session-local planning/ docs before
# the workspace is torn down, so notes and plans survive for later lookup.
# (Pairs with post-create/init-planning.sh, which creates that planning/ dir.)
#
# ENABLE IT: copy this whole tree into the live (gitignored) hooks dir and make
# the script executable —
#     cp -R hooks.example/ hooks/
#     chmod +x hooks/pre-remove/backup-planning.sh
# `ws remove` then runs every executable file in hooks/pre-remove/ after you
# confirm, before it deletes anything (both worktrees still exist here). If this
# script exits non-zero, ws remove aborts and deletes nothing.
#
# ws remove exports for hooks:
#   WS_SLUG              the workspace slug
#   WS_SESSION_DIR       the session directory
#   WS_FRONTEND          frontend worktree path
#   WS_BACKEND           backend  worktree path
#   WS_FRONTEND_DIR_NAME / WS_BACKEND_DIR_NAME   the repo directory names
#
# Destination defaults to ~/Projects/ws_docs/<slug>; override with WS_DOCS_DIR.
# ---------------------------------------------------------------------------
set -euo pipefail

src="$WS_SESSION_DIR/planning"
dest_root="${WS_DOCS_DIR:-$HOME/Projects/ws_docs}"
dest="$dest_root/$WS_SLUG"

if [[ ! -d "$src" ]]; then
  echo "no planning/ in $WS_SESSION_DIR — nothing to back up"
  exit 0
fi

mkdir -p "$dest"
# The trailing /. copies the CONTENTS of planning/ into $dest (not a nested
# planning/ dir), including sub-directories.
cp -R "$src/." "$dest/"
echo "backed up planning/ -> $dest"
