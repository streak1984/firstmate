#!/usr/bin/env bash
# Behavior tests for bin/fm-testcount-check.sh.
# Fixture repos live in the task temp dir and never touch a real repository.
# Covered: a genuine test-count drop, the moved-base false-alarm case, clean
# no-change runs, deleted test files, the --all table, all detection and
# counting heuristics, default-branch resolution, commit-content-only
# counting, and the usage/environment error contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-testcount-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-testcount-check)
fm_git_identity

# make_repo <dir> -> a repo on main with one empty init commit.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
}

# commit_file <dir> <path> <content> <msg> -> write one file and commit.
commit_file() {
  local dir=$1 path=$2 content=$3 msg=$4
  mkdir -p "$dir/$(dirname "$path")"
  printf '%s\n' "$content" > "$dir/$path"
  git -C "$dir" add "$path"
  git -C "$dir" commit -q -m "$msg"
}

# assert_row <out> <path-regex> <base> <head> <delta> <msg>: the per-file table
# must contain a row for <path-regex> with exactly those counts.
assert_row() {
  local out=$1 path=$2 base=$3 head=$4 delta=$5 msg=$6
  printf '%s\n' "$out" | grep -Eq "${path}[[:space:]]+${base}[[:space:]]+${head}[[:space:]]+${delta}" \
    || fail "$msg (output: $out)"
}

# assert_no_row <out> <path-regex> <msg>: no table row may mention <path-regex>.
assert_no_row() {
  local out=$1 path=$2 msg=$3
  ! printf '%s\n' "$out" | grep -Eq "${path}[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+-?[0-9]+" \
    || fail "$msg (output: $out)"
}

test_genuine_drop_detected() {
  local repo out rc
  repo="$TMP_ROOT/genuine-drop"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py \
    $'def test_one():\ndef test_two():\ndef test_three():\ndef test_four():\ndef test_five():\n' c1
  git -C "$repo" checkout -q -b feature
  commit_file "$repo" tests/alpha.py $'def test_one():\ndef test_two():\n' f1
  out=$("$TOOL" "$repo" main 2>&1); rc=$?
  expect_code 1 "$rc" "a genuine drop should exit 1"
  assert_contains "$out" "merge-base:" "output should print the merge-base line"
  assert_row "$out" 'tests/alpha\.py' 5 2 -3 "genuine drop row should show base 5 head 2 delta -3"
  assert_contains "$out" "totals: files=1 base=5 head=2" "genuine drop totals"
  pass "fm-testcount-check: genuine drop detected (exit 1, drop row, totals)"
}

test_moved_base_false_alarm() {
  local repo out rc mb tip
  repo="$TMP_ROOT/moved-base"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py \
    $'def test_one():\ndef test_two():\ndef test_three():\ndef test_four():\ndef test_five():\n' c1
  git -C "$repo" checkout -q -b feature
  commit_file "$repo" tests/alpha.py \
    $'# feature tweak\ndef test_one():\ndef test_two():\ndef test_three():\ndef test_four():\ndef test_five():\n' f1
  git -C "$repo" checkout -q main
  commit_file "$repo" tests/alpha.py \
    $'def test_one():\ndef test_two():\ndef test_three():\ndef test_four():\ndef test_five():\ndef test_six():\ndef test_seven():\n' c2
  git -C "$repo" checkout -q feature
  mb=$(git -C "$repo" merge-base HEAD main)
  tip=$(git -C "$repo" rev-parse main)
  out=$("$TOOL" "$repo" main 2>&1); rc=$?
  expect_code 0 "$rc" "a base that moved after the branch was cut must not alarm"
  assert_contains "$out" "merge-base: $mb" "merge-base line should print the fork point, not the moved tip"
  assert_not_contains "$out" "merge-base: $tip" "the moved main tip must never be the comparison base"
  assert_contains "$out" "totals: files=1 base=5 head=5" "fork-point counts should stay 5/5"
  assert_contains "$out" "(none)" "dropped table should be empty"
  assert_no_row "$out" 'tests/alpha\.py' "no drop row for an unchanged file"
  pass "fm-testcount-check: moved base does not produce a false alarm"
}

test_no_change_clean() {
  local repo out rc
  repo="$TMP_ROOT/no-change"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py \
    $'def test_one():\ndef test_two():\ndef test_three():\n' c1
  out=$("$TOOL" "$repo" main 2>&1); rc=$?
  expect_code 0 "$rc" "a no-change run should exit 0"
  assert_contains "$out" "(none)" "no-change run should show an empty dropped table"
  assert_contains "$out" "totals: files=1 base=3 head=3" "no-change totals"
  out=$("$TOOL" "$repo" 2>&1); rc=$?
  expect_code 0 "$rc" "default base resolution should stay clean"
  assert_contains "$out" "totals: files=1 base=3 head=3" "default-resolution totals"
  pass "fm-testcount-check: no-change run exits 0 (explicit and default base)"
}

