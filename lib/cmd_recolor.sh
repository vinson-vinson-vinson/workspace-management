# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_recolor.sh — `workspaces recolor`: give a workspace a new accent
# color. Draws from the same picker `ws create` uses (random_workspace_color),
# then rewrites only the color keys in the workspace's .code-workspace — the
# rest of the file (folders, tasks, hand edits) is left untouched.
# -----------------------------------------------------------------------------

cmd_recolor_usage() {
  cat <<'USAGE'
Usage:
  ws recolor [N|SLUG] [--color '#rrggbb'] [--dry-run] [-v]

Arguments:
  N|SLUG      Workspace slug, or its `ws list` index (the # column). If omitted,
              auto-detects from the current directory.

Options:
  --color HEX   Use this exact color instead of picking one.
  --dry-run     Show the old and the new color without changing anything.
  -v, --verbose Show step-by-step detail.
  -h, --help    Show this help.

The new color is picked the way `ws create` picks one: at random from the half
of the unused palette that sits farthest from every color currently in use.
The workspace's own current color counts as "in use", so the result is always
visibly different from what it had.

An open VS Code window recolors itself as soon as the file is written. Things
derived from the color catch up later: the tinted favicons on the next
`ws serve`, the workspace's Chrome (MCP) window on its next launch.

Examples:
  ws recolor                                   # the workspace you're in
  ws recolor 3                                 # by `ws list` index
  ws recolor CU-1234_my-feature --color '#42b5f5'
USAGE
}

# Set one "key": "value" color entry in a .code-workspace file. Only an existing
# key is rewritten — a key the file doesn't carry is left absent.
_recolor_set_key() {
  local file="$1" key="$2" value="$3"
  local key_re="${key//./\\.}"
  sed -i '' -E "s|(\"${key_re}\"[[:space:]]*:[[:space:]]*\")[^\"]*\"|\\1${value}\"|" "$file"
}

cmd_recolor() {
  local slug="" color_override=""
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --color)
        [[ $# -ge 2 && -n "$2" ]] || { err "--color needs a hex color like '#42b5f5'."; exit 1; }
        color_override="$2"; shift 2 ;;
      --dry-run)    DRY_RUN=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_recolor_usage; exit 0 ;;
      -*)           err "Unknown option: $1"; cmd_recolor_usage; exit 1 ;;
      *)
        if [[ -n "$slug" ]]; then
          err "Too many arguments: $1"; cmd_recolor_usage; exit 1
        fi
        slug="$1"; shift ;;
    esac
  done

  # Accept a `ws list` index, like `ws open` and `ws remove` do.
  if [[ "$slug" =~ ^[0-9]+$ ]]; then
    local n=$((10#$slug))
    if (( n == 0 )); then
      err "Index 0 is MAIN — its workspace file is yours to style; recolor only handles task workspaces."
      exit 1
    fi
    local _slugs=() _line
    while IFS= read -r _line; do _slugs+=("$_line"); done < <(workspace_slugs)
    if (( n < 1 || n > ${#_slugs[@]} )); then
      err "Index $n is out of range — 'ws list' shows ${#_slugs[@]} workspace(s) (0 = MAIN)."
      exit 1
    fi
    slug="${_slugs[n - 1]}"
    vlog "Resolved index $n -> $slug"
  fi

  if [[ -z "$slug" ]]; then
    slug="$(slug_from_cwd)" || {
      err "Not inside a workspace directory and no slug provided."
      err "Expected a path under: $WORKSPACES_ROOT/"
      exit 1
    }
    vlog "Auto-detected slug from CWD: $slug"
  fi

  if [[ ! -d "$WORKSPACES_ROOT/$slug" ]]; then
    err "No such workspace: $slug (see 'ws list')."
    exit 1
  fi

  local workspace_file
  workspace_file="$(workspace_file_for "$slug")"
  if [[ ! -f "$workspace_file" ]]; then
    workspace_file="$(legacy_workspace_file_for "$slug")"
  fi
  if [[ ! -f "$workspace_file" ]]; then
    err "No .code-workspace file found for $slug — nothing to recolor."
    exit 1
  fi
  vlog "Workspace file: $workspace_file"

  local old_color
  old_color="$(_ws_color "$slug")"
  if [[ -z "$old_color" ]]; then
    err "$workspace_file has no titleBar.activeBackground color to replace."
    err "Recolor only rewrites existing color keys; it won't restructure a hand-made file."
    exit 1
  fi

  local new_color
  if [[ -n "$color_override" ]]; then
    new_color="#${color_override#\#}"
    if [[ ! "$new_color" =~ ^#[0-9a-fA-F]{6}$ ]]; then
      err "Not a #rrggbb color: $color_override"
      exit 1
    fi
    new_color="$(printf '%s' "$new_color" | tr '[:upper:]' '[:lower:]')"
  else
    # The picker counts every live workspace's color as taken — including this
    # one's current color, which is what keeps the new one well away from it.
    new_color="$(random_workspace_color)"
  fi
  vlog "Color: $old_color -> $new_color"

  local active_fg inactive_fg
  if [[ "$(contrast_foreground "$new_color")" == "dark" ]]; then
    active_fg="#000000"; inactive_fg="#000000cc"
  else
    active_fg="#ffffff"; inactive_fg="#ffffffcc"
  fi

  # Swatches only exist on a terminal; without them the hex codes stand alone.
  local old_label="$old_color" new_label="$new_color" swatch
  swatch="$(_ws_swatch "$old_color")"
  if [[ -n "$swatch" ]]; then
    old_label="$swatch $old_color"
  fi
  swatch="$(_ws_swatch "$new_color")"
  if [[ -n "$swatch" ]]; then
    new_label="$swatch $new_color"
  fi
  local change="$old_label → $new_label"

  if "$DRY_RUN"; then
    printf '[dry-run] recolor %s: %s\n' "$slug" "$change"
    return 0
  fi

  _recolor_set_key "$workspace_file" "titleBar.activeBackground"       "$new_color"
  _recolor_set_key "$workspace_file" "titleBar.inactiveBackground"     "$new_color"
  _recolor_set_key "$workspace_file" "titleBar.activeForeground"       "$active_fg"
  _recolor_set_key "$workspace_file" "titleBar.inactiveForeground"     "$inactive_fg"
  _recolor_set_key "$workspace_file" "commandCenter.foreground"        "$active_fg"
  _recolor_set_key "$workspace_file" "commandCenter.activeForeground"  "$active_fg"
  _recolor_set_key "$workspace_file" "commandCenter.inactiveForeground" "$inactive_fg"
  _recolor_set_key "$workspace_file" "commandCenter.border"            "$inactive_fg"
  _recolor_set_key "$workspace_file" "commandCenter.inactiveBorder"    "$inactive_fg"

  if [[ "$(_ws_color "$slug")" != "$new_color" ]]; then
    err "Failed to write the new color into $workspace_file."
    exit 1
  fi

  log_ws_event recolor "$slug" "color=$new_color"
  ok "recolored $slug: $change"

  # Things derived from the color don't follow on their own — say which apply.
  if [[ -f "$WORKSPACES_ROOT/$slug/.favicons/stamp" ]]; then
    printf '    %sfavicons keep the old tint until the next: ws serve %s%s\n' "$C_DIM" "$slug" "$C_RESET"
  fi
  if [[ -d "$HOME/.chrome-mcp/$slug" ]]; then
    printf '    %sthe Chrome (MCP) window picks it up on its next launch%s\n' "$C_DIM" "$C_RESET"
  fi
  return 0
}
