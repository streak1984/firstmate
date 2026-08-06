#!/usr/bin/env bash
# Tests for bin/fm-land.sh: the one guarded landing chain per shipped PR task -
# merge, clone refresh, cleanup, backlog completion, and the queue re-evaluation
# cue. The chain never decides merge authority, has no force or discard paths,
# and stops at the first failure with evidence, so firstmate can fix and re-run.
#
# Matrix:
#   (a) happy path runs every step in order and completes with the pr url
#   (b) merge failure stops the chain before any later step
#   (c) clone refresh failure stops the chain before cleanup
#   (d) teardown refusal is terminal and keeps the refusal text verbatim
#   (e) backlog completion failure stops the chain after cleanup
#   (f) ready cue failure stops the chain after landing
#   (g) resume skips an already-merged PR and continues at clone refresh
#   (h) resume after a completed teardown skips every completed step
#   (i) the merge probe honors a recorded gh account token
#   (j) manual backlog backend prints instructions without editing
#   (k) missing meta is refused naming exactly what is missing
#   (l) meta without pr= is refused naming exactly what is missing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

LAND="$ROOT/bin/fm-land.sh"
TMP_ROOT=$(fm_test_tmproot fm-land-tests)

# Build a fresh sandbox for one test case: a fake firstmate home with a task
# meta and project dir, plus a fakebin with the child-script stubs. Echoes the
# case dir.
make_case() {
  local name=$1 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects/demo" "$fakebin"
  fm_write_meta "$home/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$home/projects/demo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/example/repo/pull/9"
  install_stubs "$fakebin" "$home/state"
  printf '%s\n' "$case_dir"
}

# Install the child-script stubs into the fakebin. Each stub logs its argv to a
# per-case log file and honors FM_TEST_* knobs, so a test can prove both that a
# step ran (or did not run) and how it failed. The teardown stub emulates the
# real teardown's final meta removal so resume paths see the same state shape.
install_stubs() {
  local fakebin=$1 state_dir=$2
  cat > "$fakebin/fm-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_PR_MERGE_LOG:?}"
if [ "${FM_TEST_PR_MERGE_FAIL:-0}" = 1 ]; then
  echo "merge refused: checks not green" >&2
  exit 1
fi
exit 0
SH
  cat > "$fakebin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_FLEET_SYNC_LOG:?}"
if [ "${FM_TEST_FLEET_SYNC_FAIL:-0}" = 1 ]; then
  echo "sync failed: fetch failed" >&2
  exit 1
fi
if [ "${FM_TEST_FLEET_SYNC_CURRENT:-0}" = 1 ]; then
  printf '%s\n' "$(basename "${1:-unknown}") already current"
else
  printf '%s\n' "$(basename "${1:-unknown}") synced abc..def"
fi
exit 0
SH
  cat > "$fakebin/fm-teardown.sh" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_TEST_TEARDOWN_LOG:?}"
if [ "\${FM_TEST_TEARDOWN_REFUSE:-0}" = 1 ]; then
  cat >&2 <<'EOF'
REFUSED: worktree has uncommitted changes.
uncommitted changes present
Commit them (or get the captain's explicit OK to discard, then --force).
EOF
  exit 1
fi
# The real teardown removes the task meta only after a successful cleanup.
rm -f -- "$state_dir/task-x1.meta"
printf '%s\n' "teardown \$1 complete (window fake, worktree fake)"
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'token=%s %s\n' "${GH_TOKEN:-}" "$*" >> "${FM_TEST_GH_LOG:?}"
case "${1:-} ${2:-}" in
  "pr view")
    printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}"
    exit 0
    ;;
  "auth token")
    printf '%s\n' "fixture-token-for-${4:-}"
    exit 0
    ;;
esac
echo "unexpected gh call: $*" >&2
exit 2
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_TASKS_AXI_LOG:?}"
case " $* " in
  *" --help"*)
    case "${1:-}" in
      update) printf '%s\n' "--archive-body" ;;
      mv) printf '%s\n' "[<id>...]" ;;
    esac
    exit 0
    ;;
