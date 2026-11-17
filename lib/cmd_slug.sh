# shellcheck shell=bash
# -----------------------------------------------------------------------------
# lib/cmd_slug.sh — `workspaces slug`: what `ws create` would name things.
#
# Local and fast: no network and no repository access (git only checks that
# the names are valid branch names). Runs the same normalisation `ws create`
# runs (workspace_slug_for, branch_base_name, with_branch_prefix from
# common.sh), so a preview names things exactly as the real create will.
# Meant for tools that preview a create before running it (the Workspace
# Overview app).
# -----------------------------------------------------------------------------

cmd_slug_usage() {
  cat <<'USAGE'
Usage:
  ws slug <NAME_OR_TASK_AND_NAME> [BASE_BRANCH[@REMOTE]] [--branch NAME] [--json]
  ws slug --branch <NAME> [--json]

Print the workspace slug and the two branch names `ws create` would use for
the same arguments, and whether that workspace already exists. Nothing is
created, and no repository or remote is looked at.

Takes every argument `ws create` takes, so a tool can preview the exact
command it is about to run. BASE_BRANCH[@REMOTE], --remote, --neanderthal,
--dry-run and -v change no name: they are only checked for form. Whether the
base branch exists is for `ws create` to find out.

Options:
  --branch NAME   The branch `ws create --branch NAME` would use. Without a
                  name, the slug is the branch's last segment.
  --json          Machine-readable output. Any invalid input — argument
                  errors included — prints {"error": "..."} and exits 1.
  -h, --help      Show this help.

Examples:
  ws slug "CU-1234_My Feature"
  ws slug --branch cursor/test-project-05ff --json
  ws slug CU-1234_follow-up feature/base --json
USAGE
}

# Report an invalid input: {"error": …} with --json, the usual err otherwise.
_slug_fail() {
  local message="$1"
  if "$show_json"; then
    printf '{"error": "%s"}\n' "$(json_str "$message")"
  else
    err "$message"
  fi
  exit 1
}

cmd_slug() {
  local name="" base="" branch_override="" show_json=false arg
  local -a positional=()

  # --json decides how EVERY error is reported, argument errors included, so
  # it is looked for before anything is validated (up to a `--`, after which
  # everything is a name).
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
      break
    fi
    if [[ "$arg" == "--json" ]]; then
      show_json=true
    fi
  done

  # The same arguments `ws create` parses. The ones that change no name are
  # accepted and dropped.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        if [[ $# -lt 2 || -z "$2" ]]; then
          _slug_fail "--branch needs a branch name."
        fi
        branch_override="$2"; shift 2 ;;
      --remote)
        if [[ $# -lt 2 || -z "$2" ]]; then
          _slug_fail "--remote needs a remote name."
        fi
        shift 2 ;;
      --json|-n|--neanderthal|--dry-run|-v|--verbose) shift ;;
      -h|--help) cmd_slug_usage; exit 0 ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          positional+=("$1"); shift
        done ;;
      -*) _slug_fail "Unknown option: $1" ;;
      *) positional+=("$1"); shift ;;
    esac
  done

  if [[ ${#positional[@]} -gt 2 ]]; then
    _slug_fail "Unexpected extra argument: ${positional[2]}"
  fi
  if [[ ${#positional[@]} -ge 1 ]]; then
    name="${positional[0]}"
  fi
  if [[ ${#positional[@]} -ge 2 ]]; then
    base="${positional[1]}"
  fi
  # Same form check `ws create` makes on BASE_BRANCH@REMOTE.
  if [[ "$base" == *@* ]]; then
    if [[ -z "${base##*@}" || -z "${base%@*}" ]]; then
      _slug_fail "Invalid BASE_BRANCH@REMOTE: '$base'"
    fi
  fi

  # Same fallback as `ws create`: --branch alone names the workspace after the
  # branch's last segment.
  if [[ -z "$name" && -n "$branch_override" ]]; then
    name="${branch_override##*/}"
  fi
  if [[ -z "$name" ]]; then
    if "$show_json"; then
      _slug_fail "A name is required."
    fi
    cmd_slug_usage
    exit 1
  fi

  # workspace_slug_for exits non-zero on input it can't name, after an err.
  # On success its stderr is dropped: `ws create` would print the same stray
  # warnings (a `tr` locale complaint, say) and carry on with this same slug.
  # Only on failure is it run again, for its message — the last ERROR line.
  local combined slug message
  combined="$(branch_base_name "$name")"
  if ! slug="$(workspace_slug_for "$combined" 2>/dev/null)"; then
    message="$(workspace_slug_for "$combined" 2>&1 >/dev/null | grep 'ERROR: ' | tail -n 1)" || true
    message="${message#*ERROR: }"
    if [[ -z "$message" ]]; then
      message="Not a usable name: '$name'"
    fi
    _slug_fail "$message"
  fi

  local wt_name fe_branch be_branch candidate
  if [[ -n "$branch_override" ]]; then
    wt_name="$(branch_base_name "$branch_override")"
  else
    wt_name="$(branch_base_name "$slug")"
  fi
  fe_branch="$(with_branch_prefix "$FRONTEND_BRANCH_PREFIX" "$wt_name")"
  be_branch="$(with_branch_prefix "$BACKEND_BRANCH_PREFIX" "$wt_name")"
  for candidate in "$fe_branch" "$be_branch"; do
    if ! git check-ref-format --branch "$candidate" >/dev/null 2>&1; then
      _slug_fail "Not a valid branch name: '$candidate'"
    fi
    if is_protected_branch "$candidate"; then
      _slug_fail "'$candidate' is a base branch."
    fi
  done

  local exists=false
  if [[ -d "$WORKSPACES_ROOT/$slug" ]]; then
    exists=true
  fi

  if "$show_json"; then
    printf '{"slug": "%s", "frontend_branch": "%s", "backend_branch": "%s", "frontend_prefix": "%s", "backend_prefix": "%s", "exists": %s}\n' \
      "$(json_str "$slug")" \
      "$(json_str "$fe_branch")" \
      "$(json_str "$be_branch")" \
      "$(json_str "$FRONTEND_BRANCH_PREFIX")" \
      "$(json_str "$BACKEND_BRANCH_PREFIX")" \
      "$exists"
    return 0
  fi

  local exists_label="no"
  if "$exists"; then
    exists_label="yes"
  fi
  printf '  %-9s %s\n' "slug" "$slug"
  printf '  %-9s %s\n' "frontend" "$fe_branch"
  printf '  %-9s %s\n' "backend" "$be_branch"
  printf '  %-9s %s\n' "exists" "$exists_label"
}
