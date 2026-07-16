# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_list.sh — `workspaces list`: the wordmark banner over a box-drawing
# table of all workspaces — # (the `ws open` index, starred for the current
# workspace), color swatch + clickable name, serve URL. Piped output falls back
# to plain aligned columns so scripts keep working.
# -----------------------------------------------------------------------------

cmd_list_usage() {
  cat <<'USAGE'
Usage:
  ws list [--quiet]

Lists all workspaces under the worktrees root. Each row shows the `ws open`
index (the current workspace is starred), the workspace name (clickable:
opens the VS Code workspace), and — if it is being served — its admin URL.

Options:
  -q, --quiet   Print only the workspace names, one per line (script-friendly).
  -h, --help    Show this help.
USAGE
}

# Clickable green link for a bare host+path (https:// is added here). On a
# terminal, wraps the URL in an OSC 8 hyperlink; otherwise prints the plain URL.
_ws_link() {
  local url="https://$1"
  if "$TTY"; then
    printf '\033]8;;%s\033\\%s%s%s\033]8;;\033\\' "$url" "$C_GREEN" "$url" "$C_RESET"
  else
    printf '%s' "$url"
  fi
}

# Wrap TEXT in an OSC 8 hyperlink to the slug's .code-workspace file, so
# clicking the workspace name opens it in VS Code (a file:// URL goes through
# LaunchServices — same as double-clicking the file in Finder). Plain text when
# stdout isn't a terminal or the workspace file doesn't exist.
_ws_name_link() {
  local slug="$1" text="$2" file
  "$TTY" || { printf '%s' "$text"; return; }
  file="$(workspace_file_for "$slug")"
  [[ -f "$file" ]] || file="$(legacy_workspace_file_for "$slug")"
  [[ -f "$file" ]] || { printf '%s' "$text"; return; }
  printf '\033]8;;file://%s\033\\%s\033]8;;\033\\' "$file" "$text"
}

