#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# install.sh
#
# Symlinks the `workspaces` command (and its short alias `ws`) into a bin
# directory on your PATH, so you can run it by bare name from anywhere:
#
#     workspaces <command>      ws <command>
#
# Usage:
#   ./install.sh [BIN_DIR]        # default: $HOME/.local/bin
#   BIN_DIR=~/bin ./install.sh
#
# Both names point back at the `workspaces` dispatcher in this checkout, so
# `git pull` updates the command in place — no reinstall needed. Re-running is
# safe (idempotent).
# -----------------------------------------------------------------------------

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${1:-${BIN_DIR:-$HOME/.local/bin}}"

ENTRY="$REPO_DIR/workspaces"
NAMES=(workspaces ws)   # both are the same dispatcher

[[ -f "$ENTRY" ]] || { printf 'ERROR: missing %s\n' "$ENTRY" >&2; exit 1; }

mkdir -p "$BIN_DIR"

for name in "${NAMES[@]}"; do
  dst="$BIN_DIR/$name"
  ln -sfn "$ENTRY" "$dst"
  printf 'linked %s -> %s\n' "$dst" "$ENTRY"
done

# Best-effort cleanup of the old per-command symlinks from the pre-`workspaces`
# layout (only if they still point back into this checkout).
for old in create-workspace remove-workspace list-workspaces serve-workspace; do
  link="$BIN_DIR/$old"
  if [[ -L "$link" && "$(readlink "$link")" == "$REPO_DIR/"* ]]; then
    rm -f "$link"
    printf 'removed stale command %s\n' "$link"
  fi
done

# Warn if BIN_DIR isn't on PATH (checked against a padded PATH so partial
# matches like /usr/local/bin vs /usr/local/bin2 don't produce false hits).
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf '\nNOTE: %s is not on your PATH. Add this to your shell profile:\n' "$BIN_DIR"
    printf '    export PATH="%s:$PATH"\n' "$BIN_DIR"
    ;;
esac

printf '\nDone. Try: ws help\n'
