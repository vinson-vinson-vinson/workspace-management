# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/envs.sh — compare a workspace's .env files against MAIN's. Shared by
# `ws envdiff` (just the report) and `ws remove` (report + backup before the
# worktrees go). Sourced by those two commands, not by common.sh.
#
# A workspace's envs start as copies of MAIN's, so anything that differs was
# added by hand while working there — new keys for an integration, a changed
# value, a commented-out line — and is lost with the worktree unless it was
# ported to MAIN first. These helpers find exactly that, ignoring what
# `ws serve` itself rewrites (the workspace host in every URL, and the pinned
# HOST / PORT / HMR_PORT / STORAGE_PREFIX).
# -----------------------------------------------------------------------------

# Keys `ws serve` pins per workspace — a difference there is expected.
ENV_SERVE_PINNED_KEYS="HOST PORT HMR_PORT STORAGE_PREFIX"

# Keys whose values are masked in terminal output (the backup keeps them whole).
ENV_SECRET_KEY_RE='SECRET|TOKEN|PASS|KEY|PRIVATE|CREDENTIAL'

# The .env files to compare for a workspace, one per line:
#     <label>TAB<workspace file>TAB<main file>
# label is the path relative to the session dir. The backend .env plus every
# frontend app-*/.env that exists in the worktree; .env.yarn is a plain copy of
# MAIN's registry tokens and deliberately out of scope.
env_file_pairs() {
  local session_dir="$1"
  local fe_wt="$session_dir/$FRONTEND_DIR_NAME" be_wt="$session_dir/$BACKEND_DIR_NAME"
  local app_dir app
  if [[ -f "$be_wt/.env" ]]; then
    printf '%s\t%s\t%s\n' "$BACKEND_DIR_NAME/.env" "$be_wt/.env" "$BACKEND_REPO/.env"
  fi
  for app_dir in "$fe_wt"/app-*/; do
    [[ -d "$app_dir" ]] || continue
    app="$(basename "$app_dir")"
    if [[ -f "$app_dir/.env" ]]; then
      printf '%s\t%s\t%s\n' "$FRONTEND_DIR_NAME/$app/.env" "$app_dir/.env" "$FRONTEND_REPO/$app/.env"
    fi
  done
}

# Compare one workspace .env with its MAIN counterpart. Emits one line per
# difference, TAB-separated:
#     add     KEY  WS_VALUE  -            key the MAIN file doesn't have
#     change  KEY  WS_VALUE  MAIN_VALUE   same key, different value
#     nomain  -    -         -            MAIN has no such file at all
# A commented-out line (`#KEY=value`) is an entry of its own, keyed "#KEY", so
# it is compared and reported like any other. Values are compared after the
# workspace host is mapped back to the base domain, and the serve-pinned keys
# are skipped. Needs python3 (bash 3.2 has no maps).
env_compare() {
  local ws_file="$1" main_file="$2" ws_host="$3"
  if [[ ! -f "$main_file" ]]; then
    printf 'nomain\t-\t-\t-\n'
    return 0
  fi
  python3 - "$ws_file" "$main_file" "$ws_host" "$BASE_DOMAIN" "$ENV_SERVE_PINNED_KEYS" <<'PY'
import re, sys
ws_file, main_file, ws_host, base_domain, pinned = sys.argv[1:6]
pinned = set(pinned.split())
LINE = re.compile(r'^(#\s*)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$')

def parse(path):
    order = []
    values = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            m = LINE.match(raw.rstrip("\n"))
            if not m:
                continue
            key = m.group(2)
            if m.group(1):
                key = "#" + key
            if key not in values:
                order.append(key)
            values[key] = m.group(3).rstrip()
    return order, values

def norm(value):
    if ws_host:
        value = re.sub(re.escape(ws_host), base_domain, value, flags=re.IGNORECASE)
    return value

ws_order, ws = parse(ws_file)
_, main = parse(main_file)
for key in ws_order:
    if key.lstrip("#") in pinned:
        continue
    if key not in main:
        print("add\t%s\t%s\t-" % (key, ws[key]))
    elif norm(ws[key]) != norm(main[key]):
        print("change\t%s\t%s\t%s" % (key, ws[key], main[key]))
PY
}

