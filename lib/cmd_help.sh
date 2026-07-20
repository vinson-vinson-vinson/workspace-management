# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_help.sh — `workspaces help`: colorful banner + command overview.
# -----------------------------------------------------------------------------

# The wordmark banner (wsm_banner) lives in common.sh — `ws list` shows it too.

cmd_help() {
  wsm_banner
  cat <<EOF

${C_BOLD}Usage${C_RESET}
  ${C_CYAN}ws${C_RESET} <command> [options]        ${C_DIM}(or: workspaces <command>)${C_RESET}

${C_BOLD}Commands${C_RESET}
  ${C_GREEN}create${C_RESET} <slug> [options]   Create (or reopen) a workspace and open your IDE(s)
  ${C_GREEN}list${C_RESET} [--quiet]            List all workspaces ${C_DIM}(default when no command given)${C_RESET}
  ${C_GREEN}open${C_RESET} <N|slug>             Open a workspace in the configured IDE(s) by its ${C_DIM}ws list${C_RESET} index
  ${C_GREEN}serve${C_RESET} [slug] [options]    Serve a workspace at its subdomain ${C_DIM}(defaults to cwd)${C_RESET}
  ${C_GREEN}remove${C_RESET} [slug] [options]   Tear a workspace down safely ${C_DIM}(defaults to cwd)${C_RESET}
  ${C_GREEN}test${C_RESET} [slug] [args]       Run the backend suite on the workspace's OWN test DB ${C_DIM}(defaults to cwd)${C_RESET}
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
