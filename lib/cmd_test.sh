# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_test.sh — `workspaces test`: run the backend suite against the
# workspace's OWN test database, so concurrent runs in different workspaces
# can't `migrate:fresh` over each other.
#
# Mechanism: phpunit.xml pins the shared anny_bookings_test but declares
# DB_DATABASE without force="true" — PHPUnit skips <env> entries whose variable
# already exists, so exporting DB_DATABASE wins. This command is the one entry
# point that does that export; it FAILS CLOSED (a run that can't get its
# isolated DB errors out rather than silently hitting the shared one, because a
# silent fallback reproduces exactly the cross-workspace clobbering this
# prevents — misread as a regression in your own diff).
# -----------------------------------------------------------------------------

cmd_test_usage() {
  cat <<'USAGE'
Usage:
  ws test [SLUG] [phpunit args...]

Runs `php vendor/bin/phpunit` in the workspace's backend worktree with
DB_DATABASE pointed at the workspace's own test database
(<TEST_DB_PREFIX>_<short-label>, e.g. anny_bookings_test_cu_1234). The DB is
created on demand; the first run loads the schema (~35s), later runs are
normal speed. The shared test DB and the dev DB are never touched.

SLUG is required when not inside a workspace directory; every other argument
is passed to phpunit verbatim.

Options (before any phpunit args):
  --changed     Only the tests that touch this branch's changes: changed test
                files plus every test referencing a changed app class (diff vs
                merge-base with the base branch + uncommitted work). Nothing
                matched -> exits 0 and says so.
  --parallel    Run through `php artisan test --parallel` (paratest). Laravel
                creates <db>_test_<n> databases on first use.
  --processes N Worker count for --parallel (default: 4) and --full
                (default: TEST_FULL_PROCESSES, 16).
  --full        The whole suite the way CI runs it, tuned for this machine:
                own MySQL instance on a RAM disk (CI flags, port 3308, started
                on demand), mjml server container, PHP without Xdebug + JIT,
                paratest with files ordered by tests/durations.json. Ends with
                the duration and every failing test. Uses the workspace's own
                DB names on that instance, so workspaces don't collide.
                ~3.5 min warm; the first run after a reboot also builds the
                schema in every worker DB (~+40s).
  --db-status   Show the --full test MySQL instance.
  --db-stop     Stop it and release its RAM disk.
  --with-flaky  Do not exclude the FLAKY_TESTS from config.sh. By default they
                are excluded via --exclude-filter (serial) / a negative
                --filter (parallel, only when you pass no --filter yourself).
  --dry-run     Print the command instead of running it.
  -h, --help    Show this help.

Examples:
  ws test                                # suite for the workspace you're in
  ws test --changed                      # fast loop while working on a branch
  ws test --parallel --processes 6
  ws test --full                         # whole suite, CI-style, ~3.5 min
  ws test --filter=IntegrationError
  ws test tests/Feature/Integrations
  ws test CU-1234_my-feature --filter=Foo
USAGE
}

