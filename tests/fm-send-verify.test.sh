#!/usr/bin/env bash
# fm-send --verify post-send classification.
#
# The plain send exit code is unreliable in both directions: it has reported
# success with the text left unsubmitted, and reported "delivery unconfirmed"
# while a busy pane had correctly queued the message. --verify therefore
# classifies what happened after the send path completes - landed, queued, or
# dropped - from the composer state, the pane's busy state, and a plain pane
# capture, and exits nonzero only for dropped.
#
# These tests are fixture/stub-driven, extending the style of
# tests/fm-tmux-submit-busy.test.sh (lib-level, stubbed backend reads) and
# tests/fm-send-settle.test.sh (end-to-end through fm-send.sh with a fake
# tmux):
#   1. landed with the message wrapped across lines (word-boundary wrap).
#   2. landed with a hard wrap in the middle of a long token (URL split).
#   3. landed with ANSI escapes and composer box borders around the echo.
#   4. queued on a busy pane whose composer holds the text (tmux busy-queue).
#   5. queued from herdr's native "Steering:" queue-entry evidence.
#   6. dropped with the text stuck in the composer on an idle pane.
#   7. dropped with the text vanished on an idle pane.
#   8. unknown backend reported honestly with exit 0.
#   9. unreadable composer states and busy panes without evidence never guess.
#  10. real-pane shapes with submit-verdict evidence: a working pi pane whose
#      composer read is refused is landed on a confirmed submit; a busy pane
#      without a matchable echo is landed on a confirmed submit; a confirmed
#      submit on an idle pane without an echo stays unknown (never a false
#      dropped); the submit core's queued proof survives queue-entry scroll;
#      the invisible U+2063 marker never breaks the echo match.
#  11. default mode (no --verify) output unchanged.
#  12. CLI end-to-end: landed exits 0; the unconfirmed-submit path prints its
#      verify line (dropped exits 1, queued proof rescues to exit 0); a
#      transport send failure prints its verify line; queued exits 0.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-send-verify-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-verify)
# fm_test_tmproot's EXIT trap fires inside the command substitution subshell
# and deletes the fresh root there, so the returned name needs recreating
# (the same convention fm-send-strict.test.sh relies on).
mkdir -p "$TMP_ROOT"

# --- lib-level stubs --------------------------------------------------------
#
# The classifier dispatches through these named seams; redefining them here
# drives every verdict without any real tmux/herdr. State comes from env vars,
# and results are written to files (never nested $()) so the bash
# prefix-assignment + command-substitution environment gap cannot bite.

stub_backend_reads() {
  # shellcheck disable=SC2317 # invoked by the classifier under test
  fm_backend_source() { return 0; }
  # shellcheck disable=SC2317
  fm_backend_composer_state() { printf '%s' "${FM_STUB_COMPOSER:-unknown}"; }
  # shellcheck disable=SC2317
  fm_backend_capture() { printf '%s' "${FM_STUB_CAPTURE:-}"; }
  # shellcheck disable=SC2317
  fm_backend_busy_state() { printf '%s' "${FM_STUB_BUSY:-unknown}"; }
  # shellcheck disable=SC2317
  fm_pane_is_busy() { [ "${FM_STUB_TMUX_BUSY:-0}" = 1 ]; }
  # shellcheck disable=SC2317
  fm_backend_herdr_submit_queue_evidence() { printf '%s' "${FM_STUB_EVIDENCE:-absent}"; }
}

