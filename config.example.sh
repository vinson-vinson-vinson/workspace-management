# shellcheck shell=bash
# -----------------------------------------------------------------------------
# workspaces configuration
#
# Copy this file to `config.sh` and edit the values for your machine:
#
#     cp config.example.sh config.sh
#
# `config.sh` is gitignored so your local paths never get committed. The
# `workspaces` command (all subcommands) sources this file. You can also point
# it at a config elsewhere by exporting WSM_CONFIG=/path/to/config.sh.
# -----------------------------------------------------------------------------

# Root that holds your two repos and the worktrees/ directory.
ROOT_DIR="$HOME/Projects/anny"

# The two repos that make up a workspace. FRONTEND/BACKEND are conceptual roles:
# the frontend is expected to be a multi-app JS project (Nuxt-style), the backend
# a PHP/Laravel-style app. *_DIR_NAME is the folder name each repo keeps inside a
# session directory (usually just the repo's own directory name).
FRONTEND_DIR_NAME="anny-ui"
BACKEND_DIR_NAME="bookings-api"
FRONTEND_REPO="$ROOT_DIR/$FRONTEND_DIR_NAME"
BACKEND_REPO="$ROOT_DIR/$BACKEND_DIR_NAME"

# Where session worktrees are created (one sub-directory per workspace slug).
WORKSPACES_ROOT="$ROOT_DIR/workspaces"

# .code-workspace file for the MAIN workspace — what `ws open 0` opens (and
# where the MAIN row in `ws list` links to). If unset or missing, `ws open 0`
# opens both main repos in one new VS Code window instead. Optional.
# MAIN_WORKSPACE_FILE="$ROOT_DIR/full-stack.code-workspace"

# Base branch each brand-new worktree branch is cut from, per repo.
FRONTEND_BASE_BRANCH="main"
BACKEND_BASE_BRANCH="main"

# Task-id prefix for "task" workspaces, e.g. ClickUp's "CU". A slug of the form
# <PREFIX>-<id>_<feature-name> (CU-1234_my-feature) is treated as a task
# workspace and gets a short subdomain derived from the task id. Any other name
# works too (served under a subdomain derived from the whole slug). The prefix no
# longer gates which workspaces may be served/removed — that is now guarded by a
# "don't touch a main/base checkout" branch check. Case-insensitive.
TASK_ID_PREFIX="CU"

# IDE used to open workspaces, per repo role. Allowed values: vscode (the
# default), phpstorm, webstorm, zed. With the SAME value on both sides,
# `ws open` / `ws create` open the workspace combined in ONE window (vscode:
# the .code-workspace file; zed: one multi-folder window; phpstorm/webstorm —
# which have no multi-root projects — the session dir as a single project).
# With DIFFERENT values, each worktree opens separately in its own IDE.
# Needs the IDE's CLI launcher on PATH: code / phpstorm / webstorm / zed.
# Optional; both default to vscode.
FRONTEND_IDE="vscode"
BACKEND_IDE="vscode"

# Set to true to NOT open VS Code after `ws create`. The worktrees and the
# .code-workspace file are still created — you open the workspace yourself
# (e.g. via the clickable name in `ws list`). Optional; defaults to false.
NO_OPEN_AFTER_CREATE=false

# Set to true to cut new workspace branches from the LIVE remote base branch:
# `ws create` fetches origin/<base-branch> in both repos first and branches
# from that, so workspaces never start from a stale local main. With false
# (the default), branches are cut from your local base branch as it sits on
# disk. Optional; defaults to false.
USE_REMOTE_MAIN=false

# Set to false to skip `ws remove`'s "Continue? [y/N]" confirmation prompt.
# The other safety nets are unaffected: removal still refuses worktrees on a
# protected base branch, and still aborts on uncommitted/unpushed work unless
# --force is given. Optional; defaults to true.
REQUIRE_CONFIRM_REMOVE=true

# Extra folders added to every workspace's VS Code window — e.g. shared local
# packages you regularly edit alongside task work. Absolute paths, appended
# after the two worktree folders. Paths that don't exist on this machine are
# skipped with a warning. Optional; defaults to empty.
EXTRA_WORKSPACE_FOLDERS=(
  # "$HOME/Projects/packages/laravel-integrations"
)

