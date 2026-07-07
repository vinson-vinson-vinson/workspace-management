# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_help.sh — `workspaces help`: colorful banner + command overview.
# -----------------------------------------------------------------------------

# Print a horizontal run of a box-drawing char (bash-3.2 safe).
_ws_hline() {
  local ch="$1" n="$2" i
  for ((i = 0; i < n; i++)); do printf '%s' "$ch"; done
}

# Print one framed row. Padding is computed from the PLAIN text length so the
# box still aligns when the colored text carries (zero-width) ANSI codes.
_ws_box_row() {
  local plain="$1" colored="$2" w="$3" pad
  pad=$(( w - ${#plain} ))
  (( pad < 0 )) && pad=0
  printf '  %s│%s%s%*s%s│%s\n' \
    "$C_BLUE" "$C_RESET" "$colored" "$pad" "" "$C_BLUE" "$C_RESET"
}

wsm_banner() {
  local w=46
  printf '\n  %s╭' "$C_BLUE"; _ws_hline '─' "$w"; printf '╮%s\n' "$C_RESET"
  _ws_box_row "" "" "$w"
  _ws_box_row \
    "   WORKSPACE MANAGEMENT" \
    "   ${C_BOLD}${C_CYAN}WORKSPACE${C_RESET} ${C_BOLD}${C_MAGENTA}MANAGEMENT${C_RESET}" \
    "$w"
  _ws_box_row \
    "   per-task git worktree dev workspaces" \
    "   ${C_DIM}per-task git worktree dev workspaces${C_RESET}" \
    "$w"
  _ws_box_row "" "" "$w"
  printf '  %s╰' "$C_BLUE"; _ws_hline '─' "$w"; printf '╯%s\n' "$C_RESET"
}

cmd_help() {
  wsm_banner
  cat <<EOF

${C_BOLD}Usage${C_RESET}
  ${C_CYAN}ws${C_RESET} <command> [options]        ${C_DIM}(or: workspaces <command>)${C_RESET}

${C_BOLD}Commands${C_RESET}
  ${C_GREEN}create${C_RESET} <slug> [options]   Create (or reopen) a workspace and open VS Code
  ${C_GREEN}list${C_RESET} [--quiet]            List all workspaces ${C_DIM}(default when no command given)${C_RESET}
  ${C_GREEN}serve${C_RESET} [slug] [options]    Serve a workspace at its subdomain ${C_DIM}(defaults to cwd)${C_RESET}
  ${C_GREEN}remove${C_RESET} [slug] [options]   Tear a workspace down safely ${C_DIM}(defaults to cwd)${C_RESET}
  ${C_GREEN}sync${C_RESET}                     Refresh each window's Source Control repo list ${C_DIM}(auto on create/remove)${C_RESET}
  ${C_GREEN}help${C_RESET}                     Show this help
  ${C_GREEN}version${C_RESET}                  Print the version

${C_BOLD}Examples${C_RESET}
  ws create CU-1234_my-feature
  ws                          ${C_DIM}# list${C_RESET}
  ws serve                    ${C_DIM}# serve the workspace you're in${C_RESET}
  ws remove --dry-run

Run ${C_CYAN}ws <command> --help${C_RESET} for command-specific options.
EOF
}
