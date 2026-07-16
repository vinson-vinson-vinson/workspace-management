# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_list.sh — `workspaces list`: list workspaces, star the current one,
# and link each served workspace to its admin URL.
# -----------------------------------------------------------------------------

cmd_list_usage() {
  cat <<'USAGE'
Usage:
  ws list [--quiet]

Lists all workspaces under the worktrees root. Each line shows the workspace
name, and — if it is being served — a link to its admin URL. The workspace you
are currently inside is marked with a leading '*'.

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

# Extract a workspace's accent color (titleBar.activeBackground) from its
# .code-workspace file. Echoes a hex like "#571f74", or nothing.
_ws_color() {
  local file
  file="$(workspace_file_for "$1")"
  [[ -f "$file" ]] || file="$(legacy_workspace_file_for "$1")"
  [[ -f "$file" ]] || return 0
  grep -o '"titleBar\.activeBackground"[[:space:]]*:[[:space:]]*"#[0-9a-fA-F]\{6\}"' "$file" 2>/dev/null \
    | grep -o '#[0-9a-fA-F]\{6\}' | head -n1
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

  # Collect workspace slugs: immediate subdirectories of the worktrees root.
  local slugs=()
  if [[ -d "$WORKSPACES_ROOT" ]]; then
    local entry
    for entry in "$WORKSPACES_ROOT"/*/; do
      [[ -d "$entry" ]] || continue
      slugs+=("$(basename "$entry")")
    done
  fi

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

  # ---- build rows: col1 = color swatch / MAIN tag, col2 = name, col3 = link --
  local -a r_key=() r_name=() r_badge_plain=() r_badge=() r_link=()

  # MAIN first — identified by a MAIN tag (not a color), always served.
  r_key+=("MAIN")
  r_name+=("$(_ws_main_label)")
  r_badge_plain+=("MAIN")
  r_badge+=("${C_BOLD}${C_CYAN}MAIN${C_RESET}")
  r_link+=("${BASE_DOMAIN}${ADMIN_PATH}")

  local slug sw badge
  for slug in ${slugs[@]+"${slugs[@]}"}; do
    r_key+=("$slug")
    r_name+=("$slug")
    sw="$(_ws_swatch "$(_ws_color "$slug")")"
    if [[ -n "$sw" ]]; then badge="$sw"; else badge="${C_DIM}●${C_RESET}"; fi
    r_badge_plain+=("●")
    r_badge+=("$badge")
    r_link+=("$(_ws_admin_url "$slug")")
  done

  # Column widths from PLAIN text so ANSI / hyperlink codes don't skew alignment.
  # Long names are capped with an ellipsis so the table stays compact.
  local name_cap=50
  local i len maxbadge=0 maxname=9      # 9 = len("WORKSPACE")
  for i in "${!r_key[@]}"; do
    len=${#r_badge_plain[$i]}; (( len > maxbadge )) && maxbadge=$len
    len=${#r_name[$i]}; (( len > name_cap )) && len=$name_cap
    (( len > maxname )) && maxname=$len
  done

  # Header (col1 is the marker/color column, left unlabeled).
  printf '%*s  %s%-*s  %s%s\n' \
    $((2 + maxbadge)) "" \
    "$C_DIM" "$maxname" "WORKSPACE" "SERVE URL" "$C_RESET"

  # Rows: leading '*' marks the workspace containing the cwd. col2 is padded by
  # hand (not %-*s) because a truncated name carries a multi-byte ellipsis whose
  # byte length would otherwise throw the alignment off.
  local curc bpad link name dw pad
  for i in "${!r_key[@]}"; do
    if [[ "$current_key" == "${r_key[$i]}" ]]; then
      curc="${C_BOLD}*${C_RESET}"
    else
      curc=' '
    fi
    bpad=$(( maxbadge - ${#r_badge_plain[$i]} ))

    name="${r_name[$i]}"
    if (( ${#name} > maxname )); then
      name="${name:0:maxname-1}…"   # display width == maxname
      dw=$maxname
    else
      dw=${#name}
    fi
    pad=$(( maxname - dw ))

    # Linkify AFTER truncation/padding math — the OSC 8 escapes are zero-width
    # but would inflate ${#name}. MAIN has no .code-workspace, so it stays plain.
    if [[ "${r_key[$i]}" != "MAIN" ]]; then
      name="$(_ws_name_link "${r_key[$i]}" "$name")"
    fi

    if [[ -n "${r_link[$i]}" ]]; then
      link="$(_ws_link "${r_link[$i]}")"
    else
      link="${C_DIM}—${C_RESET}"
    fi

    printf '%s %s%*s  %s%*s  %s\n' \
      "$curc" "${r_badge[$i]}" "$bpad" "" \
      "$name" "$pad" "" \
      "$link"
  done
}