test_deleted_file_flagged() {
  local repo out rc
  repo="$TMP_ROOT/deleted-file"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py \
    $'def test_one():\ndef test_two():\ndef test_three():\n' c1
  commit_file "$repo" tests/beta.py $'def test_one():\ndef test_two():\n' c2
  git -C "$repo" checkout -q -b feature
  git -C "$repo" rm -q tests/beta.py
  git -C "$repo" commit -q -m f1
  out=$("$TOOL" "$repo" main 2>&1); rc=$?
  expect_code 1 "$rc" "a deleted test file should exit 1"
  assert_row "$out" 'tests/beta\.py' 2 0 -2 "deleted file should show base 2 head 0 delta -2"
  assert_contains "$out" "totals: files=2 base=5 head=3" "deleted-file totals"
  assert_no_row "$out" 'tests/alpha\.py' "an unchanged file should not appear in the dropped table"
  pass "fm-testcount-check: deleted test file flagged as a drop to zero"
}

test_all_table() {
  local repo out rc
  repo="$TMP_ROOT/all-table"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py \
    $'def test_one():\ndef test_two():\ndef test_three():\n' c1
  git -C "$repo" checkout -q -b feature
  commit_file "$repo" tests/alpha.py \
    $'def test_one():\ndef test_two():\ndef test_three():\ndef test_four():\n' f1
  commit_file "$repo" gamma.test.js $'it("a", () => {});\nit("b", () => {});\ntest("c", () => {});\n' f2
  out=$("$TOOL" --all "$repo" main 2>&1); rc=$?
  expect_code 0 "$rc" "increases and additions should exit 0"
  assert_contains "$out" "all files (path, base, head, delta):" "--all should label the full table"
  assert_row "$out" 'tests/alpha\.py' 3 4 1 "increased file row should show base 3 head 4 delta +1"
  assert_row "$out" 'gamma\.test\.js' 0 3 3 "added file row should show base 0 head 3 delta +3"
  assert_contains "$out" "totals: files=2 base=3 head=7" "--all totals"
  out=$("$TOOL" "$repo" main 2>&1); rc=$?
  expect_code 0 "$rc" "default mode should stay clean for increases"
  assert_contains "$out" "(none)" "default mode should not list increases"
  assert_no_row "$out" 'tests/alpha\.py' "increased file must not appear in the default table"
  assert_no_row "$out" 'gamma\.test\.js' "added file must not appear in the default table"
  pass "fm-testcount-check: --all table includes unchanged and increased files"
}

test_detection_and_counting_heuristics() {
  local repo out rc
  repo="$TMP_ROOT/heuristics"
  make_repo "$repo"
  commit_file "$repo" test_count.py \
    $'def test_a():\n    assert True\nasync def test_b():\n    assert True\ndef test_c():\n    assert True\n' c1
  commit_file "$repo" tool_test.py $'def test_util():\n    assert True\n' c2
  commit_file "$repo" tests/plain.py \
    $'def test_plain_one():\n    assert True\ndef test_plain_two():\n    assert True\n' c3
  commit_file "$repo" util.test.sh $'test_alpha() {\n    :\n}\ntest_beta() {\n    :\n}\n' c4
  commit_file "$repo" types.test.ts $'it("a", () => {});\nit("b", () => {});\ntest("c", () => {});\n' c5
  commit_file "$repo" node.test.js $'test("x", () => {});\n' c6
  commit_file "$repo" widget.spec.ts $'it("w", () => {});\n' c7
  commit_file "$repo" cases_test.go $'func TestAlpha(t *testing.T) {}\nfunc TestBeta(t *testing.T) {}\n' c8
  out=$("$TOOL" --all "$repo" main 2>&1); rc=$?
  expect_code 0 "$rc" "identical base and head should exit 0"
  assert_row "$out" 'test_count\.py' 3 3 0 "python def test_ (incl. async) counts 3"
  assert_row "$out" 'tool_test\.py' 1 1 0 "python *_test.py counts 1"
  assert_row "$out" 'tests/plain\.py' 2 2 0 "python under tests/ dir counts 2"
  assert_row "$out" 'util\.test\.sh' 2 2 0 "shell test_NAME() counts 2"
  assert_row "$out" 'types\.test\.ts' 3 3 0 "ts it( + test( occurrences count 3"
  assert_row "$out" 'node\.test\.js' 1 1 0 "js test( occurrence counts 1"
  assert_row "$out" 'widget\.spec\.ts' 1 1 0 "ts spec file it( counts 1"
  assert_row "$out" 'cases_test\.go' 2 2 0 "go func Test counts 2"
  assert_contains "$out" "totals: files=8 base=15 head=15" "heuristics totals"
  pass "fm-testcount-check: detection and counting heuristics for all documented patterns"
}

