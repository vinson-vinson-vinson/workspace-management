#!/usr/bin/env node
// ws-ui — a tiny local dashboard over the `ws` workspace-management CLI.
// Zero dependencies. Run: `ws ui` (or node ui/server.mjs)
//
//   GET  /                      dashboard
//   GET  /api/workspaces        MAIN + every workspace, with status
//   POST /api/open    {slug}    ws open <slug>          (IDE switch)
//   POST /api/serve   {slug}    ws serve <slug>         (nginx routing)
//   POST /api/dev/start {slug,app}   yarn serve-<app> in the worktree (detached)
//   POST /api/dev/stop  {slug,app}   kill whatever listens on the app's port
//   POST /api/create  {slug}    ws create <slug>  (runs in Terminal.app)
//   GET  /api/logs?slug&app     tail of a dev-server log

import http from 'node:http';
import { spawn, execFile } from 'node:child_process';
import { readFile, readdir, mkdir, open as fsOpen } from 'node:fs/promises';
import { existsSync, readFileSync, createWriteStream } from 'node:fs';
import { promisify } from 'node:util';
import path from 'node:path';
import os from 'node:os';

const execFileP = promisify(execFile);
const HOME = os.homedir();
const PORT = Number(process.env.WS_UI_PORT || 7777);
// This file lives in <repo>/ui, so the dispatcher and config.sh are one level up.
// `ws ui` passes WSM_HOME/WSM_CONFIG explicitly; the fallbacks keep a bare
// `node ui/server.mjs` (and the Raycast script) working on their own.
const WSM_HOME = process.env.WSM_HOME || path.dirname(path.dirname(new URL(import.meta.url).pathname));
const WS_BIN = process.env.WS_BIN
  || (existsSync(`${WSM_HOME}/workspaces`) ? `${WSM_HOME}/workspaces` : null)
  || (existsSync(`${HOME}/.local/bin/ws`) ? `${HOME}/.local/bin/ws` : 'ws');
const CONFIG = process.env.WSM_CONFIG
  || (existsSync(`${WSM_HOME}/config.sh`) ? `${WSM_HOME}/config.sh` : `${HOME}/.config/workspace-management/config.sh`);
const LOG_DIR = `${HOME}/.ws-ui/logs`;
const HTML = new URL('./index.html', import.meta.url);
const BOOT_ID = Date.now().toString(36); // lets the page detect a restarted server and reload itself

// ---- config (read the few keys we need straight out of config.sh) ---------
function readConfig() {
  const cfg = {
    ROOT_DIR: `${HOME}/Desktop/code`,
    FRONTEND_DIR_NAME: 'anny-ui',
    BACKEND_DIR_NAME: 'bookings-api',
    BASE_DOMAIN: 'anny.test',
    ADMIN_PATH: '/admin/calendar',
    DEFAULT_APPS: ['admin', 'shop'],
    // key -> { dir, offset }  (mirrors APPS=("key:dir:route:offset") in config.sh)
    APPS: { admin: { dir: 'app-admin', offset: 1 }, shop: { dir: 'app-shop', offset: 2 }, account: { dir: 'app-account', offset: 3 },
            panels: { dir: 'app-panels', offset: 4 }, outlook: { dir: 'app-outlook', offset: 5 }, designer: { dir: 'app-designer', offset: 6 } },
  };
  try {
    const src = readFileSync(CONFIG, 'utf8');
    const get = (k) => src.match(new RegExp(`^${k}="?([^"\\n]*)"?`, 'm'))?.[1];
    for (const k of ['ROOT_DIR', 'FRONTEND_DIR_NAME', 'BACKEND_DIR_NAME', 'BASE_DOMAIN', 'ADMIN_PATH']) {
      const v = get(k);
      if (v) cfg[k] = v.replace('$HOME', HOME);
    }
    const da = src.match(/^DEFAULT_APPS=\(([^)]*)\)/m)?.[1];
    if (da) cfg.DEFAULT_APPS = da.trim().split(/\s+/);
    const apps = src.match(/^APPS=\(([\s\S]*?)^\)/m)?.[1];
    if (apps) {
      cfg.APPS = {};
      for (const m of apps.matchAll(/"([^:"]+):([^:"]+):([^:"]*):(\d+)"/g)) cfg.APPS[m[1]] = { dir: m[2], offset: Number(m[4]) };
    }
  } catch { /* fall back to defaults */ }
  cfg.WORKSPACES_ROOT = `${cfg.ROOT_DIR}/workspaces`;
  cfg.FRONTEND_REPO = `${cfg.ROOT_DIR}/${cfg.FRONTEND_DIR_NAME}`;
  cfg.BACKEND_REPO = `${cfg.ROOT_DIR}/${cfg.BACKEND_DIR_NAME}`;
  return cfg;
}
const cfg = readConfig();