# Test files related to the branch's changes (see --changed). Prints one path
# per line, relative to the backend worktree; empty when nothing matches.
test_changed_files() {
  local wt="$1" base changed names=() tests=() f t re
  base="$(git -C "$wt" merge-base HEAD "origin/$BACKEND_BASE_BRANCH" 2>/dev/null \
       || git -C "$wt" merge-base HEAD "$BACKEND_BASE_BRANCH" 2>/dev/null || true)"
  changed="$( {
      [[ -n "$base" ]] && git -C "$wt" diff --name-only "$base" 2>/dev/null
      git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null | sed -E 's/^.{3}//; s/^.* -> //'
    } | grep -E '\.php$' | sort -u )"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      tests/*Test.php) [[ -f "$wt/$f" ]] && tests+=("$f") ;;
      app/*|src/*|database/*|routes/*|config/*) names+=("$(basename "$f" .php)") ;;
    esac
  done <<< "$changed"
  if (( ${#names[@]} )); then
    re="$(IFS='|'; printf '%s' "${names[*]}")"
    while IFS= read -r t; do [[ -n "$t" ]] && tests+=("$t"); done \
      < <(cd "$wt" && grep -rlwE "$re" tests --include='*Test.php' 2>/dev/null || true)
  fi
  (( ${#tests[@]} )) && printf '%s\n' "${tests[@]}" | sort -u
  return 0
}

# shellcheck source=/dev/null
source "$LIB_DIR/test_instance.sh"

# Regex (alternation) of FLAKY_TESTS from config.sh; empty when none configured.
flaky_regex() {
  [[ -n "${FLAKY_TESTS[@]+x}" ]] || return 0   # unset/empty array under set -u (bash 3.2)
  local IFS='|'; printf '%s' "${FLAKY_TESTS[*]}"
}

cmd_test() {
  DRY_RUN=false
  local changed=false parallel=false with_flaky=false processes="" full=false
  # Only leading, known flags (before or right after the slug) are consumed;
  # everything else belongs to phpunit (which has its own rich option set we
  # must not swallow). A first argument naming a workspace is the slug.
  local slug=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)    DRY_RUN=true; shift ;;
      --changed)    changed=true; shift ;;
      --parallel)   parallel=true; shift ;;
      --processes)  processes="${2:?--processes needs a number}"; shift 2 ;;
      --processes=*) processes="${1#*=}"; shift ;;
      --with-flaky) with_flaky=true; shift ;;
      --full)       full=true; shift ;;
      --db-status)  tm_status; exit 0 ;;
      --db-stop)    tm_stop; exit 0 ;;
      -h|--help)    cmd_test_usage; exit 0 ;;
      *)
        if [[ -z "$slug" && -d "$WORKSPACES_ROOT/$1" ]]; then
          slug="$1"; shift
        else
          break
        fi ;;
    esac
  done

  if ! "$TEST_DB_ENABLED"; then
    err "Per-workspace test DBs are disabled (TEST_DB_ENABLED=false)."
    err "Run phpunit directly for the shared DB, or enable the feature in config.sh."
    exit 1
  fi

  # No slug given: it comes from the cwd. Fails closed outside a workspace —
  # no silent fallback to the shared DB.
  if [[ -z "$slug" ]]; then
    slug="$(slug_from_cwd)" || {
      err "Not inside a workspace — run from a worktree, or name one: ws test <slug>"
      err "(see 'ws list')"
      exit 1
    }
    vlog "Auto-detected slug from CWD: $slug"
  fi

  local wt_backend="$WORKSPACES_ROOT/$slug/$BACKEND_DIR_NAME"
  [[ -d "$wt_backend" ]] || { err "Backend worktree not found for '$slug'."; exit 1; }
  [[ -f "$wt_backend/vendor/bin/phpunit" ]] \
    || { err "No vendor/bin/phpunit in the worktree — run 'ws serve $slug' first (installs dependencies)."; exit 1; }

  if "$full"; then
    cmd_test_full "$slug" "$wt_backend" "${processes:-$TEST_FULL_PROCESSES}" "$with_flaky" "$@"
    exit $?
  fi

  require_command php
  require_command mysql

  local db
  db="$(resolve_test_db "$slug")" \
    || { err "Could not derive a test-DB name from '$slug'."; exit 1; }

  # On-demand creation covers workspaces created before this feature existed.
  # FAILS CLOSED: no isolated DB, no run.
  test_db_ensure "$slug" \
    || { err "Could not ensure test DB '$db' — refusing to fall back to the shared one."; exit 1; }

  # --changed: narrow the run to the tests that touch this branch's changes.
  local -a extra=()
  if "$changed"; then
    local -a related=()
    while IFS= read -r f; do [[ -n "$f" ]] && related+=("$f"); done < <(test_changed_files "$wt_backend")
    if (( ${#related[@]} == 0 )); then
      ok "No tests relate to the branch's changes (nothing changed under app/, src/, database/, routes/, config/ or tests/)."
      exit 0
    fi
    log "Tests related to the branch's changes: ${#related[@]}"
    for f in "${related[@]}"; do printf '    %s\n' "$f"; done
    extra+=("${related[@]}")
  fi

  # Flaky exclusion (config.sh FLAKY_TESTS): serial runs get --exclude-filter,
  # parallel runs a negative --filter (paratest has no exclude-filter), but
  # never on top of a --filter you passed yourself.
  local flaky user_filter=false
  flaky="$(flaky_regex)"
  for a in "$@"; do case "$a" in --filter|--filter=*|--exclude-filter|--exclude-filter=*) user_filter=true ;; esac; done
  if [[ -n "$flaky" ]] && ! "$with_flaky"; then
    if ! "$parallel"; then
      extra+=("--exclude-filter=$flaky")
    elif ! "$user_filter"; then
      extra+=("--filter=^(?!.*(?:$flaky)).*$")
    fi
  fi

  local -a cmd
  if "$parallel"; then
    cmd=(php -d memory_limit="$TEST_MEMORY_LIMIT" artisan test --parallel --processes="${processes:-4}")
  else
    cmd=(php -d memory_limit="$TEST_MEMORY_LIMIT" vendor/bin/phpunit)
  fi

  if "$DRY_RUN"; then
    printf '[dry-run] cd %s && DB_DATABASE=%s' "$wt_backend" "$db"
    printf ' %q' "${cmd[@]}" ${extra[@]+"${extra[@]}"} "$@"; printf '\n'
    exit 0
  fi

  log "Running suite against isolated DB: $db"
  cd "$wt_backend"
  # The CLI php.ini limit is whatever the machine happens to have; a full suite
  # run exhausts a default 128M long before it finishes.
  "$DRY_RUN" || log_ws_event test "$slug"
  DB_DATABASE="$db" exec "${cmd[@]}" ${extra[@]+"${extra[@]}"} "$@"
}

# `ws test --full`: the whole suite, CI-style, on the dedicated test MySQL.
# Args: slug, backend worktree, process count, with_flaky, extra artisan args.
cmd_test_full() {
  local slug="$1" wt="$2" procs="$3" with_flaky="$4"; shift 4
  require_command php
  require_command mysql
  require_command mysqladmin

  local db
  db="$(resolve_test_db "$slug")" && _test_db_name_ok "$db" \
    || { err "No safe test-DB name for '$slug'."; exit 1; }

  if "$DRY_RUN"; then
    printf '[dry-run] test MySQL on port %s (RAM disk %s), DB %s + %s_test_1..%s, %s processes\n' \
      "$TEST_MYSQL_PORT" "$TEST_MYSQL_VOLUME" "$db" "$db" "$procs" "$procs"
    exit 0
  fi

  tm_ensure || exit 1
  # Laravel's parallel testing creates the per-worker DBs (<db>_test_N) through
  # a connection to <db> itself, so it has to exist first.
  tm_sql -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" \
    || { err "Could not create $db on the test MySQL."; exit 1; }

  local mjml ini tmp state junit
  mjml="$(tm_mjml_url)"
  ini="$(tm_php_ini_dir)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ws-test-full.XXXXXX")"
  # The shard config never touches the worktree (phpunit.shard.xml is not
  # gitignored); it lives here with absolute paths and goes away on exit.
  # Expanded now: the trap fires after this function's locals are gone.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  state="${XDG_STATE_HOME:-$HOME/.local/state}/workspace-management"
  mkdir -p "$state"
  junit="$state/test-full-$slug.junit.xml"

  # One shard, $procs processes: tests/shard.php orders files heaviest first
  # (paratest hands them out in that order) and splits files too heavy for one
  # process by method. Older branches without shard.php: plain phpunit.xml.
  local abs="s#bootstrap=\"#bootstrap=\"$wt/#; s#cacheDirectory=\"#cacheDirectory=\"$wt/#; s#<file>#<file>$wt/#g; s#>\\./#>$wt/#g"
  local shard_filter=""
  if [[ -f "$wt/tests/shard.php" ]]; then
    (cd "$wt" && php tests/shard.php --configuration 1 1 "$procs") | sed -e "$abs" > "$tmp/phpunit.xml" \
      || { err "tests/shard.php failed."; exit 1; }
    shard_filter="$(cd "$wt" && php tests/shard.php --filter 1 1 "$procs")"
  else
    sed -e "$abs" "$wt/phpunit.xml" > "$tmp/phpunit.xml"
  fi

  # Filters: yours wins; otherwise the shard's method split and the flaky
  # exclusion are merged into one pattern (phpunit honours only one --filter).
  local -a filter=()
  local a user_filter=false flaky
  for a in "$@"; do case "$a" in --filter|--filter=*) user_filter=true ;; esac; done
  flaky="$(flaky_regex)"
  if ! "$user_filter"; then
    local inner=""
    [[ -n "$shard_filter" ]] && { inner="${shard_filter#/^}"; inner="${inner%/}"; }
    if [[ -n "$flaky" ]] && ! "$with_flaky"; then
      filter=(--filter "/^(?!.*(?:$flaky))$inner/")
    elif [[ -n "$inner" ]]; then
      filter=(--filter "$shard_filter")
    fi
  fi

  local -a env_vars=(
    TELESCOPE_ENABLED=false XDEBUG_MODE=off PHP_INI_SCAN_DIR="$ini"
    DB_CONNECTION=mysql DB_HOST=127.0.0.1 DB_PORT="$TEST_MYSQL_PORT" DB_SOCKET="$TEST_MYSQL_SOCKET"
    DB_READ_HOSTS= DB_WRITE_HOSTS= DB_USERNAME=root DB_PASSWORD= DB_DATABASE="$db"
    TEST_SHARED_ORGANIZATION=1 TEST_COVERAGE=0
  )
  [[ -n "$mjml" ]] && env_vars+=(MJML_MODE=api MJML_API_URL="$mjml")
  # Values the worktree's .env sets for local development that CI never has
  # (config.sh, TEST_FULL_ENV) — e.g. a real LLM endpoint the tests then call.
  [[ -n "${TEST_FULL_ENV[@]+x}" ]] && env_vars+=("${TEST_FULL_ENV[@]}")

  log "Full suite: $procs processes, DB $db on the test MySQL${mjml:+, mjml server}"
  log_ws_event test "$slug"
  local start=$SECONDS rc=0
  (cd "$wt" && env "${env_vars[@]}" php -d memory_limit="$TEST_MEMORY_LIMIT" artisan test \
      --parallel --processes="$procs" --configuration="$tmp/phpunit.xml" \
      ${filter[@]+"${filter[@]}"} --log-junit="$junit" "$@") || rc=$?
  local took=$(( SECONDS - start ))

  printf '\n'
  log "Duration: $(( took / 60 ))m $(( took % 60 ))s ($procs processes)"
  if [[ -s "$junit" ]]; then
    php -r '
      $x = simplexml_load_file($argv[1]); $bad = [];
      foreach ($x->xpath("//testcase") as $c) {
        foreach (["error", "failure"] as $k) {
          if (isset($c->$k)) {
            $line = trim(strtok(trim((string) $c->$k), "\n"));
            $bad[] = sprintf("  %s  %s::%s\n      %s", strtoupper($k[0]), $c["class"], $c["name"], mb_strimwidth($line, 0, 160, "…"));
          }
        }
      }
      $s = $x->testsuite;
      printf("[test] %d tests, %d errors, %d failures, %d skipped\n", $s["tests"], $s["errors"], $s["failures"], $s["skipped"]);
      if ($bad) { echo implode("\n", $bad), "\n"; }
    ' "$junit"
    log "JUnit report: $junit"
  fi
  return "$rc"
}
