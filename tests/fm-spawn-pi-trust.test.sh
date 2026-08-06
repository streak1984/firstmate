#!/usr/bin/env bash
# Behavior tests for fm-spawn's pi trust-dialog auto-accept: a positively
# matched dialog is accepted with exactly one Enter and confirmed cleared, an
# absent match sends nothing, a persistent dialog or a different blocking
# prompt appends a blocked: status line, non-pi launches are untouched, an
# already-trusted path skips the poll entirely, and a --secondmate pi launch
# gets the same acceptance in its home worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-trust)

DIALOG_TEXT=$'Trust\n\nThis allows pi to load .pi settings and resources…\nTrust (this session only)\nDo not trust'

# The fake tmux models pi's startup: capture-pane returns the ordinary TUI
# capture until FM_FAKE_DIALOG_CAPTURE_DELAY captures have happened, then the
# trust dialog appears (the observed "dialog seconds after an immediate peek"
# delay); delay 0 shows it on the very first capture and a large delay never
# shows it. send-keys is logged verbatim to FM_FAKE_KEYS_LOG, and an Enter
# sent while the dialog is showing accepts it (removes the dialog file)
# unless FM_FAKE_DIALOG_STICKY=1, which models a dialog that survives accept.
make_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate ;;
  list-windows|has-session|new-session|set-window-option|kill-window) ;;
  new-window) printf '%s\n' %1 ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_KEYS_LOG"
    if [ -e "$FM_FAKE_DIALOG_FILE" ] && [ "${FM_FAKE_DIALOG_STICKY:-0}" != 1 ]; then
      rm -f "$FM_FAKE_DIALOG_FILE"
    fi
    ;;
  capture-pane)
    n=0
    [ -f "$FM_FAKE_CAPTURE_COUNT" ] && n=$(cat "$FM_FAKE_CAPTURE_COUNT")
    n=$((n + 1))
    printf '%s\n' "$n" > "$FM_FAKE_CAPTURE_COUNT"
    # The dialog appears exactly once, on capture (delay + 1), and stays
    # until an Enter accepts it; a capture after the delay must never
    # re-create it.
    delay=${FM_FAKE_DIALOG_CAPTURE_DELAY:-1}
    if [ "$n" -eq "$((delay + 1))" ]; then
      : > "$FM_FAKE_DIALOG_FILE"
    fi
    if [ -e "$FM_FAKE_DIALOG_FILE" ]; then
      printf '%s\n' "${FM_FAKE_DIALOG_CAPTURE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_CAPTURE:-}"
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude codex gh gh-axi sleep
  printf '%s\n' "$fakebin"
}

# A ship/scout-style case: a fake home (crew harness pinned), a project with
# a real git worktree (the pi launch cwd), and the fakebin. The pi trust
# store lives under the fake home, so `trusted` pre-records the worktree path
# to exercise the already-trusted fast path.
make_case() {  # <name> <harness> <id> <trusted>
  local name=$1 harness=$2 id=$3 trusted=$4 dir home project worktree fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  fakebin=$(make_fakebin "$dir")
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  if [ "$trusted" = trusted ]; then
    mkdir -p "$home/.pi/agent"
    printf '{\n  "%s": true\n}\n' "$worktree" > "$home/.pi/agent/trust.json"
  fi
  printf '%s\n' "$home|$project|$worktree|$fakebin"
}

enter_count() {  # <keys-log>
  grep -c ' Enter$' "$1" 2>/dev/null || true
}

capture_count() {  # <capture-count-file>
  cat "$1" 2>/dev/null || true
}

run_spawn() {  # <home> <project> <worktree> <fakebin> <id> <harness> <dialog-delay> [dialog-capture] [pane-capture]
  local home=$1 project=$2 worktree=$3 fakebin=$4 id=$5 harness=$6 delay=$7
  local dialog=${8:-} pane=${9:-'pi TUI content'}
  : > "$TMP_ROOT/$id.keys"
  : > "$TMP_ROOT/$id.captures"
  rm -f "$TMP_ROOT/$id.dialog"
  # FM_BACKEND=tmux pins the fake backend: the suite may run inside a herdr
  # or cmux runtime, whose auto-detection would otherwise target the real
  # session instead of the fake tmux binary.
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" \
    FM_FAKE_PANE_CAPTURE="$pane" \
    FM_FAKE_DIALOG_CAPTURE="$dialog" FM_FAKE_DIALOG_CAPTURE_DELAY="$delay" \
    FM_FAKE_DIALOG_FILE="$TMP_ROOT/$id.dialog" FM_FAKE_DIALOG_STICKY="${FM_FAKE_DIALOG_STICKY:-0}" \
    FM_FAKE_KEYS_LOG="$TMP_ROOT/$id.keys" FM_FAKE_CAPTURE_COUNT="$TMP_ROOT/$id.captures" \
    FM_PI_TRUST_POLLS=3 FM_PI_TRUST_POLL_INTERVAL=0 \
    FM_PI_TRUST_CLEAR_POLLS=3 FM_PI_TRUST_CLEAR_POLL_INTERVAL=0 \
    FM_SPAWN_CONFIRM_TIMEOUT=0 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.01 \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --harness "$harness" 2>&1
}

