# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_stats.sh — `workspaces stats`: usage stats + a scrollable timeline.
#
# Numbers up top (created / live / peak parallel / lifespans / activity), then
# a graph of every workspace the log knows about, git-branch-graph style: time
# flows DOWN (top row = now), each workspace is a slim vertical bar with dot
# caps in its own accent color, and you scroll DOWN into the past. Columns are packed the way
# git packs lanes — a workspace takes the leftmost free column when created and
# frees it when removed — so the graph is only as wide as the most workspaces
# that ever coexisted. Reads the append-only event log (log_ws_event in
# common.sh). The heavy lifting is a python3 block; the pager is bash.
# -----------------------------------------------------------------------------

cmd_stats_usage() {
  cat <<'USAGE'
Usage:
  ws stats [--no-scroll] [--json]

Shows how you use workspaces: how many you've created, how many are live, the
most that ever existed at once (and when), the longest-lived one, average and
median lifespans, and how often each command was used — followed by a timeline
you scroll DOWN into: one row per day, today at the top, each workspace a slim
vertical bar in its own color. Its bottom dot is the day it was created, its
top dot the day it was removed (an open top = still live). Columns are reused once
a workspace is gone, so the graph is as wide as your busiest moment.

Only what happened since logging began is counted; the workspaces that exist
right now are included from their creation date.

Options:
  --no-scroll   Print everything once instead of opening the scroll view
                (automatic when output isn't a terminal).
  --json        Print the numbers (and every lifespan) as JSON.
  -h, --help    Show this help.

Keys in the scroll view:
  j / ↓  down one    k / ↑  up one    space / f  page down    b  page up
  g  top    G  bottom    q  quit
USAGE
}

# The report, for a given width. $1 = columns, $2 = color | plain | json.
# Prints the header lines, a "@@BODY@@" marker, then the timeline rows (json
# mode prints one JSON document instead).
_stats_python() {
  local cols="$1" mode="$2" live
  live="$(workspace_slugs | tr '\n' ',')"
  python3 - "$WSM_HISTORY_FILE" "$live" "$cols" "$mode" "$(date +%s)" <<'PY'
import json, sys, time, statistics, datetime

path, live_csv, cols, mode, now = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
live = set(s for s in live_csv.split(",") if s)
color_on = (mode == "color")

def esc(code):
    if color_on:
        return "\033[%sm" % code
    return ""
RESET, DIM, BOLD = esc("0"), esc("2"), esc("1")

def rgb(hexs):
    if not color_on or not hexs:
        return ""
    h = hexs.lstrip("#")
    try:
        r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    except Exception:
        return ""
    return "\033[38;2;%d;%d;%dm" % (r, g, b)

# ---- read the log -----------------------------------------------------------
events = []
try:
    with open(path) as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                e = json.loads(raw)
            except Exception:
                continue
            if isinstance(e, dict) and "ts" in e and "event" in e:
                events.append(e)
except FileNotFoundError:
    pass
# Same timestamp: a remove sorts before a create, so a slug re-created in the
# same second doesn't overlap itself.
events.sort(key=lambda e: (int(e["ts"]), 0 if e["event"] == "remove" else 1))

# ---- lifespans: pair create -> remove per slug, in order ---------------------
spans = []
open_by = {}
created = removed = 0
acts_count = {"serve": 0, "share": 0, "mr": 0, "test": 0, "open": 0}
rac_total = rac_n = rac_max = 0
for e in events:
    ev = e["event"]
    ts = int(e["ts"])
    slug = e.get("slug")
    if ev == "raccoon":
        d = int(e.get("duration", 0) or 0)
        if d > 0:
            rac_total += d
            rac_n += 1
            rac_max = max(rac_max, d)
        continue
    if not slug:
        continue
    if ev == "create":
        if slug in open_by:
            continue
        sp = {"slug": slug, "start": ts, "end": None, "live": False, "untracked": False,
              "color": e.get("color", ""), "acts": [], "last": ts}
        spans.append(sp)
        open_by[slug] = sp
        created += 1
    elif ev == "recolor":
        # The timeline draws a workspace in the color it wears NOW.
        sp = open_by.get(slug)
        if sp is not None:
            if e.get("color"):
                sp["color"] = e["color"]
    elif ev == "remove":
        sp = open_by.pop(slug, None)
        if sp is not None:
            sp["end"] = ts
            sp["last"] = ts
            removed += 1
    elif ev in acts_count:
        acts_count[ev] += 1
        sp = open_by.get(slug)
        if sp is not None:
            sp["acts"].append((ts, ev))
            if ts > sp["last"]:
                sp["last"] = ts

# Still-open spans: alive if the directory exists, otherwise removed outside
# `ws remove` (untracked) — ended at the last thing we saw happen to it.
untracked = 0
for slug, sp in list(open_by.items()):
    if slug in live:
        sp["live"] = True
        sp["end"] = now
    else:
        sp["untracked"] = True
        sp["end"] = sp["last"]
        untracked += 1
live_n = sum(1 for sp in spans if sp["live"])

# ---- max parallel: sweep the starts and ends --------------------------------
pts = []
for sp in spans:
    pts.append((sp["start"], 1))
    pts.append((sp["end"], -1))
pts.sort(key=lambda p: (p[0], p[1]))
cur = peak = 0
peak_ts = None
for t, d in pts:
    cur += d
    if cur > peak:
        peak = cur
        peak_ts = t

# ---- lane packing, git-graph style ------------------------------------------
# Chronologically, each workspace takes the leftmost column whose previous
# occupant ended before this one started; a removed workspace frees its column.
# So the graph is exactly as wide as the most workspaces that ever coexisted.
lane_end = []
for sp in sorted(spans, key=lambda s: (s["start"], s["slug"])):
    lane = None
    for i, e in enumerate(lane_end):
        if e < sp["start"]:
            lane = i
            break
    if lane is None:
        lane = len(lane_end)
        lane_end.append(0)
    lane_end[lane] = sp["end"]
    sp["lane"] = lane
nlanes = len(lane_end)

def dur(sp):
    return max(0, sp["end"] - sp["start"])
lens = [dur(sp) for sp in spans]
longest = max(spans, key=dur) if spans else None
avg = int(sum(lens) / len(lens)) if lens else 0
med = int(statistics.median(lens)) if lens else 0

def human(s):
    s = int(s)
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm" % (s // 60)
    if s < 86400:
        h, r = divmod(s, 3600)
        m = r // 60
        if m:
            return "%dh %dm" % (h, m)
        return "%dh" % h
    d, r = divmod(s, 86400)
    h = r // 3600
    if h:
        return "%dd %dh" % (d, h)
    return "%dd" % d

def datestr(ts):
    t = time.localtime(ts)
    return "%s %d" % (time.strftime("%b", t), t.tm_mday)

if mode == "json":
    longest_j = None
    if longest is not None:
        longest_j = {"slug": longest["slug"], "seconds": dur(longest), "live": longest["live"]}
    print(json.dumps({
        "created": created,
        "removed": removed + untracked,
        "untracked": untracked,
        "live": live_n,
        "peak_parallel": peak,
        "peak_at": peak_ts,
        "longest": longest_j,
        "avg_lifespan_seconds": avg,
        "median_lifespan_seconds": med,
        "activity": acts_count,
        "raccoon": {"seconds": rac_total, "sessions": rac_n, "longest_seconds": rac_max},
        "spans": [{
            "slug": sp["slug"], "start": sp["start"], "end": sp["end"],
            "live": sp["live"], "untracked": sp["untracked"], "color": sp["color"],
            "lane": sp["lane"],
            "activity": [{"ts": t, "event": ev} for t, ev in sp["acts"]],
        } for sp in spans],
    }, indent=2))
    sys.exit(0)

# ---- header -----------------------------------------------------------------
H = []
def row(label, text):
    H.append("  %s%-11s%s %s" % (BOLD, label, RESET, text))
sep = " %s·%s " % (DIM, RESET)

if not spans:
    H.append("  %sNo workspace history yet — it starts recording from now.%s" % (DIM, RESET))
else:
    row("workspaces", sep.join(["created %d" % created,
                                "removed %d" % (removed + untracked),
                                "live %d" % live_n]))
    ptxt = "now %d" % live_n
    if peak:
        ptxt += sep + "peak %d (%s)" % (peak, datestr(peak_ts))
    row("parallel", ptxt)
    if longest is not None:
        state = "live" if longest["live"] else "removed"
        ltxt = "longest %s (%s%s%s, %s)" % (human(dur(longest)), rgb(longest["color"]),
                                          longest["slug"], RESET, state)
        row("lifespan", sep.join([ltxt, "avg %s" % human(avg), "median %s" % human(med)]))
    row("activity", sep.join(["served %d" % acts_count["serve"],
                              "shared %d" % acts_count["share"],
                              "MRs %d" % acts_count["mr"],
                              "tests %d" % acts_count["test"],
                              "opened %d" % acts_count["open"]]))
# The easter egg: only ever shown once there's time on the clock.
if rac_total > 0:
    plural = "" if rac_n == 1 else "s"
    row("🦝 raccoon", sep.join([human(rac_total),
                                "%d session%s" % (rac_n, plural),
                                "longest %s" % human(rac_max)]))

for h in H:
    print(h)
print("@@BODY@@")

# ---- timeline: time flows DOWN, one column per workspace ---------------------
if not spans:
    sys.exit(0)
today = datetime.date.fromtimestamp(now)
def days_ago(ts):
    return max(0, (today - datetime.date.fromtimestamp(ts)).days)

label_w = 6                      # "Sep 07"
lane_w, gap = 1, 1               # one-char double rails, a space between
gw = nlanes * (lane_w + gap) - gap
ann_w = max(12, cols - label_w - 1 - gw - 1)

# A heavy centered bar with dot caps: • on the creation day at the bottom, • on
# the removal day at the top, ┃ in between (a half-block would sit off-center
# under the dot — Unicode has no centered half block). Live bars run open-ended.
BODY   = "┃"
TOPCAP = "•"                     # dot cap: the bar ends here (removed)
BOTCAP = "•"                     # dot cap: the bar starts here (created)
ONEDAY = "•"
MARK = {"serve": "▲", "share": "◇", "mr": "◆", "test": "▪", "open": "·"}

nrows = max(days_ago(sp["start"]) for sp in spans) + 1
grid = [[None] * nlanes for _ in range(nrows)]
ann = [[] for _ in range(nrows)]
for sp in spans:
    r_top, r_bot = days_ago(sp["end"]), days_ago(sp["start"])
    L = sp["lane"]
    colr = rgb(sp["color"])
    if r_top == r_bot:
        grid[r_top][L] = (BODY if sp["live"] else ONEDAY, colr)
    else:
        for r in range(r_top, r_bot + 1):
            if r == r_bot:
                g = BOTCAP
            elif r == r_top:
                g = BODY if sp["live"] else TOPCAP
            else:
                g = BODY
            grid[r][L] = (g, colr)
    # Activity notches sit on the body only, never on a cap, so the ends stay round.
    for ts, ev in sp["acts"]:
        r = days_ago(ts)
        if r_top < r < r_bot:
            grid[r][L] = (MARK.get(ev, "•") + BODY[1:], colr)
    ann[r_bot].append(("+", sp))
    if not sp["live"]:
        ann[r_top].append(("?" if sp["untracked"] else "×", sp))

for r in range(nrows):
    if r == 0:
        lab = "today"
    else:
        d = today - datetime.timedelta(days=r)
        lab = "%s %02d" % (d.strftime("%b"), d.day)
    cells = []
    for L in range(nlanes):
        c = grid[r][L]
        if c is None:
            cells.append(" " * lane_w)
        else:
            cells.append(c[1] + c[0] + RESET)
    graph = (" " * gap).join(cells)
    # Day annotations: "+ slug" created, "× slug" removed, "? slug" untracked.
    parts = []
    for mark, sp in ann[r][:2]:
        name = sp["slug"]
        if len(name) > 26:
            name = name[:25] + "…"
        parts.append("%s%s %s%s%s" % (DIM, mark, rgb(sp["color"]), name, RESET))
    extra = len(ann[r]) - 2
    if extra > 0:
        parts.append("%s+%d more%s" % (DIM, extra, RESET))
    a = ("%s, %s" % (DIM, RESET)).join(parts)
    print("  %s%-*s%s %s %s" % (DIM, label_w, lab, RESET, graph, a))
PY
}

# Fill _ST_HDR (fixed header lines) and _ST_BODY (scrollable timeline rows)
# for a given width.
_ST_HDR=()
_ST_BODY=()
_stats_render() {
  local cols="$1" out line in_body=false
  out="$(_stats_python "$cols" color)"
  _ST_HDR=(); _ST_BODY=()
  while IFS= read -r line; do
    if [[ "$line" == "@@BODY@@" ]]; then in_body=true; continue; fi
    if "$in_body"; then _ST_BODY+=("$line"); else _ST_HDR+=("$line"); fi
  done <<<"$out"
}

# ------------------------------ scroll view ----------------------------------
# Alternate screen, raw keys, a fixed header and a scrolling window of rows.
# Today is the top row, so scrolling down walks back in time. Re-renders when
# the terminal is resized. The terminal is restored on every exit path.
_ST_STTY=""
_stats_tui_exit() {
  [[ -n "$_ST_STTY" ]] && stty "$_ST_STTY" 2>/dev/null
  printf '\033[?25h\033[?1049l'
  trap - EXIT INT TERM HUP
}

_stats_tui() {
  local off=0 rows cols last_cols=0 hdr nbody avail max_off i key rest lo hi
  _ST_STTY="$(stty -g 2>/dev/null || true)"
  printf '\033[?1049h\033[?25l'
  stty -echo -icanon min 1 time 0 2>/dev/null || true
  trap '_stats_tui_exit; exit 0' INT TERM HUP
  trap '_stats_tui_exit' EXIT
  # A resize interrupts the blocking read, so the loop redraws at the new size.
  trap ':' WINCH
  while :; do
    rows="$(tput lines 2>/dev/null || echo 24)"
    cols="$(tput cols 2>/dev/null || echo 100)"
    if (( cols != last_cols )); then
      _stats_render "$cols"
      last_cols=$cols
    fi
    hdr=${#_ST_HDR[@]}; nbody=${#_ST_BODY[@]}
    avail=$(( rows - hdr - 3 ))
    (( avail < 1 )) && avail=1
    max_off=$(( nbody - avail )); (( max_off < 0 )) && max_off=0
    (( off > max_off )) && off=$max_off
    (( off < 0 )) && off=0

    printf '\033[H'
    for (( i = 0; i < hdr; i++ )); do printf '%s\033[K\n' "${_ST_HDR[i]}"; done
    printf '\033[K\n'
    for (( i = 0; i < avail; i++ )); do
      if (( off + i < nbody )); then
        printf '%s\033[K\n' "${_ST_BODY[off + i]}"
      else
        printf '\033[K\n'
      fi
    done
    lo=$(( nbody == 0 ? 0 : off + 1 ))
    hi=$(( off + avail < nbody ? off + avail : nbody ))
    printf '\033[2m  ↑↓/jk scroll · space/b page · g/G ends · q quit   days %d-%d of %d\033[0m\033[K' \
      "$lo" "$hi" "$nbody"
    printf '\033[J'

    IFS= read -rsn1 key || continue
    if [[ "$key" == $'\e' ]]; then
      rest=""; IFS= read -rsn2 -t 1 rest || true; key+="$rest"
    fi
    case "$key" in
      q|Q)          break ;;
      j|$'\e[B')    off=$(( off + 1 )) ;;
      k|$'\e[A')    off=$(( off - 1 )) ;;
      ' '|f)        off=$(( off + avail )) ;;
      b)            off=$(( off - avail )) ;;
      g)            off=0 ;;
      G)            off=$max_off ;;
    esac
  done
  _stats_tui_exit
}

cmd_stats() {
  DRY_RUN=false
  VERBOSE=false
  local json=false scroll=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)      json=true; shift ;;
      --no-scroll) scroll=false; shift ;;
      -h|--help)   cmd_stats_usage; exit 0 ;;
      *)           err "Unknown option: $1"; cmd_stats_usage; exit 1 ;;
    esac
  done
  require_command python3

  # Anything on disk that the log doesn't know as live gets recorded first, so
  # the picture is right even for workspaces made before logging existed.
  history_seed_live

  local cols
  cols="$(tput cols 2>/dev/null || echo 100)"

  if "$json"; then
    _stats_python "$cols" json
    exit 0
  fi
  if ! "$TTY" || ! "$scroll"; then
    local mode=plain
    "$TTY" && mode=color
    _stats_python "$cols" "$mode" | grep -v '^@@BODY@@$' || true
    exit 0
  fi
  _stats_tui
  exit 0
}