# ------------------------- post-create terminals -----------------------------
# Only used when FRONTEND_IDE/BACKEND_IDE aren't both vscode: a VS Code
# workspace starts these same commands from its .code-workspace tasks block,
# and running both would start every dev server twice.

# Terminal app used for auto-opening command tabs after `ws create`:
# "terminal" (default) or "warp". Optional.
TERMINAL_APP="terminal"

# Commands auto-started in terminal tabs after `ws create` finishes, one tab
# each. $WT_FRONTEND and $WT_BACKEND are substituted with the session worktree
# paths at runtime, so each command has to cd itself. Leave the array empty to
# skip. Optional; defaults to empty.
# SINGLE quotes are load-bearing: the literal string $WT_FRONTEND must survive
# into the array. Double-quoted, the shell expands it while sourcing this file
# — where it is unset — and every `ws` command dies with "unbound variable".
POST_CREATE_TERMINALS=(
  # 'cd $WT_FRONTEND && yarn serve-admin'
  # 'cd $WT_BACKEND && claude'
)

# ------------------------ per-workspace test database ------------------------
# Each workspace gets its own MySQL test DB (created by `ws create`, dropped by
# `ws remove`), and `ws test` runs the backend suite against it — so concurrent
# test runs in different workspaces can't `migrate:fresh` over each other. The
# shared test DB (= the bare prefix) and the dev DB are never touched. The
# credentials are separate from the backend .env on purpose: provisioning needs
# CREATE/DROP privileges the app user may not have. If they drift, the feature
# fails loudly and harmlessly. All optional, with these defaults.
TEST_DB_ENABLED=true
TEST_DB_PREFIX="anny_bookings_test"
TEST_DB_HOST="127.0.0.1"
TEST_DB_USER="root"
TEST_DB_PASSWORD=""

# ------------------------------ serving (ws serve) ---------------------------
# `ws serve` makes a task worktree reachable at <sub>.$BASE_DOMAIN using Laravel
# Valet's nginx + wildcard cert. If you don't use `ws serve` you can leave this
# section at its defaults.

# Workspaces are served at <sub>.$BASE_DOMAIN. For a task workspace <sub> is the
# lowercased task id (cu-1234.anny.test); for any other name it's the whole slug
# lowercased (admin-test.anny.test). The main workspace is served at $BASE_DOMAIN.
BASE_DOMAIN="anny.test"

# Landing path shown by list-workspaces for each served workspace.
ADMIN_PATH="/admin/calendar"

# Base of the per-workspace dev-server port block. Kept well clear of your main
# workspace's ports so main + a task can run at the same time.
PORT_RANGE_START=20000

# Laravel Valet paths. The cert/key must cover both $BASE_DOMAIN and its
# wildcard (*.$BASE_DOMAIN) — that's what `valet secure $BASE_DOMAIN` produces.
VALET_DIR="$HOME/.config/valet"
VALET_CERT="$VALET_DIR/Certificates/$BASE_DOMAIN.crt"
VALET_CERT_KEY="$VALET_DIR/Certificates/$BASE_DOMAIN.key"
VALET_PHP_SOCK="$VALET_DIR/valet.sock"
VALET_NGINX_DIR="$VALET_DIR/Nginx"
VALET_LOG="$VALET_DIR/Log/nginx-error.log"

# Frontend app registry, one entry per servable app:
#     "key:dir:route:port-offset"
#   key         short name used on the CLI and in URLs summary
#   dir         directory under the frontend repo (e.g. app-admin)
#   route       nginx location prefix proxied to that app's dev server
#   port-offset added to the workspace's port base to get the app's dev port
# (Parallel-array form is used deliberately so this works on macOS bash 3.2,
# which has no associative arrays.)
APPS=(
  "admin:app-admin:/admin:1"
  "shop:app-shop:/b:2"
  "account:app-account:/account:3"
  "panels:app-panels:/panel:4"
  "outlook:app-outlook:/outlook:5"
)

# Apps served by default (without --all-apps). Must be keys present in APPS.
DEFAULT_APPS=(admin shop)
