#!/usr/bin/env bash
# tests/fm-send-refuse-dead-agent.test.sh - the pre-send agent-registry
# refusal fm-send.sh's own header documents (data/fm-herdr-friction-s1/
# report.md finding F1, work item W1): before typing any message text,
# fm-send requires positive evidence that a registered agent owns the
# target on a backend that can prove agent registration
# (bin/fm-busy-lib.sh's fm_busy_agent_proof_capable). A `dead` verdict from
# fm_backend_agent_alive refuses with a typed error and sends nothing at
# all; an unreadable/ambiguous verdict never blocks a healthy delivery, and
# a backend that cannot prove agent registration (tmux) is unaffected.
#
# Every assertion below is pinned to the exact wording fm-send.sh's own
# "Pre-send agent-registry refusal" header paragraph documents, so a future
# edit that changes the contract's wording without updating this test fails
# loudly instead of silently drifting.
#
# This check runs FIRST of fm-send.sh's two pre-send refusals, ahead of
# fm-send-refuse-blocked-w2's own native-blocked-dialog check (a676e9c) - see
# that call site's inline comment for why. The fixtures below that reach past
# this check to a real delivery (unreadable/alive/busy-queued) therefore also
# feed one well-formed "not blocked" agent-status response for the w2 check's
# own herdr call, which sits between this check and the submit core; a
# fixture that only asserts THIS refusal (test_dead_agent_refuses_before_typing)
# never reaches the w2 check at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-refuse-dead-agent)

# make_herdr_fakebin: a `herdr` stub that logs every invocation (one line,
# unit-separated args, to $FM_HERDR_LOG) and returns the canned response for
# that call from $FM_HERDR_RESPONSES/<n>.out, consumed in order. status --json
# is answered inline and never consumes a numbered slot. Follows
# tests/fm-herdr-submit-busy.test.sh's fake-CLI conventions.
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

# A WORKING pi pane: the editor separator pair with an empty editor, no
# Steering row (tests/fm-herdr-submit-busy.test.sh's canned capture, reused
# verbatim so the busy-queued fixture below exercises the real shape).
write_pi_busy_capture() {  # <file>
  local file=$1 sep
  sep=$(printf '\xe2\x94\x80%.0s' {1..29})
  printf '  Working on your request...\n%s\n%s\n' "$sep" "$sep" > "$file"
}

# A WORKING pi pane with an accepted-and-queued Enter: the dim "Steering:
# <text>" row fm_backend_herdr_submit_queue_evidence's regex scan matches.
write_pi_queued_capture() {  # <file>
  local file=$1 sep
  sep=$(printf '\xe2\x94\x80%.0s' {1..29})
  {
    printf '\x1b[2mSteering: fix the validation run\x1b[0m\n'
    printf '\x1b[2m\xe2\x86\xb3 \xe2\x87\xa7\xe2\x8c\x98X to edit all queued messages\x1b[0m\n'
    printf '%s\n%s\n' "$sep" "$sep"
  } > "$file"
}

# --- herdr: capability-gated refusal ----------------------------------------

# A confirmed agent-less pane (pane_get echoes the pane id, then agent_get
# answers agent_not_found -> fm_backend_agent_alive prints "dead") must be
# refused before ANY text is typed or Enter is pressed - the exact husk-pane
# execution hazard finding F1 proved live.
test_dead_agent_refuses_before_typing() {
  local dir state resp log neutral out rc
  dir="$TMP_ROOT/dead"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  neutral="$dir/neutral"; mkdir -p "$neutral"
  fm_write_meta "$state/husk.meta" "window=default:w1:p2" "backend=herdr" "harness=claude"
  touch "$state/.last-watcher-beat"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/1.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" --verify husk "touch /tmp/should-not-exist" 2>&1 )
  rc=$?
  expect_code 1 "$rc" "a confirmed dead-agent target must refuse and exit non-zero"
  assert_contains "$out" "refusing to send to default:w1:p2" "the refusal must name the target"
  assert_contains "$out" "no registered agent for this pane" "the refusal must name the reason (header: no registered agent)"
  assert_contains "$out" "verify: unknown refused before send - no agent registered for target" \
    "the --verify line must match the header's documented pre-send refusal wording exactly"
  if grep -q $'\x1f''pane'$'\x1f''send-text' "$log"; then
    fail "a dead-agent target must never receive typed text"$'\n'"$(cat "$log")"
  fi
  if grep -q $'\x1f''pane'$'\x1f''send-keys' "$log"; then
    fail "a dead-agent target must never receive Enter"$'\n'"$(cat "$log")"
  fi
  pass "fm-send: a confirmed dead herdr agent is refused before any text or Enter is sent"
}

# --- herdr: fail-safe direction (never block on an inconclusive answer) ----

