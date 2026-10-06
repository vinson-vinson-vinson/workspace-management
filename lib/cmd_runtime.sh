# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_runtime.sh — `ws runtime`: the docker runtime's lifecycle.
#
# With RUNTIME=docker, nginx and the backend's php-fpm image run as containers
# on the host network and serve every workspace (and the main checkouts at
# BASE_DOMAIN) on 127.0.0.1, the way Valet does. See lib/runtime.sh.
# -----------------------------------------------------------------------------

# The app registry and render_nginx_block, for the main site.
# shellcheck source=/dev/null
source "$LIB_DIR/cmd_serve.sh"

cmd_runtime_usage() {
  cat <<'USAGE'
Usage:
  ws runtime [up|down|restart|status|logs [edge|php]|setup|pull] [options]

Manages the docker runtime (RUNTIME=docker in config.sh): nginx and the
backend's php-fpm image, as containers on the host network.

  setup      one-time: a certificate for BASE_DOMAIN and *.BASE_DOMAIN, a DNS
             check, a port check, and the image pull
  up         write the runtime config from config.sh and start it (default)
  down       stop and remove the containers (worktrees and routing stay)
  restart    down, then up
  status     containers, ports and the sites they serve
  logs       follow the logs, of both containers or of one
  pull       pull the images again (after changing WS_PHP_IMAGE)

Options:
  --self-signed   setup: make a self-signed certificate when mkcert is missing
                  (browsers will warn; curl needs -k)
  -v, --verbose   show docker's own output
  -h, --help      show this help

`ws serve` starts the runtime when it isn't running, so `up` is rarely needed.
USAGE
}

_runtime_require_docker_mode() {
  runtime_is_docker && return 0
  err "RUNTIME is '$RUNTIME' in config.sh. Set RUNTIME=\"docker\" to use the docker runtime."
  exit 1
}

# Who listens on a TCP port, or nothing.
_port_owner() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}'
}

_runtime_setup_cert() {
  local self_signed="$1"
  if [[ -f "$WS_CERT" && -f "$WS_CERT_KEY" ]]; then
    ok "certificate: $WS_CERT"
    return 0
  fi
  mkdir -p "$(dirname "$WS_CERT")"
  if command -v mkcert >/dev/null 2>&1; then
    run_quiet mkcert -cert-file "$WS_CERT" -key-file "$WS_CERT_KEY" "$BASE_DOMAIN" "*.$BASE_DOMAIN" \
      || { err "mkcert failed."; return 1; }
    ok "certificate: $WS_CERT (mkcert; run 'mkcert -install' once if browsers don't trust it yet)"
    return 0
  fi
  if "$self_signed"; then
    run_quiet openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
      -keyout "$WS_CERT_KEY" -out "$WS_CERT" -subj "/CN=$BASE_DOMAIN" \
      -addext "subjectAltName=DNS:$BASE_DOMAIN,DNS:*.$BASE_DOMAIN" \
      || { err "openssl failed."; return 1; }
    warn "certificate: self-signed ($WS_CERT). Browsers will warn until you use mkcert instead."
    return 0
  fi
  err "No certificate for $BASE_DOMAIN, and mkcert isn't installed."
  printf '  brew install mkcert && mkcert -install && ws runtime setup\n' >&2
  printf '  (or: ws runtime setup --self-signed, which browsers will warn about)\n' >&2
  return 1
}

_runtime_check_dns() {
  local probe="ws-dns-check.$BASE_DOMAIN" addr tld="${BASE_DOMAIN##*.}"
  addr="$(python3 -c 'import socket,sys
try: print(socket.getaddrinfo(sys.argv[1], 443)[0][4][0])
except Exception: pass' "$probe" 2>/dev/null)"
  case "$addr" in
    127.0.0.1|::1)
      ok "DNS: *.$BASE_DOMAIN resolves to this machine"
      return 0 ;;
  esac
  warn "DNS: *.$BASE_DOMAIN doesn't resolve to 127.0.0.1. Valet sets this up; without Valet, once:"
  printf '  brew install dnsmasq\n' >&2
  printf '  echo "address=/.%s/127.0.0.1" >> "$(brew --prefix)/etc/dnsmasq.conf"\n' "$tld" >&2
  printf '  sudo brew services start dnsmasq\n' >&2
  printf '  sudo mkdir -p /etc/resolver && echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/%s\n' "$tld" >&2
  return 0
}