// ---- shell helpers --------------------------------------------------------
// Login shell so nvm/yarn/ws on the user's PATH are found.
function sh(cmd, opts = {}) {
  return new Promise((resolve) => {
    execFile('/bin/zsh', ['-lc', cmd], { maxBuffer: 8 * 1024 * 1024, ...opts }, (err, stdout, stderr) => {
      resolve({ ok: !err, code: err?.code ?? 0, stdout: stdout ?? '', stderr: stderr ?? '' });
    });
  });
}
const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

async function gitBranch(repo) {
  const r = await execFileP('git', ['-C', repo, 'symbolic-ref', '--quiet', '--short', 'HEAD']).catch(() => null);
  return r?.stdout.trim() || '(detached)';
}
async function gitState(repo) {
  const r = await execFileP('git', ['-C', repo, 'status', '--porcelain']).catch(() => null);
  if (!r) return 'unknown';
  const n = r.stdout.split('\n').filter(Boolean).length;
  return n ? `uncommitted (${n})` : 'clean';
}
async function listeningPorts() {
  const r = await sh('lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk \'NR>1{print $9}\' | sed "s/.*://" | sort -u');
  return new Set(r.stdout.split('\n').filter(Boolean).map(Number));
}
function envPort(file) {
  try { return Number(readFileSync(file, 'utf8').match(/^PORT=(\d+)/m)?.[1]) || null; } catch { return null; }
}

// ---- data -----------------------------------------------------------------
// Every registered app that exists in the worktree, with its port. `ws status`
// only reports what `ws serve` proxies (DEFAULT_APPS unless --all-apps), but
// you can run any app's dev server regardless — designer, panels, …
function appsIn(fe, portFor, listening) {
  return Object.entries(cfg.APPS)
    .filter(([, a]) => existsSync(`${fe}/${a.dir}`))
    .map(([app, a]) => {
      const port = portFor(app, a);
      return { app, port, running: port ? listening.has(port) : false };
    })
    .filter((s) => s.port); // no known port → can't start/stop it sensibly
}

async function mainWorkspace(listening) {
  const fe = cfg.FRONTEND_REPO, be = cfg.BACKEND_REPO;
  const servers = appsIn(fe, (app, a) => envPort(`${fe}/${a.dir}/.env`), listening);
  return {
    slug: 'MAIN', index: 0, main: true,
    path: cfg.ROOT_DIR,
    served: true,
    url: `https://${cfg.BASE_DOMAIN}${cfg.ADMIN_PATH}`,
    frontend: { branch: await gitBranch(fe), git: await gitState(fe), servers },
    backend: { branch: await gitBranch(be), git: await gitState(be) },
  };
}

