# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_raccoon.sh — `workspaces raccoon`: an easter egg. A raccoon whose
# diagonal gradient (the same stops the `ws list` banner uses, per
# WS_BANNER_COLORS) SHIMMERS — the colors flow across it endlessly until you
# quit with Ctrl-C. Piped / non-TTY output is a single static frame. 🦝
# -----------------------------------------------------------------------------

# State shared by the render helpers (built once in cmd_raccoon).
_RAC_ART=(); _RAC_R=0; _RAC_W=0; _RAC_L=2; _RAC_N=0
_RAC_PAL=(); _RAC_CAPTION_LINE=""; _RAC_FRAME_OUT=""

# Precompute a CYCLIC palette of _RAC_L truecolor escapes from the active
# gradient stops (or pink→sky). Closing the loop (last stop blends back to the
# first) is what lets the shimmer wrap seamlessly. Sampling once here keeps each
# animation frame to array lookups instead of per-glyph interpolation.
_raccoon_build_palette() {
  local -a SR SG SB
  if (( ${#WSM_GRAD_STOPS_R[@]} >= 2 )); then
    SR=("${WSM_GRAD_STOPS_R[@]}"); SG=("${WSM_GRAD_STOPS_G[@]}"); SB=("${WSM_GRAD_STOPS_B[@]}")
  else
    SR=("$WSM_GRAD_R1" "$WSM_GRAD_R2"); SG=("$WSM_GRAD_G1" "$WSM_GRAD_G2"); SB=("$WSM_GRAD_B1" "$WSM_GRAD_B2")
  fi
  local n=${#SR[@]}
  SR+=("${SR[0]}"); SG+=("${SG[0]}"); SB+=("${SB[0]}")   # close the loop
  local L=$_RAC_L i seg rem a b rr gg bb esc
  _RAC_PAL=()
  for (( i = 0; i < L; i++ )); do
    seg=$(( i * n / L ))                 # segment index in [0, n-1]
    rem=$(( i * n - seg * L ))           # fraction numerator over L
    a=$seg; b=$(( seg + 1 ))
    rr=$(( SR[a] + (SR[b] - SR[a]) * rem / L ))
    gg=$(( SG[a] + (SG[b] - SG[a]) * rem / L ))
    bb=$(( SB[a] + (SB[b] - SB[a]) * rem / L ))
    # printf -v to an array ELEMENT needs bash 4.1; macOS has 3.2, so build the
    # escape in a scalar first, then assign.
    printf -v esc '\033[1;38;2;%d;%d;%dm' "$rr" "$gg" "$bb"
    _RAC_PAL[i]="$esc"
  done
}

# Build one frame (all art rows + the caption) into _RAC_FRAME_OUT, colored by
# the palette shifted by $1 (phase). Diagonal: index = (row + col + phase).
# Blank braille cells (⠀) carry no visible dots, so they skip the color code —
# that's ~half the glyphs, so it shrinks the frame and speeds the build.
_raccoon_frame() {
  local phase="$1" r c llen idx line g frame=""
  for (( r = 0; r < _RAC_R; r++ )); do
    line="${_RAC_ART[r]}"; llen=${#line}
    frame+='  '
    for (( c = 0; c < llen; c++ )); do
      g="${line:c:1}"
      if [[ "$g" == '⠀' ]]; then
        frame+="$g"
      else
        idx=$(( (r + c + phase) % _RAC_L ))
        frame+="${_RAC_PAL[idx]}$g"
      fi
    done
    frame+=$'\033[0m\n'
  done
  frame+="$_RAC_CAPTION_LINE"
  _RAC_FRAME_OUT="$frame"
}

# Return the cursor below the raccoon and make it visible again.
_raccoon_cleanup() { printf '\033[u\033[%dB\033[?25h' "$_RAC_N"; }

cmd_raccoon() {
  ws_load_banner_gradient

  local line
  _RAC_ART=()
  while IFS= read -r line; do _RAC_ART+=("$line"); done <<'RACCOON'
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

  _RAC_R=${#_RAC_ART[@]}; _RAC_W=0
  for line in "${_RAC_ART[@]}"; do (( ${#line} > _RAC_W )) && _RAC_W=${#line}; done
  (( _RAC_R > 0 )) || return 0
  _RAC_L=$(( _RAC_R + _RAC_W - 1 )); (( _RAC_L < 2 )) && _RAC_L=2
  _RAC_N=$(( _RAC_R + 1 ))                       # art rows + caption line

  local cap="↑ this is a raccoon"
  local cpad=$(( 2 + (_RAC_W - ${#cap}) / 2 )); (( cpad < 0 )) && cpad=0

  # No TTY (piped) or byte locale: one static, uncolored frame — no animation.
  if ! "$TTY" || ! "$WS_UTF8"; then
    printf '\n'
    for line in "${_RAC_ART[@]}"; do printf '  %s\n' "$line"; done
    printf '%*s%s\n' "$cpad" "" "$cap"
    return 0
  fi

  printf -v _RAC_CAPTION_LINE '%*s\033[2m%s\033[0m\n' "$cpad" "" "$cap"
  _raccoon_build_palette

  # Reserve N lines so the animation never scrolls mid-run, anchor at the top
  # (save cursor), and hide the cursor. Ctrl-C restores it and drops the prompt
  # below the raccoon. It also auto-quits after WS_RACCOON_SECONDS (5 min by
  # default) so it can't burn CPU unattended; WS_RACCOON_FRAMES caps frames
  # instead (0 = uncapped).
  local max="${WS_RACCOON_FRAMES:-0}" max_s="${WS_RACCOON_SECONDS:-300}"
  local phase=0 count=0 start=$SECONDS i
  local -a FRAMES=()
  printf '\n'
  for (( i = 0; i < _RAC_N; i++ )); do printf '\n'; done
  printf '\033[%dA\033[s\033[?25l' "$_RAC_N"
  # Restore the cursor on Ctrl-C (INT), kill (TERM), and terminal-close (HUP),
  # so an interrupted shimmer never leaves the cursor hidden.
  trap '_raccoon_cleanup; exit 130' INT TERM HUP

  # The animation is periodic — only _RAC_L distinct frames — so build each once
  # and cache it. After the first cycle the loop is just a lookup + a print, so
  # the sustained CPU drops to little more than the per-frame sleep.
  while :; do
    if [[ -z "${FRAMES[phase]+x}" ]]; then
      _raccoon_frame "$phase"; FRAMES[phase]="$_RAC_FRAME_OUT"
    fi
    printf '\033[u%s' "${FRAMES[phase]}"
    count=$(( count + 1 ))
    (( max > 0 && count >= max )) && break              # frame cap (testing)
    (( SECONDS - start >= max_s )) && break              # 5-minute time limit
    (( max > 0 )) || sleep 0.05
    # Decrement (with wrap) so the gradient flows toward the bottom-right.
    phase=$(( (phase + _RAC_L - 1) % _RAC_L ))
  done

  _raccoon_cleanup; printf '\n'
}