classify_to() {  # <out-file> <backend> <message> [name=value...]
  local out=$1 backend=$2 message=$3 a name value
  shift 3
  # Assign the stub state into the current shell (not exported): the stubs are
  # functions, so plain shell variables reach them and their subshells, and
  # `env` could not invoke a function anyway. printf -v keeps the dynamic
  # name shellcheck-clean without eval. FM_STUB_SUBMIT feeds the optional
  # submit-verdict evidence argument; unset preserves the read-only
  # classification the pre-submit-evidence tests assert.
  FM_STUB_SUBMIT=
  for a in "$@"; do
    name=${a%%=*}
    value=${a#*=}
    printf -v "$name" '%s' "$value"
  done
  fm_send_verify_classify "$backend" win "" "$message" "" "$FM_STUB_SUBMIT" > "$out" 2>/dev/null
  rc=$?
  [ "$rc" = 0 ] || fail "classify exited $rc"
}

test_landed_wrapped_at_word_boundary() {
  local out
  out="$TMP_ROOT/landed-word-wrap"
  classify_to "$out" tmux "steer: please fix the build now" \
    FM_STUB_COMPOSER=empty FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE=$'steer: please fix the build\nnow'
  [ "$(cat "$out")" = "landed composer cleared and message echoed in the pane capture" ] \
    || fail "wrapped-at-word-boundary message should be landed, got '$(cat "$out")'"
  pass "fm-send-verify: landed when the echo wraps at a word boundary"
}

test_landed_hard_wrap_mid_token() {
  local out
  out="$TMP_ROOT/landed-mid-token"
  classify_to "$out" tmux "run https://example.com/very/long/path please" \
    FM_STUB_COMPOSER=empty FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE=$'run https://example.com/very/lo\nng/path please'
  [ "$(cat "$out")" = "landed composer cleared and message echoed in the pane capture" ] \
    || fail "mid-token hard wrap should fall back to the whitespace-free match, got '$(cat "$out")'"
  pass "fm-send-verify: landed when a long token is hard-wrapped mid-word"
}

test_landed_bordered_ansi_capture() {
  local out
  out="$TMP_ROOT/landed-bordered"
  classify_to "$out" tmux "fix the build" \
    FM_STUB_COMPOSER=empty FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE=$'\033[0m│ fix the build      │\n│ (bordered echo)   │'
  [ "$(cat "$out")" = "landed composer cleared and message echoed in the pane capture" ] \
    || fail "bordered ANSI echo should be landed after normalization, got '$(cat "$out")'"
  pass "fm-send-verify: landed when the echo carries ANSI escapes and box borders"
}

test_queued_busy_pane_pending_composer() {
  local out
  out="$TMP_ROOT/queued-busy"
  classify_to "$out" tmux "fix build" \
    FM_STUB_COMPOSER=pending FM_STUB_TMUX_BUSY=1 \
    FM_STUB_CAPTURE='Working...'
  [ "$(cat "$out")" = "queued busy pane accepted the message for delivery at turn end" ] \
    || fail "pending composer on a busy pane should be queued, got '$(cat "$out")'"
  pass "fm-send-verify: queued when a busy pane holds the text (busy-queue shape)"
}

test_queued_herdr_steering_evidence() {
  local out
  out="$TMP_ROOT/queued-herdr-steering"
  classify_to "$out" herdr "fix build" \
    FM_STUB_COMPOSER=unknown FM_STUB_BUSY=busy FM_STUB_EVIDENCE=queued \
    FM_STUB_CAPTURE='Steering: fix build'
  [ "$(cat "$out")" = "queued busy pane shows an accepted queue entry" ] \
    || fail "herdr Steering queue entry on a busy pane should be queued, got '$(cat "$out")'"
  pass "fm-send-verify: queued from herdr's native queue-entry evidence"
}

test_dropped_text_stuck_in_composer() {
  local out
  out="$TMP_ROOT/dropped-stuck"
  classify_to "$out" tmux "fix build" \
    FM_STUB_COMPOSER=pending FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE='idle pane text'
  [ "$(cat "$out")" = "dropped composer still holds the message on an idle pane" ] \
    || fail "pending composer on an idle pane should be dropped, got '$(cat "$out")'"
  pass "fm-send-verify: dropped when the composer still holds the text on an idle pane"
}

test_dropped_text_vanished_idle_pane() {
  local out
  out="$TMP_ROOT/dropped-vanished"
  classify_to "$out" tmux "hello captain" \
    FM_STUB_COMPOSER=empty FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE='only unrelated transcript text'
  [ "$(cat "$out")" = "dropped message found nowhere on an idle pane" ] \
    || fail "empty composer with the text nowhere on an idle pane should be dropped, got '$(cat "$out")'"
  pass "fm-send-verify: dropped when the text vanished on an idle pane"
}

test_unknown_backend_reports_honestly() {
  local out rc
  out="$TMP_ROOT/unknown-backend-zellij"
  fm_send_verify_classify zellij win "" "hello" > "$out" 2>/dev/null
  rc=$?
  [ "$rc" = 0 ] || fail "unknown backend must exit 0, got $rc"
  [ "$(cat "$out")" = "unknown backend zellij has no composer-state owner" ] \
    || fail "zellij should report no composer-state owner, got '$(cat "$out")'"
  out="$TMP_ROOT/unknown-backend-orca"
  fm_send_verify_classify orca win "" "hello" > "$out" 2>/dev/null
  rc=$?
  [ "$rc" = 0 ] || fail "unknown backend must exit 0, got $rc"
  [ "$(cat "$out")" = "unknown backend orca has no busy-state source to separate queued from dropped" ] \
    || fail "orca should report the missing busy-state source, got '$(cat "$out")'"
  pass "fm-send-verify: backends without the verification chain report unknown with exit 0"
}

test_unreadable_composer_never_guesses() {
  local out
  out="$TMP_ROOT/unknown-composer"
  classify_to "$out" tmux "hello captain" \
    FM_STUB_COMPOSER=unknown FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE='hello captain'
  [ "$(cat "$out")" = "unknown composer state unreadable" ] \
    || fail "an unreadable composer must stay unknown even with text in the capture, got '$(cat "$out")'"
  pass "fm-send-verify: an unreadable composer is never promoted to landed"
}

test_busy_pane_without_echo_is_unknown_not_dropped() {
  local out
  out="$TMP_ROOT/unknown-busy-no-echo"
  classify_to "$out" tmux "hello captain" \
    FM_STUB_COMPOSER=empty FM_STUB_TMUX_BUSY=1 \
    FM_STUB_CAPTURE='Working...'
  [ "$(cat "$out")" = "unknown composer empty but message not echoed while the pane is busy" ] \
    || fail "empty composer without an echo on a busy pane must stay unknown, got '$(cat "$out")'"
  pass "fm-send-verify: a busy pane without the echo is unknown, never dropped"
}

test_herdr_busy_without_evidence_is_unknown() {
  local out
  out="$TMP_ROOT/unknown-herdr-no-evidence"
  classify_to "$out" herdr "hello captain" \
    FM_STUB_COMPOSER=unknown FM_STUB_BUSY=busy FM_STUB_EVIDENCE=absent \
    FM_STUB_CAPTURE='Working...'
  [ "$(cat "$out")" = "unknown busy pane without queue evidence" ] \
    || fail "a busy herdr pane without queue evidence must stay unknown, got '$(cat "$out")'"
  pass "fm-send-verify: a busy herdr pane without queue evidence is never promoted"
}

test_pending_unproven_never_promoted_to_queued() {
  local out
  out="$TMP_ROOT/unproven-busy"
  classify_to "$out" tmux "fix" \
    FM_STUB_COMPOSER=pending-unproven FM_STUB_TMUX_BUSY=1 \
    FM_STUB_CAPTURE='Working...'
  [ "$(cat "$out")" = "unknown ambiguous composer text on a busy pane" ] \
    || fail "pending-unproven on a busy pane must not be promoted to queued, got '$(cat "$out")'"
  out="$TMP_ROOT/unproven-idle"
  classify_to "$out" tmux "fix" \
    FM_STUB_COMPOSER=pending-unproven FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE='idle'
  [ "$(cat "$out")" = "dropped composer holds the message text on an idle pane" ] \
    || fail "pending-unproven on an idle pane still holds the text and must drop, got '$(cat "$out")'"
  pass "fm-send-verify: pending-unproven is never promoted to queued"
}

test_herdr_pending_with_unreadable_busy_is_unknown() {
  local out
  out="$TMP_ROOT/unknown-herdr-busy-read"
  classify_to "$out" herdr "hello captain" \
    FM_STUB_COMPOSER=pending FM_STUB_BUSY=unknown \
    FM_STUB_CAPTURE=''
  [ "$(cat "$out")" = "unknown cannot read the pane busy state" ] \
    || fail "an unreadable busy state must not drop a pending composer, got '$(cat "$out")'"
  pass "fm-send-verify: an unreadable busy state stays unknown (never a false dropped)"
}

# --- real-pane shapes: submit-verdict evidence -------------------------------
#
# The live-use regression class (task fm-send-verify-landed-line-v2): real
# panes do not behave like the echo fixtures above. A working Pi refuses its
# separated composer shape by design (composer reads unknown while busy), and
# real harnesses rarely echo a steer in matchable form. The submit core's own
# proof-carrying verdict is the missing evidence.

test_landed_real_pi_working_composer_refused() {
  local out
  out="$TMP_ROOT/landed-pi-working"
  classify_to "$out" herdr "steer: run the wake tests" \
    FM_STUB_COMPOSER=unknown FM_STUB_BUSY=busy FM_STUB_EVIDENCE=absent \
    FM_STUB_CAPTURE='transcript without any echo' FM_STUB_SUBMIT=empty
  [ "$(cat "$out")" = "landed submit confirmed on the busy pane; composer unreadable while the agent works" ] \
    || fail "a confirmed submit to a working pi pane must be landed, got '$(cat "$out")'"
  pass "fm-send-verify: landed on the real working-pi shape (composer refused, submit confirmed)"
}

test_landed_confirmed_no_echo_busy_pane() {
  local out
  out="$TMP_ROOT/landed-no-echo-busy"
  classify_to "$out" tmux "a long steer whose echo the harness collapsed" \
    FM_STUB_COMPOSER=empty FM_STUB_TMUX_BUSY=1 \
    FM_STUB_CAPTURE='Working on it... esc to interrupt' FM_STUB_SUBMIT=empty
  [ "$(cat "$out")" = "landed submit confirmed and the composer is clear on the busy pane" ] \
    || fail "a confirmed submit with a clear composer on a busy pane must be landed, got '$(cat "$out")'"
  pass "fm-send-verify: landed when submit is confirmed and the busy pane shows no echo"
}

test_confirmed_idle_vanish_is_unknown_not_dropped() {
  local out
  out="$TMP_ROOT/confirmed-idle-vanish"
  classify_to "$out" tmux "quick steer" \
    FM_STUB_COMPOSER=empty FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE='no echo anywhere' FM_STUB_SUBMIT=empty
  [ "$(cat "$out")" = "unknown submit confirmed but the message is no longer visible on the idle pane" ] \
    || fail "a confirmed submit must not report a false dropped on a fast turn, got '$(cat "$out")'"
  pass "fm-send-verify: a confirmed submit on an idle pane is unknown, never a false dropped"
}

test_queued_submit_core_evidence_survives_scroll() {
  local out
  out="$TMP_ROOT/queued-evidence-scrolled"
  classify_to "$out" herdr "steer while busy" \
    FM_STUB_COMPOSER=unknown FM_STUB_BUSY=busy FM_STUB_EVIDENCE=absent \
    FM_STUB_CAPTURE='the Steering entry has scrolled away' FM_STUB_SUBMIT=queued
  [ "$(cat "$out")" = "queued submit core observed the accepted queue entry" ] \
    || fail "the submit core's queued proof must survive evidence scroll, got '$(cat "$out")'"
  pass "fm-send-verify: the submit core's queued proof survives queue-entry scroll"
}

test_marked_message_invisible_carrier_still_matches() {
  local out marker
  out="$TMP_ROOT/landed-marked"
  marker=$(printf '\xe2\x81\xa3')
  classify_to "$out" tmux "${marker}FIRSTMATE_OP: v1 corr=ab12 fix the build" \
    FM_STUB_COMPOSER=empty FM_STUB_TMUX_BUSY=0 \
    FM_STUB_CAPTURE='FIRSTMATE_OP: v1 corr=ab12 fix the build'
  [ "$(cat "$out")" = "landed composer cleared and message echoed in the pane capture" ] \
    || fail "the invisible U+2063 marker must not break the echo match, got '$(cat "$out")'"
  pass "fm-send-verify: the invisible operational-marker carrier never breaks the echo match"
}

# --- CLI end-to-end ---------------------------------------------------------
#
# A fake tmux that lets fm-send's submit path reach a clean verdict and then
# serves the post-send pane state to the --verify reads. send-keys Enter
# either persists the pane (FM_FAKE_SWALLOW, busy-queue shape) or swaps in the
# cleared fixture (FM_FAKE_PANE_AFTER_ENTER); display-message yields a
# configurable cursor_y; capture-pane serves the current pane fixture to the
# composer scan, the busy tail, and the verify transcript alike.

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ -z "${FM_FAKE_SEND_FAIL:-}" ] || exit 1
    shift
    is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift ;;
        Enter) is_enter=1; shift ;;
        *) shift ;;
      esac
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      elif [ -n "${FM_FAKE_PANE_AFTER_ENTER:-}" ] && [ -f "$FM_FAKE_PANE_AFTER_ENTER" ]; then
        cat "$FM_FAKE_PANE_AFTER_ENTER" > "$FM_FAKE_PANE"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*)
          # FM_FAKE_CURSOR_ONCE names a marker file: while it exists, the
          # first cursor read is served garbage (an unreadable composer) and
          # the marker is consumed, so the submit core sees an unconfirmable
          # pane while the later --verify reads see the real fixture.
          if [ -n "${FM_FAKE_CURSOR_ONCE:-}" ] && [ -f "$FM_FAKE_CURSOR_ONCE" ]; then
            rm -f "$FM_FAKE_CURSOR_ONCE"
            printf 'garbage\n'
            exit 0
          fi
          printf '%s\n' "${FM_FAKE_CURSOR_Y:-1}"; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) cat "$FM_FAKE_PANE" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <out> <err> [env-assignments...] -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH; stdout and stderr land in <out> and
