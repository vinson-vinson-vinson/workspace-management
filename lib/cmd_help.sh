# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_help.sh — `workspaces help`: colorful banner + command overview.
# -----------------------------------------------------------------------------

# ---------------------------- wordmark banner --------------------------------
# "WORKSPACE" stacked over "MANAGEMENT" in the Calvin S box-drawing font
# (3 rows per word, 3 cols per glyph — the whole name in 2 rows at 30 cols).
_WSM_L1='╦ ╦╔═╗╦═╗╦╔═╔═╗╔═╗╔═╗╔═╗╔═╗'
_WSM_L2='║║║║ ║╠╦╝╠╩╗╚═╗╠═╝╠═╣║  ╠═ '
_WSM_L3='╚╩╝╚═╝╩╚═╩ ╩╚═╝╩  ╩ ╩╚═╝╚═╝'
_WSM_L4='╔╦╗╔═╗╔╗╔╔═╗╔═╗╔═╗╔╦╗╔═╗╔╗╔╔╦╗'
_WSM_L5='║║║╠═╣║║║╠═╣║ ╦╠═ ║║║╠═ ║║║ ║ '
_WSM_L6='╩ ╩╩ ╩╝╚╝╩ ╩╚═╝╚═╝╩ ╩╚═╝╝╚╝ ╩ '

# Both rows share one ramp (the width of the widest row) so the fade lines up
# vertically and the two words read as one wordmark. The palette and the fade
# itself live in common.sh — `ws serve`'s summary box uses the same accent.
_WSM_RAMP=30

wsm_banner() {
  local l
  printf '\n'
  for l in "$_WSM_L1" "$_WSM_L2" "$_WSM_L3" "$_WSM_L4" "$_WSM_L5" "$_WSM_L6"; do
    printf '  %s\n' "$(ws_grad "$l" "$_WSM_RAMP")"
  done
  if "$TTY"; then
    printf '  \033[2;38;2;170;140;200mper-task git worktree dev workspaces%s\n' "$C_RESET"
  else
    printf '  per-task git worktree dev workspaces\n'
  fi
}

cmd_help() {
  wsm_banner
  cat <<EOF

${C_BOLD}Usage${C_RESET}
  ${C_CYAN}ws${C_RESET} <command> [options]        ${C_DIM}(or: workspaces <command>)${C_RESET}

${C_BOLD}Commands${C_RESET}
  ${C_GREEN}create${C_RESET} <slug> [options]   Create (or reopen) a workspace and open VS Code
  ${C_GREEN}list${C_RESET} [--quiet]            List all workspaces ${C_DIM}(default when no command given)${C_RESET}
  ${C_GREEN}open${C_RESET} <N|slug>             Open a workspace in VS Code by its ${C_DIM}ws list${C_RESET} index
  ${C_GREEN}serve${C_RESET} [slug] [options]    Serve a workspace at its subdomain ${C_DIM}(defaults to cwd)${C_RESET}
  ${C_GREEN}remove${C_RESET} [slug] [options]   Tear a workspace down safely ${C_DIM}(defaults to cwd)${C_RESET}
  ${C_GREEN}sync${C_RESET}                     Refresh each window's Source Control repo list ${C_DIM}(auto on create/remove)${C_RESET}
  ${C_GREEN}trust${C_RESET} [--revoke]         Stop serve's sudo prompts for good ${C_DIM}(one-time sudoers rule)${C_RESET}
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
