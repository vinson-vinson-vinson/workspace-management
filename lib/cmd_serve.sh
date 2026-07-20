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
    Run `ws trust` once to make the nginx reload passwordless.
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
# No-op when the exact line is already there: sed -i rewrites the file (and
# bumps its mtime) even for identical content, and serve re-pins HOST/PORT on
# every run — a running dev server watching the .env would restart for nothing.
set_env_var() {
  local file="$1" key="$2" val="$3"
  if grep -qxF "${key}=${val}" "$file" 2>/dev/null; then
    return 0
  fi
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
    # Keep the existing env — but HOST/PORT are not the user's to own. nginx is
    # already proxying to port_for(), so an env that disagrees is a permanent
    # 502 with nothing to see: serve reports success, `ws list` reports served,
    # and the dev server logs look perfect on the wrong port. Anything that
    # drops a .env here before serve runs (an editor, a worktree hook, an
    # earlier checkout) otherwise pins the port to whatever main uses.
    set_env_var "$wt_env" HOST "127.0.0.1"
    set_env_var "$wt_env" PORT "$port"
    vlog "Frontend env already present: $dir/.env (kept; HOST/PORT re-pinned to $port)."
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

# ------------------------------ favicons ------------------------------------
# Badge the apps' favicons with the workspace color: the app's own icon (the
# anny butterfly etc.) shrunk to the middle, with a ring around it in the
# workspace accent (same color as the VS Code title bar and the `ws list`
# swatch) — so every browser tab shows which workspace it belongs to AND which
# app it is. We never touch the repos: the badged icons are generated per app
# into the session dir and nginx serves them via exact-match locations that
# shadow the apps' /_favicons/ URLs. Set by prepare_favicons;
# emit_favicon_locations only runs when it succeeded.
HAVE_FAVICONS=false

# Generate <FAVICON_DIR>/<app>/{favicon.ico,favicon-16x16.png,favicon-32x32.png,
# apple-touch-icon.png} for every served app. Pure-stdlib python3 — decodes the
# app's own PNGs (8-bit palette/RGB/RGBA, the formats in the repos), scales the
# logo inside the ring, and falls back to a plain filled circle for an icon it
# can't read. A stamp file makes re-runs cheap and regenerates when the color
# (or app set) changed.
prepare_favicons() {
  local color="$1"; shift
  local -a apps=("$@")
  HAVE_FAVICONS=false
  if [[ -z "$color" ]]; then
    vlog "No workspace color found — keeping the apps' own favicons."
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    vlog "python3 not found — keeping the apps' own favicons."
    return 0
  fi
  if "$DRY_RUN"; then
    printf '[dry-run] generate %s-ringed favicons for %s in %s\n' \
      "$color" "${apps[*]}" "$FAVICON_DIR"
    HAVE_FAVICONS=true
    return 0
  fi
  local stamp="$color ${apps[*]}"
  if [[ "$(cat "$FAVICON_DIR/stamp" 2>/dev/null)" == "$stamp" ]] && ! "$FORCE"; then
    vlog "Workspace favicons already generated ($color)."
    HAVE_FAVICONS=true
    return 0
  fi
  local -a specs=()
  local app
  for app in "${apps[@]}"; do
    specs+=("${app}:$WT_FRONTEND/$(app_dir "$app")/public/_favicons")
  done
  mkdir -p "$FAVICON_DIR"
  if python3 - "$color" "$FAVICON_DIR" "${specs[@]}" <<'PY'
import struct, sys, zlib, os

def chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

def encode_png(rows, size):                           # rows: RGBA bytearrays
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    ihdr = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

def ico_wrapping(png_bytes, size):                    # ICO with embedded PNG
    header = struct.pack('<HHH', 0, 1, 1)
    entry = struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32,
                        len(png_bytes), 22)
    return header + entry + png_bytes

def decode_png(path):
    """8-bit gray/RGB/palette/RGBA, non-interlaced -> (RGBA rows, w, h)."""
    b = open(path, 'rb').read()
    if b[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a png')
    pos, idat, plte, trns, hdr = 8, b'', b'', b'', None
    while pos < len(b):
        ln = int.from_bytes(b[pos:pos + 4], 'big')
        tag, c = b[pos + 4:pos + 8], b[pos + 8:pos + 8 + ln]
        if tag == b'IHDR': hdr = struct.unpack('>IIBBBBB', c)
        elif tag == b'PLTE': plte = c
        elif tag == b'tRNS': trns = c
        elif tag == b'IDAT': idat += c
        pos += 12 + ln
    w, h, depth, ctype, _, _, inter = hdr
    if depth != 8 or inter != 0 or ctype not in (0, 2, 3, 6):
        raise ValueError('unsupported png variant')
    bpp = {0: 1, 2: 3, 3: 1, 6: 4}[ctype]
    raw, stride = zlib.decompress(idat), w * bpp
    prev, lines, p = bytearray(stride), [], 0
    for _ in range(h):                                # undo PNG filters
        f, line = raw[p], bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            up = prev[i]
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + up) & 255
            elif f == 3: line[i] = (line[i] + ((a + up) >> 1)) & 255
            elif f == 4:
                c0 = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(up - c0), abs(a - c0), abs(a + up - 2 * c0)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc
                                      else up if pb <= pc else c0)) & 255
        lines.append(line); prev = line
    rows = []
    for y in range(h):
        row, line = bytearray(), lines[y]
        for x in range(w):
            if ctype == 6:   row += line[x * 4:x * 4 + 4]
            elif ctype == 2: row += line[x * 3:x * 3 + 3] + b'\xff'
            elif ctype == 0: row += bytes([line[x]] * 3) + b'\xff'
            else:
                i = line[x]
                row += bytes(plte[i * 3:i * 3 + 3])
                row += bytes([trns[i] if i < len(trns) else 255])
        rows.append(row)
    return rows, w, h