# <err>. Echoes nothing; returns the exit code.
run_send() {
  local fb=$1 out=$2 err=$3 home dir a sep=0
  shift 3
  home="$TMP_ROOT/home-$RANDOM"; mkdir -p "$home/state"
  local -a envs=()
  local -a args=()
  for a in "$@"; do
    if [ "$a" = "--" ]; then
      sep=1
    elif [ "$sep" = 0 ]; then
      envs+=("$a")
    else
      args+=("$a")
    fi
  done
  : > "$out"; : > "$err"
  env "${envs[@]}" PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    "$SEND" "${args[@]}" > "$out" 2> "$err"
}

test_default_mode_output_unchanged() {
  local dir fb home out rc
  dir="$TMP_ROOT/default-mode"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$TMP_ROOT/home-$RANDOM"; mkdir -p "$home/state"
  printf 'hello captain\n╭──────────────╮\n│              │\n╰──────────────╯\n' > "$dir/pane"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    FM_FAKE_PANE="$dir/pane" FM_FAKE_CURSOR_Y=3 \
    "$SEND" sess:win "hello captain" > "$dir/out" 2> "$dir/err"; rc=$?
  expect_code 0 "$rc" "default send should succeed"
  assert_not_contains "$(cat "$dir/out")" "verify:" "default mode must not emit a verify line"
  pass "fm-send: default mode output is unchanged (no verify line, exit 0)"
}