async function workspaceStatus(slug, index, listening) {
  const r = await sh(`${q(WS_BIN)} status ${q(slug)} --json`);
  if (!r.ok) return { slug, index, error: (r.stderr || r.stdout).trim() || 'status failed' };
  try {
    const j = JSON.parse(r.stdout);
    if (j.url && !/^https?:/.test(j.url)) j.url = `https://${j.url}`;
    // Extend the served-app list with the rest of the registry. The port base
    // is recovered from any app ws reported (port - offset), so we don't have
    // to re-implement the cksum-based allocation here.
    const reported = j.frontend?.servers || [];
    const known = reported.find((s) => cfg.APPS[s.app]?.offset && s.port);
    const base = known ? known.port - cfg.APPS[known.app].offset : null;
    if (base !== null) {
      const byApp = new Map(reported.map((s) => [s.app, s]));
      j.frontend.servers = appsIn(worktreeFor(slug), (app, a) => byApp.get(app)?.port ?? base + a.offset, listening)
        .map((s) => ({ ...byApp.get(s.app), ...s, proxied: byApp.has(s.app) }));
    }
    return { index, ...j };
  } catch {
    return { slug, index, error: 'unparseable status output' };
  }
}

async function allWorkspaces() {
  const r = await sh(`${q(WS_BIN)} list -q`);
  const slugs = r.stdout.split('\n').map((s) => s.trim()).filter((s) => s && s !== 'MAIN');
  const listening = await listeningPorts();
  const [main, ...rest] = await Promise.all([
    mainWorkspace(listening),
    ...slugs.map((s, i) => workspaceStatus(s, i + 1, listening)),
  ]);
  return { generatedAt: new Date().toISOString(), bootId: BOOT_ID, baseDomain: cfg.BASE_DOMAIN, workspaces: [main, ...rest] };
}

// ---- actions --------------------------------------------------------------
function worktreeFor(slug) {
  return slug === 'MAIN' ? cfg.FRONTEND_REPO : `${cfg.WORKSPACES_ROOT}/${slug}/${cfg.FRONTEND_DIR_NAME}`;
}
function logFile(slug, app) { return `${LOG_DIR}/${slug}-${app}.log`; }

async function inTerminal(cmd, cwd = HOME) {
  const full = `cd ${q(cwd)} && ${cmd}`;
  const script = `tell application "Terminal"\nactivate\ndo script ${JSON.stringify(full)}\nend tell`;
  return sh(`osascript -e ${q(script)}`);
}

async function actionOpen(slug) {
  const cmd = slug === 'MAIN' ? `${q(WS_BIN)} open 0` : `${q(WS_BIN)} open ${q(slug)} --no-create`;
  return sh(cmd);
}

async function actionServe(slug) {
  if (slug === 'MAIN') return { ok: false, stdout: '', stderr: 'MAIN is always served.' };
  const r = await sh(`${q(WS_BIN)} serve ${q(slug)} </dev/null`);
  const out = r.stdout + r.stderr;
  if (!r.ok && /sudo|password/i.test(out)) {
    // nginx reload needs sudo and we have no TTY — hand it to Terminal.app.
    await inTerminal(`${q(WS_BIN)} serve ${q(slug)}`);
    return { ...r, handedToTerminal: true };
  }
  return r;
}

async function actionDevStart(slug, app, port) {
  const cwd = worktreeFor(slug);
  if (!existsSync(cwd)) return { ok: false, stderr: `worktree not found: ${cwd}` };
  await mkdir(LOG_DIR, { recursive: true });
  const fh = await fsOpen(logFile(slug, app), 'w');
  // Pin the port explicitly: before `ws serve` has written the worktree .env,
  // nuxi would otherwise fall back to :3000.
  const env = { ...process.env, HOST: '127.0.0.1' };
  if (port) env.PORT = String(port);
  const child = spawn('/bin/zsh', ['-lc', `exec yarn serve-${app}`], {
    cwd, env, detached: true, stdio: ['ignore', fh.fd, fh.fd],
  });
  child.unref();
  await fh.close();
  return { ok: true, pid: child.pid, log: logFile(slug, app) };
}

