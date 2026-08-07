#!/usr/bin/env bash
# Behavior tests for fm-spawn's post-launch confirmation phase (ship/scout
# only): a harness-owned busy event yields an immediate processing outcome, a
# parked prompt is reported as dialog without any keystroke, a gone endpoint
# yields failed with a blocked: status line and nonzero exit, a harness with
# no verified busy source yields unknown at the timeout, a seed-only busy
# record is not mistaken for processing, and --secondmate spawns never print
# a confirm: line at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-confirm)

# The fake tmux models the worker pane and the harness busy-state hook:
#   - #{pane_current_path} answers the worktree-settle probe.
#   - #{pane_id} display-message queries (the endpoint liveness probe) are
#     counted, and once the count passes FM_FAKE_ENDPOINT_DEAD_AFTER the
#     probe fails - the launch Enter's own existence check passes and the
#     confirmation phase's first poll sees a dead endpoint.
#   - capture-pane is counted, and once the count passes
#     FM_FAKE_HOOK_FIRE_AFTER the fake plays the harness hook: it applies a
#     claude-hook busy event through the real fm-busy-event.sh writer with
#     the task's current armed gen, exactly what the worker's own hook would
#     do. send-keys is logged verbatim to FM_FAKE_KEYS_LOG.
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
  display-message)
    case "$*" in
      *"#{cursor_y}"*)
        printf '%s\n' "${FM_FAKE_CURSOR_Y:-firstmate}"
        exit 0
        ;;
    esac
    case "$*" in
      *"#{pane_id}"*)
        n=0
        [ -f "$FM_FAKE_PANE_ID_COUNT" ] && n=$(cat "$FM_FAKE_PANE_ID_COUNT")
        n=$((n + 1))
        printf '%s\n' "$n" > "$FM_FAKE_PANE_ID_COUNT"
        if [ -n "${FM_FAKE_ENDPOINT_DEAD_AFTER:-}" ] && [ "$n" -gt "$FM_FAKE_ENDPOINT_DEAD_AFTER" ]; then
          exit 1
        fi
        ;;
    esac
    printf '%s\n' firstmate
    ;;
  list-windows|has-session|new-session|set-window-option|kill-window) ;;
  new-window) printf '%s\n' %1 ;;
  send-keys) printf '%s\n' "$*" >> "$FM_FAKE_KEYS_LOG" ;;
  capture-pane)
    n=0
    [ -f "$FM_FAKE_CAPTURE_COUNT" ] && n=$(cat "$FM_FAKE_CAPTURE_COUNT")
    n=$((n + 1))
    printf '%s\n' "$n" > "$FM_FAKE_CAPTURE_COUNT"
    if [ -n "${FM_FAKE_HOOK_FIRE_AFTER:-}" ] && [ "$n" -gt "$FM_FAKE_HOOK_FIRE_AFTER" ] \
       && [ -f "$FM_FAKE_STATE/$FM_FAKE_ID.busy-gen" ]; then
      gen=$(cat "$FM_FAKE_STATE/$FM_FAKE_ID.busy-gen")
      "$FM_FAKE_ROOT/bin/fm-busy-event.sh" apply "$FM_FAKE_STATE" "$FM_FAKE_ID" busy \
        --gen "$gen" --source claude-hook --event user-prompt-submit >/dev/null 2>&1 || true
    fi
    printf '%s\n' "${FM_FAKE_PANE_CAPTURE:-}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude codex gh gh-axi sleep
  printf '%s\n' "$fakebin"
}

# A ship/scout-style case: a fake home (crew harness pinned), a project with
# a real git worktree (the launch cwd), and the fakebin.
make_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 dir home project worktree fakebin
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
  printf '%s\n' "$home|$project|$worktree|$fakebin"
}

enter_count() {  # <keys-log>
  grep -c ' Enter$' "$1" 2>/dev/null || true
}

capture_count() {  # <capture-count-file>
  cat "$1" 2>/dev/null || true
}

