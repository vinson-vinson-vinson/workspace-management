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

# Set to false to leave MAIN_WORKSPACE_FILE alone during the Source Control
# ignore-list sync. With true (the default), the main workspace is treated like
# any other: `ws create`/`remove`/`sync` rewrite its git.ignoredRepositories so
# its window shows only the two main clones, not every task worktree. Turn this
# off if you hand-maintain that file — the sync rewrites it as plain JSON, so
# comments and custom formatting are lost. Ignored when MAIN_WORKSPACE_FILE is
# unset. Optional; defaults to true.
SYNC_MAIN_WORKSPACE=true

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

# Optional URL template for your task tracker. {id} is replaced by the task id
# parsed from a task slug (CU-1234_x -> 1234), and `ws status` shows a clickable
# link. Empty = no link. ClickUp example:
# TASK_URL_TEMPLATE="https://app.clickup.com/t/{id}"
TASK_URL_TEMPLATE=""

# Default assignee for MRs created by `ws mr`: a GitLab username (or a
# comma-separated list) handed to `glab mr create --assignee`. Empty = don't
# assign. Applies only to newly created MRs, not ones that already exist.
# e.g. MR_ASSIGNEE="vinson.mick"
MR_ASSIGNEE=""

# Whether `ws mr` creates merge requests as drafts. true (default) makes a
# draft; false makes them ready for review. Override per run with `ws mr
# --draft` (force draft) or `ws mr --nd` (force no-draft).
MR_DRAFT=true

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

# Source of the `ws list` wordmark banner's gradient. Optional; one of:
#   ws-colors       fade through your current workspaces' accent colors, in list
#                   order — the banner reflects the workspaces you have (default).
#                   Falls back to `static` until at least two colored workspaces
#                   exist (a gradient needs two stops).
#   recent-commits  fade through this repo's last 3 commit colors (first 6 hex of
#                   each SHA), so the banner shifts as new commits land.
#   static          the fixed pink→sky brand fade, same as `ws help`.
WS_BANNER_COLORS="ws-colors"

# Directory of custom lifecycle hooks. `ws remove` runs every executable file in
# <dir>/pre-remove/ after you confirm and before it deletes anything (both
# worktrees still exist), exporting WS_SLUG, WS_SESSION_DIR, WS_FRONTEND,
# WS_BACKEND (and *_DIR_NAME). A hook that exits non-zero aborts the removal.
# Machine-specific, so it's gitignored like this file; copy the shipped
# templates to enable them: cp -R hooks.example/ hooks/ && chmod +x hooks/**/*.
# Optional; defaults to a `hooks/` dir next to the command.
# WSM_HOOKS_DIR="$HOME/.config/workspace-management/hooks"

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

# Terminal app used for the workspace's terminals: "terminal" (default) or
# "warp". Optional.
#
# Both render the SAME set of tabs: one `yarn serve-<app>` per served app,
# plus every SESSION_TABS entry (default: a queue worker and one agent per
# repo — see SESSION_TABS below). What differs is the container:
#   terminal  one tab per command in Terminal.app
#   warp      ONE window holding the tabs, via a generated launch configuration
#             (Warp has no CLI and its URI scheme can't carry a command)
#
# Warp does have tab groups, but only as a UI gesture — a launch configuration
# cannot declare one yet (warpdotdev/warp#13898; the patch adding
# `tab_groups:`/`group:` is open in warp#13937). Once that ships, each
# workspace's tabs can become a named collapsible group.
TERMINAL_APP="terminal"

# Overrides the derived tab set above with your own commands, one tab each.
# $WT_FRONTEND and $WT_BACKEND are substituted with the session worktree paths
# at runtime, so each command has to cd itself. Leave the array empty to use
# the derived set. Optional; defaults to empty.
# SINGLE quotes are load-bearing: the literal string $WT_FRONTEND must survive
# into the array. Double-quoted, the shell expands it while sourcing this file
# — where it is unset — and every `ws` command dies with "unbound variable".
POST_CREATE_TERMINALS=(
  # 'cd $WT_FRONTEND && yarn serve-admin'
  # 'cd $WT_BACKEND && claude'
)

# Tabs beyond the served apps, one entry each:
#
#     "NAME:frontend|backend:COMMAND"
#
# NAME is the tab title, the middle field picks which worktree it starts in,
# and the rest of the line is the command. Only the first two colons split, so
# a command may contain them (`php artisan schedule:work` works fine).
#
# The app tabs are derived — one `yarn serve-<app>` per served app — because
# serving those is what `ws serve` does. Everything else is yours: however many
# agents you want, in whichever repo, or none.
#
# Optional; the default below is two agents (one per repo, since an agent
# inherits the AGENTS.md and branch conventions of the directory it starts in)
# plus a queue worker.
SESSION_TABS=(
  "queue:backend:php artisan horizon"
  "agent (api):backend:claude"
  "agent (ui):frontend:claude"
  # "scheduler:backend:php artisan schedule:work"
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

# memory_limit passed to php for `ws test`. The CLI php.ini default (often
# 128M) is exhausted partway through a full suite, which surfaces as an
# "Allowed memory size exhausted" fatal rather than a test failure.
TEST_MEMORY_LIMIT="1G"

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

# ------------------------------ sharing (ws share) ---------------------------
# `ws share [slug]` runs ngrok in the foreground to expose a served workspace
# (or main) on the internet, valet-share style. Only needed if you use it.
#
# Your reserved ngrok domain (free plan gives one static domain). Required for
# `ws share`. e.g. NGROK_DOMAIN="your-name.ngrok-free.dev"
NGROK_DOMAIN=""
# Upstream ngrok forwards to for `ws share main`. Workspaces are derived
# (https://<sub>.$BASE_DOMAIN); main can differ if it's served on another
# scheme/port. Optional; defaults to https://$BASE_DOMAIN.
# NGROK_MAIN_UPSTREAM="http://anny.test:60"
# The ngrok binary. Optional; defaults to "ngrok".
NGROK_BIN="ngrok"

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
