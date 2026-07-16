# shellcheck shell=bash
# -----------------------------------------------------------------------------
# workspace-management configuration
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