# run_spawn <home> <project> <worktree> <fakebin> <id> <harness>
#           [--scout] [RAW=<launch>] [FM_FAKE_PANE_CAPTURE=<text>] [VAR=val ...]
# RAW=<launch> passes the launch as a raw command (unverified-adapter escape
# hatch) instead of --harness; VAR=val arguments become env prefixes on the
# spawn invocation.
run_spawn() {
  local home=$1 project=$2 worktree=$3 fakebin=$4 id=$5 harness=$6
  shift 6
  local scout='' pane_capture='pi TUI content' raw_launch='' a
  local -a extra=()
  for a in "$@"; do
    case "$a" in
      --scout) scout=1 ;;
      FM_FAKE_PANE_CAPTURE=*) pane_capture=${a#FM_FAKE_PANE_CAPTURE=} ;;
      RAW=*) raw_launch=${a#RAW=} ;;
      *) extra+=("$a") ;;
    esac
  done
  : > "$TMP_ROOT/$id.keys"
  : > "$TMP_ROOT/$id.captures"
  : > "$TMP_ROOT/$id.pane-id"
  local -a spawn_args=("$id" "$project")
  if [ -n "$raw_launch" ]; then
    spawn_args+=("$raw_launch")
  else
    spawn_args+=(--harness "$harness")
  fi
  [ -n "$scout" ] && spawn_args+=(--scout)
  # FM_BACKEND=tmux pins the fake backend: the suite may run inside a herdr
  # or cmux runtime, whose auto-detection would otherwise target the real
  # session instead of the fake tmux binary.
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" \
    FM_FAKE_PANE_CAPTURE="$pane_capture" \
    FM_FAKE_KEYS_LOG="$TMP_ROOT/$id.keys" FM_FAKE_CAPTURE_COUNT="$TMP_ROOT/$id.captures" \
    FM_FAKE_PANE_ID_COUNT="$TMP_ROOT/$id.pane-id" \
    FM_FAKE_STATE="$home/state" FM_FAKE_ID="$id" FM_FAKE_ROOT="$ROOT" \
    FM_SPAWN_AUTONOMY_POLLS=1 FM_SPAWN_AUTONOMY_POLL_INTERVAL=0 \
    env "${extra[@]+"${extra[@]}"}" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "${spawn_args[@]}" 2>&1
}

# confirm_line_is_final <out>: the confirm: line must be the LAST stdout line,
# after the spawned: line.
confirm_line_is_final() {
  local out=$1 spawned_line confirm_line
  spawned_line=$(printf '%s\n' "$out" | grep -n '^spawned ' | tail -1 | cut -d: -f1)
  confirm_line=$(printf '%s\n' "$out" | grep -n '^confirm: ' | tail -1 | cut -d: -f1)
  [ -n "$spawned_line" ] || fail "no spawned line in output"
  [ -n "$confirm_line" ] || fail "no confirm line in output"
  [ "$confirm_line" -gt "$spawned_line" ] || fail "confirm line is not the final stdout line"
}

test_harness_busy_event_yields_immediate_processing() {
  local id="confirm-processing-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case processing claude "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # The harness hook fires during the autonomy phase's last capture, so the
  # confirmation phase's very first poll classifies processing and the spawn
  # returns without polling the timeout away.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" claude \
    --scout FM_FAKE_HOOK_FIRE_AFTER=1 FM_SPAWN_CONFIRM_TIMEOUT=5) || rc=$?
  expect_code 0 "$rc" "a worker turn running must not fail the spawn"
  assert_contains "$out" "spawned $id harness=claude" "processing spawn did not complete"
  assert_contains "$out" "confirm: processing busy/claude-hook" \
    "the harness-owned busy event did not yield the processing outcome"
  confirm_line_is_final "$out"
  [ "$(capture_count "$TMP_ROOT/$id.captures")" = 2 ] || \
    fail "processing landed on the first confirm poll (expected 2 captures total, got $(capture_count "$TMP_ROOT/$id.captures"))"
  [ ! -f "$home/state/$id.status" ] || assert_no_grep 'blocked:' "$home/state/$id.status" "processing must not append a blocked line"
  pass "fm-spawn: a harness-owned busy event yields confirm: processing on the first poll"
}

test_seed_busy_record_alone_is_not_processing() {
  local id="confirm-seed-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case seed claude "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # No hook ever fires: the pre-launch busy/fm-spawn seed is not positive
  # evidence, so the phase polls the bounded budget and reports unknown.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" claude \
    FM_SPAWN_CONFIRM_TIMEOUT=2 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5) || rc=$?
  expect_code 0 "$rc" "a seed-only launch must not fail the spawn"
  assert_contains "$out" "confirm: unknown no-busy-event" \
    "the busy/fm-spawn seed was treated as processing evidence"
  confirm_line_is_final "$out"
  [ ! -f "$home/state/$id.status" ] || assert_no_grep 'blocked:' "$home/state/$id.status" "unknown must not append a blocked line"
  pass "fm-spawn: the pre-launch busy/fm-spawn seed alone stays unknown, never processing"
}

