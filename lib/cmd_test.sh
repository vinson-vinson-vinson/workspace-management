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
  --dry-run     Print the command instead of running it.
  -h, --help    Show this help.

Examples:
  ws test                                # suite for the workspace you're in
  ws test --filter=IntegrationError
  ws test tests/Feature/Integrations
  ws test CU-1234_my-feature --filter=Foo
USAGE
}

cmd_test() {
  DRY_RUN=false
  # Only leading, known flags are consumed; everything else belongs to phpunit
  # (which has its own rich option set we must not swallow).
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) cmd_test_usage; exit 0 ;;
      *) break ;;
    esac
  done

  if ! "$TEST_DB_ENABLED"; then
    err "Per-workspace test DBs are disabled (TEST_DB_ENABLED=false)."
    err "Run phpunit directly for the shared DB, or enable the feature in config.sh."
    exit 1
  fi

  # First argument names a workspace? Then it's the slug; otherwise it's a
  # phpunit arg and the slug comes from the cwd. Fails closed outside a
  # workspace — no silent fallback to the shared DB.
  local slug=""
  if [[ $# -gt 0 && -d "$WORKSPACES_ROOT/$1" ]]; then
    slug="$1"; shift
  else
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

  require_command php
  require_command mysql

  local db
  db="$(resolve_test_db "$slug")" \
    || { err "Could not derive a test-DB name from '$slug'."; exit 1; }

  # On-demand creation covers workspaces created before this feature existed.
  # FAILS CLOSED: no isolated DB, no run.
  test_db_ensure "$slug" \
    || { err "Could not ensure test DB '$db' — refusing to fall back to the shared one."; exit 1; }

  if "$DRY_RUN"; then
    printf '[dry-run] cd %s && DB_DATABASE=%s php vendor/bin/phpunit %s\n' \
      "$wt_backend" "$db" "$*"
    exit 0
  fi

  log "Running suite against isolated DB: $db"
  cd "$wt_backend"
  DB_DATABASE="$db" exec php vendor/bin/phpunit "$@"
}