async function actionDevStop(port) {
  if (!port) return { ok: false, stderr: 'no port' };
  // Kill the process group of whatever listens on the port (nuxi + its children).
  const r = await sh(`pids=$(lsof -nP -tiTCP:${Number(port)} -sTCP:LISTEN); [ -n "$pids" ] && kill $pids`);
  return { ok: r.ok, stdout: r.stdout, stderr: r.stderr };
}

async function actionRemove(slug, force = false) {
  if (!slug || slug === 'MAIN') return { ok: false, stderr: 'refusing to remove MAIN' };
  if (!existsSync(`${cfg.WORKSPACES_ROOT}/${slug}`)) return { ok: false, stderr: `no such workspace: ${slug}` };
  // The browser already confirmed; answer the CLI's own [y/N] prompt. Without
  // --force every safety check (protected branch, uncommitted/unpushed work)
  // still applies and the command aborts with its explanation.
  const cmd = force
    ? `${q(WS_BIN)} remove ${q(slug)} --force </dev/null`
    : `printf 'y\n' | ${q(WS_BIN)} remove ${q(slug)}`;
  const r = await sh(cmd);
  const out = r.stdout + r.stderr;
  if (!r.ok && /sudo|password|a terminal is required/i.test(out)) {
    // Reverting nginx routing needs sudo and we have no TTY — hand it to Terminal.app.
    await inTerminal(`${q(WS_BIN)} remove ${q(slug)}${force ? ' --force' : ''}`);
    return { ...r, handedToTerminal: true };
  }
  // `ws remove` exits 0 on "Aborted." and on a refused safety check — surface
  // those as failures so the UI can offer the explicit force step.
  const refused = /uncommitted|unpushed|diverged|local-only|Aborted|refus/i.test(out) && existsSync(`${cfg.WORKSPACES_ROOT}/${slug}`);
  return { ...r, ok: r.ok && !refused, refused };
}

async function actionCreate(slug) {
  if (!/^[A-Za-z0-9._-]+$/.test(slug)) return { ok: false, stderr: 'slug may only contain letters, digits, . _ -' };
  return inTerminal(`${q(WS_BIN)} create ${q(slug)}`);
}

async function tailLog(slug, app, lines = 200) {
  const file = logFile(slug, app);
  if (!existsSync(file)) return '';
  const r = await sh(`tail -n ${Number(lines)} ${q(file)}`);
  return r.stdout.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
}

// ---- http -----------------------------------------------------------------
const json = (res, code, body) => {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
};
const readBody = (req) => new Promise((resolve) => {
  let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => { try { resolve(JSON.parse(d || '{}')); } catch { resolve({}); } });
});

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(await readFile(HTML));
    }
    if (req.method === 'GET' && url.pathname === '/api/workspaces') return json(res, 200, await allWorkspaces());
    if (req.method === 'GET' && url.pathname === '/api/logs') {
      return json(res, 200, { log: await tailLog(url.searchParams.get('slug'), url.searchParams.get('app')) });
    }
    if (req.method === 'POST') {
      const body = await readBody(req);
      switch (url.pathname) {
        case '/api/open':      return json(res, 200, await actionOpen(body.slug));
        case '/api/serve':     return json(res, 200, await actionServe(body.slug));
        case '/api/dev/start': return json(res, 200, await actionDevStart(body.slug, body.app, body.port));
        case '/api/dev/stop':  return json(res, 200, await actionDevStop(body.port));
        case '/api/create':    return json(res, 200, await actionCreate(String(body.slug || '').trim()));
        case '/api/remove':    return json(res, 200, await actionRemove(body.slug, body.force === true));
      }
    }
    json(res, 404, { error: 'not found' });
  } catch (e) {
    json(res, 500, { error: String(e?.stack || e) });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`ws-ui → http://localhost:${PORT}   (ws: ${WS_BIN})`);
  if (process.argv.includes('--open')) spawn('open', [`http://localhost:${PORT}`], { stdio: 'ignore' }).unref();
});
