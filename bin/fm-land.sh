#!/usr/bin/env bash
# Land one shipped PR task in one guarded chain: merge the recorded PR, refresh
# the merged project's clone through the guarded fleet-sync owner, tear the task
# down, complete its backlog item, and print the queue re-evaluation cue.
# This tool NEVER decides merge authority. Firstmate runs it only after the
# captain's explicit word or the project's standing yolo authority. Its own
# guards are mechanical: it refuses when preconditions are missing, and it
# inherits bin/fm-pr-merge.sh's green/mergeable refusals. It has NO force flags
# and NO discard paths; a teardown refusal is a terminal stop-and-report, never
# bypassed.
# The chain stops at the first failure with "land: failed at <step>: <evidence>"
# and a nonzero exit, so firstmate can fix the cause and re-run the same command.
# Re-running after a mid-chain failure detects already-completed steps - PR
# already merged, clone already current, worktree already gone, task already
# done - and continues from the first incomplete step, reporting each skip as
# "land: <step> already done".
# Before any action the task meta (state/<id>.meta) must exist and carry pr=;
# otherwise the tool refuses, naming exactly what is missing. The one exception
# is a task already recorded Done in the backlog: its meta is gone only because
# teardown already completed, so the chain resumes from the backlog step onward.
# The tool mutates nothing under projects/ itself except through the guarded
# fleet-sync owner, and it never touches another task's state.
# On success it prints "land: complete <task-id> <pr-url>".
# Exit status: 0 complete, 1 refused or failed with evidence, 2 usage error.
# Usage: fm-land.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="${FM_BACKLOG_OVERRIDE:-$FM_HOME/data/backlog.md}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which silently truncated
  # this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -ne 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "usage: fm-land.sh <task-id>" >&2
  exit 2
fi
ID=$1

# Resolve sibling bin scripts through PATH, so the caller does not need the
# firstmate bin dir on PATH. The dir is appended, never prepended, so a caller
# with its own earlier PATH entry (a test fakebin, for example) still wins.
case ":$PATH:" in
  *":$SCRIPT_DIR:"*) ;;
  *) export PATH="${PATH:+$PATH:}$SCRIPT_DIR" ;;
esac

META="$STATE/$ID.meta"
RESUME=0
PR_URL=
LAND_STEP_OUT=

# Run one chain step: capture the child's combined output, replay it on success,
# and stop the whole chain on failure with the evidence line.
run_step() {
  local step=$1 run_cwd=$2 rc=0 evidence
  shift 2
  if LAND_STEP_OUT=$(cd "$run_cwd" && "$@" 2>&1); then
    :
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    [ -z "$LAND_STEP_OUT" ] || printf '%s\n' "$LAND_STEP_OUT" >&2
    evidence=$(printf '%s\n' "$LAND_STEP_OUT" | sed '/^$/d' | head -1)
    [ -n "$evidence" ] || evidence="exit $rc"
    echo "land: failed at $step: $evidence" >&2
    exit 1
  fi
}

replay_step_out() {
  [ -z "$LAND_STEP_OUT" ] || printf '%s\n' "$LAND_STEP_OUT"
}

# Is the recorded PR already merged? A read-only probe that resolves the stored
# gh_account token exactly like fm-pr-check/fm-pr-merge resolve it, so a resume
# run can skip a merge that already happened. Any failure here means "cannot
# prove merged", and the merge step then re-validates through fm-pr-merge.sh.
pr_is_merged() {
  local account token state
  fm_pr_url_parse "$PR_URL" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  account=$(grep '^gh_account=' "$META" | tail -1 | cut -d= -f2- || true)
  token=
  if [ -n "$account" ]; then
    fm_pr_gh_account_valid "$account" || return 1
    token=$(gh auth token -u "$account" 2>/dev/null) || return 1
    [ -n "$token" ] || return 1
  fi
  if [ -n "$token" ]; then
    state=$(GH_TOKEN="$token" gh pr view "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" --json state -q .state 2>/dev/null) || return 1
  else
    state=$(gh pr view "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" --json state -q .state 2>/dev/null) || return 1
  fi
  [ "$state" = MERGED ]
}

