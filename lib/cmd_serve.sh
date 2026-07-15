# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_serve.sh — `workspaces serve`: make a worktree reachable at its own
# subdomain (<sub>.$BASE_DOMAIN) via Valet/nginx, serving BOTH the worktree
# frontend (Nuxt dev servers) and backend (Laravel) under one host. The backend
# reuses the MAIN database; only the self-domain and dev-server ports change.
#
# What it does:
#   1. Copies + rewrites the frontend/backend .env files into the worktree.
#   2. Writes an nginx server block for <sub>.$BASE_DOMAIN and reloads nginx.
#   3. Installs deps (frontend `yarn`, backend vendor clone), generates the Nuxt
#      scaffolding, seeds the backend's Cognitor JWT key — last.
# It does NOT run the `yarn serve-*` commands — that is left to you.
# -----------------------------------------------------------------------------

cmd_serve_usage() {
  cat <<'USAGE'
Usage:
  ws serve [SLUG] [--all-apps] [--force] [--dry-run] [-v]

Arguments:
  SLUG        Workspace slug. If omitted, auto-detects from the current directory.

Options:
  --all-apps    Serve every known app (admin, shop, account, panels, outlook)
                instead of just admin + shop.
  --force       Regenerate the worktree .env files and rewrite/reload the nginx
                block even if they already exist (overwrites manual edits).
  --dry-run     Print all actions (incl. the nginx block) without executing.
  -v, --verbose Show nginx's own output/warnings (hidden by default on success).
  -h, --help    Show this help.

Notes:
  - Works for any workspace name. The subdomain is derived from the slug: a task
    workspace CU-1234_my-feature -> cu-1234; a plain workspace admin-test ->
    admin-test. Names are lowercased and non-DNS characters collapsed to '-'.
  - Refuses to serve a worktree that is on a protected base branch (main/master
    or your configured base branch), so it never overwrites your main setup.
  - Safe to re-run: it keeps existing envs, and only touches nginx (and prompts
    for sudo) when the routing block actually changes. Use --force to refresh.
  - Does NOT start the dev servers; it prints the `yarn serve-*` commands to run.
USAGE
}

# Set to false by any dependency step that didn't fully succeed, so we never
# claim "dependencies installed successfully" over the top of a warning.
DEPS_OK=true

# ------------------------------ app registry --------------------------------
# The registry lives in config.sh as APPS=("key:dir:route:offset" …) and
# DEFAULT_APPS=(…). Only apps with a matching .env (or .env.example) get served.
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

all_app_keys() {
  local entry
  for entry in "${APPS[@]}"; do printf '%s\n' "${entry%%:*}"; done
}

# Deterministic per-workspace port block base, derived from the subdomain so the
# same task always maps to the same ports and different tasks get different
# blocks (so several workspaces can run at once).
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
# Copy the ENTIRE main env, then rewrite the self-domain and dev-server port.
# Shared infra (socket.anny.dev, cognitor.dev, anny.co, DB, APP_KEY, mail, …) is
# left pointing at main. ECHO_HOST_URL is untouched so realtime keeps using the
# shared soketi on the main host.
prepare_frontend_env() {
  local app_key="$1" host="$2"
  local dir port main_env wt_env
  dir="$(app_dir "$app_key")"
  port="$(port_for "$app_key")"
  main_env="$FRONTEND_REPO/$dir/.env"
  wt_env="$WT_FRONTEND/$dir/.env"

  if [[ ! -d "$WT_FRONTEND/$dir" ]]; then
    warn "App '$dir' does not exist in this worktree — skipping app '$app_key'."
    return 1
  fi
  if [[ -f "$wt_env" ]] && ! "$FORCE"; then
    vlog "Frontend env already present: $dir/.env (keeping existing; use --force to regenerate)."
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
  sed -i '' -E "/^ECHO_HOST_URL=/!s#https://${BASE_DOMAIN_RE}#https://${host}#g" "$wt_env"
  vlog "Frontend env ready: $dir (.env, PORT=$port, host=$host)"
  return 0
}

