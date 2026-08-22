# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_url.sh — `workspaces url`: deep links.
#
# Two halves:
#   1. Handling — turn a `ws://create/CU-1234_my-feature?base=main` link into
#      the equivalent `ws` command and run it in a terminal window. This is what
#      the handler app invokes; you rarely type it yourself.
#   2. Installing — build and register the tiny macOS app that owns the URL
#      scheme, because a scheme needs a bundle and this repo is shell scripts.
#
# A link that arrives from outside (a task tracker, an MR description, a chat
# message) is untrusted input that ends in an exec, so every field is validated
# against a strict character class BEFORE it reaches a command line, and the
# verb is a whitelist. `remove` is deliberately not on it: no link should be
# able to delete a workspace with one click.
# -----------------------------------------------------------------------------

# Scheme and app location are overridable (env or config.sh) — `ws` is short and
# could collide with something else you have installed.
WSM_URL_SCHEME="${WSM_URL_SCHEME:-ws}"
WSM_URL_APP="${WSM_URL_APP:-$HOME/Applications/WorkspacesURL.app}"
WSM_URL_BUNDLE_ID="${WSM_URL_BUNDLE_ID:-dev.workspaces.urlhandler}"

# Verbs a link may invoke, and the flags each accepts. Anything else is refused.
WSM_URL_VERBS="create open serve"

