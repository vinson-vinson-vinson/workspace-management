# workspace-management

> **macOS only** (for now). It relies on BSD `sed`, `open`, the `code`
> CLI, and Laravel Valet. Linux support isn't there yet.

**TL;DR** — `ws create <slug>` spins up an isolated workspace (frontend + backend
git worktrees on their own branch) and opens VS Code; `ws serve` puts it on its
own local subdomain; `ws list` shows them; `ws remove` tears it down. Run several
tasks in parallel without them colliding. Setup: copy `config.example.sh` →
`config.sh`, then `./install.sh`.

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
| `ws create <slug> [opts]` | Create (or reopen) a workspace: adds the two worktrees, writes a `.code-workspace` file, and opens VS Code. |
| `ws list` &nbsp;(or bare `ws`) | List all workspaces, star the one you're in, and link each served workspace to its landing URL. |
| `ws serve [slug] [opts]` | Make a workspace reachable at `<sub>.<domain>` via Valet/nginx: copies + rewrites envs, writes an nginx block, installs deps (`yarn` frontend, cloned vendor backend), and generates the Nuxt scaffolding. Slug defaults to the current directory. |
| `ws remove [slug] [opts]` | Tear a workspace down safely: reverts routing, removes worktrees, deletes local branches, cleans the session dir. Refuses on unpushed work unless `--force`. Slug defaults to the current directory. |
| `ws sync` | Recompute each workspace's VS Code Source Control ignore-list so every window shows only its own two worktrees (hiding the other workspaces' worktrees and the main clones). Runs automatically on `create`/`remove`; use this for a manual re-sync. |
| `ws help` / `ws version` | Banner + command overview / print the version. |

Run `ws <command> --help` for per-command options.

## Requirements

- **macOS** — required for now; it uses BSD `sed` (`sed -i ''`), `open`, and the `code` CLI.
- **git** with worktree support.
- **VS Code** with the `code` command on your `PATH` (for `ws create`).
- **python3** — for `ws sync` (keeps each workspace's Source Control ignore-list
  current); usually already present, and skipped with a warning if not.
- For `ws serve` only: **Laravel Valet** (nginx + a wildcard cert for
  your domain), `nginx`, `yarn`, and `sudo` access to reload nginx. If you don't
  serve workspaces you can ignore that command entirely.

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
command in place.

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

`TASK_ID_PREFIX` (case-insensitive; default `CU`, e.g. `JIRA`/`ENG`) only governs
the *short* subdomain form — it doesn't gate which workspaces may be served or removed.

## Usage

```bash
# Create a task workspace (adds worktrees, opens VS Code)
ws create CU-1234_my-feature

# Preview without doing anything
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

## Typical workflow

`create` → `serve` → `list` → `remove`:

1. **create** — cut matching branches in both repos into one session dir; VS Code opens.
2. **serve** (optional) — the workspace answers on its own subdomain. Only the
   self-domain and dev-server ports are rewritten, so the DB, keys, and shared
   infra keep pointing at your main setup.
3. **list** — see what's live and where.
4. **remove** — reverses everything, guarding against unpushed work.

## Auth on served subdomains (OAuth wildcard redirects)

A served workspace answers on a subdomain (`cu-1234.anny.dev`) but still
authenticates against your **main** OAuth server. That server must accept the
subdomain as a valid redirect target — otherwise the page loads and then auth
fails with *"authorization is invalid"*. Enable wildcard redirects **per OAuth
client**, once:

1. **Ensure the `allow_wildcard_redirect` column exists** (once per database):

   ```bash
   /opt/homebrew/opt/php@8.4/bin/php artisan migrate
   ```

2. **Set the flag and add the `*.` subdomain variant** to the client's existing
   redirect URL:

   ```sql
   UPDATE oauth_clients
   SET redirect = 'https://anny.dev/admin/login/callback,https://*.anny.dev/admin/login/callback',
       allow_wildcard_redirect = 1
   WHERE name = 'admin';
   ```

   The existing URL is kept; the `*.` variant is added alongside it. Repeat for
   each client, using that client's own callback path.

## License

[MIT](LICENSE)