prepare_backend_env() {
  local host="$1"
  local main_env="$BACKEND_REPO/.env"
  local wt_env="$WT_BACKEND/.env"
  [[ -f "$main_env" ]] || { err "Main backend .env not found: $main_env"; exit 1; }
  if [[ -f "$wt_env" ]] && ! "$FORCE"; then
    vlog "Backend env already present (keeping existing; use --force to regenerate)."
    return 0
  fi
  if "$DRY_RUN"; then
    printf '[dry-run] cp %s %s ; rewrite APP_URL/CLIENT_URLs host -> %s (DB + rest kept)\n' "$main_env" "$wt_env" "$host"
    return 0
  fi
  cp "$main_env" "$wt_env"
  sed -i '' -E "s#https://${BASE_DOMAIN_RE}#https://${host}#g" "$wt_env"
  vlog "Backend env ready: reuses main DB, APP_URL=https://${host}"
}

# ------------------------------ nginx block ---------------------------------
# NOTE: built with printf / plain (uncaptured) heredocs on purpose — macOS ships
# bash 3.2, whose parser mishandles heredocs nested inside $(...) substitution.
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

render_nginx_block() {
  local host="$1" locations="$2"
  cat <<EOF
# Managed by \`ws serve\` — task workspace ${host}
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

# Idempotent: write the nginx block and reload ONLY when its content changed (or
# --force). An unchanged re-run touches nothing and needs no sudo/reload.
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
    vlog "nginx routing already up to date — no rewrite/reload needed."
    ok "nginx setup successfully"
    ok "no reload needed (routing unchanged)"
    return 0
  fi

  printf '%s\n' "$expected" >"$conf"
  vlog "Wrote nginx block: $conf"
  ok "nginx setup successfully"

  # Stays visible even without -v: `sudo` is about to prompt for a password and
  # a bare "Password:" with no stated reason is hostile.
  log "Requesting sudo (needed to reload nginx)…"
  sudo -v || { err "sudo is required to reload nginx."; exit 1; }
  run_nginx -t || { err "nginx config test failed — not reloading."; exit 1; }
  run_nginx -s reload || { err "nginx reload failed."; exit 1; }
  vlog "nginx reloaded."
  ok "reloaded successfully"
}