test_parked_prompt_is_reported_as_dialog_without_keystrokes() {
  local id="confirm-dialog-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case dialog claude "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # Claude's directory-trust dialog is not auto-accepted by any existing
  # phase, so the confirmation phase must report it and send no key.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" claude \
    FM_FAKE_PANE_CAPTURE='Do you trust the contents of this directory?' \
    FM_SPAWN_CONFIRM_TIMEOUT=5) || rc=$?
  expect_code 0 "$rc" "a parked dialog must not fail the spawn (it is reported)"
  assert_contains "$out" "confirm: dialog parked-prompt" \
    "the directory-trust dialog was not reported as dialog"
  confirm_line_is_final "$out"
  # Baseline launch Enters only (treehouse get, PATH guarantee, GOTMPDIR
  # export, launch) - the confirmation phase never sends a key.
  [ "$(enter_count "$TMP_ROOT/$id.keys")" = 4 ] || \
    fail "dialog report sent a keystroke (expected 4 baseline Enters, got $(enter_count "$TMP_ROOT/$id.keys"))"
  assert_grep 'blocked: an interactive prompt parked the worker' "$home/state/$id.status" \
    "dialog report did not append the blocked status line"
  pass "fm-spawn: a parked prompt is reported as dialog with a blocked line and zero keystrokes"
}

test_dead_endpoint_yields_failed() {
  local id="confirm-dead-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case dead claude "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # The launch Enter's own pane_id probe passes; the confirmation phase's
  # first poll then sees the endpoint gone.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" claude \
    FM_FAKE_ENDPOINT_DEAD_AFTER=1 FM_SPAWN_CONFIRM_TIMEOUT=5) || rc=$?
  expect_code 1 "$rc" "a dead endpoint must fail the spawn"
  assert_contains "$out" "confirm: failed endpoint-dead" \
    "the gone endpoint did not yield the failed outcome"
  assert_grep 'blocked: the worker endpoint died right after launch' "$home/state/$id.status" \
    "failed did not append the blocked status line"
  pass "fm-spawn: a dead endpoint yields confirm: failed, a blocked line, and exit 1"
}

test_unverified_harness_is_unknown_at_timeout() {
  local id="confirm-unknown-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case unknown codex "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # Codex has no verified busy source, so the phase polls the full bounded
  # budget and reports unknown honestly.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" codex \
    FM_SPAWN_CONFIRM_TIMEOUT=2 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5) || rc=$?
  expect_code 0 "$rc" "an unknown outcome must not fail the spawn"
  assert_contains "$out" "confirm: unknown codex-unverified" \
    "the unverified harness was not reported unknown"
  confirm_line_is_final "$out"
  [ "$(capture_count "$TMP_ROOT/$id.captures")" = 4 ] || \
    fail "unknown polled the full bounded budget (expected 4 captures, got $(capture_count "$TMP_ROOT/$id.captures"))"
  [ ! -f "$home/state/$id.status" ] || assert_no_grep 'blocked:' "$home/state/$id.status" "unknown must not append a blocked line"
  pass "fm-spawn: a harness with no verified busy source reports unknown at the timeout"
}

test_unconfirmable_harness_window_is_capped() {
  # Codex outside herdr can never classify processing (no armed busy record,
  # no native busy verdict), so the phase must not stall for the full
  # FM_SPAWN_CONFIRM_TIMEOUT budget on every such spawn: the poll window is
  # capped at FM_SPAWN_CONFIRM_UNCONFIRMABLE_TIMEOUT while dialog and
  # dead-endpoint detection keep running inside the capped window.
  local id="confirm-capped-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case capped codex "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" codex \
    FM_SPAWN_CONFIRM_TIMEOUT=45 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5 \
    FM_SPAWN_CONFIRM_UNCONFIRMABLE_TIMEOUT=1) || rc=$?
  expect_code 0 "$rc" "a capped unknown outcome must not fail the spawn"
  assert_contains "$out" "confirm: unknown codex-unverified" \
    "the capped window did not report the honest unknown"
  confirm_line_is_final "$out"
  [ "$(capture_count "$TMP_ROOT/$id.captures")" = 2 ] || \
    fail "the unconfirmable window was not capped (expected 2 captures, got $(capture_count "$TMP_ROOT/$id.captures"))"
  pass "fm-spawn: an unconfirmable harness/backend pair gets a capped confirm window"
}

# A bordered composer box with real text and the cursor on its content row:
# the shared tmux composer reader classifies it pending. Every row's inner
# width is identical (23), so the geometry is proven, not ambiguous.
PENDING_COMPOSER=$(printf '╭%s╮\n│ launch text sits here │\n╰%s╯' \
  "$(printf '─%.0s' $(seq 1 23))" "$(printf '─%.0s' $(seq 1 23))")

