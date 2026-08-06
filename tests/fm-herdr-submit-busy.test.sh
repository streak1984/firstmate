#!/usr/bin/env bash
# tests/fm-herdr-submit-busy.test.sh - regression: the herdr submit path's
# busy-queue fallback (2026-08-05 incident: a pi/deepseek worker mid-turn
# queues every fm-send as a "Steering:" entry and picks it up at turn end, but
# fm-send exited 1 with "delivery unconfirmed; verdict=unknown" every time, and
# three concurrent blind retry loops queued ~30 duplicate messages into an
# active validation run).
#
# Quadrant contract (mirrors tests/fm-tmux-submit-busy.test.sh's coverage of
# the tmux adapter's fm_pane_is_busy fallback):
#   busy + queued evidence  -> verdict `queued` (fm-send exits 0 with a
#                              "queued (busy pane)" note, never re-sends)
#   busy + absent evidence  -> verdict `pending` (true negative preserved)
#   idle + pending          -> verdict `pending` (genuine swallow)
#   idle + cleared          -> verdict `empty` (normal confirmation)
# Plus the 2026-08-05 OPPOSITE direction: a busy pi whose Enter hit the
# bash-running warning retains the typed text in the editor with NO Steering
# row - that send did NOT land and must keep failing (retained text is only
# queue evidence for a positively non-Pi harness, the opencode 1.18.4 shape
# the tmux adapter verifies).
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

TMP_ROOT=$(fm_test_tmproot fm-herdr-submit-busy-tests)
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0
export FM_BACKEND_HERDR_SUBMIT_POLLS=1

# make_herdr_fakebin: `herdr` stub that logs every invocation (one line,
# unit-separated args, to $FM_HERDR_LOG) and returns the canned response for
# that call from $FM_HERDR_RESPONSES/<n>.out, consumed in order. status --json
# is answered inline (the real CLI is session-independent for client info).
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

# --- canned pane captures ---------------------------------------------------
# A WORKING pi pane: the editor separator pair with an empty editor, no
# Steering row. fm_backend_herdr_composer_state must read unknown for it (the
# working-Pi identity gate), never pending/empty.
write_pi_busy_capture() {  # <file>
  local file=$1 sep
  sep=$(printf '\xe2\x94\x80%.0s' {1..29})
  printf '  Working on your request...\n%s\n%s\n' "$sep" "$sep" > "$file"
}

# A WORKING pi pane with an accepted-and-queued Enter: pi renders the queue
# entry as a dim "Steering: <text>" row above the composer (verified from
# pi's own interactive-mode source; the dim styling is included to prove the
# structural scan survives it).
write_pi_queued_capture() {  # <file>
  local file=$1 sep
  sep=$(printf '\xe2\x94\x80%.0s' {1..29})
  {
    printf '\x1b[2mSteering: fix the validation run\x1b[0m\n'
    printf '\x1b[2m\xe2\x86\xb3 \xe2\x87\xa7\xe2\x8c\x98X to edit all queued messages\x1b[0m\n'
    printf '%s\n%s\n' "$sep" "$sep"
  } > "$file"
}

# A WORKING pi pane whose Enter hit the bash-running warning: the typed text
# is RETAINED in the editor (pi shows a warning and re-sets the editor text)
# and NO Steering row exists - the 2026-08-05 "had NOT landed" direction.
write_pi_retained_capture() {  # <file>
  local file=$1 sep
  sep=$(printf '\xe2\x94\x80%.0s' {1..29})
  {
    printf '%s\n' "$sep"
    printf '  ! cat bigfile.log\n'
    printf '%s\n' "$sep"
  } > "$file"
}

# A busy opencode pane with the Enter accepted-and-queued text still visible
# in a bordered composer (the tmux-verified 1.18.4 busy-queue shape).
write_opencode_pending_capture() {  # <file>
  local file=$1 dash
  dash=$(printf '\xe2\x94\x80%.0s' {1..27})
  printf '\xe2\x94\x8c%s\xe2\x94\x90\n' "$dash" > "$file"
  printf '\xe2\x94\x82 > fix the validation run \xe2\x94\x82\n' >> "$file"
  printf '\xe2\x94\xb0%s\xe2\x94\xaf\n' "$dash" >> "$file"
}

# --- quadrant tests ---------------------------------------------------------

# busy + queued: a working pi whose composer shows the Steering queue entry
# must report `queued` after spending the full Enter budget, so fm-send does
# not re-send (the duplicate-steering incident).
test_busy_pi_queued_steering_row_returns_queued() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/busy-pi-queued"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/2.out"
  write_pi_busy_capture "$resp/4.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/6.out"
  write_pi_busy_capture "$resp/8.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/9.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/10.out"
  write_pi_busy_capture "$resp/12.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/13.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/14.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/15.out"
  write_pi_queued_capture "$resp/16.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "steer me now" 3 0.01 0.01' "$ROOT" )
  [ "$out" = queued ] || fail "busy pi with a Steering queue entry should report queued, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 3 ] || fail "busy-pi unknown composer should consume the full Enter retry budget before the fallback, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: busy pi + Steering queue entry returns queued (accepted for turn end) after the full retry budget"
}

# busy + absent: a working pi whose composer shows neither the sent text nor
# a Steering row must keep failing (true negative never promoted).
test_busy_pi_absent_returns_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-pi-absent"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/2.out"
  write_pi_busy_capture "$resp/4.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/6.out"
  write_pi_busy_capture "$resp/8.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/9.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/10.out"
  write_pi_busy_capture "$resp/12.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/13.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/14.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/15.out"
  write_pi_busy_capture "$resp/16.out"
  write_pi_busy_capture "$resp/17.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/18.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "steer me now" 3 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "busy pi without queue evidence must keep reporting pending, got '$out'"
  pass "fm_backend_herdr_send_text_submit: busy pi + no queue evidence stays pending (true negative preserved)"
}

