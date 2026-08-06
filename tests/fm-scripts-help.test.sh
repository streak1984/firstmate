#!/usr/bin/env bash
# -h/--help handling for the fleet entrypoints whose first positional is a task
# id or send target (bin/fm-pr-merge.sh, bin/fm-pr-check.sh, bin/fm-send.sh).
# These scripts used to treat --help as the positional and fail fail-closed,
# leaving the header comment as the only discoverable usage.
# -h/--help is honored only as the FIRST argument and prints the header usage
# with exit 0; every other invocation keeps its exact current behavior - in
# particular fm-send.sh must keep treating a later --help as literal message
# text, and a missing/positional failure must keep its existing error text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-scripts-help)

setup_home() {  # <name> -> echoes a home dir with an empty state dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_pr_merge_help_prints_usage() {
  local out rc
  out=$("$PR_MERGE" --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-pr-merge.sh --help should exit 0"
  assert_contains "$out" "Usage: fm-pr-merge.sh" "fm-pr-merge.sh --help should print the header usage"
  out=$("$PR_MERGE" -h 2>&1); rc=$?
  expect_code 0 "$rc" "fm-pr-merge.sh -h should exit 0"
  assert_contains "$out" "Usage: fm-pr-merge.sh" "fm-pr-merge.sh -h should print the header usage"
  pass "fm-scripts help: fm-pr-merge.sh -h/--help prints usage and exits 0"
}

test_pr_check_help_prints_usage() {
  local out rc
  out=$("$PR_CHECK" --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-pr-check.sh --help should exit 0"
  assert_contains "$out" "Usage: fm-pr-check.sh" "fm-pr-check.sh --help should print the header usage"
  out=$("$PR_CHECK" -h 2>&1); rc=$?
  expect_code 0 "$rc" "fm-pr-check.sh -h should exit 0"
  assert_contains "$out" "Usage: fm-pr-check.sh" "fm-pr-check.sh -h should print the header usage"
  pass "fm-scripts help: fm-pr-check.sh -h/--help prints usage and exits 0"
}

test_send_help_prints_usage() {
  # --help must win before the FM_HOME gate so it works in a bare shell.
  local out rc
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE "$SEND" --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-send.sh --help should exit 0"
  assert_contains "$out" "Usage: fm-send.sh" "fm-send.sh --help should print the header usage"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE "$SEND" -h 2>&1); rc=$?
  expect_code 0 "$rc" "fm-send.sh -h should exit 0"
  assert_contains "$out" "Usage: fm-send.sh" "fm-send.sh -h should print the header usage"
  pass "fm-scripts help: fm-send.sh -h/--help prints usage and exits 0"
}

test_pr_merge_missing_args_still_fails() {
  local dir err rc
  dir="$TMP_ROOT/pr-merge-missing"; mkdir -p "$dir"
  err="$dir/err"
  "$PR_MERGE" >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "fm-pr-merge.sh with no args should still exit 2"
  assert_contains "$(cat "$err")" "error: invalid PR merge request" "fm-pr-merge.sh missing args should keep the existing error text"
  pass "fm-scripts help: fm-pr-merge.sh missing args still fails with the existing error"
}

test_pr_check_missing_args_still_fails() {
  local dir err rc
  dir="$TMP_ROOT/pr-check-missing"; mkdir -p "$dir"
  err="$dir/err"
  "$PR_CHECK" >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "fm-pr-check.sh with no args should still exit 2"
  assert_contains "$(cat "$err")" "error: invalid PR check request" "fm-pr-check.sh missing args should keep the existing error text"
  pass "fm-scripts help: fm-pr-check.sh missing args still fails with the existing error"
}

test_send_unresolvable_target_still_fails() {
  local dir home err rc
  dir="$TMP_ROOT/send-unresolvable"; mkdir -p "$dir"; err="$dir/err"
  home=$(setup_home send-unresolvable)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SEND" ghost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send.sh with an unresolvable target should still fail"
  assert_contains "$(cat "$err")" "error: target 'ghost-target' is not resolvable" "fm-send.sh unresolvable target should keep the existing error text"
  pass "fm-scripts help: fm-send.sh unresolvable target still fails with the existing error"
}

test_send_later_help_is_message_text() {
  local dir home err rc
  dir="$TMP_ROOT/send-later-help"; mkdir -p "$dir"; err="$dir/err"
  home=$(setup_home send-later-help)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$SEND" ghost-target --help >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send.sh must not intercept a later --help"
  assert_not_contains "$(cat "$err")" "Usage" "a later --help must not print usage"
  assert_contains "$(cat "$err")" "error: target 'ghost-target' is not resolvable" "a later --help should stay message text and hit the normal target-resolution error"
  pass "fm-scripts help: fm-send.sh treats a later --help as message text"
}

test_pr_merge_help_prints_usage
test_pr_check_help_prints_usage
test_send_help_prints_usage
test_pr_merge_missing_args_still_fails
test_pr_check_missing_args_still_fails
test_send_unresolvable_target_still_fails
test_send_later_help_is_message_text
