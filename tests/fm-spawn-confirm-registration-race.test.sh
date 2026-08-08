#!/usr/bin/env bash
# tests/fm-spawn-confirm-registration-race.test.sh - behavior tests for
# spawn_confirm_registration_settled_verdict, the bounded retry that closes
# the ~1s gap between Herdr launching an agent process and Herdr's own agent
# registry recording it (data/fm-herdr-080-verify-w6/report.md
# "spawn-confirm vs agent-registration race", task
# fm-spawn-confirm-registration-race-g1).
#
# fm_busy_classify's capability-gated agent-liveness gate
# (fm_busy_agent_proof_capable, bin/fm-busy-lib.sh) is unconditional and
# non-retried, so spawn_confirm_launch's very first poll can read "dead
# agent-gone" while the agent is still genuinely starting, before Herdr's
# registry has caught up. This suite drives the REAL bin/fm-spawn.sh end to
# end against a hermetic, stateful fake `herdr` CLI (the same shape as
# tests/fm-spawn-herdr-native-confirm.test.sh's make_herdr_fakebin), proving
# the intended contract from spawn-confirm's own outcome, never from the
# implementation's internal retry mechanics: a target whose agent registers
# after a short delay is confirmed, not refused, and a target whose agent
# never registers is still refused once the bounded settle window elapses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

herdr_forget_inherited_pane

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-confirm-registration-race)

# make_herdr_fakebin: a stateful `herdr` CLI stub, the same subcommand
# surface as tests/fm-spawn-herdr-native-confirm.test.sh's
# make_herdr_fakebin, extended with a call-counted `agent get` so a caller
# can model an agent that registers only after N reads instead of either
# "always registered" or "never registered".
#
# FM_FAKE_HERDR_AGENT_REGISTERS_AFTER: number of `agent get` calls that
# still answer agent_not_found before the agent is considered registered;
# unset or 0 means registered from the first read, and a value higher than
# the test ever polls models an agent that never registers (the genuinely
# dead case). Once registered, FM_FAKE_HERDR_AGENT_STATUS (default
# "working") is reported.
make_herdr_fakebin() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$dir/state.json"
  : > "$dir/agent-get-count"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_FAKE_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
COUNT_FILE="${FM_FAKE_HERDR_AGENT_COUNT_FILE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; pane=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
  esac