test_cli_verify_landed_exit_zero() {
  local dir fb rc last
  dir="$TMP_ROOT/cli-landed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  printf 'steer: please fix the build\nnow\n╭──────────────╮\n│              │\n╰──────────────╯\n' > "$dir/pane"
  run_send "$fb" "$dir/out" "$dir/err" FM_FAKE_PANE="$dir/pane" FM_FAKE_CURSOR_Y=3 \
    -- --verify sess:win "steer: please fix the build now"; rc=$?
  expect_code 0 "$rc" "landed verify should exit 0"
  last=$(tail -1 "$dir/out")
  [ "$last" = "verify: landed composer cleared and message echoed in the pane capture" ] \
    || fail "expected a landed verify line, got '$last'"$'\n'"--- out ---"$'\n'"$(cat "$dir/out")"
  pass "fm-send --verify: landed exit 0 with the wrapped-text echo"
}

test_cli_verify_dropped_exit_nonzero() {
  # A genuine swallow: the composer keeps the text on an idle pane, so the
  # submit core reports pending (unconfirmed). The old code exited before the
  # --verify block on every unconfirmed verdict - the live silent-landed-send
  # defect - so this asserts the verify line now prints on that path too.
  local dir fb rc last
  dir="$TMP_ROOT/cli-dropped"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  printf 'idle pane text\n╭──────────────╮\n│ > fix build  │\n╰──────────────╯\n' > "$dir/pane"
  touch "$dir/.swallow"
  run_send "$fb" "$dir/out" "$dir/err" FM_FAKE_PANE="$dir/pane" FM_FAKE_CURSOR_Y=2 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    -- --verify sess:win "fix build"; rc=$?
  expect_code 1 "$rc" "dropped verify should exit 1"
  last=$(tail -1 "$dir/out")
  [ "$last" = "verify: dropped composer still holds the message on an idle pane" ] \
    || fail "expected a dropped verify line on the unconfirmed path, got '$last'"$'\n'"--- out ---"$'\n'"$(cat "$dir/out")"
  pass "fm-send --verify: an unconfirmed swallow prints the dropped verify line and exits 1"
}