test_dialog_matched_is_accepted_and_confirmed_cleared() {
  local id="pi-trust-accept-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case accept pi "$id" untrusted)
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" pi 0 "$DIALOG_TEXT") || rc=$?
  expect_code 0 "$rc" "a matched pi trust dialog must be accepted without failing the spawn"
  assert_contains "$out" "spawned $id harness=pi" "accepted dialog blocked spawn completion"
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 5 ] || fail "expected exactly one accept Enter (5 total), got $(enter_count "$TMP_ROOT/$id.keys")"
  [ ! -e "$TMP_ROOT/$id.dialog" ] || fail "dialog file still present after accept"
  pass "fm-spawn: a positively matched pi trust dialog is accepted with one Enter and confirmed cleared"
}

test_dialog_appearing_after_the_first_poll_is_still_accepted() {
  local id="pi-trust-delayed-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case delayed pi "$id" untrusted)
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" pi 1 "$DIALOG_TEXT") || rc=$?
  expect_code 0 "$rc" "a dialog appearing after the first poll must still be accepted"
  assert_contains "$out" "spawned $id harness=pi" "delayed dialog accept blocked spawn completion"
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 5 ] || fail "expected exactly one accept Enter (5 total), got $(enter_count "$TMP_ROOT/$id.keys")"
  pass "fm-spawn: a trust dialog appearing after the first capture is caught by the poll and accepted"
}

test_no_dialog_sends_nothing() {
  local id="pi-trust-absent-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case absent pi "$id" untrusted)
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" pi 999 '') || rc=$?
  expect_code 0 "$rc" "an absent dialog must not disturb the spawn"
  assert_contains "$out" "spawned $id harness=pi" "absent dialog blocked spawn completion"
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 4 ] || fail "trust handler sent keys without a dialog match"
  # The confirmation phase follows the pi phase for ship/scout spawns and adds
  # its single bounded poll (FM_SPAWN_CONFIRM_TIMEOUT=0 still polls once).
  [ "$(capture_count "$TMP_ROOT/$id.captures")" = 5 ] || fail "expected the pi-phase bound (4 captures) plus the single confirm poll, got $(capture_count "$TMP_ROOT/$id.captures")"
  [ ! -e "$TMP_ROOT/$id.dialog" ] || fail "dialog file appeared without a dialog"
  pass "fm-spawn: an absent trust dialog sends nothing beyond the bounded poll"
}

test_persistent_dialog_appends_blocked_status() {
  local id="pi-trust-sticky-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case sticky pi "$id" untrusted)
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  FM_FAKE_DIALOG_STICKY=1
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" pi 0 "$DIALOG_TEXT") || rc=$?
  FM_FAKE_DIALOG_STICKY=0
  expect_code 1 "$rc" "a persistent trust dialog must fail the spawn"
  assert_not_contains "$out" "spawned $id" "persistent dialog must not report a successful spawn"
  assert_grep 'blocked: pi trust dialog did not clear after accept' "$home/state/$id.status" \
    "persistent dialog did not append the blocked status line"
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 5 ] || fail "expected exactly one accept attempt (5 total), got $(enter_count "$TMP_ROOT/$id.keys")"
  pass "fm-spawn: a dialog that survives the single accept appends blocked: for firstmate"
}

test_other_blocking_prompt_appends_blocked_status() {
  local id="pi-trust-other-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case other pi "$id" untrusted)
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" pi 999 '' \
    "Username for 'https://github.com':") || rc=$?
  expect_code 1 "$rc" "a non-trust blocking prompt must fail the spawn"
  assert_not_contains "$out" "spawned $id" "other-prompt blocker must not report a successful spawn"
  assert_grep 'blocked: a non-trust interactive prompt parked the pi worker' "$home/state/$id.status" \
    "other-prompt blocker did not append the blocked status line"
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 4 ] || fail "other-prompt blocker must not send an accept Enter"
  pass "fm-spawn: a non-trust blocking prompt appends blocked: and never gets an Enter"
}

