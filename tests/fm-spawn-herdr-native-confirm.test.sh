#!/usr/bin/env bash
# tests/fm-spawn-herdr-native-confirm.test.sh - behavior tests for
# spawn_confirm_launch's seed-only native-busy corroboration
# (data/fm-herdr-friction-s1/report.md finding F7, work item W8).
#
# While the ONLY busy record for a freshly spawned target is fm-spawn's own
# launch seed (never advanced by a real lifecycle event), a capability-gated
# backend's native busy read (fm_busy_native_busy_capable in
# bin/fm-busy-lib.sh; herdr today) confirms processing instead of polling to
# the confirm timeout. This suite exercises the REAL bin/fm-spawn.sh end to
# end against a hermetic, stateful fake `herdr` CLI (mirrors
# tests/fm-backend-herdr.test.sh's make_herdr_statefake) rather than a live
# Herdr session: the fix is pure control flow inside spawn_confirm_launch, and
# every primitive it depends on (fm_backend_herdr_busy_state,
# fm_backend_herdr_agent_alive, the herdr JSON shapes) already has its own
# live-verified and fixture coverage elsewhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

# This suite fakes the herdr CLI entirely, but a real herdr pane's injected
# identity (HERDR_PANE_ID and friends) would otherwise leak in and make
# fm_backend_herdr_launcher_identity try to resolve a real launcher pane
# through the fake CLI, which cannot answer for it.
herdr_forget_inherited_pane

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-native-confirm)

# make_herdr_fakebin: a stateful `herdr` CLI stub covering exactly the
# subcommands a claude/herdr scout spawn's container-ensure, task-create, and
# confirm phase exercise: status, server, workspace/tab/pane create and list,
# pane get/run/send-text/send-keys/read, and agent get. Modeled response
# shapes match bin/backends/herdr.sh's own jq field reads (verified facts
# recorded in docs/herdr-backend.md), the same shapes
# tests/fm-backend-herdr.test.sh's make_herdr_statefake uses. Every call is
# logged unit-separated to $FM_FAKE_HERDR_LOG for call-count assertions.
#
# FM_FAKE_HERDR_CWD: the foreground_cwd every `pane get` reports, regardless
# of what was actually sent to the pane - mirrors the tmux fakes' static
# FM_FAKE_PANE_PATH, since "treehouse get" is never really executed by a fake
# shell. FM_FAKE_HERDR_AGENT_STATUS: the agent_status every `agent get`
# reports for the task pane once created (empty means agent_not_found,
# modeling a never-registered agent).
make_herdr_fakebin() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_FAKE_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
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
    if [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
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

herdr_call_count() {  # <log-file> <cmd-space-sub-pattern>
  grep -c "$2" "$1" 2>/dev/null || true
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
    FM_FAKE_HERDR_CWD="$worktree" \
    FM_SPAWN_AUTONOMY_POLLS=1 FM_SPAWN_AUTONOMY_POLL_INTERVAL=0 \
    env "$@" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --harness claude --scout 2>&1
}

confirm_line_is_final() {
  local out=$1 spawned_line confirm_line
  spawned_line=$(printf '%s\n' "$out" | grep -n '^spawned ' | tail -1 | cut -d: -f1)
  confirm_line=$(printf '%s\n' "$out" | grep -n '^confirm: ' | tail -1 | cut -d: -f1)
  [ -n "$spawned_line" ] || fail "no spawned line in output"
  [ -n "$confirm_line" ] || fail "no confirm line in output"
  [ "$confirm_line" -gt "$spawned_line" ] || fail "confirm line is not the final stdout line"
}

test_herdr_native_working_confirms_seed_promptly() {
  local id="herdr-confirm-native-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case native "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # No claude-hook ever fires (no real claude process runs against the fake),
  # so the only busy record ever written is fm-spawn's own launch seed.
  # herdr's native agent read reports "working" from the start, exactly F7's
  # reproduction: the record never advances but the native verdict is
  # positive immediately.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" \
    FM_FAKE_HERDR_AGENT_STATUS=working \
    FM_SPAWN_CONFIRM_TIMEOUT=5 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5) || rc=$?
  expect_code 0 "$rc" "a native-busy-corroborated seed must not fail the spawn"$'\n'"$out"
  assert_contains "$out" "confirm: processing busy/herdr-native" \
    "the native busy read did not corroborate the seed-only record"
  confirm_line_is_final "$out"
  # spawn_confirm_launch's busy/fm-spawn branch returns BEFORE spawn_capture
  # (`pane read`) is ever reached when the native corroboration fires, so a
  # confirmation on the very first poll adds no `pane read` call of its own.
  # Exactly 2 `pane read` calls are expected from the autonomy-mode
  # verification phase alone (FM_SPAWN_AUTONOMY_POLLS=1 still captures once
  # before its poll loop and once at the end of its one iteration; unrelated
  # to spawn_confirm_launch). A confirmation on the very first confirm poll
  # must add none beyond that baseline; the unconfirmed path (test below)
  # adds several more, one per poll.
  [ "$(herdr_call_count "$TMP_ROOT/$id.log" $'\x1f''pane'$'\x1f''read')" = 2 ] || \
    fail "confirmation on the first poll must not have polled the pane from the confirm loop (expected exactly the 2 autonomy-phase reads, got $(herdr_call_count "$TMP_ROOT/$id.log" $'\x1f''pane'$'\x1f''read'))"
  [ ! -f "$home/state/$id.status" ] || assert_no_grep 'blocked:' "$home/state/$id.status" "processing must not append a blocked line"
  pass "fm-spawn: herdr's native busy read corroborates a seed-only busy/fm-spawn record instead of polling to the timeout"
}

test_herdr_native_not_busy_still_polls_to_timeout() {
  local id="herdr-confirm-noconfirm-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case noconfirm "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # The agent IS registered (alive, unlike the never-registered case, which
  # the pre-existing agent-liveness override - F4/W4 - would classify dead
  # before this code is ever reached) but its native status is idle, never
  # working, so the native read is never positive evidence. The fix must not
  # weaken the real confirmation: this still polls the bounded budget and
  # reports the honest seed-only unknown, exactly as before the fix (mirrors
  # tests/fm-spawn-confirm.test.sh's
  # test_seed_busy_record_alone_is_not_processing for backend=tmux).
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" \
    FM_FAKE_HERDR_AGENT_STATUS=idle \
    FM_SPAWN_CONFIRM_TIMEOUT=1.5 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5) || rc=$?
  expect_code 0 "$rc" "a seed-only launch with no positive native read must not fail the spawn"$'\n'"$out"
  assert_contains "$out" "confirm: unknown no-busy-event" \
    "an absent native verdict was wrongly treated as processing evidence"
  confirm_line_is_final "$out"
  # More than the 2-call autonomy-phase baseline (see the test above) proves
  # the confirm loop itself kept polling instead of confirming immediately.
  [ "$(herdr_call_count "$TMP_ROOT/$id.log" $'\x1f''pane'$'\x1f''read')" -gt 2 ] || \
    fail "an unconfirmed seed-only record must still poll the pane across the bounded budget"
  [ ! -f "$home/state/$id.status" ] || assert_no_grep 'blocked:' "$home/state/$id.status" "unknown must not append a blocked line"
  pass "fm-spawn: a registered but non-busy herdr agent gives no native corroboration, so the seed-only record still polls to the timeout"
}

test_herdr_native_working_confirms_seed_promptly
test_herdr_native_not_busy_still_polls_to_timeout
