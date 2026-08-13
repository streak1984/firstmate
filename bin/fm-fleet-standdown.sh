#!/usr/bin/env bash
# fm-fleet-standdown.sh - execute a deterministic subordinate fleet stand-down.
#
# Usage: fm-fleet-standdown.sh
#
# The `fleet-standdown` skill owns the procedure, evidence interpretation,
# captain surfacing, and the decision that the fleet is ready. This script does
# not decide PR authority, backup adequacy, or the meaning of a captain-held
# decision. It mechanically rechecks only preconditions represented by existing
# executable owners, then performs clean exits.
#
# Phase 1 is read-only and must finish for the whole fleet before any exit is
# submitted. It requires the invoking session lock, an empty durable wake queue,
# a valid registry and complete structured snapshot, no recorded ordinary
# crewmates, no active or recorded secondmate child work, and no safety-relevant
# unknown, contradiction, truncation, or status-only gate. The landed-work check
# delegates to `fm-teardown.sh --check-only` rather than reimplementing it.
#
# Phase 2 resolves the clean-exit command through
# `fm-harness.sh exit-command <harness>`, submits it to each verified-live
# secondmate through the backend's bare, unmarked submission primitive, and
# waits for both a dead-or-missing agent classification and a released session
# lock. The marked `fm-send` steering channel is deliberately not used because
# its operational envelope makes slash commands ordinary agent input. Already
# dormant secondmates require the same lock proof.
# Exactly one clean-exit command is submitted per live secondmate, followed by
# the bounded wait below; a stubborn session is left alive for the captain's
# decision rather than retried forever, interrupted, force-killed, or closed.
# A harness exit normally leaves its pane alive at a login shell, so pane
# existence is not agent liveness: `dead` means that shell is positively
# agent-free, `missing` means the endpoint is gone, and alive, ambiguous,
# unreadable, or unverified never passes. Final agent messages are not evidence.
# Metadata, status, backlogs, registries, homes, clones, worktrees, data stores,
# backend containers, and the lock files themselves are deliberately left alone.
# A stale lock file is released semantically because its recorded harness process
# is gone; preserving its bytes lets session start reclaim it normally.
#
# The invoking primary is deliberately outside the stop set so this process can
# prove subordinate completion and print it before the terminal layer restarts.
# It cannot stop or prove the later death of its own session, and it cannot
# perform or prove the terminal-layer restart. A phase-2 failure may leave an
# already-confirmed prefix stopped and is reported as partial rather than atomic.
#
# Idempotence: dead or missing secondmate agents with released locks are reported
# as already dormant, so running the command twice and running it on an empty
# fleet are both successful no-ops. It never calls spawn or any restart path.
# A home-scoped watcher is classified through `fm-supervision-lib.sh` and the
# watcher lock owner: one attached to recorded work or X polling is legitimate
# supervision and blocks stand-down, while a live watcher with no supervision
# need is a leak. Neither case is signaled or killed here, and stale task
# metadata is never repaired by writing into a project.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BIN="$FM_ROOT/bin"
WAIT_SECS=${FM_STANDDOWN_WAIT_SECS:-20}
MAX_SECONDMATES=${FM_STANDDOWN_MAX_SECONDMATES:-1000}
EXIT_ATTEMPTS=1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) echo "error: fm-fleet-standdown.sh takes no arguments" >&2; exit 2 ;;
esac

case "$WAIT_SECS" in
  ''|*[!0-9]*|0) echo "error: FM_STANDDOWN_WAIT_SECS must be a positive integer" >&2; exit 2 ;;
esac
case "$MAX_SECONDMATES" in
  ''|*[!0-9]*|0) echo "error: FM_STANDDOWN_MAX_SECONDMATES must be a positive integer" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required for fleet stand-down" >&2
  exit 1
}

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$BIN/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent "$FM_ROOT"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$BIN/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$BIN/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$BIN/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$BIN/fm-supervision-lib.sh"