# Render a truecolor filled circle for a hex color (#RRGGBB), only on a terminal.
_ws_swatch() {
  local hex="${1#\#}"
  [[ ${#hex} -eq 6 ]] || return 0
  "$TTY" || return 0
  local r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))
  printf '\033[38;2;%d;%d;%dm●\033[0m' "$r" "$g" "$b"
}

# Echo a repo's current branch, or empty if none/detached.
_ws_repo_branch() {
  local repo="$1"
  [[ -d "$repo/.git" ]] || return 0
  git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# Branch label for the main workspace: one branch if both repos agree, else both
# labeled. Empty if neither repo resolves.
_ws_main_label() {
  local fe be
  fe="$(_ws_repo_branch "$FRONTEND_REPO")"
  be="$(_ws_repo_branch "$BACKEND_REPO")"
  if [[ -n "$fe" && "$fe" == "$be" ]]; then
    printf '%s' "$fe"
  elif [[ -n "$fe" || -n "$be" ]]; then
    printf '%s:%s %s:%s' "$FRONTEND_DIR_NAME" "${fe:-?}" "$BACKEND_DIR_NAME" "${be:-?}"
  fi
}

# Echo the admin URL for a slug if an nginx block exists, else nothing.
_ws_admin_url() {
  local slug="$1" sub host
  sub="$(resolve_subdomain "$slug")" || return 0
  host="${sub}.${BASE_DOMAIN}"
  [[ -f "$VALET_NGINX_DIR/$host" ]] && printf '%s' "${host}${ADMIN_PATH}"
  return 0
}

cmd_list() {
  local quiet=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q|--quiet) quiet=true; shift ;;
      -h|--help)  cmd_list_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_list_usage; exit 1 ;;
      *)  err "Unexpected argument: $1"; cmd_list_usage; exit 1 ;;
    esac
  done

  local cwd; cwd="$(pwd -P)"

  # Collect workspace slugs via the shared helper — the row numbers printed
  # here are what `ws open <N>` resolves, so both must see the same sequence.
  local slugs=() slug_line
  while IFS= read -r slug_line; do
    slugs+=("$slug_line")
  done < <(workspace_slugs)

  # Figure out which workspace the CLI is inside. Each workspace owns a few base
  # dirs (frontend, backend, and their parent); the LONGEST matching base wins,
  # so a task worktree stars that task rather than MAIN (whose parent, the
  # project root, also matches). `${slugs[@]+…}` keeps `set -u` happy when empty.
  local -a cand_key=() cand_base=()
  cand_key+=("MAIN"); cand_base+=("$ROOT_DIR")
  cand_key+=("MAIN"); cand_base+=("$FRONTEND_REPO")
  cand_key+=("MAIN"); cand_base+=("$BACKEND_REPO")
  local slug
  for slug in ${slugs[@]+"${slugs[@]}"}; do
    cand_key+=("$slug"); cand_base+=("$WORKSPACES_ROOT/$slug")
  done

  local current_key="" best_len=-1 i base
  for i in "${!cand_base[@]}"; do
    base="${cand_base[$i]}"
    if [[ "$cwd" == "$base" || "$cwd" == "$base/"* ]] && (( ${#base} > best_len )); then
      best_len=${#base}
      current_key="${cand_key[$i]}"
    fi
  done

  if "$quiet"; then
    printf 'MAIN\n'
    [[ ${#slugs[@]} -gt 0 ]] && printf '%s\n' "${slugs[@]}"
    exit 0
  fi

  # ---- build the table model --------------------------------------------
  # Box-drawing table under the centered wordmark on a UTF-8 terminal, with a
  # spinner while the model is collected (the per-row color/nginx/git lookups
  # add up). The banner prints only after collection: centering it needs the
  # final table width. Piped or byte-locale output falls back to plain
  # aligned columns for scripts.
  local fancy=false
  "$TTY" && "$WS_UTF8" && fancy=true
  "$fancy" && spin "loading workspaces"

  # Parallel arrays: *_plain carries the width math (ANSI + OSC 8 escapes are
  # zero display width but inflate ${#}), the styled twin is what's printed.
  local -a r_key=() r_idx=() r_ws_plain=() r_ws=() r_url_plain=() r_url=()
  local name_cap=50

  # MAIN first — index 0 (`ws open 0`), identified by a MAIN tag (not a
  # swatch), always served. Its name links to MAIN_WORKSPACE_FILE when set.
  local main_label main_name
  main_label="$(_ws_main_label)"
  main_name="${C_BOLD}${C_CYAN}MAIN${C_RESET} ${main_label}"
  if "$TTY" && [[ -n "$MAIN_WORKSPACE_FILE" && -f "$MAIN_WORKSPACE_FILE" ]]; then
    main_name="$(printf '\033]8;;file://%s\033\\%s\033]8;;\033\\' "$MAIN_WORKSPACE_FILE" "$main_name")"
  fi
  r_key+=("MAIN"); r_idx+=("0")
  r_ws_plain+=("MAIN ${main_label}")
  r_ws+=("$main_name")
  r_url_plain+=("https://${BASE_DOMAIN}${ADMIN_PATH}")
  r_url+=("$(_ws_link "${BASE_DOMAIN}${ADMIN_PATH}")")

  local sw name url n=0
  for slug in ${slugs[@]+"${slugs[@]}"}; do
    n=$((n + 1))
    r_key+=("$slug"); r_idx+=("$n")
    name="$slug"
    (( ${#name} > name_cap )) && name="${name:0:name_cap-1}…"
    sw="$(_ws_swatch "$(_ws_color "$slug")")"
    [[ -n "$sw" ]] || sw="${C_DIM}●${C_RESET}"
    r_ws_plain+=("● ${name}")
    r_ws+=("${sw} $(_ws_name_link "$slug" "$name")")
    url="$(_ws_admin_url "$slug")"
    if [[ -n "$url" ]]; then
      r_url_plain+=("https://${url}")
      r_url+=("$(_ws_link "$url")")
    else
      r_url_plain+=("—")
      r_url+=("${C_DIM}—${C_RESET}")
    fi
  done

  # Current-workspace marker folded into the # cell: "*3" ("*0" for MAIN).
  local -a r_no=()
  local mark
  for i in "${!r_key[@]}"; do
    mark=" "
    [[ "$current_key" == "${r_key[$i]}" ]] && mark="*"
    r_no+=("${mark}${r_idx[$i]}")
  done

  # ---- column widths (from PLAIN text) -----------------------------------
  local idxw=1 wsw=9 urlw=9 len   # 9 = len("Workspace") / len("Serve URL")
  for i in "${!r_key[@]}"; do
    len=${#r_no[$i]};        (( len > idxw )) && idxw=$len
    len=${#r_ws_plain[$i]};  (( len > wsw ))  && wsw=$len
    len=${#r_url_plain[$i]}; (( len > urlw )) && urlw=$len
  done

  if ! "$fancy"; then
    # Plain fallback (piped / non-UTF-8 locale): same data, no box. Padded by
    # hand — printf's %-*s width counts BYTES, and ●/— are multibyte.
    printf '%*s  %s%*s  %s\n' "$idxw" "#" "WORKSPACE" $((wsw - 9)) "" "SERVE URL"
    for i in "${!r_key[@]}"; do
      printf '%*s  %s%*s  %s\n' \
        "$idxw" "${r_no[$i]}" \
        "${r_ws_plain[$i]}" $((wsw - ${#r_ws_plain[$i]})) "" \
        "${r_url_plain[$i]}"
    done
    return 0
  fi

  spin_stop

  # ---- render: banner spanning the box width, then the box ----------------
  # Box width = 3 cells with one space of padding each side (+6) plus the 4
  # vertical borders. The banner centers the wordmark over that width, with
  # its gradient rules cascading out to both box edges.
  local box_w=$((idxw + wsw + urlw + 10))
  wsm_banner 2 "$box_w"
  printf '\n'

  local seg1 seg2 seg3 sep="${C_DIM}│${C_RESET}"
  seg1="$(ws_rule '─' $((idxw + 2)))"
  seg2="$(ws_rule '─' $((wsw + 2)))"
  seg3="$(ws_rule '─' $((urlw + 2)))"

  printf '  %s╭%s┬%s┬%s╮%s\n' "$C_DIM" "$seg1" "$seg2" "$seg3" "$C_RESET"
  printf '  %s│ %-*s │ %-*s │ %-*s │%s\n' \
    "$C_DIM" "$idxw" "#" "$wsw" "Workspace" "$urlw" "Serve URL" "$C_RESET"
  printf '  %s├%s┼%s┼%s┤%s\n' "$C_DIM" "$seg1" "$seg2" "$seg3" "$C_RESET"

  local pad1 pad2 pad3
  for i in "${!r_key[@]}"; do
    pad1=$((idxw - ${#r_no[$i]}))
    pad2=$((wsw - ${#r_ws_plain[$i]}))
    pad3=$((urlw - ${#r_url_plain[$i]}))
    printf '  %s %s%*s %s %s%*s %s %s%*s %s\n' \
      "$sep" "${r_no[$i]}" "$pad1" "" \
      "$sep" "${r_ws[$i]}" "$pad2" "" \
      "$sep" "${r_url[$i]}" "$pad3" "" \
      "$sep"
  done
  printf '  %s╰%s┴%s┴%s╯%s\n' "$C_DIM" "$seg1" "$seg2" "$seg3" "$C_RESET"
}
