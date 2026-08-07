# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_share.sh — `workspaces share`: expose a served workspace (or main) to
# the internet through your reserved ngrok domain, like `valet share`. Runs in
# the FOREGROUND — the public URL is live only while the command runs; Ctrl-C
# (or closing the terminal) tears it down. Free ngrok = one tunnel at a time.
# -----------------------------------------------------------------------------

cmd_share_usage() {
  cat <<'USAGE'
Usage:
  ws share [SLUG] [--dry-run]

Expose a served workspace — or main — over the internet through your reserved
ngrok domain (NGROK_DOMAIN). Foreground: the URL is live only while this runs;
press Ctrl-C or close the terminal to stop it, like `valet share`.

Arguments:
  SLUG          Workspace to share. Defaults to the one you're in; outside any
                workspace it shares main. Use "main" (or "0") to force main.

Options:
      --dry-run Show the target and the exact ngrok command without running it.
  -h, --help    Show this help.

Needs NGROK_DOMAIN set (your reserved ngrok domain) and an ngrok authtoken
(`ngrok config add-authtoken …`). The target must already be served: a workspace
via `ws serve`, main via your usual Valet setup. Free ngrok is one tunnel at a
time — to switch, stop this one (Ctrl-C) and run `ws share` again.
USAGE
}

cmd_share() {
  DRY_RUN=false
  local slug=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  DRY_RUN=true; shift ;;
      -h|--help)  cmd_share_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_share_usage; exit 1 ;;
      *)  [[ -z "$slug" ]] || { err "Unexpected extra argument: $1"; exit 1; }
          slug="$1"; shift ;;
    esac
  done

  require_command "$NGROK_BIN"
  [[ -n "$NGROK_DOMAIN" ]] || {
    err "NGROK_DOMAIN is not set — add your reserved ngrok domain to config.sh, e.g."
    err '  NGROK_DOMAIN="your-name.ngrok-free.dev"'
    exit 1
  }
  local domain="${NGROK_DOMAIN#http://}"; domain="${domain#https://}"; domain="${domain%/}"

  # Resolve the target: its local host (for the served check + label) and the
  # upstream URL ngrok forwards to. Workspaces are HTTPS behind Valet; main uses
  # whatever NGROK_MAIN_UPSTREAM points at (a plain HTTP endpoint here).
  local host label upstream sub
  if [[ "$slug" == "main" || "$slug" == "MAIN" || "$slug" == "0" ]]; then
    host="$BASE_DOMAIN"; label="main"; upstream="$NGROK_MAIN_UPSTREAM"
  elif [[ -n "$slug" ]]; then
    sub="$(resolve_subdomain "$slug")" || { err "Can't derive a subdomain for '$slug'."; exit 1; }
    host="${sub}.${BASE_DOMAIN}"; label="$slug"; upstream="https://${host}"
  elif slug="$(slug_from_cwd 2>/dev/null)" && [[ -n "$slug" ]]; then
    sub="$(resolve_subdomain "$slug")" || { err "Can't derive a subdomain for '$slug'."; exit 1; }
    host="${sub}.${BASE_DOMAIN}"; label="$slug"; upstream="https://${host}"
  else
    host="$BASE_DOMAIN"; label="main"; upstream="$NGROK_MAIN_UPSTREAM"
  fi

  # Must be served — its nginx block has to exist.
  if [[ ! -f "$VALET_NGINX_DIR/$host" ]]; then
    err "$label is not served ($host has no nginx block)."
    if [[ "$label" == "main" ]]; then err "Start your main site in Valet first."
    else err "Run 'ws serve $label' first."; fi
    exit 1
  fi

  "$NGROK_BIN" config check >/dev/null 2>&1 \
    || warn "ngrok has no valid config/authtoken — run 'ngrok config add-authtoken <token>' if the tunnel fails."

  # --host-header is essential: Valet is name-based virtual hosting (every site
  # shares one IP/port, disambiguated purely by Host). ngrok preserves the
  # incoming Host (the ngrok domain) by default, which matches no site — nginx
  # falls through to its default server (main) or a "Not Found" page, never the
  # workspace. Rewriting Host to the site's own domain is what makes nginx route
  # to the right worktree (this is exactly what `valet share` does).
  #
  # ngrok 3.x also forwards to the HTTPS upstream without verifying the local
  # Valet cert by default, so pointing straight at the served site is fine.
  local -a cmd=( "$NGROK_BIN" http --url="$domain" --host-header="$host" "$upstream" )
  local landing="https://${domain}${ADMIN_PATH}"

  if "$DRY_RUN"; then
    printf '[dry-run] target   : %s\n' "$label"
    printf '[dry-run] upstream : %s\n' "$upstream"
    printf '[dry-run] public   : %s\n' "$landing"
    printf '[dry-run] exec     : %s\n' "${cmd[*]}"
    return 0
  fi

  log "Sharing ${label} -> ${landing}   (Ctrl-C to stop)"
  # Hand the terminal to ngrok; the tunnel lives exactly as long as this command.
  exec "${cmd[@]}"
}