test_default_branch_resolution() {
  local repo out rc mb
  repo="$TMP_ROOT/default-branch"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py $'def test_one():\ndef test_two():\n' c1
  git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse main)"
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$repo" checkout -q -b feature
  commit_file "$repo" util.test.sh $'test_foo() {\n    :\n}\n' f1
  mb=$(git -C "$repo" merge-base HEAD main)
  out=$("$TOOL" "$repo" 2>&1); rc=$?
  expect_code 0 "$rc" "default resolution to origin/HEAD should stay clean"
  assert_contains "$out" "merge-base: $mb" "merge-base line should resolve through origin/HEAD"
  assert_contains "$out" "totals: files=2 base=2 head=3" "default-resolution totals"
  pass "fm-testcount-check: default base resolves through origin/HEAD"
}

test_working_tree_ignored() {
  local repo out rc status
  repo="$TMP_ROOT/working-tree"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py $'def test_one():\ndef test_two():\n' c1
  out=$("$TOOL" "$repo" main 2>&1); rc=$?
  expect_code 0 "$rc" "clean run before the edit"
  printf '%s\n' 'def nothing():' '    pass' > "$repo/tests/alpha.py"
  status=$(git -C "$repo" status --porcelain)
  assert_contains "$status" "tests/alpha.py" "fixture should have a dirty working tree"
  out=$("$TOOL" "$repo" main 2>&1); rc=$?
  expect_code 0 "$rc" "uncommitted working-tree edits must not affect counts"
  assert_contains "$out" "totals: files=1 base=2 head=2" "counts must come from commit content only"
  pass "fm-testcount-check: counts come from commit content, never the working tree"
}

test_non_repo_exit_2() {
  local out rc
  mkdir -p "$TMP_ROOT/not-a-repo"
  out=$("$TOOL" "$TMP_ROOT/not-a-repo" 2>&1); rc=$?
  expect_code 2 "$rc" "a non-repo directory should exit 2"
  assert_contains "$out" "not a git repository" "non-repo error should name the failure"
  pass "fm-testcount-check: non-repo directory exits 2 with a clear message"
}

test_unknown_ref_exit_2() {
  local repo out rc
  repo="$TMP_ROOT/unknown-ref"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py $'def test_one():\n' c1
  out=$("$TOOL" "$repo" no-such-ref 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown base ref should exit 2"
  assert_contains "$out" "cannot resolve base ref 'no-such-ref'" "unknown-ref error should name the ref"
  pass "fm-testcount-check: unknown base ref exits 2 with a clear message"
}

test_usage_errors() {
  local repo out rc
  repo="$TMP_ROOT/usage-errors"
  make_repo "$repo"
  commit_file "$repo" tests/alpha.py $'def test_one():\n' c1
  out=$("$TOOL" 2>&1); rc=$?
  expect_code 2 "$rc" "missing repo-dir should exit 2"
  assert_contains "$out" "missing <repo-dir>" "missing-arg error should say what is missing"
  out=$("$TOOL" "$repo" main extra 2>&1); rc=$?
  expect_code 2 "$rc" "too many arguments should exit 2"
  assert_contains "$out" "too many arguments" "too-many-args error should say so"
  out=$("$TOOL" --bogus "$repo" 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown option should exit 2"
  assert_contains "$out" "unknown option" "unknown-option error should say so"
  pass "fm-testcount-check: usage errors exit 2"
}

test_help_prints_header() {
  local out rc
  out=$("$TOOL" -h 2>&1); rc=$?
  expect_code 0 "$rc" "-h should exit 0"
  assert_contains "$out" "Usage: fm-testcount-check.sh" "-h should print the header usage"
  assert_contains "$out" "merge-base" "-h should document the merge-base rule"
  assert_contains "$out" "rename" "-h should document the rename caveat"
  out=$("$TOOL" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help should exit 0"
  assert_contains "$out" "Usage: fm-testcount-check.sh" "--help should print the header usage"
  pass "fm-testcount-check: -h/--help prints the header and exits 0"
}

test_genuine_drop_detected
test_moved_base_false_alarm
test_no_change_clean
test_deleted_file_flagged
test_all_table
test_detection_and_counting_heuristics
test_default_branch_resolution
test_working_tree_ignored
test_non_repo_exit_2
test_unknown_ref_exit_2
test_usage_errors
test_help_prints_header
