# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/test_instance.sh — the machinery behind `ws test --full`: a dedicated,
# CI-tuned MySQL instance on a RAM disk, the mjml render server, and a PHP ini
# set without Xdebug. Sourced by cmd_test.sh only.
#
# Why a second mysqld instead of the dev MySQL or a container:
#   - The dev MySQL (3306) runs with durable defaults (fsync per commit,
#     doublewrite, 128M buffer pool) and must not be reconfigured.
#   - A container in the colima/Docker VM is capped by the VM's CPUs (6) and
#     pays the VM's network hop on every query: measured 349s for the full
#     suite vs 208s against this native instance (14 processes, warm DBs).
# The instance runs the same flags as the CI service (no doublewrite, no fsync,
# no binlog, one shared tablespace) from the Homebrew mysqld binary, with its
# datadir on a RAM disk. It lives until `ws test --db-stop` or a reboot; the
# per-worker databases (and the schema they were built from) survive between
# runs, so only the first run after a reboot loads the 240-table schema.
# -----------------------------------------------------------------------------

_tm_datadir() { printf '/Volumes/%s/data' "$TEST_MYSQL_VOLUME"; }
_tm_mysqld()  { printf '%s/bin/mysqld' "$TEST_MYSQL_PREFIX"; }

# mysql client against the test instance (socket: no TCP auth quirks).
tm_sql() { mysql -S "$TEST_MYSQL_SOCKET" -uroot "$@"; }

tm_running() {
  mysqladmin -S "$TEST_MYSQL_SOCKET" -uroot ping >/dev/null 2>&1
}

# Mount the RAM disk unless it already is. Prints nothing on success.
_tm_ramdisk_up() {
  local vol="/Volumes/$TEST_MYSQL_VOLUME" dev sectors
  [[ -d "$vol" ]] && return 0
  sectors=$(( TEST_MYSQL_RAMDISK_MB * 2048 ))   # 512-byte sectors
  dev="$(hdiutil attach -nomount "ram://$sectors" | awk '{print $1}')" \
    || { err "hdiutil could not allocate a ${TEST_MYSQL_RAMDISK_MB} MB RAM disk."; return 1; }
  diskutil erasevolume APFS "$TEST_MYSQL_VOLUME" "$dev" >/dev/null \
    || { err "Could not format the RAM disk ($dev)."; hdiutil detach "$dev" >/dev/null 2>&1; return 1; }
  # Keep Spotlight off it: every test run rewrites the tablespace.
  mdutil -i off "$vol" >/dev/null 2>&1 || true
  touch "$vol/.metadata_never_index" 2>/dev/null || true
}

# Start the instance if it is not up. Idempotent; safe to call every run.
tm_ensure() {
  tm_running && { vlog "Test MySQL already up on port $TEST_MYSQL_PORT."; return 0; }

  local mysqld datadir vol fresh=false i
  mysqld="$(_tm_mysqld)"
  [[ -x "$mysqld" ]] \
    || { err "mysqld not found at $mysqld — brew install mysql@8.4 or set TEST_MYSQL_PREFIX."; return 1; }
  # Refuse to collide with something else (e.g. the dev MySQL) on our port.
  if lsof -nP -iTCP:"$TEST_MYSQL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    err "Port $TEST_MYSQL_PORT is taken by another process — set TEST_MYSQL_PORT to a free port."
    return 1
  fi

  spin "Starting test MySQL (RAM disk, port $TEST_MYSQL_PORT)"
  _tm_ramdisk_up || { spin_stop; return 1; }
  vol="/Volumes/$TEST_MYSQL_VOLUME"
  datadir="$(_tm_datadir)"
  if [[ ! -d "$datadir/mysql" ]]; then
    fresh=true
    mkdir -p "$datadir" "$vol/tmp"
    "$mysqld" --no-defaults --initialize-insecure --datadir="$datadir" \
      --innodb-file-per-table=OFF --log-error="$vol/init.err" >/dev/null 2>&1 \
      || { spin_stop; err "mysqld --initialize failed, see $vol/init.err"; return 1; }
  fi

  # CI flags (.gitlab-ci.yml, test(mysql-8.4)) + sizes for ~20 worker DBs x 240
  # tables. Performance schema off: it costs CPU on every statement.
  nohup "$mysqld" --no-defaults --datadir="$datadir" --tmpdir="$vol/tmp" \
    --port="$TEST_MYSQL_PORT" --bind-address=127.0.0.1 --socket="$TEST_MYSQL_SOCKET" \
    --mysqlx=OFF --pid-file="$vol/mysqld.pid" --log-error="$vol/mysqld.err" \
    --mysql-native-password=ON --skip-name-resolve \
    --innodb-doublewrite=OFF --innodb-flush-log-at-trx-commit=0 --sync-binlog=0 \
    --innodb-flush-method=nosync --skip-log-bin --innodb-file-per-table=OFF \
    --innodb-buffer-pool-size="$TEST_MYSQL_BUFFER_POOL" --innodb-redo-log-capacity=512M \
    --max-connections=500 --table-open-cache=20000 --table-definition-cache=20000 \
    --performance-schema=OFF >/dev/null 2>&1 &
  for i in $(seq 1 60); do tm_running && break; sleep 0.5; done
  if ! tm_running; then
    spin_stop; err "Test MySQL did not come up, see $vol/mysqld.err"; return 1
  fi

  if "$fresh"; then
    # Laravel connects over TCP (127.0.0.1); with skip-name-resolve that is a
    # different account than root@localhost. Time zone tables: the official
    # image ships them, the bare datadir does not — without them CONVERT_TZ()
    # returns NULL and ~60 analytics/time-of-day tests fail.
    tm_sql -e "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY ''; GRANT ALL ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;" \
      && mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | tm_sql mysql \
      || { spin_stop; err "Initial setup of the test MySQL failed."; return 1; }
  fi
  spin_ok "Test MySQL up (port $TEST_MYSQL_PORT, datadir on $vol)"
}