esac
case "${1:-}" in
  --version)
    printf '%s\n' "tasks-axi 0.2.3"
    ;;
  show)
    if [ -n "${FM_TEST_TASKS_AXI_DONE:-}" ]; then
      case " $* " in
        *"--full"*)
          printf 'task:\n  id: %s\n  state: done\n  links: "pr:%s"\n' "${2:-}" "${FM_TEST_TASKS_AXI_PR:-}"
          ;;
        *)
          printf 'task:\n  id: %s\n  state: done\n' "${2:-}"
          ;;
      esac
    else
      printf 'task:\n  id: %s\n  state: %s\n' "${2:-}" "${FM_TEST_TASKS_AXI_STATE:-in_flight}"
    fi
    exit 0
    ;;
  done)
    if [ "${FM_TEST_TASKS_AXI_DONE_FAIL:-0}" = 1 ]; then
      echo "error: done failed" >&2
      exit 1
    fi
    exit 0
    ;;
  ready)
    if [ "${FM_TEST_TASKS_AXI_READY_FAIL:-0}" = 1 ]; then
      echo "error: ready failed" >&2
      exit 1
    fi
    printf '%s\n' "queued: none dispatchable right now"
    exit 0
    ;;
  *)
    echo "error: unexpected tasks-axi call: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/fm-pr-merge.sh" "$fakebin/fm-fleet-sync.sh" \
    "$fakebin/fm-teardown.sh" "$fakebin/gh" "$fakebin/tasks-axi"
}

# Run fm-land.sh against a case dir with the stub PATH and per-case logs.
run_land() {
  local case_dir=$1 rc
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_TEST_PR_MERGE_LOG="$case_dir/pr-merge.log" \
  FM_TEST_FLEET_SYNC_LOG="$case_dir/fleet-sync.log" \
  FM_TEST_TEARDOWN_LOG="$case_dir/teardown.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_TASKS_AXI_LOG="$case_dir/tasks-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$LAND" "$@"
  rc=$?
  return "$rc"
}

test_missing_project_refused() {
  local case_dir rc
  case_dir=$(make_case meta-no-project)
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "kind=ship" \
    "pr=https://github.com/example/repo/pull/9"

  set +e
  run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "meta-no-project: fm-land should stop with exit 1"
  assert_grep 'land: failed at clone-refresh: task task-x1 meta carries no project=' "$case_dir/stderr" \
    "meta-no-project: no failure line naming the missing project"
  assert_no_grep 'land: complete' "$case_dir/stdout" \
    "meta-no-project: a refused landing must not print the completion line"
  [ ! -s "$case_dir/teardown.log" ] || fail "meta-no-project: cleanup ran without a project"
  pass "fm-land stops with exit 1 at clone refresh when the meta carries no project="
}

test_happy_path() {
  local case_dir rc
  case_dir=$(make_case happy)
  set +e
  run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "happy: fm-land should succeed"
  assert_grep 'land: merge done' "$case_dir/stdout" "happy: no merge step line"
  assert_grep 'land: clone refresh done' "$case_dir/stdout" "happy: no clone refresh step line"
  assert_grep 'land: cleanup done' "$case_dir/stdout" "happy: no cleanup step line"
  assert_grep 'land: backlog done' "$case_dir/stdout" "happy: no backlog step line"
  assert_grep 'land: ready:' "$case_dir/stdout" "happy: no ready cue line"
  assert_grep 'land: complete task-x1 https://github.com/example/repo/pull/9' "$case_dir/stdout" \
    "happy: no final completion line with the pr url"
  grep -qxF 'task-x1 https://github.com/example/repo/pull/9' "$case_dir/pr-merge.log" \
    || fail "happy: fm-pr-merge was not invoked with the task id and pr url"
  grep -qxF "$case_dir/home/projects/demo" "$case_dir/fleet-sync.log" \
    || fail "happy: fm-fleet-sync was not invoked with the recorded project"
  grep -qxF 'task-x1' "$case_dir/teardown.log" \
    || fail "happy: fm-teardown was not invoked with the task id"
  grep -qxF 'done task-x1 --pr https://github.com/example/repo/pull/9' "$case_dir/tasks-axi.log" \
    || fail "happy: tasks-axi done was not invoked with the id and --pr"
  grep -qxF 'queued: none dispatchable right now' "$case_dir/stdout" \
    || fail "happy: tasks-axi ready output was not relayed"
  pass "fm-land runs the full chain in order and completes with the pr url"
}