cmd_url_usage() {
  cat <<USAGE
Usage:
  ws url <${WSM_URL_SCHEME}://...>          Handle a deep link (what the handler app calls)
  ws url --install [--dry-run]   Install + register the macOS URL handler app
  ws url --uninstall             Remove it again
  ws url --link <SLUG> [...]     Print a shareable link for a workspace

Link grammar (verb is one of: ${WSM_URL_VERBS// /, }):
  ${WSM_URL_SCHEME}://create/<slug>[?base=<branch>&remote=<name>&bare=1]
  ${WSM_URL_SCHEME}://open/<slug>[?remote=<name>&base=<branch>]
  ${WSM_URL_SCHEME}://serve/<slug>[?all-apps=1]

  An open link creates the workspace when the machine following it doesn't have
  one, which is what \`remote\` and \`base\` are for there: they decide where the
  branch comes from. \`remote\` is a remote NAME as configured in the repos
  (FRONTEND_REMOTE / BACKEND_REMOTE), never a URL.

  The slug may also be given as a query field (${WSM_URL_SCHEME}://open?slug=<slug>), which is
  what most trackers produce when you build the link in their UI.

  \`remove\` is NOT linkable, on purpose — a one-click teardown of someone's
  work is exactly the kind of thing a stray link should not be able to do.

Options:
  --install       Build the handler app (default: \$WSM_URL_APP) and register it
                  with Launch Services, so ${WSM_URL_SCHEME}:// links open it.
  --uninstall     Deregister and delete that app.
  --link <SLUG>   Print a link instead of following one. Combine with --verb
                  and --base.
  --verb <VERB>   Verb for --link (default: create).
  --base <BRANCH> Base branch for --link / an override when handling a link.
  --remote <NAME> Remote name for --link / an override when handling a link.
  -n, --print     Print the command a link resolves to; run nothing.
  --here          Run the resolved command in THIS terminal instead of opening
                  a new one (the default when stdout is a terminal).
  --dry-run       Print actions without executing them.
  -h, --help      Show this help.

Environment / config overrides:
  WSM_URL_SCHEME  URL scheme to own (default: ${WSM_URL_SCHEME})
  WSM_URL_APP     Handler app bundle (default: \$HOME/Applications/WorkspacesURL.app)

Examples:
  ws url --install
  ws url --link CU-1234_my-feature --base CU-1200_parent
  ws url --link CU-1234_my-feature --verb open --remote upstream
  ws url '${WSM_URL_SCHEME}://create/CU-1234_my-feature?base=main' --print
  open '${WSM_URL_SCHEME}://open/CU-1234_my-feature'
USAGE
}

# --------------------------------- helpers ----------------------------------

# Percent-decode one URL field. '+' means space in a query string; %XX becomes
# \xXX for printf %b. Anything that survives is still validated afterwards, so a
# decoded backslash or quote can't reach a command line.
url_decode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

# Value of KEY in a & separated query string, or empty. Last one wins.
url_query_field() {
  local query="$1" key="$2" pair out=""
  local IFS='&'
  # shellcheck disable=SC2086  # deliberate word-split on '&'
  for pair in $query; do
    [[ "$pair" == "$key="* ]] && out="${pair#*=}"
    [[ "$pair" == "$key" ]] && out="1"      # bare flag: ?bare
  done
  url_decode "$out"
}

# True for the affirmative spellings a link might use for a flag field.
url_is_true() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# A link handled by the app has no terminal to print to, so failures would be
# silent. Mirror them into a notification when we're not on a TTY.
url_notify() {
  "$TTY" && return 0
  local msg="$1"
  # Only through osascript's own quoting; msg is ours, never the raw URL.
  osascript -e "display notification \"${msg//\"/\'}\" with title \"workspaces\"" \
    >/dev/null 2>&1 || true
}

url_die() {
  err "$1"
  url_notify "$1"
  exit 1
}

# Slug: also a directory name under WORKSPACES_ROOT, so no slashes, no dots
# leading, nothing that could climb out of it.
url_valid_slug() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *".."* ]]
}

# Branch: same, plus '/' for namespaced branches (feature/foo).
url_valid_branch() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] && [[ "$1" != *".."* ]]
}

# Remote name: a git remote is a plain identifier — no slashes, so a link can't
# smuggle a URL in here and make the CLI fetch from somewhere unconfigured.
url_valid_remote() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *".."* ]]
}

# Single-quote an argument for the command string handed to the terminal. The
# fields are pre-validated, so the only realistic source of a quote or backslash
# is an exotic WSM_HOME — refused rather than escaped into an AppleScript string
# where the escaping rules differ from the shell's.
url_shquote() {
  case "$1" in
    *[\'\"\\]*) url_die "Path contains a quote or backslash; can't build a terminal command: $1" ;;
  esac
  printf "'%s'" "$1"
}

# ------------------------------- handling -----------------------------------

# Run the resolved command where the caller can actually see it: inline on a
# TTY, otherwise a fresh terminal window (which is also what makes serve's sudo
# prompt reachable).
url_run() {
  local -a argv=("$@")
  local cmd="" arg
  for arg in "${argv[@]}"; do cmd+="$(url_shquote "$arg") "; done
  cmd="${cmd% }"

  if "$URL_PRINT"; then
    printf '%s\n' "$cmd"
    return 0
  fi
  if "$URL_HERE" || "$TTY"; then
    vlog "Running inline: $cmd"
    run_cmd "${argv[@]}"
    return $?
  fi
  if "$DRY_RUN"; then
    printf '[dry-run] open %s terminal: %s\n' "$TERMINAL_APP" "$cmd"
    return 0
  fi

  case "$TERMINAL_APP" in
    warp)
      # One tab, named after the verb; the config is rewritten per link rather
      # than accumulating one file per workspace.
      open_warp_session "ws-url" "$(printf '%s\t%s\t%s' "${argv[1]}" "$HOME" "$cmd")" \
        || url_die "Could not open a Warp tab for: $cmd"
      ;;
    *)
      open_terminal_window "$cmd" >/dev/null \
        || url_die "Could not open a terminal. If macOS asked for permission to control Terminal and it was denied, grant it under System Settings > Privacy & Security > Automation."
      ;;
  esac
}

# Parse LINK into a validated (verb, slug, flags) triple and run it.
url_handle() {
  local url="$1" rest query="" verb path="" slug base remote

  [[ "$url" == "$WSM_URL_SCHEME://"* ]] \
    || url_die "Not a ${WSM_URL_SCHEME}:// link: $url"
  rest="${url#"$WSM_URL_SCHEME://"}"
  [[ "$rest" == *\?* ]] && { query="${rest#*\?}"; rest="${rest%%\?*}"; }
  rest="${rest%/}"
  verb="$(url_decode "${rest%%/*}" | tr '[:upper:]' '[:lower:]')"
  [[ "$rest" == */* ]] && path="$(url_decode "${rest#*/}")"

  case " $WSM_URL_VERBS " in
    *" $verb "*) ;;
    *) url_die "Refusing verb '${verb:-<empty>}' — a link may only ${WSM_URL_VERBS// /, }." ;;
  esac

  # Path form (ws://open/SLUG) and query form (ws://open?slug=SLUG) are both
  # accepted; the path wins when a link somehow carries both.
  slug="$path"
  [[ -n "$slug" ]] || slug="$(url_query_field "$query" slug)"
  [[ -n "$slug" ]] || url_die "Link carries no workspace slug: $url"
  url_valid_slug "$slug" || url_die "Refusing slug '$slug' — letters, digits, . _ - only."

  base="${URL_BASE:-$(url_query_field "$query" base)}"
  if [[ -n "$base" ]]; then
    url_valid_branch "$base" || url_die "Refusing base branch '$base' — letters, digits, . _ - / only."
  fi

  # The remote a link names is a NAME, resolved against the remotes the repos
  # already have — `ws create --remote` fails on an unknown one rather than
  # adding it. A link can pick between your remotes; it can't introduce one.
  remote="${URL_REMOTE:-$(url_query_field "$query" remote)}"
  if [[ -n "$remote" ]]; then
    url_valid_remote "$remote" || url_die "Refusing remote '$remote' — a remote NAME, not a URL (letters, digits, . _ - only)."
  fi

  local -a argv=("$WSM_HOME/workspaces" "$verb" "$slug")
  case "$verb" in
    create)
      [[ -n "$base" ]] && argv+=("$base")
      [[ -n "$remote" ]] && argv+=(--remote "$remote")
      url_is_true "$(url_query_field "$query" bare)" && argv+=(--neanderthal)
      ;;
    open)
      # base and remote reach `ws open`'s create-when-missing path — they decide
      # where the workspace comes from on a machine that doesn't have it yet.
      [[ -n "$base" ]] && argv+=(--base "$base")
      [[ -n "$remote" ]] && argv+=(--remote "$remote")
      ;;
    serve)
      url_is_true "$(url_query_field "$query" all-apps)" && argv+=(--all-apps)
      # Cleared, not just warned about, so the log line below reports what the
      # command actually does.
      [[ -n "$base" ]] && { warn "'base' is meaningless for serve — ignored."; base=""; }
      [[ -n "$remote" ]] && { warn "'remote' is meaningless for serve — ignored."; remote=""; }
      ;;
  esac
  # Only serve has a -v; passing it to create/open would be an "unknown option".
  { "$VERBOSE" && [[ "$verb" == "serve" ]]; } && argv+=(-v)

  log "link -> ${verb} ${slug}${base:+ (base ${base})}${remote:+ (remote ${remote})}"
  url_run "${argv[@]}"
}

# -------------------------------- link ---------------------------------------

url_link() {
  local slug="$1" verb="$2" base="$3" remote="$4" query=""
  case " $WSM_URL_VERBS " in
    *" $verb "*) ;;
    *) err "Unknown verb '$verb' — one of: ${WSM_URL_VERBS// /, }"; exit 1 ;;
  esac
  url_valid_slug "$slug" || { err "Not a linkable slug: $slug"; exit 1; }
  [[ -z "$base" ]] || url_valid_branch "$base" || { err "Not a linkable branch: $base"; exit 1; }
  [[ -z "$remote" ]] || url_valid_remote "$remote" || { err "Not a linkable remote: $remote"; exit 1; }

  [[ -z "$base" ]]   || query+="${query:+&}base=$base"
  [[ -z "$remote" ]] || query+="${query:+&}remote=$remote"
  printf '%s://%s/%s%s\n' "$WSM_URL_SCHEME" "$verb" "$slug" "${query:+?$query}"

  # The served host is the other, handler-free deep link: a plain https URL any
  # browser already knows how to open. Worth printing next to the ws:// one.
  local sub
  if [[ "$verb" == "serve" || "$verb" == "create" ]] && sub="$(resolve_subdomain "$slug")"; then
    printf '%shttps://%s.%s%s%s\n' "$C_DIM" "$sub" "$BASE_DOMAIN" "$ADMIN_PATH" "$C_RESET"
  fi
}

# ------------------------------ install --------------------------------------

# The handler is an AppleScript applet: the cheapest bundle that can own a URL
# scheme, and the only one buildable from a shell script with no toolchain. It
# does nothing but hand the URL straight back to this command, by absolute path
# — `do shell script` runs with a minimal PATH where `ws` isn't on it.
url_applescript() {
  cat <<APPLESCRIPT
-- Generated by \`ws url --install\` — do not edit; re-run to regenerate.
-- Owns ${WSM_URL_SCHEME}:// and forwards the link to the workspaces CLI.
on open location this_URL
	do shell script quoted form of "$WSM_HOME/workspaces" & " url " & quoted form of this_URL
end open location
APPLESCRIPT
}

url_lsregister() {
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$lsregister" ]] || { warn "lsregister not found — the app may not be picked up until you open it once."; return 0; }
  run_quiet "$lsregister" "$@"
}

cmd_url_install() {
  require_command osacompile
  local app="$WSM_URL_APP" plist tmp script
  [[ "$app" == *.app ]] || { err "WSM_URL_APP must end in .app: $app"; exit 1; }
  # Launch Services registers a bundle from anywhere but only *binds* a scheme
  # to one living in a real Applications directory — from /tmp the app shows up
  # in the LS database with its scheme and `open` still says "no application
  # knows how to open URL". Verified the hard way; warn rather than fail, since
  # the rule is Apple's and undocumented.
  case "$app" in
    "$HOME/Applications/"*|/Applications/*) ;;
    *) warn "$app is outside ~/Applications and /Applications — macOS may register the app but refuse to route ${WSM_URL_SCHEME}:// links to it." ;;
  esac

  if "$DRY_RUN"; then
    printf '[dry-run] build %s\n' "$app"
    printf '[dry-run] register scheme %s:// for bundle id %s\n' "$WSM_URL_SCHEME" "$WSM_URL_BUNDLE_ID"
    url_applescript | sed 's/^/    | /'
    exit 0
  fi

  mkdir -p "$(dirname "$app")"
  tmp="$(mktemp -d)"
  script="$tmp/handler.applescript"
  url_applescript >"$script"

  # osacompile refuses to overwrite an existing bundle; the .app check above
  # plus this one keep the rm from ever pointing at something else.
  if [[ -e "$app" ]]; then
    [[ -d "$app" && -f "$app/Contents/Info.plist" ]] \
      || { rm -rf "$tmp"; err "$app exists and is not an app bundle — refusing to replace it."; exit 1; }
    url_lsregister -u "$app"
    rm -rf "$app"
  fi

  spin "building the handler app"
  if ! run_quiet osacompile -o "$app" "$script"; then
    spin_stop; rm -rf "$tmp"
    err "osacompile failed to build $app"
    exit 1
  fi
  rm -rf "$tmp"

  # CFBundleURLTypes is what makes the scheme ours; LSUIElement keeps the applet
  # out of the Dock (it has no UI, it just relays the URL).
  plist="$app/Contents/Info.plist"
  local pb=/usr/libexec/PlistBuddy
  $pb -c "Delete :CFBundleURLTypes" "$plist" >/dev/null 2>&1 || true
  {
    $pb -c "Add :CFBundleURLTypes array" "$plist" &&
    $pb -c "Add :CFBundleURLTypes:0 dict" "$plist" &&
    $pb -c "Add :CFBundleURLTypes:0:CFBundleURLName string workspaces deep link" "$plist" &&
    $pb -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist" &&
    $pb -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $WSM_URL_SCHEME" "$plist" &&
    $pb -c "Add :LSUIElement bool true" "$plist"
  } >/dev/null 2>&1 || {
    spin_stop
    err "Could not write $plist — the app was built but owns no scheme."
    exit 1
  }
  $pb -c "Set :CFBundleIdentifier $WSM_URL_BUNDLE_ID" "$plist" >/dev/null 2>&1 \
    || $pb -c "Add :CFBundleIdentifier string $WSM_URL_BUNDLE_ID" "$plist" >/dev/null 2>&1 \
    || warn "Could not set the bundle id; the app still works."
  spin_ok "handler app built"

  url_lsregister -f "$app"
  ok "${WSM_URL_SCHEME}:// links now open workspaces"
  printf '  %sapp:%s %s\n' "$C_DIM" "$C_RESET" "$app"
  printf '  %stry:%s open %s://open/%s\n' "$C_DIM" "$C_RESET" "$WSM_URL_SCHEME" "$(workspace_slugs | head -n1)"
  printf '  %sThe first link asks macOS for permission to control your terminal.%s\n' "$C_DIM" "$C_RESET"
  printf '  %sRe-run after moving this checkout — the app hard-codes %s.%s\n' \
    "$C_DIM" "$WSM_HOME" "$C_RESET"
}

cmd_url_uninstall() {
  local app="$WSM_URL_APP"
  if [[ ! -d "$app" ]]; then
    log "No handler app at $app — nothing to uninstall."
    exit 0
  fi
  [[ "$app" == *.app && -f "$app/Contents/Info.plist" ]] \
    || { err "$app is not an app bundle — refusing to delete it."; exit 1; }
  if "$DRY_RUN"; then
    printf '[dry-run] unregister + rm -rf %s\n' "$app"
    exit 0
  fi
  url_lsregister -u "$app"
  rm -rf "$app"
  ok "handler removed — ${WSM_URL_SCHEME}:// links no longer resolve"
}

# --------------------------------- entry -------------------------------------

# `shift 2` on a flag whose value is missing shifts nothing and spins the
# parse loop forever, so the value is required before the shift.
url_need_value() {
  [[ $# -ge 2 && -n "$2" ]] || { err "$1 needs a value."; cmd_url_usage; exit 1; }
}

cmd_url() {
  DRY_RUN=false
  VERBOSE=false
  URL_PRINT=false
  URL_HERE=false
  URL_BASE=""
  URL_REMOTE=""
  local mode="" url="" link_slug="" verb="create"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install)   mode="install"; shift ;;
      --uninstall) mode="uninstall"; shift ;;
      --link)      url_need_value "$@"; mode="link"; link_slug="$2"; shift 2 ;;
      --verb)      url_need_value "$@"; verb="$2"; shift 2 ;;
      --base)      url_need_value "$@"; URL_BASE="$2"; shift 2 ;;
      --remote)    url_need_value "$@"; URL_REMOTE="$2"; shift 2 ;;
      -n|--print)  URL_PRINT=true; shift ;;
      --here)      URL_HERE=true; shift ;;
      --dry-run)   DRY_RUN=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_url_usage; exit 0 ;;
      -*)          err "Unknown option: $1"; cmd_url_usage; exit 1 ;;
      *)
        [[ -z "$url" ]] || { err "Expected one link, got another argument: $1"; exit 1; }
        url="$1"; mode="${mode:-handle}"; shift ;;
    esac
  done

  case "$mode" in
    install)   cmd_url_install ;;
    uninstall) cmd_url_uninstall ;;
    link)
      [[ -n "$link_slug" ]] || { err "--link needs a workspace slug."; exit 1; }
      url_link "$link_slug" "$verb" "$URL_BASE" "$URL_REMOTE"
      ;;
    handle)    url_handle "$url" ;;
    *)         cmd_url_usage; exit 1 ;;
  esac
}
