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

# Vaporwave fade: pink -> sky. Both rows share one ramp (the width of the widest
# row) so the fade lines up vertically and the two words read as one wordmark.
_WSM_RAMP=30
_WSM_R1=255; _WSM_G1=113; _WSM_B1=206     # pink
_WSM_R2=1;   _WSM_G2=205; _WSM_B2=254     # sky

# Print one wordmark row, interpolating the fade by COLUMN index.
_ws_grad_line() {
  # NB: separate `local` statements — in a single one, bash expands ${#line}
  # before `line` is assigned, which trips `set -u`.
  local line="$1"
  local n=${#line} i t r g b
  printf '  '
  for ((i = 0; i < n; i++)); do
    t=$i; (( t > _WSM_RAMP - 1 )) && t=$(( _WSM_RAMP - 1 ))
    r=$(( _WSM_R1 + (_WSM_R2 - _WSM_R1) * t / (_WSM_RAMP - 1) ))
    g=$(( _WSM_G1 + (_WSM_G2 - _WSM_G1) * t / (_WSM_RAMP - 1) ))
    b=$(( _WSM_B1 + (_WSM_B2 - _WSM_B1) * t / (_WSM_RAMP - 1) ))
    printf '\033[1;38;2;%d;%d;%dm%s' "$r" "$g" "$b" "${line:i:1}"
  done
  printf '%s\n' "$C_RESET"
}

wsm_banner() {
  local l
  printf '\n'
  # The fade slices the rows per character, which needs a UTF-8 locale — under a
  # byte-oriented one (LC_ALL=C) ${#_WSM_L1} counts bytes, not glyphs, and we'd
  # cut a multibyte char in half. Fall back to a plain wordmark there, and when
  # stdout isn't a terminal.
  if "$TTY" && [[ ${#_WSM_L1} -eq 27 ]]; then
    for l in "$_WSM_L1" "$_WSM_L2" "$_WSM_L3" "$_WSM_L4" "$_WSM_L5" "$_WSM_L6"; do
      _ws_grad_line "$l"
    done
    printf '  \033[2;38;2;170;140;200mper-task git worktree dev workspaces%s\n' "$C_RESET"
  else
    for l in "$_WSM_L1" "$_WSM_L2" "$_WSM_L3" "$_WSM_L4" "$_WSM_L5" "$_WSM_L6"; do
      printf '  %s\n' "$l"
    done
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
