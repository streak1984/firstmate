#!/usr/bin/env bash
# tests/fm-send-refuse-blocked.test.sh - regression for task
# fm-send-refuse-blocked-w2 (F2 in data/fm-herdr-friction-s1/report.md): a
# steer sent to a herdr pane natively parked on an interactive dialog (a
# permission prompt, a trust dialog, or an AskUserQuestion menu) must be
# refused BEFORE anything is typed - never answered by pressing Enter into
# the dialog's highlighted option.
#
# Contract under test, stated once in bin/fm-send.sh's header (this file
# asserts against that header's own wording, not implementation detail):
#   - a blocked target sends no text and no Enter
#   - fm-send exits non-zero
#   - fm-send prints one typed `error:` line naming the parked dialog
#   - --verify prints `verify: blocked <target> is parked on an interactive
#     dialog; refused before typing or pressing Enter`
#   - the refusal is capability-gated: only herdr can prove it; every other
#     backend keeps its current behavior (never a silent `landed`)
#
# Companion coverage lives elsewhere, not duplicated here (one-owner rule):
#   - the real dialog lab e2e (force a trust prompt, steer it, assert the
#     dialog is still unanswered) is
#     tests/fm-send-refuse-blocked-e2e.test.sh
#   - "a healthy busy pane still accepts a queued steer" is
#     tests/fm-herdr-submit-busy.test.sh's
#     test_fm_send_queued_verdict_exits_zero_with_note, re-verified passing
#     with this task's change in place (it exercises the real fm-send.sh
#     script, so it also exercises the new pre-submit blocked check)
#
# Follows tests/fm-backend-herdr.test.sh's fake-CLI conventions: a small
# LOG-based, canned-response fake `herdr` + real jq. Every response file is
# consumed IN ORDER (call 1 reads 1.out, ...), status --json is answered
# inline, and a missing response file means "succeed with empty stdout".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-send-refuse-blocked-tests)
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0
export FM_BACKEND_HERDR_SUBMIT_POLLS=1

# make_herdr_fakebin: identical convention to tests/fm-herdr-submit-busy.test.sh.
make_herdr_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# --- unit level: fm_backend_herdr_target_blocked / fm_backend_target_blocked

test_target_blocked_true_on_native_blocked() {
  local dir log resp fb out
  dir="$TMP_ROOT/predicate-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  if ! PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_target_blocked default:w1:p2' "$ROOT"; then
    fail "fm_backend_herdr_target_blocked must return 0 (true) when agent_status reads blocked"
  fi
  pass "fm_backend_herdr_target_blocked: true on a native blocked agent_status"
}

test_target_blocked_false_on_idle_and_working() {
  local dir log resp fb
  dir="$TMP_ROOT/predicate-idle"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  if PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_target_blocked default:w1:p2' "$ROOT"; then
    fail "fm_backend_herdr_target_blocked must return 1 (false) on idle - never widen a refusal beyond a positive blocked read"
  fi

  dir="$TMP_ROOT/predicate-working"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  if PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_target_blocked default:w1:p2' "$ROOT"; then
    fail "fm_backend_herdr_target_blocked must return 1 (false) on working - never widen a refusal beyond a positive blocked read"
  fi
  pass "fm_backend_herdr_target_blocked: false (never widens) on idle and working"
}

test_target_blocked_false_on_unreadable_target() {
  local dir log resp fb
  dir="$TMP_ROOT/predicate-unreadable"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  if PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_target_blocked default:w1:p2' "$ROOT"; then
    fail "fm_backend_herdr_target_blocked must return 1 (false) on an unreadable target - a read failure never proves blocked"
  fi
  pass "fm_backend_herdr_target_blocked: false (fail-safe) on an unreadable target"
}

test_dispatcher_capability_gated_to_herdr() {
  local dir log
  dir="$TMP_ROOT/dispatcher-tmux"; mkdir -p "$dir"; log="$dir/log"
  if bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_blocked tmux default:w1' "$ROOT" 2>"$log"; then
    fail "fm_backend_target_blocked must report 1 (not blocked) for a backend with no native blocked concept"
  fi
  pass "fm_backend_target_blocked: capability-gated - a backend with no native blocked state always reports not-blocked"
}

# --- fm-send.sh end to end: the refusal contract, asserted from the header --