test_merge_failure_stops_chain() {
  local case_dir rc
  case_dir=$(make_case merge-fail)
  set +e
  FM_TEST_PR_MERGE_FAIL=1 \
    run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fail: fm-land should stop with nonzero exit"
  assert_grep 'land: failed at merge: merge refused: checks not green' "$case_dir/stderr" \
    "merge-fail: no failure line with evidence"
  assert_no_grep 'land: complete' "$case_dir/stdout" "merge-fail: chain completed despite merge failure"
  [ ! -s "$case_dir/fleet-sync.log" ] || fail "merge-fail: clone refresh ran after merge failure"
  [ ! -s "$case_dir/teardown.log" ] || fail "merge-fail: cleanup ran after merge failure"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "merge-fail: the meta should survive a merge failure"
  pass "fm-land stops at a merge failure with evidence before any later step"
}

test_clone_refresh_failure_stops_chain() {
  local case_dir rc
  case_dir=$(make_case clone-fail)
  set +e
  FM_TEST_FLEET_SYNC_FAIL=1 \
    run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "clone-fail: fm-land should stop with nonzero exit"
  assert_grep 'land: failed at clone-refresh: sync failed: fetch failed' "$case_dir/stderr" \
    "clone-fail: no failure line with evidence"
  assert_no_grep 'land: complete' "$case_dir/stdout" "clone-fail: chain completed despite clone failure"
  [ ! -s "$case_dir/teardown.log" ] || fail "clone-fail: cleanup ran after clone refresh failure"
  pass "fm-land stops at a clone refresh failure with evidence before cleanup"
}

test_teardown_refusal_is_terminal() {
  local case_dir rc
  case_dir=$(make_case teardown-refuse)
  set +e
  FM_TEST_TEARDOWN_REFUSE=1 \
    run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "teardown-refuse: fm-land should stop with nonzero exit"
  assert_grep 'REFUSED: worktree has uncommitted changes.' "$case_dir/stderr" \
    "teardown-refuse: the refusal text was not preserved verbatim"
  assert_grep 'uncommitted changes present' "$case_dir/stderr" \
    "teardown-refuse: the refusal detail was not preserved"
  assert_grep 'land: failed at cleanup: REFUSED: worktree has uncommitted changes.' "$case_dir/stderr" \
    "teardown-refuse: no failure line with the refusal as evidence"
  assert_present "$case_dir/home/state/task-x1.meta" \
    "teardown-refuse: a refusal must preserve the task state"
  [ ! -s "$case_dir/tasks-axi.log" ] || fail "teardown-refuse: backlog step ran after a refusal"
  pass "fm-land treats a teardown refusal as terminal with the refusal text verbatim"
}

test_backlog_failure_stops_chain() {
  local case_dir rc
  case_dir=$(make_case backlog-fail)
  set +e
  FM_TEST_TASKS_AXI_DONE_FAIL=1 \
    run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "backlog-fail: fm-land should stop with nonzero exit"
  assert_grep 'land: failed at backlog: error: done failed' "$case_dir/stderr" \
    "backlog-fail: no failure line with evidence"
  assert_no_grep 'land: complete' "$case_dir/stdout" "backlog-fail: chain completed despite backlog failure"
  assert_no_grep 'land: ready:' "$case_dir/stdout" "backlog-fail: ready cue ran after backlog failure"
  assert_absent "$case_dir/home/state/task-x1.meta" \
    "backlog-fail: cleanup should have removed the meta"
  pass "fm-land stops at a backlog failure with evidence after cleanup"
}