# ------------------------------ dependencies --------------------------------
setup_dependencies() {
  local -a served=("$@")   # app keys actually being served (for nuxi prepare)

  # Copy the gitignored root yarn env FIRST — .yarnrc.yml resolves private
  # registry tokens (ANNY_NPM_TOKEN, FONTAWESOME_NPM_TOKEN) from it, and Yarn 4
  # auto-loads .env.yarn, so every yarn command needs it present.
  if [[ -f "$FRONTEND_REPO/.env.yarn" && ! -f "$WT_FRONTEND/.env.yarn" ]]; then
    run_cmd cp "$FRONTEND_REPO/.env.yarn" "$WT_FRONTEND/.env.yarn"
  fi

  # Backend deps FIRST: cloning vendor is fast, local and deterministic, whereas
  # the yarn install below is slow and network-dependent. Ordered the other way
  # round, a failed/interrupted yarn aborts the whole function under `set -e` and
  # the worktree is left with no vendor at all — Laravel then can't boot and the
  # backend 500s, which looks like "the backend can't be found".
  #
  # CLONE vendor (copy-on-write) rather than symlink: a symlinked vendor makes
  # Composer's autoloader resolve its base dir to the MAIN repo (PHP realpaths
  # __DIR__), so the worktree would run main's backend code.
  #
  # NB: test -L as well as -e — `-e` follows symlinks and is FALSE for a dangling
  # one, so a vendor symlink whose target has moved would slip past an -e-only
  # guard and then make `cp` write through the broken link.
  if [[ -L "$WT_BACKEND/vendor" && ! -e "$WT_BACKEND/vendor" ]]; then
    warn "vendor is a dangling symlink ($(readlink "$WT_BACKEND/vendor")) — replacing it with a real clone."
    run_cmd rm -f "$WT_BACKEND/vendor"
  fi

  if [[ -e "$WT_BACKEND/vendor" ]]; then
    vlog "vendor already present in worktree (skipping)."
  elif "$DRY_RUN"; then
    printf '[dry-run] cp -Rc %s %s (clone vendor)\n' "$BACKEND_REPO/vendor" "$WT_BACKEND/vendor"
  elif [[ ! -d "$BACKEND_REPO/vendor" ]]; then
    warn "Main backend has no vendor/ ($BACKEND_REPO/vendor) — run 'composer install' there, then re-run 'ws serve'."
    DEPS_OK=false
  else
    cp -Rc "$BACKEND_REPO/vendor" "$WT_BACKEND/vendor" 2>/dev/null \
      || cp -R "$BACKEND_REPO/vendor" "$WT_BACKEND/vendor"
    vlog "Cloned vendor into worktree."
  fi

  # Frontend: install real dependencies with Yarn. We deliberately do NOT symlink
  # node_modules from the main repo — a symlink is confusing (stack traces point
  # back at the main clone) and couples the worktree to main. Yarn's postinstall
  # (nuxi prepare) also generates the root .nuxt that every app's tsconfig
  # extends. Install once; a re-run skips if node_modules already exists.
  #
  # A yarn failure is a WARNING, not a hard abort: the backend is already set up
  # by this point, so a flaky registry shouldn't tear down the rest of serve.
  # Say so loudly instead — a half-installed frontend is easy to finish by hand.
  if [[ -d "$WT_FRONTEND/node_modules" ]]; then
    vlog "Frontend node_modules already present (skipping yarn — run 'yarn' in the worktree to refresh)."
  else
    vlog "Installing frontend dependencies with yarn (this can take a while)…"
    if ! run_cmd bash -c "cd '$WT_FRONTEND' && yarn"; then
      warn "yarn install failed in $WT_FRONTEND."
      DEPS_OK=false
      warn "The backend is set up; finish the frontend with: cd '$WT_FRONTEND' && yarn"
    fi
  fi

  # Generate the Nuxt scaffolding the worktree needs. Every app's root
  # tsconfig.json does `extends: ./.nuxt/tsconfig.json`, a file produced by
  # `nuxi prepare`. `yarn`'s postinstall runs it for the ROOT only; nuxi dev
  # generates each app's own .nuxt but not necessarily before the first request,
  # and a skipped `yarn` regenerates nothing. Missing .nuxt makes Vite 500, so we
  # prepare the root and each served app here, guarded on the generated tsconfig.
  local nuxi="$WT_FRONTEND/node_modules/.bin/nuxi"
  if [[ ! -e "$nuxi" ]]; then
    warn "nuxi not found in worktree node_modules — skipping Nuxt prepare (run 'yarn' in $WT_FRONTEND)."
    DEPS_OK=false
  else
    if [[ -f "$WT_FRONTEND/.nuxt/tsconfig.json" ]]; then
      vlog "Root Nuxt scaffolding already present (skipping)."
    else
      vlog "Preparing root Nuxt scaffolding (nuxi prepare)…"
      run_cmd bash -c "cd '$WT_FRONTEND' && ./node_modules/.bin/nuxi prepare" \
        || warn "nuxi prepare (root) failed — the app may 500 until .nuxt is generated."
    fi
    local sa dir
    for sa in "${served[@]}"; do
      dir="$(app_dir "$sa")" || continue
      [[ -d "$WT_FRONTEND/$dir" ]] || continue
      if [[ -f "$WT_FRONTEND/$dir/.nuxt/tsconfig.json" ]]; then
        vlog "Nuxt scaffolding already present for $dir (skipping)."
      else
        vlog "Preparing Nuxt scaffolding for ${dir}…"
        run_cmd bash -c "cd '$WT_FRONTEND' && ./node_modules/.bin/nuxi prepare '$dir'" \
          || warn "nuxi prepare '$dir' failed — that app may 500 until its .nuxt is generated."
      fi
    done
  fi

  # Seed the backend's Cognitor JWT public key. anny/laravel-jwt-guard verifies
  # Cognitor-issued tokens against the key file named by IAM_PUBLIC_KEY_PATH
  # (relative to storage/, e.g. `cognitor.key`) — a generated secret outside git.
  # Without it file_get_contents() throws, EVERY authenticated request 500s, and
  # the frontend surfaces it as "Failed to load user/org data" / auth_failed.
  # Seed whatever the .env actually points at (prefer the worktree's .env, fall
  # back to main's) so we never seed the wrong filename — the app uses
  # `cognitor.key`, NOT `cognitor-public.key`.
  local cog_env="$WT_BACKEND/.env"; [[ -f "$cog_env" ]] || cog_env="$BACKEND_REPO/.env"
  local cog_rel=""
  if [[ -f "$cog_env" ]]; then
    cog_rel="$(grep -E '^IAM_PUBLIC_KEY_PATH=' "$cog_env" | tail -1 | cut -d= -f2-)"
    cog_rel="${cog_rel//\"/}"; cog_rel="${cog_rel//\'/}"; cog_rel="${cog_rel// /}"
  fi
  [[ -n "$cog_rel" ]] || cog_rel="cognitor.key"
  local cog_key="storage/$cog_rel"
  if [[ ! -f "$BACKEND_REPO/$cog_key" ]]; then
    warn "Main backend missing $cog_key — worktree Cognitor JWT verification will 500."
    # Same class as a missing vendor: the workspace comes up but every
    # authenticated request fails. Don't report success for that.
    DEPS_OK=false
  elif [[ -f "$WT_BACKEND/$cog_key" ]]; then
    vlog "Cognitor public key already present in worktree (skipping)."
  else
    run_cmd mkdir -p "$WT_BACKEND/$(dirname "$cog_key")"
    run_cmd cp "$BACKEND_REPO/$cog_key" "$WT_BACKEND/$cog_key"
    vlog "Seeded Cognitor public key into worktree ($cog_key)."
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

cmd_serve() {
  DRY_RUN=false
  ALL_APPS=false
  VERBOSE=false
  FORCE=false
  local slug="" positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all-apps)   ALL_APPS=true; shift ;;
      --force)      FORCE=true; shift ;;
      --dry-run)    DRY_RUN=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_serve_usage; exit 0 ;;
      -*) err "Unknown option: $1"; cmd_serve_usage; exit 1 ;;
      *)  positional+=("$1"); shift ;;
    esac
  done

  if [[ ${#positional[@]} -gt 1 ]]; then
    err "Expected at most one positional argument (slug)."; exit 1
  fi
  [[ ${#positional[@]} -eq 1 ]] && slug="${positional[0]}"

  require_command git
  require_command sed
  require_command nginx
  require_command cksum
  require_command yarn

  [[ -f "$VALET_CERT" && -f "$VALET_CERT_KEY" ]] \
    || { err "Wildcard cert not found ($VALET_CERT). Is $BASE_DOMAIN secured in Valet?"; exit 1; }

  if [[ -z "$slug" ]]; then
    slug="$(slug_from_cwd)" || {
      err "Not inside a worktree directory and no slug provided."
      err "Expected a path under: $WORKSPACES_ROOT/"
      exit 1
    }
    vlog "Auto-detected slug from CWD: $slug"
  fi

  # Dots escaped so BASE_DOMAIN can be dropped into the env-rewriting sed regexes.
  BASE_DOMAIN_RE="${BASE_DOMAIN//./\\.}"

  local sub host session_dir
  sub="$(resolve_subdomain "$slug")" \
    || { err "Refusing to serve '$slug': no DNS-safe characters to build a subdomain from."; exit 1; }
  host="${sub}.${BASE_DOMAIN}"

  session_dir="$WORKSPACES_ROOT/$slug"
  WT_FRONTEND="$session_dir/$FRONTEND_DIR_NAME"
  WT_BACKEND="$session_dir/$BACKEND_DIR_NAME"

  [[ -d "$WT_FRONTEND" && -d "$WT_BACKEND" ]] \
    || { err "Worktree not found for '$slug'. Run 'ws create' first."; exit 1; }

  # SAFETY: never serve — and thus never overwrite envs or nginx routing — a
  # worktree sitting on a protected base branch. That would be your main setup.
  local fe_branch be_branch
  fe_branch="$(worktree_branch "$WT_FRONTEND")"
  be_branch="$(worktree_branch "$WT_BACKEND")"
  if is_protected_branch "$fe_branch" || is_protected_branch "$be_branch"; then
    err "Refusing to serve '$slug': worktree is on a protected branch (frontend='$fe_branch', backend='$be_branch')."
    err "serve rewrites env files and nginx routing; it will not touch a main/base checkout."
    exit 1
  fi

  PORT_BASE="$(compute_port_base "$sub")"

  # Which apps to serve (skip any that lack an env source).
  local -a requested_apps served_apps=()
  if "$ALL_APPS"; then
    local key
    while IFS= read -r key; do requested_apps+=("$key"); done < <(all_app_keys)
  else
    requested_apps=("${DEFAULT_APPS[@]}")
  fi

  vlog "Slug:      $slug"
  vlog "Subdomain: https://$host"
  vlog "Worktree:  $session_dir"
  vlog "Port base: $PORT_BASE   apps: ${requested_apps[*]}"

  # 1) envs (idempotent: existing worktree envs are kept unless --force)
  local app
  for app in "${requested_apps[@]}"; do
    if prepare_frontend_env "$app" "$host"; then
      served_apps+=("$app")
    fi
  done
  [[ ${#served_apps[@]} -gt 0 ]] || { err "No servable frontend apps found."; exit 1; }
  prepare_backend_env "$host"
  ok "envs copied successfully"

  # 2) nginx (idempotent: only rewrites + reloads — and prompts sudo — if changed)
  #    ensure_nginx emits its own two checks; which ones depend on whether the
  #    routing actually changed.
  ensure_nginx "$host" "${served_apps[@]}"

  # 3) dependencies (last — only after routing/env succeeded; guarded/idempotent)
  setup_dependencies "${served_apps[@]}"
  if "$DEPS_OK"; then
    ok "dependencies installed successfully"
  else
    warn "dependencies incomplete — see the warnings above."
  fi

  # Detail only under -v; the checks above already say what happened.
  vlog ""
  vlog "Status: '$slug' is served at https://$host"
  vlog "Backend (Laravel) is served from the worktree and shares the main DB."
  vlog "URLs:"
  for app in "${served_apps[@]}"; do
    vlog "$(printf '    %-7s https://%s%s' "${app}:" "$host" "$(app_route "$app")")"
  done
  vlog "Tear it all down again with: ws remove $slug"

  # The payoff, last and unmissable: the URL you actually open + how to start it.
  # Still printed on a degraded run — routing and envs are done, so the URL is
  # real and the recovery command is exactly what you need.
  _ws_landing_box "$host" "${served_apps[@]}"

  # …but the exit code must carry the same truth the checks do. Otherwise a
  # degraded run reports success and `ws serve && open <url>` walks into a
  # broken app.
  "$DEPS_OK" || exit 1
}

# Print the landing URL in a bordered box tinted with the `ws help` banner fade
# (pink -> sky). Prefers admin — the usual destination, and the one $ADMIN_PATH
# describes — falling back to the first served app so the box is never empty.
_ws_landing_box() {
  local host="$1"; shift
  local -a served=("$@")
  local label path app found=false

  for app in ${served[@]+"${served[@]}"}; do
    [[ "$app" == "admin" ]] && found=true
  done

  if "$found"; then
    label="ADMIN"; path="$ADMIN_PATH"
  else
    app="${served[0]:-}"
    [[ -n "$app" ]] || return 0
    label="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
    path="$(app_route "$app")"
  fi

  local url="https://${host}${path}"
  local inner="  ${label}   ${url}  "
  local w=${#inner}
  local rule; rule="$(ws_rule '─' "$w")"

  # Border fades across the box; the URL stays a solid, readable link. Padding is
  # measured off the PLAIN string, so the ANSI/OSC-8 codes can't skew the width.
  printf '\n  %s\n' "$(ws_grad "╭${rule}╮" "$(( w + 2 ))")"
  if "$TTY"; then
    printf '  %s│%s  %s%s%s   \033]8;;%s\033\\%s%s%s\033]8;;\033\\  %s│%s\n' \
      "$WSM_GRAD_START" "$C_RESET" "$C_BOLD" "$WSM_GRAD_START" "$label" \
      "$url" "$WSM_GRAD_END" "$url" "$C_RESET" "$WSM_GRAD_END" "$C_RESET"
  else
    printf '  │%s│\n' "$inner"
  fi
  printf '  %s\n' "$(ws_grad "╰${rule}╯" "$(( w + 2 ))")"

  # That URL is dead until its dev server is up — serve deliberately doesn't
  # start it, so hand over the exact command.
  local key; key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  printf '\n  %sstart it with:%s cd %q && yarn serve-%s\n\n' \
    "$C_DIM" "$C_RESET" "$WT_FRONTEND" "$key"
}