test_cli_verify_unconfirmed_rescue_queued() {
  # The live silent-landed-send shape: the submit core cannot confirm (the
  # first composer read is unreadable, verdict unknown), but the post-send
  # reads prove the busy pane holds the accepted message. --verify must
  # classify, print queued, and rescue the send to exit 0 instead of refusing
  # with no verify line.
  local dir fb rc last
  dir="$TMP_ROOT/cli-rescue"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  printf 'Working...\n╭──────────────╮\n│ > fix build  │\n╰──────────────╯\n' > "$dir/pane"
  touch "$dir/.swallow" "$dir/.cursor-once"
  run_send "$fb" "$dir/out" "$dir/err" FM_FAKE_PANE="$dir/pane" FM_FAKE_CURSOR_Y=2 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    FM_FAKE_CURSOR_ONCE="$dir/.cursor-once" \
    -- --verify sess:win "fix build"; rc=$?
  expect_code 0 "$rc" "a rescued queued delivery should exit 0"
  last=$(tail -1 "$dir/out")
  [ "$last" = "verify: queued busy pane accepted the message for delivery at turn end" ] \
    || fail "expected the rescued queued verify line, got '$last'"$'\n'"--- out ---"$'\n'"$(cat "$dir/out")"
  assert_contains "$(cat "$dir/err")" "post-send verification proves delivery" \
    "the rescue must note that verification overruled the unconfirmed verdict"
  pass "fm-send --verify: an unconfirmed submit with queued proof is rescued to exit 0"
}

