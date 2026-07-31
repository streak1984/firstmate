#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# --gh-account passes the GitHub account login through to fm-pr-check.sh,
# which records it (see that header for the schema and reuse rules). The merge
# itself then honors whatever account the meta records - passed now or on an
# earlier arm - by resolving its token per command with gh auth token -u, so a
# PR on a repository the ambient account cannot see merges without any manual
# credential prefix. No token is ever written to disk. A recorded account
# whose token cannot be resolved refuses the merge rather than retrying with
# ambient credentials, which could act on the wrong account's view of the PR.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--gh-account <login>] [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
ACCOUNT_ARG=
if [ "${1:-}" = --gh-account ]; then
  if [ "$#" -lt 2 ] || ! fm_pr_gh_account_valid "$2"; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  ACCOUNT_ARG=$2
  shift 2
fi
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

if [ -n "$ACCOUNT_ARG" ]; then
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" --gh-account "$ACCOUNT_ARG"
else
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
fi
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# fm-pr-check.sh just made the meta authoritative for the account binding,
# whether it was passed above or recorded by an earlier arm.
ACCOUNT=$(grep '^gh_account=' "$META" | tail -1 | cut -d= -f2- || true)
GH_TOKEN_VALUE=
if [ -n "$ACCOUNT" ]; then
  if ! fm_pr_gh_account_valid "$ACCOUNT"; then
    echo "error: recorded gh account is invalid" >&2
    exit 1
  fi
  if ! GH_TOKEN_VALUE=$(gh auth token -u "$ACCOUNT" 2>/dev/null) || [ -z "$GH_TOKEN_VALUE" ]; then
    echo "error: gh has no usable token for account $ACCOUNT; run gh auth login" >&2
    exit 1
  fi
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if [ -n "$ACCOUNT" ]; then
  GH_TOKEN="$GH_TOKEN_VALUE" gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
else
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
fi