# An unreadable/ambiguous registry answer (here: pane_get succeeds but its
# echoed pane_id does not round-trip, the documented "misread response
# shape" fail-safe in fm_backend_herdr_pane_agent_state) must never block a
# delivery a healthy worker would otherwise receive.
test_unreadable_registry_answer_still_delivers() {
  local dir state resp log neutral out rc
  dir="$TMP_ROOT/unreadable"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  neutral="$dir/neutral"; mkdir -p "$neutral"
  fm_write_meta "$state/husk.meta" "window=default:w1:p2" "backend=herdr" "harness=claude"
  touch "$state/.last-watcher-beat"
  printf '{"result":{"weird":true}}\n' > "$resp/1.out"
  # 2: fm-send-refuse-blocked-w2's own pre-submit blocked check - not blocked
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" husk "hello worker" 2>&1 )
  rc=$?
  expect_code 0 "$rc" "an unreadable registry answer must never block a healthy delivery"$'\n'"$out"
  if ! grep -q $'\x1f''pane'$'\x1f''send-text' "$log"; then
    fail "the message should still have been typed"$'\n'"$(cat "$log")"
  fi
  pass "fm-send: an unreadable herdr agent-registry answer never blocks delivery (fail-safe direction)"
}

# --- herdr: a genuinely alive agent is unaffected ---------------------------

# A well-formed alive verdict (pane_get round-trips, agent_get reports a
# real status) must deliver exactly as it did before this refusal existed.
test_healthy_alive_agent_still_delivers() {
  local dir state resp log neutral out rc
  dir="$TMP_ROOT/alive"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  neutral="$dir/neutral"; mkdir -p "$neutral"
  fm_write_meta "$state/husk.meta" "window=default:w1:p2" "backend=herdr" "harness=claude"
  touch "$state/.last-watcher-beat"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  # 3: fm-send-refuse-blocked-w2's own pre-submit blocked check - not blocked
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" husk "hello worker" 2>&1 )
  rc=$?
  expect_code 0 "$rc" "a confirmed alive agent must deliver normally"$'\n'"$out"
  if ! grep -q $'\x1f''pane'$'\x1f''send-text' "$log"; then
    fail "the message should have been typed to the live agent"$'\n'"$(cat "$log")"
  fi
  pass "fm-send: a confirmed alive herdr agent still delivers normally"
}

# A busy pane the pre-send check confirms alive must still reach the
# busy-queue fallback unchanged (the 2026-08-05 duplicate-steer incident's
# fix), proving the new refusal composes with the existing busy/queued path
# instead of weakening it.
test_healthy_busy_queued_path_still_delivers() {
  local dir state resp log neutral out err rc
  dir="$TMP_ROOT/alive-queued"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; err="$dir/err"; : > "$log"
  neutral="$dir/neutral"; mkdir -p "$neutral"
  fm_write_meta "$state/husk.meta" "window=default:w1:p2" "backend=herdr" "harness=pi"
  touch "$state/.last-watcher-beat"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/2.out"
  # 3: fm-send-refuse-blocked-w2's own pre-submit blocked check - not blocked
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/5.out"
  write_pi_busy_capture "$resp/7.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/8.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/9.out"
  printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n' > "$resp/10.out"
  write_pi_queued_capture "$resp/11.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" husk "steer me now" 2>"$err" )
  rc=$?
  expect_code 0 "$rc" "an alive-but-busy pane whose pane shows queue evidence must still exit 0"$'\n'"$(cat "$err")"
  assert_contains "$(cat "$err")" "queued (busy pane)" \
    "the busy-queue fallback note must still print unchanged"
  pass "fm-send: the pre-send refusal composes with the busy-queued fallback unchanged"
}

# --- tmux: the capability gate is a true no-op ------------------------------

# tmux cannot prove agent registration off a real registry
# (fm_busy_agent_proof_capable), so the pre-send check must never even
# attempt an agent-registry read for it - a healthy tmux send is byte-for-
# byte the same as before this refusal existed.
test_tmux_backend_unaffected_by_capability_gate() {
  local dir fb home err log rc
  dir="$TMP_ROOT/tmux-healthy"; mkdir -p "$dir"
  home="$dir/home"; mkdir -p "$home/state"
  fb="$dir/fakebin"; mkdir -p "$fb"
  log="$dir/tmux.log"; err="$dir/send.err"; : > "$log"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship" "backend=tmux"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"
  rc=$?
  expect_code 0 "$rc" "a healthy tmux send must be unaffected by the herdr-only capability gate"$'\n'"$(cat "$err")"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "tmux send should still type the literal text"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "tmux send should still submit with Enter"
  pass "fm-send: the pre-send refusal never engages for tmux (capability gate is a true no-op)"
}

test_dead_agent_refuses_before_typing
test_unreadable_registry_answer_still_delivers
test_healthy_alive_agent_still_delivers
test_healthy_busy_queued_path_still_delivers
test_tmux_backend_unaffected_by_capability_gate