if ! fm_session_lock_owned_by_self "$STATE"; then
  echo "REFUSED: the invoking firstmate does not verifiably own $STATE/.lock; no agent received an exit command." >&2
  exit 1
fi
if [ -e "$STATE/.afk" ] || [ -L "$STATE/.afk" ]; then
  echo "REFUSED: away mode is active in $FM_HOME; return from away mode before standing the fleet down. No agent received an exit command." >&2
  exit 1
fi
if [ -e "$STATE/.wake-queue" ] || [ -L "$STATE/.wake-queue" ]; then
  if [ -L "$STATE/.wake-queue" ] || [ ! -f "$STATE/.wake-queue" ]; then
    echo "REFUSED: the durable wake queue at $STATE/.wake-queue is not a safe regular file; no agent received an exit command." >&2
    exit 1
  fi
  if [ -s "$STATE/.wake-queue" ]; then
    wake_count=$(awk 'END { print NR + 0 }' "$STATE/.wake-queue")
    echo "REFUSED: the durable wake queue has $wake_count undrained record(s); handle them through fm-wake-drain.sh before stand-down. No agent received an exit command." >&2
    exit 1
  fi
fi

PLAN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-standdown.XXXXXX")
cleanup_plan() {
  case "$PLAN_DIR" in
    "${TMPDIR:-/tmp}"/fm-fleet-standdown.*) rm -rf -- "$PLAN_DIR" ;;
  esac
}
trap cleanup_plan EXIT
mkdir -p "$PLAN_DIR/plans" "$PLAN_DIR/dormant"
ERRORS="$PLAN_DIR/errors"
SNAPSHOT="$PLAN_DIR/snapshot.json"

record_error() {
  printf '%s\n' "$*" >> "$ERRORS"
}

record_error_block() {
  local heading=$1 body=${2:-}
  printf '%s\n' "$heading" >> "$ERRORS"
  if [ -n "$body" ]; then
    while IFS= read -r line; do
      printf '  %s\n' "$line" >> "$ERRORS"
    done <<EOF
$body
EOF
  fi
}

lock_is_released() {
  local home=$1 out
  if ! out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" "$BIN/fm-lock.sh" status 2>&1); then
    LAST_LOCK_STATUS="lock status command failed: $out"
    return 1
  fi
  LAST_LOCK_STATUS=$out
  case "$out" in
    "lock: free"|"lock: stale"*) return 0 ;;
    *) return 1 ;;
  esac
}

watcher_inventory_state() {
  local home=$1 home_state="$1/state" watch_path="$1/bin/fm-watch.sh"
  local lock pid
  WATCHER_STATE=unreadable
  WATCHER_DESC="watcher state unreadable"
  WATCHER_NEEDED=unknown
  WATCHER_IN_FLIGHT=unknown
  if [ ! -d "$home_state" ] || [ -L "$home_state" ]; then
    WATCHER_DESC="unsafe or missing state directory $home_state"
    return 0
  fi

  fm_supervision_status "$home_state"
  WATCHER_NEEDED=$FM_SUP_NEEDED
  WATCHER_IN_FLIGHT=$FM_SUP_IN_FLIGHT
  if fm_watcher_healthy "$home_state" "$watch_path" "${FM_GUARD_GRACE:-300}" "$home"; then
    WATCHER_STATE=live
    WATCHER_DESC="healthy home-scoped watcher pid $FM_WATCHER_HEALTHY_PID"
    return 0
  fi

  lock="$home_state/.watch.lock"
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    WATCHER_STATE=missing
    WATCHER_DESC="no watcher lock"
    return 0
  fi
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*)
      WATCHER_STATE=unreadable
      WATCHER_DESC="watcher lock has no readable pid"
      ;;
    *)
      if fm_pid_alive "$pid"; then
        if fm_watcher_lock_matches_pid "$home_state" "$watch_path" "$pid" "$home"; then
          WATCHER_STATE=live
          WATCHER_DESC="home-scoped watcher pid $pid is live but its beacon is stale"
        else
          WATCHER_STATE=ambiguous
          WATCHER_DESC="live pid $pid cannot be attributed to this home's watcher"
        fi
      else
        WATCHER_STATE=stale
        WATCHER_DESC="watcher lock pid $pid is dead"
      fi
      ;;
  esac
}

