# workspace-management

> **macOS only** (for now). The scripts rely on BSD `sed`, `open`, the `code`
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
├── worktrees/
│   └── CU-1234_my-feature/          # a workspace ("session")
│       ├── <frontend-repo>/         #   frontend worktree on branch CU-1234_my-feature
│       └── <backend-repo>/          #   backend  worktree on branch CU-1234_my-feature
└── CU-1234_my-feature.code-workspace
```

The tooling was extracted from a specific two-repo setup (a Nuxt-style
multi-app frontend + a Laravel/PHP backend, served through Laravel Valet), but
**all machine- and project-specific values live in a single `config.sh`**, so it
adapts to your own repos, branches, domain, and app layout.

## Scripts

| Script | What it does |
| --- | --- |
| `create-workspace.sh` | Create (or reopen) a workspace: adds the two worktrees, writes a `.code-workspace` file, and opens VS Code. Optionally opens a Claude Code session with `--claude`. Also `--remove`. |
| `remove-workspace.sh` | Tear a workspace down safely: reverts routing, removes worktrees, deletes local branches, and cleans the session dir. Refuses to run on unpushed work unless `--force`. |
| `list-workspaces.sh` | List all current workspaces, star the one you're in, and link each served workspace to its landing URL. |
| `serve-workspace.sh` | Make a workspace reachable at `<sub>.<domain>` via Valet/nginx: copies + rewrites envs, writes an nginx block, then installs dependencies (`yarn` for the frontend, cloned vendor for the backend) and generates the Nuxt scaffolding. |

## Requirements

- **macOS** — required for now; the scripts use BSD `sed` (`sed -i ''`), `open`, and the `code` CLI.
- **git** with worktree support.
- **VS Code** with the `code` command on your `PATH` (for `create-workspace.sh`).
- For `serve-workspace.sh` only: **Laravel Valet** (nginx + a wildcard cert for
  your domain), `nginx`, and `sudo` access to reload nginx. If you don't serve
  workspaces you can ignore this script entirely.
- Optional: the **Claude** desktop app, for the opt-in `claude://` deep-link
  session that `create-workspace.sh --claude` opens.

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

# (optional) install the commands onto your PATH by bare name:
#   create-workspace  remove-workspace  list-workspaces  serve-workspace
./install.sh                 # symlinks into ~/.local/bin (override: ./install.sh ~/bin)
```

The scripts are committed with the executable bit set, so a fresh clone can run
them directly (`./list-workspaces.sh`) with no `chmod` needed. `install.sh` just
symlinks them (minus the `.sh`) into a bin directory so you can call them from
anywhere; the symlinks point back at the checkout, so `git pull` updates the
commands in place.

`config.sh` is gitignored, so your local paths never get committed. Every script
looks for its config in this order:

1. `$WSM_CONFIG`, if set (explicit override)
2. `config.sh` next to the scripts (git-clone / `install.sh` layout)
3. `~/.config/workspace-management/config.sh` (`$XDG_CONFIG_HOME`; Homebrew layout)

So a git clone keeps `config.sh` in the checkout, a brew install keeps it under
`~/.config`, and either way you can override with `WSM_CONFIG`:

```bash
WSM_CONFIG=~/dotfiles/wsm.config.sh ./list-workspaces.sh
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
| `BASE_DOMAIN`, `ADMIN_PATH`, `PORT_RANGE_START`, `VALET_*` | `serve-workspace.sh` routing. |
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
./create-workspace.sh CU-1234_my-feature

# Also open a Claude Code session (opt-in); or just preview
./create-workspace.sh CU-1234_my-feature --claude
./create-workspace.sh CU-1234_my-feature --dry-run

# List everything (the workspace you're in is starred)
./list-workspaces.sh

# Serve a task workspace at https://cu-1234.<domain>
cd worktrees/CU-1234_my-feature && ../../workspace-management/serve-workspace.sh
serve-workspace.sh CU-1234_my-feature --all-apps      # every app in the registry

# Tear it down (auto-detects the slug from your cwd inside the worktree)
./remove-workspace.sh                                 # safe: refuses on unpushed work
./remove-workspace.sh CU-1234_my-feature --force      # discard local-only work
```

Most commands accept `--dry-run` to print actions without executing them, and
`-h`/`--help` for full option lists. `serve-workspace.sh` does **not** start the
dev servers — it prints the `yarn serve-*` commands for you to run.

## How it fits together

1. `create-workspace.sh` cuts matching branches in both repos into a shared
   session directory and opens it.
2. `serve-workspace.sh` (optional) copies each repo's env into the worktree,
   rewrites only the self-domain and dev-server ports (DB, keys, and shared
   infra keep pointing at your main setup), and adds an nginx block so the whole
   workspace answers on one subdomain.
3. `list-workspaces.sh` shows what's live and where.
4. `remove-workspace.sh` reverses all of it, with guards against losing unpushed
   work.

## License

[MIT](LICENSE)
