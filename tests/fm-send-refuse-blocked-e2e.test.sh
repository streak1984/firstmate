#!/usr/bin/env bash
# tests/fm-send-refuse-blocked-e2e.test.sh - real Claude/Herdr regression for
# task fm-send-refuse-blocked-w2 (F2 in data/fm-herdr-friction-s1/report.md,
# live reproduction: probe 6). Reproduces the exact live incident against a
# REAL claude agent and a REAL isolated Herdr lab session: a steer sent while
# the agent is genuinely parked on an AskUserQuestion dialog must be refused
# BEFORE anything is typed, and the dialog must be left exactly as it was -
# still showing, still unanswered, still highlighting its default option.
#
# Opt-in because it launches a real interactive Claude process (real model
# calls) and a real isolated Herdr lab session.
#
# Every Herdr call, including calls made inside the production backend
# adapter (via fm-send.sh), is routed through bin/fm-herdr-lab.sh - never a
# bare herdr call scoped only by ambient HERDR_SESSION.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SEND_REFUSE_BLOCKED_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SEND_REFUSE_BLOCKED_E2E=1 to run the real Claude/Herdr blocked-dialog refusal regression"
  exit 0
fi

for tool in git herdr jq claude; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-send-refuse-blocked-w2)
TMP_ROOT=$(fm_test_tmproot fm-send-refuse-blocked-e2e)
HOME_DIR="$TMP_ROOT/fm-home"
PROJECT_DIR="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
REAL_CLAUDE=$(command -v claude)
PANE=

cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/state" "$FAKEBIN" "$PROJECT_DIR"
(cd "$PROJECT_DIR" && git init -q && git commit -q --allow-empty -m init)

# Route every production adapter Herdr call (fm-send.sh -> bin/backends/herdr.sh
# -> the bare `herdr` binary on PATH) through the guarded lab helper, exactly
# like the other real-Herdr e2e suites. The helper itself runs with the
# original PATH, preventing recursion into this shim.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in
      --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;;
    esac
  done
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION"

WS_RAW=$("$LAB_HELPER" run "$SESSION" workspace create --label fm-send-refuse-blocked-w2 2>&1) \
  || fail "could not create the lab workspace: $WS_RAW"
PANE=$(printf '%s' "$WS_RAW" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || fail "workspace create did not return a root pane id: $WS_RAW"
TARGET="$SESSION:$PANE"

"$LAB_HELPER" run "$SESSION" pane run "$PANE" "cd $PROJECT_DIR" >/dev/null \
  || fail "could not cd the lab pane into the fresh project directory"
sleep 0.3

pane_capture() {
  "$LAB_HELPER" run "$SESSION" pane read "$PANE" --lines 200 2>/dev/null
}

agent_status() {
  "$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

wait_for_status() { # <status> <timeout-ticks>
  local want=$1 ticks=$2 _ got
  for _ in $(seq 1 "$ticks"); do
    got=$(agent_status)
    [ "$got" = "$want" ] && return 0
    sleep 0.5
  done
  return 1
}

# --dangerously-skip-permissions matches fm-spawn.sh's real claude launch
# command; it does not skip the folder-trust gate for a never-before-seen
# directory (verified live), so this test accepts that gate itself, once, as
# ordinary test SETUP - the deliberate audited acceptance is not the thing
# under test. What is under test starts after this.
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" \
  "$REAL_CLAUDE --dangerously-skip-permissions" >/dev/null \
  || fail "could not type the real claude launch command"
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null \
  || fail "could not submit the real claude launch command"

trust_seen=0
for _ in $(seq 1 40); do
  case "$(pane_capture)" in
    *"Yes, I trust this folder"*) trust_seen=1; break ;;
  esac
  sleep 0.5
done
[ "$trust_seen" -eq 1 ] || fail "real claude did not show the folder-trust dialog in the fresh directory within the bound"
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null \
  || fail "could not accept the folder-trust dialog"
wait_for_status "done" 40 || wait_for_status idle 40 \
  || fail "real claude did not settle to idle after accepting the folder-trust setup dialog"

# --- the scenario under test -------------------------------------------------

"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" \
  "Use the AskUserQuestion tool right now to ask me to pick a color, with options Red and Blue. Do nothing else first." >/dev/null \
  || fail "could not type the AskUserQuestion prompt"
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null \
  || fail "could not submit the AskUserQuestion prompt"

wait_for_status blocked 40 \
  || fail "real claude did not reach a native blocked agent_status after being asked to invoke AskUserQuestion"
BEFORE_CAPTURE=$(pane_capture)
assert_contains "$BEFORE_CAPTURE" "Which color do you pick?" \
  "the real AskUserQuestion dialog did not render before the steer"
pass "real herdr/claude: a live AskUserQuestion dialog reaches native agent_status=blocked (F2's exact live trigger)"

# Write real firstmate metadata for this target, exactly as fm-spawn.sh would,
# so fm-send.sh resolves it through the ordinary task-id path.
fm_write_meta "$HOME_DIR/state/probe.meta" "window=$TARGET" "backend=herdr" "harness=claude"
touch "$HOME_DIR/state/.last-watcher-beat"

ERR="$TMP_ROOT/send.err"
if PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-send.sh" --verify probe "please pick blue" >"$TMP_ROOT/send.out" 2>"$ERR"; then
  fail "REGRESSION: fm-send must exit non-zero when the live target is natively parked on a dialog"$'\n'"$(cat "$ERR")"
fi
assert_contains "$(cat "$ERR")" "parked on an interactive dialog" \
  "fm-send did not name the parked dialog in its error"
assert_contains "$(cat "$ERR")" "no text or Enter sent" \
  "fm-send did not state that no text or Enter was sent"
assert_contains "$(cat "$TMP_ROOT/send.out")" "verify: blocked" \
  "fm-send --verify did not print the documented blocked verdict"
pass "real herdr/claude: fm-send refuses the blind steer to a live blocked dialog (no text, no Enter, exit non-zero)"

# The critical live assertion: the dialog is EXACTLY as it was before the
# refused steer - still showing, still unanswered, still highlighting its
# default option. This is what F2 got wrong (the highlighted option got
# silently selected); the fix must leave it genuinely untouched.
sleep 0.5
[ "$(agent_status)" = blocked ] \
  || fail "REGRESSION: the live target must still read native agent_status=blocked after the refused steer"
AFTER_CAPTURE=$(pane_capture)
assert_contains "$AFTER_CAPTURE" "Which color do you pick?" \
  "REGRESSION: the AskUserQuestion dialog is no longer showing after the refused steer"
assert_contains "$AFTER_CAPTURE" $'\xe2\x9d\xaf 1. Red' \
  "REGRESSION: the dialog's highlighted default option changed after the refused steer"
case "$AFTER_CAPTURE" in
  *"You picked"*|*"You prefer"*|*"→ Red"*|*"→ Blue"*)
    fail "REGRESSION: the dialog was answered (Red or Blue was selected) by the refused steer"
    ;;
esac
pass "real herdr/claude: the live AskUserQuestion dialog is still unanswered after the refused steer - not silently answered with its highlighted default"

"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" escape >/dev/null 2>&1 || true
