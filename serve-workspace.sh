#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# serve-workspace.sh
#
# Makes a task worktree (created by create-workspace.sh) reachable in the
# browser under its own subdomain, e.g. https://cu-1234.anny.dev, serving BOTH
# the worktree frontend (Nuxt dev servers) and the worktree backend (Laravel)
# under that one host. The backend reuses the MAIN database and all main env
# values; only the self-domain and the dev-server ports are rewritten.
#
# What this script does:
#   1. Copies + rewrites the frontend/backend .env files into the worktree.
#   2. Writes an nginx server block for <sub>.anny.dev (reusing the wildcard
#      *.anny.dev cert) and reloads nginx.
#   3. Sets up dependencies (node_modules symlinked, vendor cloned) — last, so
#      it only runs after everything else succeeded.
#
# It does NOT run the `yarn serve-*` commands — that is left to you.
# -----------------------------------------------------------------------------

# Load configuration (see config.example.sh). WSM_CONFIG can point elsewhere.
# Resolve this script's real dir following symlinks, so it still finds config.sh
# when symlinked onto your PATH (see install.sh).
_src="${BASH_SOURCE[0]}"
while [[ -h "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
CONFIG_FILE="${WSM_CONFIG:-$SCRIPT_DIR/config.sh}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  printf 'ERROR: config file not found: %s\n' "$CONFIG_FILE" >&2
  printf 'Copy config.example.sh to config.sh and edit it (or set WSM_CONFIG).\n' >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Lowercased task-id prefix, used for case-insensitive slug matching.
TASK_ID_PREFIX_LC="$(printf '%s' "$TASK_ID_PREFIX" | tr '[:upper:]' '[:lower:]')"

# Dots escaped so BASE_DOMAIN can be dropped into the env-rewriting sed regexes.
BASE_DOMAIN_RE="${BASE_DOMAIN//./\\.}"

DRY_RUN=false
ALL_APPS=false
FRESH_DEPS=false
VERBOSE=false
FORCE=false
INPUT_SLUG=""

# ------------------------------ app registry --------------------------------
# The registry lives in config.sh as APPS=("key:dir:route:offset" …) and
# DEFAULT_APPS=(…). To add an app: append an entry to APPS. Only apps with a
# matching .env (or .env.example) actually get served.

# Look up field N (2=dir, 3=route, 4=offset) for an app key in the APPS registry.
app_field() {
  local key="$1" idx="$2" entry
  for entry in "${APPS[@]}"; do
    if [[ "${entry%%:*}" == "$key" ]]; then
      printf '%s' "$entry" | cut -d: -f"$idx"
      return 0
    fi
  done
  return 1
}

app_dir()    { app_field "$1" 2; }  # frontend directory under the frontend repo
app_route()  { app_field "$1" 3; }  # nginx location prefix
app_offset() { app_field "$1" 4; }  # port offset within the per-workspace block

# Every app key defined in the registry, one per line.
all_app_keys() {
  local entry
  for entry in "${APPS[@]}"; do printf '%s\n' "${entry%%:*}"; done
}

# ------------------------------- helpers ------------------------------------
print_usage() {
  cat <<'USAGE'
Usage:
  serve-workspace.sh [SLUG] [--all-apps] [--fresh-deps] [--dry-run]

Arguments:
  SLUG        The workspace slug (e.g. CU-1234_my-feature). If omitted,
              auto-detects from the current working directory.

Options:
  --all-apps    Serve every known app (admin, shop, account, panels, outlook)
                instead of just admin + shop.
  --fresh-deps  Run `yarn install` / `composer install` in the worktree instead
                of symlinking node_modules / cloning vendor from the main repos.
  --force       Regenerate the worktree .env files and rewrite/reload the nginx
                block even if they already exist (overwrites manual edits).
  --dry-run     Print all actions (incl. the nginx block) without executing.
  -v, --verbose Show nginx's own output/warnings (hidden by default on success).
  -h, --help    Show this help.

Notes:
  - Only CU- task workspaces are supported. The subdomain is derived from the
    task id: CU-1234_my-feature -> cu-1234.anny.dev. If the derived subdomain
    is not of the form cu-<alnum>, the script aborts.
  - Safe to re-run: it keeps existing envs, and only touches nginx (and prompts
    for sudo) when the routing block actually changes. Use --force to refresh.
  - Does NOT start the dev servers; it prints the `yarn serve-*` commands to run.
USAGE
}

log()  { printf '[serve] %s\n' "$*"; }
err()  { printf '[serve] ERROR: %s\n' "$*" >&2; }
warn() { printf '[serve] WARN: %s\n' "$*" >&2; }

run_cmd() {
  if "$DRY_RUN"; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }
}

parse_args() {
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all-apps)   ALL_APPS=true; shift ;;
      --fresh-deps) FRESH_DEPS=true; shift ;;
      --force)      FORCE=true; shift ;;
      --dry-run)    DRY_RUN=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    print_usage; exit 0 ;;
      -*)           err "Unknown option: $1"; print_usage; exit 1 ;;
      *)            positional+=("$1"); shift ;;
    esac
  done
  if [[ ${#positional[@]} -gt 1 ]]; then
    err "Expected at most one positional argument (slug)."; exit 1
  fi
  # NB: use an if-block (not `[[ … ]] && …`) so the function never returns a
  # non-zero status as its last command, which would trip `set -e` in main.
  if [[ ${#positional[@]} -eq 1 ]]; then
    INPUT_SLUG="${positional[0]}"
  fi
}

detect_slug_from_cwd() {
  local cwd="$PWD"
  if [[ "$cwd" != "$WORKTREES_ROOT/"* ]]; then
    err "Not inside a worktree directory and no slug provided."
    err "Expected a path under: $WORKTREES_ROOT/"
    exit 1
  fi
  local relative="${cwd#"$WORKTREES_ROOT/"}"
  INPUT_SLUG="${relative%%/*}"
  log "Auto-detected slug from CWD: $INPUT_SLUG"
}

# Derive the subdomain label from the slug's task id and validate the pattern.
resolve_subdomain() {
  local slug="$1"
  local task_id="${slug%%_*}"          # CU-1234_feature -> CU-1234
  local sub
  sub="$(printf '%s' "$task_id" | tr '[:upper:]' '[:lower:]')"
  if [[ ! "$sub" =~ ^cu-[a-z0-9]+$ ]]; then
    err "Refusing to serve '$slug': derived subdomain '$sub' is not of the form cu-<alnum>."
    err "serve-workspace only supports CU- task workspaces (CU-<id>_<name>)."
    exit 1
  fi
  printf '%s' "$sub"
}

# Deterministic per-workspace port block base, derived from the subdomain so the
# same task always maps to the same ports (idempotent) and different tasks get
# different blocks (so several workspaces can run at once).
compute_port_base() {
  local key="$1" h
  h="$(printf '%s' "$key" | cksum | cut -d' ' -f1)"
  printf '%s' "$(( PORT_RANGE_START + (h % 2000) * 10 ))"
}

port_for() { printf '%s' "$(( PORT_BASE + $(app_offset "$1") ))"; }

# Set KEY=VALUE in an env file (replace if present, append otherwise).
set_env_var() {
  local file="$1" key="$2" val="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i '' -E "s#^${key}=.*#${key}=${val}#" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >>"$file"
  fi
}

# --------------------------- env preparation --------------------------------
# Copy the ENTIRE main env, then rewrite the self-domain (anny.dev -> subdomain)
# and the dev-server port. Shared infra (socket.anny.dev, cognitor.dev,
# anny.co, DB, APP_KEY, mail, …) is left pointing at main. ECHO_HOST_URL is left
# untouched so realtime keeps using the shared soketi on the main host.
prepare_frontend_env() {
  local app_key="$1" host="$2"
  local dir port main_env wt_env
  dir="$(app_dir "$app_key")"
  port="$(port_for "$app_key")"
  main_env="$FRONTEND_REPO/$dir/.env"
  wt_env="$WT_FRONTEND/$dir/.env"

  # This worktree's branch may not contain every app that exists on main.
  if [[ ! -d "$WT_FRONTEND/$dir" ]]; then
    warn "App '$dir' does not exist in this worktree — skipping app '$app_key'."
    return 1
  fi

  # Idempotent: keep an existing worktree env (and any manual edits) unless --force.
  if [[ -f "$wt_env" ]] && ! "$FORCE"; then
    log "Frontend env already present: $dir/.env (keeping existing; use --force to regenerate)."
    return 0
  fi

  if [[ ! -f "$main_env" ]]; then
    main_env="$FRONTEND_REPO/$dir/.env.example"
    [[ -f "$main_env" ]] || { warn "No .env or .env.example for $dir — skipping app '$app_key'."; return 1; }
    warn "$dir has no .env; falling back to .env.example."
  fi

  if "$DRY_RUN"; then
    printf '[dry-run] cp %s %s ; set PORT=%s ; rewrite host -> %s\n' "$main_env" "$wt_env" "$port" "$host"
    return 0
  fi

  cp "$main_env" "$wt_env"
  set_env_var "$wt_env" HOST "127.0.0.1"
  set_env_var "$wt_env" PORT "$port"
  # Rewrite the self-domain everywhere except the realtime host (ECHO_HOST_URL).
  sed -i '' -E "/^ECHO_HOST_URL=/!s#https://${BASE_DOMAIN_RE}#https://${host}#g" "$wt_env"
  log "Frontend env ready: $dir (.env, PORT=$port, host=$host)"
  return 0
}

prepare_backend_env() {
  local host="$1"
  local main_env="$BACKEND_REPO/.env"
  local wt_env="$WT_BACKEND/.env"
  [[ -f "$main_env" ]] || { err "Main backend .env not found: $main_env"; exit 1; }

  # Idempotent: keep an existing worktree env (and any manual edits) unless --force.
  if [[ -f "$wt_env" ]] && ! "$FORCE"; then
    log "Backend env already present (keeping existing; use --force to regenerate)."
    return 0
  fi

  if "$DRY_RUN"; then
    printf '[dry-run] cp %s %s ; rewrite APP_URL/CLIENT_URLs host -> %s (DB + rest kept)\n' "$main_env" "$wt_env" "$host"
    return 0
  fi

  cp "$main_env" "$wt_env"
  # Self-domain -> subdomain (APP_URL, *_CLIENT_URL, OUTLOOK_ADD_IN_BASE_URL, …).
  # DB_*, APP_KEY, socket.anny.dev, cognitor.dev, anny.co, mail, etc. are untouched.
  sed -i '' -E "s#https://${BASE_DOMAIN_RE}#https://${host}#g" "$wt_env"
  log "Backend env ready: reuses main DB, APP_URL=https://${host}"
}

# ------------------------------ nginx block ---------------------------------
# NOTE: built with printf / plain (uncaptured) heredocs on purpose — macOS ships
# bash 3.2, whose parser mishandles heredocs nested inside $(...) command
# substitution, so we never capture a heredoc into a variable here.
emit_frontend_location() {
  local route="$1" port="$2"
  printf '%s\n' \
"    location ${route} {" \
"        proxy_pass http://127.0.0.1:${port};" \
"        proxy_http_version 1.1;" \
"        proxy_set_header Host \$host;" \
"        proxy_set_header X-Real-IP \$remote_addr;" \
"        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
"        proxy_set_header X-Forwarded-Proto \$scheme;" \
"        proxy_set_header Upgrade \$http_upgrade;" \
"        proxy_set_header Connection \"upgrade\";" \
"    }"
}

# Render the full nginx server block to stdout (never captured into a var).
render_nginx_block() {
  local host="$1" locations="$2"
  cat <<EOF
# Managed by serve-workspace.sh — task workspace ${host}
# Frontend paths proxy to the worktree Nuxt dev servers; everything else is the
# worktree Laravel backend (served via valet php-fpm, sharing the main DB).
server {
    listen 127.0.0.1:80;
    server_name ${host};
    return 301 https://\$host\$request_uri;
}

server {
    listen 127.0.0.1:443 ssl;
    http2 on;
    server_name ${host};
    charset utf-8;
    client_max_body_size 512M;

    ssl_certificate "${VALET_CERT}";
    ssl_certificate_key "${VALET_CERT_KEY}";

    # --- worktree frontend (Nuxt dev servers) ---
${locations}
    # --- worktree backend (Laravel, shares the main DB) ---
    root "${WT_BACKEND}/public";
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ [^/]\.php(/|\$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        fastcgi_pass "unix:${VALET_PHP_SOCK}";
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
    }

    location ~ /\.ht { deny all; }

    access_log off;
    error_log "${VALET_LOG}";
}
EOF
}

# Run an nginx command, hiding its (noisy, valet-wide) deprecation warnings on
# success. Output is shown only with --verbose, or always when the command fails.
run_nginx() {
  local out status=0
  # `|| status=$?` keeps `set -e` from aborting on a failed nginx command, so we
  # can print its captured output ourselves before returning the error.
  out="$(sudo nginx "$@" 2>&1)" || status=$?
  if [[ $status -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    return "$status"
  fi
  if "$VERBOSE"; then
    printf '%s\n' "$out"
  fi
  return 0
}

# Idempotent: write the nginx block and reload ONLY when its content changed
# (or --force). An unchanged re-run touches nothing and needs no sudo/reload.
ensure_nginx() {
  local host="$1"; shift
  local -a apps=("$@")
  local conf="$VALET_NGINX_DIR/$host"

  local locations="" app route port
  for app in "${apps[@]}"; do
    route="$(app_route "$app")"
    port="$(port_for "$app")"
    locations+="$(emit_frontend_location "$route" "$port")"$'\n'
  done

  local expected
  expected="$(render_nginx_block "$host" "$locations")"

  if "$DRY_RUN"; then
    printf '[dry-run] ensure nginx block %s (write + reload only if changed):\n' "$conf"
    printf '%s\n' "$expected" | sed 's/^/    | /'
    return 0
  fi

  if ! "$FORCE" && [[ -f "$conf" && "$(cat "$conf")" == "$expected" ]]; then
    log "nginx routing already up to date — no rewrite/reload needed."
    return 0
  fi

  printf '%s\n' "$expected" >"$conf"
  log "Wrote nginx block: $conf"

  # Reload needs sudo — only prompted here, i.e. only when something changed.
  log "Requesting sudo (needed to reload nginx)…"
  sudo -v || { err "sudo is required to reload nginx."; exit 1; }
  run_nginx -t || { err "nginx config test failed — not reloading."; exit 1; }
  run_nginx -s reload || { err "nginx reload failed."; exit 1; }
  log "nginx reloaded."
}

# ------------------------------ dependencies --------------------------------
setup_dependencies() {
  # Copy the gitignored root yarn env FIRST — .yarnrc.yml resolves private
  # registry tokens (ANNY_NPM_TOKEN, FONTAWESOME_NPM_TOKEN) from it, and Yarn 4
  # auto-loads .env.yarn, so every yarn command (incl. `yarn install` below and
  # the `yarn serve-*` you run later) needs it present.
  if [[ -f "$FRONTEND_REPO/.env.yarn" && ! -f "$WT_FRONTEND/.env.yarn" ]]; then
    run_cmd cp "$FRONTEND_REPO/.env.yarn" "$WT_FRONTEND/.env.yarn"
  fi

  if "$FRESH_DEPS"; then
    log "Installing fresh dependencies (this can take a while)…"
    run_cmd bash -c "cd '$WT_FRONTEND' && yarn install"
    run_cmd bash -c "cd '$WT_BACKEND' && composer install"
  else
    # Frontend: symlink each main node_modules dir into the worktree (safe —
    # Node resolves modules relative to the importing file, no base-dir remap).
    # Skip any whose worktree parent is absent (this branch may lack newer apps)
    # and never let a single ln failure abort the whole step.
    local nm rel target parent
    while IFS= read -r nm; do
      rel="${nm#"$FRONTEND_REPO"/}"
      target="$WT_FRONTEND/$rel"
      parent="$(dirname "$target")"
      if [[ ! -d "$parent" ]]; then
        log "Skipping node_modules for '$rel' (not in this worktree)."
        continue
      fi
      if [[ -e "$target" || -L "$target" ]]; then
        log "node_modules already present: $rel (skipping)"
        continue
      fi
      run_cmd ln -s "$nm" "$target" || warn "Failed to symlink node_modules for '$rel'."
    done < <(find "$FRONTEND_REPO" -maxdepth 2 -name node_modules -type d)

    # Backend: CLONE vendor (copy-on-write) rather than symlink. A symlinked
    # vendor makes Composer's autoloader resolve its base dir to the MAIN repo
    # (PHP realpaths __DIR__), so the worktree would run main's backend code.
    if [[ -e "$WT_BACKEND/vendor" ]]; then
      log "vendor already present in worktree (skipping)."
    elif "$DRY_RUN"; then
      printf '[dry-run] cp -Rc %s %s (clone vendor)\n' "$BACKEND_REPO/vendor" "$WT_BACKEND/vendor"
    else
      cp -Rc "$BACKEND_REPO/vendor" "$WT_BACKEND/vendor" 2>/dev/null \
        || cp -R "$BACKEND_REPO/vendor" "$WT_BACKEND/vendor"
      log "Cloned vendor into worktree."
    fi
  fi

  # Laravel: ensure writable runtime dirs and drop any stale cached config.
  if ! "$DRY_RUN"; then
    mkdir -p "$WT_BACKEND/storage/framework/cache" \
             "$WT_BACKEND/storage/framework/sessions" \
             "$WT_BACKEND/storage/framework/views" \
             "$WT_BACKEND/storage/logs" \
             "$WT_BACKEND/bootstrap/cache"
    chmod -R ug+w "$WT_BACKEND/storage" "$WT_BACKEND/bootstrap/cache" 2>/dev/null || true
    ( cd "$WT_BACKEND" && php artisan config:clear >/dev/null 2>&1 || true )
  fi
}

# --------------------------------- main -------------------------------------
main() {
  parse_args "$@"

  require_command git
  require_command sed
  require_command nginx
  require_command cksum
  if "$FRESH_DEPS"; then require_command yarn; require_command composer; fi

  [[ -f "$VALET_CERT" && -f "$VALET_CERT_KEY" ]] \
    || { err "Wildcard cert not found ($VALET_CERT). Is anny.dev secured in Valet?"; exit 1; }

  [[ -z "$INPUT_SLUG" ]] && detect_slug_from_cwd

  local slug="$INPUT_SLUG"
  local sub host session_dir
  sub="$(resolve_subdomain "$slug")"
  host="${sub}.${BASE_DOMAIN}"

  session_dir="$WORKTREES_ROOT/$slug"
  WT_FRONTEND="$session_dir/$FRONTEND_DIR_NAME"
  WT_BACKEND="$session_dir/$BACKEND_DIR_NAME"

  [[ -d "$WT_FRONTEND" && -d "$WT_BACKEND" ]] \
    || { err "Worktree not found for '$slug'. Run create-workspace.sh first."; exit 1; }

  PORT_BASE="$(compute_port_base "$sub")"

  # Which apps to serve (skip any that lack an env source).
  local -a requested_apps served_apps=()
  if "$ALL_APPS"; then
    local key
    while IFS= read -r key; do requested_apps+=("$key"); done < <(all_app_keys)
  else
    requested_apps=("${DEFAULT_APPS[@]}")
  fi

  log "Slug:      $slug"
  log "Subdomain: https://$host"
  log "Worktree:  $session_dir"
  log "Port base: $PORT_BASE   apps: ${requested_apps[*]}"

  # 1) envs (idempotent: existing worktree envs are kept unless --force)
  local app
  for app in "${requested_apps[@]}"; do
    if prepare_frontend_env "$app" "$host"; then
      served_apps+=("$app")
    fi
  done
  [[ ${#served_apps[@]} -gt 0 ]] || { err "No servable frontend apps found."; exit 1; }
  prepare_backend_env "$host"

  # 2) nginx (idempotent: only rewrites + reloads — and prompts sudo — if changed)
  ensure_nginx "$host" "${served_apps[@]}"

  # 3) dependencies (last — only after routing/env succeeded; guarded/idempotent)
  setup_dependencies

  # summary
  log ""
  log "Status: '$slug' is served at https://$host"
  log "Backend (Laravel) is served from the worktree and shares the main DB."
  log ""
  log "URLs:"
  for app in "${served_apps[@]}"; do
    printf '    %-7s https://%s%s\n' "${app}:" "$host" "$(app_route "$app")"
  done
  log ""
  log "Start the frontend dev server(s) yourself (if not already running):"
  for app in "${served_apps[@]}"; do
    printf '    cd %q && yarn serve-%s\n' "$WT_FRONTEND" "$app"
  done
  log ""
  log "Tear it all down again with: remove-workspace.sh $slug"
}

main "$@"
