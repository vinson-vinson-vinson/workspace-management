# shellcheck shell=bash
# -----------------------------------------------------------------------------
# Serving runtime. Everything `ws` serves runs on this machine's 127.0.0.1, in
# one of two ways (RUNTIME in config.sh):
#
#   valet   Laravel Valet's nginx + php-fpm, installed on the Mac (the default,
#           and what every command did before this setting existed)
#   docker  the same two pieces as containers on the HOST network: an nginx
#           ("edge") and the backend's own production php-fpm image with dev
#           settings. Nothing else moves: the Nuxt dev servers still run on the
#           host, MySQL/Redis/etc. are still whatever the main .env points at,
#           and the nginx blocks `ws serve` writes look the same. Reloads need
#           no sudo, and PHP is the version and build production runs.
#
# The helpers below are the only places that know which runtime is active.
# `ws runtime` (cmd_runtime.sh) starts, stops and sets up the docker runtime.
# -----------------------------------------------------------------------------

runtime_is_docker() { [[ "${RUNTIME:-valet}" == "docker" ]]; }

# docker compose for the runtime's generated project.
runtime_compose() {
  docker compose -p ws-runtime -f "$WS_RUNTIME_DIR/compose.yml" "$@"
}

# --- what the nginx blocks say, per runtime --------------------------------
nginx_listen_http()  { if runtime_is_docker; then printf '127.0.0.1:%s' "$WS_HTTP_PORT"; else printf '127.0.0.1:80'; fi; }
nginx_listen_https() { if runtime_is_docker; then printf '127.0.0.1:%s' "$WS_HTTPS_PORT"; else printf '127.0.0.1:443'; fi; }
nginx_fastcgi_pass() { if runtime_is_docker; then printf '127.0.0.1:%s' "$WS_PHP_PORT"; else printf 'unix:%s' "$VALET_PHP_SOCK"; fi; }
# Kept word for word for valet: a changed block makes every existing workspace
# rewrite and reload (with a sudo prompt) on its next serve.
nginx_backend_note() { if runtime_is_docker; then printf 'served via the docker runtime php-fpm'; else printf 'served via valet php-fpm'; fi; }
nginx_error_log()    { if runtime_is_docker; then printf '/dev/stderr'; else printf '%s' "$VALET_LOG"; fi; }
# The certificate as nginx sees it (inside the edge container for docker).
nginx_cert()         { if runtime_is_docker; then printf '/etc/ws-certs/%s' "$(basename "$WS_CERT")"; else printf '%s' "$VALET_CERT"; fi; }
nginx_cert_key()     { if runtime_is_docker; then printf '/etc/ws-certs/%s' "$(basename "$WS_CERT_KEY")"; else printf '%s' "$VALET_CERT_KEY"; fi; }
# The certificate as this machine sees it (for existence checks).
host_cert()          { if runtime_is_docker; then printf '%s' "$WS_CERT"; else printf '%s' "$VALET_CERT"; fi; }
host_cert_key()      { if runtime_is_docker; then printf '%s' "$WS_CERT_KEY"; else printf '%s' "$VALET_CERT_KEY"; fi; }
# Port suffix for URLs when the docker runtime listens somewhere other than 443.
url_port_suffix()    { if runtime_is_docker && [[ "$WS_HTTPS_PORT" != "443" ]]; then printf ':%s' "$WS_HTTPS_PORT"; fi; }

# --- php ---------------------------------------------------------------------
# Run php in DIR: on the host (valet) or inside the runtime's php container at
# the same path (docker). Leading `--env NAME=VALUE` pairs are passed through.
ws_php_in() {
  local dir="$1"; shift
  local -a envs=()
  while [[ "${1:-}" == "--env" ]]; do envs+=("$2"); shift 2; done
  if runtime_is_docker; then
    local -a args=(exec)
    [[ -t 0 && -t 1 ]] || args+=(-T)
    local e
    for e in ${envs[@]+"${envs[@]}"}; do args+=(-e "$e"); done
    runtime_compose "${args[@]}" -w "$dir" php php "$@"
  else
    ( cd "$dir" && env ${envs[@]+"${envs[@]}"} php "$@" )
  fi
}

