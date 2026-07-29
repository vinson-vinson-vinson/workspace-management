# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_raccoon.sh — `workspaces raccoon`: an easter egg. Prints a raccoon
# colored with the same gradient stops the `ws list` banner uses (per
# WS_BANNER_COLORS: ws-colors | recent-commits | static), applied on a diagonal
# — the fade sweeps from the top-left corner to the bottom-right. 🦝
# -----------------------------------------------------------------------------

# Render the art (read from stdin) with the active gradient swept diagonally.
# Per-glyph truecolor foreground; math is inlined (no per-char subshell) so a
# ~1500-cell image stays snappy. Plain (uncolored) on a non-TTY / byte locale.
_raccoon_render() {
  local caption="${1:-}"
  local -a art=()
  local line
  while IFS= read -r line; do art+=("$line"); done
  local R=${#art[@]} W=0
  for line in "${art[@]}"; do (( ${#line} > W )) && W=${#line}; done
  (( R > 0 )) || return 0

  # Caption centered under the art (matching the 2-space art indent).
  _raccoon_caption() {
    [[ -n "$caption" ]] || return 0
    local pad=$(( 2 + (W - ${#caption}) / 2 )); (( pad < 0 )) && pad=0
    if "$TTY"; then printf '%*s%s%s%s\n' "$pad" "" "$C_DIM" "$caption" "$C_RESET"
    else printf '%*s%s\n' "$pad" "" "$caption"; fi
  }

  printf '\n'
  if ! "$TTY" || ! "$WS_UTF8"; then
    for line in "${art[@]}"; do printf '  %s\n' "$line"; done
    _raccoon_caption
    return 0
  fi

  local stops=${#WSM_GRAD_STOPS_R[@]}
  local ramp=$(( R + W - 1 )); (( ramp < 2 )) && ramp=2
  local r c llen t pos seg rem nxt cr0 cg0 cb0
  for (( r = 0; r < R; r++ )); do
    line="${art[r]}"; llen=${#line}
    printf '  '
    for (( c = 0; c < llen; c++ )); do
      t=$(( r + c ))                         # diagonal: top-left → bottom-right
      (( t > ramp - 1 )) && t=$(( ramp - 1 ))
      if (( stops >= 2 )); then
        pos=$(( t * (stops - 1) )); seg=$(( pos / (ramp - 1) )); rem=$(( pos - seg * (ramp - 1) ))
        nxt=$(( seg + 1 )); (( nxt > stops - 1 )) && nxt=$(( stops - 1 ))
        cr0=$(( WSM_GRAD_STOPS_R[seg] + (WSM_GRAD_STOPS_R[nxt] - WSM_GRAD_STOPS_R[seg]) * rem / (ramp - 1) ))
        cg0=$(( WSM_GRAD_STOPS_G[seg] + (WSM_GRAD_STOPS_G[nxt] - WSM_GRAD_STOPS_G[seg]) * rem / (ramp - 1) ))
        cb0=$(( WSM_GRAD_STOPS_B[seg] + (WSM_GRAD_STOPS_B[nxt] - WSM_GRAD_STOPS_B[seg]) * rem / (ramp - 1) ))
      else
        cr0=$(( WSM_GRAD_R1 + (WSM_GRAD_R2 - WSM_GRAD_R1) * t / (ramp - 1) ))
        cg0=$(( WSM_GRAD_G1 + (WSM_GRAD_G2 - WSM_GRAD_G1) * t / (ramp - 1) ))
        cb0=$(( WSM_GRAD_B1 + (WSM_GRAD_B2 - WSM_GRAD_B1) * t / (ramp - 1) ))
      fi
      printf '\033[1;38;2;%d;%d;%dm%s' "$cr0" "$cg0" "$cb0" "${line:c:1}"
    done
    printf '\033[0m\n'
  done
  _raccoon_caption
}

cmd_raccoon() {
  ws_load_banner_gradient
  _raccoon_render "↑ this is a raccoon" <<'RACCOON'
⠀⠀⠀⠀⠀⠀⠀⣀⣀⣄⣠⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢰⠇⡀⠀⠙⠻⡿⣦⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⡎⢰⣧⠀⠀⠀⠁⠈⠛⢿⣦⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣠⣴⡦⠶⠟⠓⠚⠻⡄⠀
⠀⠀⠀⠀⠀⠀⣧⠀⣱⣀⣰⣧⠀⢀⠀⣘⣿⣿⣦⣶⣄⣠⡀⠀⠀⣀⣀⣤⣴⣄⣀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣴⣿⠿⠏⠁⠀⣀⣠⣶⣿⡶⣿⠀
⠀⠀⠀⠀⠀⠀⣹⣆⠘⣿⣿⣿⣇⢸⣷⣿⣿⣿⣿⣿⣿⣿⣿⣿⣾⣿⣿⣿⣿⣿⣿⣿⣿⣶⣶⣦⡀⣀⣤⣠⣤⡾⠋⠀⢀⣤⣶⣿⣿⣿⣿⣿⣿⣿⡀
⠀⠀⠀⠀⠀⠀⠘⢿⡄⢼⣿⣿⣿⣿⣿⡟⠻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣵⣾⡾⠙⣋⣩⣽⣿⣿⣿⣿⢋⡼⠁
⠀⠀⠀⠀⠀⠀⠀⠈⢻⣄⠸⢿⣿⣿⠿⠷⠀⠈⠀⣭⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣾⣿⣿⣿⣿⣿⣿⠇⡼⠁⠀
⠀⠀⠀⠀⠀⠀⠀⠀⢾⣯⡀⠀⢼⡿⠀⠀⠀⢼⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⣿⡿⣿⣿⣿⠿⣿⣯⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢋⡼⠁⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⢻⡏⠠⣦⠁⠀⠀⠀⠀⠀⠟⠛⠛⣿⣿⣿⣿⣿⠿⠁⠀⠁⢿⠙⠁⠀⠛⠹⣿⣏⣾⣿⣿⣿⣿⣿⣿⣿⣿⠿⠃⣹⠁⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⣘⣧⠀⠙⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⣿⡿⡿⠀⠀⠀⠀⠈⠀⠀⠀⠀⠀⠀⢹⣿⠿⢿⣿⣿⣿⣿⣿⠋⢀⡤⠛⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⢹⡯⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⣿⣿⣿⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠁⠀⢸⣿⣿⣿⠛⠉⠀⣰⠷⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⠇⠀⠀⠀⠀⠀⢀⣿⡇⠀⠀⢻⣿⣿⠁⠀⠀⢠⣾⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⠟⢿⣿⣄⡀⢸⣿⡀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⢀⣿⠀⠀⠀⢰⣿⣿⡛⣿⣿⡄⢠⡺⠿⡍⠁⢀⣤⣿⣿⣿⠿⣷⣮⣉⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠈⣿⠀⠀⠈⣧⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⢾⠉⠃⠀⣴⣿⣟⠻⣿⣿⣿⡇⢸⣿⣶⠀⢀⣾⣿⣿⣟⠿⣷⣾⣿⣿⣿⣿⣦⣤⣤⡤⠀⠀⠀⠀⠀⠁⠀⠀⠀⣼⠗⠀⠀⠀⠀
⠀⠀⠐⢄⡀⠀⠀⠀⢘⡀⠀⢶⣾⣿⣿⣿⣿⡿⠋⠁⠈⠻⠉⠀⠚⠻⣿⣿⣿⣶⣾⣿⣿⣿⣿⣿⣿⣷⣬⣤⣶⣦⡀⣾⣶⣇⠀⠀⠈⢉⣷⠀⠀⠀⠀
⠀⠀⠀⠀⠈⠓⠶⢦⡽⠄⣈⣿⣿⣿⣿⣿⠏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠹⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡓⠙⣿⡟⠀⠀⠀⠈⠛⣷⣶⡄⠀
⠀⠀⠀⠀⠀⠀⠀⢀⣬⠆⢠⣍⣛⠻⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⣀⡀⠀⠀⠈⠛⢿⣦⡀
⠐⠒⠒⠶⠶⠶⢦⣬⣟⣥⣀⡉⠛⠻⠶⢁⣤⣾⣿⣿⣿⣷⡄⠀⠀⠀⠀⠀⢸⣿⣿⣿⣿⣿⣟⡛⠿⠭⠭⠭⠭⠭⠿⠿⠿⢿⣿⣟⠃⠀⠀⠀⠹⣟⠓
⠀⣀⣠⠤⠤⢤⣤⣾⣤⡄⣉⣉⣙⣓⡂⣿⣿⣭⣹⣿⣿⣿⣿⡰⣂⣀⢀⠀⠻⣿⠛⠻⠟⠡⣶⣾⣿⣿⣿⣿⣿⣿⣿⡖⠒⠒⠒⠛⠷⢤⡀⢰⣴⣿⡆
⠀⠀⠀⢀⣠⡴⠾⠟⠻⣟⡉⠉⠉⠉⢁⢿⣿⣿⣿⣿⣿⣿⡿⣱⣿⣭⡌⠤⠀⠀⠐⣶⣌⡻⣶⣭⡻⢿⣿⣿⣿⣿⣿⣯⣥⣤⣦⠀⠠⣴⣶⣶⣿⡟⢿
⢀⠔⠊⠉⠀⠀⠀⠀⢸⣯⣤⠀⠀⠠⣼⣮⣟⣿⣿⣿⣻⣭⣾⣿⣿⣷⣶⣦⠶⣚⣾⣿⣿⣷⣜⣿⣿⣶⣝⢿⣿⣿⣿⣿⣷⣦⣄⣰⡄⠈⢿⣿⡿⣇⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠈⢡⢇⠀⠀⣠⣿⣿⣿⣯⣟⣛⣛⣛⣛⣛⣩⣭⣴⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⣻⣿⣧⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⣾⠏⠀⢹⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⣍⣿⣿⣿⣿⡄⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣾⡁⢈⣾⣿⡿⠛⣛⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡏⠈⠙⠈⠁⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠛⡿⠛⠉⣽⣿⣷⣾⡿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠷⠌⠛⠉⠀⠁⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠀⠀⠹⠋⠀⢻⣿⣿⣿⣿⠿⢿⣿⣿⣿⣿⣿⣿⠿⣿⣿⣿⣿⠿⠛⠋⠉⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠉⠁⠀⠀⠀⠀⠀⠈⠉⠉⠀⠀⠈⠋⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
RACCOON

  printf '\n'
}