def resize(rows, w, h, n):                            # bilinear -> n x n
    out = []
    for y in range(n):
        sy = max(0.0, (y + 0.5) * h / n - 0.5)
        y0 = min(h - 1, int(sy)); y1 = min(h - 1, y0 + 1); fy = sy - y0
        row = bytearray()
        for x in range(n):
            sx = max(0.0, (x + 0.5) * w / n - 0.5)
            x0 = min(w - 1, int(sx)); x1 = min(w - 1, x0 + 1); fx = sx - x0
            for c in range(4):
                row.append(round(
                    rows[y0][x0 * 4 + c] * (1 - fx) * (1 - fy)
                    + rows[y0][x1 * 4 + c] * fx * (1 - fy)
                    + rows[y1][x0 * 4 + c] * (1 - fx) * fy
                    + rows[y1][x1 * 4 + c] * fx * fy))
        out.append(row)
    return out

def badge(size, rgb, src):
    """App logo centered inside an anti-aliased workspace-color ring."""
    canvas = [bytearray(size * 4) for _ in range(size)]
    thick = max(2, round(size / 10))
    if src is not None:
        gap = max(1, size // 16)
        inner = size - 2 * (thick + gap)
        logo, off = resize(*src, inner), thick + gap
        for y in range(inner):
            canvas[off + y][off * 4:(off + inner) * 4] = logo[y]
    cx = (size - 1) / 2
    r_out = size / 2 - 0.5
    r_in = r_out - thick
    for y in range(size):
        for x in range(size):
            d = ((x - cx) ** 2 + (y - cx) ** 2) ** 0.5
            cov = (min(1.0, max(0.0, r_out - d + 0.5))
                   * min(1.0, max(0.0, d - r_in + 0.5)))
            if cov <= 0:
                continue
            i, sa = x * 4, round(cov * 255)          # ring over canvas
            da = canvas[y][i + 3] * (255 - sa) // 255
            fa = sa + da
            for c in range(3):
                canvas[y][i + c] = (rgb[c] * sa + canvas[y][i + c] * da) // fa
            canvas[y][i + 3] = fa
    return canvas

color, outroot = sys.argv[1].lstrip('#'), sys.argv[2]
rgb = tuple(int(color[i:i + 2], 16) for i in (0, 2, 4))
for spec in sys.argv[3:]:
    app, srcdir = spec.split(':', 1)
    outdir = os.path.join(outroot, app)
    os.makedirs(outdir, exist_ok=True)
    for name, size in (('favicon-16x16.png', 16), ('favicon-32x32.png', 32),
                       ('apple-touch-icon.png', 180)):
        src = None
        path = os.path.join(srcdir, name)
        if os.path.isfile(path):
            try:
                src = decode_png(path)
            except Exception:
                src = None                            # fall back: plain circle
        data = encode_png(badge(size, rgb, src), size)
        with open(os.path.join(outdir, name), 'wb') as fh:
            fh.write(data)
        if size == 32:
            with open(os.path.join(outdir, 'favicon.ico'), 'wb') as fh:
                fh.write(ico_wrapping(data, 32))
PY
  then
    printf '%s' "$stamp" >"$FAVICON_DIR/stamp"
    vlog "Workspace favicons generated ($color, apps: ${apps[*]})."
    ok "favicons ringed ($color)"
    HAVE_FAVICONS=true
  else
    warn "favicon generation failed — keeping the apps' own favicons."
  fi
}