# Is the task already Done in this home's backlog? tasks-axi show answers for
# the tasks-axi backend; a done-line grep of the backlog file for the manual
# backend.
task_is_done() {
  local out
  if fm_backlog_backend_manual "$CONFIG"; then
    [ -f "$BACKLOG" ] || return 1
    grep -qE -- "^- \\[x\\] $(printf '%s' "$ID" | sed 's/\./\\./g')( |$)" "$BACKLOG" 2>/dev/null
  else
    out=$(cd "$FM_HOME" && tasks-axi show "$ID" 2>&1) || return 1
    printf '%s\n' "$out" | grep -q '^  state: done'
  fi
}

# Recover the recorded PR URL after the meta is gone: the done item's pr link
# for the tasks-axi backend, the item line in the backlog file otherwise.
recover_pr_url() {
  local out line
  if ! fm_backlog_backend_manual "$CONFIG"; then
    out=$(cd "$FM_HOME" && tasks-axi show "$ID" --full 2>&1) || return 1
    line=$(printf '%s\n' "$out" | sed -n 's/^  links: "pr:\(.*\)"$/\1/p' | head -1)
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi
  [ -f "$BACKLOG" ] || return 1
  grep -E -- "^- \\[x\\] $(printf '%s' "$ID" | sed 's/\./\\./g')( |$)" "$BACKLOG" 2>/dev/null \
    | grep -oE 'https://[^ )"]*pull/[0-9]+' \
    | head -1
}

manual_backlog_edit_instruction() {
  printf 'land: manual backlog: edit %s now - change "- [ ] %s -" to "- [x] %s -" and append the PR URL %s to that line; keep Done to the 10 most recent entries.\n' \
    "$BACKLOG" "$ID" "$ID" "$PR_URL"
}

# --- preconditions ---------------------------------------------------------

if [ -f "$META" ] && [ ! -L "$META" ]; then
  PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -z "$PR_URL" ]; then
    echo "error: task $ID meta exists but carries no pr=; record the PR first with bin/fm-pr-check.sh $ID <pr-url>" >&2
    exit 1
  fi
elif task_is_done; then
  # No meta means teardown already completed (it removes the meta only after a
  # successful cleanup), and a Done backlog item corroborates that earlier run;
  # resume from the backlog step onward instead of refusing.
  RESUME=1
  PR_URL=$(recover_pr_url || true)
else
  echo "error: no meta for task $ID at $META; the task is not recorded Done in the backlog" >&2
  exit 1
fi

# --- the chain -------------------------------------------------------------

PROJ=
if [ "$RESUME" = 1 ]; then
  echo "land: merge already done"
  echo "land: clone refresh already done"
  echo "land: cleanup already done"
  echo "land: backlog already done"
else
  PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)

  if pr_is_merged; then
    echo "land: merge already done"
  else
    run_step merge . fm-pr-merge.sh "$ID" "$PR_URL"
    replay_step_out
    echo "land: merge done"
  fi

  if [ -z "$PROJ" ]; then
    echo "land: failed at clone refresh: task $ID meta carries no project=" >&2
    exit 1
  fi
  run_step clone-refresh . fm-fleet-sync.sh "$PROJ"
  if printf '%s\n' "$LAND_STEP_OUT" | grep -qF 'already current'; then
    echo "land: clone refresh already done"
  else
    echo "land: clone refresh done"
  fi
  replay_step_out

  run_step cleanup . fm-teardown.sh "$ID"
  replay_step_out
  echo "land: cleanup done"

  if task_is_done; then
    echo "land: backlog already done"
  elif fm_backlog_backend_manual "$CONFIG"; then
    manual_backlog_edit_instruction
  else
    run_step backlog "$FM_HOME" tasks-axi 'done' "$ID" --pr "$PR_URL"
    replay_step_out
    echo "land: backlog done"
  fi
fi

# --- queue re-evaluation cue -----------------------------------------------

if fm_backlog_backend_manual "$CONFIG"; then
  echo "land: manual backlog: re-scan queued work in $BACKLOG and dispatch only items whose blockers are gone and date is due."
else
  run_step ready-cue "$FM_HOME" tasks-axi ready
  echo "land: ready:"
  replay_step_out
fi

if [ -n "$PR_URL" ]; then
  echo "land: complete $ID $PR_URL"
else
  echo "land: complete $ID (pr url not recorded)"
fi
