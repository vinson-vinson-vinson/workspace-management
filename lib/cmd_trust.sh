# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_trust.sh — `workspaces trust`: one-time sudoers rule so `ws serve`
# can test/reload nginx without a password prompt (same mechanism as
# `valet trust`). The password is entered once to install the rule and is
# never stored anywhere; the rule covers exactly two commands.
# -----------------------------------------------------------------------------

cmd_trust_usage() {
  cat <<'USAGE'
Usage:
  ws trust [--revoke] [--dry-run]

Installs /etc/sudoers.d/workspace-management: a NOPASSWD rule for exactly the
two nginx commands `ws serve` runs (`nginx -t`, `nginx -s reload`), so serving
stops prompting for your password. Asks for the password ONE last time to
install the rule; the password itself is never stored.

Options:
  --revoke      Remove the rule again (back to password prompts).
  --dry-run     Print the rule without installing anything.
  -h, --help    Show this help.

Examples:
  ws trust
  ws trust --revoke
USAGE
}

cmd_trust() {
  DRY_RUN=false
  local revoke=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --revoke)  revoke=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) cmd_trust_usage; exit 0 ;;
      *) err "Unknown argument: $1"; cmd_trust_usage; exit 1 ;;
    esac
  done

  if "$revoke"; then
    if [[ ! -f "$WSM_SUDOERS_FILE" ]]; then
      log "No trust rule installed ($WSM_SUDOERS_FILE) — nothing to revoke."
      exit 0
    fi
    if "$DRY_RUN"; then
      printf '[dry-run] sudo rm -f %s\n' "$WSM_SUDOERS_FILE"
      exit 0
    fi
    log "Requesting sudo (to remove the rule)…"
    sudo rm -f "$WSM_SUDOERS_FILE" || { err "Could not remove $WSM_SUDOERS_FILE."; exit 1; }
    ok "trust revoked — ws serve prompts for sudo again"
    exit 0
  fi

  require_command nginx
  require_command visudo

  # Full resolved path: sudoers matches the exact command string, and the rule
  # must keep working regardless of the invoking shell's PATH.
  local nginx_path rule
  nginx_path="$(command -v nginx)"
  rule="# Managed by \`ws trust\` — lets \`ws serve\` test/reload nginx without a
# password. Exactly these two commands; remove with \`ws trust --revoke\`.
Cmnd_Alias WSM_NGINX = ${nginx_path} -t, ${nginx_path} -s reload
${USER} ALL=(root) NOPASSWD: WSM_NGINX"

  if "$DRY_RUN"; then
    printf '[dry-run] install %s (mode 0440, root:wheel):\n' "$WSM_SUDOERS_FILE"
    printf '%s\n' "$rule" | sed 's/^/    | /'
    exit 0
  fi

  [[ -f "$WSM_SUDOERS_FILE" ]] \
    && vlog "Rule already installed — rewriting (nginx path or user may have changed)."

  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$rule" >"$tmp"
  # Syntax-check BEFORE anything lands in /etc/sudoers.d — a broken sudoers
  # file can lock sudo up entirely.
  if ! visudo -c -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    err "Generated rule failed visudo validation — not installing."
    exit 1
  fi

  log "Requesting sudo (one last time — installs the passwordless rule)…"
  if ! sudo install -m 0440 -o root -g wheel "$tmp" "$WSM_SUDOERS_FILE"; then
    rm -f "$tmp"
    err "Could not install $WSM_SUDOERS_FILE."
    exit 1
  fi
  rm -f "$tmp"
  ok "trusted — ws serve reloads nginx without prompting from now on"
  vlog "Rule file: $WSM_SUDOERS_FILE (revoke with 'ws trust --revoke')"
}
