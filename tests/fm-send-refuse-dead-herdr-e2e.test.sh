#!/usr/bin/env bash
# tests/fm-send-refuse-dead-herdr-e2e.test.sh - real Claude/Herdr regression
# for the pre-send agent-registry refusal (data/fm-herdr-friction-s1/
# report.md finding F1, work item W1).
#
# This is opt-in because it launches a real interactive Claude agent and a
# real isolated Herdr lab session. It reproduces the exact live evidence the
# diagnostic report recorded: launch a real claude agent, /exit it so its
# pane survives as a bare login shell, then steer the husk through the
# production bin/fm-send.sh. Before this fix that steer typed the message
# into the shell and zsh EXECUTED it; the marker file this test's message
# would create is the ground truth that no shell execution happened.
#
# Every Herdr call is routed through bin/fm-herdr-lab.sh (HARD SAFETY
# CONTRACT): a named non-default lab session, provisioned/run/torn down only
# through the helper, with an EXIT trap and the helper's own default-session
# tripwire. The captain's live fleet (the `default` session) is never
# touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SEND_REFUSE_DEAD_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SEND_REFUSE_DEAD_HERDR_E2E=1 to run the real Claude/Herdr husk-refusal regression"
  exit 0
fi

for tool in git herdr jq claude; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-send-refuse-dead-w1)

TMP_ROOT=$(fm_test_tmproot fm-send-refuse-dead-herdr-e2e)
REPO="$TMP_ROOT/repo"
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
MARKER="$TMP_ROOT/EXECUTED"
mkdir -p "$REPO" "$HOME_DIR/state" "$FAKEBIN"
git init -q "$REPO"

ORIGINAL_PATH=$PATH

cleanup() {
  local status=$?
  env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

agent_status() {  # -> raw agent_status, or empty on any read failure
  lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true
}

agent_dead() {  # 0 only for a positively confirmed agent_not_found
  local out code
  out=$(lab agent get "$PANE" 2>&1) || true
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null || true)
  [ "$code" = agent_not_found ]
}

# Route production adapter herdr calls through the same guarded lab helper as
# every other isolated E2E probe. The shim strips only the adapter's already-
# validated trailing --session pair, then delegates to the lab helper (run
# with the ORIGINAL PATH, so the helper itself never recurses into this shim).
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$HERDR_LAB_HELPER'
session='$HERDR_LAB_SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

# --- launch a real claude agent, grant workspace trust, wait for idle -------

WS=$(lab workspace create --cwd "$REPO" --label fm-send-refuse-dead-w1 --no-focus) \
  || fail "could not create the isolated Herdr workspace"
PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
[ -n "$PANE" ] || fail "workspace create did not return a pane id"

lab pane run "$PANE" "claude --dangerously-skip-permissions" >/dev/null \
  || fail "could not launch a real claude agent in the isolated pane"

# The first-run workspace-trust dialog's highlighted default is "1. Yes, I
# trust this folder" - accept it before waiting for a real idle agent.
sleep 3
lab pane send-keys "$PANE" enter >/dev/null

idle=0
for _ in $(seq 1 60); do
  [ "$(agent_status)" = idle ] && { idle=1; break; }
  sleep 0.5
done
[ "$idle" = 1 ] || fail "real claude agent never reached idle after launch and trust acceptance"
pass "real Claude/Herdr: a real claude agent registered and reached idle"

# --- /exit it: harness process ends, pane survives as a bare login shell ---
#
# /exit opens claude's slash-command popup; timing-sensitive in a headless
# lab, so this retries the full type+settle+Enter cycle rather than assuming
# a single attempt lands (mirrors fm-send.sh's own submit-retry philosophy).
exited=0
for _ in 1 2 3 4 5 6; do
  lab pane send-text "$PANE" "/exit" >/dev/null
  sleep 1.5
  lab pane send-keys "$PANE" enter >/dev/null
  for _ in $(seq 1 10); do
    agent_dead && { exited=1; break; }
    sleep 0.5
  done
  [ "$exited" = 1 ] && break
done
[ "$exited" = 1 ] || fail "real claude agent never exited (agent_not_found) after repeated /exit attempts"
pass "real Claude/Herdr: /exit left a husk pane with no registered agent (agent_not_found)"

[ ! -e "$MARKER" ] || fail "marker pre-existed before the steer under test"$'\n'"$MARKER"

# --- steer the husk through the REAL production fm-send.sh -----------------

cat > "$HOME_DIR/state/husk-w1.meta" <<META
window=$HERDR_LAB_SESSION:$PANE
backend=herdr
harness=claude
META

SEND_OUT=$( PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
  "$ROOT/bin/fm-send.sh" --verify husk-w1 "touch $MARKER" 2>&1 )
SEND_RC=$?

expect_code 1 "$SEND_RC" "steering a real husk pane must refuse and exit non-zero"$'\n'"$SEND_OUT"
assert_contains "$SEND_OUT" "no registered agent for this pane" "the refusal must name the reason"
case "$SEND_OUT" in
  *"verify: landed"*) fail "the verify line must never be 'landed' for a refused husk steer"$'\n'"$SEND_OUT" ;;
esac
assert_contains "$SEND_OUT" "verify: unknown" "the verify line must report unknown, never a promoted verdict"

if [ -e "$MARKER" ]; then
  fail "THE DEFECT IS STILL PRESENT: the husk shell executed the steered text and created $MARKER"$'\n'"$SEND_OUT"
fi
pass "real Claude/Herdr: fm-send refuses a real exited-agent husk pane before any text reaches the shell (marker absent)"
