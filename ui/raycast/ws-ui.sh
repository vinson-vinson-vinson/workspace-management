#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Workspaces UI
# @raycast.mode silent
# @raycast.packageName ws

# Optional parameters:
# @raycast.icon 🗂️
# @raycast.description Open the ws workspaces dashboard (starts the server if it isn't running)

# Raycast launches scripts with a minimal environment — resolve node via nvm.
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1 && nvm use default >/dev/null 2>&1
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

PORT="${WS_UI_PORT:-7777}"
URL="http://localhost:${PORT}"
# <repo>/ui/raycast/ws-ui.sh -> UI_DIR=<repo>/ui, WSM_HOME=<repo>
UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WSM_HOME="$(dirname "$UI_DIR")"

if ! lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  command -v node >/dev/null 2>&1 || { echo "node not found (nvm?)"; exit 1; }
  mkdir -p "$HOME/.ws-ui"
  # Detach fully so the server outlives Raycast's script runner.
  WSM_HOME="$WSM_HOME" WS_UI_PORT="$PORT" \
    nohup node "$UI_DIR/server.mjs" >>"$HOME/.ws-ui/server.log" 2>&1 &
  disown
  # Wait (max ~3s) for the port to come up before opening the browser.
  for _ in $(seq 1 15); do
    lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.2
  done
  echo "ws-ui started → $URL"
else
  echo "ws-ui → $URL"
fi

open "$URL"