# The OPPOSITE direction of the 2026-08-05 incident: the send that reported
# unconfirmed had NOT landed - its Enter hit pi's bash-running warning, which
# retains the typed text in the editor and renders NO Steering row. Retained
# text is NOT queue evidence for pi (pi clears the editor when it queues), so
# this must keep failing.
test_busy_pi_retained_text_returns_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-pi-retained"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/2.out"
  write_pi_retained_capture "$resp/4.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/6.out"
  write_pi_retained_capture "$resp/8.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/9.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/10.out"
  write_pi_retained_capture "$resp/12.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/13.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/14.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/15.out"
  write_pi_retained_capture "$resp/16.out"
  write_pi_retained_capture "$resp/17.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/18.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "steer me now" 3 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "a busy pi with retained editor text but no Steering row must NOT be promoted to queued, got '$out'"
  pass "fm_backend_herdr_send_text_submit: busy pi + retained text without a Steering row stays pending (the not-landed direction never promoted)"
}

# busy + retained text on a positively non-Pi harness (opencode 1.18.4): the
# tmux-verified busy-queue shape - Enter accepted while busy, text kept
# visible - reports queued, mirroring fm_tmux_submit_enter_core's busy fallback.
test_busy_nonpi_retained_text_returns_queued() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/busy-opencode-queued"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent":"opencode","agent_status":"working"}}}\n' > "$resp/2.out"
  write_opencode_pending_capture "$resp/4.out"
  write_opencode_pending_capture "$resp/6.out"
  write_opencode_pending_capture "$resp/8.out"
  printf '{"result":{"agent":{"agent":"opencode","agent_status":"working"}}}\n' > "$resp/9.out"
  write_opencode_pending_capture "$resp/10.out"
  write_opencode_pending_capture "$resp/11.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "steer me now" 3 0.01 0.01' "$ROOT" )
  [ "$out" = queued ] || fail "a busy non-pi composer holding real typed text should report queued (opencode busy-queue shape), got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 3 ] || fail "busy non-pi pending composer should consume the full Enter retry budget before the fallback, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: busy non-pi + retained composer text returns queued (mirrors the tmux busy fallback)"
}

# idle + cleared: an idle baseline whose Enter starts a turn confirms with
# `empty` exactly as before - the fallback never weakens the normal path.
test_idle_pane_cleared_returns_empty() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/idle-cleared"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "steer me now" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "an idle pane whose Enter starts a turn should still report empty, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "an idle-baseline confirm must not consume extra Enters, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: idle pane + cleared composer returns empty (normal confirmation unchanged)"
}

# idle + pending: an idle pane whose Enters never start a turn is a genuine
# swallow - the fallback's busy check fails, so pending is preserved.
test_idle_pane_pending_returns_pending() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/idle-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/8.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/9.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "steer me now" 3 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "an idle pane whose Enter never starts a turn must keep reporting pending, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 3 ] || fail "a swallowed idle submit should consume the full Enter retry budget, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: idle pane + pending stays pending (genuine swallow preserved)"
}

# fm-send end to end: the `queued` verdict must exit 0 with an explicit
# "queued (busy pane)" note (the deliverable's caller-facing contract), and
# the busy+absent direction must still exit non-zero with the loud
# unconfirmed error.
test_fm_send_queued_verdict_exits_zero_with_note() {
  local dir state neutral log resp fb out err rc
  dir="$TMP_ROOT/fm-send-queued"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; err="$dir/stderr"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/herdr-busy.meta" "window=default:w1:p2" "backend=herdr"
  touch "$state/.last-watcher-beat"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/2.out"
  write_pi_busy_capture "$resp/4.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/7.out"
  write_pi_queued_capture "$resp/8.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" default:w1:p2 "steer me now" 2>"$err" )
  rc=$?
  expect_code 0 "$rc" "fm-send with a queued verdict must exit 0"
  assert_contains "$(cat "$err")" "queued (busy pane)" "fm-send must print the explicit queued (busy pane) note"
  pass "fm-send: a busy-pane queued verdict exits 0 with the explicit queued (busy pane) note"
}

test_fm_send_busy_absent_still_fails_loud() {
  local dir state neutral log resp fb out err rc
  dir="$TMP_ROOT/fm-send-absent"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; err="$dir/stderr"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/herdr-busy.meta" "window=default:w1:p2" "backend=herdr"
  touch "$state/.last-watcher-beat"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/2.out"
  write_pi_busy_capture "$resp/4.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/7.out"
  write_pi_busy_capture "$resp/8.out"
  write_pi_busy_capture "$resp/9.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/10.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" default:w1:p2 "steer me now" 2>"$err" )
  rc=$?
  expect_code 1 "$rc" "fm-send with a busy pane lacking queue evidence must exit non-zero"
  assert_contains "$(cat "$err")" "delivery unconfirmed" "fm-send must keep the loud refusal for the busy-absent direction"
  pass "fm-send: busy pane without queue evidence still exits non-zero with delivery unconfirmed"
}

test_busy_pi_queued_steering_row_returns_queued
test_busy_pi_absent_returns_pending
test_busy_pi_retained_text_returns_pending
test_busy_nonpi_retained_text_returns_queued
test_idle_pane_cleared_returns_empty
test_idle_pane_pending_returns_pending
test_fm_send_queued_verdict_exits_zero_with_note
test_fm_send_busy_absent_still_fails_loud
