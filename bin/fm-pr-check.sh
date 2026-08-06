#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
#
# This header owns the sidecar schema (state/<id>.pr-poll): provider, url,
# host, path, number, one per line, plus an optional sixth line naming the
# GitHub account login whose stored gh token the poll must use. --gh-account
# binds that account to a GitHub PR whose repository the ambient gh account
# cannot see (a private personal repository while a work account is active).
# The login is data only: it is recorded in the sidecar and as one gh_account=
# line in the task's meta (so a poll rebuild and fm-pr-merge.sh keep using it),
# and its token is resolved fresh per command through gh's own store with
# gh auth token -u <login> - no token is ever written to disk. Without the
# option, a previously recorded gh_account= is reused, so re-arming keeps the
# binding. Arming refuses an account whose token gh cannot resolve, for the
# same reason as the glab refusal below: this is the one point where a watch
# that could never see its PR can be stopped loudly instead of armed blind.
# GitLab merge requests take no account; the option is GitHub-only.
# Usage: fm-pr-check.sh <task-id> <pr-url> [--gh-account <login>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which silently truncated
  # this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ] && [ "$#" -ne 4 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
ACCOUNT=
if [ "$#" -eq 4 ]; then
  if [ "$3" != --gh-account ] || ! fm_pr_gh_account_valid "$4"; then
    echo "error: invalid PR check request" >&2
    exit 2
  fi
  ACCOUNT=$4
fi
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Without an explicit --gh-account, a previously recorded account stays bound
# so re-arming (including through fm-pr-merge.sh) cannot silently drop it back
# to ambient credentials. A recorded account that no longer validates is an
# error to resolve, never a silent fallback.
if [ -z "$ACCOUNT" ]; then
  RECORDED_ACCOUNT=$(grep '^gh_account=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -n "$RECORDED_ACCOUNT" ]; then
    if ! fm_pr_gh_account_valid "$RECORDED_ACCOUNT"; then
      echo "error: recorded gh account is invalid; re-arm with --gh-account" >&2
      exit 1
    fi
    ACCOUNT=$RECORDED_ACCOUNT
  fi
fi
if [ -n "$ACCOUNT" ] && [ "$PROVIDER" != github ]; then
  echo "error: a gh account applies only to a GitHub pull request" >&2
  exit 2
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# The same arming-time refusal for an account-bound watch: resolve the named
# account's token from gh's own store now, so a watch that could never see its
# PR is stopped here instead of armed blind. The token stays in this variable
# for the pr_head read below and is never written anywhere.
GH_TOKEN_VALUE=
if [ -n "$ACCOUNT" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: an account-bound PR watch requires gh on PATH" >&2
    exit 1
  fi
  if ! GH_TOKEN_VALUE=$(gh auth token -u "$ACCOUNT" 2>/dev/null) || [ -z "$GH_TOKEN_VALUE" ]; then
    echo "error: gh has no usable token for account $ACCOUNT; run gh auth login" >&2
    exit 1
  fi
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
gh_pr_view_head() {
  if [ -n "$ACCOUNT" ]; then
    GH_TOKEN="$GH_TOKEN_VALUE" gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null
  else
    gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null
  fi
}
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh_pr_view_head) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" "$ACCOUNT" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*|gh_account=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
[ -z "$ACCOUNT" ] || printf 'gh_account=%s\n' "$ACCOUNT" >> "$META_TMP" || exit 1
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] \
  && [ "$FM_PR_META_GH_ACCOUNT" = "$ACCOUNT" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] \
  && [ "$FM_PR_META_GH_ACCOUNT" = "$ACCOUNT" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
