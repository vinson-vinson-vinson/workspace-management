#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# install.sh
#
# Symlinks the workspace-management commands into a bin directory on your PATH,
# so you can run them by bare name from anywhere:
#
#     create-workspace   remove-workspace   list-workspaces   serve-workspace
#
# Usage:
#   ./install.sh [BIN_DIR]        # default: $HOME/.local/bin
#   BIN_DIR=~/bin ./install.sh
#
# The symlinks point back at this checkout, so `git pull` updates the commands
# in place — no reinstall needed. Re-running is safe (idempotent).
# -----------------------------------------------------------------------------

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${1:-${BIN_DIR:-$HOME/.local/bin}}"

SCRIPTS=(create-workspace remove-workspace list-workspaces serve-workspace)

mkdir -p "$BIN_DIR"

for name in "${SCRIPTS[@]}"; do
  src="$REPO_DIR/$name.sh"
  dst="$BIN_DIR/$name"
  [[ -f "$src" ]] || { printf 'ERROR: missing %s\n' "$src" >&2; exit 1; }
  ln -sfn "$src" "$dst"
  printf 'linked %s -> %s\n' "$dst" "$src"
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

printf '\nDone. Try: list-workspaces\n'