test_cli_verify_send_failed_prints_line() {
  local dir fb rc last
  dir="$TMP_ROOT/cli-send-failed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  printf 'idle\n' > "$dir/pane"
  run_send "$fb" "$dir/out" "$dir/err" FM_FAKE_PANE="$dir/pane" FM_FAKE_SEND_FAIL=1 \
    -- --verify sess:win "hello"; rc=$?
  expect_code 1 "$rc" "a transport send failure should exit 1"
  last=$(tail -1 "$dir/out")
  [ "$last" = "verify: unknown transport send failed before submission" ] \
    || fail "expected the transport-failure verify line, got '$last'"$'\n'"--- out ---"$'\n'"$(cat "$dir/out")"
  pass "fm-send --verify: a transport send failure still prints its verify line"
}

test_cli_verify_queued_busy_pane() {
  local dir fb rc last
  dir="$TMP_ROOT/cli-queued"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  printf 'Working...\n╭──────────────╮\n│ > fix build  │\n╰──────────────╯\n' > "$dir/pane"
  touch "$dir/.swallow"
  run_send "$fb" "$dir/out" "$dir/err" FM_FAKE_PANE="$dir/pane" FM_FAKE_CURSOR_Y=2 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    -- --verify sess:win "fix build"; rc=$?
  expect_code 0 "$rc" "queued verify should exit 0"
  last=$(tail -1 "$dir/out")
  [ "$last" = "verify: queued busy pane accepted the message for delivery at turn end" ] \
    || fail "expected a queued verify line, got '$last'"$'\n'"--- out ---"$'\n'"$(cat "$dir/out")"
  pass "fm-send --verify: queued exit 0 on the busy-queue shape"
}

test_cli_verify_key_path_reports_unknown() {
  local dir fb rc last
  dir="$TMP_ROOT/cli-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  printf '╭────╮\n│    │\n╰────╯\n' > "$dir/pane"
  run_send "$fb" "$dir/out" "$dir/err" FM_FAKE_PANE="$dir/pane" \
    -- --verify sess:win --key Enter; rc=$?
  expect_code 0 "$rc" "--key verify should exit 0"
  last=$(tail -1 "$dir/out")
  [ "$last" = "verify: unknown --key path carries no message text to verify" ] \
    || fail "expected the --key unknown line, got '$last'"$'\n'"--- out ---"$'\n'"$(cat "$dir/out")"
  pass "fm-send --verify: the --key path reports unknown with exit 0"
}

stub_backend_reads

test_landed_wrapped_at_word_boundary
test_landed_hard_wrap_mid_token
test_landed_bordered_ansi_capture
test_queued_busy_pane_pending_composer
test_queued_herdr_steering_evidence
test_dropped_text_stuck_in_composer
test_dropped_text_vanished_idle_pane
test_unknown_backend_reports_honestly
test_unreadable_composer_never_guesses
test_busy_pane_without_echo_is_unknown_not_dropped
test_herdr_busy_without_evidence_is_unknown
test_pending_unproven_never_promoted_to_queued
test_herdr_pending_with_unreadable_busy_is_unknown
test_landed_real_pi_working_composer_refused
test_landed_confirmed_no_echo_busy_pane
test_confirmed_idle_vanish_is_unknown_not_dropped
test_queued_submit_core_evidence_survives_scroll
test_marked_message_invisible_carrier_still_matches
test_default_mode_output_unchanged
test_cli_verify_landed_exit_zero
test_cli_verify_dropped_exit_nonzero
test_cli_verify_unconfirmed_rescue_queued
test_cli_verify_send_failed_prints_line
test_cli_verify_key_path_reports_unknown
