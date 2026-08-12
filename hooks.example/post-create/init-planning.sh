#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# post-create hook: give a new workspace a session-local planning/ directory —
# a sibling of the two worktrees, outside both repos, so it's never git-tracked.
# A scratch area for agent output, notes and .md plans that stay purely local.
# It's also added to the VS Code workspace so it shows up in the window.
#
# ENABLE IT: copy this tree into the live (gitignored) hooks dir + chmod +x —
#     cp -R hooks.example/ hooks/
#     chmod +x hooks/post-create/init-planning.sh
# `ws create` runs every executable in hooks/post-create/ after the workspace is
# provisioned and its .code-workspace written, but before the IDE opens. A
# failing hook only warns — it never undoes the create.
#
# ws create exports: WS_SLUG, WS_SESSION_DIR, WS_FRONTEND, WS_BACKEND,
# WS_FRONTEND_DIR_NAME, WS_BACKEND_DIR_NAME, WS_WORKSPACE_FILE.
# ---------------------------------------------------------------------------
set -euo pipefail

mkdir -p "$WS_SESSION_DIR/planning"

# Add ./planning as a workspace folder. Paths in a .code-workspace are relative
# to the file (which lives in the session dir), so "planning" resolves to the
# dir above. Idempotent, and it survives `ws sync` (that only rewrites
# git.ignoredRepositories). python3 keeps the JSON valid; macOS ships it.
if [[ -f "$WS_WORKSPACE_FILE" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$WS_WORKSPACE_FILE" <<'PY'
import json, sys
f = sys.argv[1]
with open(f) as fh:
    data = json.load(fh)
folders = data.setdefault("folders", [])
if not any(x.get("path") == "planning" for x in folders):
    folders.append({"path": "planning"})
    with open(f, "w") as fh:
        json.dump(data, fh, indent=2)
PY
fi

echo "planning/ ready and added to the workspace"