test_ready_cue_failure_stops_chain() {
  local case_dir rc
  case_dir=$(make_case ready-fail)
  set +e
  FM_TEST_TASKS_AXI_READY_FAIL=1 \
    run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ready-fail: fm-land should stop with nonzero exit"
  assert_grep 'land: failed at ready-cue: error: ready failed' "$case_dir/stderr" \
    "ready-fail: no failure line with evidence"
  assert_no_grep 'land: complete' "$case_dir/stdout" "ready-fail: completion line printed despite failure"
  pass "fm-land stops at a ready cue failure with evidence"
}

test_resume_skips_already_merged_pr() {
  local case_dir rc
  case_dir=$(make_case resume-merged)
  set +e
  FM_TEST_FLEET_SYNC_FAIL=1 \
    run_land "$case_dir" task-x1 > "$case_dir/run1.out" 2> "$case_dir/run1.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "resume-merged: the first run should stop at clone refresh"

  set +e
  FM_TEST_GH_STATE=MERGED \
    run_land "$case_dir" task-x1 > "$case_dir/run2.out" 2> "$case_dir/run2.err"
  rc=$?
  set -e

  expect_code 0 "$rc" "resume-merged: the resume run should complete"
  assert_grep 'land: merge already done' "$case_dir/run2.out" \
    "resume-merged: resume did not skip the already-merged pr"
  assert_grep 'land: clone refresh done' "$case_dir/run2.out" \
    "resume-merged: resume did not continue at clone refresh"
  assert_grep 'land: complete task-x1 https://github.com/example/repo/pull/9' "$case_dir/run2.out" \
    "resume-merged: resume did not complete with the pr url"
  [ "$(wc -l < "$case_dir/pr-merge.log")" -eq 1 ] \
    || fail "resume-merged: the merge was attempted again on resume"
  pass "fm-land resume skips an already-merged PR and continues from clone refresh"
}

test_resume_after_teardown_skips_completed_steps() {
  local case_dir rc
  case_dir=$(make_case resume-torn-down)
  set +e
  FM_TEST_TASKS_AXI_DONE_FAIL=1 \
    run_land "$case_dir" task-x1 > "$case_dir/run1.out" 2> "$case_dir/run1.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "resume-torn-down: the first run should stop at backlog completion"
  assert_absent "$case_dir/home/state/task-x1.meta" \
    "resume-torn-down: the first run should have torn the task down"

  set +e
  FM_TEST_TASKS_AXI_DONE=1 FM_TEST_TASKS_AXI_PR=https://github.com/example/repo/pull/9 \
    run_land "$case_dir" task-x1 > "$case_dir/run2.out" 2> "$case_dir/run2.err"
  rc=$?
  set -e

  expect_code 0 "$rc" "resume-torn-down: the resume run should complete"
  assert_grep 'land: merge already done' "$case_dir/run2.out" \
    "resume-torn-down: resume did not skip the merge step"
  assert_grep 'land: clone refresh already done' "$case_dir/run2.out" \
    "resume-torn-down: resume did not skip the clone refresh step"
  assert_grep 'land: cleanup already done' "$case_dir/run2.out" \
    "resume-torn-down: resume did not skip the cleanup step"
  assert_grep 'land: backlog already done' "$case_dir/run2.out" \
    "resume-torn-down: resume did not skip the backlog step"
  assert_grep 'land: complete task-x1 https://github.com/example/repo/pull/9' "$case_dir/run2.out" \
    "resume-torn-down: resume did not recover the pr url"
  [ "$(wc -l < "$case_dir/teardown.log")" -eq 1 ] \
    || fail "resume-torn-down: teardown was run again on resume"
  pass "fm-land resume after a completed teardown skips every completed step"
}