test_template_launch_with_unsubmitted_text_yields_failed() {
  local id="confirm-pending-tpl-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case pending-tpl codex "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # A template launch whose composer still holds the launch text at the
  # timeout is the swallowed-Enter failure mode: failed.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" codex \
    FM_FAKE_PANE_CAPTURE="$PENDING_COMPOSER" FM_FAKE_CURSOR_Y=1 \
    FM_SPAWN_CONFIRM_TIMEOUT=2 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5) || rc=$?
  expect_code 1 "$rc" "unsubmitted launch text in a template launch must fail the spawn"
  assert_contains "$out" "confirm: failed launch-text-unsubmitted" \
    "pending composer text did not yield the failed outcome"
  assert_grep 'blocked: the launch text was never submitted' "$home/state/$id.status" \
    "failed did not append the blocked status line"
  pass "fm-spawn: a template launch whose composer still holds the launch text fails at the timeout"
}

test_raw_launch_composer_lookalike_is_not_failed() {
  local id="confirm-pending-raw-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case pending-raw sh "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  # A raw launch runs in the plain shell, whose treehouse prompt itself
  # starts with the agent glyph ❯, so a shell-prompt row can look exactly
  # like pending composer text. The composer verdict is scoped to template
  # launches, so a raw launch stays honestly unknown instead of a false
  # failed.
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$id" sh \
    RAW="sh -c 'sleep 1'" FM_FAKE_PANE_CAPTURE="$PENDING_COMPOSER" FM_FAKE_CURSOR_Y=1 \
    FM_SPAWN_CONFIRM_TIMEOUT=2 FM_SPAWN_CONFIRM_POLL_INTERVAL=0.5) || rc=$?
  expect_code 0 "$rc" "a raw launch must not fail on composer lookalike text"
  assert_contains "$out" "confirm: unknown missing" \
    "raw launch composer lookalike was misreported as failed"
  [ ! -f "$home/state/$id.status" ] || assert_no_grep 'blocked:' "$home/state/$id.status" "raw launch must not append a blocked line"
  pass "fm-spawn: raw launches skip the composer verdict and stay honestly unknown"
}

# A minimal seeded secondmate home (validate_firstmate_home_for_spawn needs
# the seed marker, AGENTS.md, bin/, and a charter to launch), mirroring
# tests/fm-spawn-pi-trust.test.sh's fixture.
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

test_secondmate_spawn_prints_no_confirm_line() {
  local id="confirm-sm-$$" rec home sm fakebin out rc=0
  rec=$(make_secondmate_case sm "$id")
  IFS='|' read -r home sm fakebin <<EOF
$rec
EOF
  out=$(HOME="$home" TMUX='' FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$sm" \
    FM_FAKE_PANE_CAPTURE='pi TUI content' \
    FM_FAKE_KEYS_LOG="$TMP_ROOT/$id.keys" FM_FAKE_CAPTURE_COUNT="$TMP_ROOT/$id.captures" \
    FM_FAKE_PANE_ID_COUNT="$TMP_ROOT/$id.pane-id" \
    FM_FAKE_STATE="$home/state" FM_FAKE_ID="$id" FM_FAKE_ROOT="$ROOT" \
    FM_PI_TRUST_POLLS=3 FM_PI_TRUST_POLL_INTERVAL=0 \
    FM_PI_TRUST_CLEAR_POLLS=3 FM_PI_TRUST_CLEAR_POLL_INTERVAL=0 \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$sm" pi --secondmate 2>&1) || rc=$?
  expect_code 0 "$rc" "a secondmate spawn must stay healthy"
  assert_contains "$out" "spawned $id harness=pi" "secondmate spawn did not complete"
  assert_not_contains "$out" "confirm:" "secondmate spawns must keep their existing behavior"
  pass "fm-spawn: --secondmate spawns skip the confirmation phase entirely"
}

test_harness_busy_event_yields_immediate_processing
test_seed_busy_record_alone_is_not_processing
test_parked_prompt_is_reported_as_dialog_without_keystrokes
test_dead_endpoint_yields_failed
test_unverified_harness_is_unknown_at_timeout
test_unconfirmable_harness_window_is_capped
test_template_launch_with_unsubmitted_text_yields_failed
test_raw_launch_composer_lookalike_is_not_failed
test_secondmate_spawn_prints_no_confirm_line