test_non_pi_harness_is_untouched() {
  local id="pi-trust-claude-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case claude claude "$id" untrusted)
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" claude 0 "$DIALOG_TEXT") || rc=$?
  expect_code 0 "$rc" "a claude launch showing pi dialog text must stay untouched"
  assert_contains "$out" "spawned $id harness=claude" "claude launch blocked by the pi trust handler"
  assert_contains "$out" "AUTONOMY WARNING" "claude did not actually capture the dialog text in this fixture"
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 4 ] || fail "claude launch got an unexpected extra Enter"
  [ -e "$TMP_ROOT/$id.dialog" ] || fail "claude fixture lost the dialog before the harness gate could ignore it"
  if grep -F 'blocked:' "$home/state/$id.status" 2>/dev/null; then
    fail "claude launch appended a blocked line"
  fi
  pass "fm-spawn: non-pi harnesses are untouched even when the pane shows pi dialog text"
}

test_already_trusted_path_skips_the_poll() {
  local id="pi-trust-fast-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case fast pi "$id" trusted)
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" pi 0 "$DIALOG_TEXT") || rc=$?
  expect_code 0 "$rc" "an already-trusted worktree must spawn cleanly"
  assert_contains "$out" "spawned $id harness=pi" "already-trusted spawn did not complete"
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 4 ] || fail "already-trusted spawn sent keys"
  # The already-trusted fast path skips the pi poll entirely; only the
  # confirmation phase's single bounded poll reads the pane.
  [ "$(capture_count "$TMP_ROOT/$id.captures")" = 1 ] || fail "already-trusted spawn captured beyond the single confirm poll (captures: $(capture_count "$TMP_ROOT/$id.captures"))"
  pass "fm-spawn: a path already recorded in pi's trust store skips the poll entirely"
}

# A minimal seeded secondmate home (validate_firstmate_home_for_spawn needs
# the seed marker, AGENTS.md, bin/, and a charter to launch), mirroring
# tests/fm-secondmate-harness.test.sh's fixture. The secondmate home worktree
# is untrusted on its first pi launch exactly like a fresh crew worktree, so
# the same auto-accept must apply.
make_secondmate_case() {  # <name> <id>
  local name=$1 id=$2 dir home sm fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  sm="$dir/sm"
  fakebin=$(make_fakebin "$dir")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  printf '%s\n' "$home|$sm|$fakebin"
}

run_secondmate_spawn() {  # <home> <smhome> <fakebin> <id> <dialog-delay> [dialog-capture]
  local home=$1 sm=$2 fakebin=$3 id=$4 delay=$5 dialog=${6:-}
  : > "$TMP_ROOT/$id.keys"
  : > "$TMP_ROOT/$id.captures"
  rm -f "$TMP_ROOT/$id.dialog"
  # FM_BACKEND=tmux pins the fake backend; see run_spawn.
  HOME="$home" TMUX='' FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$sm" \
    FM_FAKE_PANE_CAPTURE='pi TUI content' \
    FM_FAKE_DIALOG_CAPTURE="$dialog" FM_FAKE_DIALOG_CAPTURE_DELAY="$delay" \
    FM_FAKE_DIALOG_FILE="$TMP_ROOT/$id.dialog" FM_FAKE_DIALOG_STICKY=0 \
    FM_FAKE_KEYS_LOG="$TMP_ROOT/$id.keys" FM_FAKE_CAPTURE_COUNT="$TMP_ROOT/$id.captures" \
    FM_PI_TRUST_POLLS=3 FM_PI_TRUST_POLL_INTERVAL=0 \
    FM_PI_TRUST_CLEAR_POLLS=3 FM_PI_TRUST_CLEAR_POLL_INTERVAL=0 \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$sm" pi --secondmate 2>&1
}

test_secondmate_launch_accepts_the_dialog() {
  local id="pi-trust-sm-$$" rec home sm fakebin out rc=0
  rec=$(make_secondmate_case sm "$id")
  IFS='|' read -r home sm fakebin <<EOF
$rec
EOF
  out=$(run_secondmate_spawn "$home" "$sm" "$fakebin" "$id" 0 "$DIALOG_TEXT") || rc=$?
  expect_code 0 "$rc" "a secondmate pi launch with a trust dialog must accept it"
  assert_contains "$out" "spawned $id harness=pi" "secondmate accept blocked spawn completion"
  # No treehouse get in a secondmate launch: baseline is 3 Enters + 1 accept.
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 4 ] || fail "expected exactly one accept Enter (4 total), got $(enter_count "$TMP_ROOT/$id.keys")"
  [ ! -e "$TMP_ROOT/$id.dialog" ] || fail "secondmate dialog file still present after accept"
  pass "fm-spawn: a --secondmate pi launch into an untrusted home worktree gets the same auto-accept"
}

test_dialog_matched_is_accepted_and_confirmed_cleared
test_dialog_appearing_after_the_first_poll_is_still_accepted
test_no_dialog_sends_nothing
test_persistent_dialog_appends_blocked_status
test_other_blocking_prompt_appends_blocked_status
test_non_pi_harness_is_untouched
test_already_trusted_path_skips_the_poll
test_secondmate_launch_accepts_the_dialog