# Mask a value for terminal output when its key looks secret.
_env_display_value() {
  local key="${1#\#}" value="$2"
  if [[ -z "$value" ]]; then
    printf '<empty>'
    return 0
  fi
  if "$ENV_SHOW_SECRETS"; then
    printf '%s' "$value"
    return 0
  fi
  if [[ ! "$key" =~ $ENV_SECRET_KEY_RE ]]; then
    printf '%s' "$value"
    return 0
  fi
  if (( ${#value} >= 8 )); then
    printf '••••••••%s' "${value: -4}"
  else
    printf '••••••••'
  fi
}

# Print the report for one workspace. Sets ENV_DIFF_COUNT to the number of
# differences found (0 = every env matches MAIN beyond serve's rewrites).
# $1 slug, $2 session dir, $3 "terminal" (colored, masked) or "plain" (for the
# backup's DIFF.txt — everything in full).
ENV_SHOW_SECRETS="${ENV_SHOW_SECRETS:-false}"
ENV_DIFF_COUNT=0
env_report() {
  local slug="$1" session_dir="$2" style="${3:-terminal}"
  local sub ws_host="" label ws_file main_file kind key wsv mainv
  local dim="" reset="" add="" chg="" cmt=""
  if [[ "$style" == "terminal" ]]; then
    dim="$C_DIM"; reset="$C_RESET"; add="$C_GREEN"; chg="$C_YELLOW"; cmt="$C_DIM"
  fi
  if sub="$(resolve_subdomain "$slug" 2>/dev/null)"; then
    ws_host="${sub}.${BASE_DOMAIN}"
  fi
  ENV_DIFF_COUNT=0
  local shown_label
  while IFS=$'\t' read -r label ws_file main_file; do
    [[ -n "$label" ]] || continue
    shown_label=false
    while IFS=$'\t' read -r kind key wsv mainv; do
      [[ -n "$kind" ]] || continue
      ENV_DIFF_COUNT=$((ENV_DIFF_COUNT + 1))
      if ! "$shown_label"; then
        printf '    %s%s%s\n' "$dim" "$label" "$reset"
        shown_label=true
      fi
      case "$kind" in
        nomain)
          printf '      %s(no such file in MAIN — whole file is workspace-only)%s\n' "$chg" "$reset" ;;
        add)
          if [[ "$key" == \#* ]]; then
            printf '      %s# %s = %s   (commented out)%s\n' "$cmt" "${key#\#}" "$(_env_display_value "$key" "$wsv")" "$reset"
          else
            printf '      %s+ %s%s = %s\n' "$add" "$key" "$reset" "$(_env_display_value "$key" "$wsv")"
          fi ;;
        change)
          if [[ "$key" == \#* ]]; then
            printf '      %s~ # %s = %s   (commented out; MAIN: %s)%s\n' "$cmt" "${key#\#}" \
              "$(_env_display_value "$key" "$wsv")" "$(_env_display_value "$key" "$mainv")" "$reset"
          else
            printf '      %s~ %s%s = %s   %s(MAIN: %s)%s\n' "$chg" "$key" "$reset" \
              "$(_env_display_value "$key" "$wsv")" "$dim" "$(_env_display_value "$key" "$mainv")" "$reset"
          fi ;;
      esac
    done < <(env_compare "$ws_file" "$main_file" "$ws_host")
  done < <(env_file_pairs "$session_dir")
  return 0
}

# Copy every compared .env into ENV_BACKUP_DIR/<slug>/ (flat: bookings-api.env,
# app-admin.env, …) plus DIFF.txt with the unmasked report. An existing backup
# for the slug is moved aside, never overwritten. Returns non-zero when a copy
# fails — the caller must then abort the removal.
env_backup() {
  local slug="$1" session_dir="$2"
  local dest="$ENV_BACKUP_DIR/$slug" label ws_file main_file name n=0
  if [[ -e "$dest" ]]; then
    local aside="$dest.bak-$(date +%s)"
    mv "$dest" "$aside" || return 1
    vlog "Previous env backup moved aside: $aside"
  fi
  mkdir -p "$dest" || return 1
  while IFS=$'\t' read -r label ws_file main_file; do
    [[ -n "$label" ]] || continue
    name="$(basename "$(dirname "$ws_file")").env"
    cp "$ws_file" "$dest/$name" || return 1
    n=$((n + 1))
  done < <(env_file_pairs "$session_dir")
  {
    printf 'envs of %s vs MAIN — %s\n' "$slug" "$(date '+%Y-%m-%d %H:%M')"
    printf '(serve-pinned keys and the workspace host in URLs are ignored)\n\n'
    ENV_SHOW_SECRETS=true env_report "$slug" "$session_dir" plain
    if (( ENV_DIFF_COUNT == 0 )); then
      printf '    no differences\n'
    fi
  } > "$dest/DIFF.txt" || return 1
  ENV_BACKUP_FILES=$n
  ENV_BACKUP_DEST="$dest"
  return 0
}
ENV_BACKUP_FILES=0
ENV_BACKUP_DEST=""
