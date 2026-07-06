# workspace-management

> **macOS only** (for now). It relies on BSD `sed`, `open`, the `code`
> CLI, and Laravel Valet. Linux support isn't there yet.

Bash tooling for spinning up **isolated, per-task development workspaces** out of
git worktrees, opening them in VS Code, and (optionally) serving each one under
its own local subdomain — so you can have several tasks in flight at once without
them stepping on each other.

A "workspace" is one session directory containing a **frontend** and a
**backend** worktree of two sibling repos, cut from the same branch:

```
<ROOT_DIR>/
├── <frontend-repo>/                 # your main frontend clone
├── <backend-repo>/                  # your main backend clone
└── worktrees/
    └── CU-1234_my-feature/          # a workspace ("session"), self-contained
        ├── <frontend-repo>/         #   frontend worktree on branch CU-1234_my-feature
        ├── <backend-repo>/          #   backend  worktree on branch CU-1234_my-feature
        └── CU-1234_my-feature.code-workspace
```

The tooling was extracted from a specific two-repo setup (a Nuxt-style
multi-app frontend + a Laravel/PHP backend, served through Laravel Valet), but
**all machine- and project-specific values live in a single `config.sh`**, so it
adapts to your own repos, branches, domain, and app layout.

## Commands

Everything is one command — `workspaces` (short alias: **`ws`**) — with subcommands:

| Command | What it does |
| --- | --- |
| `ws create <slug> [opts]` | Create (or reopen) a workspace: adds the two worktrees, writes a `.code-workspace` file, and opens VS Code. Optionally opens a Claude Code session with `--claude`. |
| `ws list` &nbsp;(or bare `ws`) | List all workspaces, star the one you're in, and link each served workspace to its landing URL. |
| `ws serve [slug] [opts]` | Make a workspace reachable at `<sub>.<domain>` via Valet/nginx: copies + rewrites envs, writes an nginx block, installs deps (`yarn` frontend, cloned vendor backend), and generates the Nuxt scaffolding. Slug defaults to the current directory. |
| `ws remove [slug] [opts]` | Tear a workspace down safely: reverts routing, removes worktrees, deletes local branches, cleans the session dir. Refuses on unpushed work unless `--force`. Slug defaults to the current directory. |
| `ws help` / `ws version` | Banner + command overview / print the version. |

Run `ws <command> --help` for per-command options.

## Requirements

- **macOS** — required for now; it uses BSD `sed` (`sed -i ''`), `open`, and the `code` CLI.
- **git** with worktree support.
- **VS Code** with the `code` command on your `PATH` (for `ws create`).
- For `ws serve` only: **Laravel Valet** (nginx + a wildcard cert for
  your domain), `nginx`, `yarn`, and `sudo` access to reload nginx. If you don't
  serve workspaces you can ignore that command entirely.
- Optional: the **Claude** desktop app, for the opt-in `claude://` deep-link
  session that `ws create --claude` opens.

## Setup

### Homebrew (team install)

If a tap has been published (see [PACKAGING.md](PACKAGING.md)):

```bash
brew tap vinson-vinson-vinson/tap git@github.com:vinson-vinson-vinson/homebrew-tap.git
brew install vinson-vinson-vinson/tap/workspace-management

# One-time config (brew prints this in its caveats):
mkdir -p ~/.config/workspace-management
cp "$(brew --prefix)/share/workspace-management/config.example.sh" \
   ~/.config/workspace-management/config.sh
$EDITOR ~/.config/workspace-management/config.sh
```

### From a git clone

```bash
git clone <your-fork-url> workspace-management
cd workspace-management

# Copy the template and edit it for your machine.
cp config.example.sh config.sh
$EDITOR config.sh

# (optional) install the command onto your PATH — adds `workspaces` and `ws`:
./install.sh                 # symlinks into ~/.local/bin (override: ./install.sh ~/bin)
```

The `workspaces` command is committed executable, so a fresh clone can run it
directly (`./workspaces help`) with no `chmod` needed. `install.sh` symlinks both
`workspaces` and its short alias `ws` into a bin directory so you can call them
from anywhere; the symlinks point back at the checkout, so `git pull` updates the
command in place. (It also removes the stale `create-workspace`/`serve-workspace`/…
symlinks from the old layout — repoint any `sws`-style shell alias to `ws serve`.)

