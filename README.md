# workspace-management

> **macOS only** (for now). It relies on BSD `sed`, `open`, the `code`
> CLI, and Laravel Valet. Linux support isn't there yet.

**TL;DR** — `ws create <slug>` spins up an isolated workspace (frontend + backend
git worktrees on their own branch) and opens VS Code; `ws serve` puts it on its
own local subdomain; `ws list` shows them; `ws remove` tears it down. Run several
tasks in parallel without them colliding.

A "workspace" is one self-contained session directory holding a **frontend** and
a **backend** worktree of two sibling repos, cut from the same branch, plus the
VS Code workspace file that opens them together (see
[Directory structure](#directory-structure)).

The tooling was extracted from a specific two-repo setup (a Nuxt-style
multi-app frontend + a Laravel/PHP backend, served through Laravel Valet), but
**all machine- and project-specific values live in a single `config.sh`**, so it
adapts to your own repos, branches, domain, and app layout.

## Requirements

- **macOS** — required for now; it uses BSD `sed` (`sed -i ''`), `open`, and the `code` CLI.
- **git** with worktree support.
- **VS Code** with the `code` command on your `PATH` (for `ws create`).
- **python3** — for `ws sync` (keeps each workspace's Source Control ignore-list
  current); usually already present, and skipped with a warning if not.
- For `ws serve` only: **Laravel Valet** (nginx + a wildcard cert for
  your domain), `nginx`, `yarn`, and `sudo` access to reload nginx. If you don't
  serve workspaces you can ignore that command entirely.

## Install

Two ways in. Either way you get two command names — `workspaces` and its short
alias **`ws`** — and you supply a machine-specific `config.sh` (see
[Configuration](#configuration)).

Before it works, edit at least these in `config.sh`: **`ROOT_DIR`** (where your
two repos live), **`WORKSPACES_ROOT`** (where session worktrees get created,
usually `$ROOT_DIR/workspaces`), and — if you use `ws serve` — **`BASE_DOMAIN`**.
Use a reserved dev TLD like `.test` (e.g. `anny.test`) rather than `.dev`: `.dev`
is a real, HSTS-preloaded TLD and browsers force HTTPS on it, which fights local
serving.

### 1. Homebrew (team install)

```bash
brew tap vinson-vinson-vinson/tap git@github.com:vinson-vinson-vinson/homebrew-tap.git
brew install vinson-vinson-vinson/tap/workspace-management

# One-time config (brew prints this in its caveats):
mkdir -p ~/.config/workspace-management
cp "$(brew --prefix)/share/workspace-management/config.example.sh" \
   ~/.config/workspace-management/config.sh
$EDITOR ~/.config/workspace-management/config.sh
```

`brew upgrade workspace-management` pulls new releases. See
[PACKAGING.md](PACKAGING.md) for how releases are cut.

### 2. Git clone

```bash
git clone git@github.com:vinson-vinson-vinson/workspace-management.git
cd workspace-management

# Copy the template and edit it for your machine.
cp config.example.sh config.sh
$EDITOR config.sh

# (optional) put the command on your PATH — adds `workspaces` and `ws`:
./install.sh                 # symlinks into ~/.local/bin (override: ./install.sh ~/bin)
```

The `workspaces` command is committed executable, so a fresh clone runs directly
(`./workspaces help`) with no `chmod`. `install.sh` symlinks `workspaces` and
`ws` into a bin directory; the symlinks point back at the checkout, so `git pull`
updates the command in place. If `~/.local/bin` isn't on your `PATH`, `install.sh`
tells you the line to add.

## Configuration

`config.sh` is gitignored, so your local paths never get committed. `workspaces`
finds its config in this order:

1. `$WSM_CONFIG`, if set (explicit override)
2. `config.sh` next to the `workspaces` command (git-clone / `install.sh` layout)
3. `~/.config/workspace-management/config.sh` (`$XDG_CONFIG_HOME`; Homebrew layout)

```bash
WSM_CONFIG=~/dotfiles/wsm.config.sh ws list   # override anytime
```

Every setting is documented inline in [`config.example.sh`](config.example.sh).
The essentials:

| Setting | Meaning |
| --- | --- |
| `ROOT_DIR` | Directory holding your two repos and `workspaces/`. |
| `FRONTEND_DIR_NAME` / `BACKEND_DIR_NAME` | Directory names of the two repos. |
| `FRONTEND_REPO` / `BACKEND_REPO` | Full paths to the main clones. |
| `WORKSPACES_ROOT` | Where session worktrees are created. |
| `FRONTEND_BASE_BRANCH` / `BACKEND_BASE_BRANCH` | Branch new worktrees are cut from. |
| `TASK_ID_PREFIX` | Prefix that marks a "task" workspace (default `CU`, for ClickUp). |
| `BASE_DOMAIN`, `ADMIN_PATH`, `PORT_RANGE_START`, `VALET_*` | `ws serve` routing. |
| `APPS`, `DEFAULT_APPS` | Frontend app registry (`key:dir:route:port-offset`). |

**Task vs. plain slugs.** A `CU-1234_my-feature` slug
(`<TASK_ID_PREFIX>-<id>_<feature>`) gets a short subdomain from the task id
(`cu-1234.<domain>`); any other name (`admin-test`, `my-feature`) is served under
a subdomain derived from the whole slug. Both are created, served, and removed
the same way — the only thing `serve`/`remove` refuse is a worktree on a
protected base branch, so your main checkout is never touched.

## Workflow and commands

Typical flow — `create` → `serve` → `list` → `remove`:

1. **create** — cut matching branches in both repos into one session dir; VS Code
   opens and auto-starts one terminal each for `ws serve` and the default apps'
   `yarn serve-<app>` dev servers (opt out with `--neanderthal`).
2. **serve** (optional) — the workspace answers on its own subdomain. Only the
   self-domain and dev-server ports are rewritten, so the DB, keys, and shared
   infra keep pointing at your main setup. Then start the dev servers it prints.
3. **list** — see what's live and where.
4. **remove** — reverses everything, guarding against unpushed work.

Everything is one command, `workspaces` (alias `ws`), with subcommands:

| Command | What it does |
| --- | --- |
| `ws create <slug>` | Create (or reopen) a workspace: add both worktrees, write a `.code-workspace`, open VS Code. On open, VS Code auto-runs `ws serve` and then `yarn serve-<app>` per default app, each in its own terminal; `--neanderthal` skips those tasks. |
| `ws list` (or bare `ws`) | List all workspaces, star the one you're in, link each served one to its landing URL. |
| `ws serve [slug]` | Make a workspace reachable at `<sub>.<domain>` via Valet/nginx: rewrite envs, write the nginx block, install deps. Slug defaults to the current directory. Does **not** start dev servers — it prints the `yarn serve-*` commands. |
| `ws remove [slug]` | Tear a workspace down safely: revert routing, remove worktrees, delete branches, clean the session dir. Refuses on unpushed work unless `--force`. Slug defaults to cwd. |
| `ws sync` | Recompute each workspace's VS Code Source Control ignore-list so every window shows only its own two worktrees. Runs automatically on `create`/`remove`. |
| `ws help` / `ws version` | Banner + command overview / print the version. |

Every subcommand takes `--dry-run` (print actions without doing them) and
`-h`/`--help`. Add `-v` for full step-by-step detail.

```bash
ws create CU-1234_my-feature                 # worktrees + VS Code
cd workspaces/CU-1234_my-feature && ws serve # serve the one you're in
ws serve CU-1234_my-feature --all-apps       # every app in the registry
ws                                           # list (bare `ws`)
ws remove                                     # tear down (auto-detects slug from cwd)
ws remove CU-1234_my-feature --force          # discard local-only work
```

## OAuth config: wildcard redirects

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

## Directory structure

What lives where on disk once you're set up:

```
<ROOT_DIR>/                          # your projects root (config: ROOT_DIR)
├── <frontend-repo>/                 # main frontend clone (FRONTEND_REPO)
├── <backend-repo>/                  # main backend clone  (BACKEND_REPO)
└── workspaces/                      # all session worktrees (WORKSPACES_ROOT)
    └── CU-1234_my-feature/          # one workspace = one session dir (the slug)
        ├── <frontend-repo>/         #   frontend worktree on branch CU-1234_my-feature
        ├── <backend-repo>/          #   backend  worktree on branch CU-1234_my-feature
        └── CU-1234_my-feature.code-workspace   # the VS Code workspace file
```

- **The two main clones stay put.** `ws create` never touches them beyond adding
  a git *worktree* — a second working copy of the same repo, on its own branch,
  sharing the original's `.git`. That's why a workspace is cheap to spin up and
  throw away.
- **Each workspace is one self-contained session dir** under `WORKSPACES_ROOT`,
  named by its slug. It holds both worktrees plus the `.code-workspace` file that
  opens them together — so removing the workspace is just deleting this directory
  (which `ws remove` does, after its safety checks).
- **`ws serve` adds gitignored files inside the worktrees** — rewritten `.env`s, a
  cloned `vendor/`, an installed `node_modules/` — none of which touch your main
  clones. They vanish with the session dir on `ws remove`.
- **The tooling itself** (this repo) lives wherever you cloned it; only `config.sh`
  ties it to the `ROOT_DIR` above.

## License

[MIT](LICENSE)