done
pane=${3:-}

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    label=""
    for ((i=0; i<${#args[@]}; i++)); do
      [ "${args[$i]}" = --label ] && label=${args[$((i+1))]:-}
    done
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    label=""
    for ((i=0; i<${#args[@]}; i++)); do
      [ "${args[$i]}" = --label ] && label=${args[$((i+1))]:-}
    done
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "tab close")
    tab=${3:-}
    jq_state --arg t "$tab" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane close")
    p=${3:-}
    jq_state --arg p "$p" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "$pane" "${FM_FAKE_HERDR_CWD:-}"
    ;;
  "pane run"|"pane send-text"|"pane send-keys") ;;
  "pane read")
    printf '%s\n' "${FM_FAKE_HERDR_CAPTURE:-benign agent output}"
    ;;
  "agent get")
    n=0
    [ -f "$COUNT_FILE" ] && n=$(cat "$COUNT_FILE")
    n=$((n + 1))
    printf '%s\n' "$n" > "$COUNT_FILE"
    registers_after=${FM_FAKE_HERDR_AGENT_REGISTERS_AFTER:-0}
    if [ "$n" -gt "$registers_after" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${FM_FAKE_HERDR_AGENT_STATUS:-working}"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  fm_fake_exit0 "$fb" treehouse jq gh gh-axi sleep
  # jq must be the real tool (the fake herdr's own responses are parsed with
  # it), so undo the exit0 stub fm_fake_exit0 just installed.
  rm -f "$fb/jq"
  printf '%s\n' "$fb"
}

# make_case <name> <id> -> "<home>|<project>|<worktree>|<fakebin>"
make_case() {
  local name=$1 id=$2 dir home project worktree fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"; project="$dir/project"; worktree="$dir/worktree"
  fakebin=$(make_herdr_fakebin "$dir")
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  printf '%s|%s|%s|%s\n' "$home" "$project" "$worktree" "$fakebin"
}

# run_spawn <home> <project> <worktree> <fakebin> <id> [VAR=val ...]
run_spawn() {
  local home=$1 project=$2 worktree=$3 fakebin=$4 id=$5
  shift 5
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BACKEND=herdr HERDR_SESSION="fmtest-$id" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_LOG="$TMP_ROOT/$id.log" FM_FAKE_HERDR_STATE="$fakebin/../state.json" \
    FM_FAKE_HERDR_AGENT_COUNT_FILE="$fakebin/../agent-get-count" \
    FM_FAKE_HERDR_CWD="$worktree" \
    FM_SPAWN_AUTONOMY_POLLS=1 FM_SPAWN_AUTONOMY_POLL_INTERVAL=0 \
    env "$@" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --harness claude --scout 2>&1
}

# The exact race from data/fm-herdr-080-verify-w6/report.md: the agent
# registers two reads after the pane exists (well inside the settle
# window's default 6-poll budget), so the very first dead reads must not be
# trusted - spawn-confirm's own outcome must be a settle, not a refusal.
test_delayed_agent_registration_is_confirmed_not_refused() {
  local id="regrace-settles-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case settles "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" \
    FM_FAKE_HERDR_AGENT_REGISTERS_AFTER=2 FM_FAKE_HERDR_AGENT_STATUS=working \
    FM_SPAWN_CONFIRM_DEAD_SETTLE_TIMEOUT=1.5 FM_SPAWN_CONFIRM_DEAD_SETTLE_POLL_INTERVAL=0.1 \
    FM_SPAWN_CONFIRM_TIMEOUT=5 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5) || rc=$?
  expect_code 0 "$rc" "an agent that registers within the settle window must not fail the spawn"$'\n'"$out"
  assert_not_contains "$out" "confirm: failed endpoint-dead" \
    "a registration that settles within the window must not be reported as a dead endpoint"
  assert_contains "$out" "confirm: processing busy/herdr-native" \
    "the settled registration did not resume normal confirmation"
  [ ! -f "$home/state/$id.status" ] || assert_no_grep 'blocked:' "$home/state/$id.status" \
    "a settled registration must not append a blocked line"
  pass "fm-spawn: an agent that registers a beat after launch is confirmed, not refused as endpoint-dead"
}

# The counterfactual the fix must preserve: an agent that never registers
# (the genuine husk-pane case, data/fm-herdr-friction-s1/report.md F1/W1)
# still fails once the bounded settle window elapses - the retry narrows
# WHEN dead is trusted, it never turns dead into "never refuse".
test_agent_never_registering_is_still_refused_after_settle_window() {
  local id="regrace-stays-dead-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case stays-dead "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # A registers-after value higher than the settle window will ever poll to
  # models an agent that never registers.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" \
    FM_FAKE_HERDR_AGENT_REGISTERS_AFTER=999 \
    FM_SPAWN_CONFIRM_DEAD_SETTLE_TIMEOUT=0.6 FM_SPAWN_CONFIRM_DEAD_SETTLE_POLL_INTERVAL=0.1 \
    FM_SPAWN_CONFIRM_TIMEOUT=5 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5) || rc=$?
  expect_code 1 "$rc" "a target whose agent never registers must still fail the spawn"
  assert_contains "$out" "confirm: failed endpoint-dead" \
    "a husk that never registers an agent must still be refused as endpoint-dead"
  assert_grep 'blocked: the worker endpoint died right after launch' "$home/state/$id.status" \
    "the still-dead outcome did not append the blocked status line"
  # At least the initial read plus every settle-window poll must have run
  # (0.6s window / 0.1s interval = 6 polls), proving the window was actually
  # exhausted rather than the refusal firing on the very first read by luck.
  agent_get_calls=$(grep -c $'\x1f''agent'$'\x1f''get'$'\x1f' "$TMP_ROOT/$id.log" 2>/dev/null || true)
  [ "${agent_get_calls:-0}" -ge 6 ] || \
    fail "expected the settle window to be exhausted (>=6 agent get calls), got ${agent_get_calls:-0}"
  pass "fm-spawn: an agent that never registers is still refused once the bounded settle window elapses"
}

test_delayed_agent_registration_is_confirmed_not_refused
test_agent_never_registering_is_still_refused_after_settle_window