# Shut the instance down and release the RAM disk (frees its memory).
tm_stop() {
  local vol="/Volumes/$TEST_MYSQL_VOLUME"
  if tm_running; then
    mysqladmin -S "$TEST_MYSQL_SOCKET" -uroot shutdown >/dev/null 2>&1 || true
    local i; for i in $(seq 1 40); do tm_running || break; sleep 0.5; done
    ok "Test MySQL stopped"
  else
    log "Test MySQL is not running."
  fi
  if [[ -d "$vol" ]]; then
    hdiutil detach "$vol" >/dev/null 2>&1 && ok "RAM disk $vol released" \
      || warn "Could not detach $vol (in use?) — hdiutil detach '$vol' by hand."
  fi
}

tm_status() {
  if tm_running; then
    ok "Test MySQL up: port $TEST_MYSQL_PORT, socket $TEST_MYSQL_SOCKET"
    tm_sql -N -e "SELECT CONCAT('    ', COUNT(*), ' test databases') FROM information_schema.schemata WHERE schema_name LIKE '${TEST_DB_PREFIX}%'"
    df -h "/Volumes/$TEST_MYSQL_VOLUME" | awk 'NR==2 {print "    RAM disk: " $3 " used of " $2}'
  else
    log "Test MySQL not running (starts on the next 'ws test --full')."
  fi
}

# mjml render server (MJML_MODE=api), as in CI. Echoes the API URL on success;
# echoes nothing (and warns) when Docker is unavailable — the suite then
# renders through the local mjml binary, slower but correct.
tm_mjml_url() {
  local name="$TEST_MJML_CONTAINER" url="http://127.0.0.1:${TEST_MJML_PORT}/v1"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    warn "Docker not reachable — rendering mails without the mjml server."
    return 0
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]]; then
    # Something already serves the port (e.g. an mjml container started by
    # hand): use it rather than fail to bind a second one.
    if lsof -nP -iTCP:"$TEST_MJML_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      vlog "Port $TEST_MJML_PORT already serves — using it as the mjml server."
      printf '%s' "$url"; return 0
    fi
    if docker inspect "$name" >/dev/null 2>&1; then
      docker start "$name" >/dev/null || { warn "Could not start container $name."; return 0; }
    else
      docker run -d --name "$name" --restart unless-stopped -p "127.0.0.1:${TEST_MJML_PORT}:8080" \
        -e WORKERS="$TEST_MJML_WORKERS" "$TEST_MJML_IMAGE" >/dev/null 2>&1 \
        || { docker rm -f "$name" >/dev/null 2>&1; warn "Could not start $TEST_MJML_IMAGE."; return 0; }
    fi
    local i; for i in $(seq 1 30); do [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${TEST_MJML_PORT}/" 2>/dev/null)" != "000" ]] && break; sleep 0.5; done
  fi
  printf '%s' "$url"
}

# A PHP_INI_SCAN_DIR with the machine's ini files minus Xdebug/PCOV, plus
# opcache + JIT for the CLI. Child processes (paratest workers) inherit it.
# Xdebug merely loaded (XDEBUG_MODE=off) still slows every call; CI does not
# load it either. Rebuilt every run: cheap, and it follows php.ini changes.
tm_php_ini_dir() {
  local src dir="${TMPDIR:-/tmp}/ws-test-php-ini" f
  src="$(php -r 'echo PHP_CONFIG_FILE_SCAN_DIR;')"
  rm -rf "$dir"; mkdir -p "$dir"
  if [[ -d "$src" ]]; then
    for f in "$src"/*.ini; do
      [[ -f "$f" ]] || continue
      grep -qiE '^[[:space:]]*(zend_)?extension[[:space:]]*=.*(xdebug|pcov)' "$f" && continue
      cp "$f" "$dir/"
    done
  fi
  cat > "$dir/zz-ws-test.ini" <<'INI'
opcache.enable_cli=1
opcache.jit=tracing
opcache.jit_buffer_size=128M
opcache.memory_consumption=512
opcache.max_accelerated_files=100000
INI
  printf '%s' "$dir"
}