# True if a `php artisan horizon` runs out of this backend worktree.
runtime_horizon_running() {
  local wt_be="$1" cwds
  # Captured, not piped into grep -q: under pipefail, grep quitting early makes
  # the pipeline fail even on a match.
  cwds="$(runtime_compose exec -T php sh -c '
    for d in /proc/[0-9]*; do
      case "$(tr "\0" " " < "$d/cmdline" 2>/dev/null)" in
        *"artisan horizon"*) readlink "$d/cwd" 2>/dev/null ;;
      esac
    done' 2>/dev/null)" || return 1
  grep -q "^${wt_be}" <<<"$cwds"
}

# One SQL statement against TEST_DB_HOST from inside the php container, for
# machines without a mysql client. Output mimics the client's: the matching
# names for SHOW, "ERROR …" on failure.
runtime_sql() {
  runtime_compose exec -T \
    -e WS_SQL="$1" -e WS_DB_HOST="$TEST_DB_HOST" -e WS_DB_USER="$TEST_DB_USER" -e WS_DB_PASS="$TEST_DB_PASSWORD" \
    php php -r '
      try {
        $pdo = new PDO("mysql:host=" . getenv("WS_DB_HOST"), getenv("WS_DB_USER"), getenv("WS_DB_PASS"),
          [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        $st = $pdo->query(getenv("WS_SQL"));
        foreach (($st ? $st->fetchAll(PDO::FETCH_COLUMN) : []) as $v) echo $v, PHP_EOL;
      } catch (Throwable $e) { echo "ERROR ", $e->getMessage(), PHP_EOL; exit(1); }' 2>&1
}

# --- lifecycle ---------------------------------------------------------------
runtime_running() {
  [[ -f "$WS_RUNTIME_DIR/compose.yml" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' ws-runtime-edge ws-runtime-php 2>/dev/null | tr '\n' ' ')" == "true true " ]]
}

# Host directories the containers need at their real paths: the root, the
# workspaces root and both main repos, minus any that sit inside another.
runtime_mounts() {
  local -a dirs=() kept=()
  local d e inside
  for d in "$ROOT_DIR" "$WORKSPACES_ROOT" "$FRONTEND_REPO" "$BACKEND_REPO"; do
    [[ -d "$d" ]] || continue
    dirs+=("$(cd -P "$d" && pwd)")
  done
  for d in "${dirs[@]}"; do
    inside=false
    for e in "${dirs[@]}"; do
      [[ "$d" != "$e" && "$d" == "$e"/* ]] && inside=true
    done
    "$inside" && continue
    case " ${kept[*]-} " in *" $d "*) continue ;; esac
    kept+=("$d")
  done
  printf '%s\n' "${kept[@]}"
}

# Write compose.yml, nginx.conf and the php overrides into WS_RUNTIME_DIR.
# Generated from config.sh on every `ws runtime up`, so editing them by hand is
# pointless; change config.sh instead.
runtime_write_files() {
  [[ -n "$WS_PHP_IMAGE" ]] || {
    err "WS_PHP_IMAGE isn't set. The docker runtime runs your backend's production php-fpm image; name it in config.sh:"
    printf '  WS_PHP_IMAGE="<registry>/<backend>/php-fpm:<tag>"\n' >&2
    return 1
  }
  local rt="$WS_RUNTIME_DIR" m
  mkdir -p "$rt/sites"
  local cert_dir; cert_dir="$(dirname "$WS_CERT")"
  {
    printf '# Generated by `ws runtime` from config.sh. Do not edit: it is rewritten on every `ws runtime up`.\n'
    printf 'name: ws-runtime\n'
    printf 'services:\n'
    printf '  edge:\n'
    printf '    container_name: ws-runtime-edge\n'
    printf '    image: "%s"\n' "$WS_EDGE_IMAGE"
    printf '    network_mode: host\n'
    printf '    restart: unless-stopped\n'
    printf '    volumes:\n'
    printf '      - "%s/nginx.conf:/etc/nginx/nginx.conf:ro"\n' "$rt"
    printf '      - "%s/sites:/etc/nginx/ws-sites:ro"\n' "$rt"
    printf '      - "%s:/etc/ws-certs:ro"\n' "$cert_dir"
    while IFS= read -r m; do printf '      - "%s:%s:ro"\n' "$m" "$m"; done < <(runtime_mounts)
    printf '  php:\n'
    printf '    container_name: ws-runtime-php\n'
    printf '    image: "%s"\n' "$WS_PHP_IMAGE"
    printf '    network_mode: host\n'
    printf '    restart: unless-stopped\n'
    printf '    environment:\n'
    printf '      PHP_FPM_PORT: "%s"\n' "$WS_PHP_PORT"
    printf '      PHP_FPM_PM: "ondemand"\n'
    printf '      PHP_FPM_MAX_CHILDREN: "16"\n'
    printf '      PHP_FPM_MAX_REQUESTS: "500"\n'
    printf '      PHP_FPM_ACCESS_LOG_DESTINATION: "/dev/null"\n'
    printf '      PHP_FPM_EMERGENCY_RESTART_INTERVAL: "0"\n'
    printf '      PHP_FPM_EMERGENCY_RESTART_THRESHOLD: "0"\n'
    printf '      PHP_FPM_PROCESS_CONTROL_TIMEOUT: "10s"\n'
    printf '      PHP_MAX_EXECUTION_TIME: "300"\n'
    printf '      PHP_OPCACHE_ENABLE: "1"\n'
    printf '      PHP_OPCACHE_MAX_ACCELERATED_FILES: "50000"\n'
    printf '      PHP_OPCACHE_MEMORY_CONSUMPTION: "256"\n'
    printf '      PHP_OPCACHE_REVALIDATE_FREQUENCY: "0"\n'
    printf '      PHP_OPCACHE_VALIDATE_TIMESTAMPS: "1"\n'
    printf '    volumes:\n'
    printf '      - "%s/php.ini:/usr/local/etc/php/conf.d/zz-ws.ini:ro"\n' "$rt"
    printf '      - "%s/fpm-pool.conf:/usr/local/etc/php-fpm.d/zz-ws-pool.conf:ro"\n' "$rt"
    while IFS= read -r m; do printf '      - "%s:%s"\n' "$m" "$m"; done < <(runtime_mounts)
  } > "$rt/compose.yml"

  printf '%s\n' \
    '# Generated by `ws runtime`. Sites are the files `ws serve` writes into sites/.' \
    'worker_processes auto;' \
    'error_log /dev/stderr warn;' \
    'pid /tmp/nginx.pid;' \
    'events { worker_connections 1024; }' \
    'http {' \
    '    include /etc/nginx/mime.types;' \
    '    default_type application/octet-stream;' \
    '    sendfile off;' \
    '    server_names_hash_bucket_size 128;' \
    '    client_max_body_size 512M;' \
    '    proxy_read_timeout 300s;' \
    '    fastcgi_read_timeout 300s;' \
    '    fastcgi_buffers 16 32k;' \
    '    fastcgi_buffer_size 64k;' \
    '    # Unknown hosts land here, and so does the health check `ws runtime up` makes' \
    '    # to be sure these ports reach this nginx and not something else.' \
    '    server {' \
    "        listen 127.0.0.1:${WS_HTTP_PORT} default_server;" \
    "        listen 127.0.0.1:${WS_HTTPS_PORT} ssl default_server;" \
    "        ssl_certificate \"$(nginx_cert)\";" \
    "        ssl_certificate_key \"$(nginx_cert_key)\";" \
    '        location = /__ws_runtime { add_header X-WS-Runtime 1 always; return 204; }' \
    '        location / { return 404; }' \
    '    }' \
    '    include /etc/nginx/ws-sites/*;' \
    '}' > "$rt/nginx.conf"

  # Development on top of the production build: memory and upload limits that
  # match the nginx side. Opcache revalidation comes from the env above.
  printf '%s\n' \
    '; Generated by `ws runtime`.' \
    'memory_limit = 1G' \
    'upload_max_filesize = 512M' \
    'post_max_size = 512M' \
    'display_errors = Off' \
    'log_errors = On' > "$rt/php.ini"

  # Last in php-fpm.d, so it wins: the image's zz-docker.conf also listens on
  # 9000, which on the host network collides with whatever else uses 9000
  # (MinIO, often). ondemand keeps idle workspaces at zero workers.
  printf '%s\n' \
    '; Generated by `ws runtime`.' \
    '[www]' \
    "listen = 127.0.0.1:${WS_PHP_PORT}" \
    'pm = ondemand' \
    'pm.max_children = 16' \
    'pm.process_idle_timeout = 60s' > "$rt/fpm-pool.conf"
}

# The main checkouts at $BASE_DOMAIN, the way `valet link` served them: the main
# backend, plus each app whose main .env names a PORT.
runtime_write_main_site() {
  local conf="$WS_RUNTIME_DIR/sites/$BASE_DOMAIN"
  [[ -d "$BACKEND_REPO/public" ]] || { rm -f "$conf"; return 0; }
  local key dir port locations="" loc
  for key in $(all_app_keys); do
    dir="$(app_dir "$key")"
    port="$(grep -E '^PORT=' "$FRONTEND_REPO/$dir/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')"
    [[ -n "$port" ]] || continue
    loc="$(emit_frontend_location "$(app_route "$key")" "$port")"
    locations="${locations}${loc}"$'\n'
  done
  # shellcheck disable=SC2034  # render_nginx_block reads WT_BACKEND (dynamic scope)
  ( WT_BACKEND="$BACKEND_REPO"; render_nginx_block "$BASE_DOMAIN" "$locations" ) > "$conf"
}

runtime_up() {
  require_command docker
  [[ -f "$WS_CERT" && -f "$WS_CERT_KEY" ]] || {
    err "No certificate for $BASE_DOMAIN at $WS_CERT. Run 'ws runtime setup' once."
    return 1
  }
  runtime_write_files || return 1
  runtime_write_main_site
  spin "starting the docker runtime"
  if ! run_quiet runtime_compose up -d --remove-orphans; then
    spin_stop; err "docker compose up failed (see 'ws runtime logs')."; return 1
  fi
  local deadline=$(( $(date +%s) + 30 )) restarts svc
  while (( $(date +%s) < deadline )); do
    if nc -z -w 1 127.0.0.1 "$WS_PHP_PORT" 2>/dev/null \
       && runtime_answers http "$WS_HTTP_PORT" && runtime_answers https "$WS_HTTPS_PORT"; then
      spin_ok "docker runtime up (nginx on $(nginx_listen_https), php-fpm on 127.0.0.1:$WS_PHP_PORT)"
      return 0
    fi
    # A container that keeps exiting won't come up by waiting: say why now.
    for svc in edge php; do
      restarts="$(docker inspect -f '{{.RestartCount}}' "ws-runtime-$svc" 2>/dev/null || printf 0)"
      if (( restarts > 0 )); then
        spin_stop
        err "The runtime's $svc container keeps exiting:"
        docker logs --tail 20 "ws-runtime-$svc" 2>&1 | grep -iE 'emerg|error|fatal|address' | tail -3 >&2
        [[ "$svc" == edge ]] && err "If a port is in use, free it or set WS_HTTP_PORT/WS_HTTPS_PORT in config.sh."
        return 1
      fi
    done
    sleep 1
  done
  spin_stop
  local scheme port
  for scheme in http https; do
    port="$WS_HTTP_PORT"; [[ "$scheme" == https ]] && port="$WS_HTTPS_PORT"
    runtime_answers "$scheme" "$port" \
      || err "127.0.0.1:$port doesn't reach the runtime's nginx — something else answers there. Free it, or set WS_HTTP_PORT/WS_HTTPS_PORT."
  done
  err "The runtime didn't come up within 30s (see 'ws runtime logs')."
  return 1
}

# True if 127.0.0.1:PORT is answered by the runtime's own nginx.
runtime_answers() {
  local scheme="$1" port="$2" headers
  headers="$(curl -sk -m 2 -o /dev/null -D - -H 'Host: ws-runtime.invalid' "$scheme://127.0.0.1:$port/__ws_runtime" 2>/dev/null)" || return 1
  grep -qi '^x-ws-runtime: 1' <<<"$headers"
}

# Start the runtime if it isn't running. Quiet when it already is.
runtime_ensure_up() {
  runtime_is_docker || return 0
  runtime_running && return 0
  runtime_up
}