check_recorded_crew() {
  local owner=$1 id=$2 meta=$3 out kind owner_state
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    record_error "REFUSED: crewmate $id has missing or unsafe metadata at $meta."
    return 0
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" = secondmate ]; then
    record_error "REFUSED: nested secondmate metadata $meta is outside the supported fleet shape."
    return 0
  fi
  owner_state=$(dirname "$meta")
  if out=$(FM_HOME="$owner" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$owner_state" FM_DATA_OVERRIDE="$owner/data" \
      FM_CONFIG_OVERRIDE="$owner/config" \
      "$BIN/fm-teardown.sh" "$id" --check-only 2>&1); then
    record_error "REFUSED: crewmate $id remains recorded in $owner; finish and tear it down before fleet stand-down."
  else
    record_error_block "REFUSED: crewmate $id failed the landed-work preflight in $owner." "$out"
  fi
}

if ! FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_DATA_OVERRIDE="$DATA" "$BIN/fm-home-seed.sh" validate \
    >"$PLAN_DIR/registry.out" 2>"$PLAN_DIR/registry.err"; then
  record_error_block "REFUSED: secondmate registry validation failed." "$(cat "$PLAN_DIR/registry.err" "$PLAN_DIR/registry.out")"
fi

if ! FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_SNAPSHOT_SECONDMATES="$MAX_SECONDMATES" \
    FM_SNAPSHOT_SECONDMATE_CHILDREN="$MAX_SECONDMATES" \
    FM_SNAPSHOT_SECONDMATE_QUEUED="$MAX_SECONDMATES" \
    FM_SNAPSHOT_SECONDMATE_DECISIONS="$MAX_SECONDMATES" \
    "$BIN/fm-fleet-snapshot.sh" --json > "$SNAPSHOT"; then
  record_error "REFUSED: the read-only fleet snapshot failed."
elif ! jq -e '
    .schema == "fm-fleet-snapshot.v1"
    and (.tasks | type) == "array"
    and (.secondmate_current.records | type) == "array"
    and (.secondmate_current.registry.complete | type) == "boolean"
  ' "$SNAPSHOT" >/dev/null 2>&1; then
  record_error "REFUSED: the read-only fleet snapshot was malformed."
fi

if [ -s "$SNAPSHOT" ] && jq -e '.schema == "fm-fleet-snapshot.v1"' "$SNAPSHOT" >/dev/null 2>&1; then
  if ! jq -e '.main_inventory.valid == true' "$SNAPSHOT" >/dev/null 2>&1; then
    record_error "REFUSED: main-home inventory is not durable and consistent: $(jq -r '.main_inventory.reason // "unknown reason"' "$SNAPSHOT")."
  fi
  if ! jq -e '
      .secondmate_current.registry.complete == true
      and .secondmate_current.truncated == false
      and .secondmate_current.total == .secondmate_current.shown
    ' "$SNAPSHOT" >/dev/null 2>&1; then
    record_error "REFUSED: registered secondmate inventory was incomplete or truncated."
  fi

  jq -r '.tasks[] | select(.kind != "secondmate") | [.id,.paths.meta.path] | @tsv' "$SNAPSHOT" \
    > "$PLAN_DIR/main-crews"
  while IFS=$'\t' read -r crew_id crew_meta; do
    [ -n "$crew_id" ] || continue
    check_recorded_crew "$FM_HOME" "$crew_id" "$crew_meta"
  done < "$PLAN_DIR/main-crews"

  jq -r '.secondmate_current.records[].id' "$SNAPSHOT" > "$PLAN_DIR/secondmate-ids"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! fm_task_id_path_safe "$id"; then
      record_error "REFUSED: unsafe secondmate id in fleet snapshot: $id."
      continue
    fi
    record=$(jq -c --arg id "$id" '.secondmate_current.records[] | select(.id == $id)' "$SNAPSHOT")
    home=$(printf '%s' "$record" | jq -r '.home // ""')
    selected=$(printf '%s' "$record" | jq -r '.provenance.selected // "unknown"')
    summary_valid=$(printf '%s' "$record" | jq -r '.provenance.summary_valid // false')
    current=$(printf '%s' "$record" | jq -r '.current.state // "unknown"')
    contradiction=$(printf '%s' "$record" | jq -r '.contradiction // false')

    if [ -z "$home" ] || [ "$selected" != structured-home ] || [ "$summary_valid" != true ]; then
      reason=$(printf '%s' "$record" | jq -r '.current.reason // "structured secondmate home is unavailable"')
      record_error "REFUSED: secondmate $id has no complete validated home summary: $reason."
      continue
    fi
    case "$current" in
      no_active_work|captain_decision|externally_held) ;;
      active_child_work)
        active=$(printf '%s' "$record" | jq -r '[.active_children[].id] | join(", ")')
        record_error "REFUSED: secondmate $id reports work in flight${active:+: $active}."
        ;;
      *)
        reason=$(printf '%s' "$record" | jq -r '.current.reason // "current state is unknown"')
        record_error "REFUSED: secondmate $id current state is not safely classifiable: $reason."
        ;;
    esac
    if [ "$contradiction" = true ]; then
      record_error "REFUSED: secondmate $id has contradictory parent and structured-home evidence."
    fi
    if printf '%s' "$record" | jq -e '
        any(.omitted[]?; .surface == "active_children" or .surface == "decisions_open" or .surface == "endpoints")
      ' >/dev/null; then
      record_error "REFUSED: secondmate $id safety-relevant structured state was truncated."
    fi
    undurable=$(printf '%s' "$record" | jq -r '
      [(.decisions_open[]? | select(.source != "backlog") | "decision " + (.key // .id // "unknown")),
       (.holds[]? | select(.source != "backlog") | "hold " + (.id // "unknown"))]
      | join(", ")')
    if [ -n "$undurable" ]; then
      record_error "REFUSED: secondmate $id has captain-gated state not yet recorded in its backlog: $undurable."
    fi

    child_count=$(printf '%s' "$record" | jq -r '.counts.endpoints // 0')
    case "$child_count" in ''|*[!0-9]*) child_count=1 ;; esac
    if [ "$child_count" -gt 0 ]; then
      record_error "REFUSED: secondmate $id still has $child_count recorded crewmate task(s) in $home."
    fi
    if [ -d "$home/state" ] && [ ! -L "$home/state" ]; then
      for child_meta in "$home/state"/*.meta; do
        [ -e "$child_meta" ] || [ -L "$child_meta" ] || continue
        child_id=$(basename "$child_meta" .meta)
        check_recorded_crew "$home" "$child_id" "$child_meta"
      done
    elif [ "$child_count" -gt 0 ]; then
      record_error "REFUSED: secondmate $id state directory is unavailable at $home/state."
    fi

    watcher_inventory_state "$home"
    if [ "$WATCHER_NEEDED" = true ]; then
      record_error "REFUSED: secondmate $id still requires home-scoped supervision for $WATCHER_IN_FLIGHT recorded task(s) or X polling; $WATCHER_DESC is legitimate supervision, not a leak. Reconcile the owning lifecycle without writing into a project, force-cleaning metadata, or killing the watcher."
    else
      case "$WATCHER_STATE" in
        missing|stale) ;;
        live)
          record_error "REFUSED: secondmate $id has a live home-scoped watcher despite no supervision need ($WATCHER_DESC); treat it as a leak and reconcile it through the watcher owner. No watcher was signaled or killed."
          ;;
        *)
          record_error "REFUSED: secondmate $id watcher state is $WATCHER_STATE ($WATCHER_DESC); unreadable or ambiguous watcher inventory cannot prove a dormant home. No watcher was signaled or killed."
          ;;
      esac
    fi

    task=$(jq -c --arg id "$id" '[.tasks[] | select(.id == $id and .kind == "secondmate")][0] // null' "$SNAPSHOT")
    if [ "$task" = null ]; then
      if lock_is_released "$home"; then
        printf '%s\n%s\n%s\n' "$home" "$LAST_LOCK_STATUS" "no recorded endpoint" > "$PLAN_DIR/dormant/$id"
      else
        record_error "REFUSED: registered secondmate $id has no endpoint metadata but its session lock is not released ($LAST_LOCK_STATUS)."
      fi
      continue
    fi

    meta=$(printf '%s' "$task" | jq -r '.paths.meta.path // ""')
    harness=$(printf '%s' "$task" | jq -r '.harness // ""')
    if ! fm_backend_validate_task_endpoint "$meta" "$id" >"$PLAN_DIR/$id.validate.out" 2>"$PLAN_DIR/$id.validate.err"; then
      record_error_block "REFUSED: secondmate $id endpoint metadata is unsafe." "$(cat "$PLAN_DIR/$id.validate.err" "$PLAN_DIR/$id.validate.out")"
      continue
    fi
    backend=$FM_BACKEND_VALIDATED_BACKEND
    target=$FM_BACKEND_VALIDATED_TARGET
    agent_state=$(fm_backend_agent_state "$backend" "$target")
    case "$agent_state" in
      alive)
        if ! exit_cmd=$("$BIN/fm-harness.sh" exit-command "$harness" 2>"$PLAN_DIR/$id.harness.err"); then
          record_error_block "REFUSED: secondmate $id uses a harness without a verified clean-exit command." "$(cat "$PLAN_DIR/$id.harness.err")"
          continue
        fi
        printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
          "$home" "$meta" "$backend" "$target" "$harness" "$exit_cmd" > "$PLAN_DIR/plans/$id"
        ;;
      dead|missing)
        if lock_is_released "$home"; then
          printf '%s\n%s\n%s\n' "$home" "$LAST_LOCK_STATUS" "agent $agent_state" > "$PLAN_DIR/dormant/$id"
        else
          record_error "REFUSED: secondmate $id agent is $agent_state but its session lock is not released ($LAST_LOCK_STATUS)."
        fi
        ;;
      *)
        record_error "REFUSED: secondmate $id agent state is $agent_state on backend $backend; clean exit cannot be proved, so no agent will be touched."
        ;;
    esac
  done < "$PLAN_DIR/secondmate-ids"
fi

if [ -s "$ERRORS" ]; then
  cat "$ERRORS" >&2
  echo "standdown: REFUSED - fleet-wide safety preflight failed; no agent received an exit command." >&2
  exit 1
fi

stopped=0
already=0
total=0
for dormant in "$PLAN_DIR/dormant"/*; do
  [ -f "$dormant" ] || continue
  id=$(basename "$dormant")
  home=$(sed -n '1p' "$dormant")
  lock_status=$(sed -n '2p' "$dormant")
  agent_evidence=$(sed -n '3p' "$dormant")
  printf 'standdown: already dormant secondmate %s (%s; %s; home %s)\n' \
    "$id" "$agent_evidence" "$lock_status" "$home"
  already=$((already + 1))
  total=$((total + 1))
done

for plan in "$PLAN_DIR/plans"/*; do
  [ -f "$plan" ] || continue
  id=$(basename "$plan")
  home=$(sed -n '1p' "$plan")
  meta=$(sed -n '2p' "$plan")
  backend=$(sed -n '3p' "$plan")
  target=$(sed -n '4p' "$plan")
  harness=$(sed -n '5p' "$plan")
  exit_cmd=$(sed -n '6p' "$plan")

  if ! fm_backend_validate_task_endpoint "$meta" "$id" >"$PLAN_DIR/$id.revalidate.out" 2>"$PLAN_DIR/$id.revalidate.err"; then
    echo "standdown: FAILED after stopping $stopped secondmate(s) - endpoint metadata changed for $id after preflight." >&2
    cat "$PLAN_DIR/$id.revalidate.err" "$PLAN_DIR/$id.revalidate.out" >&2
    exit 1
  fi
  if [ "$FM_BACKEND_VALIDATED_BACKEND" != "$backend" ] || [ "$FM_BACKEND_VALIDATED_TARGET" != "$target" ]; then
    echo "standdown: FAILED after stopping $stopped secondmate(s) - endpoint identity changed for $id after preflight." >&2
    exit 1
  fi
  agent_state=$(fm_backend_agent_state "$backend" "$target")
  if [ "$agent_state" != alive ]; then
    echo "standdown: FAILED after stopping $stopped secondmate(s) - $id changed from alive to $agent_state after preflight; no exit command was sent to it." >&2
    exit 1
  fi

  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$exit_cmd" 3 0.4 1.2 "fm-$id"); then
    echo "standdown: FAILED after stopping $stopped secondmate(s) - clean-exit transport failed for $id." >&2
    exit 1
  fi
  case "$verdict" in
    ''|queued) ;;
    *)
      echo "standdown: FAILED after stopping $stopped secondmate(s) - clean-exit submission for $id was not confirmed (verdict: $verdict)." >&2
      exit 1
      ;;
  esac

  deadline=$(( $(date +%s) + WAIT_SECS ))
  confirmed=0
  while [ "$(date +%s)" -le "$deadline" ]; do
    agent_state=$(fm_backend_agent_state "$backend" "$target")
    if { [ "$agent_state" = dead ] || [ "$agent_state" = missing ]; } \
      && lock_is_released "$home"; then
      confirmed=1
      break
    fi
    sleep 1
  done
  if [ "$confirmed" -ne 1 ]; then
    echo "standdown: REFUSED after stopping $stopped secondmate(s) - secondmate $id at $target did not prove both agent exit and session-lock release after $EXIT_ATTEMPTS bounded clean-exit attempt within ${WAIT_SECS}s (agent=$agent_state; ${LAST_LOCK_STATUS:-lock unread})." >&2
    echo "standdown: captain decision required - $id was left untouched and no interrupt, force-kill, endpoint close, or terminal restart was attempted." >&2
    exit 1
  fi
  watcher_inventory_state "$home"
  if [ "$WATCHER_NEEDED" = true ] || { [ "$WATCHER_STATE" != missing ] && [ "$WATCHER_STATE" != stale ]; }; then
    echo "standdown: REFUSED after stopping $stopped secondmate(s) - secondmate $id agent exited, but its watcher did not prove dormant (needed=$WATCHER_NEEDED; state=$WATCHER_STATE; $WATCHER_DESC)." >&2
    echo "standdown: captain decision required - no watcher was signaled or killed and no project or task metadata was changed." >&2
    exit 1
  fi
  printf 'standdown: stopped secondmate %s cleanly (harness %s; backend %s; agent %s; %s)\n' \
    "$id" "$harness" "$backend" "$agent_state" "$LAST_LOCK_STATUS"
  stopped=$((stopped + 1))
  total=$((total + 1))
done

if [ "$total" -eq 0 ]; then
  echo "standdown: subordinate fleet already empty; nothing to stop."
else
  printf 'standdown: subordinate fleet complete - %d stopped, %d already dormant.\n' "$stopped" "$already"
fi
echo "left alone: the invoking firstmate session and its live session lock, so this command could report subordinate completion."
echo "left alone: every home, backlog, registry entry, status record, clone, worktree, project, data store, backend container, and lock-file byte."
echo "not performed: no agent, watcher, home, backend container, or terminal layer was restarted."
echo "proof boundary: subordinate agents are dead or missing and their locks are released; this command cannot prove the later primary-session or terminal-layer shutdown."