`config.sh` is gitignored, so your local paths never get committed. `workspaces`
looks for its config in this order:

1. `$WSM_CONFIG`, if set (explicit override)
2. `config.sh` next to the `workspaces` command (git-clone / `install.sh` layout)
3. `~/.config/workspace-management/config.sh` (`$XDG_CONFIG_HOME`; Homebrew layout)

So a git clone keeps `config.sh` in the checkout, a brew install keeps it under
`~/.config`, and either way you can override with `WSM_CONFIG`:

```bash
WSM_CONFIG=~/dotfiles/wsm.config.sh ws list
```

## Configuration

All settings are documented inline in [`config.example.sh`](config.example.sh).
The essentials:

| Setting | Meaning |
| --- | --- |
| `ROOT_DIR` | Directory holding your two repos and `worktrees/`. |
| `FRONTEND_DIR_NAME` / `BACKEND_DIR_NAME` | Directory names of the two repos. |
| `FRONTEND_REPO` / `BACKEND_REPO` | Full paths to the main clones. |
| `WORKTREES_ROOT` | Where session worktrees are created. |
| `FRONTEND_BASE_BRANCH` / `BACKEND_BASE_BRANCH` | Branch new worktrees are cut from. |
| `TASK_ID_PREFIX` | Prefix that marks a "task" workspace (default `CU`, for ClickUp). |
| `BASE_DOMAIN`, `ADMIN_PATH`, `PORT_RANGE_START`, `VALET_*` | `ws serve` routing. |
| `APPS`, `DEFAULT_APPS` | Frontend app registry (`key:dir:route:port-offset`). |

### Task vs. plain workspaces

Slugs come in two shapes:

- **Task workspace** — `CU-1234_my-feature` (`<TASK_ID_PREFIX>-<id>_<feature>`).
  Gets a short derived subdomain from the task id (`cu-1234.<domain>`).
- **Plain workspace** — any other name (`admin-test`, `test-123`, `my-feature`).
  Served under a subdomain derived from the whole slug (`admin-test.<domain>`).

Both kinds can be created, served, and removed — names are effectively
unrestricted. The only thing `serve`/`remove` refuse is a worktree sitting on a
protected base branch (main/master or your configured base branch), so your main
checkout is never overwritten or deleted.

`TASK_ID_PREFIX` is matched case-insensitively; set it to your own tracker's
prefix (e.g. `JIRA`, `ENG`) or keep `CU`. It only governs the *short* subdomain
form — it no longer gates which workspaces may be served or removed.

## Usage

```bash
# Create a task workspace (adds worktrees, opens VS Code)
ws create CU-1234_my-feature

# Also open a Claude Code session (opt-in); or just preview
ws create CU-1234_my-feature --claude
ws create CU-1234_my-feature --dry-run

# List everything (the workspace you're in is starred); bare `ws` also lists
ws
ws list --quiet

# Serve at https://cu-1234.<domain> — from inside the worktree, no slug needed
cd worktrees/CU-1234_my-feature && ws serve
ws serve CU-1234_my-feature --all-apps                # every app in the registry

# Tear it down (auto-detects the slug from your cwd inside the worktree)
ws remove                                             # safe: refuses on unpushed work
ws remove CU-1234_my-feature --force                  # discard local-only work
```

Every subcommand accepts `--dry-run` to print actions without executing them, and
`-h`/`--help` for full option lists. `ws serve` does **not** start the dev
servers — it prints the `yarn serve-*` commands for you to run.

## How it fits together

1. `ws create` cuts matching branches in both repos into a shared session
   directory and opens it.
2. `ws serve` (optional) copies each repo's env into the worktree, rewrites only
   the self-domain and dev-server ports (DB, keys, and shared infra keep pointing
   at your main setup), and adds an nginx block so the whole workspace answers on
   one subdomain.
3. `ws list` shows what's live and where.
4. `ws remove` reverses all of it, with guards against losing unpushed work.

## License

[MIT](LICENSE)
