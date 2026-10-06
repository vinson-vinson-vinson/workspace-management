# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_php.sh — `ws php …` and `ws artisan …`: PHP where the workspace runs.
#
# With RUNTIME=docker, PHP lives in the runtime's php container (the backend's
# production build), so `php artisan …` on the host would use a different PHP,
# or none. These run it in the container at the current directory instead;
# with RUNTIME=valet they are plain `php` / `php artisan`. Agents and the
# queue tab use them so the same command works on every machine.
# -----------------------------------------------------------------------------

cmd_php_usage() {
  cat <<'USAGE'
Usage:
  ws php [args...]        php in the current directory
  ws artisan [args...]    php artisan in the backend checkout you're in

With RUNTIME=docker these run inside the runtime's php container (started if
needed) at the same path; with RUNTIME=valet they run the host's php.

Examples:
  ws artisan migrate
  ws artisan horizon
  ws artisan tinker --execute 'dump(App\Models\User::count());'
  ws php vendor/bin/phpunit --filter=Foo
USAGE
}

# The nearest directory at or above the cwd that has an `artisan` file.
_artisan_root() {
  local d; d="$(pwd -P)"
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/artisan" ]] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

cmd_php() {
  local mode="$1"; shift
  case "${1:-}" in -h|--help) cmd_php_usage; exit 0 ;; esac

  local dir
  if [[ "$mode" == "artisan" ]]; then
    dir="$(_artisan_root)" || { err "No artisan file here or above — run it inside a backend checkout."; exit 1; }
    set -- artisan "$@"
  else
    dir="$(pwd -P)"
  fi

  if runtime_is_docker; then
    local m inside=false
    while IFS= read -r m; do
      [[ "$dir" == "$m" || "$dir" == "$m"/* ]] && inside=true
    done < <(runtime_mounts)
    "$inside" || { err "$dir isn't mounted into the php container (ROOT_DIR, WORKSPACES_ROOT or a main repo)."; exit 1; }
    runtime_ensure_up >&2 || exit 1
  else
    require_command php
  fi
  ws_php_in "$dir" "$@"
}