test_merge_probe_honors_recorded_account() {
  local case_dir rc
  case_dir=$(make_case gh-account)
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/home/projects/demo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "gh_account=personal" \
    "pr=https://github.com/example/private-repo/pull/31"

  set +e
  run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gh-account: fm-land should succeed"
  grep -qxF 'token=fixture-token-for-personal pr view 31 --repo example/private-repo --json state -q .state' "$case_dir/gh.log" \
    || fail "gh-account: the merge probe did not read the pr under the recorded account's token"
  grep -qxF 'task-x1 https://github.com/example/private-repo/pull/31' "$case_dir/pr-merge.log" \
    || fail "gh-account: the merge did not receive the recorded pr url"
  pass "fm-land's merge probe honors a recorded gh account token"
}

test_manual_backend_prints_instructions_without_editing() {
  local case_dir rc backlog
  case_dir=$(make_case manual-backend)
  backlog="$case_dir/home/data/backlog.md"
  printf '%s\n' "- [ ] task-x1 - firstmate: some shipped task (repo: demo) (kind: ship)" > "$backlog"
  printf 'manual\n' > "$case_dir/home/config/backlog-backend"

  set +e
  run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "manual-backend: fm-land should succeed"
  assert_grep 'land: manual backlog: edit' "$case_dir/stdout" \
    "manual-backend: no manual edit instruction"
  assert_grep 'land: manual backlog: re-scan' "$case_dir/stdout" \
    "manual-backend: no manual queue re-evaluation pointer"
  assert_grep 'land: complete task-x1 https://github.com/example/repo/pull/9' "$case_dir/stdout" \
    "manual-backend: no completion line"
  assert_grep '- [ ] task-x1' "$backlog" \
    "manual-backend: the backlog file was edited"
  [ ! -e "$case_dir/tasks-axi.log" ] || fail "manual-backend: tasks-axi was invoked in manual mode"
  pass "fm-land's manual backlog backend prints the edit instruction and never edits the backlog"
}

test_missing_meta_refused() {
  local case_dir rc
  case_dir=$(make_case missing-meta)
  rm -f "$case_dir/home/state/task-x1.meta"

  set +e
  run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-land should refuse with exit 1"
  assert_grep 'error: no meta for task task-x1' "$case_dir/stderr" \
    "missing-meta: refusal did not name the missing meta"
  assert_grep 'land: refused: no meta for task task-x1' "$case_dir/stderr" \
    "missing-meta: no terminal land: refused verdict line"
  assert_no_grep 'land: complete' "$case_dir/stdout" \
    "missing-meta: a refused landing must not print the completion line"
  [ ! -s "$case_dir/pr-merge.log" ] || fail "missing-meta: merge ran without meta"
  [ ! -s "$case_dir/teardown.log" ] || fail "missing-meta: cleanup ran without meta"
  pass "fm-land refuses with exit 1 before any action when the task meta is missing"
}

test_meta_without_pr_refused() {
  local case_dir rc
  case_dir=$(make_case meta-no-pr)
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/home/projects/demo" \
    "kind=ship"

  set +e
  run_land "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "meta-no-pr: fm-land should refuse with exit 1"
  assert_grep 'carries no pr=' "$case_dir/stderr" \
    "meta-no-pr: refusal did not name the missing pr"
  assert_grep 'land: refused: task task-x1 meta carries no pr=' "$case_dir/stderr" \
    "meta-no-pr: no terminal land: refused verdict line"
  assert_no_grep 'land: complete' "$case_dir/stdout" \
    "meta-no-pr: a refused landing must not print the completion line"
  [ ! -s "$case_dir/pr-merge.log" ] || fail "meta-no-pr: merge ran without a recorded pr"
  pass "fm-land refuses with exit 1 when the task meta carries no pr="
}

test_happy_path
test_missing_project_refused
test_merge_failure_stops_chain
test_clone_refresh_failure_stops_chain
test_teardown_refusal_is_terminal
test_backlog_failure_stops_chain
test_ready_cue_failure_stops_chain
test_resume_skips_already_merged_pr
test_resume_after_teardown_skips_completed_steps
test_merge_probe_honors_recorded_account
test_manual_backend_prints_instructions_without_editing
test_missing_meta_refused
test_meta_without_pr_refused