test_fm_send_refuses_blocked_no_text_no_enter() {
  local dir state neutral log resp fb out err rc
  dir="$TMP_ROOT/fm-send-blocked"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; err="$dir/stderr"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/herdr-blocked.meta" "window=default:w1:p2" "backend=herdr"
  touch "$state/.last-watcher-beat"
  # 1: fm-send-refuse-dead-w1's pre-submit agent-registry check - pane_id
  #    round-trips, proving the pane structurally exists
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/1.out"
  # 2: same check's agent read - "blocked" is a registered (alive) agent, so
  #    the registration check passes through to this w2 predicate
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/2.out"
  # 3: fm-send's own pre-submit blocked check (this task, w2) - blocked
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" default:w1:p2 "please pick blue" 2>"$err" )
  rc=$?
  expect_code 1 "$rc" "fm-send must exit non-zero when the target is natively parked on a dialog"
  assert_contains "$(cat "$err")" "parked on an interactive dialog" "fm-send must name the parked dialog in its error"
  assert_contains "$(cat "$err")" "no text or Enter sent" "fm-send must state that no text or Enter was sent"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-text' "$log")" -eq 0 ] \
    || fail "a blocked target must never receive typed text: $(cat "$log")"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-keys' "$log")" -eq 0 ] \
    || fail "a blocked target must never receive Enter (or any key): $(cat "$log")"
  pass "fm-send: a natively blocked target is refused with no text and no Enter sent, exit non-zero"
}

test_fm_send_verify_reports_blocked() {
  local dir state neutral log resp fb out err rc
  dir="$TMP_ROOT/fm-send-blocked-verify"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; err="$dir/stderr"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/herdr-blocked.meta" "window=default:w1:p2" "backend=herdr"
  touch "$state/.last-watcher-beat"
  # See test_fm_send_refuses_blocked_no_text_no_enter for why this is 3 calls
  # deep: fm-send-refuse-dead-w1's pre-submit agent-registry check (calls 1-2)
  # runs before this task's own blocked check (call 3).
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" --verify default:w1:p2 "please pick blue" 2>"$err" )
  rc=$?
  expect_code 1 "$rc" "fm-send --verify must exit non-zero on a blocked refusal"
  [ "$out" = "verify: blocked default:w1:p2 is parked on an interactive dialog; refused before typing or pressing Enter" ] \
    || fail "unexpected --verify output for a blocked refusal: '$out'"
  pass "fm-send --verify: a blocked refusal prints the documented verify: blocked line and exits non-zero"
}

# healthy idle pane: unaffected regression coverage for the new pre-submit
# check (busy/queued coverage lives in tests/fm-herdr-submit-busy.test.sh, see
# header).
test_fm_send_idle_pane_still_delivers() {
  local dir state neutral log resp fb out err rc
  dir="$TMP_ROOT/fm-send-idle-ok"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; err="$dir/stderr"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/herdr-idle.meta" "window=default:w1:p2" "backend=herdr"
  touch "$state/.last-watcher-beat"
  # 1: fm-send-refuse-dead-w1's pre-submit agent-registry check - pane_id
  #    round-trips, proving the pane structurally exists
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/1.out"
  # 2: same check's agent read - idle is a registered (alive) agent
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  # 3: fm-send's own pre-submit blocked check (this task, w2) - not blocked
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/3.out"
  # 4: send-text (literal, no output)
  # 5: agent get - pre-Enter baseline is idle
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  # 6: send-keys enter
  # 7: agent get - agent_status working (a real turn started: submitted)
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=3 FM_SEND_SLEEP=0.01 FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" default:w1:p2 "hello captain" 2>"$err" )
  rc=$?
  expect_code 0 "$rc" "fm-send must still deliver normally to a healthy idle (not blocked) pane"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-text'$'\x1f''w1:p2'$'\x1f''hello captain' \
    "fm-send did not type the literal text to a healthy idle pane"
  [ "$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")" -eq 1 ] \
    || fail "fm-send should submit with exactly one Enter for a healthy idle pane"
  pass "fm-send: a healthy idle (not blocked) pane still delivers normally, unaffected by the new pre-submit check"
}

test_target_blocked_true_on_native_blocked
test_target_blocked_false_on_idle_and_working
test_target_blocked_false_on_unreadable_target
test_dispatcher_capability_gated_to_herdr
test_fm_send_refuses_blocked_no_text_no_enter
test_fm_send_verify_reports_blocked
test_fm_send_idle_pane_still_delivers
