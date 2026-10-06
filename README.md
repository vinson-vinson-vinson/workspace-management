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
  your domain), `nginx`, `yarn`, and `sudo` access to reload nginx. Or, with
  `RUNTIME="docker"`, **Docker** instead of Valet; see
  [Runtime: Valet or Docker](#runtime-valet-or-docker). If you don't serve
  workspaces you can ignore that command entirely.

## Install

You get two command names — `workspaces` and its short alias **`ws`** — and you
supply a machine-specific `config.sh` (see [Configuration](#configuration)).

Before it works, edit at least these in `config.sh`: **`ROOT_DIR`** (where your
two repos live), **`WORKSPACES_ROOT`** (where session worktrees get created,
usually `$ROOT_DIR/workspaces`), and — if you use `ws serve` — **`BASE_DOMAIN`**.
Use a reserved dev TLD like `.test` (e.g. `anny.test`) rather than `.dev`: `.dev`
is a real, HSTS-preloaded TLD and browsers force HTTPS on it, which fights local
serving.

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
3. `~/.config/workspace-management/config.sh` (`$XDG_CONFIG_HOME`)

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
| `FRONTEND_REMOTE` / `BACKEND_REMOTE` | Git remote each repo fetches from and pushes to (both default to `origin`). Per repo, so a forked frontend and an upstream backend both work. `--remote <name>` on `create`/`open`/`mr` overrides both for one run. |
| `FRONTEND_IDE` / `BACKEND_IDE` | IDE each repo opens in: `vscode` (default), `phpstorm`, `webstorm`, or `zed`. Same value → one combined window; different values → separate windows per worktree. |
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
| `ws create <slug> [base[@remote]]` | Create (or reopen) a workspace: add both worktrees, write a `.code-workspace`, open the configured IDE(s) (`FRONTEND_IDE`/`BACKEND_IDE`, VS Code by default). An optional second argument bases the branches on an existing branch instead of the configured base; `branch@remote` takes it from another git remote (e.g. a bot branch on a GitHub fork). When that's VS Code, it auto-runs `ws serve` and then `yarn serve-<app>` per default app, each in its own terminal; `--neanderthal` skips those tasks. |
| `ws list` (or bare `ws`) | List all workspaces, star the one you're in, link each served one to its landing URL. The `#` column numbers the rows for `ws open`. |
| `ws open <N\|slug>` | Open a workspace by its `ws list` index (or slug) in the IDE(s) named by `FRONTEND_IDE`/`BACKEND_IDE` — VS Code by default, or PhpStorm/WebStorm/Zed. Same IDE on both sides → one combined window; different IDEs → each worktree opens separately. Index 0 (or `MAIN`) opens the main workspace (`MAIN_WORKSPACE_FILE`, or both main repos). A **slug with no workspace behind it is created first** (`--no-create` opts out; `--remote`/`--base` say where the branch comes from), which is what makes an `ws://open/<slug>` link work on a machine that has never seen that workspace. |
| `ws serve [slug]` | Make a workspace reachable at `<sub>.<domain>` via Valet/nginx: rewrite envs, write the nginx block, install deps. Slug defaults to the current directory. Does **not** start dev servers — it prints the `yarn serve-*` commands. |
| `ws recolor [N\|slug]` | Give a workspace a new accent color, drawn from the same picker `ws create` uses (random, from the unused colors farthest from everything live — its own current color included, so the result always looks different). Rewrites only the color keys in the `.code-workspace`; an open VS Code window updates at once. `--color '#rrggbb'` sets an exact color. Slug defaults to cwd. |
| `ws remove [slug]` | Tear a workspace down safely: revert routing, remove worktrees, delete branches, clean the session dir. Refuses on unpushed work unless `--force`. Slug defaults to cwd. |
| `ws test [slug] [args]` | Run the backend suite against the workspace's **own** MySQL test DB (created on demand; args pass through to phpunit), so concurrent runs in different workspaces can't `migrate:fresh` over each other. Fails closed: no isolated DB → no run. Slug defaults to cwd. |
| `ws trust` | One-time sudoers rule (like `valet trust`) so `ws serve` can test/reload nginx without password prompts. Covers exactly `nginx -t` and `nginx -s reload`; never stores the password. `--revoke` removes it. |
| `ws url` | Clickable `ws://` deep links: `--install` registers a tiny macOS handler app, `--link <slug>` prints a link to paste into a task or an MR. Following a link runs the matching `ws create`/`open`/`serve` in a new terminal window. See [Deep links](#deep-links). |
| `ws sync` | Recompute each workspace's VS Code Source Control ignore-list so every window shows only its own two worktrees. Runs automatically on `create`/`remove`. |
| `ws help` / `ws version` | Banner + command overview / print the version. |

Every subcommand takes `--dry-run` (print actions without doing them) and
`-h`/`--help`. Add `-v` for full step-by-step detail.

```bash
ws create CU-1234_my-feature                 # worktrees + VS Code
ws create form-timing cursor/some-branch@github  # base on a branch from another remote
cd workspaces/CU-1234_my-feature && ws serve # serve the one you're in
ws serve CU-1234_my-feature --all-apps       # every app in the registry
ws                                           # list (bare `ws`)
ws remove                                     # tear down (auto-detects slug from cwd)
ws remove CU-1234_my-feature --force          # discard local-only work
```

## Deep links

`ws url --install` builds a small AppleScript app in `~/Applications` and
registers it as the owner of the `ws://` scheme, so a link in a ClickUp task, an
MR description or a chat message can open the workspace for that task:

```bash
ws url --install                                    # one-time
ws url --link CU-1234_my-feature                    # -> ws://create/CU-1234_my-feature
ws url --link CU-1234_my-feature --base CU-1200_parent
ws url --link CU-1234_my-feature --verb open        # -> ws://open/CU-1234_my-feature
ws url --link CU-1234_my-feature --verb open --remote upstream
```

| Link | Runs |
| --- | --- |
| `ws://open?branch=<name>` | `ws open --branch <name>` — workspace named after the branch |
| `ws://create/<slug>?branch=<name>&base=<branch>&remote=<name>&bare=1` | `ws create <slug> [base] [--branch name] [--remote name] [--neanderthal]` |
| `ws://open/<slug>?branch=<name>&remote=<name>&base=<branch>` | `ws open <slug> [--branch name] [--remote name] [--base branch]` |
| `ws://serve/<slug>?all-apps=1` | `ws serve <slug> [--all-apps]` |

**A branch is not a slug.** A workspace slug is a directory name, so it can't
contain `/` — which is exactly what an agent branch like
`cursor/anny-customer-stateless-mcp-05ff` has. The branch therefore travels in
its own `branch` field, and the workspace takes the branch's **last segment**:
that link opens the workspace `anny-customer-stateless-mcp-05ff` with both
worktrees checked out on `cursor/anny-customer-stateless-mcp-05ff`. Since the
branch already names the workspace, the link needs nothing else:

```bash
ws url --link --verb open --branch cursor/anny-customer-stateless-mcp-05ff
# -> ws://open?branch=cursor/anny-customer-stateless-mcp-05ff
```

Pass a slug as well (`ws url --link CU-1234_x --branch cursor/…`) when you want
the workspace called something other than the branch tail — two namespaces with
the same tail (`cursor/foo`, `codex/foo`) would otherwise want the same
workspace.

`remote` and `base` matter on an **open** link too, because opening a slug the
machine doesn't have creates it first: they decide which remote the branch is
fetched from and what it's cut from if it doesn't exist yet. `remote` is a
remote *name* the repos already have (`FRONTEND_REMOTE`/`BACKEND_REMOTE`), never
a URL — a link can pick between your remotes, it can't introduce one.

The slug can also travel as a query field (`ws://open?slug=<slug>`), which is
what most trackers produce when you build a link in their UI. Clicking a link
opens a terminal (`TERMINAL_APP`: a Terminal.app window, a new Warp window, or
with `warp-tabs` a tab in your current Warp window) running the command, so you
see its output and `serve` can still ask for sudo. `ws url '<link>' --print` resolves a
link to the command without running it.

**What a link cannot do.** A link that reaches you from outside is untrusted
input that ends in an exec, so the verb is a whitelist (`create`, `open`,
`serve`) and every field is validated against a strict character class before it
touches a command line. `remove` is deliberately not linkable — one click should
never be able to tear a workspace down.

One detail worth knowing: the app hard-codes the path of this checkout, so
re-run `ws url --install` if you move it. Following a link needs no permission
grant — the command runs through a generated `.command` file opened with
`open`, not an AppleScript Apple Event, which would put a one-time Automation
consent dialog between the click and the window. `WSM_URL_SCHEME` and
`WSM_URL_APP` override the scheme and the bundle location — Launch Services
only routes links to an app that lives in `~/Applications` or `/Applications`.
Remove it all again with `ws url --uninstall`.

The other deep link needs no handler at all: a served workspace is a plain
`https://<sub>.<domain>` URL, which `ws list` and `ws url --link` both print.

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

## Runtime: Valet or Docker

`ws serve` needs an nginx and a php-fpm on `127.0.0.1`. `RUNTIME` in `config.sh` picks where
they come from:

| | `valet` (default) | `docker` |
|---|---|---|
| nginx + php-fpm | Laravel Valet, installed on the Mac | two containers on the host network: nginx, and your backend's own **production php-fpm image** (`WS_PHP_IMAGE`) with dev settings (opcache revalidates, workers start on demand) |
| PHP version | whatever Homebrew has | the version and build production runs |
| Reloading nginx | `sudo` (or `ws trust`) | no sudo |
| `ws test`, the queue tab | host `php`, host `mysql` client | inside the php container; no host PHP or mysql client needed |

Everything else stays the same in both: the Nuxt dev servers run on the Mac (fast file watching),
MySQL, Redis and the other services are whatever the main `.env` points at, and the nginx block
`ws serve` writes per workspace has the same routes. On the host network, `127.0.0.1` in a
container is the Mac's `127.0.0.1`, so the copied `.env` files work unchanged.

**Switching to docker, once:**

1. Docker with host networking on macOS: [OrbStack](https://orbstack.dev) (recommended), or
   Docker Desktop with host networking turned on.
2. `WS_PHP_IMAGE` in `config.sh`: the php-fpm image your backend runs in production (`ws` has
   no default for it). If its registry is private, `docker login <registry>` once.
3. `brew install mkcert && mkcert -install` (a trusted wildcard cert for `BASE_DOMAIN`). If you
   already secured the domain in Valet, its cert is reused.
4. In `config.sh`: `RUNTIME="docker"`. Then free ports 80/443 (`valet stop`) and run
   `ws runtime setup`. It makes the cert, checks DNS and ports, pulls the images and starts the
   runtime. `*.BASE_DOMAIN` has to resolve to `127.0.0.1`: Valet's dnsmasq already does that, and
   `ws runtime setup` prints the dnsmasq commands if it doesn't.

**Commands:**

```bash
ws runtime status        # containers, ports, served sites
ws runtime logs php      # follow one container (or both without a name)
ws runtime down          # stop; `ws serve` starts it again when needed
ws artisan migrate       # php artisan in the container, in the checkout you're in
ws php vendor/bin/phpunit --filter=Foo
```

The main checkouts are served at `https://BASE_DOMAIN`, like `valet link` did. The queue tab
defaults to `ws artisan horizon`, which runs Horizon in the container.

**Footprint:** about 250 MB for the whole runtime, however many workspaces it serves: nginx
takes about 10 MB, and the php container about 240 MB idle, mostly opcache's shared memory, which
every workspace shares. Workers start per request and stop after 60 s idle, so an idle workspace
adds nothing. The Nuxt dev servers run on the Mac as before.

**Settings:** `WS_PHP_IMAGE` is required (step 2 above); the rest are optional: `WS_HTTP_PORT` / `WS_HTTPS_PORT`
(default 80/443), `WS_PHP_PORT` (default 9074), `WS_CERT` / `WS_CERT_KEY`, `WS_RUNTIME_DIR`
(generated compose file, nginx config, certs and site blocks; default
`~/.config/workspace-management/runtime`). Other ports than 443 are for trying the runtime next
to a running Valet: the URLs `ws` prints carry the port, but the `.env` files it copies don't.

## Hooks

Splice machine-specific steps into a command's lifecycle with **hooks** — small
executable scripts the tool runs at a defined point. Two events:

| Event | When it runs |
| --- | --- |
| `post-create` | During `ws create`, after the workspace is provisioned and its `.code-workspace` is written, **before the IDE opens**. A failing hook only **warns** — it never undoes the create. |
| `pre-remove` | During `ws remove`, after you confirm and **before anything is deleted** (both worktrees still exist). A hook that exits non-zero **aborts** the removal, so nothing is lost. |

Hooks live in `$WSM_HOOKS_DIR/<event>/` (default `hooks/` next to the command),
which is **gitignored** — like `config.sh`, it's yours per machine. The repo
ships templates under [`hooks.example/`](hooks.example/); copy them in and mark
them executable to enable:

```bash
cp -R hooks.example/ hooks/
chmod +x hooks/**/*.sh
```

Every executable file in the event dir runs in lexical order. Each is a normal
process; the tool exports the context it needs:

| Variable | Meaning |
| --- | --- |
| `WS_SLUG` | The workspace slug. |
| `WS_SESSION_DIR` | The session directory (parent of both worktrees). |
| `WS_FRONTEND` / `WS_BACKEND` | The two worktree paths. |
| `WS_FRONTEND_DIR_NAME` / `WS_BACKEND_DIR_NAME` | The repo directory names. |
| `WS_WORKSPACE_FILE` | The `.code-workspace` file (`post-create` only). |

The shipped examples pair up: `post-create/init-planning.sh` gives a new
workspace a session-local `planning/` directory (a sibling of the worktrees,
outside both repos, so it's never git-tracked) and adds it to the VS Code
window; `pre-remove/backup-planning.sh` then copies that `planning/` to
`~/Projects/ws_docs/<slug>/` before teardown (destination overridable with
`WS_DOCS_DIR`). Both `ws create` and `ws remove` support `--dry-run`, which
lists the hooks they would run without executing them.

## Per-workspace Chrome (MCP)

Optional. If you drive a browser from Claude via the
[Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp), a
single shared server makes every workspace fight over **one** browser — one
"selected page", one profile — so parallel sessions clobber each other.
[`bin/chrome-mcp-launch.sh`](bin/chrome-mcp-launch.sh) gives **each workspace its
own isolated Chrome** instead.

Register it **once**, user-scoped (run from the repo root), then drop the old
shared server so you don't get a stray extra browser:

```bash
claude mcp add chrome -s user -- "$PWD/bin/chrome-mcp-launch.sh"
claude mcp remove chrome-devtools -s user   # if you had the shared one
```

How it works: Claude Code spawns an MCP server with its working directory set to
wherever you launched `claude`. The launcher reads that **real** directory
(`pwd -P`, never `$PWD` — an IDE can leak a stale one from another window),
derives the workspace slug, and hands Chrome a persistent per-slug profile at
`~/.chrome-mcp/<slug>`. So browsers in different workspaces never collide, logins
persist, and there's nothing for the agent to pick — the profile follows the
directory you run `claude` in. This is needed because Claude Code collapses a git
worktree onto its main repo for MCP config, which makes a per-worktree
registration impossible; keying off the spawn directory sidesteps that. Each
window is tinted to its workspace's accent color (the `.code-workspace`
`titleBar.activeBackground`, via Chrome's `--install-autogenerated-theme`) so the
browsers are distinguishable at a glance. Outside a workspace it falls back to a
shared `_default` profile.

Requires the `claude` CLI and `chrome-devtools-mcp` (fetched via `npx`). It's a
single global registration — **not** wired into `ws create` and **not**
auto-enabled by `git pull`; each person opts in with the command above.

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