# Exact-match locations shadowing one app's /_favicons/ icon URLs. Everything
# else under /_favicons/ (manifest, startup images, …) still proxies to the app.
emit_favicon_locations() {
  local app="$1" route="$2" f
  for f in favicon.ico favicon-16x16.png favicon-32x32.png apple-touch-icon.png; do
    printf '%s\n' \
"    location = ${route}/_favicons/${f} {" \
"        alias \"${FAVICON_DIR}/${app}/${f}\";" \
"        access_log off;" \
"    }"
  done
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
    if "$HAVE_FAVICONS"; then
      locations+="$(emit_favicon_locations "$app" "$route")"$'\n'
    fi
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

  # Get sudo BEFORE writing the block: a written-but-not-reloaded conf would
  # pass the "unchanged" check on every later run and the reload would never
  # happen. ensure_sudo_for_nginx is quiet with the `ws trust` rule installed.
  ensure_sudo_for_nginx \
    || { err "sudo is required to reload nginx. Routing left unchanged — re-run 'ws serve'."; exit 1; }

  printf '%s\n' "$expected" >"$conf"
  vlog "Wrote nginx block: $conf"
  ok "nginx setup successfully"

  # Spinner starts only AFTER sudo has returned — it must never share the line
  # with a password prompt. run_nginx keeps its own output quiet on success.
  spin "reloading nginx"
  run_nginx -t || { spin_stop; err "nginx config test failed — not reloading."; exit 1; }
  run_nginx -s reload || { spin_stop; err "nginx reload failed."; exit 1; }
  vlog "nginx reloaded."
  spin_ok "reloaded successfully"
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
    ok "backend vendor cloned"
  elif [[ ! -d "$BACKEND_REPO/vendor" ]]; then
    warn "Main backend has no vendor/ ($BACKEND_REPO/vendor) — run 'composer install' there, then re-run 'ws serve'."
    DEPS_OK=false
  else
    # Copying ~150 packages: slow enough to look hung without a spinner.
    spin "cloning backend vendor"
    cp -Rc "$BACKEND_REPO/vendor" "$WT_BACKEND/vendor" 2>/dev/null \
      || cp -R "$BACKEND_REPO/vendor" "$WT_BACKEND/vendor"
    spin_ok "backend vendor cloned"
    vlog "Cloned vendor into worktree."
  fi

  # Backend node_modules, same clone treatment as vendor: the backend has its
  # own JS deps (mjml for mails; chokidar, which `artisan horizon:watch` dies
  # without). Warn-only when main has none — the app boots fine without them,
  # only horizon:watch / mail rendering need it, so don't fail the whole serve.
  if [[ -e "$WT_BACKEND/node_modules" ]]; then
    vlog "Backend node_modules already present in worktree (skipping)."
  elif "$DRY_RUN"; then
    printf '[dry-run] cp -Rc %s %s (clone backend node_modules)\n' \
      "$BACKEND_REPO/node_modules" "$WT_BACKEND/node_modules"
    ok "backend node_modules cloned"
  elif [[ ! -d "$BACKEND_REPO/node_modules" ]]; then
    warn "Main backend has no node_modules — 'artisan horizon:watch' and mail rendering won't work in the worktree (run 'yarn' in $BACKEND_REPO, then re-run 'ws serve')."
  else
    spin "cloning backend node_modules"
    cp -Rc "$BACKEND_REPO/node_modules" "$WT_BACKEND/node_modules" 2>/dev/null \
      || cp -R "$BACKEND_REPO/node_modules" "$WT_BACKEND/node_modules"
    spin_ok "backend node_modules cloned"
    vlog "Cloned backend node_modules into worktree."
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
    # Slow and chatty: hide yarn's output behind a spinner (run_quiet shows it
    # under -v, and on failure — where it's the error message).
    spin "yarn installing"
    if run_quiet bash -c "cd '$WT_FRONTEND' && yarn"; then
      spin_ok "yarn installed"
    else
      spin_stop
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

  # Serve /storage/* (user uploads: gallery images, logos, …). On the MAIN
  # host Valet's Laravel driver maps /storage/<x> to storage/app/public/<x>
  # internally, but the workspace nginx block serves static files straight
  # from public/ — and a fresh worktree has no public/storage link (gitignored,
  # `artisan storage:link` never ran), so every image 404s. Link it to the MAIN
  # repo's storage/app/public: the worktree shares the main DB, so its file
  # records point at main's uploads.
  local wt_pub_storage="$WT_BACKEND/public/storage"
  if [[ -L "$wt_pub_storage" && ! -e "$wt_pub_storage" ]]; then
    warn "public/storage is a dangling symlink ($(readlink "$wt_pub_storage")) — relinking."
    run_cmd rm -f "$wt_pub_storage"
  fi
  if [[ -e "$wt_pub_storage" ]]; then
    vlog "public/storage already present (skipping)."
  elif [[ ! -d "$BACKEND_REPO/storage/app/public" ]]; then
    warn "Main backend has no storage/app/public — /storage URLs (images) will 404."
  else
    run_cmd ln -s "$BACKEND_REPO/storage/app/public" "$wt_pub_storage"
    vlog "Linked public/storage -> main storage/app/public (shared uploads)."
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
  # Silent work (cp + sed, detail behind -v), so it gets a spinner.
  spin "copying envs"
  local app
  for app in "${requested_apps[@]}"; do
    if prepare_frontend_env "$app" "$host"; then
      served_apps+=("$app")
    fi
  done
  if [[ ${#served_apps[@]} -eq 0 ]]; then
    spin_stop
    err "No servable frontend apps found."; exit 1
  fi
  prepare_backend_env "$host"
  spin_ok "envs copied successfully"

  # 1b) workspace-colored favicons (before nginx, which aliases to them)
  FAVICON_DIR="$session_dir/.favicons"
  prepare_favicons "$(_ws_color "$slug")" "${served_apps[@]}"

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