_runtime_check_ports() {
  local port owner bad=false
  for port in "$WS_HTTP_PORT" "$WS_HTTPS_PORT" "$WS_PHP_PORT"; do
    owner="$(_port_owner "$port")"
    if [[ -z "$owner" ]] || runtime_running; then
      continue
    fi
    bad=true
    warn "port $port is taken by '$owner'."
  done
  if "$bad"; then
    printf '  If that is Valet: valet stop. Or move the runtime: WS_HTTP_PORT / WS_HTTPS_PORT / WS_PHP_PORT in config.sh.\n' >&2
    return 1
  fi
  ok "ports: $WS_HTTP_PORT, $WS_HTTPS_PORT and $WS_PHP_PORT are free"
}

_runtime_pull() {
  runtime_write_files || return 1
  spin "pulling images (the php image is large the first time)"
  if run_quiet runtime_compose pull; then
    spin_ok "images pulled"
    return 0
  fi
  spin_stop
  local registry="${WS_PHP_IMAGE%%/*}"
  [[ "$WS_PHP_IMAGE" == */* && "$registry" == *[.:]* ]] || registry=""
  err "Pulling failed. If the image is in a private registry, log in to it once:"
  printf '  docker login %s\n' "$registry" >&2
  return 1
}

_runtime_status() {
  printf '%sruntime%s  %s  %s(%s)%s\n' "$C_BOLD" "$C_RESET" "$RUNTIME" "$C_DIM" "$WS_RUNTIME_DIR" "$C_RESET"
  if [[ ! -f "$WS_RUNTIME_DIR/compose.yml" ]]; then
    printf '  not set up yet: ws runtime setup\n'
    return 0
  fi
  runtime_compose ps --format '  {{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null || true
  local port owner
  for port in "$WS_HTTPS_PORT" "$WS_PHP_PORT"; do
    owner="$(_port_owner "$port")"
    printf '  port %-6s %s\n' "$port" "${owner:-free}"
  done
  local site
  printf '  sites:\n'
  for site in "$WS_RUNTIME_DIR"/sites/*; do
    [[ -e "$site" ]] || { printf '    (none)\n'; break; }
    printf '    https://%s%s\n' "$(basename "$site")" "$(url_port_suffix)"
  done
}

# shellcheck disable=SC2034  # VERBOSE is read by run_quiet in common.sh
cmd_runtime() {
  local action="up" self_signed=false service=""
  VERBOSE=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      up|down|restart|status|logs|setup|pull) action="$1"; shift ;;
      edge|php) service="$1"; shift ;;
      --self-signed) self_signed=true; shift ;;
      -v|--verbose)  VERBOSE=true; shift ;;
      -h|--help)     cmd_runtime_usage; exit 0 ;;
      *) err "Unknown argument: $1"; cmd_runtime_usage; exit 1 ;;
    esac
  done

  if [[ "$action" == "status" ]]; then _runtime_status; return 0; fi
  _runtime_require_docker_mode
  require_command docker

  case "$action" in
    setup)
      _runtime_setup_cert "$self_signed" || exit 1
      _runtime_check_dns
      _runtime_check_ports || true
      _runtime_pull || exit 1
      runtime_up || exit 1
      ;;
    up)      runtime_up || exit 1 ;;
    down)    run_quiet runtime_compose down --remove-orphans && ok "docker runtime stopped" ;;
    restart) run_quiet runtime_compose down --remove-orphans; runtime_up || exit 1 ;;
    pull)    _runtime_pull || exit 1 ;;
    logs)    runtime_compose logs -f --tail 100 ${service:+"$service"} ;;
  esac
}
